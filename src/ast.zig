//! AST node definitions.
//!
//! All nodes are allocated in an arena allocator and never freed individually.
//! Nodes reference source spans via byte offsets into the source file.
//! This keeps nodes small and avoids string copies.

const std = @import("std");

pub const NodeTag = enum(u8) {
    // ---- atoms ----
    integer,
    float_val,
    string,
    path,
    search_path,
    identifier,
    bool_true,
    bool_false,
    null,

    // ---- compound ----
    unary_op,
    binary_op,
    apply,
    lambda,
    lambda_attrs,
    let_in,
    if_else,
    assert,
    with_expr,
    attr_set,
    attr_path, // foo.bar.baz
    attr_dynamic, // foo.${expr}
    attr_or, // foo.bar or default
    has_attr, // foo ? bar.baz
    has_attr_dynamic, // foo ? ${expr}
    has_attr_mixed, // foo ? bar.${expr}
    list,
    parens, // parenthesized subexpression
};

pub const BinaryOp = enum(u8) {
    add,
    sub,
    mul,
    div,
    eq,
    neq,
    lt,
    lte,
    gt,
    gte,
    and_,
    or_,
    impl, // ->
    update, // //
    concat, // + on strings
};

pub const UnaryOp = enum(u8) {
    not,
    negate,
};

/// All AST nodes use this struct. The `data` union holds type-specific fields.
/// Pointers inside `data` point to other Node structs within the same arena.
pub const Node = struct {
    tag: NodeTag,
    data: Data,

    pub const Data = union {
        // Atoms store byte offsets into source.
        atom: Atom,
        // Compound nodes hold pointers to children.
        unary: Unary,
        binary: Binary,
        apply: Apply,
        lambda: Lambda,
        lambda_attrs: LambdaAttrs,
        let_in: LetIn,
        if_else: IfElse,
        assert: Assert,
        with_expr: WithExpr,
        attr_set: AttrSet,
        attr_path: AttrPath,
        attr_dynamic: AttrDynamic,
        attr_or: AttrOr,
        has_attr: HasAttr,
        has_attr_dynamic: AttrDynamic,
        has_attr_mixed: HasAttrMixed,
        list: List,
        parens: *Node,
    };

    pub const Atom = struct {
        offset: u32,
        len: u32,
    };

    pub const Unary = struct {
        op: UnaryOp,
        expr: *Node,
    };

    pub const Binary = struct {
        op: BinaryOp,
        left: *Node,
        right: *Node,
    };

    pub const Apply = struct {
        func: *Node,
        arg: *Node,
    };

    pub const Lambda = struct {
        param_offset: u32,
        param_len: u32,
        body: *Node,
    };

    pub const LambdaAttrs = struct {
        bind_name: ?Atom,
        params: []LambdaAttrParam,
        allow_extra: bool,
        body: *Node,
    };

    pub const LambdaAttrParam = struct {
        name: Atom,
        default: ?*Node,
    };

    pub const LetIn = struct {
        bindings: []Binding,
        body: *Node,
    };

    pub const Binding = struct {
        name_offset: u32,
        name_len: u32,
        path: []Atom,
        expr: *Node,
        inherit_outer: bool = false,
    };

    pub const IfElse = struct {
        cond: *Node,
        then_branch: *Node,
        else_branch: *Node,
    };

    pub const Assert = struct {
        cond: *Node,
        body: *Node,
    };

    pub const WithExpr = struct {
        attr_set: *Node,
        body: *Node,
    };

    pub const AttrSetEntry = struct {
        path: []Atom,
        dynamic_name: ?*Node = null,
        tail_dynamic_name: ?*Node = null,
        expr: *Node,
        inherit_outer: bool = false,
    };

    pub const AttrSet = struct {
        entries: []AttrSetEntry,
        recursive: bool,
    };

    pub const AttrPath = struct {
        root: *Node,
        /// Attribute names (as source offsets).
        /// e.g., `a.b.c` → [a, b, c]
        segments: []Atom,
    };

    pub const AttrDynamic = struct {
        root: *Node,
        name: *Node,
    };

    pub const AttrOr = struct {
        attr_path: *Node,
        default: *Node,
    };

    pub const HasAttr = struct {
        root: *Node,
        segments: []Atom,
    };

    pub const HasAttrMixedSegment = union(enum) {
        static: Atom,
        dynamic: *Node,
    };

    pub const HasAttrMixed = struct {
        root: *Node,
        segments: []HasAttrMixedSegment,
    };

    pub const List = struct {
        items: []*Node,
    };
};

