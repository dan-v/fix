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
    upvalue_count: u32,
    storage: Storage,

    /// Up to `INLINE_CAP` upvalues live *inline* in the thunk — one
    /// allocation, one cache line on the hot force path, no separate
    /// `values`-store range to chase. The overwhelming majority of
    /// bytecode thunks capture 0-2 upvalues. Wider captures spill to a
    /// slice into the heap's `values` store. The discriminant is
    /// `upvalue_count` itself (no tag word), which keeps the struct at
    /// the same 24 bytes the old `[]const Value` slice occupied — so the
    /// (very hot, millions-live) Thunk doesn't grow.
    pub const INLINE_CAP: u32 = 2;

    const Storage = union {
        inline_vals: [INLINE_CAP]Value,
        spilled: []const Value,
    };

    /// The captured upvalues. For inline storage the returned slice
    /// points into `self`, so this MUST be called through a stable
    /// pointer to the thunk (the heap's append-only store gives stable
    /// addresses) — never on a by-value copy of the thunk.
    pub fn upvalues(self: *const BytecodeThunk) []const Value {
        if (self.upvalue_count <= INLINE_CAP) return self.storage.inline_vals[0..self.upvalue_count];
        return self.storage.spilled;
    }
};

/// What a thunk evaluates when forced.
///
///   - `.closure` and `.bytecode` are computed targets: forcing invokes
///     bytecode or a builtin and the result is stored.
///   - `.pass_through` is a memoization wrapper: the underlying Value is
///     forced and the result becomes the thunk's resolved value. This is
///     how the compiler models recursive let-binding cells.
/// Frameless lazy attr access: forcing computes `getAttrValue(base,
/// name)` directly, with no frame push or bytecode dispatch. The
/// overwhelmingly common `someUpvalue.attr` thunk shape (`config.foo`,
/// `lib.bar`, attrset-pattern param lookups) would otherwise allocate a
/// `bytecode` thunk over a 7-byte `get_upvalue_attr; ret` chunk and run a
/// whole isolated frame to force it — `run_isolated_frame` is the biggest
/// machinery bucket on the serial critical path.
pub const AttrAccess = struct {
    base: Value,
    name: types.InternId,
};

/// Discriminant for `ThunkTarget`. Stored as a plain byte in `Future`'s
/// padding (`Future.target_kind`) rather than as a `union(enum)` tag —
/// the union is 8-aligned (it holds `Value`s and pointers), so an inline
/// tag would round the whole target up by 8 bytes. Externalizing the
/// 1-byte discriminant into otherwise-wasted padding shrinks the
/// (millions-live) Thunk by 8 bytes.
pub const TargetKind = enum(u8) { closure, bytecode, pass_through, attr_access };

