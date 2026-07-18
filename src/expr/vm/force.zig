//! The thunk force protocol: the claim/busy/resolved/errored state machine that
//! drives lazy evaluation, plus speculative (demand-invisible) forcing,
//! collection fan-out, and the GC safepoints — the VM's hot serial path.
//! Concurrency: a demander CAS-claims a thunk and spins then enrolls as a waiter
//! on a peer-owned `.busy` one; each evaluator OS thread owns a lazily allocated
//! thunk-result memo, published for the STW collector to mark.
const std = @import("std");
const builtin = @import("builtin");
const vm_mod = @import("context.zig");
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const ObjectId = types.ObjectId;
const thunk_mod = @import("runtime").thunk;
const future_mod = @import("runtime").future;
const Thunk = thunk_mod.Thunk;
const ThunkTarget = thunk_mod.ThunkTarget;
const clock = @import("base").clock;
const observ = @import("base").observ;
const sched_mod = @import("../eval/workers/scheduler.zig");

const access = @import("access.zig");
const closures = @import("closures.zig");
const vm_trace = @import("trace.zig");
const trace_log = @import("trace_log.zig");
const BuiltinId = @import("runtime").builtins.BuiltinId;
const prof = @import("../probe.zig").prof;
const prof_census = @import("../probe.zig").prof_census;
const vm_errors = @import("errors.zig");
const prof_path = @import("../probe.zig").prof_path;
const Chunk = @import("../bytecode.zig").chunk.Chunk;
const heap_mod = @import("runtime").heap;
const gc = @import("runtime").gc;
const thunk_trace = @import("../probe.zig").thunk_trace;
const ChunkId = types.ChunkId;
const deferred_compile = @import("../compiler/deferred.zig");
const force_label = @import("force_label.zig");
const speculate = @import("force_speculate.zig");
const thread_caches = @import("thread_caches.zig");

const critical_wait_observation: observ.SpanSpec = .{
    .category = "scheduler",
    .name = "wait",
    .begin_verb = "waiting",
    .finish_verb = "waited",
    .begin_level = std.math.maxInt(u8),
    .finish_level = std.math.maxInt(u8),
};

/// Source labels for thunks live in `force_label.zig`; re-exported for worker
/// run-quantum observations.
pub const thunkLabel = force_label.thunkLabel;

/// Bounded spin a demanded fiber does on a `.busy` (helper-owned) thunk
/// before enrolling as a waiter and suspending. Sized to catch a resolve
/// that lands within a few hundred nanoseconds — the common case when the
/// owner is nearly done — while still falling through to a real yield for
/// long waits (so the worker can run other fibers). See the `.busy` arm.
const busy_spin_before_enroll: u32 = 1024;

/// Map a thunk body to a `prof_path` key: the body's `ChunkId` (≈ a Nix
/// source location) for bytecode/closure thunks, a per-builtin key for
/// builtin closures, a synthetic key for pass-through cells. Only
/// evaluated in `-Dprof-path` builds.
inline fn pathKey(self: *VM, target: *const ThunkTarget, kind: thunk_mod.TargetKind) u32 {
    return switch (kind) {
        .bytecode => target.bytecode.chunk_id,
        .closure => switch (target.closure.kind()) {
            .closure => if (target.closure.isFunction()) target.closure.asFunctionChunkId() else if (self.heap.getClosure(target.closure.asObjectId())) |cl| cl.chunk_id else |_| prof_path.other_key,
            .builtin_closure => if (self.heap.getBuiltinClosure(target.closure.asObjectId())) |bc| prof_path.builtin_key_base + @as(u32, bc.builtin_id) else |_| prof_path.other_key,
            .builtin => prof_path.builtin_key_base + @as(u32, target.closure.asBuiltinId()),
            else => prof_path.other_key,
        },
        .pass_through => prof_path.pass_through_key,
        .attr_access => prof_path.other_key,
        .deferred => prof_path.other_key,
    };
}

const VM = vm_mod.VM;

// ---- thunk-result memo ----
//
// nixpkgs re-evaluates the same pure `lib` helpers (`lib.types.*`,
// `lib.mkXxx`, ...) with identical arguments across thousands of modules,
// producing distinct thunk objects that compute identical values — work
// the per-object thunk memoization can't share. ~10.8% of bytecode-thunk
// computations on the NixOS toplevel are such duplicates.
//
// This is a bounded, per-worker-thread (zero-contention) cache
// mapping (heap_token, chunk_id, ≤2 upvalues) → resolved Value. Before
// computing a freshly-claimed bytecode thunk we check it; a hit resolves
// the thunk to the cached value and skips re-running the body. Pure
// functions, so reuse is sound; the `heap_token` guard invalidates stale
// entries across Evaluator instances (same trick as the attr inline
// cache). Limited to ≤2-upvalue thunks so the key compares exactly with
// no allocation — that's the inline-storage majority.
const memo_size = thread_caches.memo_size;

/// GC: the thunk-result memo holds Values keyed by heap token. An
/// entry can be the momentary sole reference to a shared result, so valid
/// entries (token match) are roots. Each worker publishes its lazy cache bundle
/// into a registry the stop-the-world collector walks.
/// Register this worker's thread-local GC caches (thunk memo + attr cache)
/// so the collector can mark them. Called once per worker before it runs.
pub fn gcRegisterWorkerCaches(worker_id: u8) void {
    thread_caches.register(worker_id);
}

/// Remove cache pointers before a helper thread exits; its TLS storage becomes
/// invalid immediately afterward and must not remain visible to a later GC.
pub fn gcUnregisterWorkerCaches(worker_id: u8) void {
    thread_caches.unregister(worker_id);
}

/// Mark every registered worker's live memo entries. STW-only (peers parked).
pub fn gcMarkThunkMemo(tr: *gc.Tracer, heap: *const heap_mod.ObjectHeap) void {
    for (thread_caches.registered()) |maybe| {
        const caches = maybe orelse continue;
        for (&caches.thunk_memo) |*slot| {
            if (slot.token == heap.token) tr.markValue(heap, slot.value);
        }
    }
}

inline fn memoSlotIndex(chunk: u32, up0: u64, up1: u64) usize {
    var h: u64 = @as(u64, chunk) *% 0x9E3779B97F4A7C15;
    h ^= up0 *% 0xC2B2AE3D27D4EB4F;
    h ^= up1 *% 0x165667B19E3779F9;
    return @intCast((h ^ (h >> 29)) & (memo_size - 1));
}

const MemoKey = struct { chunk: u32, count: u8, up0: u64, up1: u64, idx: usize };

/// Build the memo key for a bytecode thunk if it's memoizable (≤2
/// upvalues), else null.
inline fn memoKeyForBytecode(b: *const thunk_mod.BytecodeThunk) ?MemoKey {
    const ups = b.upvalues();
    if (ups.len > 2) return null;
    const a0: u64 = if (ups.len >= 1) ups[0].bits else 0;
    const a1: u64 = if (ups.len >= 2) ups[1].bits else 0;
    return .{ .chunk = b.chunk_id, .count = @intCast(ups.len), .up0 = a0, .up1 = a1, .idx = memoSlotIndex(b.chunk_id, a0, a1) };
}

// ---- thunk management ----

