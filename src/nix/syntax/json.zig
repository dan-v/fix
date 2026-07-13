//! AST → JSON serializer matching Lix's `nix-instantiate --parse` schema.
//!
//! fix keeps a lean, raw AST (operators un-desugared, attr paths un-merged,
//! curried applies nested). Nix's `--parse` JSON is the *lowered* tree: `+`
//! becomes `ExprConcatStrings`, `-`/`*`/`/`/`<`/`>` become primop calls,
//! static attr paths are nested and merged, curried applies are flattened, and
//! so on. This module performs those transforms while walking the AST and emits
//! the JSON directly.
//!
//! Output format mirrors nlohmann's `dump(2)`: 2-space indent, object keys
//! sorted lexicographically with `_type` pinned first, empty collection fields
//! omitted. There are no source positions anywhere.
//!
//! Scope is parse-OKAY only: this assumes a well-formed tree from `Parser`.

const std = @import("std");
const ast = @import("ast.zig");
const Node = ast.Node;
const string_syntax = @import("string_syntax.zig");
const parser_mod = @import("parser.zig");

/// A minimal JSON value model. Built in an arena, then emitted. Keeping an
/// explicit tree (rather than streaming) lets us sort object keys and omit
/// empty fields uniformly.
pub const J = union(enum) {
    int: i64,
    /// A float, emitted with a forced decimal point (Nix/nlohmann style).
    float: f64,
    str: []const u8,
    boolean: bool,
    nul,
    array: []const J,
    object: []const Field,

    pub const Field = struct { key: []const u8, val: J };
};

/// Serialize `node` (a parse-OKAY AST rooted in `source`) as JSON to `writer`.
/// `gpa` backs a scratch arena for the JSON tree, decoded strings, and the
/// sub-parsers used for string interpolations.
pub fn write(
    writer: *std.Io.Writer,
    gpa: std.mem.Allocator,
    source: []const u8,
    node: *const Node,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var ser: Ser = .{ .arena = arena_state.allocator(), .gpa = gpa, .source = source };
    const j = try ser.node(node);
    try emit(writer, j, 0);
    try writer.writeByte('\n');
}