/// Arena allocator wrapper for building ASTs.
/// All nodes and their children live here.
pub const AstArena = struct {
    inner: std.heap.ArenaAllocator,

    pub fn init(parent_allocator: std.mem.Allocator) AstArena {
        return .{ .inner = std.heap.ArenaAllocator.init(parent_allocator) };
    }

    pub fn deinit(self: *AstArena) void {
        self.inner.deinit();
    }

    pub fn allocator(self: *AstArena) std.mem.Allocator {
        return self.inner.allocator();
    }

    pub fn createNode(self: *AstArena, tag: NodeTag, data: Node.Data) !*Node {
        const node = try self.allocator().create(Node);
        node.* = .{ .tag = tag, .data = data };
        return node;
    }

    pub fn allocSlice(self: *AstArena, comptime T: type, len: usize) ![]T {
        return self.allocator().alloc(T, len);
    }
};

pub fn cloneNode(arena: *AstArena, node: *const Node) anyerror!*Node {
    return switch (node.tag) {
        .integer,
        .float_val,
        .string,
        .path,
        .search_path,
        .identifier,
        .bool_true,
        .bool_false,
        .null,
        => arena.createNode(node.tag, .{ .atom = node.data.atom }),

        .unary_op => arena.createNode(.unary_op, .{ .unary = .{
            .op = node.data.unary.op,
            .expr = try cloneNode(arena, node.data.unary.expr),
        } }),
        .binary_op => arena.createNode(.binary_op, .{ .binary = .{
            .op = node.data.binary.op,
            .left = try cloneNode(arena, node.data.binary.left),
            .right = try cloneNode(arena, node.data.binary.right),
        } }),
        .apply => arena.createNode(.apply, .{ .apply = .{
            .func = try cloneNode(arena, node.data.apply.func),
            .arg = try cloneNode(arena, node.data.apply.arg),
        } }),
        .lambda => arena.createNode(.lambda, .{ .lambda = .{
            .param_offset = node.data.lambda.param_offset,
            .param_len = node.data.lambda.param_len,
            .body = try cloneNode(arena, node.data.lambda.body),
        } }),
        .lambda_attrs => arena.createNode(.lambda_attrs, .{ .lambda_attrs = .{
            .bind_name = node.data.lambda_attrs.bind_name,
            .params = try cloneLambdaParams(arena, node.data.lambda_attrs.params),
            .allow_extra = node.data.lambda_attrs.allow_extra,
            .body = try cloneNode(arena, node.data.lambda_attrs.body),
        } }),
        .let_in => arena.createNode(.let_in, .{ .let_in = .{
            .bindings = try cloneBindings(arena, node.data.let_in.bindings),
            .body = try cloneNode(arena, node.data.let_in.body),
        } }),
        .if_else => arena.createNode(.if_else, .{ .if_else = .{
            .cond = try cloneNode(arena, node.data.if_else.cond),
            .then_branch = try cloneNode(arena, node.data.if_else.then_branch),
            .else_branch = try cloneNode(arena, node.data.if_else.else_branch),
        } }),
        .assert => arena.createNode(.assert, .{ .assert = .{
            .cond = try cloneNode(arena, node.data.assert.cond),
            .body = try cloneNode(arena, node.data.assert.body),
        } }),
        .with_expr => arena.createNode(.with_expr, .{ .with_expr = .{
            .attr_set = try cloneNode(arena, node.data.with_expr.attr_set),
            .body = try cloneNode(arena, node.data.with_expr.body),
        } }),
        .attr_set => arena.createNode(.attr_set, .{ .attr_set = .{
            .entries = try cloneAttrSetEntries(arena, node.data.attr_set.entries),
            .recursive = node.data.attr_set.recursive,
        } }),
        .attr_path => arena.createNode(.attr_path, .{ .attr_path = .{
            .root = try cloneNode(arena, node.data.attr_path.root),
            .segments = try cloneAtoms(arena, node.data.attr_path.segments),
        } }),
        .attr_dynamic => arena.createNode(.attr_dynamic, .{ .attr_dynamic = .{
            .root = try cloneNode(arena, node.data.attr_dynamic.root),
            .name = try cloneNode(arena, node.data.attr_dynamic.name),
        } }),
        .attr_or => arena.createNode(.attr_or, .{ .attr_or = .{
            .attr_path = try cloneNode(arena, node.data.attr_or.attr_path),
            .default = try cloneNode(arena, node.data.attr_or.default),
        } }),
        .has_attr => arena.createNode(.has_attr, .{ .has_attr = .{
            .root = try cloneNode(arena, node.data.has_attr.root),
            .segments = try cloneAtoms(arena, node.data.has_attr.segments),
        } }),
        .has_attr_dynamic => arena.createNode(.has_attr_dynamic, .{ .has_attr_dynamic = .{
            .root = try cloneNode(arena, node.data.has_attr_dynamic.root),
            .name = try cloneNode(arena, node.data.has_attr_dynamic.name),
        } }),
        .has_attr_mixed => arena.createNode(.has_attr_mixed, .{ .has_attr_mixed = .{
            .root = try cloneNode(arena, node.data.has_attr_mixed.root),
            .segments = try cloneHasAttrMixedSegments(arena, node.data.has_attr_mixed.segments),
        } }),
        .list => arena.createNode(.list, .{ .list = .{
            .items = try cloneNodeSlice(arena, node.data.list.items),
        } }),
        .parens => arena.createNode(.parens, .{ .parens = try cloneNode(arena, node.data.parens) }),
    };
}

