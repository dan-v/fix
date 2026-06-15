//! Hot-anchor detection for the tracing JIT (`-Dtjit`).
//!
//! Nix isn't loopy, so we anchor traces at hot *chunk entries* (thunk bodies
//! and lambda bodies) rather than loop headers. A per-chunk saturating
//! counter is bumped on entry; when it crosses `hot_threshold` the chunk
//! becomes a trace anchor and the next entry is recorded. See
//! `docs/tracing-jit.md`.
//!
//! Lifecycle per chunk: cold (counting) → armed (record next entry) →
//! traced (a compiled trace is installed; stop counting) or blacklisted
//! (recording aborted too many times; stop trying). One word per chunk.

const std = @import("std");
const build_options = @import("build_options");
const types = @import("../runtime/types.zig");

pub const enabled: bool = build_options.tjit;

const ChunkId = types.ChunkId;

pub const State = enum(u8) { cold, armed, traced, blacklisted };

/// Per-chunk recording state + a saturating entry counter, packed so the hot
/// path touches one cache line. `count` saturates; `state` drives the FSM.
pub const ChunkHot = struct {
    count: u32 = 0,
    state: State = .cold,
};

pub const HotTable = struct {
    /// Indexed by ChunkId. Grows lazily as chunks are registered.
    entries: std.ArrayListUnmanaged(ChunkHot) = .empty,
    /// Entries needed before a cold chunk arms for recording.
    hot_threshold: u32 = 64,
    /// Failed recordings before a chunk is given up on.
    max_aborts: u32 = 3,
    aborts: std.ArrayListUnmanaged(u8) = .empty,

    pub fn deinit(self: *HotTable, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
        self.aborts.deinit(allocator);
    }

    fn ensure(self: *HotTable, allocator: std.mem.Allocator, id: ChunkId) !void {
        if (id < self.entries.items.len) return;
        const old = self.entries.items.len;
        try self.entries.resize(allocator, id + 1);
        try self.aborts.resize(allocator, id + 1);
        for (old..self.entries.items.len) |i| {
            self.entries.items[i] = .{};
            self.aborts.items[i] = 0;
        }
    }

    /// Record one entry to `id`. Returns true exactly once — the entry that
    /// transitions cold→armed — signalling "record the next execution
    /// through this chunk." Cheap and allocation-free once `ensure`d; the
    /// caller `ensure`s at registration time, off the hot path.
    pub fn onEntry(self: *HotTable, id: ChunkId) bool {
        if (id >= self.entries.items.len) return false;
        const e = &self.entries.items[id];
        switch (e.state) {
            .cold => {
                if (e.count < self.hot_threshold) {
                    e.count += 1;
                    if (e.count >= self.hot_threshold) {
                        e.state = .armed;
                        return true;
                    }
                }
                return false;
            },
            else => return false,
        }
    }

    pub fn markTraced(self: *HotTable, id: ChunkId) void {
        if (id < self.entries.items.len) self.entries.items[id].state = .traced;
    }

    /// Recording aborted; re-arm unless we've given up on this chunk.
    pub fn markAborted(self: *HotTable, id: ChunkId) void {
        if (id >= self.entries.items.len) return;
        self.aborts.items[id] +|= 1;
        if (self.aborts.items[id] >= self.max_aborts) {
            self.entries.items[id].state = .blacklisted;
        } else {
            // Re-heat from scratch so we don't immediately re-arm and thrash.
            self.entries.items[id] = .{ .count = 0, .state = .cold };
        }
    }

    pub fn reserve(self: *HotTable, allocator: std.mem.Allocator, id: ChunkId) !void {
        try self.ensure(allocator, id);
    }
};

test "hot table arms once at threshold then stops" {
    const allocator = std.testing.allocator;
    var t = HotTable{ .hot_threshold = 4 };
    defer t.deinit(allocator);
    try t.reserve(allocator, 0);

    var armed_count: u32 = 0;
    for (0..20) |_| {
        if (t.onEntry(0)) armed_count += 1;
    }
    // Arms exactly once (cold→armed), then stays armed (no re-arm).
    try std.testing.expectEqual(@as(u32, 1), armed_count);
    try std.testing.expectEqual(State.armed, t.entries.items[0].state);

    t.markTraced(0);
    try std.testing.expectEqual(State.traced, t.entries.items[0].state);
    // Traced chunks never re-arm.
    for (0..20) |_| try std.testing.expect(!t.onEntry(0));
}

test "hot table blacklists after repeated aborts" {
    const allocator = std.testing.allocator;
    var t = HotTable{ .hot_threshold = 1, .max_aborts = 2 };
    defer t.deinit(allocator);
    try t.reserve(allocator, 5);

    try std.testing.expect(t.onEntry(5)); // arm
    t.markAborted(5); // 1 → cold (re-arm allowed)
    try std.testing.expectEqual(State.cold, t.entries.items[5].state);
    try std.testing.expect(t.onEntry(5)); // arm again
    t.markAborted(5); // 2 → blacklisted
    try std.testing.expectEqual(State.blacklisted, t.entries.items[5].state);
    for (0..10) |_| try std.testing.expect(!t.onEntry(5));
}