const Ser = struct {
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    source: []const u8,

    // ---- dispatch ----

    fn node(self: *Ser, n_in: *const Node) anyerror!J {
        const n = ast.unwrapParens(n_in);
        return switch (n.tag) {
            .integer => self.literal("Int", .{ .int = try self.parseInt(n.data.atom) }),
            .float_val => self.literal("Float", .{ .float = try self.parseFloat(n.data.atom) }),
            .string => try self.stringNode(n.data.atom),
            .path => self.literal("Path", .{ .str = self.atomText(n.data.atom) }),
            // URL literals are ordinary strings in Nix.
            .uri => self.literal("String", .{ .str = self.atomText(n.data.atom) }),
            .search_path => self.searchPath(n.data.atom),
            .identifier => self.identifier(self.atomText(n.data.atom)),
            .bool_true => self.exprVar("true"),
            .bool_false => self.exprVar("false"),
            .null => self.exprVar("null"),

            .unary_op => try self.unary(n.data.unary),
            .binary_op => try self.binary(n.data.binary),
            .apply => try self.call(n),

            .lambda => self.obj(&.{
                .{ .key = "_type", .val = .{ .str = "ExprLambda" } },
                .{ .key = "arg", .val = .{ .str = self.atomText(.{ .offset = n.data.lambda.param_offset, .len = n.data.lambda.param_len }) } },
                .{ .key = "body", .val = try self.node(n.data.lambda.body) },
            }),
            .lambda_attrs => try self.lambdaAttrs(n.data.lambda_attrs),

            .let_in => try self.letIn(n.data.let_in),
            .if_else => self.obj(&.{
                .{ .key = "_type", .val = .{ .str = "ExprIf" } },
                .{ .key = "cond", .val = try self.node(n.data.if_else.cond) },
                .{ .key = "then", .val = try self.node(n.data.if_else.then_branch) },
                .{ .key = "else", .val = try self.node(n.data.if_else.else_branch) },
            }),
            .assert => self.obj(&.{
                .{ .key = "_type", .val = .{ .str = "ExprAssert" } },
                .{ .key = "cond", .val = try self.node(n.data.assert.cond) },
                .{ .key = "body", .val = try self.node(n.data.assert.body) },
            }),
            .with_expr => self.obj(&.{
                .{ .key = "_type", .val = .{ .str = "ExprWith" } },
                .{ .key = "attrs", .val = try self.node(n.data.with_expr.attr_set) },
                .{ .key = "body", .val = try self.node(n.data.with_expr.body) },
            }),

            .attr_set => try self.attrSet(n),
            .attr_path, .attr_dynamic => try self.select(n, null),
            .attr_or => try self.select(n.data.attr_or.attr_path, n.data.attr_or.default),
            .has_attr => try self.hasAttr(n),
            .has_attr_mixed => try self.hasAttrMixed(n),
            .list => try self.list(n.data.list),

            .parens => unreachable, // unwrapped above
            .elided => return error.ElidedBody, // elision is left off; never reached
        };
    }

    // ---- atoms ----

    fn atomText(self: *Ser, atom: Node.Atom) []const u8 {
        return self.source[atom.offset .. atom.offset + atom.len];
    }

    fn parseInt(self: *Ser, atom: Node.Atom) !i64 {
        return std.fmt.parseInt(i64, self.atomText(atom), 10) catch error.InvalidInteger;
    }

    fn parseFloat(self: *Ser, atom: Node.Atom) !f64 {
        return std.fmt.parseFloat(f64, self.atomText(atom)) catch error.InvalidFloat;
    }

    fn literal(self: *Ser, value_type: []const u8, value: J) J {
        return self.obj(&.{
            .{ .key = "_type", .val = .{ .str = "ExprLiteral" } },
            .{ .key = "value", .val = value },
            .{ .key = "valueType", .val = .{ .str = value_type } },
        });
    }

    fn exprVar(self: *Ser, name: []const u8) J {
        return self.obj(&.{
            .{ .key = "_type", .val = .{ .str = "ExprVar" } },
            .{ .key = "value", .val = .{ .str = name } },
        });
    }

    fn identifier(self: *Ser, name: []const u8) J {
        // The magic `__curPos` identifier is Nix's `ExprPos`.
        if (std.mem.eql(u8, name, "__curPos")) {
            return self.obj(&.{.{ .key = "_type", .val = .{ .str = "ExprPos" } }});
        }
        return self.exprVar(name);
    }

    fn searchPath(self: *Ser, atom: Node.Atom) J {
        // `<x>` → __findFile __nixPath "x"
        const text = self.atomText(atom);
        const inner = if (text.len >= 2 and text[0] == '<' and text[text.len - 1] == '>')
            text[1 .. text.len - 1]
        else
            text;
        return self.obj(&.{
            .{ .key = "_type", .val = .{ .str = "ExprCall" } },
            .{ .key = "fun", .val = self.exprVar("__findFile") },
            .{ .key = "args", .val = self.arr(&.{
                self.exprVar("__nixPath"),
                self.literal("String", .{ .str = inner }),
            }) },
        });
    }

    // ---- strings ----

    /// A string atom. A single constant text run is an `ExprLiteral String`;
    /// any `${...}` makes it an interpolating `ExprConcatStrings`.
    fn stringNode(self: *Ser, atom: Node.Atom) !J {
        const parsed = string_syntax.parseLiteral(self.gpa, self.source, .{
            .start = atom.offset, .end = atom.offset + atom.len,
        }) catch return error.InvalidStringLiteral;
        defer parsed.deinit();

        var has_interp = false;
        for (parsed.parts) |part| {
            if (part == .interpolation) has_interp = true;
        }

        if (!has_interp) {
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            for (parsed.parts) |part| {
                switch (part) {
                    .text => |t| try buf.appendSlice(self.arena, t.bytes),
                    .interpolation => {},
                }
            }
            // Nix strings are NUL-terminated, so a `\0` truncates the value (the
            // `nul-bytes` feature only decides whether that is also an error).
            const bytes = buf.items;
            const end = std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len;
            return self.literal("String", .{ .str = try self.arena.dupe(u8, bytes[0..end]) });
        }

        var es: std.ArrayListUnmanaged(J) = .empty;
        for (parsed.parts) |part| {
            switch (part) {
                .text => |t| {
                    if (t.bytes.len == 0) continue; // drop empty text chunks
                    try es.append(self.arena, self.literal("String", .{ .str = try self.arena.dupe(u8, t.bytes) }));
                },
                .interpolation => |span| try es.append(self.arena, try self.interpolation(span)),
            }
        }
        return self.obj(&.{
            .{ .key = "_type", .val = .{ .str = "ExprConcatStrings" } },
            .{ .key = "es", .val = self.arr(try es.toOwnedSlice(self.arena)) },
            .{ .key = "isInterpolation", .val = .{ .boolean = true } },
        });
    }

    /// Parse and serialize one `${...}` interpolation. It's a standalone
    /// expression over the interpolation's source slice, so a fresh sub-parser
    /// runs there and a nested serializer walks the result (its own `source`).
    fn interpolation(self: *Ser, span: string_syntax.Span) !J {
        const sub = self.source[span.start..span.end];
        var arena = ast.AstArena.init(self.gpa);
        defer arena.deinit();
        var parser = parser_mod.Parser.init(self.gpa, &arena, sub);
        defer parser.deinit();
        const n = parser.parse() catch return error.InterpolationParseError;
        var sub_ser: Ser = .{ .arena = self.arena, .gpa = self.gpa, .source = sub };
        return sub_ser.node(n);
    }

    // ---- operators ----

    fn unary(self: *Ser, u: Node.Unary) !J {
        return switch (u.op) {
            .not => self.obj(&.{
                .{ .key = "_type", .val = .{ .str = "ExprOpNot" } },
                .{ .key = "e", .val = try self.node(u.expr) },
            }),
            // -x  →  __sub 0 x
            .negate => self.primopCall("__sub", &.{
                self.literal("Int", .{ .int = 0 }),
                try self.node(u.expr),
            }),
        };
    }

    fn binary(self: *Ser, b: Node.Binary) !J {
        const l = try self.node(b.left);
        const r = try self.node(b.right);
        return switch (b.op) {
            // `+` is string/path/int concat → ExprConcatStrings
            .add => self.concatStrings(&.{ l, r }, false),
            .sub => self.primopCall("__sub", &.{ l, r }),
            .mul => self.primopCall("__mul", &.{ l, r }),
            .div => self.primopCall("__div", &.{ l, r }),
            .lt => self.primopCall("__lessThan", &.{ l, r }),
            .gt => self.primopCall("__lessThan", &.{ r, l }), // a > b → __lessThan b a
            .lte => self.opNot(self.primopCall("__lessThan", &.{ r, l })), // a <= b → !(b < a)
            .gte => self.opNot(self.primopCall("__lessThan", &.{ l, r })), // a >= b → !(a < b)
            .eq => self.binOp("ExprOpEq", l, r),
            .neq => self.binOp("ExprOpNEq", l, r),
            .and_ => self.binOp("ExprOpAnd", l, r),
            .or_ => self.binOp("ExprOpOr", l, r),
            .impl => self.binOp("ExprOpImpl", l, r),
            .update => self.binOp("ExprOpUpdate", l, r),
            .concat => self.binOp("ExprOpConcatLists", l, r), // `++`
        };
    }

    fn binOp(self: *Ser, type_name: []const u8, e1: J, e2: J) J {
        return self.obj(&.{
            .{ .key = "_type", .val = .{ .str = type_name } },
            .{ .key = "e1", .val = e1 },
            .{ .key = "e2", .val = e2 },
        });
    }

    fn opNot(self: *Ser, e: J) J {
        return self.obj(&.{
            .{ .key = "_type", .val = .{ .str = "ExprOpNot" } },
            .{ .key = "e", .val = e },
        });
    }

    fn primopCall(self: *Ser, name: []const u8, args: []const J) J {
        return self.obj(&.{
            .{ .key = "_type", .val = .{ .str = "ExprCall" } },
            .{ .key = "fun", .val = self.exprVar(name) },
            .{ .key = "args", .val = self.arr(args) },
        });
    }

    fn concatStrings(self: *Ser, es: []const J, is_interp: bool) J {
        return self.obj(&.{
            .{ .key = "_type", .val = .{ .str = "ExprConcatStrings" } },
            .{ .key = "es", .val = self.arr(es) },
            .{ .key = "isInterpolation", .val = .{ .boolean = is_interp } },
        });
    }

    // ---- application (curried-apply flattening) ----

    fn call(self: *Ser, n: *const Node) !J {
        const app = n.data.apply;
        // A pipe application is a single call `func arg`; the spine is not
        // flattened across it.
        if (app.pipe != .none) {
            return self.obj(&.{
                .{ .key = "_type", .val = .{ .str = "ExprCall" } },
                .{ .key = "fun", .val = try self.node(app.func) },
                .{ .key = "args", .val = self.arr(&.{try self.node(app.arg)}) },
            });
        }
        // Flatten the left spine of plain applies: apply(apply(f,a),b) → f [a,b].
        var args_rev: std.ArrayListUnmanaged(*Node) = .empty;
        var cur = n;
        while (cur.tag == .apply and cur.data.apply.pipe == .none) {
            try args_rev.append(self.arena, cur.data.apply.arg);
            cur = ast.unwrapParens(cur.data.apply.func);
        }
        const args = try self.arena.alloc(J, args_rev.items.len);
        // args_rev holds outermost-arg-first; reverse into source order.
        for (args_rev.items, 0..) |arg_node, i| {
            args[args_rev.items.len - 1 - i] = try self.node(arg_node);
        }
        return self.obj(&.{
            .{ .key = "_type", .val = .{ .str = "ExprCall" } },
            .{ .key = "fun", .val = try self.node(cur) },
            .{ .key = "args", .val = .{ .array = args } },
        });
    }

    // ---- lambda patterns ----

    fn lambdaAttrs(self: *Ser, la: *const Node.LambdaAttrs) !J {
        var fields: std.ArrayListUnmanaged(J.Field) = .empty;
        try fields.append(self.arena, .{ .key = "_type", .val = .{ .str = "ExprLambda" } });
        if (la.bind_name) |bind| {
            try fields.append(self.arena, .{ .key = "arg", .val = .{ .str = self.atomText(bind) } });
        }
        try fields.append(self.arena, .{ .key = "body", .val = try self.node(la.body) });
        if (la.params.len != 0) {
            var formals: std.ArrayListUnmanaged(J.Field) = .empty;
            for (la.params) |p| {
                const dflt: J = if (p.default) |d| try self.node(d) else .nul;
                try formals.append(self.arena, .{ .key = self.attrNameText(p.name), .val = dflt });
            }
            try fields.append(self.arena, .{ .key = "formals", .val = .{ .object = try formals.toOwnedSlice(self.arena) } });
        }
        // Present iff a pattern lambda (always, here).
        try fields.append(self.arena, .{ .key = "formalsEllipsis", .val = .{ .boolean = la.allow_extra } });
        return .{ .object = try fields.toOwnedSlice(self.arena) };
    }

    // ---- selects / hasAttr ----

    /// Flatten a select chain (`attr_path`/`attr_dynamic` nesting) into a base
    /// expression `e` plus an ordered `attrs` list (static names as strings,
    /// dynamic keys as expressions).
    fn select(self: *Ser, chain: *const Node, default: ?*const Node) !J {
        var attrs: std.ArrayListUnmanaged(J) = .empty;
        const base = try self.collectSelect(chain, &attrs);
        var fields: std.ArrayListUnmanaged(J.Field) = .empty;
        try fields.append(self.arena, .{ .key = "_type", .val = .{ .str = "ExprSelect" } });
        try fields.append(self.arena, .{ .key = "attrs", .val = self.arr(try attrs.toOwnedSlice(self.arena)) });
        if (default) |d| try fields.append(self.arena, .{ .key = "default", .val = try self.node(d) });
        try fields.append(self.arena, .{ .key = "e", .val = try self.node(base) });
        return .{ .object = try fields.toOwnedSlice(self.arena) };
    }

    fn collectSelect(self: *Ser, n_in: *const Node, attrs: *std.ArrayListUnmanaged(J)) anyerror!*const Node {
        const n = ast.unwrapParens(n_in);
        switch (n.tag) {
            .attr_path => {
                const base = try self.collectSelect(n.data.attr_path.root, attrs);
                for (n.data.attr_path.segments) |seg| {
                    try attrs.append(self.arena, .{ .str = self.attrNameText(seg) });
                }
                return base;
            },
            .attr_dynamic => {
                const base = try self.collectSelect(n.data.attr_dynamic.root, attrs);
                try attrs.append(self.arena, try self.node(n.data.attr_dynamic.name));
                return base;
            },
            else => return n,
        }
    }

    fn hasAttr(self: *Ser, n: *const Node) !J {
        const ha = n.data.has_attr;
        const attrs = try self.arena.alloc(J, ha.segments.len);
        for (ha.segments, attrs) |seg, *out| out.* = .{ .str = self.attrNameText(seg) };
        return self.obj(&.{
            .{ .key = "_type", .val = .{ .str = "ExprOpHasAttr" } },
            .{ .key = "attrs", .val = .{ .array = attrs } },
            .{ .key = "e", .val = try self.node(ha.root) },
        });
    }

    fn hasAttrMixed(self: *Ser, n: *const Node) !J {
        const ha = n.data.has_attr_mixed;
        const attrs = try self.arena.alloc(J, ha.segments.len);
        for (ha.segments, attrs) |seg, *out| {
            out.* = switch (seg) {
                .static => |a| .{ .str = self.attrNameText(a) },
                .dynamic => |d| try self.node(d),
            };
        }
        return self.obj(&.{
            .{ .key = "_type", .val = .{ .str = "ExprOpHasAttr" } },
            .{ .key = "attrs", .val = .{ .array = attrs } },
            .{ .key = "e", .val = try self.node(ha.root) },
        });
    }

    fn list(self: *Ser, l: Node.List) !J {
        const elems = try self.arena.alloc(J, l.items.len);
        for (l.items, elems) |item, *out| out.* = try self.node(item);
        return self.obj(&.{
            .{ .key = "_type", .val = .{ .str = "ExprList" } },
            .{ .key = "elems", .val = .{ .array = elems } },
        });
    }

    // ---- attribute sets / let (nesting, merging, inherit regrouping) ----

    fn attrSet(self: *Ser, n: *const Node) !J {
        const set = try self.buildSet(n.data.attr_set);
        return self.emitSet(set, false, null);
    }

    fn letIn(self: *Ser, l: Node.LetIn) !J {
        const set = try self.arena.create(BSet);
        set.* = .{};
        for (l.bindings) |b| {
            try self.addBinding(set, b.path, null, b.expr, b.inherit_outer);
        }
        return self.emitSet(set, true, l.body);
    }

    fn buildSet(self: *Ser, s: Node.AttrSet) anyerror!*BSet {
        const set = try self.arena.create(BSet);
        set.* = .{ .recursive = s.recursive };
        for (s.entries) |e| {
            try self.addBinding(set, e.path, e.dynamic_name, e.expr, e.inherit_outer);
        }
        return set;
    }

    /// Route one binding into the mutable `BSet`, performing constant-dynamic
    /// folding, static-path nesting/merging, and inherit / inherit-from
    /// regrouping.
    fn addBinding(
        self: *Ser,
        set: *BSet,
        path: []const Node.Atom,
        dynamic_name: ?*const Node,
        expr: *const Node,
        inherit_outer: bool,
    ) !void {
        // `inherit name;` — outer inherit.
        if (inherit_outer) {
            try set.inherits.append(self.arena, self.attrNameText(path[0]));
            return;
        }
        // `inherit (src) name;` — fix clones `src` per name as attr_path(src,
        // [name]) reusing the *same* name atom for the path and the segment, so
        // path[0] and segments[0] share a source offset. A genuine `a = b.a`
        // never does (its lhs and rhs names are distinct tokens).
        if (dynamic_name == null and path.len == 1) {
            const e = ast.unwrapParens(expr);
            if (e.tag == .attr_path and e.data.attr_path.segments.len == 1) {
                const seg = e.data.attr_path.segments[0];
                if (seg.offset == path[0].offset and seg.len == path[0].len) {
                    try self.addInheritFrom(set, e.data.attr_path.root, self.attrNameText(path[0]));
                    return;
                }
            }
        }

        // Descend the static path.
        var cur = set;
        if (dynamic_name) |dyn| {
            for (path) |seg| cur = try self.descend(cur, self.attrNameText(seg));
            // Constant-string dynamic key folds into a static attr.
            if (try self.constString(dyn)) |name| {
                try self.setLeaf(cur, name, expr);
            } else {
                try cur.dynamic.append(self.arena, .{ .name = dyn, .value = try self.buildValue(expr) });
            }
            return;
        }
        // Static path (len >= 1): descend all but the last, assign the last.
        var i: usize = 0;
        while (i + 1 < path.len) : (i += 1) cur = try self.descend(cur, self.attrNameText(path[i]));
        try self.setLeaf(cur, self.attrNameText(path[path.len - 1]), expr);
    }

    fn addInheritFrom(self: *Ser, set: *BSet, from: *const Node, name: []const u8) !void {
        const from_off: u32 = if (from.span) |s| s.offset else 0;
        if (set.inherit_from.items.len > 0) {
            const last = &set.inherit_from.items[set.inherit_from.items.len - 1];
            if (last.from_offset == from_off) {
                try last.names.append(self.arena, name);
                return;
            }
        }
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        try names.append(self.arena, name);
        try set.inherit_from.append(self.arena, .{ .from = from, .from_offset = from_off, .names = names });
    }

    /// Descend (creating/merging as needed) into the nested set at `name`.
    fn descend(self: *Ser, set: *BSet, name: []const u8) !*BSet {
        if (set.attrs.getPtr(name)) |slot| {
            switch (slot.*) {
                .set => |s| return s,
                // A non-set leaf here would be a duplicate-attribute conflict,
                // which Nix rejects (parse-fail, out of scope). Best-effort:
                // replace it with a fresh set so serialization proceeds.
                .leaf => {
                    const s = try self.arena.create(BSet);
                    s.* = .{};
                    slot.* = .{ .set = s };
                    return s;
                },
            }
        }
        const s = try self.arena.create(BSet);
        s.* = .{};
        try set.attrs.put(self.arena, name, .{ .set = s });
        return s;
    }

    /// Assign `expr` at `name`, merging when both the existing and new values
    /// are (non-recursive) attribute sets — Nix's recursive attr merge.
    fn setLeaf(self: *Ser, set: *BSet, name: []const u8, expr: *const Node) !void {
        const newv = try self.buildValue(expr);
        if (set.attrs.getPtr(name)) |slot| {
            if (slot.* == .set and newv == .set and !slot.set.recursive and !newv.set.recursive) {
                try self.mergeSets(slot.set, newv.set);
            } else {
                slot.* = newv; // duplicate non-mergeable → last wins (Nix errors)
            }
            return;
        }
        try set.attrs.put(self.arena, name, newv);
    }

    fn mergeSets(self: *Ser, dst: *BSet, src: *BSet) !void {
        var it = src.attrs.iterator();
        while (it.next()) |kv| {
            const name = kv.key_ptr.*;
            const val = kv.value_ptr.*;
            if (dst.attrs.getPtr(name)) |slot| {
                if (slot.* == .set and val == .set and !slot.set.recursive and !val.set.recursive) {
                    try self.mergeSets(slot.set, val.set);
                } else {
                    slot.* = val;
                }
            } else {
                try dst.attrs.put(self.arena, name, val);
            }
        }
        try dst.dynamic.appendSlice(self.arena, src.dynamic.items);
        try dst.inherits.appendSlice(self.arena, src.inherits.items);
        try dst.inherit_from.appendSlice(self.arena, src.inherit_from.items);
    }

    /// A value slot: a non-recursive attribute-set literal becomes a mutable
    /// `BSet` (so sibling binds can merge into it); everything else is a leaf
    /// serialized on demand.
    fn buildValue(self: *Ser, expr: *const Node) !BValue {
        const e = ast.unwrapParens(expr);
        if (e.tag == .attr_set) return .{ .set = try self.buildSet(e.data.attr_set) };
        return .{ .leaf = e };
    }

    fn emitSet(self: *Ser, set: *BSet, is_let: bool, body: ?*const Node) anyerror!J {
        var fields: std.ArrayListUnmanaged(J.Field) = .empty;
        try fields.append(self.arena, .{ .key = "_type", .val = .{ .str = if (is_let) "ExprLet" else "ExprSet" } });
        if (is_let) {
            try fields.append(self.arena, .{ .key = "body", .val = try self.node(body.?) });
        } else {
            try fields.append(self.arena, .{ .key = "recursive", .val = .{ .boolean = set.recursive } });
        }

        // attrs
        if (set.attrs.count() != 0) {
            var attr_fields: std.ArrayListUnmanaged(J.Field) = .empty;
            var it = set.attrs.iterator();
            while (it.next()) |kv| {
                try attr_fields.append(self.arena, .{ .key = kv.key_ptr.*, .val = try self.emitValue(kv.value_ptr.*) });
            }
            try fields.append(self.arena, .{ .key = "attrs", .val = .{ .object = try attr_fields.toOwnedSlice(self.arena) } });
        }
        // dynamicAttrs (never present for let)
        if (set.dynamic.items.len != 0) {
            const dyn = try self.arena.alloc(J, set.dynamic.items.len);
            for (set.dynamic.items, dyn) |d, *out| {
                out.* = self.obj(&.{
                    .{ .key = "name", .val = try self.node(d.name) },
                    .{ .key = "value", .val = try self.emitValue(d.value) },
                });
            }
            try fields.append(self.arena, .{ .key = "dynamicAttrs", .val = .{ .array = dyn } });
        }
        // inherit
        if (set.inherits.items.len != 0) {
            var inh: std.ArrayListUnmanaged(J.Field) = .empty;
            for (set.inherits.items) |name| {
                try inh.append(self.arena, .{ .key = name, .val = self.exprVar(name) });
            }
            try fields.append(self.arena, .{ .key = "inherit", .val = .{ .object = try inh.toOwnedSlice(self.arena) } });
        }
        // inheritFrom
        if (set.inherit_from.items.len != 0) {
            const groups = try self.arena.alloc(J, set.inherit_from.items.len);
            for (set.inherit_from.items, groups) |g, *out| {
                const names = try self.arena.alloc(J, g.names.items.len);
                for (g.names.items, names) |name, *nn| nn.* = .{ .str = name };
                out.* = self.obj(&.{
                    .{ .key = "attrs", .val = .{ .array = names } },
                    .{ .key = "from", .val = try self.node(g.from) },
                });
            }
            try fields.append(self.arena, .{ .key = "inheritFrom", .val = .{ .array = groups } });
        }

        return .{ .object = try fields.toOwnedSlice(self.arena) };
    }

    fn emitValue(self: *Ser, v: BValue) !J {
        return switch (v) {
            .leaf => |n| try self.node(n),
            .set => |s| try self.emitSet(s, false, null),
        };
    }

    // ---- name decoding ----

    /// The textual name of a static attr/formal atom. A quoted-string atom is
    /// decoded (`"a b"` → `a b`); a bare identifier/keyword is taken verbatim.
    fn attrNameText(self: *Ser, atom: Node.Atom) []const u8 {
        const text = self.atomText(atom);
        if (string_syntax.kindAt(text, 0) == null) return text;
        const parsed = string_syntax.parseLiteral(self.gpa, self.source, .{
            .start = atom.offset, .end = atom.offset + atom.len,
        }) catch return text;
        defer parsed.deinit();
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        for (parsed.parts) |part| {
            switch (part) {
                .text => |t| buf.appendSlice(self.arena, t.bytes) catch return text,
                .interpolation => {}, // constant names only; ignore any dynamics
            }
        }
        return buf.toOwnedSlice(self.arena) catch text;
    }

    /// If `n` is a constant (non-interpolating) string literal, its decoded
    /// text; otherwise null. Drives `${"lit"}` → static-attr folding.
    fn constString(self: *Ser, n_in: *const Node) !?[]const u8 {
        const n = ast.unwrapParens(n_in);
        if (n.tag != .string) return null;
        const atom = n.data.atom;
        const parsed = string_syntax.parseLiteral(self.gpa, self.source, .{
            .start = atom.offset, .end = atom.offset + atom.len,
        }) catch return null;
        defer parsed.deinit();
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        for (parsed.parts) |part| {
            switch (part) {
                .text => |t| try buf.appendSlice(self.arena, t.bytes),
                .interpolation => return null, // interpolating → stays dynamic
            }
        }
        return try buf.toOwnedSlice(self.arena);
    }

    // ---- J builders ----

    fn obj(self: *Ser, fields: []const J.Field) J {
        return .{ .object = self.arena.dupe(J.Field, fields) catch unreachable };
    }

    fn arr(self: *Ser, items: []const J) J {
        return .{ .array = self.arena.dupe(J, items) catch unreachable };
    }
};

