//! Atomic lazy thunk and the `Future` primitive it's built on.
//!
//! `Future` is the shared claim+wait state machine: a state word, an
//! optional result, a waiter list, and the methods that drive
//! transitions atomically. It's the abstraction `Thunk` is built on
//! and the one `eval/imports.zig`'s `ImportEntry` also embeds. The
//! protocol is identical wherever it appears: the first fiber to
//! CAS-claim runs the work; others enroll a `Waiter` and yield until
//! the claimer publishes a terminal state. A fiber that tries to
//! force a future under the *same* claimer id it already holds sees
//! `.blackhole` — real recursion within one logical evaluation.
//!
//! `Thunk` layers a `ThunkTarget` (what to evaluate) and a
//! `demanded` flag (was this resolution observed by a real caller?)
//! on top of `Future`.
//!
//! Post-F1 architecture notes:
//!   - Claimer identity (`ClaimerId`) is a globally-allocated fiber id
//!     (`Scheduler.allocFiberId`). It does NOT encode which OS thread
//!     the fiber runs on, so a fiber that migrates across workers
//!     keeps the same identity.
//!   - Wakes are routed to the scheduler's ready queue keyed by the
//!     fiber's allocator-worker (`Fiber.worker`), but ready fibers
//!     are stealable across workers — any worker may resume a waiter
//!     once it's queued.
//!   - All workers (including worker 0 / main) participate
//!     symmetrically in `tryForce`, waiter enrollment, and resolution.
//!     There is no special "main" path through this module.
//!
//! Memory model:
//!   - `Future.state` transitions follow release-acquire pairs.
//!   - `Future.result` is written before the `state → resolved`
//!     store-release; readers observe it after acquire-loading
//!     state == resolved.
//!   - `Thunk.target` is set at construction and never mutated
//!     (except by `publishCellBinding` under EVALUATING claim).
//!   - Waiter list manipulation is protected by `waiters_mu`. Resolvers
//!     re-acquire the lock after the state store so any concurrent
//!     `enrollWaiter` either sees the new state (and refuses) or its
//!     waiter is drained.

const std = @import("std");
const types = @import("types.zig");
const Value = @import("value.zig").Value;
const ChunkId = types.ChunkId;
const stable = @import("stable_segments.zig");

/// `state` is a u32 so it's the right shape for futex-style ops if we
/// ever need them. The low byte encodes the lifecycle (`FutureState`);
/// the rest is zero.
pub const FutureState = enum(u32) {
    unresolved = 0,
    evaluating = 1,
    resolved = 2,
    blackhole = 3,
    /// The work ran and failed deterministically. The captured error
    /// (and optional message) is cached in the sidecar `ErrorInfo` so
    /// subsequent forces don't re-run a body whose outcome is already
    /// known.
    errored = 4,
};

/// Identity of whoever is currently claiming a thunk. Each fiber is
/// assigned a globally unique 32-bit id at allocation time (from the
/// scheduler's `next_fiber_id` counter). The claimer is just that id.
///
/// Blackhole detection compares ids directly: same fiber re-entering
/// its own evaluation = real recursion; different fiber on any worker
/// = must wait. The id is stable across fiber migration (F1 unpin),
/// so a fiber that wakes on a different worker than where it was
/// allocated still presents the same identity.
pub const ClaimerId = u32;
pub const INVALID_CLAIMER: ClaimerId = std.math.maxInt(ClaimerId);

pub fn makeClaimer(fiber_id: u32) ClaimerId {
    return fiber_id;
}

/// Lightweight linked-list node used to enroll fibers on a future's
/// waiter list. The future owns the list; the embedding struct (a
/// FiberSlot in worker.zig) supplies `wake_fn`, which is invoked when
/// the future resolves/resets/blackholes. `wake_fn` typically marks
/// the parent slot resumable and nudges its owning worker.
///
/// Embedders use `@fieldParentPtr("waiter", w)` inside `wake_fn` to
/// recover the parent. The Future is intentionally agnostic about
/// what the parent is — it just walks pointers.
pub const Waiter = struct {
    next: ?*Waiter = null,
    wake_fn: *const fn (*Waiter) void,
};

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