/// Bare (untagged) union — the active arm is named by `Future.target_kind`,
/// set at construction and immutable thereafter (a target is never
/// mutated after creation except by `publishCellBinding`, which keeps
/// the same `pass_through` kind).
pub const ThunkTarget = union {
    closure: Value,
    bytecode: BytecodeThunk,
    pass_through: Value,
    attr_access: AttrAccess,
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

/// Bare outcome of a claim attempt — no payload. The embedder
/// (`Thunk`/`ImportEntry`) owns its typed result/error storage and
/// reads it itself once `tryClaim` reports a terminal state. Keeping
/// the value out of `Future` lets `Thunk` overlap its resolved
/// `result` with its still-unresolved `target` (never live at once),
/// shrinking the hottest, most-numerous heap object.
pub const ClaimResult = enum { already_resolved, claimed, blackhole, busy, errored };

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

    pub fn init() Future {
        return .{
            .state = .init(@intFromEnum(FutureState.unresolved)),
            .claimer = .init(INVALID_CLAIMER),
            .demanded = .init(0),
            .waiters_head = null,
            .waiters_mu = .{},
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

/// Atomic lazy thunk: a `Future` (claim/wait state machine) plus a
/// `result`/`target` union. `target` (what to evaluate) is the live
/// union arm while the thunk is unresolved/evaluating; `result` (the
/// resolved Value, or an `*ErrorInfo`'s bits when errored) is live once
/// the thunk reaches a terminal state. The two are never live at the
/// same instant — a thunk reads `target` to compute its value, then
/// overwrites the same bytes with `result` at resolution — so they
/// share storage, keeping the (millions-live, cache-bound) Thunk small.
/// `future.state` is the discriminant. `demanded` (inside `future`)
/// distinguishes a real observation from speculative pre-forcing so
/// lazy renderers can keep speculation invisible.
pub const Thunk = struct {
    future: Future,
    payload: Payload,

    /// Bare (untagged) union: `future.state` is the only discriminant.
    /// `.resolved`/`.errored` → read `result`; any other state → `target`.
    pub const Payload = union {
        /// Resolved Value, or (when `.errored`) the `*ErrorInfo` bits
        /// reinterpreted through `Value.bits`.
        result: Value,
        target: ThunkTarget,
    };

    pub fn init(closure: Value) Thunk {
        return .{ .future = Future.init(), .payload = .{ .target = .{ .closure = closure } } };
    }

    /// `upvalues` of length <= `BytecodeThunk.INLINE_CAP` are copied
    /// inline; wider captures keep the passed slice (the caller is
    /// responsible for it living in stable `values` storage).
    pub fn initBytecode(chunk_id: ChunkId, upvalues: []const Value) Thunk {
        var storage: BytecodeThunk.Storage = undefined;
        if (upvalues.len <= BytecodeThunk.INLINE_CAP) {
            var arr: [BytecodeThunk.INLINE_CAP]Value = undefined;
            @memcpy(arr[0..upvalues.len], upvalues);
            storage = .{ .inline_vals = arr };
        } else {
            storage = .{ .spilled = upvalues };
        }
        return .{
            .future = Future.initFor(.bytecode),
            .payload = .{ .target = .{ .bytecode = .{
                .chunk_id = chunk_id,
                .upvalue_count = @intCast(upvalues.len),
                .storage = storage,
            } } },
        };
    }

    /// A frameless attr-access thunk (see `AttrAccess`). Forcing computes
    /// `getAttrValue(base, name)` with no frame/dispatch.
    pub fn initAttrAccess(base: Value, name: types.InternId) Thunk {
        return .{ .future = Future.initFor(.attr_access), .payload = .{ .target = .{ .attr_access = .{ .base = base, .name = name } } } };
    }

    /// A "cell" thunk: holds a Value to be forced lazily. Used by
    /// `builtins.deepSeq`-style memoisation and by `make_cell` where
    /// the wrapped value is known at construction time.
    pub fn initPassThrough(value: Value) Thunk {
        return .{ .future = Future.initFor(.pass_through), .payload = .{ .target = .{ .pass_through = value } } };
    }

    /// Pre-resolved "lazy shell" thunk: wraps a value that's already
    /// computed but should still appear unevaluated to lazy renderers.
    /// Forces in O(1) (resolved fast path), prints `<unevaluated />`
    /// in XML lazy mode until a real consumer marks it demanded.
    ///
    /// Used by the compiler when an eager-buildable shape (list /
    /// attrset / lambda) sits in a context where the value is
    /// observably lazy (attrset entry, list item) — we skip the
    /// chunk-registration + bytecode-dispatch roundtrip and just
    /// wrap the already-built shell. Born `.resolved` with `result`
    /// already live, so there is no target.
    pub fn initLazyShell(value: Value) Thunk {
        return .{ .future = Future.initResolved(), .payload = .{ .result = value } };
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
        var f = Future.initClaimed(claimer);
        f.target_kind = .pass_through;
        return .{
            .future = f,
            // Placeholder; never observed since no fiber can CAS-claim
            // an `.evaluating` cell, and `publishCellBinding` overwrites
            // `target` before transitioning back to `.unresolved`.
            .payload = .{ .target = .{ .pass_through = Value.null_val } },
        };
    }

    pub inline fn markDemanded(self: *Thunk) void {
        self.future.markDemanded();
    }

    pub inline fn isDemanded(self: *const Thunk) bool {
        return self.future.isDemanded();
    }

    /// The active arm of the bare `payload.target` union. Only meaningful
    /// while the thunk is unresolved/evaluating (the states in which
    /// `target` is the live union arm).
    pub inline fn targetKind(self: *const Thunk) TargetKind {
        return self.future.target_kind;
    }

    /// Publish a binding cell's value (see `initBindingCell`). Writes
    /// `target = pass_through(value)` and transitions `.evaluating →
    /// .unresolved` so the next force runs the normal pass_through
    /// path. Ordering: the plain write to `target` is published by the
    /// release-store inside `future.reset`, which pairs with
    /// `tryClaim`'s acquire-load. The cell never reached `.resolved`,
    /// so the `target` arm of the union is still the live one.
    pub fn publishCellBinding(self: *Thunk, value: Value) void {
        self.payload = .{ .target = .{ .pass_through = value } };
        self.future.reset();
    }

    // Delegators to the embedded Future. The hot ones are `inline` so
    // the force path has no extra call frame. The value-carrying ones
    // (`tryForce`, `resolve`, `markErrored`) read/write the local
    // `payload` union — the Future itself is value-less.

    pub inline fn tryForce(self: *Thunk, claimer: ClaimerId) ForceOutcome {
        return switch (self.future.tryClaim(claimer)) {
            // The state acquire-load inside `tryClaim` pairs with the
            // release-store in `publish`/`publishErrored`, so the
            // `payload` reads below observe the published arm.
            .already_resolved => .{ .already_resolved = self.payload.result },
            .errored => .{ .errored = self.cachedErrorInfo() },
            .claimed => .claimed,
            .busy => .busy,
            .blackhole => .blackhole,
        };
    }

    pub inline fn enrollWaiter(self: *Thunk, waiter: *Waiter) bool {
        return self.future.enrollWaiter(waiter);
    }

    /// Publish `value` as the resolved result, overwriting the `target`
    /// arm, then transition to `.resolved`.
    pub inline fn resolve(self: *Thunk, value: Value) void {
        self.payload = .{ .result = value };
        self.future.publish();
    }

    pub fn reset(self: *Thunk) void {
        // Transient retry: `target` is still the live arm (a transient
        // failure never wrote `result`), so just re-arm the future.
        self.future.reset();
    }

    /// Stash the `*ErrorInfo` in the result slot (overwriting `target`)
    /// and transition to `.errored`.
    pub fn markErrored(self: *Thunk, info: *ErrorInfo) void {
        self.payload = .{ .result = .{ .bits = @intFromPtr(info) } };
        self.future.publishErrored();
    }

    pub inline fn cachedErrorInfo(self: *const Thunk) *const ErrorInfo {
        return @ptrFromInt(self.payload.result.bits);
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
    const info: *ErrorInfo = @ptrFromInt(thunk.payload.result.bits);
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
