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
    out: []std.ArrayListUnmanaged(ChunkId),
    inc: []std.ArrayListUnmanaged(ChunkId),
    allocator: std.mem.Allocator,

    pub fn build(allocator: std.mem.Allocator, registry: *const ChunkRegistry) !RefGraph {
        const n = registry.count();
        const out = try allocator.alloc(std.ArrayListUnmanaged(ChunkId), n);
        const inc = try allocator.alloc(std.ArrayListUnmanaged(ChunkId), n);
        for (out) |*list| list.* = .empty;
        for (inc) |*list| list.* = .empty;

        var refs: std.AutoArrayHashMapUnmanaged(ChunkId, void) = .empty;
        defer refs.deinit(allocator);
        var id: ChunkId = 0;
        while (id < n) : (id += 1) {
            const chunk = registry.get(id) orelse continue;
            refs.clearRetainingCapacity();
            collectRefsInto(chunk, &refs, allocator) catch continue;
            for (refs.keys()) |target| {
                out[id].append(allocator, target) catch {};
                if (target < n) inc[target].append(allocator, id) catch {};
            }
        }
        for (out) |*list| std.mem.sort(ChunkId, list.items, {}, std.sort.asc(ChunkId));
        for (inc) |*list| std.mem.sort(ChunkId, list.items, {}, std.sort.asc(ChunkId));
        return .{ .out = out, .inc = inc, .allocator = allocator };
    }

    pub fn deinit(self: *RefGraph) void {
        for (self.out) |*list| list.deinit(self.allocator);
        for (self.inc) |*list| list.deinit(self.allocator);
        self.allocator.free(self.out);
        self.allocator.free(self.inc);
    }

    pub fn outgoing(self: *const RefGraph, id: ChunkId) []const ChunkId {
        return if (id < self.out.len) self.out[id].items else &.{};
    }

    pub fn incoming(self: *const RefGraph, id: ChunkId) []const ChunkId {
        return if (id < self.inc.len) self.inc[id].items else &.{};
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
            .thunk, .thunk_eag, .closure_cap => ip + 2,
            .thunk_w, .thunk_eag_w, .closure_cap_w, .thunk_arg => ip + 4,
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
