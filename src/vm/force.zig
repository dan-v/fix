//! The thunk force protocol: the claim/busy/resolved/errored state machine that
//! drives lazy evaluation, plus speculative (demand-invisible) forcing, work-first
//! collection fan-out, and the GC safepoints — the VM's hot serial path.
//! Concurrency: a demander CAS-claims a thunk and spins then enrolls as a waiter
//! on a peer-owned `.busy` one; the per-worker thunk-result memo, scavenge cost
//! tables, and cache registries are thread-local, published for the STW collector to mark.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const vm_mod = @import("../vm.zig");
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const ObjectId = types.ObjectId;
const thunk_mod = @import("runtime").thunk;
const Thunk = thunk_mod.Thunk;
const ThunkTarget = thunk_mod.ThunkTarget;
const fiber_mod = @import("parallel").fiber;
const sched_mod = @import("parallel").scheduler;
const ContKind = sched_mod.ContKind;
const Continuation = sched_mod.Continuation;
const worker_mod = @import("../eval/worker.zig");

const access = @import("access.zig");
const closures = @import("closures.zig");
const trace_log = @import("trace_log.zig");
const BuiltinId = @import("runtime").builtins.BuiltinId;
const prof = @import("../probe/prof.zig");
const prof_census = @import("../probe/prof_census.zig");
const timeline = @import("../probe/timeline.zig");
const vm_errors = @import("errors.zig");
const prof_path = @import("../probe/prof_path.zig");
const Chunk = @import("../bytecode.zig").chunk.Chunk;
const heap_mod = @import("runtime").heap;
const gc = @import("runtime").gc;
const thunk_trace = @import("../probe/thunk_trace.zig");
const ChunkId = types.ChunkId;
const deferred_compile = @import("../compiler/deferred.zig");
const force_label = @import("force_label.zig");
const speculate = @import("force_speculate.zig");

/// Timeline source labels for thunks live in `force_label.zig`; re-exported
/// so `vm_force.thunkLabel` keeps resolving for worker.zig.
pub const thunkLabel = force_label.thunkLabel;

/// Bounded spin a demanded fiber does on a `.busy` (helper-owned) thunk
/// before enrolling as a waiter and suspending. Sized to catch a resolve
/// that lands within a few hundred nanoseconds — the common case when the
/// owner is nearly done — while still falling through to a real yield for
/// long waits (so the worker can run other fibers). See the `.busy` arm.
const BUSY_SPIN_BEFORE_ENROLL: u32 = 1024;