// ---- GC roots for native code ----
//
// The collector is fully PRECISE: it never scans raw C-stacks or registers.
// Every live heap `Value` must therefore be reachable from an enumerable root
// at a collection safepoint (a `forceValue`/`forceThunk`). The roots are:
//   - the VM operand stack + frames + upvalues (bytecode ops — kept precise by
//     forcing operands *in place*; see `forceAt`/`forceTop`, never pop-then-force);
//   - the in-flight thunk force chain (`forceThunkImpl` pushes each claimed
//     thunk — roots its target closure / upvalues / attr-access base);
//   - `callValue`/`doCall`/`doTailCall` root their callee+arg for the call's
//     duration; `doCallN` keeps args on the operand stack — so a builtin's
//     arguments are rooted by whichever invoked it (`applyBuiltin` no longer
//     roots them itself);
//   - `gc_temp_roots` for anything native code holds that none of the above
//     covers (see rule below).
//
// RULE for writing a native builtin (so you get it right on the first try):
//   Your ARGUMENTS are already rooted (by the caller — doCall/callValue/doCallN). Any value you pass to
//   `forceValue`/`callValue`/`getAttrValue` is rooted for that call. List
//   elements / attr values reached THROUGH a rooted argument are covered too.
//   => You only need a scope when you stash a *newly produced* heap value in a
//      Zig-side collection (an ArrayList, a running result) and keep it across a
//      LATER force — e.g. lists a user function returns mid-loop. Then:
//
//        const scope = force.rootsBegin(self);
//        defer force.rootsEnd(self, scope);
//        ...
//        force.rootKeep(self, produced); // keep `produced` alive across later forces
//
pub const RootScope = usize;

pub inline fn rootsBegin(self: *VM) RootScope {
    return self.gc_temp_roots.items.len;
}
pub inline fn rootsEnd(self: *VM, scope: RootScope) void {
    self.gc_temp_roots.items.len = scope;
}
pub inline fn rootKeep(self: *VM, v: Value) void {
    // DORMANT GATE (the temp-root flavor of forceThunkImpl's force-chain
    // gate — see the soundness argument there): while collection is
    // unarmed these roots cannot be observed, so skip the append. Once
    // armed (or constrained from eval start), root the value normally.
    if (!self.heap.gc_root_active) return;
    self.gc_temp_roots.append(self.allocator, v) catch @panic("gc temp root oom");
}

pub fn forceThunk(self: *VM, thunk_val: Value) !Value {
    return forceThunkImpl(self, thunk_val, true);
}

/// Probe-only (`-Dprof-main`): is `v` a thunk that is ALREADY resolved?
/// Used by the repeat-force census to size resolved-value writeback.
pub inline fn profIsResolvedThunk(self: *VM, v: Value) bool {
    if (!v.isThunk()) return false;
    const thunk = self.heap.getThunkAssumeValid(v.asObjectId());
    return thunk.future.state.load(.monotonic) == @intFromEnum(future_mod.FutureState.resolved);
}

pub inline fn forceValue(self: *VM, value: Value) anyerror!Value {
    const t = prof.start(.force_value);
    defer prof.end(.force_value, t);
    return forceValueImpl(self, value, true);
}

/// Speculative force: evaluate the value (resolving thunks) without
/// marking them as demanded. Used by scheduler helpers — if no real
/// caller later observes the thunk, lazy renderers will still treat it
/// as unevaluated.
pub fn forceValueSpeculative(self: *VM, value: Value) anyerror!Value {
    // Mark this VM as running speculative work for the duration of the
    // force. `makeThunk` keys off this to decide whether new thunks
    // created during evaluation should themselves be submitted for
    // speculation — they shouldn't, otherwise a single speculative task
    // can cascade into the rest of the dependency graph.
    const saved = self.in_speculation;
    self.in_speculation = true;
    // Mirror the fiber-state flag into the per-worker-thread creation-
    // context flag so thunks created inside this speculative force (incl.
    // by nested import VMs, which never toggle `in_speculation`) are
    // tagged as spec-context. `Worker.runFiber` re-syncs it whenever a
    // different fiber resumes on this thread.
    self.heap.setSpecCtx(true);
    defer {
        self.in_speculation = saved;
        self.heap.setSpecCtx(saved);
    }
    return forceValueImpl(self, value, false);
}

pub inline fn forceValueImpl(self: *VM, value: Value, demand: bool) anyerror!Value {
    // Bounded speculation (`FIX_SIBLING` / band budget): a
    // speculative task's cascade is abandoned once it has created more
    // thunks than its budget. Checked here (not just at claimed forces)
    // because creation-heavy builtins force sub-values far more often
    // than they claim thunks. One predictable `in_speculation` branch on
    // the demand path.
    if (self.in_speculation and self.spec_create_left != vm_mod.no_spec_budget) {
        if (specCreateExhausted(self)) return error.SpeculativeBail;
    }
    if (!value.isThunk()) {
        if (comptime prof.enabled) {
            if (demand and self.workerId() == 0) prof_census.fv_plain += 1;
        }
        return value;
    }
    // Inline the resolved-thunk fast path. The vast majority of forces
    // hit an already-resolved thunk in steady state (workers and
    // demand-driven fan-out tend to resolve hot thunks early); folding
    // the resolved-check into the caller's bytecode dispatch saves the
    // forceThunkImpl call frame on the hottest path. Everything else
    // (claimed/busy/blackhole/errored) goes through the full function.
    // `getThunkAssumeValid` skips the tagged-union dispatch — we just
    // matched on `discriminant == .thunk`, so the object slot must be
    // a `Thunk`.
    const thunk = self.heap.getThunkAssumeValid(value.asObjectId());
    const state = thunk.future.state.load(.acquire);
    if (state == @intFromEnum(future_mod.FutureState.resolved)) {
        if (demand) {
            // Discovery probe: main is the first real demander of an
            // already-resolved thunk ⇒ a helper resolved it ahead of demand.
            if (comptime prof.enabled) {
                if (self.workerId() == 0) {
                    prof_census.fv_resolved += 1;
                    if (!thunk.isDemanded()) prof_census.disc.resolved_ahead += 1;
                }
            }
            thunk.markDemanded();
        }
        const r = thunk.payload.result;
        // A resolved thunk should hold WHNF, but a tail `call`/functor/builtin
        // can publish a *forwarding* thunk as its result — e.g. returning a
        // value read straight from an attr binding cell — so no caller must
        // observe a thunk where it expects WHNF (the "got thunk" bug). The
        // guard is one predictable branch, almost always not taken; the cold
        // helper follows the chain (non-inline, so this stays `inline`-safe).
        if (r.isThunk()) return derefForwarder(self, r, demand);
        return r;
    }
    return forceThunkImpl(self, value, demand);
}

/// Follow a chain of *forwarding* thunks (a resolved thunk whose payload is
/// itself a thunk) to the WHNF at its end. Only ALREADY-RESOLVED links are
/// followed, reading each published value behind the acquire-load of its state
/// — the same read `Thunk.tryForce` does on its `.already_resolved` path. An
/// unresolved/busy forwardee is returned as-is rather than forced: forcing it
/// here would evaluate a thunk (often a fixpoint binding cell) out of order and
/// race the fiber that owns it. Cold: reached only when a resolved thunk's
/// payload is unexpectedly another thunk.
fn derefForwarder(self: *VM, start: Value, demand: bool) Value {
    var r = start;
    while (r.isThunk()) {
        const t = self.heap.getThunkAssumeValid(r.asObjectId());
        if (t.future.state.load(.acquire) != @intFromEnum(future_mod.FutureState.resolved)) return r;
        if (demand) t.markDemanded();
        r = t.payload.result;
    }
    return r;
}

pub fn forceDeep(self: *VM, value: Value) !void {
    var seen: std.ArrayListUnmanaged(SeenDeepObject) = .empty;
    defer seen.deinit(self.allocator);
    try forceDeepInner(self, value, &seen);
}

pub const SeenDeepKind = enum { list, attrs };