/// Captured failure of a thunk's deterministic body, replayed on
/// subsequent forces. Allocated out-of-band when a thunk transitions
/// to `.errored`; pointer is stored in the `result_or_error` union
/// slot (which is otherwise unused in that state). The struct and its
/// message string are freed in `ObjectHeap.deinit`.
///
/// Sidecar storage avoids widening the (very hot) Thunk struct by
/// 24 bytes per instance — multiplied across millions of live thunks
/// on real workloads, an inline field translated into a 10–15 %
/// regression even though only a handful of thunks ever errored.
pub const ErrorInfo = struct {
    err: anyerror,
    message: ?[]const u8,
};

/// Overlay of the resolved-`Value` slot and the errored-`*ErrorInfo`
/// sidecar pointer. Sized at `max(@sizeOf(Value), 8)` so it stays at
/// `@sizeOf(Value)` for the 16-byte Value layout and grows naturally
/// to 8 bytes when Value is 8 (NaN-boxed). The union tag is implicit
/// in `Thunk.state`: `.resolved` → read `.result`; `.errored` → read
/// `.error_info_bits` and cast back to the heap-owned `*ErrorInfo`.
pub const ResultOrError = extern union {
    result: Value,
    error_info_bits: u64,
};

pub const ForceOutcome = union(enum) {
    already_resolved: Value,
    claimed,
    blackhole,
    busy,
    /// Borrowed pointer into the heap-owned sidecar; valid for the
    /// lifetime of the heap. Kept as a pointer rather than an inline
    /// `ErrorInfo` value so the union stays 24 bytes (Value-sized) —
    /// `forceThunkImpl` is in the hot dispatch path and any growth
    /// here measurably widens its stack frame.
    errored: *const ErrorInfo,
};

