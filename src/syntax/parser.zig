//! Table-driven LALR(1) parser.
//!
//! The grammar and its ACTION/GOTO tables are generated at compile time
//! (`grammar.zig` → `lr.zig`). This file is the runtime: a tight shift/reduce
//! loop over the flat tables, plus the semantic actions that build the AST.
//!
//! Pipeline: source → scanner → token array. A single O(n) brace-matching pass
//! retags a lambda pattern's opening `{` to the synthetic `pattern_lbrace`
//! terminal (the one context-sensitive decision Nix's grammar needs). Then the
//! driver consumes the token/terminal arrays, maintaining a state stack and a
//! parallel semantic-value stack; each reduce runs one action to fold children
//! into an AST node. Nodes live in the caller's arena, exactly as before.

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

const Tab = grammar.Tables;
const Act = grammar.Act;

/// One attribute-path segment: a static name or a dynamic `${expr}`.
const Seg = union(enum) {
    static: Node.Atom,
    dynamic: *Node,
};

/// Accumulated lambda formals: `{ a, b ? d, ... }`.
const Formals = struct {
    params: std.ArrayListUnmanaged(Node.LambdaAttrParam) = .empty,
    allow_extra: bool = false,
};

/// A semantic value on the parse stack. Which variant is live is determined by
/// the grammar symbol, so reads are unchecked in spirit — the tagged union just
/// keeps development honest.
const Value = union(enum) {
    tok: Token,
    node: *Node,
    seg: Seg,
    segs: std.ArrayListUnmanaged(Seg),
    entries: std.ArrayListUnmanaged(Node.AttrSetEntry),
    names: std.ArrayListUnmanaged(Node.Atom),
    nodes: std.ArrayListUnmanaged(*Node),
    formals: Formals,
    formal: Node.LambdaAttrParam,
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

    fn report(self: *Parser, tok: Token, msg: []const u8) void {
        self.had_error = true;
        self.diagnostics.append(self.allocator, .{
            .line = tok.line,
            .column = diagnostic.columnForOffset(self.source, tok.offset),
            .offset = tok.offset,
            .len = tok.len,
            .token_type = tok.type,
            .message = msg,
        }) catch {};
    }

    // ---- entry point ----

    pub fn parse(self: *Parser) !*Node {
        const gpa = self.allocator;

        var toks: std.ArrayListUnmanaged(Token) = .empty;
        defer toks.deinit(gpa);
        var ids: std.ArrayListUnmanaged(u32) = .empty;
        defer ids.deinit(gpa);

        var scanner = Scanner.init(self.source);
        while (true) {
            const tk = scanner.next();
            if (tk.type == .error_token) {
                self.report(tk, "Invalid token.");
                continue;
            }
            try toks.append(gpa, tk);
            try ids.append(gpa, @intFromEnum(tk.type));
            if (tk.type == .eof) break;
        }

        retagPatterns(toks.items, ids.items);

        const root = try self.drive(toks.items, ids.items);

        if (self.had_error) return error.ParseError;
        return root orelse error.ParseError;
    }

    /// Retag the opening brace of every lambda pattern to `pattern_lbrace`.
    /// A `{` starts a pattern (rather than an attribute set) exactly when its
    /// matching `}` is immediately followed by `:` or `@`, and it is not the
    /// brace of a `rec { ... }`. One linear pass with a bracket stack.
    fn retagPatterns(toks: []Token, ids: []u32) void {
        var stack: [512]usize = undefined; // indices of open brackets
        var sp: usize = 0;
        var overflow = false;
        for (toks, 0..) |tk, i| {
            switch (tk.type) {
                .left_brace, .left_bracket, .left_paren, .dollar_curly => {
                    if (sp < stack.len) {
                        stack[sp] = i;
                        sp += 1;
                    } else overflow = true;
                },
                .right_brace, .right_bracket, .right_paren => {
                    if (sp == 0) continue;
                    sp -= 1;
                    const open_i = stack[sp];
                    if (overflow) continue;
                    if (toks[open_i].type != .left_brace) continue;
                    // not a `rec {`
                    if (open_i > 0 and toks[open_i - 1].type == .kw_rec) continue;
                    const next = if (i + 1 < toks.len) toks[i + 1].type else TokenType.eof;
                    if (next == .colon or next == .at) {
                        ids[open_i] = grammar.t_pattern_lbrace;
                    }
                },
                else => {},
            }
        }
    }

    // ---- the shift/reduce driver ----

    fn drive(self: *Parser, toks: []const Token, ids: []const u32) !?*Node {
        const gpa = self.allocator;
        const cap = toks.len + 16;
        const states = try gpa.alloc(u32, cap);
        defer gpa.free(states);
        const vals = try gpa.alloc(Value, cap);
        defer gpa.free(vals);

        var sp: usize = 0; // number of entries on the stack
        states[sp] = Tab.start_state;
        vals[sp] = .nil;
        sp += 1;

        var ip: usize = 0;
        while (true) {
            const state = states[sp - 1];
            const la = ids[ip];
            const c = Tab.action[state * Tab.num_terminals + la];
            switch (lr.cellKind(c)) {
                lr.ACT_SHIFT => {
                    states[sp] = lr.cellArg(c);
                    vals[sp] = .{ .tok = toks[ip] };
                    sp += 1;
                    ip += 1;
                },
                lr.ACT_REDUCE => {
                    const p = lr.cellArg(c);
                    const n = Tab.prod_rhs_len[p];
                    const base = sp - n;
                    const result = try self.runAction(grammar.act_of_prod[p], vals[base .. base + n]);
                    sp = base;
                    const lhs = Tab.prod_lhs[p];
                    const g = Tab.goto_table[states[sp - 1] * Tab.num_nonterminals + lhs];
                    if (g < 0) {
                        self.report(toks[ip], "Internal parser error (no goto).");
                        return null;
                    }
                    states[sp] = @intCast(g);
                    vals[sp] = result;
                    sp += 1;
                },
                lr.ACT_ACCEPT => {
                    return vals[sp - 1].node;
                },
                else => {
                    self.reportUnexpected(state, toks[ip]);
                    return null;
                },
            }
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
            .lambda_no_bind => return self.makeLambdaAttrs(null, rhs[1].formals, rhs[4].node),
            .lambda_bind_before => {
                const bind = rhs[0].tok;
                return self.makeLambdaAttrs(.{ .offset = bind.offset, .len = bind.len }, rhs[3].formals, rhs[6].node);
            },
            .lambda_bind_after => {
                const bind = rhs[4].tok;
                return self.makeLambdaAttrs(.{ .offset = bind.offset, .len = bind.len }, rhs[1].formals, rhs[6].node);
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
            .attr_set => {
                var entries = rhs[1].entries;
                return .{ .node = try self.arena.createNode(.attr_set, .{ .attr_set = .{
                    .entries = try entries.toOwnedSlice(a),
                    .recursive = false,
                } }) };
            },
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
                var segs: std.ArrayListUnmanaged(Seg) = .empty;
                try segs.append(a, rhs[0].seg);
                return .{ .segs = segs };
            },
            .attrpath_append => {
                var segs = rhs[0].segs;
                try segs.append(a, rhs[2].seg);
                return .{ .segs = segs };
            },
            .attr_static => return .{ .seg = .{ .static = .{ .offset = rhs[0].tok.offset, .len = rhs[0].tok.len } } },
            .attr_dynamic => return .{ .seg = .{ .dynamic = rhs[1].node } },

            // ---- formals ----
            .formals_empty => return .{ .formals = .{} },
            .formals_ellipsis => return .{ .formals = .{ .allow_extra = true } },
            .formals_list => return rhs[0],
            .formals_list_comma => return rhs[0],
            .formals_list_ellipsis => {
                var f = rhs[0].formals;
                f.allow_extra = true;
                return .{ .formals = f };
            },
            .formal_list_one => {
                var f: Formals = .{};
                try f.params.append(a, rhs[0].formal);
                return .{ .formals = f };
            },
            .formal_list_append => {
                var f = rhs[0].formals;
                try f.params.append(a, rhs[2].formal);
                return .{ .formals = f };
            },
            .formal_plain => return .{ .formal = .{
                .name = .{ .offset = rhs[0].tok.offset, .len = rhs[0].tok.len },
                .default = null,
            } },
            .formal_default => return .{ .formal = .{
                .name = .{ .offset = rhs[0].tok.offset, .len = rhs[0].tok.len },
                .default = rhs[2].node,
            } },

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
                var segs = rhs[0].segs;
                const entry = try self.foldBind(segs.items, rhs[2].node);
                segs.deinit(a);
                var list: std.ArrayListUnmanaged(Node.AttrSetEntry) = .empty;
                try list.append(a, entry);
                return .{ .entries = list };
            },
            .bind_inherit => return self.makeInherit(null, rhs[1].names, rhs[0].tok),
            .bind_inherit_from => return self.makeInherit(rhs[2].node, rhs[4].names, rhs[0].tok),
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

    fn makeLambdaAttrs(self: *Parser, bind_name: ?Node.Atom, formals_in: Formals, body: *Node) !Value {
        var formals = formals_in;
        return .{ .node = try self.arena.createNode(.lambda_attrs, .{ .lambda_attrs = .{
            .bind_name = bind_name,
            .params = try formals.params.toOwnedSlice(self.arenaAllocator()),
            .allow_extra = formals.allow_extra,
            .body = body,
        } }) };
    }

    /// `root.a.b.${x}.c` — replicate dot-access folding: runs of static names
    /// become an `attr_path`; each dynamic segment wraps in an `attr_dynamic`.
    fn buildSelect(self: *Parser, root: *Node, segs: std.ArrayListUnmanaged(Seg)) !*Node {
        var mutable = segs;
        defer mutable.deinit(self.arenaAllocator());
        const a = self.arenaAllocator();
        var current = root;
        var pending: std.ArrayListUnmanaged(Node.Atom) = .empty;
        for (mutable.items) |seg| {
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

    fn makeHasAttr(self: *Parser, root: *Node, segs_in: std.ArrayListUnmanaged(Seg)) !Value {
        var segs = segs_in;
        defer segs.deinit(self.arenaAllocator());
        const a = self.arenaAllocator();
        var has_dynamic = false;
        for (segs.items) |seg| {
            if (seg == .dynamic) has_dynamic = true;
        }
        if (has_dynamic) {
            const mixed = try a.alloc(Node.HasAttrMixedSegment, segs.items.len);
            for (segs.items, mixed) |seg, *m| {
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
        const statics = try a.alloc(Node.Atom, segs.items.len);
        for (segs.items, statics) |seg, *s| s.* = seg.static;
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

    fn makeInherit(self: *Parser, source: ?*Node, names_in: std.ArrayListUnmanaged(Node.Atom), inherit_tok: Token) !Value {
        var names = names_in;
        defer names.deinit(self.arenaAllocator());
        if (names.items.len == 0) {
            // `inherit ;` / `inherit (src) ;` — nothing named.
            self.report(inherit_tok, "Expected inherited variable name.");
            return error.ParseError;
        }
        const a = self.arenaAllocator();
        var entries: std.ArrayListUnmanaged(Node.AttrSetEntry) = .empty;
        for (names.items) |name| {
            const path = try a.alloc(Node.Atom, 1);
            path[0] = name;
            const expr: *Node = if (source) |src|
                try self.inheritSourceAttr(src, name)
            else
                try self.arena.createNode(.identifier, .{ .atom = name });
            try entries.append(a, .{
                .path = path,
                .expr = expr,
                .inherit_outer = source == null,
            });
        }
        return .{ .entries = entries };
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
