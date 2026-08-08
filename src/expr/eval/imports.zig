//! Import registry and shared import-entry state.
//!
//! Each `ImportEntry` wraps a `runtime.future.Future` — the same
//! claim+wait state machine `Thunk` uses. The first fiber to claim
//! runs the evaluator-owned import orchestration inline; concurrent fibers enroll on the
//! future's waiter list and yield. Same protocol, same primitive: a
//! Future is a Future whether it backs a thunk or a path.

const std = @import("std");
const Value = @import("runtime").value.Value;
const FailureRef = @import("runtime").failure.FailureRef;
const future_mod = @import("runtime").future;
const SpinMutex = @import("base").sync.SpinMutex;

/// Path → in-flight `ImportEntry`. The mutex is held only briefly
/// during lookup/insert; the entry's own `Future` coordinates the
/// actual evaluation.
pub const Registry = struct {
    entries: std.StringHashMapUnmanaged(*ImportEntry) = .empty,
    /// Paths in first-demand order (borrowing the map's keys). The
    /// chunk-cache import manifest replays in this order so the next run's
    /// preload tracks this run's compile/load order — narrow-operand cached
    /// units then decode while the id spaces are still small.
    order: std.ArrayListUnmanaged([]const u8) = .empty,
    /// A separate memo table for the current debugger replay. Keeping it
    /// distinct lets old normal-evaluation helpers finish against `entries`
    /// while a serial debug run starts from a clean import graph.
    replay_entries: std.StringHashMapUnmanaged(*ImportEntry) = .empty,
    mu: SpinMutex = .{},

    pub fn deinit(self: *Registry, allocator: std.mem.Allocator) void {
        self.order.deinit(allocator);
        clearEntries(&self.entries, allocator);
        clearEntries(&self.replay_entries, allocator);
    }

    /// Start a fresh serial debugger replay while keeping the compiled chunk
    /// registry and ordinary import memo table warm.
    pub fn beginReplayQuiescent(self: *Registry, allocator: std.mem.Allocator) void {
        clearEntries(&self.replay_entries, allocator);
    }

    fn clearEntries(entries: *std.StringHashMapUnmanaged(*ImportEntry), allocator: std.mem.Allocator) void {
        var it = entries.iterator();
        while (it.next()) |kv| {
            const entry = kv.value_ptr.*;
            allocator.free(kv.key_ptr.*);
            allocator.destroy(entry);
        }
        entries.clearAndFree(allocator);
    }

    pub fn lookupOrCreate(
        self: *Registry,
        allocator: std.mem.Allocator,
        path: []const u8,
        replay: bool,
    ) !*ImportEntry {
        self.mu.lock();
        defer self.mu.unlock();

        const entries = if (replay) &self.replay_entries else &self.entries;
        if (entries.get(path)) |entry| return entry;

        const key = try allocator.dupe(u8, path);
        errdefer allocator.free(key);
        const entry = try allocator.create(ImportEntry);
        errdefer allocator.destroy(entry);
        entry.* = .{ .future = future_mod.Future.init() };
        try entries.put(allocator, key, entry);
        // Best-effort: the manifest just loses one entry on OOM.
        if (!replay) self.order.append(allocator, key) catch {};
        return entry;
    }
};

pub const ImportEntry = struct {
    future: future_mod.Future,
    /// The resolved import value. `Future` is value-less, so the entry
    /// owns its own result slot, written before `future.publish()`.
    result: Value = Value.null_val,
    /// Demand-effect group discovered while a speculative import evaluated.
    /// Published before `future` reaches a terminal state, like `result`.
    effect_group: u32 = 0,
    /// Borrowed immutable failure owned by the engine's failure store.
    failure: ?FailureRef = null,
};
