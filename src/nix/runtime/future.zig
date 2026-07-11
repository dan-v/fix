//! The lock-free one-shot cell that `Thunk` (and `eval/imports.zig`'s
//! `ImportEntry`) is built on: a futex-shaped `state` word plus a
//! claimer id and a fiber waiter list.
//!
//! A `Future` is claimed once — the first fiber to CAS the state word
//! from `.unresolved` to `.evaluating` runs the work; every other fiber
//! enrolls a `Waiter` and yields until the claimer publishes a terminal
//! state (`.resolved` / `.errored` / `.blackhole`) or resets it. The
//! embedder owns the result payload; the `Future` owns only the
//! transition protocol and the parking list. All state transitions
//! follow release-acquire pairs so a plain result store made before
//! `publish` is visible to any reader that acquire-loads the terminal
//! state via `tryClaim`. This is the concurrency core — the atomic
//! orderings here are load-bearing.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const stable = @import("base").sync;
const TargetKind = @import("thunk.zig").TargetKind;

/// `-Dprof-main` age-at-force probe support: every Future carries its
/// creation TSC so the profiler can measure how long a thunk existed
/// before main demanded it (the look-ahead speculation ceiling). The
/// field is `void` (zero bytes) on normal builds.
pub const created_tsc_enabled: bool = build_options.prof_main and builtin.cpu.arch == .x86_64;

const CreatedTsc = if (created_tsc_enabled) u64 else void;

/// `-Dprof-main` demand-context probe support: was this thunk created by
/// a DEMAND fiber (main's chain) vs. a speculative helper task? Set by
/// `ObjectHeap.add` from the per-worker `spec_ctx` flag right after the
/// slot is filled. Zero bytes on normal builds.
pub const CreatedDemand = if (created_tsc_enabled) bool else void;

pub inline fn initCreatedDemand() CreatedDemand {
    return if (comptime created_tsc_enabled) false else {};
}

inline fn nowCreatedTsc() CreatedTsc {
    if (comptime !created_tsc_enabled) return {};
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdtsc"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
        :
        : .{ .memory = true });
    return (@as(u64, high) << 32) | @as(u64, low);
}

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

/// Bare outcome of a claim attempt — no payload. The embedder
/// (`Thunk`/`ImportEntry`) owns its typed result/error storage and
/// reads it itself once `tryClaim` reports a terminal state. Keeping
/// the value out of `Future` lets `Thunk` overlap its resolved
/// `result` with its still-unresolved `target` (never live at once),
/// shrinking the hottest, most-numerous heap object.
pub const ClaimResult = enum { already_resolved, claimed, blackhole, busy, errored };