pub const SeenDeepObject = struct {
    kind: SeenDeepKind,
    id: ObjectId,
};

/// Like `forceDeep`, but reports `[i/N]` over the TOP-LEVEL members (a list's
/// elements / an attrset's entries) on the active render node. Used only by the
/// strict top-level render (`Evaluator.forceDeep`) — plain `forceDeep` stays
/// count-free so builtin deep-forces (seq/deepSeq) don't hijack the counter.
/// The count is on the outermost fan-out only; nested forces recurse via the
/// uncounted `forceDeepInner`.
pub fn forceDeepCounted(self: *VM, value: Value) !void {
    var seen: std.ArrayListUnmanaged(SeenDeepObject) = .empty;
    defer seen.deinit(self.allocator);
    const forced = try forceValue(self, value);
    switch (forced.kind()) {
        .list, .attrs => {},
        else => return, // scalar result: nothing to fan out / count
    }
    const gc_roots = rootsBegin(self);
    defer rootsEnd(self, gc_roots);
    rootKeep(self, forced);
    const id = forced.asObjectId();
    if (forced.kind() == .list) {
        if (!try enterDeep(self, .list, id, &seen)) return;
        const items = try self.heap.getList(id);
        forceListAccelerate(self, id, items);
        for (items) |item| {
            try forceDeepInner(self, item, &seen);
        }
    } else {
        if (!try enterDeep(self, .attrs, id, &seen)) return;
        const entries = try self.heap.getAttrs(id);
        forceAttrsAccelerate(self, id, entries);
        for (entries) |entry| {
            try forceDeepInner(self, entry.value, &seen);
        }
    }
}

pub fn forceDeepInner(self: *VM, value: Value, seen: *std.ArrayListUnmanaged(SeenDeepObject)) anyerror!void {
    const forced = try forceValue(self, value);
    switch (forced.kind()) {
        .list, .attrs => {
            // GC: root the container across the recursive element forces — we
            // hold it only as a Zig local (`forced`) + a raw store slice, which
            // no precise root covers, and the deep recursion forces mid-walk.
            const gc_roots = rootsBegin(self);
            defer rootsEnd(self, gc_roots);
            rootKeep(self, forced);
            const id = forced.asObjectId();
            if (forced.kind() == .list) {
                if (!try enterDeep(self, .list, id, seen)) return;
                // NON-MOVING GC: `rootKeep` keeps the list live, and ranges
                // never relocate/are-swept while rooted, so the slice is stable
                // across the recursive forces — no per-element re-fetch.
                const items = try self.heap.getList(id);
                forceListAccelerate(self, id, items);
                for (items) |item| try forceDeepInner(self, item, seen);
            } else {
                if (!try enterDeep(self, .attrs, id, seen)) return;
                const entries = try self.heap.getAttrs(id);
                forceAttrsAccelerate(self, id, entries);
                for (entries) |entry| try forceDeepInner(self, entry.value, seen);
            }
        },
        else => {},
    }
}

/// Demand-driven fan-out: urgently queue each thunk-typed item from a
/// list (or attrset) for forcing by helpers. The caller is about to
/// walk every item itself, so this is guaranteed work, not speculation
/// — whoever loses the race sees `.already_resolved` and proceeds.
///
/// Public because builtins that strictly walk a list (concatStringsSep,
/// concatLists, foldl', concatMap, filter, sort, etc.) get the same
/// benefit as forceDeep — main is about to touch every item, so getting
/// helpers started early is free.
/// Below this threshold, the caller can force the items itself faster
/// than the round-trip through the scheduler (submit + helper wake +
/// fiber resume). Chosen empirically; most "small" lists in a NixOS
/// toplevel sit at 2-4 items.
const fan_out_min_items: usize = 4;

/// Items-per-batch when submitting `force_list_range` /
/// `force_attrs_range` tasks. The scheduler queue is sized in tasks,
/// not items, so batching also lets a fixed-cap queue describe much
/// more pending work.
///
/// Batch-size history: a 2026-07 census-driven re-derivation moved the
/// value to 8 on the pre-scan-summary scheduler (interleaved w=8: 8
/// beat 16 in both series, median 0.894 vs 0.907 and 0.886 vs 0.935,
/// n=10 pairs each; batch 32 regressed hard). Re-measured while porting
/// onto the per-lane scan-summary scheduler (413fc60/556af1a): the w=8
/// win did not survive (neutral, 10 interleaved pairs), and 8 REGRESSED
/// w=16 (wall median 0.905 vs 0.825, max-RSS 2.9-3.5GB vs 2.2GB —
/// finer urgent batches feed the spec churn there). Sixteen remains the
/// measured production choice.
const fan_out_batch_items: u8 = 16;

pub fn fanOutListShallow(self: *VM, list_id: ObjectId, items: []const Value) void {
    // Allow helpers running speculative tasks to fan out further list
    // work too. Module-import trees in lib.evalModules are recursive
    // (`collectStructuredModules` walks `module.imports` for each
    // imported module), and the only way helpers can get at the
    // second-level imports is if the first-level helper queues them.
    // The cascade is naturally bounded by list sizes and the
    // scheduler's urgent-queue cap.
    if (items.len < fan_out_min_items) return;
    var offset: u32 = 0;
    while (offset < items.len) {
        const remaining = items.len - offset;
        const this_len: u8 = @intCast(@min(@as(usize, fan_out_batch_items), remaining));
        if (!self.scheduler.submitUrgent(.{ .force_list_range = .{
            .list_id = list_id,
            .offset = offset,
            .len = this_len,
        } }, self.workerId())) break;
        offset += this_len;
    }
}

pub fn fanOutAttrsShallow(self: *VM, attrs_id: ObjectId, entries: []const heap_mod.AttrEntry) void {
    // Symmetric with `fanOutListShallow`: speculative helpers may
    // cascade attr traversal further. NixOS module evaluation walks
    // attrsets at every level (option merging via `mapAttrs`, the
    // module config tree itself) and the cascade is what lets
    // independent contributions parallelise.
    if (entries.len < fan_out_min_items) return;
    // Batched like the list fan-out (attrs are a positional slice in the
    // heap, so the same offset/len range shape works). The former
    // one-task-per-thunk form cost the submitter — usually MAIN, on its
    // demand path — a queue push + pending-counter bump (+ periodic
    // futex wake) per entry; the w=8 task census additionally measured
    // 82.5% of those tasks arriving at an already-resolved thunk. One
    // task per ~16 entries pays the scheduling overhead once per
    // meaningful chunk of work instead of once per thunk.
    var offset: u32 = 0;
    while (offset < entries.len) {
        const remaining = entries.len - offset;
        const this_len: u8 = @intCast(@min(@as(usize, fan_out_batch_items), remaining));
        if (!self.scheduler.submitUrgent(.{ .force_attrs_range = .{
            .attrs_id = attrs_id,
            .offset = offset,
            .len = this_len,
        } }, self.workerId())) break;
        offset += this_len;
    }
}

// ---- Strict-collection-force acceleration (eager fan-out) ----

/// Accelerate a strict list walk by eagerly fanning the elements out to idle
/// helpers (`fanOutListShallow`). Drop-in at demand-safe strict sites — the
/// caller's own loop stays the authoritative demand walk, so this only
/// pre-forces; a helper that loses the race sees `.already_resolved`.
pub inline fn forceListAccelerate(self: *VM, list_id: ObjectId, items: []const Value) void {
    if (comptime prof.enabled) {
        if (self.ctx.is_demand and self.workerId() == 0)
            prof_census.recordStrictWalk(&prof_census.list_walks, items.len, fan_out_min_items);
    }
    // Solo: no helper can ever drain the fan-out; every submit would be
    // rejected per batch. One predictable branch spares the whole loop.
    if (self.solo) return;
    fanOutListShallow(self, list_id, items);
}

