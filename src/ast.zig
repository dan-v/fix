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
    attr_or, // foo.bar or default
    has_attr, // foo ? bar.baz
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
        attr_or: AttrOr,
        has_attr: HasAttr,
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
        params: []Atom,
        body: *Node,
    };

    pub const LetIn = struct {
        bindings: []Binding,
        body: *Node,
    };

    pub const Binding = struct {
        name_offset: u32,
        name_len: u32,
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
        expr: *Node,
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

    pub const AttrOr = struct {
        attr_path: *Node,
        default: *Node,
    };

    pub const HasAttr = struct {
        root: *Node,
        segments: []Atom,
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