/// Shared claim+wait state machine. Both `Thunk` and `ImportEntry`
/// embed one. A `Future` owns: a 5-state lifecycle, a claimer id, a
/// `demanded` flag, and a fiber waiter list. It deliberately does NOT
/// own the result — the embedding struct stores its own typed result
/// (a `Value`, a `*ErrorInfo`, or in `Thunk`'s case a `result`/`target`
/// union) and reads/writes it around the state transitions. Keeping the
/// result out of `Future` lets `Thunk` overlap its resolved value with
/// its unresolved target (never live at once), shrinking the hottest,
/// most-numerous heap object.
///
/// `tryClaim` is the central method. The first caller to observe
/// `.unresolved` CAS-claims to `.evaluating` and gets `.claimed` — it
/// must compute the work, write the embedder's result slot, then call
/// exactly one of `publish`, `publishErrored`, `reset`, or `blackhole`.
/// Other callers see `.busy` and enroll a `Waiter` via `enrollWaiter`.
///
/// Memory model: the embedder writes its result slot with a plain store
/// BEFORE calling `publish`/`publishErrored`; the release-store of
/// `state` inside those methods publishes that write to any reader that
/// acquire-loads the terminal state via `tryClaim`.
pub const Future = struct {
    state: std.atomic.Value(u32),
    claimer: std.atomic.Value(ClaimerId),
    /// Was this future's resolution observed by a real caller (vs.
    /// pre-forced by speculation / fan-out)? Used by lazy renderers
    /// (XML lazy mode) to treat unobserved resolutions as still
    /// "unevaluated" so speculation stays invisible.
    demanded: std.atomic.Value(u8),
    /// Embedder-owned discriminant, free in `Future`'s padding. `Thunk`
    /// stores its `ThunkTarget`'s active arm here (see `TargetKind`);
    /// `ImportEntry` leaves it at the default. Plain (non-atomic): set
    /// once at construction, immutable thereafter, so the claimer that
    /// reads it after an acquiring `tryClaim` sees the construction
    /// store published through whatever made the thunk reachable.
    target_kind: TargetKind = .closure,
    /// Singly-linked list of fibers parked on this future. Manipulated
    /// only under `waiters_mu`. Empty in the common (uncontended) case
    /// where the claimer resolves before any other fiber tries to force.
    waiters_head: ?*Waiter,
    waiters_mu: stable.SpinMutex,
    /// Creation TSC for the `-Dprof-main` age-at-force probe; zero bytes
    /// (`void`) on normal builds. See `created_tsc_enabled`.
    created_tsc: CreatedTsc,
    /// Demand-context bit for the `-Dprof-main` creation-context probe;
    /// zero bytes (`void`) on normal builds. See `CreatedDemand`.
    created_demand: CreatedDemand = initCreatedDemand(),
    /// `-Dprof-main` only: was this future OLD (existed >= 2^21 cycles,
    /// ~0.6ms — the age-at-force probe's offloadable threshold) when the
    /// first real demand observed it? Distinguishes "prefetchable ahead
    /// of demand" from "demanded immediately, no headroom" in the exit
    /// census. Racy-benign (racing first-demanders write ~the same value).
    demanded_old: CreatedDemand = initCreatedDemand(),

    pub fn init() Future {
        return .{
            .state = .init(@intFromEnum(FutureState.unresolved)),
            .claimer = .init(INVALID_CLAIMER),
            .demanded = .init(0),
            .waiters_head = null,
            .waiters_mu = .{},
            .created_tsc = nowCreatedTsc(),
        };
    }

    /// `init` but stamping the embedder's `target_kind`. Used by the
    /// `Thunk` constructors so the bare `ThunkTarget` union has its
    /// active arm recorded.
    pub fn initFor(kind: TargetKind) Future {
        var f = init();
        f.target_kind = kind;
        return f;
    }

    /// Construct a Future born in `.resolved` with `demanded = 0`. The
    /// embedder writes its own result slot before publishing the thunk;
    /// forcing it then hits the resolved fast path immediately. Lazy
    /// renderers (XML) see resolved+undemanded and print
    /// `<unevaluated />`. (See `Thunk.initLazyShell`.)
    pub fn initResolved() Future {
        return .{
            .state = .init(@intFromEnum(FutureState.resolved)),
            .claimer = .init(INVALID_CLAIMER),
            .demanded = .init(0),
            .waiters_head = null,
            .waiters_mu = .{},
            .created_tsc = nowCreatedTsc(),
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
            .waiters_head = null,
            .waiters_mu = .{},
            .created_tsc = nowCreatedTsc(),
        };
    }

    pub inline fn markDemanded(self: *Future) void {
        // Skip the cache-line-evicting store when the flag is already
        // set. Hot thunks get re-forced repeatedly; on each re-force
        // the unconditional store invalidated other workers' copies of
        // the line even though the value didn't change. Idempotent
        // write — racing observers all store the same value.
        if (self.demanded.load(.monotonic) == 0) {
            // Probe (`-Dprof-main`): record whether the future sat >= 2^21
            // cycles (~0.6ms) before its first real demand — matches
            // `prof.AGE_OLD_THRESHOLD` (can't import probe code from runtime).
            if (comptime created_tsc_enabled) {
                self.demanded_old = (nowCreatedTsc() -| self.created_tsc) >= (1 << 21);
            }
            self.demanded.store(1, .release);
        }
    }

    pub inline fn isDemanded(self: *const Future) bool {
        return self.demanded.load(.acquire) != 0;
    }

    /// Non-claiming peek: is this future still being evaluated by *someone*?
    /// A single acquire-load, no CAS — safe to poll from a waiter that wants
    /// to spin briefly before committing to enroll+suspend (see
    /// `force.zig`'s `.busy` spin-before-enroll). A `false` return means the
    /// state left `.evaluating` (resolved / errored / reset); the caller
    /// should re-`tryClaim` to observe the terminal state.
    pub inline fn isEvaluating(self: *const Future) bool {
        return self.state.load(.acquire) == @intFromEnum(FutureState.evaluating);
    }

    /// Try to claim this future for evaluation by `claimer`. Returns a
    /// bare outcome tag; on `.already_resolved`/`.errored` the caller
    /// reads the value/error from the embedder's own result slot.
    ///   - `.already_resolved`: the result is published; read the
    ///     embedder's result slot.
    ///   - `.claimed`: this caller has claimed; must compute, write the
    ///     embedder's result, then call `publish`, `publishErrored`,
    ///     `reset`, or `blackhole`.
    ///   - `.blackhole`: the SAME claim identity is already evaluating —
    ///     real recursion (a fiber re-entering itself).
    ///   - `.busy`: a different claim identity is evaluating; caller
    ///     must enroll on the waiter list and yield.
    ///   - `.errored`: the body ran and failed deterministically; caller
    ///     should re-raise the cached error.
    pub fn tryClaim(self: *Future, claimer: ClaimerId) ClaimResult {
        while (true) {
            const s: FutureState = @enumFromInt(self.state.load(.acquire));
            switch (s) {
                .resolved => return .already_resolved,
                .blackhole => return .blackhole,
                .errored => return .errored,
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

    /// `tryClaim` for a single-worker process (`--workers=1`): exactly one
    /// OS thread touches thunk futures, so the claim CAS — a full fence +
    /// serialized RMW on x86, paid once per claimed force — degenerates to a
    /// plain load/store pair. Fibers on that one thread interleave only at
    /// yield points, never inside this function, so the read-check-write is
    /// atomic with respect to every other future user. Blackhole detection
    /// (same-claimer re-entry) is unchanged. The caller owns the solo-ness
    /// proof (`VM.solo`, derived from `Scheduler.worker_count == 1` before
    /// any helper could exist); mixing solo and atomic calls on one thread
    /// is fine — plain and atomic accesses to the same word are ordered by
    /// program order there.
    pub fn tryClaimSolo(self: *Future, claimer: ClaimerId) ClaimResult {
        // `.monotonic` compiles to plain mov on x86 — the win is dropping
        // the CAS, not the atomic qualifier. Staying atomic keeps any
        // overlooked cross-thread observer (a future sampler, a debug
        // walker) merely stale instead of racy.
        switch (@as(FutureState, @enumFromInt(self.state.load(.monotonic)))) {
            .resolved => return .already_resolved,
            .blackhole => return .blackhole,
            .errored => return .errored,
            .unresolved => {
                self.state.store(@intFromEnum(FutureState.evaluating), .monotonic);
                self.claimer.store(claimer, .monotonic);
                return .claimed;
            },
            .evaluating => return if (self.claimer.load(.monotonic) == claimer) .blackhole else .busy,
        }
    }

    /// `publish` for a single-worker process: plain stores, and the waiter
    /// drain skips the `waiters_mu` RMW when nobody ever enrolled (the
    /// overwhelmingly common case — enrollment means some same-thread fiber
    /// observed `.busy` and parked, and its list push is plainly visible
    /// here). Same solo-ness contract as `tryClaimSolo`.
    pub fn publishSolo(self: *Future) void {
        self.claimer.store(INVALID_CLAIMER, .monotonic);
        self.state.store(@intFromEnum(FutureState.resolved), .monotonic);
        if (self.waiters_head != null) self.wakeFiberWaiters();
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

    /// Publish the embedder's already-written result and wake all
    /// enrolled fiber waiters. The caller MUST have stored its result
    /// slot before this call; the release-store of `state` publishes it.
    pub fn publish(self: *Future) void {
        self.claimer.store(INVALID_CLAIMER, .release);
        self.state.store(@intFromEnum(FutureState.resolved), .release);
        self.wakeFiberWaiters();
    }

    /// Drop back to `.unresolved` and wake waiters so they can retry.
    /// Use only for *transient* errors (out-of-memory, stack overflow,
    /// scheduler contention) — deterministic failures should go through
    /// `publishErrored` instead. The embedder's `target` is left intact
    /// (a transient failure never overwrote it with a result).
    pub fn reset(self: *Future) void {
        self.claimer.store(INVALID_CLAIMER, .monotonic);
        self.state.store(@intFromEnum(FutureState.unresolved), .release);
        self.wakeFiberWaiters();
    }

    /// Publish a deterministic body failure and wake waiters. The
    /// embedder has already stashed the `*ErrorInfo` in its result slot
    /// and owns it (and any heap-allocated `info.message`) so it can
    /// release it at teardown.
    pub fn publishErrored(self: *Future) void {
        self.claimer.store(INVALID_CLAIMER, .monotonic);
        self.state.store(@intFromEnum(FutureState.errored), .release);
        self.wakeFiberWaiters();
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
