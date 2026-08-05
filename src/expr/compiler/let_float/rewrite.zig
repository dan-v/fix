//! Copy-on-write application of a let-float rewrite plan.

const std = @import("std");
const compiler_mod = @import("../context.zig");
const ast = @import("syntax").ast;
const types = @import("runtime").types;
const attr_names = @import("../attr_names.zig");
const model = @import("model.zig");

const Compiler = compiler_mod.Compiler;
const Node = compiler_mod.Node;
const InternId = types.InternId;

pub fn rebuildLet(
    self: *Compiler,
    arena: *ast.AstArena,
    decisions: *const model.Plan,
    node: *const Node,
) !*const Node {
    const let_in = node.data.let_in;

    var rw = Rewriter{
        .arena = arena,
        .replacements = &decisions.replacements,
        .wraps = &decisions.wraps,
    };

    // Which original entries survive? An entry survives when its root
    // group's binding is kept. Group ids recompute by first-occurrence
    // order, mirroring `let_analysis.collectBindings`.
    const entry_group = try self.allocator.alloc(usize, let_in.bindings.len);
    {
        var by_name: std.AutoHashMapUnmanaged(InternId, usize) = .empty;
        defer by_name.deinit(self.allocator);
        var next: usize = 0;
        for (let_in.bindings, 0..) |entry, i| {
            const name_id = try self.intern.intern(attr_names.span(self, entry.path[0]));
            const gop = try by_name.getOrPut(self.allocator, name_id);
            if (!gop.found_existing) {
                gop.value_ptr.* = next;
                next += 1;
            }
            entry_group[i] = gop.value_ptr.*;
        }
    }

    var surviving: usize = 0;
    for (let_in.bindings, 0..) |_, i| {
        if (decisions.keep[entry_group[i]]) surviving += 1;
    }

    const new_body = try rw.rewrite(let_in.body);
    if (surviving == 0) return new_body;

    const new_bindings = try arena.allocSlice(Node.Binding, surviving);
    var out: usize = 0;
    for (let_in.bindings, 0..) |entry, i| {
        if (!decisions.keep[entry_group[i]]) continue;
        var copy = entry;
        copy.expr = @constCast(try rw.rewrite(entry.expr));
        new_bindings[out] = copy;
        out += 1;
    }

    if (!rw.changed and surviving == let_in.bindings.len) return node;

    return arena.createNode(.let_in, .{ .let_in = .{
        .bindings = new_bindings,
        .body = @constCast(new_body),
    } });
}

