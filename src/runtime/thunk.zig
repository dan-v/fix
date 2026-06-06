//! Atomic lazy thunk — the core of multithreaded lazy evaluation.
//!
//! A thunk is a suspended computation. Multiple threads may concurrently
//! attempt to force it. The first thread CAS-claims it and runs the
//! suspended target. Other threads register themselves on a lock-free
//! waiter list and park until the result is published. A thread that
//! tries to force a thunk it already claimed gets a `blackhole` outcome
//! (real recursion).
//!
//! Memory model:
//!   - `state` transitions follow release-acquire pairs.
//!   - `result` is written before the `state → resolved` store-release;
//!     readers observe it after acquire-loading state == resolved.
//!   - `target` is set at construction and never mutated.
//!
//! Platform: parker uses Linux futex; other platforms fall back to spin.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const Value = @import("value.zig").Value;
const ChunkId = types.ChunkId;

/// `state` is a u32 so we can `futex_wait` / `futex_wake` directly on it.
/// The low byte encodes the lifecycle (ThunkState); the rest is zero.
pub const ThunkState = enum(u32) {
    unresolved = 0,
    evaluating = 1,
    resolved = 2,
    blackhole = 3,
};

pub const INVALID_CLAIMER: u8 = 0xFF;

pub const Cell = struct {
    initial: Value,
    forced: Value = Value.null_val,
    state: std.atomic.Value(u8) = .init(0),

    pub const STATE_INITIAL: u8 = 0;
    pub const STATE_WRITING: u8 = 1;
    pub const STATE_FORCED: u8 = 2;

    pub fn init(initial: Value) Cell {
        return .{ .initial = initial };
    }

    pub fn read(self: *const Cell) Value {
        return if (self.state.load(.acquire) == STATE_FORCED) self.forced else self.initial;
    }

    pub fn set(self: *Cell, value: Value) void {
        const prev = self.state.cmpxchgStrong(STATE_INITIAL, STATE_WRITING, .acquire, .monotonic);
        if (prev != null) return;
        self.forced = value;
        self.state.store(STATE_FORCED, .release);
    }
};

pub const BytecodeThunk = struct {
    chunk_id: ChunkId,
    upvalues: []const Value,
};

pub const ThunkTarget = union(enum) {
    closure: Value,
    bytecode: BytecodeThunk,
};

pub const ForceOutcome = union(enum) {
    already_resolved: Value,
    claimed,
    blackhole,
    busy,
};

pub const WaitOutcome = union(enum) {
    resolved: Value,
    blackhole,
    /// State went back to unresolved or another worker claimed it; the
    /// caller should re-run `tryForce` with a fresh `Waiter`.
    retry,
};