/// Attrset analogue of `forceListAccelerate` — the strict attrset walks
/// (`attrValues`/`filter`/`mapAttrsToList`/forceDeep-attrs) are where the
/// module-system option-merge work lives, so this exposes the previously-
/// serial merge to idle workers.
pub inline fn forceAttrsAccelerate(self: *VM, attrs_id: ObjectId, entries: []const heap_mod.AttrEntry) void {
    if (comptime prof.enabled) {
        if (self.ctx.is_demand and self.workerId() == 0)
            prof_census.recordStrictWalk(&prof_census.attrs_walks, entries.len, fan_out_min_items);
    }
    if (self.solo) return; // see forceListAccelerate
    fanOutAttrsShallow(self, attrs_id, entries);
}

pub fn enterDeep(self: *VM, kind: SeenDeepKind, id: ObjectId, seen: *std.ArrayListUnmanaged(SeenDeepObject)) !bool {
    for (seen.items) |item| {
        if (item.kind == kind and item.id == id) return false;
    }
    try seen.append(self.allocator, .{ .kind = kind, .id = id });
    return true;
}

pub fn forceThunkFallible(self: *VM, thunk_val: Value) anyerror!Value {
    return forceThunkImpl(self, thunk_val, true);
}

/// True when an in-flight speculative computation should abandon itself:
/// we're on the speculative path and the demanded result is already in
/// hand. Builtins with large internal loops (genList/map/...) poll this
/// periodically and `return error.SpeculativeBail` so a single huge,
/// never-demanded body can't run an allocation loop to completion. Off the
/// demand path entirely (the `in_speculation` check short-circuits).
pub inline fn specBailRequested(self: *VM) bool {
    if (!self.in_speculation) return false;
    if (self.scheduler.backgroundSuppressed() or self.spec_budget == 0) return true;
    return self.spec_create_left != vm_mod.no_spec_budget and specCreateExhausted(self);
}

/// Settle the fiber-accurate creation budget and report exhaustion. Only
/// call with `spec_create_left != no_spec_budget`. Meters creations as
/// deltas of the per-worker `thunks_created` counter since the last
/// settle/re-base on the SAME worker; a check that observes a worker
/// change before `Worker.runFiber`'s resume re-base ran (defensive — the
/// re-base runs before the fiber body resumes) re-bases instead of
/// bailing, so neither migration nor unrelated fibers interleaving on
/// this worker can burn the task's budget (see `VM.spec_create_left`).
pub inline fn specCreateExhausted(self: *VM) bool {
    const wid = self.workerId();
    const now = self.heap.currentLocal().thunks_created;
    if (wid != self.spec_create_worker) {
        self.spec_create_worker = wid;
        self.spec_create_snapshot = now;
        return self.spec_create_left == 0;
    }
    const delta = now - self.spec_create_snapshot;
    self.spec_create_snapshot = now;
    if (delta >= self.spec_create_left) {
        self.spec_create_left = 0;
        return true;
    }
    self.spec_create_left -= delta;
    return false;
}

/// Arm the creation budget on `vm` for a speculative task starting now:
/// `spec_create_left = budget`, snapshot re-based to the current worker's
/// creation counter.
pub inline fn specCreateArm(self: *VM, budget: u64) void {
    self.spec_create_left = budget;
    self.spec_create_snapshot = self.heap.currentLocal().thunks_created;
    self.spec_create_worker = self.workerId();
}

/// Force the operand at stack depth `depth` (0 = top) IN PLACE: force it
/// while it stays in its stack slot, write the forced value back, and
/// return it. This is the GC-safe replacement for `forceValue(pop())` —
/// the value never leaves the operand stack, so it (and everything it
/// reaches) is a precise root across the force, and remains rooted for the
/// rest of the op. Callers pop only once they're done with all operands.
/// Use this instead of pop-then-force anywhere an op forces a stack operand.
pub inline fn forceAt(self: *VM, depth: u32) anyerror!Value {
    const idx = self.sp - 1 - depth;
    const v = try forceValue(self, self.stack[idx]);
    self.stack[idx] = v;
    return v;
}

/// Force the top operand in place (see `forceAt`).
pub inline fn forceTop(self: *VM) anyerror!Value {
    return forceAt(self, 0);
}

// GC native-builtin call depth now lives on the VM (`VM.native_depth`), NOT a
// threadlocal: a fiber can yield mid-builtin and resume on a DIFFERENT OS
// thread, which would drift a per-thread counter (a builtin's `+1` and its
// `defer -1` landing on different threads). The VM travels with the fiber, so
// `self.native_depth` is fiber-local by construction. Imports evaluate on a
// fresh nested VM that inherits the caller's depth (depth-transparency — see
// `Evaluator.evaluateSource`), so a top-level import still collects (depth 0)
// while an import nested inside a builtin stays gated at that builtin's depth.

/// Demand-sibling prefetch (`FIX_SIBLING`) member admission: skip
/// members whose speculative force is known to wander into unbounded
/// package evaluation. The sweep-log diagnosis showed the RSS blowups
/// come from sweeping DERIVATION attrsets — their members are
/// `derivationLazyAttr` builtin closures, the one builtin the creation-
/// time speculation policy also refuses (forcing one recursively
/// evaluates arbitrary package inputs). Racy-benign union read, same as
/// the thunk may resolve concurrently; a torn read at
/// worst misclassifies, the claim CAS inside the force is authoritative.
pub fn sweepMemberAdmissible(self: *VM, thunk_id: ObjectId) bool {
    const th = self.heap.getThunkAssumeValid(thunk_id);
    if (th.future.state.load(.monotonic) != @intFromEnum(future_mod.FutureState.unresolved)) return false;
    switch (th.targetKind()) {
        .closure => {
            // Racy union read (see `Thunk.targetLeadingRacy`): a concurrent
            // resolve can flip the payload to `.result` after the state load
            // above. Reinterpret the raw storage so safe builds don't panic on
            // the torn arm; a torn Value is bounds-guarded by
            // `getBuiltinClosure` below.
            const cv = th.targetLeadingRacy(Value);
            if (cv.isBuiltinClosure()) {
                const bc = self.heap.getBuiltinClosure(cv.asObjectId()) catch return false;
                if (@as(BuiltinId, @enumFromInt(bc.builtin_id)) == .derivationLazyAttr) return false;
            }
            return true;
        },
        else => return true,
    }
}

// ---- temp diagnosis probe: claim-time touch logging ----

/// Monotonic microseconds for diagnosis log lines (same clock domain as
/// `probe/timeline.zig`); 0 off-linux.
pub fn diagNowUs() u64 {
    return clock.monotonicUs();
}

/// Claim dispatch: the solo (plain load/store) protocol at `--workers=1`,
/// the atomic CAS one otherwise. `VM.solo` is fixed at construction, so
/// this is a single predictable branch on the claim path at w>1.
inline fn tryForceDispatch(self: *VM, thunk: *Thunk) thunk_mod.ForceOutcome {
    return if (self.solo)
        thunk.tryForceSolo(self.ctx.claimer_id)
    else
        thunk.tryForce(self.ctx.claimer_id);
}

/// Resolve dispatch, symmetric with `tryForceDispatch` (the solo publish
/// skips the waiter-list mutex when no fiber ever enrolled). Failure paths
/// (`reset`/`markErrored`) stay on the atomic variants — cold, and plain +
/// atomic accesses on one thread are ordered by program order anyway.
inline fn resolveDispatch(self: *VM, thunk: *Thunk, value: Value) void {
    if (self.solo) thunk.resolveSolo(value) else thunk.resolve(value);
}

