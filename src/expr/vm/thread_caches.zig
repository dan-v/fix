//! Lazily allocated caches owned by an evaluator OS thread.
//!
//! These used to be large `threadlocal` arrays. Static TLS made every thread
//! carry ~840 KiB of evaluator-only storage, including threads that never
//! execute VM code. Keep only one pointer in TLS and allocate the
//! cache bundle when an evaluator worker first registers or uses it.

const std = @import("std");
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const Chunk = @import("../bytecode.zig").chunk.Chunk;

pub const memo_size: usize = 1 << 14;
pub const attr_cache_size: usize = 8192;
pub const call_ic_size: usize = 256;

pub const MemoSlot = struct {
    token: u64,
    chunk: u32,
    count: u8,
    up0: u64,
    up1: u64,
    value: Value,
};

pub const AttrCacheSlot = struct {
    heap_token: u64,
    obj_id: types.ObjectId,
    name_id: types.InternId,
    value: Value,
};

pub const CallICSlot = struct {
    heap_token: u64,
    caller_chunk_id: types.ChunkId,
    caller_ip: u32,
    callee_chunk_id: types.ChunkId,
    callee_ch_ptr: ?*const Chunk,
};

pub const Caches = struct {
    thunk_memo: [memo_size]MemoSlot,
    attr_cache: [attr_cache_size]AttrCacheSlot,
    call_ic: [call_ic_size]CallICSlot,
};

threadlocal var local: ?*Caches = null;

const max_workers = 256;
var registry: [max_workers]?*Caches = @splat(null);

/// Return this OS thread's cache bundle, allocating it on first VM use.
/// Zero is the empty sentinel for every cache's heap token, so byte-zeroing is
/// sufficient and avoids materializing the tagged `Value.null_val` across
/// hundreds of thousands of initialized TLS bytes.
pub fn get() *Caches {
    if (local) |caches| return caches;
    const caches = std.heap.c_allocator.create(Caches) catch @panic("VM thread cache allocation failed");
    @memset(std.mem.asBytes(caches), 0);
    local = caches;
    return caches;
}

/// Publish this worker's cache roots for the stop-the-world collector.
pub fn register(worker_id: u8) void {
    registry[worker_id] = get();
}

/// Remove the collector-visible pointer and release this OS thread's bundle.
/// Idempotent so worker teardown can be structural even when its run loop
/// already unregistered on exit.
pub fn unregister(worker_id: u8) void {
    registry[worker_id] = null;
    if (local) |caches| {
        std.heap.c_allocator.destroy(caches);
        local = null;
    }
}

pub fn registered() []const ?*Caches {
    return &registry;
}
