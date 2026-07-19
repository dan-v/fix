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
const FileCache = @import("store").FileCache;
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

/// One physical frame together with the VM whose stack owns it. Imported files
/// run in synchronous nested VMs, so a logical debugger stack may cross more
/// than one physical frame array.
pub const FrameRef = struct {
    vm: *VM,
    index: usize,

    pub fn frame(self: FrameRef) *@import("../vm/context.zig").Frame {
        return &self.vm.frames[self.index];
    }
};

pub fn frameCount(vm: *const VM) usize {
    var total: usize = vm.frames_len;
    var cursor = vm.debug_parent;
    while (cursor) |parent| : (cursor = parent.debug_parent) total += parent.frames_len;
    return total;
}

/// Resolve logical frame `i` (outermost = 0) through the import-parent chain.
pub fn frameRef(vm: *VM, i: usize) FrameRef {
    const parent_count = if (vm.debug_parent) |parent| frameCount(parent) else 0;
    if (i < parent_count) return frameRef(vm.debug_parent.?, i);
    return .{ .vm = vm, .index = i - parent_count };
}

pub fn frame(ctx: Context, i: usize) DebugFrame {
    const ref = frameRef(ctx.vm, i);
    const f = ref.frame();
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
    const f = frameRef(ctx.vm, i).frame();
    const span = bytecode.inspect.frameSpan(f.chunk_ptr, f.ip) orelse return ctx.source;
    if (span.file) |fid| return ctx.files.readFile(ctx.intern.get(fid)) catch ctx.source;
    return ctx.source;
}

pub fn step(ctx: Context, kind: StepKind) !void {
    const bp = ctx.breakpoints orelse return;
    const depth = frameCount(ctx.vm);
    if (depth == 0) return;
    const depth_u32: u32 = @intCast(depth);
    const cur = frameRef(ctx.vm, depth - 1).frame();

    var sites: std.ArrayListUnmanaged(bytecode.BreakpointTable.Site) = .empty;
    defer sites.deinit(ctx.allocator);
    const max_depth: u32 = switch (kind) {
        .out => depth_u32 - 1,
        .over => depth_u32,
        .into => std.math.maxInt(u32),
    };

    if (kind != .out) {
        const cur_span = bytecode.inspect.frameSpan(cur.chunk_ptr, cur.ip);
        for (cur.chunk_ptr.source_map) |entry| {
            if (cur_span) |span| if (sameSpan(entry.span, span)) continue;
            try sites.append(ctx.allocator, .{ .chunk_id = cur.chunk_id, .offset = entry.start });
        }
    }
    if (depth >= 2) {
        const caller = frameRef(ctx.vm, depth - 2).frame();
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
    try bp.armStep(ctx.registry, sites.items, max_depth, kind == .into);
}

pub fn scopeAttrs(ctx: Context) !Value {
    const count = frameCount(ctx.vm);
    if (count == 0) return bindValue(ctx, "it");

    var map: std.AutoArrayHashMapUnmanaged(types.InternId, Value) = .empty;
    defer map.deinit(ctx.allocator);
    for (0..count) |i| collectWithScopes(ctx, &map, i) catch {};
    for (0..count) |i| try collectFrameBindings(ctx, &map, i);
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
    const ref = frameRef(ctx.vm, i);
    const f = ref.frame();
    if (ctx.registry.upvalueNamesOf(f.chunk_id)) |names| if (f.upvalues) |ups| {
        for (names, 0..) |nid, idx| {
            if (idx >= ups.len) break;
            if (std.mem.eql(u8, ctx.intern.get(nid), compiler.with_capture_name)) try mergeWithAttrs(ctx, map, ups[idx]);
        }
    };
    if (ctx.registry.localNamesOf(f.chunk_id)) |names| {
        for (names, 0..) |nid, slot| {
            if (slot >= f.local_count) break;
            if (ctx.intern.get(nid).len == 0) try mergeWithAttrs(ctx, map, ref.vm.stack[f.frame_base + slot]);
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
    const ref = frameRef(ctx.vm, i);
    const f = ref.frame();
    if (ctx.registry.upvalueNamesOf(f.chunk_id)) |names| if (f.upvalues) |ups| {
        for (names, 0..) |nid, idx| {
            if (idx >= ups.len) break;
            if (displayName(ctx.intern.get(nid)) != null) try map.put(ctx.allocator, nid, ups[idx]);
        }
    };
    if (ctx.registry.localNamesOf(f.chunk_id)) |names| {
        for (names, 0..) |nid, slot| {
            if (slot >= f.local_count) break;
            if (displayName(ctx.intern.get(nid)) != null) try map.put(ctx.allocator, nid, ref.vm.stack[f.frame_base + slot]);
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

fn sameSpan(a: bytecode.chunk.Chunk.SourceSpan, b: bytecode.chunk.Chunk.SourceSpan) bool {
    return a.file == b.file and a.offset == b.offset and a.len == b.len;
}
