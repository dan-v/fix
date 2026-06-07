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

/// Identity of whoever is currently claiming a thunk. Packs:
///   high byte: worker_id (which OS thread)
///   low byte:  slot index within that worker's fiber pool, or
///              `MAIN_THREAD_SLOT` if the claimer is the worker's bare
///              OS-thread stack (not a fiber).
///
/// Both fields combined identify a single in-progress force operation,
/// which is what blackhole detection cares about: same fiber re-entering
/// its own evaluation = real recursion; different fiber on same worker =
/// must wait (no spurious blackhole).
pub const ClaimerId = u16;
pub const INVALID_CLAIMER: ClaimerId = 0xFFFF;
pub const MAIN_THREAD_SLOT: u8 = 0xFF;

pub fn makeClaimer(worker_id: u8, slot: u8) ClaimerId {
    return (@as(ClaimerId, worker_id) << 8) | @as(ClaimerId, slot);
}

pub const BytecodeThunk = struct {
    chunk_id: ChunkId,
    upvalues: []const Value,
};

/// What a thunk evaluates when forced.
///
///   - `.closure` and `.bytecode` are computed targets: forcing invokes
///     bytecode or a builtin and the result is stored.
///   - `.pass_through` is a memoization wrapper: the underlying Value is
///     forced and the result becomes the thunk's resolved value. This is
///     how the compiler models recursive let-binding cells.
pub const ThunkTarget = union(enum) {
    closure: Value,
    bytecode: BytecodeThunk,
    pass_through: Value,
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
/// `parked` records whether any thread has registered to be woken on
/// state change. Resolve/reset/blackhole only invoke futex_wake when
/// `parked` is set; in the common case (no contention) the syscall is
/// skipped entirely.
///
/// `demanded` distinguishes a thunk that was resolved because a real
/// caller observed it from one that was only resolved by speculative
/// pre-forcing. Lazy renderers (XML lazy mode) treat the latter as
/// "unevaluated" so speculation stays invisible to users.
pub const Thunk = struct {
    state: std.atomic.Value(u32),
    claimer: std.atomic.Value(ClaimerId),
    parked: std.atomic.Value(u8),
    demanded: std.atomic.Value(u8),
    target: ThunkTarget,
    result: Value,

    pub fn init(closure: Value) Thunk {
        return .{
            .state = .init(@intFromEnum(ThunkState.unresolved)),
            .claimer = .init(INVALID_CLAIMER),
            .parked = .init(0),
            .demanded = .init(0),
            .target = .{ .closure = closure },
            .result = Value.null_val,
        };
    }

    pub fn initBytecode(chunk_id: ChunkId, upvalues: []const Value) Thunk {
        return .{
            .state = .init(@intFromEnum(ThunkState.unresolved)),
            .claimer = .init(INVALID_CLAIMER),
            .parked = .init(0),
            .demanded = .init(0),
            .target = .{ .bytecode = .{ .chunk_id = chunk_id, .upvalues = upvalues } },
            .result = Value.null_val,
        };
    }

    /// A "cell" thunk: holds a Value to be forced lazily. The cell pattern
    /// (used by the compiler for recursive let bindings) is just a thunk
    /// whose target is a wrapped Value.
    pub fn initPassThrough(value: Value) Thunk {
        return .{
            .state = .init(@intFromEnum(ThunkState.unresolved)),
            .claimer = .init(INVALID_CLAIMER),
            .parked = .init(0),
            .demanded = .init(0),
            .target = .{ .pass_through = value },
            .result = Value.null_val,
        };
    }

    pub fn markDemanded(self: *Thunk) void {
        self.demanded.store(1, .release);
    }

    pub fn isDemanded(self: *const Thunk) bool {
        return self.demanded.load(.acquire) != 0;
    }

    /// Try to claim this thunk for evaluation by `claimer`. Returns:
    ///   - `.already_resolved`: the result is published; read `self.result`.
    ///   - `.claimed`: this caller has claimed; must compute and call
    ///     `resolve` or `reset`.
    ///   - `.blackhole`: the SAME claim identity is already evaluating —
    ///     real recursion (a fiber re-entering itself).
    ///   - `.busy`: a different claim identity is evaluating; caller must
    ///     `waitFor` (OS-thread context) or yield (fiber context).
    pub fn tryForce(self: *Thunk, claimer: ClaimerId) ForceOutcome {
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
                        self.claimer.store(claimer, .release);
                        return .claimed;
                    }
                    continue;
                },
                .evaluating => {
                    const c = self.claimer.load(.acquire);
                    if (c == claimer) return .blackhole;
                    return .busy;
                },
            }
        }
    }

    /// Park until the thunk's state changes from `evaluating`. Returns what
    /// the caller should do next. No allocation; uses futex on the state
    /// word directly.
    pub fn waitFor(self: *Thunk) WaitOutcome {
        // Spin briefly before parking. Most thunks evaluate in well under a
        // microsecond — that's faster than a futex_wait round trip. Only
        // park if the helper is genuinely slow.
        const SPIN_BUDGET: u32 = 128;
        var spins: u32 = 0;
        while (spins < SPIN_BUDGET) : (spins += 1) {
            switch (@as(ThunkState, @enumFromInt(self.state.load(.acquire)))) {
                .resolved => return .{ .resolved = self.result },
                .blackhole => return .blackhole,
                .unresolved => return .retry,
                .evaluating => {},
            }
            std.atomic.spinLoopHint();
        }

        // Announce that we are about to park so resolve() will issue a
        // futex_wake. The order matters: set the flag, then recheck state.
        // If resolve fires between flag and recheck, recheck sees `.resolved`
        // and we skip the syscall. If we set the flag and then park while
        // state is still `.evaluating`, resolve will observe the flag and
        // wake us.
        self.parked.store(1, .release);
        switch (@as(ThunkState, @enumFromInt(self.state.load(.acquire)))) {
            .resolved => return .{ .resolved = self.result },
            .blackhole => return .blackhole,
            .unresolved => return .retry,
            .evaluating => {},
        }

        const evaluating_raw = @as(u32, @intFromEnum(ThunkState.evaluating));
        switch (builtin.os.tag) {
            .linux => {
                _ = std.os.linux.futex_4arg(
                    @ptrCast(&self.state),
                    .{ .cmd = .WAIT, .private = true },
                    evaluating_raw,
                    null,
                );
            },
            else => std.Thread.yield() catch {},
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
        // Fast path: nobody has registered to be woken. Skip the futex
        // syscall entirely. The most common case (uncontended thunks
        // resolved by the worker that claimed them) hits this branch.
        if (self.parked.load(.acquire) == 0) return;
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
            switch (th.tryForce(makeClaimer(0, MAIN_THREAD_SLOT))) {
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
    switch (thunk.tryForce(makeClaimer(1, MAIN_THREAD_SLOT))) {
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

test "thunk: same claimer recursive force returns blackhole" {
    var thunk = Thunk.init(Value.null_val);
    const me = makeClaimer(0, MAIN_THREAD_SLOT);

    switch (thunk.tryForce(me)) {
        .claimed => {},
        else => return error.UnexpectedOutcome,
    }
    // Re-forcing from the same claimer → blackhole.
    switch (thunk.tryForce(me)) {
        .blackhole => {},
        else => return error.ExpectedBlackhole,
    }
}

test "thunk: same worker different fibers see .busy, not blackhole" {
    // The whole point of widening claimer to (worker, slot): two fibers
    // on the same worker must not falsely report recursion when one
    // touches a thunk the other claimed.
    var thunk = Thunk.init(Value.null_val);
    const slot_a = makeClaimer(0, 0);
    const slot_b = makeClaimer(0, 1);

    switch (thunk.tryForce(slot_a)) {
        .claimed => {},
        else => return error.UnexpectedOutcome,
    }
    switch (thunk.tryForce(slot_b)) {
        .busy => {},
        .blackhole => return error.UnexpectedBlackhole,
        else => return error.UnexpectedOutcome,
    }
}

test "thunk: reset wakes waiters and lets them retry" {
    var thunk = Thunk.init(Value.null_val);

    const Failer = struct {
        fn run(th: *Thunk, claimed_signal: *std.atomic.Value(u8), go: *std.atomic.Value(u8)) void {
            switch (th.tryForce(makeClaimer(0, MAIN_THREAD_SLOT))) {
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

    switch (thunk.tryForce(makeClaimer(1, MAIN_THREAD_SLOT))) {
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
