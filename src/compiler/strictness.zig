//! Compile-time strictness analysis on the AST.
//!
//! For a chunk's body, compute two sets of upvalues that the chunk will
//! force when entered:
//!   - **shallow** — forced unconditionally as the body is reduced to WHNF.
//!   - **deep**    — additionally forced when the *result* of the body is
//!                   deep-forced by the caller. Captures the case where the
//!                   body builds an attr-set or list whose values reference
//!                   upvalues — those values get forced if the caller walks
//!                   the structure.
//!
//! Translated at chunk-finish into `ChunkStrictness.{forced_upvalues,
//! deep_upvalues}` and consumed by the scheduler to pre-submit known-
//! demanded thunks at the producer side instead of waiting for fan-out
//! at strict barriers.
//!
//! Semantic model. Two functions:
//!   `shallow(e)` — names forced reducing `e` to weak-head normal form.
//!   `deep(e)`    — names forced reducing `e` to deep-WHNF (recursively).
//! By construction `shallow(e) ⊆ deep(e)`.
//!
//! Rules of note:
//!   - identifier `x`: shallow = {x}, deep = {x}.
//!   - lambda value: shallow = deep = ∅ (closure values are atomic).
//!   - attr-set / list literal: shallow = ∅; deep = ⋃ deep(values).
//!     Building doesn't force; walking does.
//!   - arithmetic / comparison: shallow & deep both union over operands.
//!     Result is primitive, so deep == shallow at the chunk root.
//!   - `if c then t else f`: union of cond strictness with branch-wise
//!     intersection, computed independently for shallow and deep.
//!   - `let x = rhs in body`: substitute references to `x` in `body`'s
//!     sets with the corresponding set from `rhs`.
//!   - `apply f x`: shallow(f); cross-chunk on `x` is a later phase.
//!
//! The analysis runs after the body has been compiled, walking the body's
//! AST a second time. It does NOT recurse into nested `lambda` /
//! `lambda_attrs` bodies — those are separate chunks.

const std = @import("std");
const ast = @import("../ast.zig");
const types = @import("../runtime/types.zig");
const intern_mod = @import("../runtime/intern.zig");
const chunk_mod = @import("../bytecode/chunk.zig");

const Node = ast.Node;
const InternId = types.InternId;
const InternTable = intern_mod.InternTable;
const ChunkStrictness = chunk_mod.ChunkStrictness;

const NameSet = std.AutoHashMapUnmanaged(InternId, void);

const Strictness = struct {
    shallow: NameSet,
    deep: NameSet,

    fn empty() Strictness {
        return .{ .shallow = .empty, .deep = .empty };
    }

    fn deinit(self: *Strictness, allocator: std.mem.Allocator) void {
        self.shallow.deinit(allocator);
        self.deep.deinit(allocator);
    }

    fn unionInto(self: *Strictness, allocator: std.mem.Allocator, other: *const Strictness) !void {
        var it = other.shallow.iterator();
        while (it.next()) |e| try self.shallow.put(allocator, e.key_ptr.*, {});
        var it2 = other.deep.iterator();
        while (it2.next()) |e| try self.deep.put(allocator, e.key_ptr.*, {});
    }

    /// Treat `other` as appearing in a deep-only context: its shallow
    /// names *don't* contribute to our shallow (we're not forcing them
    /// when we reduce), but they do contribute to our deep (they get
    /// forced when our result is walked). Used by attr-set / list
    /// element rules.
    fn unionIntoDeepOnly(self: *Strictness, allocator: std.mem.Allocator, other: *const Strictness) !void {
        var it = other.shallow.iterator();
        while (it.next()) |e| try self.deep.put(allocator, e.key_ptr.*, {});
        var it2 = other.deep.iterator();
        while (it2.next()) |e| try self.deep.put(allocator, e.key_ptr.*, {});
    }
};

const BoundFrame = struct {
    name: InternId,
    /// Strictness of this binding's RHS. When body references `name`,
    /// expand to this. `null` for lambda params where the RHS is the
    /// caller's arg (cross-chunk).
    rhs: ?Strictness,
};

