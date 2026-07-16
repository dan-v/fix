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
//!     `runTopLevel` dresses the demand role on the top fiber before its
//!     first resume, and `runFiber`'s finished arm resets the role before
//!     the fiber recycles. Readers (the VM run paths) only see it while the
//!     fiber runs, sequenced by the same handoff that publishes all other
//!     fiber state.
//!
//! Because it is fiber-lifetime, single-writer, and at a stable address,
//! this record is the natural future home for a sampler-readable "current
//! activity" slot (the `ProgressWait` pattern: fiber writes at a
//! safepoint, sampler thread reads lock-free). Not built yet — add it here
//! when needed, not on the VM.

const thunk_mod = @import("runtime").thunk;
const future_mod = @import("runtime").future;
const eval_progress = @import("../observ.zig").progress;

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
    /// fields below). `INVALID_CLAIMER` only in the static default (VMs not
    /// bound to any fiber).
    claimer_id: future_mod.ClaimerId = future_mod.INVALID_CLAIMER,
    /// Lowest native stack address the running fiber may touch before the
    /// thunk-force guard trips a graceful "stack overflow" (`= stack base +
    /// stack_guard_margin`). Baked once at fiber allocation from the fiber's
    /// own stack, like `claimer_id`. 0 for VMs not bound to a fiber (tools,
    /// standalone test VMs on the main thread) — a real address is always
    /// ≥ 0, so the `frameAddress() < stack_limit` compare never fires there.
    stack_limit: usize = 0,
    /// True only on the top-level DEMAND fiber for the duration of one
    /// top-level entry: its blocking waits on busy thunks are the serial
    /// critical path (crit track, "waiting on" line). Set by
    /// `Worker.runTopLevel`; cleared by the recycle reset.
    is_demand: bool = false,
    /// The demand-only stage-stack half of the progress protocol. Non-null
    /// ONLY on the demand fiber: the stage stack is a single-writer LIFO
    /// owned by the demand path, and a stray off-demand begin/end corrupts
    /// it (the historical TTY-only --workers>1 SIGSEGV/hang). Off-demand
    /// work reports via the thread-safe `VM.progress_spans` instead — don't
    /// add a bypass.
    progress_stage: ?eval_progress.StageSink = null,
    /// Shared "what is the demand path blocked on" record for the progress
    /// indicator. Non-null ONLY on the demand fiber and only while progress
    /// is drawn; the demand fiber writes its blocking source loc at a busy
    /// safepoint and the progress sampler thread reads it. Precise by
    /// construction — no compensating `is_demand` gate needed at the use
    /// site, and it stays with the fiber across a steal.
    progress_wait: ?*eval_progress.ProgressWait = null,

    /// Neutral identity for VMs not bound to any fiber (standalone test
    /// VMs, tools). Static and immutable — never dressed.
    pub const default_instance: ExecutionContext = .{};

    /// Clear the demand-role fields when the fiber recycles onto the free
    /// list (a reused fiber must not mislabel its next task as demand).
    /// The claim id is permanent and survives.
    pub fn resetRole(self: *ExecutionContext) void {
        self.is_demand = false;
        self.progress_stage = null;
        self.progress_wait = null;
    }
};

/// The demand-role half of an `ExecutionContext` — what `Worker.runTopLevel`
/// installs on the top fiber's ctx for one top-level entry. Supplied per
/// call by the embedder (eval.zig reads its progress state fresh each run,
/// so a sink (re)installed between runs — the repl — needs no worker-side
/// bookkeeping).
pub const DemandRole = struct {
    progress_stage: ?eval_progress.StageSink = null,
    progress_wait: ?*eval_progress.ProgressWait = null,
};
