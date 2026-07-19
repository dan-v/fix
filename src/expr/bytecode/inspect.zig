//! Presentation-independent bytecode inspection.
//!
//! Reference traversal, capture-layout analysis, and source-location lookup
//! live here so the evaluator/debugger does not depend on the textual
//! disassembler.

const std = @import("std");
const chunk_mod = @import("chunk.zig");
const opcode = @import("opcode.zig");
const encoding = @import("encoding.zig");
const types = @import("runtime").types;

const Chunk = chunk_mod.Chunk;
const ChunkRegistry = chunk_mod.ChunkRegistry;
const ChunkId = types.ChunkId;
const InternId = types.InternId;
const NameId = @import("name_tree.zig").NameId;
const root_name_id = @import("name_tree.zig").root_name_id;

fn readWidth(width: opcode.Width, code: []const u8, ip: usize) u32 {
    return switch (width) {
        .b1 => code[ip],
        .b2 => encoding.readU16(code, ip),
        .b4 => encoding.readU32(code, ip),
    };
}

fn collectRefsInto(chunk: *const Chunk, refs: *std.AutoArrayHashMapUnmanaged(ChunkId, void), allocator: std.mem.Allocator) !void {
    var ip: usize = 0;
    while (ip < chunk.code.len) {
        const op_byte = chunk.code[ip];
        if (op_byte >= opcode.count) {
            ip += 1;
            continue;
        }
        const op: opcode.OpCode = @enumFromInt(op_byte);
        ip += 1;
        for (opcode.layout(op)) |field| {
            switch (field) {
                .chunk_id => |width| try refs.put(allocator, @intCast(readWidth(width, chunk.code, ip)), {}),
                else => {},
            }
            ip += opcode.fieldLen(field, chunk.code, ip);
        }
    }
}

/// Collect referenced chunks in first-appearance order, deduplicated.
pub fn collectRefs(allocator: std.mem.Allocator, chunk: *const Chunk, out: *std.ArrayListUnmanaged(ChunkId)) !void {
    var refs: std.AutoArrayHashMapUnmanaged(ChunkId, void) = .empty;
    defer refs.deinit(allocator);
    try collectRefsInto(chunk, &refs, allocator);
    try out.ensureUnusedCapacity(allocator, refs.count());
    for (refs.keys()) |id| out.appendAssumeCapacity(id);
}