const Analyzer = struct {
    allocator: std.mem.Allocator,
    intern: *InternTable,
    source: []const u8,
    bound_stack: std.ArrayListUnmanaged(BoundFrame),
    /// When true, `shallow` is a sound *must-force* under-approximation
    /// (a name is included only if it is forced on every path, before
    /// any other observable effect). Differs from the default may-force
    /// set only at `assert` (body may be skipped if the assertion
    /// fails) and `with` (the scope expr is forced lazily). Used by
    /// `analyzeLetMustForce` to drive eager-binding elision, where
    /// being wrong would force a value lazy eval wouldn't.
    must_force: bool = false,

    fn deinit(self: *Analyzer) void {
        for (self.bound_stack.items) |*frame| {
            if (frame.rhs) |*r| r.deinit(self.allocator);
        }
        self.bound_stack.deinit(self.allocator);
    }

    fn findBound(self: *const Analyzer, name_id: InternId) ?usize {
        var i = self.bound_stack.items.len;
        while (i > 0) {
            i -= 1;
            if (self.bound_stack.items[i].name == name_id) return i;
        }
        return null;
    }

    fn identifierNameId(self: *Analyzer, node: *const Node) !InternId {
        const atom = node.data.atom;
        const name = self.source[atom.offset .. atom.offset + atom.len];
        return self.intern.intern(name);
    }

    fn bindingNameId(self: *Analyzer, binding: Node.Binding) !InternId {
        const name = self.source[binding.name_offset .. binding.name_offset + binding.name_len];
        return self.intern.intern(name);
    }

    fn analyze(self: *Analyzer, node: *const Node) anyerror!Strictness {
        var out = Strictness.empty();
        errdefer out.deinit(self.allocator);
        try self.analyzeInto(node, &out);
        return out;
    }

    fn analyzeInto(self: *Analyzer, node: *const Node, out: *Strictness) anyerror!void {
        switch (node.tag) {
            // ---- atomic WHNF, leaves nothing demanded ----
            .integer,
            .float_val,
            .string,
            .path,
            .search_path,
            .bool_true,
            .bool_false,
            .null,
            .lambda,
            .lambda_attrs,
            => {},

            .identifier => {
                const name_id = try self.identifierNameId(node);
                if (self.findBound(name_id)) |idx| {
                    if (self.bound_stack.items[idx].rhs) |*rhs| {
                        try out.unionInto(self.allocator, rhs);
                    }
                } else {
                    try out.shallow.put(self.allocator, name_id, {});
                    try out.deep.put(self.allocator, name_id, {});
                }
            },

            .attr_set => {
                // Building an attr-set forces nothing. Deep-forcing the
                // result forces each value's deep set.
                for (node.data.attr_set.entries) |entry| {
                    var entry_s = try self.analyze(entry.expr);
                    defer entry_s.deinit(self.allocator);
                    try out.unionIntoDeepOnly(self.allocator, &entry_s);
                }
            },

            .list => {
                for (node.data.list.items) |item| {
                    var item_s = try self.analyze(item);
                    defer item_s.deinit(self.allocator);
                    try out.unionIntoDeepOnly(self.allocator, &item_s);
                }
            },

            .unary_op => try self.analyzeInto(node.data.unary.expr, out),

            .binary_op => {
                const b = node.data.binary;
                switch (b.op) {
                    .add, .sub, .mul, .div, .eq, .neq, .lt, .lte, .gt, .gte, .update, .concat => {
                        try self.analyzeInto(b.left, out);
                        try self.analyzeInto(b.right, out);
                    },
                    .and_, .or_, .impl => {
                        try self.analyzeInto(b.left, out);
                    },
                }
            },

            .apply => try self.analyzeInto(node.data.apply.func, out),

            .let_in => {
                const let = node.data.let_in;
                const start_len = self.bound_stack.items.len;

                for (let.bindings) |binding| {
                    const name_id = try self.bindingNameId(binding);
                    try self.bound_stack.append(self.allocator, .{ .name = name_id, .rhs = null });
                }
                for (let.bindings, 0..) |binding, i| {
                    var rhs = try self.analyze(binding.expr);
                    errdefer rhs.deinit(self.allocator);
                    self.bound_stack.items[start_len + i].rhs = rhs;
                }

                try self.analyzeInto(let.body, out);

                while (self.bound_stack.items.len > start_len) {
                    var frame = self.bound_stack.pop().?;
                    if (frame.rhs) |*r| r.deinit(self.allocator);
                }
            },

            .if_else => {
                const i = node.data.if_else;
                try self.analyzeInto(i.cond, out);
                var then_s = try self.analyze(i.then_branch);
                defer then_s.deinit(self.allocator);
                var else_s = try self.analyze(i.else_branch);
                defer else_s.deinit(self.allocator);
                var it = then_s.shallow.iterator();
                while (it.next()) |entry| {
                    if (else_s.shallow.contains(entry.key_ptr.*)) {
                        try out.shallow.put(self.allocator, entry.key_ptr.*, {});
                    }
                }
                var it_deep = then_s.deep.iterator();
                while (it_deep.next()) |entry| {
                    if (else_s.deep.contains(entry.key_ptr.*)) {
                        try out.deep.put(self.allocator, entry.key_ptr.*, {});
                    }
                }
            },

            .assert => {
                const a = node.data.assert;
                try self.analyzeInto(a.cond, out);
                // The body runs only if the assertion passes, so under
                // must-force we can't promise its names are forced.
                if (!self.must_force) try self.analyzeInto(a.body, out);
            },

            .with_expr => {
                const w = node.data.with_expr;
                // The scope expr is forced lazily (only when the body
                // resolves a name through it), so exclude it under
                // must-force. The body always runs.
                if (!self.must_force) try self.analyzeInto(w.attr_set, out);
                try self.analyzeInto(w.body, out);
            },

            .attr_path => try self.analyzeInto(node.data.attr_path.root, out),

            .attr_dynamic => {
                try self.analyzeInto(node.data.attr_dynamic.root, out);
                try self.analyzeInto(node.data.attr_dynamic.name, out);
            },

            .attr_or => try self.analyzeAttrOrChain(node.data.attr_or.attr_path, out),

            .has_attr => try self.analyzeInto(node.data.has_attr.root, out),
            .has_attr_dynamic => try self.analyzeInto(node.data.has_attr_dynamic.root, out),
            .has_attr_mixed => try self.analyzeInto(node.data.has_attr_mixed.root, out),

            .parens => try self.analyzeInto(node.data.parens, out),
        }
    }

    /// Walk an `attr_or`'s lookup chain conservatively: only the
    /// chain's base expression is unconditionally evaluated. Each
    /// segment (static or dynamic) may short-circuit if a preceding
    /// lookup fails — so we must NOT mark dynamic-segment names as
    /// strict, since `attr.${k} or d` will skip evaluating `k` when
    /// an earlier segment in the chain misses.
    fn analyzeAttrOrChain(self: *Analyzer, node: *const Node, out: *Strictness) anyerror!void {
        switch (node.tag) {
            .attr_path => try self.analyzeInto(node.data.attr_path.root, out),
            .attr_dynamic => try self.analyzeAttrOrChain(node.data.attr_dynamic.root, out),
            .has_attr => try self.analyzeInto(node.data.has_attr.root, out),
            .has_attr_dynamic => try self.analyzeAttrOrChain(node.data.has_attr_dynamic.root, out),
            .has_attr_mixed => try self.analyzeInto(node.data.has_attr_mixed.root, out),
            .parens => try self.analyzeAttrOrChain(node.data.parens, out),
            else => try self.analyzeInto(node, out),
        }
    }
};