/// Atomic lazy thunk. State transitions and wake-up coordination use a
/// futex on the `state` word — no per-waiter list, so threads that hit
/// `.busy` and want to wait don't need to allocate or register anything.
///
/// `demanded` distinguishes a thunk that was resolved because a real
/// caller observed it from one that was only resolved by speculative
/// pre-forcing. Lazy renderers (XML lazy mode) treat the latter as
/// "unevaluated" so speculation stays invisible to users.
pub const Thunk = struct {
    state: std.atomic.Value(u32),
    claimer: std.atomic.Value(u8),
    demanded: std.atomic.Value(u8),
    target: ThunkTarget,
    result: Value,

    pub fn init(closure: Value) Thunk {
        return .{
            .state = .init(@intFromEnum(ThunkState.unresolved)),
            .claimer = .init(INVALID_CLAIMER),
            .demanded = .init(0),
            .target = .{ .closure = closure },
            .result = Value.null_val,
        };
    }

    pub fn initBytecode(chunk_id: ChunkId, upvalues: []const Value) Thunk {
        return .{
            .state = .init(@intFromEnum(ThunkState.unresolved)),
            .claimer = .init(INVALID_CLAIMER),
            .demanded = .init(0),
            .target = .{ .bytecode = .{ .chunk_id = chunk_id, .upvalues = upvalues } },
            .result = Value.null_val,
        };
    }

    pub fn markDemanded(self: *Thunk) void {
        self.demanded.store(1, .release);
    }

    pub fn isDemanded(self: *const Thunk) bool {
        return self.demanded.load(.acquire) != 0;
    }

    /// Try to claim this thunk for evaluation by `worker_id`. Returns:
    ///   - `.already_resolved`: the result is published; read `self.result`.
    ///   - `.claimed`: this thread has claimed; must compute and call
    ///     `resolve` or `reset`.
    ///   - `.blackhole`: the same worker is already evaluating; real recursion.
    ///   - `.busy`: another worker is evaluating; caller must `waitFor`.
    pub fn tryForce(self: *Thunk, worker_id: u8) ForceOutcome {
        while (true) {
            const s: ThunkState = @enumFromInt(self.state.load(.acquire));
            switch (s) {
                .resolved => return .{ .already_resolved = self.result },
                .blackhole => return .blackhole,
                .unresolved => {
                    const prev = self.state.cmpxchgWeak(
                        @intFromEnum(ThunkState.unresolved),
                        @intFromEnum(ThunkState.evaluating),
                        .acquire,
                        .monotonic,
                    );
                    if (prev == null) {
                        self.claimer.store(worker_id, .release);
                        return .claimed;
                    }
                    continue;
                },
                .evaluating => {
                    const c = self.claimer.load(.acquire);
                    if (c == worker_id) return .blackhole;
                    return .busy;
                },
            }
        }
    }

    /// Park until the thunk's state changes from `evaluating`. Returns what
    /// the caller should do next. No allocation; uses futex on the state
    /// word directly.
    pub fn waitFor(self: *Thunk) WaitOutcome {
        const evaluating_raw = @as(u32, @intFromEnum(ThunkState.evaluating));
        switch (@as(ThunkState, @enumFromInt(self.state.load(.acquire)))) {
            .resolved => return .{ .resolved = self.result },
            .blackhole => return .blackhole,
            .unresolved => return .retry,
            .evaluating => {},
        }

        switch (builtin.os.tag) {
            .linux => {
                _ = std.os.linux.futex_4arg(
                    @ptrCast(&self.state),
                    .{ .cmd = .WAIT, .private = true },
                    evaluating_raw,
                    null,
                );
            },
            else => {
                std.atomic.spinLoopHint();
                std.Thread.yield() catch {};
            },
        }

        return switch (@as(ThunkState, @enumFromInt(self.state.load(.acquire)))) {
            .resolved => .{ .resolved = self.result },
            .blackhole => .blackhole,
            .unresolved, .evaluating => .retry,
        };
    }

    /// Publish `value` as the result and wake all parked waiters.
    pub fn resolve(self: *Thunk, value: Value) void {
        self.result = value;
        self.claimer.store(INVALID_CLAIMER, .release);
        self.state.store(@intFromEnum(ThunkState.resolved), .release);
        self.wakeAll();
    }

    /// Mark a failed evaluation as retryable. Wakes waiters so they can
    /// re-enter `tryForce`.
    pub fn reset(self: *Thunk) void {
        self.result = Value.null_val;
        self.claimer.store(INVALID_CLAIMER, .monotonic);
        self.state.store(@intFromEnum(ThunkState.unresolved), .release);
        self.wakeAll();
    }

    /// Mark this thunk as a blackhole. Wakes waiters so they observe the
    /// new state and return an error.
    pub fn blackhole(self: *Thunk) void {
        self.claimer.store(INVALID_CLAIMER, .monotonic);
        self.state.store(@intFromEnum(ThunkState.blackhole), .release);
        self.wakeAll();
    }

    fn wakeAll(self: *Thunk) void {
        switch (builtin.os.tag) {
            .linux => {
                _ = std.os.linux.futex_3arg(
                    @ptrCast(&self.state),
                    .{ .cmd = .WAKE, .private = true },
                    std.math.maxInt(i32),
                );
            },
            else => {},
        }
    }

    /// Identity equality. Two thunks are the same object iff they live at
    /// the same heap slot — there is no structural notion of thunk equality.
    pub fn idEq(self: *const Thunk, other: *const Thunk) bool {
        return self == other;
    }
};