pub fn forceThunkImpl(self: *VM, thunk_val: Value, demand: bool) anyerror!Value {
    // GC safepoint. forceThunk is a clean unit
    // boundary; collect here, never mid-allocation. The value being forced
    // may be off the VM stack (passed by value), so root it explicitly
    // across the collection. See docs/gc.md.
    {
        // Peer stop-the-world response (w>1): only park at native depth 0,
        // where this fiber holds no builtin Zig locals a peer collector would
        // need but can't precisely see. The collection coordinator waits for
        // every peer to reach one of these safe native-depth-zero boundaries.
        if (self.native_depth == 0 and self.scheduler.gcStopRequested()) {
            self.gc_extra_root = thunk_val;
            self.scheduler.gcSafepointPark(self.workerId());
            self.gc_extra_root = Value.null_val;
        }
        // Collector: the threshold was crossed. Win the race to become the
        // sole collector (others park), stop all peers, then mark+sweep. At
        // --workers=1 this degenerates to a direct collect (0 peers).
        //
        // Fires at ANY native depth (the RSS lever). Correctness rests on the
        // precise root discipline: eval-VM registration, arg/call rooting, the
        // in-flight force chain, and container temp-roots in force-walking
        // native functions; see the root inventory in `docs/gc.md`.
        if (demand and self.heap.gcCollectRequested()) {
            self.gc_extra_root = thunk_val;
            if (self.scheduler.gcTryBeginCollection()) {
                // Time the barrier (time-to-safepoint + release) separately
                // from mark/sweep: at w>1 this busy-spin is the dominant cost.
                const b0 = gc.nowNs();
                self.scheduler.gcWaitAllParked(self.workerId());
                const b1 = gc.nowNs();
                @import("runtime").heap_collector.runCollect(self.heap, self.workerId());
                const b2 = gc.nowNs();
                self.scheduler.gcEndCollection(self.workerId());
                gc.recordBarrier(&self.heap.gc_report, (b1 - b0) + (gc.nowNs() - b2));
            } else {
                self.scheduler.gcSafepointPark(self.workerId());
            }
            self.gc_extra_root = Value.null_val;
        }
    }
    const t = prof.start(.force_thunk_slow);
    defer prof.end(.force_thunk_slow, t);
    const thunk_id = thunk_val.asObjectId();
    const thunk = self.heap.getThunkAssumeValid(thunk_id);

    while (true) {
        switch (tryForceDispatch(self, thunk)) {
            .already_resolved => |v| {
                if (demand) thunk.markDemanded();
                return v;
            },
            .blackhole => {
                recordBlackhole(self, thunk_id);
                return error.RecursiveThunk;
            },
            .errored => |info| {
                replayCachedMessage(self, info.*.message);
                return info.*.err;
            },
            .claimed => {
                // Discovery probe: main out-ran the helpers — this thunk was
                // not resolved ahead of demand, so main must compute it itself.
                // The age probe additionally buckets how long the thunk sat
                // forcible before main reached it (look-ahead ceiling).
                var age_t: u64 = std.math.maxInt(u64);
                if (comptime prof.enabled) {
                    if (demand and self.workerId() == 0) {
                        prof_census.disc.claimed_by_main += 1;
                        // Coverage-miss breakdown: main is computing this
                        // itself, so speculation did NOT cover it. Split by
                        // whether spec ever aimed here (disposition) crossed
                        // with whether it had time to (age).
                        prof_census.recordCoverage(
                            thunk.specDispValue(),
                            thunk.created_tsc,
                            @intFromEnum(thunk.targetKind()),
                        );
                        age_t = prof.ageForceBegin(
                            thunk.created_tsc,
                            @intFromEnum(thunk.targetKind()),
                            pathKey(self, &thunk.payload.target, thunk.targetKind()),
                        );
                    }
                }
                defer if (comptime prof.enabled) prof.ageForceEnd(age_t);
                // Bail out of in-flight speculation once the demanded
                // result is ready: rather than run a (possibly large,
                // never-needed) body to completion, abandon it at this safe
                // checkpoint and reset the thunk so a later real demand
                // recomputes it. Bounds the cost of a single wrong
                // speculative guess (see docs/perf/probes.md).
                // Speculative path only — demand never bails — and the
                // atomic load is off the resolved fast path.
                // A rescued fiber (`FIX_RESCUE`) is on a demand fiber's critical
                // path — bailing here would strand the waiter and force a
                // recompute, so it runs its speculation to completion.
                if (self.in_speculation and self.demand_rescue.load(.monotonic) == 0) {
                    if (self.scheduler.backgroundSuppressed()) {
                        publishThunkFailure(self, thunk, thunk_id, error.SpeculativeBail);
                        return error.SpeculativeBail;
                    }
                    // Bounded speculation (`FIX_SIBLING`): a sweep task arms
                    // a per-member claimed-force budget; when it runs dry,
                    // abandon the cascade the same way. Sub-thunks already
                    // resolved below this one stay resolved, so the partial
                    // work is kept if the value is demanded later.
                    if (self.spec_budget != vm_mod.no_spec_budget) {
                        if (self.spec_budget == 0) {
                            publishThunkFailure(self, thunk, thunk_id, error.SpeculativeBail);
                            return error.SpeculativeBail;
                        }
                        self.spec_budget -= 1;
                    }
                }
                // Thunk-result memo: reuse a previous identical pure
                // computation on this worker, skipping re-running the body.
                // Skip the map/genList application stub: its second upvalue is
                // the per-element index/item, so the key is unique every time
                // and the probe/store is pure overhead (never hits) that also
                // evicts genuinely-reusable entries.
                const memo_key: ?MemoKey = switch (thunk.targetKind()) {
                    .bytecode => if (thunk.payload.target.bytecode.chunk_id == self.registry.well_known.genlist_apply)
                        null
                    else
                        memoKeyForBytecode(&thunk.payload.target.bytecode),
                    else => null,
                };
                if (comptime prof.enabled) {
                    // Widening headroom: claimed bytecode thunks that miss
                    // the ≤2-upvalue memo-key limit, by upvalue count.
                    if (self.workerId() == 0 and memo_key == null and thunk.targetKind() == .bytecode) {
                        switch (thunk.payload.target.bytecode.upvalues().len) {
                            3 => prof_census.memo_inel_3 += 1,
                            4 => prof_census.memo_inel_4 += 1,
                            else => prof_census.memo_inel_ge5 += 1,
                        }
                    }
                }
                if (memo_key) |k| {
                    const s = &thread_caches.get().thunk_memo[k.idx];
                    // Memo census: 14.8% hit rate over 2.07M probes (w=1
                    // NixOS toplevel) — hits save ~306K body runs, well
                    // over the probe's TLS-miss cost. A 4x smaller table
                    // (L2-resident) held 14.2% but was wall-neutral;
                    // don't shrink blindly.
                    if (comptime prof.enabled) {
                        if (self.workerId() == 0) prof_census.memo_probes += 1;
                    }
                    if (s.token == self.heap.token and s.chunk == k.chunk and
                        s.count == k.count and s.up0 == k.up0 and s.up1 == k.up1)
                    {
                        if (comptime prof.enabled) {
                            if (self.workerId() == 0) prof_census.memo_hits += 1;
                        }
                        resolveDispatch(self, thunk, s.value);
                        self.heap.gcRecordEdge(thunk_id, s.value); // old→young barrier
                        recordResolve(self, thunk_id, s.value);
                        if (demand) thunk.markDemanded();
                        return s.value;
                    }
                }

                const pp = if (comptime prof_path.enabled) prof_path.enter(pathKey(self, &thunk.payload.target, thunk.targetKind())) else @as(usize, 0);
                defer prof_path.exit(pp);
                trace_log.forceEnter(self.vm_trace, self.workerId(), thunk_id);
                // Root this in-flight thunk (and thus its target closure /
                // upvalues / attr-access base) for the duration of its body:
                // a collection triggered by a nested force must not sweep it.
                // The thunk is `.evaluating` and off the operand stack while
                // its body runs, and `thunk_val` is dead here (only `thunk_id`
                // + the raw pointer remain), so the conservative scan can't
                // see it — the per-VM force chain is load-bearing. The tracer
                // follows an `.evaluating` thunk's target. See docs/gc.md.
                //
                // DORMANT GATE (the GC-default rooting tax): skip this push/pop
                // entirely while rooting is DORMANT (`gc_root_active == false`).
                // Soundness argument below assumes the pre-arming region is NEVER
                // swept — true on roomy machines. In CONSTRAINED mode a major
                // reclaims it, so `gc_root_active` (= `gc_root_always OR armed`)
                // is forced true from eval start there and this gate stays open,
                // rooting the in-flight thunk before the pre-arming major (whose
                // sweep of a live-but-unrooted in-flight thunk was a UAF).
                // Non-constrained: `gc_root_active` == `gc_collect_enabled`, so
                // the original zero-cost-when-dormant argument holds verbatim —
                // a thunk claimed while dormant is provably OLD in every
                // collection, so rooting it is a no-op:
                //   • `armTracking` sets `gc_track_from = objects.count()` at the
                //     budget/2 STW safepoint; arming is monotonic and only
                //     becomes visible after an STW where this worker was parked.
                //     If we read `false` here, no arming has completed-and-resumed
                //     for us, so this already-allocated thunk's id predates any
                //     future `gc_track_from` ⇒ `thunk_id < gc_track_from` ⇒ old
                //     (`gcIsYoung` false).
                //   • The production collector is ALWAYS a young-gated minor
                //     (`collect` uses only resetMinor/resetParallelMinor; no
                //     major). `markObject` short-circuits on old ids under the
                //     minor gate (`minor_gate and !gcIsYoung → return`), so
                //     `markObject(old thunk)` neither marks the thunk nor follows
                //     its target — the chain entry would do NOTHING.
                //   • Arming mid-body is safe: the thunk stays old (id predates
                //     the new track_from), young values the body produces are
                //     rooted by the operand stack / frames / temp-roots (markVm),
                //     never solely behind this `.evaluating` thunk; the resolved
                //     result is picked up by `gcRecordEdge` (old→young remset).
                //   • w>1 safe: arming happens only inside STW (all peers parked);
                //     a `false` read here means no peer has armed-and-resumed.
                // Captured ONCE so push and pop agree even if a peer arms
                // mid-body. Once armed (`--gc-budget` small), this is true
                // forever and the chain is maintained exactly as before.
                const gc_root_chain = self.heap.gc_root_active;
                if (gc_root_chain) self.gc_force_chain.append(self.allocator, thunk_id) catch @panic("gc force chain oom");
                defer {
                    if (gc_root_chain) _ = self.gc_force_chain.pop();
                }
                // Native-stack guard, checked right before we run the body (the
                // recursion point). Forcing recurses on the fiber's fixed stack
                // — one native frame nest per link of a deep lazy chain (e.g. a
                // lazy left-fold accumulator's `+` thunks) — and, unlike function
                // application, is NOT bounded by `max-call-depth`: thunk bodies
                // run with `is_call = false`, so `pushFrame` never counts them.
                // Without this the recursion runs off the low end of the
                // (guardless) fiber stack into an unmapped page → raw SIGSEGV.
                // Trip a graceful error `stack_guard_margin` short of that end.
                // Placed on the claimed-run path (not at entry) so the
                // resolved/busy/memo early returns stay lean; `stack_limit` is 0
                // for VMs not bound to a fiber, so it never fires there.
                if (@frameAddress() < self.ctx.stack_limit) return vm_trace.stackOverflow(self);
                // We own this thunk now; compute and publish (or
                // sticky-error / reset on failure).
                const result = evalThunkTarget(self, &thunk.payload.target, thunk.targetKind()) catch |err| {
                    publishThunkFailure(self, thunk, thunk_id, err);
                    trace_log.forceExit(self.vm_trace, self.workerId(), thunk_id, false);
                    return err;
                };
                // A tail `call`/functor/builtin can leave a *forwarding* thunk
                // on the stack, which plain `ret` returns un-forced — so the
                // computed result may itself be a thunk rather than WHNF. It is
                // published as-is (dereferencing it here would either force
                // mid-resolution, re-entering the operand stack unsafely, or
                // read a `payload.result` a concurrent `publishCellBinding` can
                // flip). The forwarding chain is followed safely on the read
                // path instead, via `derefForwarder`.
                resolveDispatch(self, thunk, result);
                self.heap.gcRecordEdge(thunk_id, result); // old→young barrier
                // If a tail call/functor/builtin left a *forwarding* thunk as
                // the result (see above), hand back — and memoize — the WHNF at
                // the end of the resolved chain, not the thunk wrapper, so the
                // caller (e.g. `getAttrValue`) never sees a thunk. The published
                // `thunk.payload` keeps the wrapper; later reads deref it the
                // same way via the resolved fast path. Almost always not a
                // thunk → no work.
                const whnf = if (result.isThunk()) derefForwarder(self, result, demand) else result;
                if (memo_key) |k| thread_caches.get().thunk_memo[k.idx] = .{
                    .token = self.heap.token,
                    .chunk = k.chunk,
                    .count = k.count,
                    .up0 = k.up0,
                    .up1 = k.up1,
                    .value = whnf,
                };
                recordResolve(self, thunk_id, whnf);
                trace_log.forceExit(self.vm_trace, self.workerId(), thunk_id, true);
                if (demand) thunk.markDemanded();
                return whnf;
            },
            .busy => {
                // Discovery probe: main (a demand fiber) blocked on a
                // helper-owned (.busy) thunk — a serial stall on the critical
                // path. Record it, note whether the awaited thunk is still
                // un-demanded (spec-owned ⇒ a demand→spec promotion could pull
                // it up), and time the whole wait.
                var disc_start: u64 = 0;
                var disc_spec = false;
                if (comptime prof.enabled) {
                    if (demand and self.workerId() == 0) {
                        const is_dem = self.ctx.is_demand;
                        if (is_dem) {
                            disc_spec = !thunk.isDemanded();
                            prof_census.disc.busy_wait += 1;
                            if (disc_spec) prof_census.disc.busy_spec_owned += 1;
                            disc_start = prof.tscMainOnly();
                        }
                    }
                }
                defer if (comptime prof.enabled) {
                    // `tscMainOnly()` returns 0 off worker 0 — the top fiber can
                    // resume on another worker after the yield, so only account
                    // the wait when we're still on worker 0 (guards underflow).
                    const end_tsc = prof.tscMainOnly();
                    if (disc_start != 0 and end_tsc > disc_start) {
                        const dt = end_tsc - disc_start;
                        prof_census.disc.busy_cycles += dt;
                        if (disc_spec) prof_census.disc.busy_spec_cycles += dt;
                    }
                };
                // Priority inheritance (`FIX_RESCUE`): this fiber — the demand
                // thread, or itself already rescued — is blocking on a thunk a
                // peer is computing speculatively. Mark it demanded and promote
                // the computing fiber so its subtree runs at URGENT priority
                // (spread across the idle workers) instead of competing with
                // junk in the spec lane. Transitive: a rescued fiber that
                // blocks here promotes the next link down the critical chain.
                if (self.scheduler.config.spec_rescue and
                    (self.ctx.is_demand or self.demand_rescue.load(.monotonic) != 0) and
                    !thunk.isDemanded())
                {
                    thunk.markDemanded();
                    self.scheduler.promoteFiber(thunk.future.claimer.load(.monotonic));
                }
                // Spin-before-enroll: a helper that is nearly done publishes
                // within a few hundred ns. Catching the resolve here skips the
                // whole enroll→suspend→yield→resume→re-tryForce cycle (µs of
                // machinery). Bounded so a genuinely long wait falls through to
                // the proper yield below, which lets the worker run other
                // fibers / drain the queue instead of burning CPU. Re-`tryForce`
                // is cheap on an `.evaluating` thunk (one acquire-load + claimer
                // compare, no CAS); on resolve it returns the terminal state and
                // we `continue` to the top where the outer switch handles it.
                {
                    var spins: u32 = 0;
                    while (spins < busy_spin_before_enroll and thunk.isEvaluating()) : (spins += 1) {
                        std.atomic.spinLoopHint();
                    }
                    // Left `.evaluating` during the spin → re-loop so the outer
                    // `tryForce` observes (and claims/reads) the terminal state.
                    if (!thunk.isEvaluating()) continue;
                }
                // Enroll on the thunk's fiber-waiter list and yield back
                // to our worker so it can run other fibers / drain the
                // queue while we wait. On resume, the outer while loop
                // retries `tryForce`, where we'll observe whichever
                // terminal state the resolver left.
                //
                // Every real call path now runs inside a fiber. If
                // we're somehow here without a current fiber, that's a
                // bug.
                const park = self.ctx.park orelse
                    @panic("forceThunkImpl hit .busy outside a fiber — every caller must run on a worker fiber");
                if (thunk.enrollWaiter(park.waiter)) {
                    var lbuf: [128]u8 = undefined;
                    var wait_span = if (self.ctx.is_demand and self.observer.profiling())
                        self.observer.beginOn(
                            &critical_wait_observation,
                            .{ .subject = force_label.critWaitLabel(self, thunk_id, &lbuf) },
                            .{ .worker = 500 },
                        )
                    else
                        observ.Span{};
                    defer wait_span.cancel();
                    const ty = prof.start(.wait_busy_thunk);
                    park.yield();
                    prof.end(.wait_busy_thunk, ty);
                    wait_span.finish(.{});
                }
                continue;
            },
        }
    }
}

