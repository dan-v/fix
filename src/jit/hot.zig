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
const types = @import("runtime").types;

pub const enabled: bool = build_options.tjit;

/// Runtime gate for the JIT's diagnostic output (per-trace IR dumps, hot-anchor
/// listing, exec/recording counters). Off by default so a `-Dtjit` build runs
/// clean — the spew is opt-in via `--print-sched-stats`. (Always-on stderr
/// dumps also corrupt the `zig build test --listen=-` IPC stream.) Set once in
/// `main` before evaluation; read at every JIT print site.
pub var report_enabled: bool = false;

const ChunkId = types.ChunkId;

pub const State = enum(u8) { cold, armed, traced, blacklisted };

pub const ChunkHot = struct {
    /// Entry counter. Plain (non-atomic): hotness is approximate, so racy
    /// increments at high worker counts are benign (a chunk just heats a
    /// little slower); only the cold→armed transition needs the atomic CAS.
    /// This keeps the per-frame-entry cost a plain load+store, not a LOCK
    /// fetchAdd, across the millions of cold entries.
    count: u32 = 0,
    state: std.atomic.Value(u8) = .{ .raw = @intFromEnum(State.cold) },
    aborts: std.atomic.Value(u8) = .{ .raw = 0 },
    /// Installed compiled trace as `@intFromPtr` (0 = none). Stored as raw
    /// bits so this module stays decoupled from the trace IR type. Published
    /// release / read acquire so a reader that sees the pointer sees a fully
    /// built trace.
    trace_bits: std.atomic.Value(usize) = .{ .raw = 0 },
    /// Native-compiled trace fn (LambdaCompiledFn) as bits, 0 = none. When
    /// set, preferred over `trace_bits` (the exec.zig interpreter fallback).
    native_bits: std.atomic.Value(usize) = .{ .raw = 0 },
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
        e.count += 1; // plain; racy-benign at w>1
        const n = e.count;
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

    /// Publish a compiled trace (as pointer bits) for `id` and mark it traced.
    pub fn publishTrace(self: *HotTable, id: ChunkId, trace_bits: usize) void {
        if (id >= self.entries.len) return;
        self.entries[id].trace_bits.store(trace_bits, .release);
        self.entries[id].state.store(@intFromEnum(State.traced), .release);
    }

    /// The installed trace pointer bits for `id` (0 = none). Acquire load.
    pub fn traceOf(self: *const HotTable, id: ChunkId) usize {
        if (id >= self.entries.len) return 0;
        return self.entries[id].trace_bits.load(.acquire);
    }

    /// Publish a native-compiled trace fn (pointer bits) for `id`.
    pub fn publishNative(self: *HotTable, id: ChunkId, fn_bits: usize) void {
        if (id < self.entries.len) self.entries[id].native_bits.store(fn_bits, .release);
    }

    /// The installed native trace fn bits for `id` (0 = none). Acquire load.
    pub fn nativeOf(self: *const HotTable, id: ChunkId) usize {
        if (id >= self.entries.len) return 0;
        return self.entries[id].native_bits.load(.acquire);
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
            e.count = 0;
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

test "hot table does not arm one entry below threshold" {
    const allocator = std.testing.allocator;
    var t = try HotTable.init(allocator, 4, 4, 3);
    defer t.deinit(allocator);

    // Three entries: one short of the threshold of 4.
    for (0..3) |_| try std.testing.expect(!t.onEntry(1));
    try std.testing.expectEqual(State.cold, t.stateOf(1));

    // The fourth entry crosses the threshold and arms exactly once.
    try std.testing.expect(t.onEntry(1));
    try std.testing.expectEqual(State.armed, t.stateOf(1));
}

test "hot table native and interpreted trace publication round-trip independently" {
    const allocator = std.testing.allocator;
    var t = try HotTable.init(allocator, 4, 1, 3);
    defer t.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), t.traceOf(2));
    try std.testing.expectEqual(@as(usize, 0), t.nativeOf(2));

    t.publishTrace(2, 0xdead0);
    try std.testing.expectEqual(@as(usize, 0xdead0), t.traceOf(2));
    try std.testing.expectEqual(State.traced, t.stateOf(2));
    try std.testing.expectEqual(@as(usize, 0), t.nativeOf(2)); // unaffected

    t.publishNative(2, 0xbeef0);
    try std.testing.expectEqual(@as(usize, 0xbeef0), t.nativeOf(2));
    try std.testing.expectEqual(@as(usize, 0xdead0), t.traceOf(2)); // unaffected

    // Out-of-capacity ids are no-ops, not crashes.
    t.publishNative(100, 1);
    try std.testing.expectEqual(@as(usize, 0), t.nativeOf(100));
}
