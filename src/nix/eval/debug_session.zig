//! Debug-session algorithms over an explicit paused-evaluation view. This file
//! does not know the Evaluator type and does not use duck-typed private access.

const std = @import("std");
const runtime = @import("runtime");
const types = runtime.types;
const Value = runtime.value.Value;
const bytecode = @import("../bytecode.zig");
const compiler = @import("../compiler.zig");
const VM = @import("../vm.zig").VM;
const vm_force = @import("../vm.zig").force;
const FileCache = @import("../host.zig").FileCache;
const InternTable = runtime.intern.InternTable;
const ObjectHeap = runtime.heap.ObjectHeap;

pub const StepKind = enum { over, into, out };

pub const Context = struct {
    allocator: std.mem.Allocator,
    heap: *ObjectHeap,
    intern: *InternTable,
    registry: *bytecode.ChunkRegistry,
    files: *FileCache,
    breakpoints: ?*bytecode.BreakpointTable,
    source: ?[]const u8,
    vm: *VM,
    value: Value,
};

pub const DebugFrame = struct {
    chunk_id: types.ChunkId,
    file: ?[]const u8,
    line: u32,
    column: u32,
    span: ?bytecode.chunk.Chunk.SourceSpan,
};

pub fn frame(ctx: Context, i: usize) DebugFrame {
    const f = &ctx.vm.frames[i];
    const span = bytecode.inspect.frameSpan(f.chunk_ptr, f.ip);
    const file_id = if (span) |s| s.file else bytecode.inspect.chunkPrimaryFile(f.chunk_ptr, f.chunk_id, ctx.registry);
    return .{
        .chunk_id = f.chunk_id,
        .file = if (file_id) |fid| ctx.intern.get(fid) else null,
        .line = if (span) |s| s.line else 0,
        .column = if (span) |s| s.column else 0,
        .span = span,
    };
}

pub fn frameSourceText(ctx: Context, i: usize) ?[]const u8 {
    const f = &ctx.vm.frames[i];
    const span = bytecode.inspect.frameSpan(f.chunk_ptr, f.ip) orelse return ctx.source;
    if (span.file) |fid| return ctx.files.readFile(ctx.intern.get(fid)) catch ctx.source;
    return ctx.source;
}

pub fn step(ctx: Context, kind: StepKind) !void {
    const bp = ctx.breakpoints orelse return;
    const depth = ctx.vm.frames_len;
    if (depth == 0) return;
    const cur = &ctx.vm.frames[depth - 1];

    var sites: std.ArrayListUnmanaged(bytecode.BreakpointTable.Site) = .empty;
    defer sites.deinit(ctx.allocator);
    const max_depth: u32 = switch (kind) {
        .out => if (depth >= 1) depth - 1 else 0,
        .over => depth,
        .into => std.math.maxInt(u32),
    };

    if (kind != .out) {
        const cur_line: u32 = if (bytecode.inspect.frameSpan(cur.chunk_ptr, cur.ip)) |s| s.line else 0;
        for (cur.chunk_ptr.source_map) |entry| {
            if (entry.span.line == cur_line) continue;
            try sites.append(ctx.allocator, .{ .chunk_id = cur.chunk_id, .offset = entry.start });
        }
    }
    if (depth >= 2) {
        const caller = &ctx.vm.frames[depth - 2];
        try sites.append(ctx.allocator, .{ .chunk_id = caller.chunk_id, .offset = @intCast(caller.ip) });
    }
    if (kind == .into) {
        var refs: std.ArrayListUnmanaged(types.ChunkId) = .empty;
        defer refs.deinit(ctx.allocator);
        bytecode.inspect.collectRefs(ctx.allocator, cur.chunk_ptr, &refs) catch {};
        for (refs.items) |rid| {
            const chunk = ctx.registry.get(rid) orelse continue;
            if (firstMappedOffset(chunk)) |off| try sites.append(ctx.allocator, .{ .chunk_id = rid, .offset = off });
        }
    }
    try bp.armStep(ctx.registry, sites.items, max_depth);
}

