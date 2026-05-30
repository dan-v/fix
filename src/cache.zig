//! Memoization cache for normalized expressions.
//!
//! The cache maps (chunk_id, env_hash) → Value. When the VM is about to
//! evaluate a chunk, it first checks this cache. If the chunk + environment
//! pair has already been evaluated, the cached result is returned immediately.
//!
//! This is aggressive normalization: identical subexpressions in identical
//! environments are evaluated once and reused.

const std = @import("std");
const types = @import("types.zig");
const Value = @import("value.zig").Value;
const ChunkId = types.ChunkId;
const MemoHash = types.MemoHash;

/// A single entry in the memo table.
const Entry = struct {
    chunk_id: ChunkId,
    env_hash: MemoHash,
    value: Value,
};

/// The memo cache. A simple open-addressing hash table.
/// Thread-safe: all mutations happen under a mutex, reads happen lock-free
/// once entries are written (the Value is immutable after insertion).
pub const MemoCache = struct {
    allocator: std.mem.Allocator,
    entries: []Entry,
    occupied: []bool,
    count: u32,
    capacity: u32,
    mutex: std.atomic.Mutex,

    pub fn init(allocator: std.mem.Allocator, capacity: u32) !MemoCache {
        const entries = try allocator.alloc(Entry, capacity);
        const occupied = try allocator.alloc(bool, capacity);
        @memset(entries, Entry{ .chunk_id = 0, .env_hash = 0, .value = Value.null_val });
        @memset(occupied, false);
        return .{
            .allocator = allocator,
            .entries = entries,
            .occupied = occupied,
            .count = 0,
            .capacity = capacity,
            .mutex = .unlocked,
        };
    }

    pub fn deinit(self: *MemoCache) void {
        self.allocator.free(self.entries);
        self.allocator.free(self.occupied);
    }

    /// Look up a result in the cache. Lock-free read path.
    pub fn get(self: *const MemoCache, chunk_id: ChunkId, env_hash: MemoHash) ?Value {
        var idx = hashKey(chunk_id, env_hash) % self.capacity;
        var i: u32 = 0;
        while (i < self.capacity) : (i += 1) {
            if (!self.occupied[idx]) return null;
            const entry = &self.entries[idx];
            if (entry.chunk_id == chunk_id and entry.env_hash == env_hash) {
                return entry.value;
            }
            idx = (idx + 1) % self.capacity;
        }
        return null;
    }

    /// Insert a result. Must hold the mutex.
    pub fn insert(self: *MemoCache, chunk_id: ChunkId, env_hash: MemoHash, value: Value) anyerror!void {
        // Grow if needed.
        if (self.count * 3 > self.capacity * 2) {
            try self.grow();
        }

        var idx = hashKey(chunk_id, env_hash) % self.capacity;
        while (self.occupied[idx]) {
            const entry = &self.entries[idx];
            if (entry.chunk_id == chunk_id and entry.env_hash == env_hash) {
                // Already present; update in place.
                entry.value = value;
                return;
            }
            idx = (idx + 1) % self.capacity;
        }

        self.entries[idx] = .{ .chunk_id = chunk_id, .env_hash = env_hash, .value = value };
        self.occupied[idx] = true;
        self.count += 1;
    }

    pub fn lock(self: *MemoCache) void {
        while (!std.atomic.Mutex.tryLock(&self.mutex)) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlock(self: *MemoCache) void {
        std.atomic.Mutex.unlock(&self.mutex);
    }

    fn grow(self: *MemoCache) !void {
        const new_cap = self.capacity * 2;
        const new_entries = try self.allocator.alloc(Entry, new_cap);
        const new_occupied = try self.allocator.alloc(bool, new_cap);
        @memset(new_entries, Entry{ .chunk_id = 0, .env_hash = 0, .value = Value.null_val });
        @memset(new_occupied, false);

        // Rehash all existing entries.
        for (self.entries, self.occupied, 0..) |entry, occ, i| {
            _ = i;
            if (!occ) continue;
            var idx = hashKey(entry.chunk_id, entry.env_hash) % new_cap;
            while (new_occupied[idx]) {
                idx = (idx + 1) % new_cap;
            }
            new_entries[idx] = entry;
            new_occupied[idx] = true;
        }

        self.allocator.free(self.entries);
        self.allocator.free(self.occupied);
        self.entries = new_entries;
        self.occupied = new_occupied;
        self.capacity = new_cap;
    }

    fn hashKey(chunk_id: ChunkId, env_hash: MemoHash) u32 {
        var h: u64 = @as(u64, chunk_id) *% 0x9e3779b97f4a7c15;
        h ^= env_hash;
        h = (h ^ (h >> 33)) *% 0xff51afd7ed558ccd;
        h = (h ^ (h >> 33)) *% 0xc4ceb9fe1a85ec53;
        h = h ^ (h >> 33);
        return @truncate(h);
    }
};