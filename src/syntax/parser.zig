//! Table-driven LALR(1) parser.
//!
//! The ACTION/GOTO tables are generated from the grammar (`grammar.zig` →
//! `lr.zig`) by a cached codegen step (`gen_parser_tables.zig`) and imported
//! here as `parser_tables`. This file is the runtime: a tight shift/reduce loop
//! over the flat tables, plus the semantic actions that build the AST.
//!
//! Pipeline: source → scanner → token array → driver. The driver maintains a
//! state stack and a parallel semantic-value stack; each reduce runs one action
//! to fold children into an AST node. Nodes live in the caller's arena. The
//! grammar is pure LR — the lambda-pattern-vs-attrset ambiguity is resolved
//! inside the grammar (a unified `brace` nonterminal), not by any pre-pass.

const std = @import("std");
const token = @import("token.zig");
const TokenType = token.TokenType;
const Token = token.Token;
const ast = @import("ast.zig");
const Node = ast.Node;
const NodeTag = ast.NodeTag;
const diagnostic = @import("diagnostic.zig");
const Diagnostic = diagnostic.Diagnostic;
const Scanner = @import("scanner.zig").Scanner;
const grammar = @import("grammar.zig");
const lr = @import("lr.zig");

/// Comptime-generated LALR tables (see `gen_parser_tables.zig`). Unit `pass`
/// productions are eliminated during generation, so the driver never performs a
/// do-nothing chain reduction — every reduce runs a real semantic action.
const Tab = @import("parser_tables");
const Act = grammar.Act;

/// One attribute-path segment: a static name or a dynamic `${expr}`.
const Seg = union(enum) {
    static: Node.Atom,
    dynamic: *Node,
};

/// Accumulator for an attribute path's segments. Almost every attrpath is 1-2
/// segments (`x`, `x.y`), so those live inline with no allocation; longer paths
/// spill to a heap list. The segments are transient scratch — every consumer
/// (`foldBind`/`buildSelect`/`makeHasAttr`) copies them into a right-sized arena
/// structure — so inline storage never escapes.
const seg_inline = 2;
const SegAccum = struct {
    buf: [seg_inline]Seg = undefined,
    len: u32 = 0,
    spill: ?*std.ArrayListUnmanaged(Seg) = null,

    fn push(self: *SegAccum, a: std.mem.Allocator, seg: Seg) !void {
        if (self.spill) |s| {
            try s.append(a, seg);
        } else if (self.len < seg_inline) {
            self.buf[self.len] = seg;
        } else {
            const s = try a.create(std.ArrayListUnmanaged(Seg));
            s.* = .empty;
            try s.ensureTotalCapacity(a, seg_inline * 2);
            s.appendSliceAssumeCapacity(self.buf[0..self.len]);
            s.appendAssumeCapacity(seg);
            self.spill = s;
        }
        self.len += 1;
    }

    fn items(self: *const SegAccum) []const Seg {
        return if (self.spill) |s| s.items else self.buf[0..self.len];
    }
};

/// One element inside a `{ ... }`. The parser cannot know whether a brace is an
/// attribute set or a lambda pattern until it sees what follows the `}`, so
/// each element is parsed into this union and validated once the role is known.
const Clause = union(enum) {
    formal: Node.LambdaAttrParam, // pattern: `a` or `a ? default`
    ellipsis, // pattern: `...`
    bind: Node.AttrSetEntry, // attrset: `attrpath = expr`
    inherit: []Node.AttrSetEntry, // attrset: `inherit ...` (one or more names)
};

/// A parsed `{ ... }` group plus its opening brace (for diagnostics).
const Brace = struct {
    clauses: std.ArrayListUnmanaged(Clause),
    lbrace: Token,
};