pub fn scopeAttrs(ctx: Context) !Value {
    if (ctx.vm.frames_len == 0) return bindValue(ctx, "it");

    var map: std.AutoArrayHashMapUnmanaged(types.InternId, Value) = .empty;
    defer map.deinit(ctx.allocator);
    for (0..ctx.vm.frames_len) |i| collectWithScopes(ctx, &map, i) catch {};
    for (0..ctx.vm.frames_len) |i| try collectFrameBindings(ctx, &map, i);
    try map.put(ctx.allocator, try ctx.intern.intern("it"), ctx.value);

    var entries: std.ArrayListUnmanaged(runtime.heap.AttrEntry) = .empty;
    defer entries.deinit(ctx.allocator);
    var it = map.iterator();
    while (it.next()) |entry| try entries.append(ctx.allocator, .{ .name = entry.key_ptr.*, .value = entry.value_ptr.* });
    return Value.attrs(try ctx.heap.addAttrs(entries.items));
}

fn bindValue(ctx: Context, name: []const u8) !Value {
    const entries = [_]runtime.heap.AttrEntry{.{ .name = try ctx.intern.intern(name), .value = ctx.value }};
    return Value.attrs(try ctx.heap.addAttrs(&entries));
}

fn collectWithScopes(ctx: Context, map: *std.AutoArrayHashMapUnmanaged(types.InternId, Value), i: usize) !void {
    const f = &ctx.vm.frames[i];
    if (ctx.registry.upvalueNamesOf(f.chunk_id)) |names| if (f.upvalues) |ups| {
        for (names, 0..) |nid, idx| {
            if (idx >= ups.len) break;
            if (std.mem.eql(u8, ctx.intern.get(nid), compiler.with_capture_name)) try mergeWithAttrs(ctx, map, ups[idx]);
        }
    };
    if (ctx.registry.localNamesOf(f.chunk_id)) |names| {
        for (names, 0..) |nid, slot| {
            if (slot >= f.local_count) break;
            if (ctx.intern.get(nid).len == 0) try mergeWithAttrs(ctx, map, ctx.vm.stack[f.frame_base + slot]);
        }
    }
}

fn mergeWithAttrs(ctx: Context, map: *std.AutoArrayHashMapUnmanaged(types.InternId, Value), subject: Value) !void {
    const forced = vm_force.forceValue(ctx.vm, subject) catch return;
    if (!forced.isAttrs()) return;
    const entries = ctx.heap.getAttrs(forced.asObjectId()) catch return;
    for (entries) |entry| try map.put(ctx.allocator, entry.name, entry.value);
}

fn collectFrameBindings(ctx: Context, map: *std.AutoArrayHashMapUnmanaged(types.InternId, Value), i: usize) !void {
    const f = &ctx.vm.frames[i];
    if (ctx.registry.upvalueNamesOf(f.chunk_id)) |names| if (f.upvalues) |ups| {
        for (names, 0..) |nid, idx| {
            if (idx >= ups.len) break;
            if (displayName(ctx.intern.get(nid)) != null) try map.put(ctx.allocator, nid, ups[idx]);
        }
    };
    if (ctx.registry.localNamesOf(f.chunk_id)) |names| {
        for (names, 0..) |nid, slot| {
            if (slot >= f.local_count) break;
            if (displayName(ctx.intern.get(nid)) != null) try map.put(ctx.allocator, nid, ctx.vm.stack[f.frame_base + slot]);
        }
    }
}

pub fn displayName(text: []const u8) ?[]const u8 {
    if (text.len == 0 or text[0] == 0) return null;
    return text;
}

fn firstMappedOffset(chunk: *const bytecode.chunk.Chunk) ?u32 {
    var best: ?u32 = null;
    for (chunk.source_map) |entry| {
        if (best == null or entry.start < best.?) best = entry.start;
    }
    return best;
}