/// A mutable attribute-set under construction. Static attrs are keyed by
/// decoded name; the other buckets preserve source order.
const BSet = struct {
    recursive: bool = false,
    attrs: std.StringArrayHashMapUnmanaged(BValue) = .empty,
    dynamic: std.ArrayListUnmanaged(BDyn) = .empty,
    inherits: std.ArrayListUnmanaged([]const u8) = .empty,
    inherit_from: std.ArrayListUnmanaged(BInheritFrom) = .empty,
};

const BValue = union(enum) {
    leaf: *const Node,
    set: *BSet,
};

const BDyn = struct { name: *const Node, value: BValue };

const BInheritFrom = struct {
    from: *const Node,
    from_offset: u32,
    names: std.ArrayListUnmanaged([]const u8),
};

// ---------------------------------------------------------------------------
// Emitting (nlohmann dump(2) shape: 2-space indent, `_type` first, keys sorted)
// ---------------------------------------------------------------------------

fn emit(w: *std.Io.Writer, j: J, indent: usize) !void {
    switch (j) {
        .int => |v| try w.print("{d}", .{v}),
        .float => |v| try emitFloat(w, v),
        .str => |s| try emitString(w, s),
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .nul => try w.writeAll("null"),
        .array => |items| {
            if (items.len == 0) {
                try w.writeAll("[]");
                return;
            }
            try w.writeAll("[\n");
            for (items, 0..) |item, i| {
                try indentBy(w, indent + 2);
                try emit(w, item, indent + 2);
                if (i + 1 != items.len) try w.writeByte(',');
                try w.writeByte('\n');
            }
            try indentBy(w, indent);
            try w.writeByte(']');
        },
        .object => |fields| {
            if (fields.len == 0) {
                try w.writeAll("{}");
                return;
            }
            // Sort: `_type` first, then lexicographic by key.
            var buf: [24]J.Field = undefined;
            const sorted = if (fields.len <= buf.len) blk: {
                @memcpy(buf[0..fields.len], fields);
                const s = buf[0..fields.len];
                std.mem.sort(J.Field, s, {}, fieldLess);
                break :blk s;
            } else fields; // pathological; emit unsorted rather than fail
            try w.writeAll("{\n");
            for (sorted, 0..) |field, i| {
                try indentBy(w, indent + 2);
                try emitString(w, field.key);
                try w.writeAll(": ");
                try emit(w, field.val, indent + 2);
                if (i + 1 != sorted.len) try w.writeByte(',');
                try w.writeByte('\n');
            }
            try indentBy(w, indent);
            try w.writeByte('}');
        },
    }
}

fn fieldLess(_: void, a: J.Field, b: J.Field) bool {
    const a_type = std.mem.eql(u8, a.key, "_type");
    const b_type = std.mem.eql(u8, b.key, "_type");
    if (a_type != b_type) return a_type; // `_type` sorts first
    return std.mem.lessThan(u8, a.key, b.key);
}

fn indentBy(w: *std.Io.Writer, n: usize) !void {
    try w.splatByteAll(' ', n);
}

/// nlohmann prints doubles with a forced decimal point for integral values
/// (`1` → `1.0`); Zig's `{d}` gives the shortest round-trip but drops the point.
fn emitFloat(w: *std.Io.Writer, v: f64) !void {
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch {
        try w.print("{d}", .{v});
        return;
    };
    try w.writeAll(s);
    if (std.mem.indexOfAny(u8, s, ".eEnN") == null) try w.writeAll(".0");
}

fn emitString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x08 => try w.writeAll("\\b"),
            0x0c => try w.writeAll("\\f"),
            else => if (c < 0x20) {
                try w.print("\\u{x:0>4}", .{c});
            } else {
                try w.writeByte(c);
            },
        }
    }
    try w.writeByte('"');
}

test {
    _ = @import("json/tests.zig");
}