/// Whole-registry incoming/outgoing chunk reference graph.
pub const RefGraph = struct {
    out_offsets: []u32,
    out_edges: []ChunkId,
    inc_offsets: []u32,
    inc_edges: []ChunkId,
    registry_count: u32,
    allocator: std.mem.Allocator,

    pub fn build(allocator: std.mem.Allocator, registry: *const ChunkRegistry) !RefGraph {
        const registry_count = registry.count();
        const n: usize = registry_count;
        const out_offsets = try allocator.alloc(u32, n + 1);
        errdefer allocator.free(out_offsets);
        const inc_offsets = try allocator.alloc(u32, n + 1);
        errdefer allocator.free(inc_offsets);
        @memset(out_offsets, 0);
        @memset(inc_offsets, 0);

        var refs: std.AutoArrayHashMapUnmanaged(ChunkId, void) = .empty;
        defer refs.deinit(allocator);
        var id: ChunkId = 0;
        while (id < registry_count) : (id += 1) {
            const chunk = registry.get(id) orelse continue;
            refs.clearRetainingCapacity();
            collectRefsInto(chunk, &refs, allocator) catch continue;
            out_offsets[@as(usize, id) + 1] = @intCast(refs.count());
            for (refs.keys()) |target| {
                if (target < registry_count) inc_offsets[@as(usize, target) + 1] += 1;
            }
        }
        prefixSum(out_offsets);
        prefixSum(inc_offsets);

        const out_edges = try allocator.alloc(ChunkId, out_offsets[n]);
        errdefer allocator.free(out_edges);
        const inc_edges = try allocator.alloc(ChunkId, inc_offsets[n]);
        errdefer allocator.free(inc_edges);
        const out_cursor = try allocator.dupe(u32, out_offsets[0..n]);
        defer allocator.free(out_cursor);
        const inc_cursor = try allocator.dupe(u32, inc_offsets[0..n]);
        defer allocator.free(inc_cursor);

        id = 0;
        while (id < registry_count) : (id += 1) {
            const chunk = registry.get(id) orelse continue;
            refs.clearRetainingCapacity();
            collectRefsInto(chunk, &refs, allocator) catch continue;
            for (refs.keys()) |target| {
                out_edges[out_cursor[id]] = target;
                out_cursor[id] += 1;
                if (target < registry_count) {
                    inc_edges[inc_cursor[target]] = id;
                    inc_cursor[target] += 1;
                }
            }
        }
        for (0..n) |i| {
            std.mem.sort(ChunkId, out_edges[out_offsets[i]..out_offsets[i + 1]], {}, std.sort.asc(ChunkId));
            std.mem.sort(ChunkId, inc_edges[inc_offsets[i]..inc_offsets[i + 1]], {}, std.sort.asc(ChunkId));
        }
        return .{
            .out_offsets = out_offsets,
            .out_edges = out_edges,
            .inc_offsets = inc_offsets,
            .inc_edges = inc_edges,
            .registry_count = registry_count,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RefGraph) void {
        self.allocator.free(self.out_offsets);
        self.allocator.free(self.out_edges);
        self.allocator.free(self.inc_offsets);
        self.allocator.free(self.inc_edges);
        self.* = undefined;
    }

    pub fn outgoing(self: *const RefGraph, id: ChunkId) []const ChunkId {
        if (id >= self.registry_count) return &.{};
        return self.out_edges[self.out_offsets[id]..self.out_offsets[@as(usize, id) + 1]];
    }

    pub fn incoming(self: *const RefGraph, id: ChunkId) []const ChunkId {
        if (id >= self.registry_count) return &.{};
        return self.inc_edges[self.inc_offsets[id]..self.inc_offsets[@as(usize, id) + 1]];
    }
};

fn prefixSum(offsets: []u32) void {
    var i: usize = 1;
    while (i < offsets.len) : (i += 1) offsets[i] += offsets[i - 1];
}

/// Compact, cold-path projection of the registry's parent-linked name tree.
///
/// Name construction stays append-only and allocation-minimal on compiler
/// threads. An explorer builds this reverse index only when needed, gaining
/// parent -> children and name -> chunks ranges plus subtree aggregates. The
/// arrays are CSR-shaped: one allocation per relation, not one allocation per
/// name, which keeps million-node evaluations practical.
pub const NameIndex = struct {
    pub const Node = struct {
        parent: NameId,
        segment: InternId,
        synthetic: bool,
    };

    pub const Stats = struct {
        chunks: u64 = 0,
        code_bytes: u64 = 0,
        constants: u64 = 0,
        attr_names: u64 = 0,
        attr_positions: u64 = 0,
        capture_bytes: u64 = 0,

        fn add(self: *Stats, other: Stats) void {
            self.chunks += other.chunks;
            self.code_bytes += other.code_bytes;
            self.constants += other.constants;
            self.attr_names += other.attr_names;
            self.attr_positions += other.attr_positions;
            self.capture_bytes += other.capture_bytes;
        }
    };

    allocator: std.mem.Allocator,
    /// Includes the implicit root at index zero.
    nodes: []Node,
    child_offsets: []u32,
    children: []NameId,
    chunk_offsets: []u32,
    chunks: []ChunkId,
    subtree: []Stats,
    /// Registry prefix represented by this immutable generation.
    registry_count: u32,
    name_count: u32,

    pub fn build(allocator: std.mem.Allocator, registry: *const ChunkRegistry) !NameIndex {
        // Capture append-only upper bounds. A concurrently registered chunk
        // whose name lies past `name_count` is conservatively attached to the
        // root in this generation; the next refresh places it precisely.
        const name_count = registry.nameCount();
        const registry_count = registry.count();
        const node_len: usize = @as(usize, name_count) + 1;

        const nodes = try allocator.alloc(Node, node_len);
        errdefer allocator.free(nodes);
        nodes[0] = .{ .parent = root_name_id, .segment = 0, .synthetic = false };
        var name: NameId = 1;
        while (name <= name_count) : (name += 1) {
            const n = registry.nameNode(name) orelse {
                nodes[name] = .{ .parent = root_name_id, .segment = 0, .synthetic = true };
                continue;
            };
            nodes[name] = .{ .parent = n.parent, .segment = n.segment, .synthetic = n.synthetic };
        }

        const child_offsets = try allocator.alloc(u32, node_len + 1);
        errdefer allocator.free(child_offsets);
        @memset(child_offsets, 0);
        name = 1;
        while (name <= name_count) : (name += 1) {
            const parent = if (nodes[name].parent <= name_count) nodes[name].parent else root_name_id;
            child_offsets[@as(usize, parent) + 1] += 1;
        }
        prefixSum(child_offsets);

        const children = try allocator.alloc(NameId, child_offsets[node_len]);
        errdefer allocator.free(children);
        const child_cursor = try allocator.dupe(u32, child_offsets[0..node_len]);
        defer allocator.free(child_cursor);
        name = 1;
        while (name <= name_count) : (name += 1) {
            const parent = if (nodes[name].parent <= name_count) nodes[name].parent else root_name_id;
            const at = child_cursor[parent];
            children[at] = name;
            child_cursor[parent] = at + 1;
        }

        const chunk_offsets = try allocator.alloc(u32, node_len + 1);
        errdefer allocator.free(chunk_offsets);
        @memset(chunk_offsets, 0);
        var chunk_id: ChunkId = 0;
        while (chunk_id < registry_count) : (chunk_id += 1) {
            const attached = normalizedName(registry.nameOf(chunk_id) orelse root_name_id, name_count);
            chunk_offsets[@as(usize, attached) + 1] += 1;
        }
        prefixSum(chunk_offsets);

        const chunks = try allocator.alloc(ChunkId, chunk_offsets[node_len]);
        errdefer allocator.free(chunks);
        const chunk_cursor = try allocator.dupe(u32, chunk_offsets[0..node_len]);
        defer allocator.free(chunk_cursor);
        chunk_id = 0;
        while (chunk_id < registry_count) : (chunk_id += 1) {
            const attached = normalizedName(registry.nameOf(chunk_id) orelse root_name_id, name_count);
            const at = chunk_cursor[attached];
            chunks[at] = chunk_id;
            chunk_cursor[attached] = at + 1;
        }

        const subtree = try allocator.alloc(Stats, node_len);
        errdefer allocator.free(subtree);
        @memset(subtree, .{});
        chunk_id = 0;
        while (chunk_id < registry_count) : (chunk_id += 1) {
            const chunk = registry.get(chunk_id) orelse continue;
            const attached = normalizedName(registry.nameOf(chunk_id) orelse root_name_id, name_count);
            subtree[attached].add(.{
                .chunks = 1,
                .code_bytes = chunk.code.len,
                .constants = chunk.constants.len,
                .attr_names = chunk.attr_names.len,
                .attr_positions = chunk.attr_pos.len,
                .capture_bytes = chunk.capture_bytes.len,
            });
        }
        // Parent ids precede children by construction, so one reverse pass
        // produces exact subtree totals.
        var reverse: usize = node_len;
        while (reverse > 1) {
            reverse -= 1;
            const parent = normalizedName(nodes[reverse].parent, name_count);
            subtree[parent].add(subtree[reverse]);
        }

        return .{
            .allocator = allocator,
            .nodes = nodes,
            .child_offsets = child_offsets,
            .children = children,
            .chunk_offsets = chunk_offsets,
            .chunks = chunks,
            .subtree = subtree,
            .registry_count = registry_count,
            .name_count = name_count,
        };
    }

    pub fn deinit(self: *NameIndex) void {
        self.allocator.free(self.nodes);
        self.allocator.free(self.child_offsets);
        self.allocator.free(self.children);
        self.allocator.free(self.chunk_offsets);
        self.allocator.free(self.chunks);
        self.allocator.free(self.subtree);
        self.* = undefined;
    }

    pub fn node(self: *const NameIndex, id: NameId) ?Node {
        if (id >= self.nodes.len) return null;
        return self.nodes[id];
    }

    pub fn childrenOf(self: *const NameIndex, id: NameId) []const NameId {
        if (id + 1 >= self.child_offsets.len) return &.{};
        return self.children[self.child_offsets[id]..self.child_offsets[id + 1]];
    }

    pub fn chunksOf(self: *const NameIndex, id: NameId) []const ChunkId {
        if (id + 1 >= self.chunk_offsets.len) return &.{};
        return self.chunks[self.chunk_offsets[id]..self.chunk_offsets[id + 1]];
    }

    pub fn statsOf(self: *const NameIndex, id: NameId) Stats {
        if (id >= self.subtree.len) return .{};
        return self.subtree[id];
    }

    fn normalizedName(id: NameId, max: NameId) NameId {
        return if (id <= max) id else root_name_id;
    }
};

pub const CaptureCensus = struct {
    total: usize = 0,
    duplicated: usize = 0,
    ops: usize = 0,
    dup_defer: usize = 0,
    dup_thunk: usize = 0,
    dup_closure: usize = 0,
    total_ge2: usize = 0,
    ops_ge2: usize = 0,
    dup_ge2: usize = 0,
};

/// Registry-wide body-sharing and capture-list measurements. Kept as data so
/// CLI and future machine-readable reporters share the same analysis.
pub const CodeDedupCensus = struct {
    total: u32 = 0,
    total_code: usize = 0,
    distinct_full: usize = 0,
    dup_full: u32 = 0,
    dup_full_bytes: usize = 0,
    distinct_code: usize = 0,
    dup_code: u32 = 0,
    captures: CaptureCensus = .{},

    pub fn build(allocator: std.mem.Allocator, registry: *const ChunkRegistry) !CodeDedupCensus {
        var by_full: std.AutoHashMapUnmanaged(u64, void) = .empty;
        defer by_full.deinit(allocator);
        var by_code: std.AutoHashMapUnmanaged(u64, void) = .empty;
        defer by_code.deinit(allocator);

        var out: CodeDedupCensus = .{};
        var id: ChunkId = 0;
        while (id < registry.count()) : (id += 1) {
            const chunk = registry.get(id) orelse continue;
            out.total += 1;
            out.total_code += chunk.code.len;

            var full_hash = std.hash.Wyhash.init(0);
            full_hash.update(chunk.code);
            full_hash.update(std.mem.sliceAsBytes(chunk.constants));
            full_hash.update(std.mem.sliceAsBytes(chunk.attr_names));
            full_hash.update(std.mem.asBytes(&chunk.local_count));
            full_hash.update(std.mem.asBytes(&chunk.arity));
            full_hash.update(std.mem.asBytes(&chunk.strict_params));
            if ((try by_full.getOrPut(allocator, full_hash.final())).found_existing) {
                out.dup_full += 1;
                out.dup_full_bytes += chunk.code.len;
            }

            var code_hash = std.hash.Wyhash.init(0);
            code_hash.update(chunk.code);
            code_hash.update(std.mem.asBytes(&chunk.local_count));
            code_hash.update(std.mem.asBytes(&chunk.arity));
            if ((try by_code.getOrPut(allocator, code_hash.final())).found_existing) out.dup_code += 1;

            const captures = captureCensus(allocator, chunk) catch continue;
            inline for (std.meta.fields(CaptureCensus)) |field| {
                @field(out.captures, field.name) += @field(captures, field.name);
            }
        }
        out.distinct_full = by_full.count();
        out.distinct_code = by_code.count();
        return out;
    }
};

/// Measure duplicate inline capture descriptor lists within one chunk.
pub fn captureCensus(allocator: std.mem.Allocator, chunk: *const Chunk) !CaptureCensus {
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer seen.deinit(allocator);

    var out: CaptureCensus = .{};
    var ip: usize = 0;
    while (ip < chunk.code.len) {
        const op_byte = chunk.code[ip];
        if (op_byte >= opcode.count) {
            ip += 1;
            continue;
        }
        const op: opcode.OpCode = @enumFromInt(op_byte);
        ip += 1;
        const list_start: ?usize = switch (op) {
            .thunk, .closure_cap => ip + 2,
            .thunk_w, .closure_cap_w, .thunk_arg => ip + 4,
            else => null,
        };
        const next = ip + opcode.operandLen(op, chunk.code, ip);
        if (list_start) |start| if (start < next) {
            const region = chunk.code[start..next];
            out.total += region.len;
            out.ops += 1;
            const count = if (region.len >= 2) (region.len - 2) / 3 else 0;
            const ge2 = count >= 2;
            if (ge2) {
                out.total_ge2 += region.len;
                out.ops_ge2 += 1;
            }
            if ((try seen.getOrPut(allocator, std.hash.Wyhash.hash(0, region))).found_existing) {
                out.duplicated += region.len;
                if (ge2) out.dup_ge2 += region.len;
                switch (op) {
                    .thunk_defer => out.dup_defer += region.len,
                    .closure_cap, .closure_cap_w => out.dup_closure += region.len,
                    else => out.dup_thunk += region.len,
                }
            }
        };
        ip = next;
    }
    return out;
}

pub fn chunkPrimaryFile(chunk: *const Chunk, chunk_id: ?ChunkId, registry: ?*const ChunkRegistry) ?InternId {
    for (chunk.source_map) |entry| if (entry.span.file) |file| return file;
    if (chunk.body_span) |span| if (span.file) |file| return file;
    if (chunk_id) |id| if (registry) |reg| if (reg.fileOf(id)) |file| return file;
    return null;
}

pub fn bestSpan(chunk: *const Chunk, ip: usize) ?Chunk.SourceSpan {
    var best: ?Chunk.SourceMapEntry = null;
    for (chunk.source_map) |entry| {
        if (ip < entry.start or ip >= entry.end) continue;
        if (best == null or entry.end - entry.start <= best.?.end - best.?.start) best = entry;
    }
    return if (best) |entry| entry.span else null;
}

pub fn frameSpan(chunk: *const Chunk, ip: usize) ?Chunk.SourceSpan {
    var best: ?Chunk.SourceMapEntry = null;
    for (chunk.source_map) |entry| {
        if (ip < entry.start or ip > entry.end) continue;
        if (best == null or entry.end - entry.start <= best.?.end - best.?.start) best = entry;
    }
    if (best) |entry| return entry.span;
    return chunk.body_span;
}

fn indexTestChunk(allocator: std.mem.Allocator, value: i64) !Chunk {
    const Value = @import("runtime").value.Value;
    var builder = try chunk_mod.ChunkBuilder.init(allocator);
    defer builder.deinit(allocator);
    try builder.emitConstant(allocator, Value.int(value));
    try builder.writeOp(allocator, .ret);
    try builder.writeOp(allocator, .halt);
    return builder.finish(allocator, 0);
}

fn refTestChunk(allocator: std.mem.Allocator, targets: []const ChunkId) !Chunk {
    var builder = try chunk_mod.ChunkBuilder.init(allocator);
    defer builder.deinit(allocator);
    for (targets) |target| {
        try builder.writeOp(allocator, .closure);
        try builder.writeU16(allocator, @intCast(target));
        try builder.writeU16(allocator, 0);
    }
    try builder.writeOp(allocator, .ret);
    try builder.writeOp(allocator, .halt);
    return builder.finish(allocator, 0);
}

test "reference graph uses compact ranges for both directions" {
    const testing = std.testing;
    var registry = try ChunkRegistry.init(testing.allocator);
    defer registry.deinit();

    const left = try registry.register(try indexTestChunk(testing.allocator, 1));
    const right = try registry.register(try indexTestChunk(testing.allocator, 2));
    const source = try registry.register(try refTestChunk(testing.allocator, &.{ right, left, right }));

    var graph = try RefGraph.build(testing.allocator, &registry);
    defer graph.deinit();
    try testing.expectEqual(registry.count(), graph.registry_count);
    try testing.expectEqualSlices(ChunkId, &.{ left, right }, graph.outgoing(source));
    try testing.expectEqualSlices(ChunkId, &.{source}, graph.incoming(left));
    try testing.expectEqualSlices(ChunkId, &.{source}, graph.incoming(right));
}

test "name index builds compact child and chunk ranges with subtree totals" {
    const testing = std.testing;
    var registry = try ChunkRegistry.init(testing.allocator);
    defer registry.deinit();

    const pkgs = try registry.childName(root_name_id, 10, false);
    const hello = try registry.childName(pkgs, 11, false);
    const world = try registry.childName(pkgs, 12, false);
    const hello_a = try registry.registerNamed(try indexTestChunk(testing.allocator, 1), hello);
    const hello_b = try registry.registerNamed(try indexTestChunk(testing.allocator, 2), hello);
    const world_a = try registry.registerNamed(try indexTestChunk(testing.allocator, 3), world);

    var index = try NameIndex.build(testing.allocator, &registry);
    defer index.deinit();

    try testing.expectEqualSlices(NameId, &.{pkgs}, index.childrenOf(root_name_id));
    try testing.expectEqualSlices(NameId, &.{ hello, world }, index.childrenOf(pkgs));
    try testing.expectEqualSlices(ChunkId, &.{ hello_a, hello_b }, index.chunksOf(hello));
    try testing.expectEqualSlices(ChunkId, &.{world_a}, index.chunksOf(world));
    try testing.expectEqual(@as(u64, 2), index.statsOf(hello).chunks);
    try testing.expectEqual(@as(u64, 1), index.statsOf(world).chunks);
    try testing.expectEqual(@as(u64, 3), index.statsOf(pkgs).chunks);
    // The root includes the registry's two eagerly-created well-known chunks.
    try testing.expectEqual(@as(u64, 5), index.statsOf(root_name_id).chunks);
    try testing.expectEqual(pkgs, index.node(hello).?.parent);
}