pub fn evalThunkTarget(self: *VM, target: *const ThunkTarget, kind: thunk_mod.TargetKind) anyerror!Value {
    return switch (kind) {
        .closure => evalThunkClosure(self, target.closure),
        // Capture by pointer: `upvalues()` may return a slice into the
        // thunk's own inline storage, which would dangle off a by-value
        // copy. `target` points into the heap's stable thunk store.
        .bytecode => blk: {
            const bytecode = &target.bytecode;
            // Fast path for the shared single-arg application stub that
            // backs every map/genList element thunk. Its body is exactly
            // `up_grab 0; up_grab 1; call_tail` — call func on the arg — so
            // skip pushing the stub frame and dispatching those ops and call
            // directly. This halves the per-element frame/dispatch work on
            // list-bound workloads (map/genList are the hottest list ops).
            if (bytecode.chunk_id == self.registry.well_known.genlist_apply) {
                const ups = bytecode.upvalues();
                break :blk closures.callValue(self, ups[0], ups[1]);
            }
            const ch = self.registry.get(bytecode.chunk_id) orelse return error.InvalidChunk;
            break :blk runBytecodeChunk(self, ch, bytecode.chunk_id, bytecode.upvalues());
        },
        .pass_through => forceValueImpl(self, target.pass_through, true),
        // Frameless `someUpvalue.attr`: skip the isolated frame +
        // bytecode dispatch and go straight to the attr lookup, exactly
        // as the `up_get_attr; ret` body would (getAttrValue forces
        // the attrs operand and the result).
        .attr_access => access.getAttrValue(self, target.attr_access.base, target.attr_access.name),
        // Lazy per-attr compilation: compile the body now (or reuse the
        // cached ChunkId), then run it exactly like a `.bytecode` thunk
        // with the captured snapshot as upvalues.
        .deferred => blk: {
            const d = &target.deferred;
            const table = self.deferred_table orelse return error.InvalidChunk;
            const entry = table.get(d.deferred_id);
            var slot = entry.compiled.load(.acquire);
            if (slot == 0) {
                const line_index = try table.lineIndexFor(entry.source);
                const new_id = try deferred_compile.compile(table.allocator, self.registry, self.intern, self.heap, self.registration_sink, entry, line_index);
                // Publish once; a concurrent racer may have won — then our
                // chunk is orphaned-but-correct and `slot` is the canonical id.
                if (entry.compiled.cmpxchgStrong(0, new_id + 1, .acq_rel, .acquire)) |winner| {
                    slot = winner;
                } else {
                    slot = new_id + 1;
                }
            }
            const chunk_id = slot - 1;
            const ch = self.registry.get(chunk_id) orelse return error.InvalidChunk;
            break :blk runBytecodeChunk(self, ch, chunk_id, d.env());
        },
    };
}