/// Map a thunk body to a `prof_path` key: the body's `ChunkId` (≈ a Nix
/// source location) for bytecode/closure thunks, a per-builtin key for
/// builtin closures, a synthetic key for pass-through cells. Only
/// evaluated in `-Dprof-path` builds.
inline fn pathKey(self: *VM, target: *const ThunkTarget, kind: thunk_mod.TargetKind) u32 {
    return switch (kind) {
        .bytecode => target.bytecode.chunk_id,
        .closure => switch (target.closure.kind()) {
            .closure => if (self.heap.getClosure(target.closure.asObjectId())) |cl| cl.chunk_id else |_| prof_path.KEY_OTHER,
            .builtin_closure => if (self.heap.getBuiltinClosure(target.closure.asObjectId())) |bc| prof_path.BUILTIN_BASE + @as(u32, bc.builtin_id) else |_| prof_path.KEY_OTHER,
            .builtin => prof_path.BUILTIN_BASE + @as(u32, target.closure.asBuiltinId()),
            else => prof_path.KEY_OTHER,
        },
        .pass_through => prof_path.KEY_PASS_THROUGH,
        .attr_access => prof_path.KEY_OTHER,
        .deferred => prof_path.KEY_OTHER,
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
// This is a bounded, **thread-local** (per-worker, zero-contention) cache
// mapping (heap_token, chunk_id, ≤2 upvalues) → resolved Value. Before
// computing a freshly-claimed bytecode thunk we check it; a hit resolves
// the thunk to the cached value and skips re-running the body. Pure
// functions, so reuse is sound; the `heap_token` guard invalidates stale
// entries across Evaluator instances (same trick as the attr inline
// cache). Limited to ≤2-upvalue thunks so the key compares exactly with
// no allocation — that's the inline-storage majority.
const MEMO_BITS = 14;
const MEMO_SIZE = 1 << MEMO_BITS;
const MemoSlot = struct {
    token: u64 = 0, // 0 = empty (heap tokens start at 1)
    chunk: u32 = 0,
    count: u8 = 0,
    up0: u64 = 0,
    up1: u64 = 0,
    value: Value = Value.null_val,
};
threadlocal var thunk_memo: [MEMO_SIZE]MemoSlot = @splat(.{});

/// GC (`-Dgc`): the thunk-result memo holds Values keyed by heap token. An
/// entry can be the momentary sole reference to a shared result, so valid
/// entries (token match) are roots. The memo is thread-local (per worker),
/// so each worker publishes the address of *its* memo into a registry the
/// stop-the-world collector walks — it can't reach other threads' TLS
/// otherwise. Bounded by worker id (u8).
const GC_MAX_WORKERS = 256;
var thunk_memo_registry: [GC_MAX_WORKERS]?*[MEMO_SIZE]MemoSlot = @splat(null);

/// Called by each worker (on its own thread) before it can allocate, so the
/// collector can mark this worker's memo entries.
pub fn gcRegisterThunkMemo(worker_id: u8) void {
    if (comptime !gc.enabled) return;
    thunk_memo_registry[worker_id] = &thunk_memo;
}

/// Register this worker's thread-local GC caches (thunk memo + attr cache)
/// so the collector can mark them. Called once per worker before it runs.
pub fn gcRegisterWorkerCaches(worker_id: u8) void {
    if (comptime !gc.enabled) return;
    gcRegisterThunkMemo(worker_id);
    access.gcRegisterAttrCache(worker_id);
}

/// Mark every registered worker's live memo entries. STW-only (peers parked).
pub fn gcMarkThunkMemo(tr: *gc.Tracer, heap: *const heap_mod.ObjectHeap) void {
    if (comptime !gc.enabled) return;
    for (thunk_memo_registry) |maybe| {
        const memo = maybe orelse continue;
        for (memo) |*slot| {
            if (slot.token == heap.token) tr.markValue(heap, slot.value);
        }
    }
}

inline fn memoSlotIndex(chunk: u32, up0: u64, up1: u64) usize {
    var h: u64 = @as(u64, chunk) *% 0x9E3779B97F4A7C15;
    h ^= up0 *% 0xC2B2AE3D27D4EB4F;
    h ^= up1 *% 0x165667B19E3779F9;
    return @intCast((h ^ (h >> 29)) & (MEMO_SIZE - 1));
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

// ---- GC roots for native code (`-Dgc`) ----
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
// All of this compiles to nothing without `-Dgc` (`self: anytype` so builtins
// taking a test mock still compile). It never costs the normal build a thing.
pub const RootScope = usize;

pub inline fn rootsBegin(self: anytype) RootScope {
    return if (comptime build_options.gc) self.gc_temp_roots.items.len else 0;
}
pub inline fn rootsEnd(self: anytype, scope: RootScope) void {
    if (comptime build_options.gc) self.gc_temp_roots.items.len = scope;
}
pub inline fn rootKeep(self: anytype, v: Value) void {
    if (comptime build_options.gc) self.gc_temp_roots.append(self.allocator, v) catch @panic("gc temp root oom");
}

pub fn forceThunk(self: *VM, thunk_val: Value) !Value {
    return forceThunkImpl(self, thunk_val, true);
}

/// Probe-only (`-Dprof-main`): is `v` a thunk that is ALREADY resolved?
/// Used by the repeat-force census to size resolved-value writeback.
pub inline fn profIsResolvedThunk(self: *VM, v: Value) bool {
    if (!v.isThunk()) return false;
    const thunk = self.heap.getThunkAssumeValid(v.asObjectId());
    return thunk.future.state.load(.monotonic) == @intFromEnum(thunk_mod.FutureState.resolved);
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
    // Bounded speculation (`FIX_SIBLING`): a sweep member's cascade is
    // abandoned once it has created more thunks than its budget. Checked
    // here (not just at claimed forces) because creation-heavy builtins
    // force sub-values far more often than they claim thunks. One
    // predictable `in_speculation` branch on the demand path.
    if (self.in_speculation and self.spec_create_limit != vm_mod.NO_SPEC_BUDGET) {
        if (self.workerId() != self.spec_create_worker or
            self.heap.currentLocal().thunks_created > self.spec_create_limit)
            return error.SpeculativeBail;
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
    if (state == @intFromEnum(thunk_mod.FutureState.resolved)) {
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
        return thunk.payload.result;
    }
    return forceThunkImpl(self, value, demand);
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
        self.progressCount(0, items.len);
        for (items, 0..) |item, i| {
            try forceDeepInner(self, item, &seen);
            self.progressCount(i + 1, items.len);
        }
    } else {
        if (!try enterDeep(self, .attrs, id, &seen)) return;
        const entries = try self.heap.getAttrs(id);
        forceAttrsAccelerate(self, id, entries);
        self.progressCount(0, entries.len);
        for (entries, 0..) |entry, i| {
            try forceDeepInner(self, entry.value, &seen);
            self.progressCount(i + 1, entries.len);
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
/// more pending work. `var` so `FIX_FANOUT_BATCH` can sweep it.
///
/// Batch-size history: a 2026-07 census-driven re-derivation moved the
/// default to 8 on the pre-scan-summary scheduler (interleaved w=8: 8
/// beat 16 in both series, median 0.894 vs 0.907 and 0.886 vs 0.935,
/// n=10 pairs each; batch 32 regressed hard). Re-measured while porting
/// onto the per-lane scan-summary scheduler (413fc60/556af1a): the w=8
/// win did not survive (neutral, 10 interleaved pairs), and 8 REGRESSED
/// w=16 (wall median 0.905 vs 0.825, max-RSS 2.9-3.5GB vs 2.2GB —
/// finer urgent batches feed the spec churn there). Default stays 16;
/// `FIX_FANOUT_BATCH` remains for re-sweeps.
pub var fan_out_batch_items: u8 = 16;

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

// ---- Work-first split-and-steal (Cilk/sparks) collection force ----
//
// The lazy-task-creation counterpart to the eager `fanOut*Shallow`: instead of
// pushing ⌈N/grain⌉ tasks up front, expose only the tail half of a range as ONE
// stealable continuation on the per-worker cont deque and descend the head
// inline. Idle peers steal the tail (FIFO) and re-split; unstolen it degrades
// to an inline recursive walk whose only overhead is owner-only deque push/pop.
// Advisory — the caller's own strict loop stays the authoritative demand walk,
// so a stranded/stolen continuation never loses work and the result is
// byte-identical to the eager path. Uses `forceValueSpeculative` (no demand
// mark, bail-able). Generalised over lists and attrsets (both are positional
// slices in the heap; `ContKind` selects which).

/// Grain: ranges at or below this many items are forced inline without exposing
/// a stealable continuation. Coarse enough that the deque push/pop + reclaim
/// overhead stays well under the per-item force cost.
const work_first_grain: u32 = 16;

/// Accelerate a strict list walk: work-first split-and-steal (`FIX_WORK_FIRST`)
/// or the eager `fanOutListShallow`, per the scheduler flag. Drop-in at
/// demand-safe strict sites — the caller's own loop stays authoritative.
pub inline fn forceListAccelerate(self: *VM, list_id: ObjectId, items: []const Value) void {
    if (self.scheduler.workFirst()) {
        forceCollectionWorkFirst(self, list_id, .list, @intCast(items.len));
    } else {
        fanOutListShallow(self, list_id, items);
    }
}

/// Attrset analogue of `forceListAccelerate` — the strict attrset walks
/// (`attrValues`/`filter`/`mapAttrsToList`/forceDeep-attrs) are where the
/// module-system option-merge work lives, so this is the path that actually
/// exposes the previously-serial merge to idle workers.
pub inline fn forceAttrsAccelerate(self: *VM, attrs_id: ObjectId, entries: []const heap_mod.AttrEntry) void {
    if (self.scheduler.workFirst()) {
        forceCollectionWorkFirst(self, attrs_id, .attrs, @intCast(entries.len));
    } else {
        fanOutAttrsShallow(self, attrs_id, entries);
    }
}

inline fn rootKeepCollection(self: *VM, id: ObjectId, kind: ContKind) void {
    switch (kind) {
        .list => rootKeep(self, Value.list(id)),
        .attrs => rootKeep(self, Value.attrs(id)),
    }
}

fn forceCollectionWorkFirst(self: *VM, id: ObjectId, kind: ContKind, len: u32) void {
    if (len < fan_out_min_items) return;
    // GC: root the collection across the recursive forces (a mid-walk collection
    // must not sweep it). No-op without -Dgc.
    const gc_roots = rootsBegin(self);
    defer rootsEnd(self, gc_roots);
    rootKeepCollection(self, id, kind);
    forceRangeWorkFirst(self, id, kind, 0, len);
}

/// Run a STOLEN continuation on the stealing worker: root the collection (the
/// owner's root scope may be gone), then force its range — re-splitting onto
/// THIS worker's own cont deque so idle peers can peel off further sub-ranges.
pub fn forceContinuation(self: *VM, cont: Continuation) void {
    const gc_roots = rootsBegin(self);
    defer rootsEnd(self, gc_roots);
    rootKeepCollection(self, cont.id, cont.kind);
    forceRangeWorkFirst(self, cont.id, cont.kind, cont.lo, cont.hi);
}

fn forceRangeWorkFirst(self: *VM, id: ObjectId, kind: ContKind, lo_in: u32, hi_in: u32) void {
    const wid = self.workerId();
    const lo = lo_in;
    var hi = hi_in;
    var pushed: u32 = 0;
    // Expose the tail half as a stealable continuation, descend the head inline.
    // A full deque just stops splitting (rest falls to the leaf) — best-effort.
    while (hi - lo > work_first_grain) {
        const mid = lo + (hi - lo) / 2;
        if (!self.scheduler.pushCont(wid, .{ .id = id, .lo = mid, .hi = hi, .kind = kind })) break;
        pushed += 1;
        hi = mid;
    }
    forceRangeLeaf(self, id, kind, lo, hi);
    // Reclaim LIFO. A hit un-stolen → run inline; a miss → it was stolen. The
    // popped continuation is USUALLY ours, but a fiber can suspend mid-leaf
    // (busy thunk) and this worker then runs another fiber whose work-first push
    // lands on the SAME per-worker deque, so a pop-back can surface a foreign
    // call's continuation. Re-split only when it's for OUR (id,kind); otherwise
    // drain it FLAT (its own caller loop backstops) so the reclaim recursion
    // stays bounded by our O(log N) split depth, not by chained foreign pops.
    while (pushed > 0) : (pushed -= 1) {
        const c = self.scheduler.popCont(wid) orelse break;
        if (c.id == id and c.kind == kind) {
            forceRangeWorkFirst(self, id, kind, c.lo, c.hi);
        } else {
            forceRangeLeaf(self, c.id, c.kind, c.lo, c.hi);
        }
    }
}

/// Shallow-force items `[lo, hi)` of a collection inline (no split, no deque).
/// Re-fetches the slice from the id (bounded: one lookup per ≤grain-sized leaf)
/// and clamps defensively so a foreign/stale range never indexes out of bounds.
fn forceRangeLeaf(self: *VM, id: ObjectId, kind: ContKind, lo: u32, hi: u32) void {
    switch (kind) {
        .list => {
            const items = self.heap.getList(id) catch return;
            const end = @min(@as(usize, hi), items.len);
            var i: usize = lo;
            while (i < end) : (i += 1) {
                if (items[i].isThunk()) _ = forceValueSpeculative(self, items[i]) catch {};
            }
        },
        .attrs => {
            const entries = self.heap.getAttrs(id) catch return;
            const end = @min(@as(usize, hi), entries.len);
            var i: usize = lo;
            while (i < end) : (i += 1) {
                if (entries[i].value.isThunk()) _ = forceValueSpeculative(self, entries[i].value) catch {};
            }
        },
    }
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
pub inline fn specBailRequested(self: *const VM) bool {
    if (!self.in_speculation) return false;
    if (self.scheduler.backgroundSuppressed() or self.spec_budget == 0) return true;
    return self.spec_create_limit != vm_mod.NO_SPEC_BUDGET and
        (self.workerId() != self.spec_create_worker or
            self.heap.currentLocal().thunks_created > self.spec_create_limit);
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

// ---- idle-scavenger support (FIX_SCAVENGE) ----
//
// Learned per-chunk cost filter. Worker 0 times the bytecode thunks it
// claims on its demand path (two rdtscs per claimed force, gated on the
// scavenger being enabled); a chunk whose single force exceeds
// `scav_hot_threshold_cy` is marked HOT. Idle helpers then scavenge ONLY
// ring thunks whose body chunk is hot (see `Worker.scavengeStep`):
// repeated expensive bodies — option merges, module machinery, drv
// builds — qualify after main pays for a few instances, while the
// millions of cheap or never-demanded thunks stay untouched. Racy-benign
// plain u8 stores (0→1, idempotent).
pub const SCAV_CHUNK_CAP: usize = 1 << 20;
var scav_hot_chunks: [SCAV_CHUNK_CAP]u8 = @splat(0);
/// Single-force cost (cycles) above which a chunk is marked hot.
/// `FIX_SCAV_HOT` overrides.
pub var scav_hot_threshold_cy: u64 = 100_000;

/// Admission governor tunables (`FIX_SCAV_MULT` / `FIX_SCAV_SLACK`):
/// the scavenger may take at most `demand * mult + slack` instances of a
/// hot chunk. Junk volume (never-demanded whole-graph eval, the RSS
/// blowup) scales with these; wins come from tightening them.
pub var scav_take_mult: u32 = 2;
pub var scav_take_slack: u32 = 16;
/// Minimum observed demand count before a hot chunk is scavengeable at
/// all (`FIX_SCAV_MINDEM`). Single-demand chunks are the junk-diversity
/// source: their remaining instances are usually never demanded, and one
/// take can force a whole never-demanded subgraph. Repeat-demanded
/// chunks (module merges, byName bodies) are where conversion happens.
pub var scav_min_demand: u32 = 0;

/// Feedback governor: per chunk, how many instances MAIN has demanded
/// vs how many the scavenger has taken. A chunk shared between demanded
/// and junk instances (make-derivation bodies!) would otherwise let the
/// scavenger evaluate the junk wholesale; capping takes at ~2× observed
/// demand keeps waste proportional to usefulness. Saturating, racy-
/// benign (a few extra takes are harmless).
var scav_demand_n: [SCAV_CHUNK_CAP]u16 = @splat(0);
var scav_taken_n: [SCAV_CHUNK_CAP]u16 = @splat(0);

pub inline fn scavChunkHot(chunk_id: u32) bool {
    return chunk_id < SCAV_CHUNK_CAP and scav_hot_chunks[chunk_id] != 0;
}

/// Scavenger-side admission check; bumps the take counter on success.
pub inline fn scavShouldTake(chunk_id: u32) bool {
    if (chunk_id >= SCAV_CHUNK_CAP) return false;
    if (scav_hot_chunks[chunk_id] == 0) return false;
    const taken = scav_taken_n[chunk_id];
    const demand = scav_demand_n[chunk_id];
    if (demand < scav_min_demand) return false;
    if (taken == std.math.maxInt(u16)) return false;
    if (@as(u32, taken) >= @as(u32, demand) * scav_take_mult + scav_take_slack) return false;
    scav_taken_n[chunk_id] = taken + 1;
    return true;
}

/// Demand-sibling prefetch (`FIX_SIBLING`) member admission: skip
/// members whose speculative force is known to wander into unbounded
/// package evaluation. The sweep-log diagnosis showed the RSS blowups
/// come from sweeping DERIVATION attrsets — their members are
/// `derivationLazyAttr` builtin closures, the one builtin the creation-
/// time speculation policy also refuses (forcing one recursively
/// evaluates arbitrary package inputs). Racy-benign union read, same as
/// `scavengeStep`: the thunk may resolve concurrently; a torn read at
/// worst misclassifies, the claim CAS inside the force is authoritative.
pub fn sweepMemberAdmissible(self: *VM, thunk_id: ObjectId) bool {
    const th = self.heap.getThunkAssumeValid(thunk_id);
    if (th.future.state.load(.monotonic) != @intFromEnum(thunk_mod.FutureState.unresolved)) return false;
    switch (th.targetKind()) {
        .closure => {
            const cv = th.payload.target.closure;
            if (cv.isBuiltinClosure()) {
                const bc = self.heap.getBuiltinClosure(cv.asObjectId()) catch return false;
                if (@as(BuiltinId, @enumFromInt(bc.builtin_id)) == .derivationLazyAttr) return false;
            }
            return true;
        },
        else => return true,
    }
}

inline fn scavRdtsc() u64 {
    if (comptime builtin.cpu.arch != .x86_64) return 0;
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdtsc"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
        :
        : .{ .memory = true });
    return (@as(u64, high) << 32) | @as(u64, low);
}

// ---- temp diagnosis probe: claim-time touch logging ----

/// Monotonic microseconds for diagnosis log lines (same clock domain as
/// `probe/timeline.zig`); 0 off-linux.
pub fn diagNowUs() u64 {
    if (builtin.os.tag != .linux) return 0;
    var ts: std.os.linux.timespec = undefined;
    if (std.os.linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    const sec: u64 = if (ts.sec > 0) @intCast(ts.sec) else 0;
    const nsec: u64 = if (ts.nsec > 0) @intCast(ts.nsec) else 0;
    return sec * 1_000_000 + nsec / 1_000;
}

/// Cold: log a claim of a thunk whose source file basename contains the
/// `FIX_TOUCH_LOG` substring. Safe here — the caller just claimed the
/// thunk, so its target union is readable.
noinline fn logTouch(self: *VM, thunk_id: ObjectId, demand: bool) void {
    const filt = self.scheduler.touch_log orelse return;
    var buf: [160]u8 = undefined;
    const subj = thunkLabel(self, thunk_id, &buf);
    if (subj.file == 0) return;
    const base = std.fs.path.basename(self.intern.get(subj.file));
    if (std.mem.indexOf(u8, base, filt) == null) return;
    std.debug.print("touch {s}:{d} id={d} t_us={d} worker={d} spec={} demand={} claimer={d}\n", .{
        base,
        subj.line,
        thunk_id,
        diagNowUs(),
        self.workerId(),
        self.in_speculation,
        demand,
        self.claimer_id,
    });
}

/// Cold: log a creation-time speculative SUBMIT of a thunk whose source file
/// basename matches the `FIX_TOUCH_LOG` substring. Paired with `logTouch`
/// (claims) so a probe run shows the full submit→claim latency of the seed
/// tasks and whether the submit was accepted or dropped (queue/cap full).
pub noinline fn logSpawn(self: *VM, thunk_id: ObjectId, accepted: bool) void {
    const filt = self.scheduler.touch_log orelse return;
    var buf: [160]u8 = undefined;
    const subj = thunkLabel(self, thunk_id, &buf);
    if (subj.file == 0) return;
    const base = std.fs.path.basename(self.intern.get(subj.file));
    if (std.mem.indexOf(u8, base, filt) == null) return;
    std.debug.print("spawn {s}:{d} id={d} t_us={d} worker={d} spec={} ok={}\n", .{
        base,
        subj.line,
        thunk_id,
        diagNowUs(),
        self.workerId(),
        self.in_speculation,
        accepted,
    });
}

pub fn forceThunkImpl(self: *VM, thunk_val: Value, demand: bool) anyerror!Value {
    // GC safepoint (`-Dgc`, --workers=1). forceThunk is a clean unit
    // boundary; collect here, never mid-allocation. The value being forced
    // may be off the VM stack (passed by value), so root it explicitly
    // across the collection. See docs/plans/gc-plan.md.
    if (comptime build_options.gc) {
        // Peer stop-the-world response (w>1): only park at native depth 0,
        // where this fiber holds no builtin Zig locals a peer collector would
        // need but can't precisely see. (The w>1 collector is dormant today;
        // see Evaluator.ensureMainWorker.)
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
        // native fns. Audit in progress (see force.zig root helpers).
        if (demand and self.heap.gcCollectRequested()) {
            self.gc_extra_root = thunk_val;
            if (self.scheduler.gcTryBeginCollection()) {
                // Time the barrier (time-to-safepoint + release) separately
                // from mark/sweep: at w>1 this busy-spin is the dominant cost.
                const b0 = gc.nowNs();
                self.scheduler.gcWaitAllParked(self.workerId());
                const b1 = gc.nowNs();
                heap_mod.heap_gc.runCollect(self.heap, self.workerId());
                const b2 = gc.nowNs();
                self.scheduler.gcEndCollection(self.workerId());
                gc.recordBarrier((b1 - b0) + (gc.nowNs() - b2));
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
        switch (thunk.tryForce(self.claimer_id)) {
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
                // Temp diagnosis probe (`FIX_TOUCH_LOG=<file substring>`):
                // log every CLAIM of a thunk whose source file matches, with
                // timestamp/worker/spec-vs-demand — who first computes the
                // etc.nix-style tail chains, and when. Off = one branch on a
                // lazily-initialized global.
                if (self.scheduler.touch_log != null) logTouch(self, thunk_id, demand);
                // Discovery probe: main out-ran the helpers — this thunk was
                // not resolved ahead of demand, so main must compute it itself.
                // The age probe additionally buckets how long the thunk sat
                // forcible before main reached it (look-ahead ceiling).
                var age_t: u64 = std.math.maxInt(u64);
                if (comptime prof.enabled) {
                    if (demand and self.workerId() == 0) {
                        prof_census.disc.claimed_by_main += 1;
                        age_t = prof.ageForceBegin(
                            thunk.future.created_tsc,
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
                // speculative guess (see docs/plans/parallel-redesign-plan.md).
                // Speculative path only — demand never bails — and the
                // atomic load is off the resolved fast path.
                if (self.in_speculation) {
                    if (self.scheduler.backgroundSuppressed()) {
                        publishThunkFailure(self, thunk, thunk_id, error.SpeculativeBail);
                        return error.SpeculativeBail;
                    }
                    // Bounded speculation (`FIX_SIBLING`): a sweep task arms
                    // a per-member claimed-force budget; when it runs dry,
                    // abandon the cascade the same way. Sub-thunks already
                    // resolved below this one stay resolved, so the partial
                    // work is kept if the value is demanded later.
                    if (self.spec_budget != vm_mod.NO_SPEC_BUDGET) {
                        if (self.spec_budget == 0) {
                            publishThunkFailure(self, thunk, thunk_id, error.SpeculativeBail);
                            return error.SpeculativeBail;
                        }
                        self.spec_budget -= 1;
                    }
                }
                // Thunk-result memo: reuse a previous identical pure
                // computation on this worker, skipping re-running the body.
                const memo_key: ?MemoKey = switch (thunk.targetKind()) {
                    .bytecode => memoKeyForBytecode(&thunk.payload.target.bytecode),
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
                    const s = &thunk_memo[k.idx];
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
                        thunk.resolve(s.value);
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
                // follows an `.evaluating` thunk's target. See docs/plans/gc-plan.md.
                //
                // DORMANT GATE (the GC-default rooting tax): skip this push/pop
                // entirely while collection is DORMANT (`gc_collect_enabled ==
                // false`). Soundness — a thunk claimed while dormant is provably
                // OLD in every collection, so rooting it is a no-op:
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
                // mid-body. Once armed (`--max-memory` small), this is true
                // forever and the chain is maintained exactly as before.
                const gc_root_chain: bool = if (comptime build_options.gc) self.heap.gc_collect_enabled else false;
                if (comptime build_options.gc) {
                    if (gc_root_chain) self.gc_force_chain.append(self.allocator, thunk_id) catch @panic("gc force chain oom");
                }
                defer if (comptime build_options.gc) {
                    if (gc_root_chain) _ = self.gc_force_chain.pop();
                };
                // Scavenger cost-learning: time this force on main's
                // demand path so repeat-expensive chunks become
                // scavengeable (see scavChunkHot). Off unless FIX_SCAVENGE.
                var scav_t0: u64 = 0;
                var scav_chunk: u32 = 0;
                if (demand and thunk.targetKind() == .bytecode and
                    self.scheduler.scavengeEnabled() and self.workerId() == 0)
                {
                    scav_chunk = thunk.payload.target.bytecode.chunk_id;
                    scav_t0 = scavRdtsc();
                    if (scav_chunk < SCAV_CHUNK_CAP and scav_demand_n[scav_chunk] != std.math.maxInt(u16))
                        scav_demand_n[scav_chunk] += 1;
                }
                // We own this thunk now; compute and publish (or
                // sticky-error / reset on failure).
                const result = evalThunkTarget(self, &thunk.payload.target, thunk.targetKind()) catch |err| {
                    publishThunkFailure(self, thunk, thunk_id, err);
                    trace_log.forceExit(self.vm_trace, self.workerId(), thunk_id, false);
                    return err;
                };
                if (scav_t0 != 0 and scav_chunk < SCAV_CHUNK_CAP and
                    scavRdtsc() - scav_t0 > scav_hot_threshold_cy)
                {
                    scav_hot_chunks[scav_chunk] = 1;
                }
                thunk.resolve(result);
                self.heap.gcRecordEdge(thunk_id, result); // old→young barrier
                if (memo_key) |k| thunk_memo[k.idx] = .{
                    .token = self.heap.token,
                    .chunk = k.chunk,
                    .count = k.count,
                    .up0 = k.up0,
                    .up1 = k.up1,
                    .value = result,
                };
                recordResolve(self, thunk_id, result);
                trace_log.forceExit(self.vm_trace, self.workerId(), thunk_id, true);
                if (demand) thunk.markDemanded();
                return result;
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
                        const is_dem = self.is_demand;
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
                    while (spins < BUSY_SPIN_BEFORE_ENROLL and thunk.isEvaluating()) : (spins += 1) {
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
                const inner = fiber_mod.currentFiber() orelse
                    @panic("forceThunkImpl hit .busy outside a fiber — every caller must run on a worker fiber");
                const worker_fiber: *worker_mod.WorkerFiber = @fieldParentPtr("inner", inner);
                if (thunk.enrollWaiter(&worker_fiber.waiter)) {
                    worker_fiber.state = .suspended;
                    // Timeline: if the DEMAND fiber blocks here, this wait is on
                    // the critical path — time it and record a labelled span on
                    // the crit track (the "main stalls on a giant file" signal).
                    // Resolve the label NOW (the busy thunk is still evaluating,
                    // so its target arm is live); after the yield it may be
                    // resolved and the union clobbered. `lbuf` lives on the fiber
                    // stack, preserved across the yield.
                    const crit_start = if (self.is_demand) timeline.critWaitBegin() else 0;
                    var lbuf: [128]u8 = undefined;
                    const crit_label: timeline.Subject = if (crit_start != 0) force_label.critWaitLabel(self, thunk_id, &lbuf) else .{};
                    // Progress "waiting on" line: publish only on the demand path
                    // and only when drawn (free otherwise). Labelled from THIS
                    // fiber's own current frame span — a stable read — NOT the
                    // target thunk's union, which a concurrent resolver can flip
                    // `.target → .result` mid-decode (a union-field panic in a
                    // safe build; `critWaitLabel` above tolerates it only because
                    // `--timeline` rarely runs, whereas progress blocks here often).
                    if (self.is_demand) if (self.progress_wait) |pw| {
                        var sbuf: [64]u8 = undefined;
                        pw.set(force_label.demandFrameText(self, &sbuf));
                    };
                    const ty = prof.start(.wait_busy_thunk);
                    fiber_mod.Fiber.yield();
                    prof.end(.wait_busy_thunk, ty);
                    worker_fiber.state = .running;
                    if (crit_start != 0) timeline.critWaitEnd(crit_label, crit_start);
                    if (self.is_demand) if (self.progress_wait) |pw| pw.clear();
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
            const ch = self.registry.get(bytecode.chunk_id) orelse return error.InvalidChunk;
            break :blk runBytecodeChunk(self, ch, bytecode.chunk_id, bytecode.upvalues());
        },
        .pass_through => forceValueImpl(self, target.pass_through, true),
        // Frameless `someUpvalue.attr`: skip the isolated frame +
        // bytecode dispatch and go straight to the attr lookup, exactly
        // as the `get_upvalue_attr; ret` body would (getAttrValue forces
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
                const new_id = try deferred_compile.compile(table.allocator, self.registry, self.intern, self.heap, entry, line_index);
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
    return closures.runIsolatedFrame(self, ch, chunk_id, 0, upvalues);
}

pub fn evalThunkClosure(self: *VM, closure_val: Value) anyerror!Value {
    switch (closure_val.kind()) {
        .closure => {
            const closure_id = closure_val.asObjectId();
            const closure = try closures.getClosureById(self, closure_id);
            const ch = self.registry.get(closure.chunk_id) orelse return error.InvalidChunk;
            return closures.runIsolatedFrame(self, ch, closure.chunk_id, 0, closure.upvalues);
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
    if (speculate.shouldSpeculateClosure(self, closure)) {
        // Novelty routing (`FIX_SPEC_NOVEL`): the first-ever speculative
        // instance of a chunk goes to the high-priority novel lane.
        // builtin_closure thunks carry no chunk of their own — bulk lane.
        const ok = if (self.scheduler.spec_novel and speculate.novelClosureChunk(self, closure))
            self.scheduler.submitNovel(.{ .force_thunk = id }, self.workerId())
        else
            self.scheduler.submit(.{ .force_thunk = id }, self.workerId());
        if (self.scheduler.touch_log != null) logSpawn(self, id, ok);
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
/// of CAS-claiming the placeholder. The corresponding `set_cell_local`
/// op publishes the real binding via `thunk.publishCellBinding`, which
/// installs `pass_through(val)`, transitions back to `.unresolved`,
/// and wakes parked waiters.
pub fn makeBindingCell(self: *VM) !Value {
    const id = try self.heap.addThunk(Thunk.initBindingCell(self.claimer_id));
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
    return self.claimer_id & 0x00FFFFFF;
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
        const ckid: ?types.ChunkId = if (closure.isClosure()) blk: {
            const c = self.heap.getClosure(closure.asObjectId()) catch break :blk null;
            break :blk c.chunk_id;
        } else null;
        const creator = creatorFrame(self);
        tt.recordCreate(id, self.workerId(), claimerFiberId(self), creator.chunk_id, creator.ip, target_kind, ckid);
    }
}

inline fn recordCreatePassThrough(self: *VM, id: ObjectId) void {
    if (comptime !vm_mod.thunks_log_enabled) return;
    if (self.thunk_trace) |tt| {
        const creator = creatorFrame(self);
        tt.recordCreate(id, self.workerId(), claimerFiberId(self), creator.chunk_id, creator.ip, .pass_through, null);
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
