//! Fiber-scoped execution identity.
//!
//! Every `WorkerFiber` owns one `ExecutionContext`; its VM — and every
//! nested VM created while running on that fiber (imports, render/force
//! bodies) — reads identity through `VM.ctx`, a pointer to it. That makes
//! identity structural: nested VMs *cannot* diverge from their fiber (the
//! historical failure mode was a nested VM whose creation site forgot to
//! copy a flag — 5d3b97d silently killed the derivation span, the waiting
//! line, and the prof-main crit track for two days).
//!
//! Lifetime and ownership:
//!   - The record lives exactly as long as its fiber (stable memory — it is
//!     embedded in the `WorkerFiber`, which is never reallocated).
//!   - Single writer: only the fiber's driving worker mutates it, and only
//!     between resumes — `allocateFiber` bakes the claim id once,
//!     `runTopLevel(s)` dresses the demand role on each top fiber before its
//!     first resume, and `runFiber`'s finished arm resets the role before the
//!     fiber recycles. Readers (the VM run paths) only see it while the fiber
//!     runs, sequenced by the same handoff that publishes all other fiber
//!     state.

const std = @import("std");
const thunk_mod = @import("runtime").thunk;
const future_mod = @import("runtime").future;
const eval_progress = @import("../../observ.zig").progress;

/// Native-stack headroom reserved below `stack_limit`: the guard trips this
/// far from the mapping's end so the deepest single force step between two
/// guard checks — plus the error-capture/unwind that follows — completes
/// without running off the stack. 512 KiB is generous against the few-KiB
/// force-frame nest; the check is per `forceThunkImpl` (once per chain link).
pub const stack_guard_margin: usize = 512 * 1024;

pub const ExecutionContext = struct {
    /// Globally-unique claim identity for thunk forces — `makeClaimer` of
    /// the owning fiber's id. Baked once at fiber allocation and permanent
    /// for the fiber's life (it survives task recycles, unlike the role
    /// fields below). `invalid_claimer` only in the static default (VMs not
    /// bound to any fiber).
    claimer_id: future_mod.ClaimerId = future_mod.invalid_claimer,
    /// Lowest native stack address the running fiber may touch before the
    /// thunk-force guard trips a graceful "stack overflow" (`= stack base +
    /// stack_guard_margin`). Baked once at fiber allocation from the fiber's
    /// own stack, like `claimer_id`. 0 for VMs not bound to a fiber (tools,
    /// standalone test VMs on the main thread) — a real address is always
    /// ≥ 0, so the `frameAddress() < stack_limit` compare never fires there.
    stack_limit: usize = 0,
    /// True only on a top-level DEMAND fiber for the duration of one
    /// top-level entry: its blocking waits on busy thunks are the serial
    /// critical path (crit track, "waiting on" line). Set by
    /// `Worker.runTopLevel(s)`; cleared by the recycle reset.
    is_demand: bool = false,
    /// Parallel top-level demand entries intentionally do not contribute to
    /// the evaluator's single-run diagnostic trace. The trace is not a
    /// concurrent data structure, and build reports failures per input.
    parallel_demand: bool = false,
    /// The demand-only stage-stack half of the progress protocol. Non-null
    /// ONLY on the demand fiber: the stage stack is a single-writer LIFO
    /// owned by the demand path, and a stray off-demand begin/end corrupts
    /// it (the historical TTY-only --workers>1 SIGSEGV/hang). Off-demand
    /// work reports via the thread-safe `VM.progress_spans` instead — don't
    /// add a bypass.
    progress_stage: ?eval_progress.StageSink = null,
    /// Head of the in-progress `builtins.scopedImport` path chain. Unlike an
    /// OS-thread-local, this travels with the fiber when work stealing resumes
    /// it on another worker. Frames themselves live on the suspended fiber's
    /// stack and are popped before that stack can be recycled.
    scoped_import_top: ?*const ScopedImportFrame = null,
    /// Fiber-owned waiter and yield operation used by VM force paths without
    /// importing the concrete WorkerFiber representation.
    park: ?ParkHandle = null,

    /// Neutral identity for VMs not bound to any fiber (standalone test
    /// VMs, tools). Static and immutable — never dressed.
    pub const default_instance: ExecutionContext = .{};

    /// Clear the demand-role fields when the fiber recycles onto the free
    /// list (a reused fiber must not mislabel its next task as demand).
    /// The claim id is permanent and survives.
    pub fn resetRole(self: *ExecutionContext) void {
        // A scoped-import frame is stack-scoped and must have unwound before
        // the fiber can finish and return to the recycle list.
        std.debug.assert(self.scoped_import_top == null);
        self.is_demand = false;
        self.parallel_demand = false;
        self.progress_stage = null;
    }
};

pub const ParkHandle = struct {
    waiter: *future_mod.Waiter,
    context: *anyopaque,
    yield_fn: *const fn (context: *anyopaque) void,

    pub fn yield(self: ParkHandle) void {
        self.yield_fn(self.context);
    }
};

/// One node in a fiber's active scoped-import chain. Kept here, beside the
/// owning head pointer, so import coordination does not smuggle fiber-local
/// state through OS-thread-local storage.
pub const ScopedImportFrame = struct {
    path: []const u8,
    next: ?*const ScopedImportFrame,
};

/// The demand-role half of an `ExecutionContext` — what `Worker.runTopLevel`
/// installs on the top fiber's ctx for one top-level entry. Supplied per
/// call by the embedder (eval.zig reads its progress state fresh each run,
/// so a sink (re)installed between runs — the repl — needs no worker-side
/// bookkeeping).
pub const DemandRole = struct {
    progress_stage: ?eval_progress.StageSink = null,
};
