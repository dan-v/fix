//! Unified, presentation-independent references between bytecode chunks and
//! runtime heap objects.
//!
//! The graph is a cold-path explorer index. It reads immutable chunks and a
//! live-object snapshot while evaluation is idle, and never forces values.

const std = @import("std");
const engine = @import("expr");
const runtime = @import("runtime");

const Evaluator = engine.Evaluator;
const ChunkId = runtime.types.ChunkId;
const ObjectId = runtime.types.ObjectId;
const object_tag: u64 = @as(u64, 1) << 63;

pub const Node = union(enum) {
    chunk: ChunkId,
    object: ObjectId,
};

pub const NodeKey = u64;

pub const Edge = struct {
    source: NodeKey,
    target: NodeKey,
};

pub fn key(reference_node: Node) NodeKey {
    return switch (reference_node) {
        .chunk => |id| id,
        .object => |id| object_tag | id,
    };
}

pub fn node(encoded: NodeKey) Node {
    return if (encoded & object_tag != 0)
        .{ .object = @intCast(encoded & ~object_tag) }
    else
        .{ .chunk = @intCast(encoded) };
}

pub const Graph = struct {
    out_edges: []Edge,
    inc_edges: []Edge,
    registry_count: u32,
    object_high_water: u32,
    allocator: std.mem.Allocator,

    pub fn build(allocator: std.mem.Allocator, ev: *const Evaluator) !Graph {
        var snapshot = try ev.heapObjectSnapshot(allocator);
        defer snapshot.deinit();

        var edges: std.ArrayListUnmanaged(Edge) = .empty;
        errdefer edges.deinit(allocator);
        var refs: std.ArrayListUnmanaged(ChunkId) = .empty;
        defer refs.deinit(allocator);
        const registry = ev.chunkRegistry();
        const registry_count = registry.count();

        var chunk_id: ChunkId = 0;
        while (chunk_id < registry_count) : (chunk_id += 1) {
            const chunk = registry.get(chunk_id) orelse continue;
            refs.clearRetainingCapacity();
            try engine.bytecode.inspect.collectRefs(allocator, chunk, &refs);
            for (refs.items) |target|
                try appendLiveEdge(&edges, allocator, &snapshot, registry, .{ .chunk = chunk_id }, .{ .chunk = target });
            for (chunk.constants) |value| switch (ev.valueRef(value).target) {
                .object => |target| try appendLiveEdge(&edges, allocator, &snapshot, registry, .{ .chunk = chunk_id }, .{ .object = target }),
                .chunk => |target| try appendLiveEdge(&edges, allocator, &snapshot, registry, .{ .chunk = chunk_id }, .{ .chunk = target }),
                .none, .intern, .builtin => {},
            };
        }

        var heap_refs: std.ArrayListUnmanaged(runtime.heap.HeapReference) = .empty;
        defer heap_refs.deinit(allocator);
        var object_id = snapshot.nextLive(0);
        while (object_id) |id| : (object_id = snapshot.nextLive(id + 1)) {
            heap_refs.clearRetainingCapacity();
            try ev.collectHeapObjectReferences(&snapshot, id, allocator, &heap_refs);
            for (heap_refs.items) |reference| switch (reference) {
                .object => |target| try appendLiveEdge(&edges, allocator, &snapshot, registry, .{ .object = id }, .{ .object = target }),
                .chunk => |target| try appendLiveEdge(&edges, allocator, &snapshot, registry, .{ .object = id }, .{ .chunk = target }),
            };
        }

        sortAndDeduplicate(&edges);
        const out_edges = try edges.toOwnedSlice(allocator);
        errdefer allocator.free(out_edges);
        const inc_edges = try allocator.alloc(Edge, out_edges.len);
        errdefer allocator.free(inc_edges);
        for (out_edges, inc_edges) |edge, *reverse|
            reverse.* = .{ .source = edge.target, .target = edge.source };
        std.mem.sort(Edge, inc_edges, {}, edgeLessThan);

        return .{
            .out_edges = out_edges,
            .inc_edges = inc_edges,
            .registry_count = registry_count,
            .object_high_water = snapshot.high_water,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Graph) void {
        self.allocator.free(self.out_edges);
        self.allocator.free(self.inc_edges);
        self.* = undefined;
    }

    pub fn outgoing(self: *const Graph, source: Node) []const Edge {
        return edgeRange(self.out_edges, key(source));
    }

    pub fn incoming(self: *const Graph, target: Node) []const Edge {
        return edgeRange(self.inc_edges, key(target));
    }
};

fn appendLiveEdge(
    edges: *std.ArrayListUnmanaged(Edge),
    allocator: std.mem.Allocator,
    snapshot: *const runtime.ObjectHeap.ObjectSnapshot,
    registry: *const engine.bytecode.ChunkRegistry,
    source: Node,
    target: Node,
) !void {
    const live = switch (target) {
        .object => |id| snapshot.isLive(id),
        .chunk => |id| registry.get(id) != null,
    };
    if (live) try edges.append(allocator, .{ .source = key(source), .target = key(target) });
}

fn edgeLessThan(_: void, a: Edge, b: Edge) bool {
    return a.source < b.source or (a.source == b.source and a.target < b.target);
}

fn sortAndDeduplicate(edges: *std.ArrayListUnmanaged(Edge)) void {
    std.mem.sort(Edge, edges.items, {}, edgeLessThan);
    var write: usize = 0;
    for (edges.items) |edge| {
        if (write > 0 and std.meta.eql(edges.items[write - 1], edge)) continue;
        edges.items[write] = edge;
        write += 1;
    }
    edges.items.len = write;
}

fn edgeRange(edges: []const Edge, source: NodeKey) []const Edge {
    var low: usize = 0;
    var high: usize = edges.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (edges[mid].source < source)
            low = mid + 1
        else
            high = mid;
    }
    const start = low;
    while (low < edges.len and edges[low].source == source) : (low += 1) {}
    return edges[start..low];
}

test "reference adjacency is sorted, deduplicated, and reversible" {
    var edges: std.ArrayListUnmanaged(Edge) = .empty;
    defer edges.deinit(std.testing.allocator);
    try edges.appendSlice(std.testing.allocator, &.{
        .{ .source = key(.{ .object = 4 }), .target = key(.{ .chunk = 2 }) },
        .{ .source = key(.{ .chunk = 1 }), .target = key(.{ .object = 4 }) },
        .{ .source = key(.{ .object = 4 }), .target = key(.{ .chunk = 2 }) },
        .{ .source = key(.{ .object = 4 }), .target = key(.{ .object = 9 }) },
    });
    sortAndDeduplicate(&edges);

    const object_edges = edgeRange(edges.items, key(.{ .object = 4 }));
    try std.testing.expectEqual(@as(usize, 2), object_edges.len);
    try std.testing.expectEqualDeep(Node{ .chunk = 2 }, node(object_edges[0].target));
    try std.testing.expectEqualDeep(Node{ .object = 9 }, node(object_edges[1].target));
}