/// Copy-on-write tree rewrite: descends the whole subtree, swapping nodes
/// that have replacements (and recursing into the replacement, so a chain of
/// sinks composes) and rebuilding only ancestors of a change.
const Rewriter = struct {
    arena: *ast.AstArena,
    replacements: *const std.AutoHashMapUnmanaged(*const Node, *const Node),
    wraps: *const std.AutoHashMapUnmanaged(*const Node, std.ArrayListUnmanaged(Node.Binding)),
    changed: bool = false,

    fn rewrite(self: *Rewriter, node_in: *const Node) anyerror!*const Node {
        var node = node_in;
        // A replacement may itself be a replaced site (a sibling sunk into an
        // alias's RHS): chase the chain. Acyclic because movement is strictly
        // "into" a live sibling and recursive SCCs never move.
        while (self.replacements.get(node)) |replacement| {
            self.changed = true;
            node = replacement;
        }
        const rewritten = try self.rewriteChildren(node);
        // Branch-local floats wrap the (fully rewritten) branch expression
        // in a synthetic let re-binding the floated names — keyed by the
        // ORIGINAL branch node the graph walk recorded.
        if (self.wraps.get(node_in)) |floated| {
            return self.wrapWithLet(node_in, rewritten, floated.items);
        }
        return rewritten;
    }

    /// `let <floated…> in <body>` around a branch expression. Binding
    /// entries reuse the original let's entries (name offsets intact), with
    /// their RHSes rewritten; the wrap compiles as an ordinary inner let, so
    /// classification, naming, and its own strict prefix all apply.
    fn wrapWithLet(self: *Rewriter, original: *const Node, body: *const Node, floated: []const Node.Binding) !*const Node {
        self.changed = true;
        const bindings = try self.arena.allocSlice(Node.Binding, floated.len);
        for (floated, bindings) |entry, *out| {
            out.* = entry;
            out.expr = @constCast(try self.rewrite(entry.expr));
        }
        const node = try self.arena.createNode(.let_in, .{ .let_in = .{
            .bindings = bindings,
            .body = @constCast(body),
        } });
        node.span = original.span;
        return node;
    }

    /// Rewrite `node`'s children; return `node` itself when nothing below
    /// changed, else a rebuilt copy (span recomputed by `createNode`).
    fn rewriteChildren(self: *Rewriter, node: *const Node) anyerror!*const Node {
        switch (node.tag) {
            .integer, .float_val, .string, .path, .uri, .search_path, .identifier, .bool_true, .bool_false, .null, .elided => return node,
            .unary_op => {
                const expr = try self.rewrite(node.data.unary.expr);
                if (expr == node.data.unary.expr) return node;
                return self.make(node, .{ .unary = .{ .op = node.data.unary.op, .expr = @constCast(expr) } });
            },
            .binary_op => {
                const b = node.data.binary;
                const left = try self.rewrite(b.left);
                const right = try self.rewrite(b.right);
                if (left == b.left and right == b.right) return node;
                return self.make(node, .{ .binary = .{ .op = b.op, .left = @constCast(left), .right = @constCast(right) } });
            },
            .apply => {
                const a = node.data.apply;
                const func = try self.rewrite(a.func);
                const arg = try self.rewrite(a.arg);
                if (func == a.func and arg == a.arg) return node;
                return self.make(node, .{ .apply = .{ .func = @constCast(func), .arg = @constCast(arg), .pipe = a.pipe } });
            },
            .lambda => {
                const lam = node.data.lambda;
                const body = try self.rewrite(lam.body);
                if (body == lam.body) return node;
                return self.make(node, .{ .lambda = .{
                    .param_offset = lam.param_offset,
                    .param_len = lam.param_len,
                    .body = @constCast(body),
                } });
            },
            .lambda_attrs => {
                const la = node.data.lambda_attrs;
                const body = try self.rewrite(la.body);
                var params_changed = false;
                const new_params = try self.arena.allocSlice(Node.LambdaAttrParam, la.params.len);
                for (la.params, new_params) |param, *out| {
                    out.* = param;
                    if (param.default) |d| {
                        const nd = try self.rewrite(d);
                        if (nd != d) {
                            out.default = @constCast(nd);
                            params_changed = true;
                        }
                    }
                }
                if (body == la.body and !params_changed) return node;
                const boxed = try self.arena.allocator().create(Node.LambdaAttrs);
                boxed.* = .{
                    .bind_name = la.bind_name,
                    .params = new_params,
                    .allow_extra = la.allow_extra,
                    .body = @constCast(body),
                };
                return self.make(node, .{ .lambda_attrs = boxed });
            },
            .let_in => {
                const li = node.data.let_in;
                const body = try self.rewrite(li.body);
                var bindings_changed = false;
                const new_bindings = try self.arena.allocSlice(Node.Binding, li.bindings.len);
                for (li.bindings, new_bindings) |binding, *out| {
                    out.* = binding;
                    const ne = try self.rewrite(binding.expr);
                    if (ne != binding.expr) {
                        out.expr = @constCast(ne);
                        bindings_changed = true;
                    }
                }
                if (body == li.body and !bindings_changed) return node;
                return self.make(node, .{ .let_in = .{
                    .bindings = new_bindings,
                    .body = @constCast(body),
                } });
            },
            .if_else => {
                const i = node.data.if_else;
                const cond = try self.rewrite(i.cond);
                const then_branch = try self.rewrite(i.then_branch);
                const else_branch = try self.rewrite(i.else_branch);
                if (cond == i.cond and then_branch == i.then_branch and else_branch == i.else_branch) return node;
                return self.make(node, .{ .if_else = .{
                    .cond = @constCast(cond),
                    .then_branch = @constCast(then_branch),
                    .else_branch = @constCast(else_branch),
                } });
            },
            .assert => {
                const a = node.data.assert;
                const cond = try self.rewrite(a.cond);
                const body = try self.rewrite(a.body);
                if (cond == a.cond and body == a.body) return node;
                return self.make(node, .{ .assert = .{ .cond = @constCast(cond), .body = @constCast(body) } });
            },
            .with_expr => {
                const w = node.data.with_expr;
                const attr_set = try self.rewrite(w.attr_set);
                const body = try self.rewrite(w.body);
                if (attr_set == w.attr_set and body == w.body) return node;
                return self.make(node, .{ .with_expr = .{ .attr_set = @constCast(attr_set), .body = @constCast(body) } });
            },
            .attr_set => {
                const set = node.data.attr_set;
                var entries_changed = false;
                const new_entries = try self.arena.allocSlice(Node.AttrSetEntry, set.entries.len);
                for (set.entries, new_entries) |entry, *out| {
                    out.* = entry;
                    const ne = try self.rewrite(entry.expr);
                    if (ne != entry.expr) {
                        out.expr = @constCast(ne);
                        entries_changed = true;
                    }
                    if (entry.dynamic_name) |dn| {
                        const ndn = try self.rewrite(dn);
                        if (ndn != dn) {
                            out.dynamic_name = @constCast(ndn);
                            entries_changed = true;
                        }
                    }
                }
                if (!entries_changed) return node;
                return self.make(node, .{ .attr_set = .{ .entries = new_entries, .recursive = set.recursive } });
            },
            .attr_path => {
                const ap = node.data.attr_path;
                const root = try self.rewrite(ap.root);
                if (root == ap.root) return node;
                return self.make(node, .{ .attr_path = .{ .root = @constCast(root), .segments = ap.segments } });
            },
            .attr_dynamic => {
                const ad = node.data.attr_dynamic;
                const root = try self.rewrite(ad.root);
                const name = try self.rewrite(ad.name);
                if (root == ad.root and name == ad.name) return node;
                return self.make(node, .{ .attr_dynamic = .{ .root = @constCast(root), .name = @constCast(name) } });
            },
            .attr_or => {
                const ao = node.data.attr_or;
                const attr_path = try self.rewrite(ao.attr_path);
                const default = try self.rewrite(ao.default);
                if (attr_path == ao.attr_path and default == ao.default) return node;
                return self.make(node, .{ .attr_or = .{ .attr_path = @constCast(attr_path), .default = @constCast(default) } });
            },
            .has_attr => {
                const ha = node.data.has_attr;
                const root = try self.rewrite(ha.root);
                if (root == ha.root) return node;
                return self.make(node, .{ .has_attr = .{ .root = @constCast(root), .segments = ha.segments } });
            },
            .has_attr_mixed => {
                const ham = node.data.has_attr_mixed;
                const root = try self.rewrite(ham.root);
                var segments_changed = false;
                const new_segments = try self.arena.allocSlice(Node.HasAttrMixedSegment, ham.segments.len);
                for (ham.segments, new_segments) |seg, *out| {
                    out.* = seg;
                    switch (seg) {
                        .static => {},
                        .dynamic => |d| {
                            const nd = try self.rewrite(d);
                            if (nd != d) {
                                out.* = .{ .dynamic = @constCast(nd) };
                                segments_changed = true;
                            }
                        },
                    }
                }
                if (root == ham.root and !segments_changed) return node;
                return self.make(node, .{ .has_attr_mixed = .{ .root = @constCast(root), .segments = new_segments } });
            },
            .list => {
                const list = node.data.list;
                var items_changed = false;
                const new_items = try self.arena.allocSlice(*Node, list.items.len);
                for (list.items, new_items) |item, *out| {
                    const ni = try self.rewrite(item);
                    out.* = @constCast(ni);
                    if (ni != item) items_changed = true;
                }
                if (!items_changed) return node;
                return self.make(node, .{ .list = .{ .items = new_items } });
            },
            .parens => {
                const inner = try self.rewrite(node.data.parens);
                if (inner == node.data.parens) return node;
                return self.make(node, .{ .parens = @constCast(inner) });
            },
        }
    }

    fn make(self: *Rewriter, original: *const Node, data: Node.Data) !*const Node {
        self.changed = true;
        const node = try self.arena.createNode(original.tag, data);
        // Keep the original node's span: `createNode` recombines child spans,
        // but the surrounding source region is still the truest attribution
        // for diagnostics on the rebuilt node.
        node.span = original.span;
        return node;
    }
};