pub const StrictnessResult = struct {
    strict: Strictness,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *StrictnessResult) void {
        self.strict.deinit(self.allocator);
    }
};

pub fn analyzeChunkBody(
    allocator: std.mem.Allocator,
    intern: *InternTable,
    source: []const u8,
    body: *const Node,
    params: []const InternId,
) !StrictnessResult {
    var an: Analyzer = .{
        .allocator = allocator,
        .intern = intern,
        .source = source,
        .bound_stack = .empty,
    };
    defer an.deinit();

    for (params) |p| {
        try an.bound_stack.append(allocator, .{ .name = p, .rhs = null });
    }

    var strict = try an.analyze(body);
    for (params) |p| {
        _ = strict.shallow.remove(p);
        _ = strict.deep.remove(p);
    }

    return .{ .strict = strict, .allocator = allocator };
}

/// For each binding name, decide whether the let-block's body will
/// unconditionally force it. Used by `compileLetIn` to emit
/// `thunk_captures_eager` for those bindings — they get submitted to
/// the urgent scheduler queue at creation instead of waiting for the
/// chunk-size speculation heuristic.
///
/// Analyzes `body` with an empty bound_stack so binding names appear
/// as free identifiers in the strict set. Inner scopes (nested lets,
/// lambdas) correctly shadow via the analyzer's bound_stack
/// management, so a shadowed outer name doesn't get a false positive.
pub fn analyzeLetEagerness(
    allocator: std.mem.Allocator,
    intern: *InternTable,
    source: []const u8,
    body: *const Node,
    binding_names: []const InternId,
    out_eager: []bool,
) !void {
    std.debug.assert(binding_names.len == out_eager.len);
    var an: Analyzer = .{
        .allocator = allocator,
        .intern = intern,
        .source = source,
        .bound_stack = .empty,
    };
    defer an.deinit();

    var strict = try an.analyze(body);
    defer strict.deinit(allocator);

    for (binding_names, out_eager) |name, *eager| {
        eager.* = strict.shallow.contains(name);
    }
}