fn cloneAtoms(arena: *AstArena, atoms: []const Node.Atom) anyerror![]Node.Atom {
    const cloned = try arena.allocSlice(Node.Atom, atoms.len);
    @memcpy(cloned, atoms);
    return cloned;
}

fn cloneNodeSlice(arena: *AstArena, nodes: []const *Node) anyerror![]*Node {
    const cloned = try arena.allocSlice(*Node, nodes.len);
    for (nodes, cloned) |item, *dest| {
        dest.* = try cloneNode(arena, item);
    }
    return cloned;
}

fn cloneLambdaParams(arena: *AstArena, params: []const Node.LambdaAttrParam) anyerror![]Node.LambdaAttrParam {
    const cloned = try arena.allocSlice(Node.LambdaAttrParam, params.len);
    for (params, cloned) |param, *dest| {
        dest.* = .{
            .name = param.name,
            .default = if (param.default) |default| try cloneNode(arena, default) else null,
        };
    }
    return cloned;
}

fn cloneBindings(arena: *AstArena, bindings: []const Node.Binding) anyerror![]Node.Binding {
    const cloned = try arena.allocSlice(Node.Binding, bindings.len);
    for (bindings, cloned) |binding, *dest| {
        dest.* = .{
            .name_offset = binding.name_offset,
            .name_len = binding.name_len,
            .path = try cloneAtoms(arena, binding.path),
            .expr = try cloneNode(arena, binding.expr),
            .inherit_outer = binding.inherit_outer,
        };
    }
    return cloned;
}

fn cloneAttrSetEntries(arena: *AstArena, entries: []const Node.AttrSetEntry) anyerror![]Node.AttrSetEntry {
    const cloned = try arena.allocSlice(Node.AttrSetEntry, entries.len);
    for (entries, cloned) |entry, *dest| {
        dest.* = .{
            .path = try cloneAtoms(arena, entry.path),
            .dynamic_name = if (entry.dynamic_name) |name| try cloneNode(arena, name) else null,
            .tail_dynamic_name = if (entry.tail_dynamic_name) |name| try cloneNode(arena, name) else null,
            .expr = try cloneNode(arena, entry.expr),
            .inherit_outer = entry.inherit_outer,
        };
    }
    return cloned;
}

fn cloneHasAttrMixedSegments(arena: *AstArena, segments: []const Node.HasAttrMixedSegment) anyerror![]Node.HasAttrMixedSegment {
    const cloned = try arena.allocSlice(Node.HasAttrMixedSegment, segments.len);
    for (segments, cloned) |segment, *dest| {
        dest.* = switch (segment) {
            .static => |atom| .{ .static = atom },
            .dynamic => |dynamic| .{ .dynamic = try cloneNode(arena, dynamic) },
        };
    }
    return cloned;
}