/// Shared claim+wait state machine. Both `Thunk` and `ImportEntry`
/// embed one. A `Future` owns: a 5-state lifecycle, a claimer id, a
/// result-or-error slot, and a fiber waiter list.
///
/// `tryForce` is the central method. The first caller to observe
/// `.unresolved` CAS-claims to `.evaluating` and gets `.claimed` —
/// it is now responsible for computing the work and calling exactly
/// one of `resolve`, `markErrored`, `reset`, or `blackhole`. Other
/// callers see `.busy` and must enroll a `Waiter` via `enrollWaiter`,
/// then yield until `wake_fn` fires.
pub const Future = struct {
    state: std.atomic.Value(u32),
    claimer: std.atomic.Value(ClaimerId),
    /// Was this future's resolution observed by a real caller (vs.
    /// pre-forced by speculation / fan-out)? Used by lazy renderers
    /// (XML lazy mode) to treat unobserved resolutions as still
    /// "unevaluated" so speculation stays invisible. Lives inside
    /// `Future` rather than `Thunk` so the hot `forceValueImpl`
    /// fast-path (state load + demand mark + result read) stays
    /// inside a single cache line. `ImportEntry` doesn't read it but
    /// pays one byte for the field — there are O(100s) of imports vs.
    /// millions of thunks, so the trade is firmly in the thunk's
    /// favour.
    demanded: std.atomic.Value(u8),
    /// Holds the resolved Value when `state == .resolved`; reinterpreted
    /// as a `*ErrorInfo` via `error_info_bits` when `state == .errored`
    /// — see `cachedErrorInfo`. Undefined for other states.
    result: ResultOrError,
    /// Singly-linked list of fibers parked on this future. Manipulated
    /// only under `waiters_mu`. Empty in the common (uncontended) case
    /// where the claimer resolves before any other fiber tries to force.
    waiters_head: ?*Waiter,
    waiters_mu: stable.SpinMutex,

    pub fn init() Future {
        return .{
            .state = .init(@intFromEnum(FutureState.unresolved)),
            .claimer = .init(INVALID_CLAIMER),
            .demanded = .init(0),
            .result = .{ .result = Value.null_val },
            .waiters_head = null,
            .waiters_mu = .{},
        };
    }

    /// Construct a Future born in `.evaluating` claimed by `claimer`.
    /// Used by `Thunk.initBindingCell` so a concurrent force attempt
    /// sees BUSY and parks instead of CAS-claiming a placeholder.
    pub fn initClaimed(claimer: ClaimerId) Future {
        return .{
            .state = .init(@intFromEnum(FutureState.evaluating)),
            .claimer = .init(claimer),
            .demanded = .init(0),
            .result = .{ .result = Value.null_val },
            .waiters_head = null,
            .waiters_mu = .{},
        };
    }

    pub inline fn markDemanded(self: *Future) void {
        // Skip the cache-line-evicting store when the flag is already
        // set. Hot thunks get re-forced repeatedly; on each re-force
        // the unconditional store invalidated other workers' copies of
        // the line even though the value didn't change. Idempotent
        // write — racing observers all store the same value.
        if (self.demanded.load(.monotonic) == 0) {
            self.demanded.store(1, .release);
        }
    }

    pub inline fn isDemanded(self: *const Future) bool {
        return self.demanded.load(.acquire) != 0;
    }

    /// Try to claim this future for evaluation by `claimer`. Returns:
    ///   - `.already_resolved`: the result is published; read `self.result`.
    ///   - `.claimed`: this caller has claimed; must compute and call
    ///     `resolve`, `markErrored`, `reset`, or `blackhole`.
    ///   - `.blackhole`: the SAME claim identity is already evaluating —
    ///     real recursion (a fiber re-entering itself).
    ///   - `.busy`: a different claim identity is evaluating; caller
    ///     must enroll on the waiter list and yield.
    ///   - `.errored`: the body ran and failed deterministically; caller
    ///     should re-raise the cached error.
    pub fn tryForce(self: *Future, claimer: ClaimerId) ForceOutcome {
        while (true) {
            const s: FutureState = @enumFromInt(self.state.load(.acquire));
            switch (s) {
                .resolved => return .{ .already_resolved = self.result.result },
                .blackhole => return .blackhole,
                .errored => return .{ .errored = self.cachedErrorInfo() },
                .unresolved => {
                    const prev = self.state.cmpxchgWeak(
                        @intFromEnum(FutureState.unresolved),
                        @intFromEnum(FutureState.evaluating),
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

    /// Enroll a fiber waiter on this future. Returns true if the waiter
    /// was added to the list (caller should yield and wait for `wake_fn`).
    /// Returns false if the future left `.evaluating` between the caller's
    /// `tryForce` and now — caller should re-loop `tryForce` instead.
    ///
    /// Ordering: we re-check `state` under the lock so that any caller
    /// that observes `.evaluating` and enrolls is guaranteed to be drained
    /// by the resolver, which takes the same lock after publishing the
    /// new state.
    pub fn enrollWaiter(self: *Future, waiter: *Waiter) bool {
        self.waiters_mu.lock();
        defer self.waiters_mu.unlock();
        const s: FutureState = @enumFromInt(self.state.load(.acquire));
        if (s != .evaluating) return false;
        waiter.next = self.waiters_head;
        self.waiters_head = waiter;
        return true;
    }

    /// Publish `value` as the result and wake all enrolled fiber waiters.
    pub fn resolve(self: *Future, value: Value) void {
        self.result = .{ .result = value };
        self.claimer.store(INVALID_CLAIMER, .release);
        self.state.store(@intFromEnum(FutureState.resolved), .release);
        self.wakeFiberWaiters();
    }

    /// Drop back to `.unresolved` and wake waiters so they can retry.
    /// Use only for *transient* errors (out-of-memory, stack overflow,
    /// scheduler contention) — deterministic failures should go through
    /// `markErrored` instead.
    pub fn reset(self: *Future) void {
        self.result = .{ .result = Value.null_val };
        self.claimer.store(INVALID_CLAIMER, .monotonic);
        self.state.store(@intFromEnum(FutureState.unresolved), .release);
        self.wakeFiberWaiters();
    }

    /// Publish a deterministic body failure and wake waiters. The
    /// caller owns `info` (and any heap-allocated `info.message`) —
    /// by convention the storage owner of this future also tracks
    /// `info` so it can release it at teardown.
    pub fn markErrored(self: *Future, info: *ErrorInfo) void {
        // Sidecar storage: `result` is unused while errored, so the
        // union slot doubles as the `*ErrorInfo` pointer.
        self.result = .{ .error_info_bits = @intFromPtr(info) };
        self.claimer.store(INVALID_CLAIMER, .monotonic);
        self.state.store(@intFromEnum(FutureState.errored), .release);
        self.wakeFiberWaiters();
    }

    pub fn cachedErrorInfo(self: *const Future) *const ErrorInfo {
        return @ptrFromInt(self.result.error_info_bits);
    }

    /// Mark this future as a blackhole. Wakes waiters so they observe
    /// the new state and return an error.
    pub fn blackhole(self: *Future) void {
        self.claimer.store(INVALID_CLAIMER, .monotonic);
        self.state.store(@intFromEnum(FutureState.blackhole), .release);
        self.wakeFiberWaiters();
    }

    /// Drain the waiter list under the lock, then call each waiter's
    /// `wake_fn` outside the lock so a slow wake doesn't block other
    /// resolvers waiting to drain their own (different) futures' lists.
    fn wakeFiberWaiters(self: *Future) void {
        self.waiters_mu.lock();
        var head = self.waiters_head;
        self.waiters_head = null;
        self.waiters_mu.unlock();
        while (head) |w| {
            const next = w.next;
            w.next = null;
            w.wake_fn(w);
            head = next;
        }
    }
};

/// Atomic lazy thunk: a `Future` plus a `ThunkTarget` (what to
/// evaluate) plus a `demanded` flag. `demanded` distinguishes a thunk
/// resolved because a real caller observed it from one resolved only
/// by speculative pre-forcing. Lazy renderers (XML lazy mode) treat
/// the latter as "unevaluated" so speculation stays invisible to
/// users.
pub const Thunk = struct {
    future: Future,
    target: ThunkTarget,

    pub fn init(closure: Value) Thunk {
        return .{
            .future = Future.init(),
            .target = .{ .closure = closure },
        };
    }

    pub fn initBytecode(chunk_id: ChunkId, upvalues: []const Value) Thunk {
        return .{
            .future = Future.init(),
            .target = .{ .bytecode = .{ .chunk_id = chunk_id, .upvalues = upvalues } },
        };
    }

    /// A "cell" thunk: holds a Value to be forced lazily. Used by
    /// `builtins.deepSeq`-style memoisation and by `make_cell` where
    /// the wrapped value is known at construction time.
    pub fn initPassThrough(value: Value) Thunk {
        return .{
            .future = Future.init(),
            .target = .{ .pass_through = value },
        };
    }

    /// A "binding cell" thunk: created by `init_cell_slot` for
    /// recursive let bindings, BEFORE the RHS is computed. The cell is
    /// born in `.evaluating` claimed by the creating fiber so any
    /// concurrent force attempt sees BUSY and parks on the waiter list
    /// instead of CAS-claiming the placeholder. The creating fiber
    /// later publishes the real binding via `publishCellBinding(val)`,
    /// which writes `target = pass_through(val)` and transitions back
    /// to `.unresolved` (keeping pass_through laziness — the cell
    /// forces `val` only when consumers actually force the cell).
    /// Without the EVALUATING-on-init guard, a fiber could CAS-claim
    /// the cell while it still wraps the placeholder null and resolve
    /// the cell to null, freezing the binding before the creator could
    /// publish.
    pub fn initBindingCell(claimer: ClaimerId) Thunk {
        return .{
            .future = Future.initClaimed(claimer),
            // Placeholder; never observed since no fiber can CAS-claim
            // an `.evaluating` cell, and `publishCellBinding` overwrites
            // `target` before transitioning back to `.unresolved`.
            .target = .{ .pass_through = Value.null_val },
        };
    }

    pub inline fn markDemanded(self: *Thunk) void {
        self.future.markDemanded();
    }

    pub inline fn isDemanded(self: *const Thunk) bool {
        return self.future.isDemanded();
    }

    /// Publish a binding cell's value (see `initBindingCell`). Writes
    /// `target = pass_through(value)` and transitions `.evaluating →
    /// .unresolved` so the next force runs the normal pass_through
    /// path. Ordering: the plain write to `target` is published by the
    /// release-store inside `future.reset`, which pairs with
    /// `tryForce`'s acquire-load.
    pub fn publishCellBinding(self: *Thunk, value: Value) void {
        self.target = .{ .pass_through = value };
        self.future.reset();
    }

    // Delegators to the embedded Future. Kept thin (and `inline` for
    // the hot ones) so callers can keep using `thunk.tryForce(...)`,
    // `thunk.resolve(...)`, etc., with no extra call frame in the hot
    // force path.

    pub inline fn tryForce(self: *Thunk, claimer: ClaimerId) ForceOutcome {
        return self.future.tryForce(claimer);
    }

    pub inline fn enrollWaiter(self: *Thunk, waiter: *Waiter) bool {
        return self.future.enrollWaiter(waiter);
    }

    pub inline fn resolve(self: *Thunk, value: Value) void {
        self.future.resolve(value);
    }

    pub fn reset(self: *Thunk) void {
        self.future.reset();
    }

    pub fn markErrored(self: *Thunk, info: *ErrorInfo) void {
        self.future.markErrored(info);
    }

    pub inline fn cachedErrorInfo(self: *const Thunk) *const ErrorInfo {
        return self.future.cachedErrorInfo();
    }

    pub fn blackhole(self: *Thunk) void {
        self.future.blackhole();
    }

    /// Identity equality. Two thunks are the same object iff they live at
    /// the same heap slot — there is no structural notion of thunk equality.
    pub fn idEq(self: *const Thunk, other: *const Thunk) bool {
        return self == other;
    }
};

test "thunk: cross-worker enroll + resolve signals waiter" {
    var thunk = Thunk.init(Value.null_val);

    const Forcer = struct {
        fn run(th: *Thunk, value: i64, ready: *std.atomic.Value(u8), release_now: *std.atomic.Value(u8)) void {
            switch (th.tryForce(makeClaimer(0))) {
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

    // Worker 1 sees .busy, enrolls a waiter that flips an atomic flag
    // when the resolver fires.
    switch (thunk.tryForce(makeClaimer(0x10000000))) {
        .busy => {},
        else => unreachable,
    }
    var signaled: std.atomic.Value(u8) = .init(0);
    const W = struct {
        waiter: Waiter,
        signaled: *std.atomic.Value(u8),
        fn wake(w: *Waiter) void {
            const self: *@This() = @fieldParentPtr("waiter", w);
            self.signaled.store(1, .release);
        }
    };
    var w: W = .{ .waiter = .{ .wake_fn = W.wake }, .signaled = &signaled };
    try std.testing.expect(thunk.enrollWaiter(&w.waiter));

    release_now.store(1, .release);
    while (signaled.load(.acquire) == 0) std.atomic.spinLoopHint();
    t.join();

    switch (thunk.tryForce(makeClaimer(0x10000000))) {
        .already_resolved => |v| try std.testing.expectEqual(@as(i64, 99), v.asInt()),
        else => return error.UnexpectedOutcome,
    }
}

test "thunk: same claimer recursive force returns blackhole" {
    var thunk = Thunk.init(Value.null_val);
    const me = makeClaimer(0);

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

test "thunk: enrollWaiter adds to list and resolve drains it" {
    var thunk = Thunk.init(Value.null_val);

    const me = makeClaimer(0);
    const other = makeClaimer(1);

    // Claim as slot 0.
    switch (thunk.tryForce(me)) {
        .claimed => {},
        else => return error.UnexpectedOutcome,
    }
    // Slot 1 hits .busy and enrolls.
    switch (thunk.tryForce(other)) {
        .busy => {},
        else => return error.UnexpectedOutcome,
    }

    var woken: std.atomic.Value(u32) = .init(0);
    const W = struct {
        waiter: Waiter,
        woken: *std.atomic.Value(u32),
        fn wake(w: *Waiter) void {
            const self: *@This() = @fieldParentPtr("waiter", w);
            _ = self.woken.fetchAdd(1, .acq_rel);
        }
    };
    var ws: [3]W = .{
        .{ .waiter = .{ .wake_fn = W.wake }, .woken = &woken },
        .{ .waiter = .{ .wake_fn = W.wake }, .woken = &woken },
        .{ .waiter = .{ .wake_fn = W.wake }, .woken = &woken },
    };
    try std.testing.expect(thunk.enrollWaiter(&ws[0].waiter));
    try std.testing.expect(thunk.enrollWaiter(&ws[1].waiter));
    try std.testing.expect(thunk.enrollWaiter(&ws[2].waiter));

    thunk.resolve(Value.int(42));
    try std.testing.expectEqual(@as(u32, 3), woken.load(.acquire));
}

test "thunk: enrollWaiter refuses to enroll on already-resolved thunk" {
    var thunk = Thunk.init(Value.null_val);
    const me = makeClaimer(0);

    switch (thunk.tryForce(me)) {
        .claimed => {},
        else => return error.UnexpectedOutcome,
    }
    thunk.resolve(Value.int(7));

    const W = struct {
        waiter: Waiter,
        fn wake(_: *Waiter) void {}
    };
    var w: W = .{ .waiter = .{ .wake_fn = W.wake } };
    try std.testing.expect(!thunk.enrollWaiter(&w.waiter));
}

test "thunk: different fibers see .busy, not blackhole" {
    // Distinct claimers (different fiber ids) must not falsely report
    // recursion when one touches a thunk the other claimed.
    var thunk = Thunk.init(Value.null_val);
    const slot_a = makeClaimer(0);
    const slot_b = makeClaimer(1);

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

test "thunk: errored caches error and replays on next force" {
    const allocator = std.testing.allocator;
    var thunk = Thunk.init(Value.null_val);
    defer freeErroredInfoForTest(&thunk, allocator);
    const me = makeClaimer(0);

    switch (thunk.tryForce(me)) {
        .claimed => {},
        else => return error.UnexpectedOutcome,
    }
    const owned_msg = try allocator.dupe(u8, "bad value");
    const info = try allocator.create(ErrorInfo);
    info.* = .{ .err = error.NixThrow, .message = owned_msg };
    thunk.markErrored(info);

    switch (thunk.tryForce(makeClaimer(1))) {
        .errored => |got| {
            try std.testing.expectEqual(@as(anyerror, error.NixThrow), got.*.err);
            try std.testing.expect(got.*.message != null);
            try std.testing.expectEqualStrings("bad value", got.*.message.?);
        },
        else => return error.ExpectedErroredOutcome,
    }
    // Replay is idempotent.
    switch (thunk.tryForce(makeClaimer(2))) {
        .errored => |got| try std.testing.expectEqual(@as(anyerror, error.NixThrow), got.*.err),
        else => return error.ExpectedErroredOutcome,
    }
}

/// Test helper: mirrors `ObjectHeap`'s sidecar cleanup for thunks
/// constructed outside the heap. Walks the test thunk's sidecar info
/// (if any) and releases its allocations.
fn freeErroredInfoForTest(thunk: *Thunk, allocator: std.mem.Allocator) void {
    const s: FutureState = @enumFromInt(thunk.future.state.load(.acquire));
    if (s != .errored) return;
    const info: *ErrorInfo = @ptrFromInt(thunk.future.result.error_info_bits);
    if (info.message) |msg| allocator.free(msg);
    allocator.destroy(info);
}

test "thunk: errored wakes enrolled waiters" {
    const allocator = std.testing.allocator;
    var thunk = Thunk.init(Value.null_val);
    defer freeErroredInfoForTest(&thunk, allocator);

    const Failer = struct {
        fn run(alloc: std.mem.Allocator, th: *Thunk, claimed_signal: *std.atomic.Value(u8), go: *std.atomic.Value(u8)) void {
            switch (th.tryForce(makeClaimer(0))) {
                .claimed => {},
                else => return,
            }
            claimed_signal.store(1, .release);
            while (go.load(.acquire) == 0) std.atomic.spinLoopHint();
            const info = alloc.create(ErrorInfo) catch return;
            info.* = .{ .err = error.NixThrow, .message = null };
            th.markErrored(info);
        }
    };

    var claimed_signal: std.atomic.Value(u8) = .init(0);
    var go: std.atomic.Value(u8) = .init(0);
    var t = try std.Thread.spawn(.{}, Failer.run, .{ allocator, &thunk, &claimed_signal, &go });

    while (claimed_signal.load(.acquire) == 0) std.atomic.spinLoopHint();

    switch (thunk.tryForce(makeClaimer(0x10000000))) {
        .busy => {},
        else => return error.ExpectedBusy,
    }

    var signaled: std.atomic.Value(u8) = .init(0);
    const W = struct {
        waiter: Waiter,
        signaled: *std.atomic.Value(u8),
        fn wake(w: *Waiter) void {
            const self: *@This() = @fieldParentPtr("waiter", w);
            self.signaled.store(1, .release);
        }
    };
    var w: W = .{ .waiter = .{ .wake_fn = W.wake }, .signaled = &signaled };
    try std.testing.expect(thunk.enrollWaiter(&w.waiter));

    go.store(1, .release);
    while (signaled.load(.acquire) == 0) std.atomic.spinLoopHint();
    t.join();

    switch (thunk.tryForce(makeClaimer(0x10000000))) {
        .errored => {},
        else => return error.ExpectedErroredOutcome,
    }
}

test "thunk: reset wakes waiters and lets them retry" {
    var thunk = Thunk.init(Value.null_val);

    const Failer = struct {
        fn run(th: *Thunk, claimed_signal: *std.atomic.Value(u8), go: *std.atomic.Value(u8)) void {
            switch (th.tryForce(makeClaimer(0))) {
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

    switch (thunk.tryForce(makeClaimer(0x10000000))) {
        .busy => {},
        else => return error.ExpectedBusy,
    }

    var signaled: std.atomic.Value(u8) = .init(0);
    const W = struct {
        waiter: Waiter,
        signaled: *std.atomic.Value(u8),
        fn wake(w: *Waiter) void {
            const self: *@This() = @fieldParentPtr("waiter", w);
            self.signaled.store(1, .release);
        }
    };
    var w: W = .{ .waiter = .{ .wake_fn = W.wake }, .signaled = &signaled };
    try std.testing.expect(thunk.enrollWaiter(&w.waiter));

    go.store(1, .release);
    while (signaled.load(.acquire) == 0) std.atomic.spinLoopHint();
    t.join();

    // After reset, the thunk is back to .unresolved — a fresh tryForce
    // should claim it.
    switch (thunk.tryForce(makeClaimer(0x10000000))) {
        .claimed => {},
        else => return error.ExpectedClaimedAfterReset,
    }
}