/// Sound *must-force* version of `analyzeLetEagerness`: sets
/// `out_must_force[i]` iff the let-block body unconditionally forces
/// `binding_names[i]` to WHNF on every path before any other
/// observable effect. Used by `compileLetIn` to eagerly evaluate such
/// bindings directly into their slot instead of emitting a thunk —
/// which is safe precisely because lazy evaluation would force them
/// anyway, so eager eval can't turn a success into an error (only
/// possibly change which error surfaces in an already-failing eval).
pub fn analyzeLetMustForce(
    allocator: std.mem.Allocator,
    intern: *InternTable,
    source: []const u8,
    body: *const Node,
    binding_names: []const InternId,
    out_must_force: []bool,
) !void {
    std.debug.assert(binding_names.len == out_must_force.len);
    var an: Analyzer = .{
        .allocator = allocator,
        .intern = intern,
        .source = source,
        .bound_stack = .empty,
        .must_force = true,
    };
    defer an.deinit();

    var strict = try an.analyze(body);
    defer strict.deinit(allocator);

    for (binding_names, out_must_force) |name, *mf| {
        mf.* = strict.shallow.contains(name);
    }
}

const Compiler = @import("../compiler.zig").Compiler;

pub fn stampOnBuilder(c: *Compiler, body: *const Node) !void {
    var params: std.ArrayListUnmanaged(InternId) = .empty;
    defer params.deinit(c.allocator);
    try params.ensureTotalCapacity(c.allocator, c.locals.items.len);
    for (c.locals.items) |local| params.appendAssumeCapacity(local.name_id);

    var result = try analyzeChunkBody(c.allocator, c.intern, c.source, body, params.items);
    defer result.deinit();

    var capture_ids: std.ArrayListUnmanaged(InternId) = .empty;
    defer capture_ids.deinit(c.allocator);
    try capture_ids.ensureTotalCapacity(c.allocator, c.captures.items.len);
    for (c.captures.items) |capture| {
        const id = c.intern.intern(capture.name) catch continue;
        capture_ids.appendAssumeCapacity(id);
    }

    const shallow_mask = nameSetToMask(&result.strict.shallow, capture_ids.items);
    const deep_mask = nameSetToMask(&result.strict.deep, capture_ids.items);

    c.builder.strictness = .{
        .forced_upvalues = shallow_mask,
        .deep_upvalues = deep_mask,
    };
}

fn nameSetToMask(names: *const NameSet, capture_ids: []const InternId) u64 {
    var mask: u64 = 0;
    var it = names.iterator();
    while (it.next()) |entry| {
        const name_id = entry.key_ptr.*;
        for (capture_ids, 0..) |cid, slot| {
            if (cid == name_id) {
                if (slot < 64) mask |= @as(u64, 1) << @as(u6, @intCast(slot));
                break;
            }
        }
    }
    return mask;
}