/// Execute a compiled chunk body with `upvalues`. Shared by the `.bytecode`
/// and `.deferred` thunk arms (a deferred thunk is a bytecode thunk whose
/// ChunkId is computed lazily).
fn runBytecodeChunk(self: *VM, ch: *const Chunk, chunk_id: ChunkId, upvalues: []const Value) anyerror!Value {
    // Passthrough: forcing a thunk body is not a function application.
    return closures.runIsolatedFrame(self, ch, chunk_id, 0, upvalues, false);
}

pub fn evalThunkClosure(self: *VM, closure_val: Value) anyerror!Value {
    switch (closure_val.kind()) {
        .closure => {
            const closure = try closures.closureRef(self, closure_val);
            const ch = self.registry.get(closure.chunk_id) orelse return error.InvalidChunk;
            return closures.runIsolatedFrame(self, ch, closure.chunk_id, 0, closure.upvalues, false);
        },
        .builtin_closure => {
            const closure = try self.heap.getBuiltinClosure(closure_val.asObjectId());
            return access.applyBuiltin(self, closure.builtin_id, closure.args);
        },
        else => return error.NotCallable,
    }
}

pub fn makeThunk(self: *VM, closure: Value) !Value {
    const id = try self.heap.addThunk(Thunk.init(closure));
    recordCreateForClosure(self, id, closure);
    // Solo: nobody could ever run the speculation, and `submit()` would
    // reject it anyway — skip the eligibility predicate (two dependent,
    // often cache-missing loads per closure thunk) outright.
    if (!self.solo and speculate.shouldSpeculateClosure(self, closure)) {
        // Novelty routing (`FIX_SPEC_NOVEL`): the first-ever speculative
        // instance of a chunk goes to the high-priority novel lane.
        // builtin_closure thunks carry no chunk of their own — bulk lane.
        const ok = if (self.scheduler.config.spec_novel and speculate.isNovelClosureChunk(self, closure))
            self.scheduler.submitNovel(.{ .force_thunk = id }, self.workerId())
        else
            self.scheduler.submit(.{ .force_thunk = id }, self.workerId());
        // Coverage census (`-Dprof-main`): stamp whether this thunk was
        // aimed at by speculation (and admitted), so the `claimed_by_main`
        // site can tell a targeting miss from a lost race.
        if (comptime prof.enabled) self.heap.getThunkAssumeValid(id).noteSpecSubmitted(ok);
    }
    return Value.thunk(id);
}

