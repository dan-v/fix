//! Hot-anchor detection for the tracing JIT (`-Dtjit`).
//!
//! Nix isn't loopy, so we anchor traces at hot *chunk entries* (thunk bodies
//! and lambda bodies) rather than loop headers. A per-chunk saturating
//! counter is bumped on entry (`stack.pushFrame`); when it crosses
//! `hot_threshold` the chunk becomes a trace anchor and the next entry is
//! recorded. See `docs/tracing-jit.md`.
//!
//! Thread-safe by construction: the entry array is allocated once at a fixed
//! capacity (no resize, so a reader never races a realloc), and per-chunk
//! state is atomic. Counter bumps race benignly (approximate hotness is
//! fine); the cold→armed transition is a single CAS so exactly one worker
//! arms a given chunk. This holds at any `--workers` count, which matters
//! because compiled traces (later) run on every worker.

const std = @import("std");
const build_options = @import("build_options");
const types = @import("../runtime/types.zig");

pub const enabled: bool = build_options.tjit;

const ChunkId = types.ChunkId;

pub const State = enum(u8) { cold, armed, traced, blacklisted };

pub const ChunkHot = struct {
    count: std.atomic.Value(u32) = .{ .raw = 0 },
    state: std.atomic.Value(u8) = .{ .raw = @intFromEnum(State.cold) },
    aborts: std.atomic.Value(u8) = .{ .raw = 0 },
};

pub const HotTable = struct {
    /// Indexed by ChunkId. Fixed capacity — ids beyond it are untracked
    /// (they never go hot, which is fine; they're rare/late).
    entries: []ChunkHot,
    hot_threshold: u32,
    max_aborts: u8,

    pub fn init(allocator: std.mem.Allocator, capacity: usize, hot_threshold: u32, max_aborts: u8) !HotTable {
        const entries = try allocator.alloc(ChunkHot, capacity);
        for (entries) |*e| e.* = .{};
        return .{ .entries = entries, .hot_threshold = hot_threshold, .max_aborts = max_aborts };
    }

    pub fn deinit(self: *HotTable, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
    }

    /// Record one entry to `id`. Returns true exactly once per chunk — for
    /// the single worker whose bump crosses the threshold and wins the
    /// cold→armed CAS — signalling "record the next execution through this
    /// chunk." Lock-free; safe to call from any worker.
    pub fn onEntry(self: *HotTable, id: ChunkId) bool {
        if (id >= self.entries.len) return false;
        const e = &self.entries[id];
        if (e.state.load(.monotonic) != @intFromEnum(State.cold)) return false;
        const n = e.count.fetchAdd(1, .monotonic) + 1;
        if (n != self.hot_threshold) return false;
        // Exactly one fetchAdd produced n == threshold; that worker arms.
        return e.state.cmpxchgStrong(
            @intFromEnum(State.cold),
            @intFromEnum(State.armed),
            .acq_rel,
            .monotonic,
        ) == null;
    }

    pub fn stateOf(self: *const HotTable, id: ChunkId) State {
        if (id >= self.entries.len) return .cold;
        return @enumFromInt(self.entries[id].state.load(.monotonic));
    }

    pub fn markTraced(self: *HotTable, id: ChunkId) void {
        if (id < self.entries.len) self.entries[id].state.store(@intFromEnum(State.traced), .release);
    }

    /// Recording aborted; re-heat from cold unless we've given up (blacklist).
    pub fn markAborted(self: *HotTable, id: ChunkId) void {
        if (id >= self.entries.len) return;
        const e = &self.entries[id];
        const n = e.aborts.fetchAdd(1, .monotonic) + 1;
        if (n >= self.max_aborts) {
            e.state.store(@intFromEnum(State.blacklisted), .release);
        } else {
            e.count.store(0, .monotonic);
            e.state.store(@intFromEnum(State.cold), .release);
        }
    }
};

test "hot table arms exactly once at threshold" {
    const allocator = std.testing.allocator;
    var t = try HotTable.init(allocator, 16, 4, 3);
    defer t.deinit(allocator);

    var armed: u32 = 0;
    for (0..20) |_| {
        if (t.onEntry(0)) armed += 1;
    }
    try std.testing.expectEqual(@as(u32, 1), armed);
    try std.testing.expectEqual(State.armed, t.stateOf(0));

    t.markTraced(0);
    try std.testing.expectEqual(State.traced, t.stateOf(0));
    for (0..20) |_| try std.testing.expect(!t.onEntry(0));
}

test "hot table blacklists after repeated aborts" {
    const allocator = std.testing.allocator;
    var t = try HotTable.init(allocator, 16, 1, 2);
    defer t.deinit(allocator);

    try std.testing.expect(t.onEntry(5)); // arm
    t.markAborted(5); // 1 → cold
    try std.testing.expectEqual(State.cold, t.stateOf(5));
    try std.testing.expect(t.onEntry(5)); // arm again
    t.markAborted(5); // 2 → blacklisted
    try std.testing.expectEqual(State.blacklisted, t.stateOf(5));
    for (0..10) |_| try std.testing.expect(!t.onEntry(5));
}

test "hot table ignores out-of-capacity ids" {
    const allocator = std.testing.allocator;
    var t = try HotTable.init(allocator, 4, 1, 3);
    defer t.deinit(allocator);
    try std.testing.expect(!t.onEntry(100));
    try std.testing.expectEqual(State.cold, t.stateOf(100));
}
