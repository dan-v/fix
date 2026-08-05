//! SCC annotation and immutable index freezing for let analysis.

const std = @import("std");
const model = @import("model.zig");

const BindingId = model.BindingId;
const Graph = model.Graph;
const invalid_binding = model.invalid_binding;

pub fn finalize(allocator: std.mem.Allocator, graph: *Graph) !void {
    try computeSccs(allocator, graph);
    try buildIndexes(allocator, graph);
}

/// Freeze the walk's name and edge indexes. From this point on the graph is
/// an analysis snapshot: rewrite policy may layer state over it, but never
/// appends uses or changes binding facts.
fn buildIndexes(allocator: std.mem.Allocator, graph: *Graph) !void {
    const n = graph.bindings.len;

    try graph.binding_by_name.ensureTotalCapacity(allocator, @intCast(n));
    for (graph.bindings, 0..) |binding, i| {
        graph.binding_by_name.putAssumeCapacity(binding.name_id, @intCast(i));
    }

    const owners = try allocator.alloc(BindingId, n);
    var inherit_owners: std.AutoHashMapUnmanaged(u32, BindingId) = .empty;
    defer inherit_owners.deinit(allocator);
    for (graph.bindings, 0..) |binding, i| {
        const binding_id: BindingId = @intCast(i);
        if (binding.kind != .inherit_member) {
            owners[i] = binding_id;
            continue;
        }
        const gop = try inherit_owners.getOrPut(allocator, binding.inherit_group);
        if (!gop.found_existing) gop.value_ptr.* = binding_id;
        owners[i] = gop.value_ptr.*;
    }
    graph.activation_owner = owners;

    const use_offsets = try allocator.alloc(u32, n + 1);
    @memset(use_offsets, 0);
    const dependency_offsets = try allocator.alloc(u32, n + 1);
    @memset(dependency_offsets, 0);
    var root_count: usize = 0;
    for (graph.uses) |use| {
        use_offsets[use.binding + 1] += 1;
        if (use.in_rhs_of == invalid_binding) {
            root_count += 1;
        } else {
            dependency_offsets[owners[use.in_rhs_of] + 1] += 1;
        }
    }
    for (1..use_offsets.len) |i| {
        use_offsets[i] += use_offsets[i - 1];
        dependency_offsets[i] += dependency_offsets[i - 1];
    }

    const use_items = try allocator.alloc(u32, graph.uses.len);
    const dependency_count: usize = dependency_offsets[n];
    const dependency_items = try allocator.alloc(u32, dependency_count);
    const roots = try allocator.alloc(BindingId, root_count);
    const cursor = try allocator.alloc(u32, n);
    defer allocator.free(cursor);

    @memcpy(cursor, use_offsets[0..n]);
    for (graph.uses, 0..) |use, use_index| {
        use_items[cursor[use.binding]] = @intCast(use_index);
        cursor[use.binding] += 1;
    }

    @memcpy(cursor, dependency_offsets[0..n]);
    var root_index: usize = 0;
    for (graph.uses) |use| {
        if (use.in_rhs_of == invalid_binding) {
            roots[root_index] = use.binding;
            root_index += 1;
        } else {
            const owner = owners[use.in_rhs_of];
            dependency_items[cursor[owner]] = use.binding;
            cursor[owner] += 1;
        }
    }

    graph.uses_by_binding = .{ .offsets = use_offsets, .items = use_items };
    graph.dependencies_by_owner = .{ .offsets = dependency_offsets, .items = dependency_items };
    graph.root_dependencies = roots;
}

/// Iterative Tarjan over same-cluster dependency edges (B → sibling C when
/// B's RHS references C). Marks every member of a multi-node component (and
/// any self-referential binding) `scc_recursive`.
fn computeSccs(allocator: std.mem.Allocator, graph: *Graph) !void {
    const n = graph.bindings.len;
    if (n == 0) return;

    const State = struct {
        index: u32 = undefined,
        lowlink: u32 = undefined,
        on_stack: bool = false,
        visited: bool = false,
    };
    const states = try allocator.alloc(State, n);
    @memset(states, .{});
    var tarjan_stack: std.ArrayListUnmanaged(u32) = .empty;
    defer tarjan_stack.deinit(allocator);

    const Frame = struct { v: u32, edge: u32 };
    var frames: std.ArrayListUnmanaged(Frame) = .empty;
    defer frames.deinit(allocator);

    var next_index: u32 = 0;
    var next_scc: u32 = 0;

    var root: u32 = 0;
    while (root < n) : (root += 1) {
        if (states[root].visited) continue;
        try frames.append(allocator, .{ .v = root, .edge = 0 });
        while (frames.items.len > 0) {
            const frame = &frames.items[frames.items.len - 1];
            const v = frame.v;
            if (frame.edge == 0) {
                states[v].visited = true;
                states[v].index = next_index;
                states[v].lowlink = next_index;
                next_index += 1;
                states[v].on_stack = true;
                try tarjan_stack.append(allocator, v);
            }
            // Advance to the next unvisited same-cluster edge.
            const frees = graph.bindings[v].free.items;
            var advanced = false;
            while (frame.edge < frees.len) {
                const e = frees[frame.edge];
                frame.edge += 1;
                if (e.class != .cluster) continue;
                const w = e.binding;
                if (!states[w].visited) {
                    try frames.append(allocator, .{ .v = w, .edge = 0 });
                    advanced = true;
                    break;
                }
                if (states[w].on_stack) {
                    states[v].lowlink = @min(states[v].lowlink, states[w].index);
                }
            }
            if (advanced) continue;

            // v is finished: pop an SCC if v is a root. Tarjan emits SCCs in
            // reverse topological order of the condensation, so ascending
            // `scc` indices process dependencies before their dependents.
            if (states[v].lowlink == states[v].index) {
                const scc_start = blk: {
                    var i = tarjan_stack.items.len;
                    while (true) {
                        i -= 1;
                        if (tarjan_stack.items[i] == v) break :blk i;
                    }
                };
                const members = tarjan_stack.items[scc_start..];
                for (members) |w| {
                    states[w].on_stack = false;
                    graph.bindings[w].scc = next_scc;
                    if (members.len > 1) graph.bindings[w].scc_recursive = true;
                }
                tarjan_stack.shrinkRetainingCapacity(scc_start);
                next_scc += 1;
            }
            _ = frames.pop();
            if (frames.items.len > 0) {
                const parent = &frames.items[frames.items.len - 1];
                states[parent.v].lowlink = @min(states[parent.v].lowlink, states[v].lowlink);
            }
        }
    }
    for (graph.bindings) |*b| {
        if (b.self_ref) b.scc_recursive = true;
    }
}