pub fn makeCell(self: *VM, val: Value) !Value {
    // "Cell" is just a pass-through thunk: the underlying value gets forced
    // and the result memoized in the thunk's resolved slot.
    const id = try self.heap.addThunk(Thunk.initPassThrough(val));
    recordCreatePassThrough(self, id);
    return Value.thunk(id);
}

/// Allocate a recursive-let binding cell. The cell is born claimed by
/// the calling fiber so concurrent forces see BUSY and park instead
/// of CAS-claiming the placeholder. The corresponding `cell_set`
/// op publishes the real binding via `thunk.publishCellBinding`, which
/// installs `pass_through(val)`, transitions back to `.unresolved`,
/// and wakes parked waiters.
pub fn makeBindingCell(self: *VM) !Value {
    const id = try self.heap.addThunk(Thunk.initBindingCell(self.ctx.claimer_id));
    recordCreatePassThrough(self, id);
    return Value.thunk(id);
}

const CreatorFrame = struct { chunk_id: types.ChunkId, ip: u32 };

fn creatorFrame(self: *VM) CreatorFrame {
    if (self.frames_len == 0) return .{ .chunk_id = 0, .ip = 0 };
    const f = self.frames[self.frames_len - 1];
    return .{ .chunk_id = f.chunk_id, .ip = @intCast(f.ip) };
}

fn claimerFiberId(self: *VM) u32 {
    // claimer_id = (worker_id << 24) | fiber_id_24bits — strip the worker
    // byte to get the local fiber id, which is the more useful field at
    // log-read time.
    return self.ctx.claimer_id & 0x00FFFFFF;
}

// ---- thunk-trace recording helpers ----
//
// All of these are no-ops in default builds because `thunks_log_enabled`
// is false; the compiler folds the whole call away. With
// `-Dthunks-log` the `vm.thunk_trace` field becomes a real pointer and
// these forward to the trace.

inline fn recordResolve(self: *VM, thunk_id: ObjectId, result: Value) void {
    if (comptime !vm_mod.thunks_log_enabled) return;
    if (self.thunk_trace) |tt| tt.recordResolve(thunk_id, self.workerId(), claimerFiberId(self), result);
}

inline fn recordBlackhole(self: *VM, thunk_id: ObjectId) void {
    if (comptime !vm_mod.thunks_log_enabled) return;
    if (self.thunk_trace) |tt| tt.recordBlackhole(thunk_id, self.workerId(), claimerFiberId(self));
}

inline fn recordReset(self: *VM, thunk_id: ObjectId, err: anyerror) void {
    if (comptime !vm_mod.thunks_log_enabled) return;
    if (self.thunk_trace) |tt| tt.recordReset(thunk_id, self.workerId(), claimerFiberId(self), @errorName(err));
}

inline fn recordErrored(self: *VM, thunk_id: ObjectId, err: anyerror, message: ?[]const u8) void {
    if (comptime !vm_mod.thunks_log_enabled) return;
    if (self.thunk_trace) |tt| tt.recordErrored(thunk_id, self.workerId(), claimerFiberId(self), @errorName(err), message);
}

inline fn recordCreateForClosure(self: *VM, id: ObjectId, closure: Value) void {
    if (comptime !vm_mod.thunks_log_enabled) return;
    if (self.thunk_trace) |tt| {
        const target_kind: thunk_trace.TargetKind = switch (closure.kind()) {
            .closure => .closure,
            .builtin_closure => .builtin_closure,
            else => .closure,
        };
        const ckid: ?types.ChunkId = if (closure.isNixClosure()) blk: {
            const c = closures.closureRef(self, closure) catch break :blk null;
            break :blk c.chunk_id;
        } else null;
        const creator = creatorFrame(self);
        const substantial = if (ckid) |chunk_id|
            if (self.registry.slot(chunk_id)) |slot| slot.body_is_substantial else false
        else
            false;
        tt.recordCreate(id, self.workerId(), claimerFiberId(self), creator.chunk_id, creator.ip, target_kind, ckid, substantial);
    }
}

inline fn recordCreatePassThrough(self: *VM, id: ObjectId) void {
    if (comptime !vm_mod.thunks_log_enabled) return;
    if (self.thunk_trace) |tt| {
        const creator = creatorFrame(self);
        tt.recordCreate(id, self.workerId(), claimerFiberId(self), creator.chunk_id, creator.ip, .pass_through, null, false);
    }
}

/// True for errors whose outcome may differ on a future force (resource
/// pressure, scheduler contention, recursive thunk that might be observed
/// from a different fiber identity). For these we discard the thunk back
/// to `.unresolved` so a later call can retry; everything else is
/// considered a deterministic body failure and gets cached on the thunk.
fn isTransientThunkError(err: anyerror) bool {
    return switch (err) {
        error.OutOfMemory,
        error.StackOverflow,
        // A speculative force that bailed because the demanded result is
        // already in hand. Transient: reset to `.unresolved` so a later
        // real demand recomputes the body cleanly. Only ever raised on the
        // speculative path (gated by `in_speculation`), which `slotEntry`
        // swallows, so it never reaches a real caller.
        error.SpeculativeBail,
        => true,
        else => false,
    };
}

fn publishThunkFailure(self: *VM, thunk: *thunk_mod.Thunk, thunk_id: ObjectId, err: anyerror) void {
    if (isTransientThunkError(err)) {
        recordReset(self, thunk_id, err);
        thunk.reset();
        return;
    }
    // Move the trace message onto the thunk's sidecar. For local
    // (speculative) traces we can transfer ownership directly — same
    // allocator backs both. For the user-facing shared trace we dupe
    // so subsequent renderers can still read the message.
    var owned_message: ?[]const u8 = null;
    if (self.trace) |trace| {
        if (trace.message) |msg| {
            if (trace.frames_disabled) {
                owned_message = msg;
                trace.message = null;
            } else {
                owned_message = self.heap.allocator.dupe(u8, msg) catch null;
            }
        }
    }
    recordErrored(self, thunk_id, err, owned_message);
    publishErrored(self, thunk, err, owned_message);
}

/// Allocate the sidecar `ErrorInfo`, register it with the heap so
/// `ObjectHeap.deinit` can free it in O(errored_thunks), then transition
/// the thunk into `.errored`. Falls back to `reset()` on any allocation
/// failure so the next force can retry under better conditions.
fn publishErrored(self: *VM, thunk: *thunk_mod.Thunk, err: anyerror, owned_message: ?[]const u8) void {
    const info = self.heap.allocator.create(thunk_mod.ErrorInfo) catch {
        if (owned_message) |m| self.heap.allocator.free(m);
        thunk.reset();
        return;
    };
    info.* = .{ .err = err, .message = owned_message };
    self.heap.trackErroredInfo(info) catch {
        // Tracker grew via the heap allocator and failed; the info
        // would leak if we left it dangling. Tear it down and reset.
        if (owned_message) |m| self.heap.allocator.free(m);
        self.heap.allocator.destroy(info);
        thunk.reset();
        return;
    };
    thunk.markErrored(info);
}

/// When a force observes a cached error, replay its message onto the
/// caller's trace so `captureErrorTrace` doesn't fall back to the generic
/// default. `setMessageIfAbsent` so an outer caller that's already
/// captured context wins.
fn replayCachedMessage(self: *VM, message: ?[]const u8) void {
    const trace = self.trace orelse return;
    const msg = message orelse return;
    trace.setMessageIfAbsent(msg) catch {};
}