/// A semantic value on the parse stack. Which variant is live is fully
/// determined by the grammar symbol reduced, so the union is untagged: no tag
/// byte in the (hot, per-symbol) value stack and no discriminant checks.
const Value = union {
    tok: Token,
    node: *Node,
    seg: Seg,
    segs: SegAccum,
    entries: std.ArrayListUnmanaged(Node.AttrSetEntry),
    names: std.ArrayListUnmanaged(Node.Atom),
    nodes: std.ArrayListUnmanaged(*Node),
    clause: Clause,
    clauses: std.ArrayListUnmanaged(Clause),
    brace: Brace,
    nil: void,
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    arena: *ast.AstArena,
    source: []const u8,
    had_error: bool,
    diagnostics: std.ArrayListUnmanaged(Diagnostic),
    /// Whether any `|>`/`<|` pipe operator was parsed. Enforcement that the
    /// `pipe-operators` feature is enabled happens at the compile chokepoint
    /// (`Evaluator.parseAndCompile`), which reads this flag.
    used_pipe_operators: bool,
    /// The earliest pipe operator token seen, for a precise "disabled"
    /// diagnostic.
    first_pipe_token: ?Token,

    pub fn init(allocator: std.mem.Allocator, arena: *ast.AstArena, source: []const u8) Parser {
        return .{
            .allocator = allocator,
            .arena = arena,
            .source = source,
            .had_error = false,
            .diagnostics = .empty,
            .used_pipe_operators = false,
            .first_pipe_token = null,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.diagnostics.deinit(self.allocator);
    }

    pub fn span(self: *const Parser, tok: Token) []const u8 {
        return self.source[tok.offset .. tok.offset + tok.len];
    }

    fn arenaAllocator(self: *Parser) std.mem.Allocator {
        return self.arena.allocator();
    }

    // ---- pipe provenance ----

    fn notePipe(self: *Parser, tok: Token) void {
        if (!self.used_pipe_operators) {
            self.used_pipe_operators = true;
            self.first_pipe_token = tok;
        } else if (self.first_pipe_token) |cur| {
            if (tok.offset < cur.offset) self.first_pipe_token = tok;
        }
    }

    // ---- diagnostics ----

    /// Line number for a token, recomputed from its offset (tokens don't
    /// carry line numbers; diagnostics are cold). Reproduces the scanner's
    /// old incremental counter exactly: it had counted every newline up to
    /// the END of the token when the token was made — except an
    /// unterminated string's `error_token` (spans to EOF, body newlines
    /// never counted), which reported its start line.
    pub fn tokenLine(source: []const u8, tok: Token) u32 {
        const target = if (tok.type == .error_token) tok.offset else tok.offset + tok.len;
        return diagnostic.lineForOffset(source, target);
    }

    fn report(self: *Parser, tok: Token, msg: []const u8) void {
        self.had_error = true;
        self.diagnostics.append(self.allocator, .{
            .line = tokenLine(self.source, tok),
            .column = diagnostic.columnForOffset(self.source, tok.offset),
            .offset = tok.offset,
            .len = tok.len,
            .token_type = tok.type,
            .message = msg,
        }) catch {};
    }

    // ---- entry point ----

    pub fn parse(self: *Parser) !*Node {
        var scanner = Scanner.init(self.source);
        const root = try self.drive(&scanner);

        if (self.had_error) return error.ParseError;
        return root orelse error.ParseError;
    }

    // ---- the shift/reduce driver ----

    /// Pull the next parseable token, reporting (and skipping) invalid ones.
    fn nextToken(self: *Parser, scanner: *Scanner) Token {
        while (true) {
            const tk = scanner.next();
            if (tk.type == .error_token) {
                self.report(tk, "Invalid token.");
                continue;
            }
            return tk;
        }
    }

    fn drive(self: *Parser, scanner: *Scanner) !?*Node {
        const gpa = self.allocator;
        // Tokens stream straight from the scanner — no token array. The
        // stack starts at a depth that covers any sane nesting (left
        // recursion keeps lists flat, so depth tracks *nesting* only) and
        // grows geometrically for pathological inputs.
        var cap: usize = 4096;
        var states = try gpa.alloc(u32, cap);
        defer gpa.free(states);
        var vals = try gpa.alloc(Value, cap);
        defer gpa.free(vals);

        var sp: usize = 0; // number of entries on the stack
        states[sp] = Tab.start_state;
        vals[sp] = .{ .nil = {} };
        sp += 1;

        var tok = self.nextToken(scanner);
        var error_count: usize = 0;
        const max_errors = 32;
        // Error cooldown: after reporting an error, stay quiet until the parser
        // has shifted a few real tokens again. This collapses the cascade of
        // spurious follow-on errors panic-mode recovery would otherwise emit.
        // Starts "elapsed" so the first error always reports.
        const cooldown = 3;
        var quiet_shifts: u32 = cooldown;
        while (true) {
            const state = states[sp - 1];
            const la = @intFromEnum(tok.type);
            const c = Tab.action[state * Tab.num_terminals + la];
            switch (lr.cellKind(c)) {
                lr.ACT_SHIFT => {
                    if (sp == cap) {
                        cap *= 2;
                        states = try gpa.realloc(states, cap);
                        vals = try gpa.realloc(vals, cap);
                    }
                    states[sp] = lr.cellArg(c);
                    vals[sp] = .{ .tok = tok };
                    sp += 1;
                    tok = self.nextToken(scanner);
                    if (quiet_shifts < cooldown) quiet_shifts += 1;
                },
                lr.ACT_REDUCE => {
                    const p = lr.cellArg(c);
                    const n = Tab.prod_rhs_len[p];
                    const base = sp - n;
                    const result = try self.runAction(grammar.act_of_prod[p], vals[base .. base + n]);
                    sp = base;
                    const g = Tab.goto_table[states[sp - 1] * Tab.num_nonterminals + Tab.prod_lhs[p]];
                    if (g < 0) {
                        self.report(tok, "Internal parser error (no goto).");
                        return null;
                    }
                    if (sp == cap) { // only epsilon productions grow the stack here
                        cap *= 2;
                        states = try gpa.realloc(states, cap);
                        vals = try gpa.realloc(vals, cap);
                    }
                    states[sp] = @intCast(g);
                    vals[sp] = result;
                    sp += 1;
                },
                lr.ACT_ACCEPT => {
                    return vals[sp - 1].node;
                },
                else => {
                    if (quiet_shifts >= cooldown) {
                        self.reportUnexpected(state, tok);
                        error_count += 1;
                        if (error_count >= max_errors) return null;
                    } else {
                        self.had_error = true;
                    }
                    quiet_shifts = 0;
                    if (!self.recover(states[sp - 1], scanner, &tok)) return null;
                },
            }
        }
    }

    /// Panic-mode recovery. Keep the parse stack intact (preserving the current
    /// context, e.g. the enclosing `{ ... }`) and discard input tokens until the
    /// current top state has a real action on one — typically the next clause
    /// separator or the context's closing token. The value stack is untouched,
    /// so it stays consistent with the state stack and semantic actions keep
    /// running safely; the recovered tree is discarded anyway, since the
    /// recorded error forces `parse` to return `ParseError`. Returns false at
    /// EOF (nothing left to resynchronize on).
    fn recover(self: *Parser, top_state: u32, scanner: *Scanner, tok: *Token) bool {
        const NT = Tab.num_terminals;
        while (true) {
            if (tok.type == .eof) return false;
            tok.* = self.nextToken(scanner); // discard a token (starting with the offending one)
            const la = @intFromEnum(tok.type);
            if (lr.cellKind(Tab.action[top_state * NT + la]) != lr.ACT_ERROR) return true;
        }
    }

    fn reportUnexpected(self: *Parser, state: u32, tok: Token) void {
        _ = state;
        var buf: [256]u8 = undefined;
        const written = if (tok.type == .eof)
            "Unexpected end of input."
        else
            std.fmt.bufPrint(&buf, "Unexpected token '{s}'.", .{
                self.source[tok.offset .. tok.offset + tok.len],
            }) catch "Syntax error.";
        // Persist the message in the arena so it outlives `buf`.
        const msg = self.arenaAllocator().dupe(u8, written) catch "Syntax error.";
        self.report(tok, msg);
    }

    // ---- semantic actions ----

    fn runAction(self: *Parser, act: Act, rhs: []Value) !Value {
        const a = self.arenaAllocator();
        switch (act) {
            .augmented => unreachable,
            .pass => return rhs[0],

            // ---- Expr (function level) ----
            .lambda_id => {
                const name = rhs[0].tok;
                return .{ .node = try self.arena.createNode(.lambda, .{ .lambda = .{
                    .param_offset = name.offset,
                    .param_len = name.len,
                    .body = rhs[2].node,
                } }) };
            },
            .lambda_no_bind => return self.buildLambda(rhs[0].brace, null, rhs[2].node),
            .lambda_bind_before => {
                const bind = rhs[0].tok;
                return self.buildLambda(rhs[2].brace, .{ .offset = bind.offset, .len = bind.len }, rhs[4].node);
            },
            .lambda_bind_after => {
                const bind = rhs[2].tok;
                return self.buildLambda(rhs[0].brace, .{ .offset = bind.offset, .len = bind.len }, rhs[4].node);
            },
            .assert_ => return .{ .node = try self.arena.createNode(.assert, .{ .assert = .{
                .cond = rhs[1].node,
                .body = rhs[3].node,
            } }) },
            .with_ => return .{ .node = try self.arena.createNode(.with_expr, .{ .with_expr = .{
                .attr_set = rhs[1].node,
                .body = rhs[3].node,
            } }) },
            .let_in => {
                var entries = rhs[1].entries;
                const bindings = try a.alloc(Node.Binding, entries.items.len);
                for (entries.items, bindings) |entry, *b| {
                    if (entry.path.len == 0) {
                        self.report(rhs[2].tok, "Dynamic attributes are not allowed in let bindings.");
                        return error.ParseError;
                    }
                    b.* = .{
                        .name_offset = entry.path[0].offset,
                        .name_len = entry.path[0].len,
                        .path = entry.path,
                        .expr = entry.expr,
                        .inherit_outer = entry.inherit_outer,
                    };
                }
                entries.deinit(a);
                return .{ .node = try self.arena.createNode(.let_in, .{ .let_in = .{
                    .bindings = bindings,
                    .body = rhs[3].node,
                } }) };
            },

            // ---- ExprIf ----
            .if_else => return .{ .node = try self.arena.createNode(.if_else, .{ .if_else = .{
                .cond = rhs[1].node,
                .then_branch = rhs[3].node,
                .else_branch = rhs[5].node,
            } }) },

            // ---- binary operators ----
            .bin_impl => return self.binary(.impl, rhs),
            .bin_or => return self.binary(.or_, rhs),
            .bin_and => return self.binary(.and_, rhs),
            .bin_eq => return self.binary(.eq, rhs),
            .bin_neq => return self.binary(.neq, rhs),
            .bin_lt => return self.binary(.lt, rhs),
            .bin_lte => return self.binary(.lte, rhs),
            .bin_gt => return self.binary(.gt, rhs),
            .bin_gte => return self.binary(.gte, rhs),
            .bin_update => return self.binary(.update, rhs),
            .bin_add => return self.binary(.add, rhs),
            .bin_sub => return self.binary(.sub, rhs),
            .bin_mul => return self.binary(.mul, rhs),
            .bin_div => return self.binary(.div, rhs),
            .bin_concat => return self.binary(.concat, rhs),
            .has_attr => return self.makeHasAttr(rhs[0].node, rhs[2].segs),
            .pipe_fwd => {
                self.notePipe(rhs[1].tok);
                return .{ .node = try self.arena.createNode(.apply, .{ .apply = .{
                    .func = rhs[2].node,
                    .arg = rhs[0].node,
                    .pipe = .forward,
                } }) };
            },
            .pipe_bwd => {
                self.notePipe(rhs[1].tok);
                return .{ .node = try self.arena.createNode(.apply, .{ .apply = .{
                    .func = rhs[0].node,
                    .arg = rhs[2].node,
                    .pipe = .backward,
                } }) };
            },
            .not => return .{ .node = try self.arena.createNode(.unary_op, .{ .unary = .{
                .op = .not,
                .expr = rhs[1].node,
            } }) },
            .negate => return .{ .node = try self.arena.createNode(.unary_op, .{ .unary = .{
                .op = .negate,
                .expr = rhs[1].node,
            } }) },

            // ---- application ----
            .apply => return .{ .node = try self.arena.createNode(.apply, .{ .apply = .{
                .func = rhs[0].node,
                .arg = rhs[1].node,
                .pipe = .none,
            } }) },

            // ---- selection ----
            .select => return .{ .node = try self.buildSelect(rhs[0].node, rhs[2].segs) },
            .select_or => {
                const selected = try self.buildSelect(rhs[0].node, rhs[2].segs);
                return .{ .node = try self.arena.createNode(.attr_or, .{ .attr_or = .{
                    .attr_path = selected,
                    .default = rhs[4].node,
                } }) };
            },

            // ---- atoms ----
            .ident => return self.atom(.identifier, rhs[0].tok),
            .integer => return self.atom(.integer, rhs[0].tok),
            .float_val => return self.atom(.float_val, rhs[0].tok),
            .string => return self.atom(.string, rhs[0].tok),
            .path => return self.atom(.path, rhs[0].tok),
            .search_path => return self.atom(.search_path, rhs[0].tok),
            .bool_true => return .{ .node = try self.arena.createNode(.bool_true, .{ .atom = .{ .offset = 0, .len = 0 } }) },
            .bool_false => return .{ .node = try self.arena.createNode(.bool_false, .{ .atom = .{ .offset = 0, .len = 0 } }) },
            .null_lit => return .{ .node = try self.arena.createNode(.null, .{ .atom = .{ .offset = 0, .len = 0 } }) },
            .parens => return .{ .node = try self.arena.createNode(.parens, .{ .parens = rhs[1].node }) },
            .attrset_from_brace => return self.buildAttrSet(rhs[0].brace),
            .rec_attr_set => {
                var entries = rhs[2].entries;
                return .{ .node = try self.arena.createNode(.attr_set, .{ .attr_set = .{
                    .entries = try entries.toOwnedSlice(a),
                    .recursive = true,
                } }) };
            },
            .list => {
                var nodes = rhs[1].nodes;
                return .{ .node = try self.arena.createNode(.list, .{ .list = .{
                    .items = try nodes.toOwnedSlice(a),
                } }) };
            },

            // ---- attrpath / attr ----
            .attrpath_one => {
                var segs: SegAccum = .{};
                try segs.push(a, rhs[0].seg);
                return .{ .segs = segs };
            },
            .attrpath_append => {
                var segs = rhs[0].segs;
                try segs.push(a, rhs[2].seg);
                return .{ .segs = segs };
            },
            .attr_static => return .{ .seg = .{ .static = .{ .offset = rhs[0].tok.offset, .len = rhs[0].tok.len } } },
            .attr_dynamic => return .{ .seg = .{ .dynamic = rhs[1].node } },

            // ---- brace / clauses (unified attrset-or-pattern body) ----
            .brace_group => return .{ .brace = .{ .clauses = rhs[1].clauses, .lbrace = rhs[0].tok } },
            .brace_empty => return .{ .clauses = .empty },
            .bc_final => {
                var list: std.ArrayListUnmanaged(Clause) = .empty;
                try list.append(a, rhs[0].clause);
                return .{ .clauses = list };
            },
            .bc_terms_final => {
                var list = rhs[0].clauses;
                try list.append(a, rhs[1].clause);
                return .{ .clauses = list };
            },
            .term_clauses_one => {
                var list: std.ArrayListUnmanaged(Clause) = .empty;
                try list.append(a, rhs[0].clause);
                return .{ .clauses = list };
            },
            .term_clauses_append => {
                var list = rhs[0].clauses;
                try list.append(a, rhs[1].clause);
                return .{ .clauses = list };
            },
            .tclause_formal_comma => return .{ .clause = .{ .formal = .{
                .name = .{ .offset = rhs[0].tok.offset, .len = rhs[0].tok.len },
                .default = null,
            } } },
            .tclause_formal_default_comma => return .{ .clause = .{ .formal = .{
                .name = .{ .offset = rhs[0].tok.offset, .len = rhs[0].tok.len },
                .default = rhs[2].node,
            } } },
            .tclause_bind => {
                const segs = rhs[0].segs;
                const entry = try self.foldBind(segs.items(), rhs[2].node);
                return .{ .clause = .{ .bind = entry } };
            },
            .tclause_inherit => return .{ .clause = .{ .inherit = try self.inheritEntries(null, rhs[1].names, rhs[0].tok) } },
            .tclause_inherit_from => return .{ .clause = .{ .inherit = try self.inheritEntries(rhs[2].node, rhs[4].names, rhs[0].tok) } },
            .fclause_formal => return .{ .clause = .{ .formal = .{
                .name = .{ .offset = rhs[0].tok.offset, .len = rhs[0].tok.len },
                .default = null,
            } } },
            .fclause_formal_default => return .{ .clause = .{ .formal = .{
                .name = .{ .offset = rhs[0].tok.offset, .len = rhs[0].tok.len },
                .default = rhs[2].node,
            } } },
            .fclause_ellipsis => return .{ .clause = .ellipsis },

            // ---- binds ----
            .binds_empty => return .{ .entries = .empty },
            .binds_append => {
                var acc = rhs[0].entries;
                var add = rhs[1].entries;
                try acc.appendSlice(a, add.items);
                add.deinit(a);
                return .{ .entries = acc };
            },
            .bind_normal => {
                const segs = rhs[0].segs;
                const entry = try self.foldBind(segs.items(), rhs[2].node);
                var list: std.ArrayListUnmanaged(Node.AttrSetEntry) = .empty;
                try list.append(a, entry);
                return .{ .entries = list };
            },
            .bind_inherit => {
                var list: std.ArrayListUnmanaged(Node.AttrSetEntry) = .empty;
                try list.appendSlice(a, try self.inheritEntries(null, rhs[1].names, rhs[0].tok));
                return .{ .entries = list };
            },
            .bind_inherit_from => {
                var list: std.ArrayListUnmanaged(Node.AttrSetEntry) = .empty;
                try list.appendSlice(a, try self.inheritEntries(rhs[2].node, rhs[4].names, rhs[0].tok));
                return .{ .entries = list };
            },
            .inherit_names_empty => return .{ .names = .empty },
            .inherit_names_append => {
                var names = rhs[0].names;
                try names.append(a, .{ .offset = rhs[1].tok.offset, .len = rhs[1].tok.len });
                return .{ .names = names };
            },

            // ---- list ----
            .list_items_empty => return .{ .nodes = .empty },
            .list_items_append => {
                var nodes = rhs[0].nodes;
                try nodes.append(a, rhs[1].node);
                return .{ .nodes = nodes };
            },
        }
    }

    // ---- action helpers ----

    fn atom(self: *Parser, tag: NodeTag, tok: Token) !Value {
        return .{ .node = try self.arena.createNode(tag, .{ .atom = .{ .offset = tok.offset, .len = tok.len } }) };
    }

    fn binary(self: *Parser, op: ast.BinaryOp, rhs: []Value) !Value {
        return .{ .node = try self.arena.createNode(.binary_op, .{ .binary = .{
            .op = op,
            .left = rhs[0].node,
            .right = rhs[2].node,
        } }) };
    }

    /// Validate a `{ ... }` group as a lambda pattern and build the node. The
    /// grammar already guarantees formal ordering (commas between formals,
    /// `...` last), so this only rejects bind/inherit clauses.
    fn buildLambda(self: *Parser, brace: Brace, bind_name: ?Node.Atom, body: *Node) !Value {
        const a = self.arenaAllocator();
        var clauses = brace.clauses;
        defer clauses.deinit(a);
        var params: std.ArrayListUnmanaged(Node.LambdaAttrParam) = .empty;
        var allow_extra = false;
        for (clauses.items) |clause| {
            switch (clause) {
                .formal => |p| try params.append(a, p),
                .ellipsis => allow_extra = true,
                .bind, .inherit => {
                    self.report(brace.lbrace, "Function argument pattern cannot contain attribute assignments.");
                    return error.ParseError;
                },
            }
        }
        const la = try a.create(Node.LambdaAttrs);
        la.* = .{
            .bind_name = bind_name,
            .params = try params.toOwnedSlice(a),
            .allow_extra = allow_extra,
            .body = body,
        };
        return .{ .node = try self.arena.createNode(.lambda_attrs, .{ .lambda_attrs = la }) };
    }

    /// Validate a `{ ... }` group as an attribute set and build the node.
    fn buildAttrSet(self: *Parser, brace: Brace) !Value {
        const a = self.arenaAllocator();
        var clauses = brace.clauses;
        defer clauses.deinit(a);
        var entries: std.ArrayListUnmanaged(Node.AttrSetEntry) = .empty;
        for (clauses.items) |clause| {
            switch (clause) {
                .bind => |e| try entries.append(a, e),
                .inherit => |es| try entries.appendSlice(a, es),
                .formal, .ellipsis => {
                    self.report(brace.lbrace, "Expected '=' after attribute name.");
                    return error.ParseError;
                },
            }
        }
        return .{ .node = try self.arena.createNode(.attr_set, .{ .attr_set = .{
            .entries = try entries.toOwnedSlice(a),
            .recursive = false,
        } }) };
    }

    /// `root.a.b.${x}.c` — replicate dot-access folding: runs of static names
    /// become an `attr_path`; each dynamic segment wraps in an `attr_dynamic`.
    fn buildSelect(self: *Parser, root: *Node, segs: SegAccum) !*Node {
        const a = self.arenaAllocator();
        var current = root;
        var pending: std.ArrayListUnmanaged(Node.Atom) = .empty;
        for (segs.items()) |seg| {
            switch (seg) {
                .static => |atomv| try pending.append(a, atomv),
                .dynamic => |name| {
                    if (pending.items.len > 0) {
                        current = try self.arena.createNode(.attr_path, .{ .attr_path = .{
                            .root = current,
                            .segments = try pending.toOwnedSlice(a),
                        } });
                        pending = .empty;
                    }
                    current = try self.arena.createNode(.attr_dynamic, .{ .attr_dynamic = .{
                        .root = current,
                        .name = name,
                    } });
                },
            }
        }
        if (pending.items.len > 0) {
            current = try self.arena.createNode(.attr_path, .{ .attr_path = .{
                .root = current,
                .segments = try pending.toOwnedSlice(a),
            } });
        }
        return current;
    }

    fn makeHasAttr(self: *Parser, root: *Node, segs: SegAccum) !Value {
        const a = self.arenaAllocator();
        const seg_items = segs.items();
        var has_dynamic = false;
        for (seg_items) |seg| {
            if (seg == .dynamic) has_dynamic = true;
        }
        if (has_dynamic) {
            const mixed = try a.alloc(Node.HasAttrMixedSegment, seg_items.len);
            for (seg_items, mixed) |seg, *m| {
                m.* = switch (seg) {
                    .static => |atomv| .{ .static = atomv },
                    .dynamic => |name| .{ .dynamic = name },
                };
            }
            return .{ .node = try self.arena.createNode(.has_attr_mixed, .{ .has_attr_mixed = .{
                .root = root,
                .segments = mixed,
            } }) };
        }
        const statics = try a.alloc(Node.Atom, seg_items.len);
        for (seg_items, statics) |seg, *s| s.* = seg.static;
        return .{ .node = try self.arena.createNode(.has_attr, .{ .has_attr = .{
            .root = root,
            .segments = statics,
        } }) };
    }

    /// Lower a bind `attrpath = expr` into a single `AttrSetEntry`, nesting any
    /// dynamic segments after a static prefix into wrapper attribute sets — the
    /// same shape the recursive-descent parser produced.
    fn foldBind(self: *Parser, segs: []const Seg, expr: *Node) anyerror!Node.AttrSetEntry {
        const a = self.arenaAllocator();
        if (segs[0] == .dynamic) {
            const inner = if (segs.len == 1) expr else try self.nestChain(segs[1..], expr);
            return .{ .path = &.{}, .dynamic_name = segs[0].dynamic, .expr = inner };
        }
        // leading static run
        var k: usize = 0;
        while (k < segs.len and segs[k] == .static) : (k += 1) {}
        const prefix = try a.alloc(Node.Atom, k);
        for (segs[0..k], prefix) |seg, *dst| dst.* = seg.static;
        if (k == segs.len) {
            return .{ .path = prefix, .dynamic_name = null, .expr = expr };
        }
        return .{ .path = prefix, .dynamic_name = null, .expr = try self.nestChain(segs[k..], expr) };
    }

    fn nestChain(self: *Parser, segs: []const Seg, expr: *Node) anyerror!*Node {
        const a = self.arenaAllocator();
        const entry = try self.foldBind(segs, expr);
        const entries = try a.alloc(Node.AttrSetEntry, 1);
        entries[0] = entry;
        return self.arena.createNode(.attr_set, .{ .attr_set = .{
            .entries = entries,
            .recursive = false,
        } });
    }

    /// Build the attribute-set entries for one `inherit ...;` clause (shared by
    /// `let`/`rec` bindings and by attribute-set braces).
    fn inheritEntries(self: *Parser, source: ?*Node, names_in: std.ArrayListUnmanaged(Node.Atom), inherit_tok: Token) ![]Node.AttrSetEntry {
        var names = names_in;
        defer names.deinit(self.arenaAllocator());
        if (names.items.len == 0) {
            // `inherit ;` / `inherit (src) ;` — nothing named.
            self.report(inherit_tok, "Expected inherited variable name.");
            return error.ParseError;
        }
        const a = self.arenaAllocator();
        const entries = try a.alloc(Node.AttrSetEntry, names.items.len);
        for (names.items, entries) |name, *entry| {
            const path = try a.alloc(Node.Atom, 1);
            path[0] = name;
            const expr: *Node = if (source) |src|
                try self.inheritSourceAttr(src, name)
            else
                try self.arena.createNode(.identifier, .{ .atom = name });
            entry.* = .{
                .path = path,
                .expr = expr,
                .inherit_outer = source == null,
            };
        }
        return entries;
    }

    fn inheritSourceAttr(self: *Parser, source: *Node, name: Node.Atom) !*Node {
        const segments = try self.arenaAllocator().alloc(Node.Atom, 1);
        segments[0] = name;
        return self.arena.createNode(.attr_path, .{ .attr_path = .{
            .root = try ast.cloneNode(self.arena, source),
            .segments = segments,
        } });
    }
};

test {
    _ = @import("parser/tests.zig");
    _ = grammar;
    _ = lr;
}