test "thunk: cross-worker force waits for resolution" {
    var thunk = Thunk.init(Value.null_val);

    const Forcer = struct {
        fn run(th: *Thunk, value: i64, ready: *std.atomic.Value(u8), release_now: *std.atomic.Value(u8)) void {
            switch (th.tryForce(0)) {
                .claimed => {},
                else => return,
            }
            ready.store(1, .release);
            while (release_now.load(.acquire) == 0) std.atomic.spinLoopHint();
            th.resolve(Value.int(value));
        }
    };

    var ready: std.atomic.Value(u8) = .init(0);
    var release_now: std.atomic.Value(u8) = .init(0);
    var t = try std.Thread.spawn(.{}, Forcer.run, .{ &thunk, @as(i64, 99), &ready, &release_now });

    while (ready.load(.acquire) == 0) std.atomic.spinLoopHint();

    // Worker 1 starts forcing, sees .busy, waits.
    var saw_busy = false;
    switch (thunk.tryForce(1)) {
        .busy => saw_busy = true,
        else => unreachable,
    }
    try std.testing.expect(saw_busy);

    // Release the resolver from another thread so the waiter parks first.
    const Releaser = struct {
        fn run(rn: *std.atomic.Value(u8)) void {
            rn.store(1, .release);
        }
    };
    var rt = try std.Thread.spawn(.{}, Releaser.run, .{&release_now});

    const outcome = thunk.waitFor();
    rt.join();
    t.join();

    switch (outcome) {
        .resolved => |v| try std.testing.expectEqual(@as(i64, 99), v.asInt()),
        else => return error.UnexpectedOutcome,
    }
}

test "thunk: same-worker recursive force returns blackhole" {
    var thunk = Thunk.init(Value.null_val);

    switch (thunk.tryForce(0)) {
        .claimed => {},
        else => return error.UnexpectedOutcome,
    }
    // Re-forcing from the same worker → blackhole.
    switch (thunk.tryForce(0)) {
        .blackhole => {},
        else => return error.ExpectedBlackhole,
    }
}

test "thunk: reset wakes waiters and lets them retry" {
    var thunk = Thunk.init(Value.null_val);

    const Failer = struct {
        fn run(th: *Thunk, claimed_signal: *std.atomic.Value(u8), go: *std.atomic.Value(u8)) void {
            switch (th.tryForce(0)) {
                .claimed => {},
                else => return,
            }
            claimed_signal.store(1, .release);
            while (go.load(.acquire) == 0) std.atomic.spinLoopHint();
            th.reset();
        }
    };

    var claimed_signal: std.atomic.Value(u8) = .init(0);
    var go: std.atomic.Value(u8) = .init(0);
    var t = try std.Thread.spawn(.{}, Failer.run, .{ &thunk, &claimed_signal, &go });

    while (claimed_signal.load(.acquire) == 0) std.atomic.spinLoopHint();

    switch (thunk.tryForce(1)) {
        .busy => {},
        else => return error.ExpectedBusy,
    }

    const Releaser = struct {
        fn run(g: *std.atomic.Value(u8)) void {
            g.store(1, .release);
        }
    };
    var rt = try std.Thread.spawn(.{}, Releaser.run, .{&go});

    const outcome = thunk.waitFor();
    rt.join();
    t.join();

    switch (outcome) {
        .retry => {},
        else => return error.ExpectedRetry,
    }
}
