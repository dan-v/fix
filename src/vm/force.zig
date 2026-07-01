const std = @import("std");
const build_options = @import("build_options");
const vm_mod = @import("../vm.zig");
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const ObjectId = types.ObjectId;
const thunk_mod = @import("runtime").thunk;
const Thunk = thunk_mod.Thunk;
const ThunkTarget = thunk_mod.ThunkTarget;
const fiber_mod = @import("parallel").fiber;
const worker_mod = @import("../eval/worker.zig");

const access = @import("access.zig");
const closures = @import("closures.zig");
const trace_log = @import("trace_log.zig");
const BuiltinId = @import("runtime").builtins.BuiltinId;
const prof = @import("../probe/prof.zig");
const prof_path = @import("../probe/prof_path.zig");
const trace_probe = @import("../probe/trace_probe.zig");
const tjit_exec = @import("../jit/exec.zig");
const tjit_record = @import("../jit/record.zig");
const Chunk = @import("../bytecode.zig").chunk.Chunk;
const heap_mod = @import("runtime").heap;
const thunk_trace = @import("../probe/thunk_trace.zig");
const ChunkId = types.ChunkId;
const deferred_compile = @import("../compiler/deferred.zig");

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

pub fn forceThunk(self: *VM, thunk_val: Value) !Value {
    return forceThunkImpl(self, thunk_val, true);
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
    defer self.in_speculation = saved;
    return forceValueImpl(self, value, false);
}

pub inline fn forceValueImpl(self: *VM, value: Value, demand: bool) anyerror!Value {
    if (!value.isThunk()) return value;
    if (comptime trace_probe.enabled) trace_probe.recordRead(value.asObjectId());
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
        if (demand) thunk.markDemanded();
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

pub fn forceDeepInner(self: *VM, value: Value, seen: *std.ArrayListUnmanaged(SeenDeepObject)) anyerror!void {
    const forced = try forceValue(self, value);
    switch (forced.kind()) {
        .list => {
            const id = forced.asObjectId();
            if (!try enterDeep(self, .list, id, seen)) return;
            const items = try self.heap.getList(id);
            fanOutListShallow(self, id, items);
            for (items) |item| try forceDeepInner(self, item, seen);
        },
        .attrs => {
            const id = forced.asObjectId();
            if (!try enterDeep(self, .attrs, id, seen)) return;
            const entries = try self.heap.getAttrs(id);
            fanOutAttrsShallow(self, entries);
            for (entries) |entry| try forceDeepInner(self, entry.value, seen);
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

/// Items-per-batch when submitting `force_list_range` tasks. With
/// average per-thunk force ≈ 15 µs, an 8-item batch lands at ~120 µs
/// of helper work — comfortably above the per-task scheduling overhead
/// without serialising the list too coarsely. The scheduler queue is
/// sized in tasks, not items, so batching also lets a fixed-cap queue
/// describe much more pending work.
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

pub fn fanOutAttrsShallow(self: *VM, entries: []const heap_mod.AttrEntry) void {
    // Symmetric with `fanOutListShallow`: speculative helpers may
    // cascade attr traversal further. NixOS module evaluation walks
    // attrsets at every level (option merging via `mapAttrs`, the
    // module config tree itself) and the cascade is what lets
    // independent contributions parallelise.
    if (entries.len < fan_out_min_items) return;
    // No batched task type for attrs yet (the heap currently lays out
    // attrs as a slice indexed by position, but we'd need a separate
    // task variant). Attrsets in real evals tend to be smaller than
    // lists; one-task-per-thunk is fine for now.
    for (entries) |entry| {
        if (!entry.value.isThunk()) continue;
        if (!self.scheduler.submitUrgent(.{ .force_thunk = entry.value.asObjectId() }, self.workerId())) break;
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
    return self.in_speculation and self.scheduler.backgroundSuppressed();
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

/// GC (`-Dgc`): per-THREAD native-builtin call depth. Collections only run
/// at depth 0 — a point where NO builtin frame is active anywhere on the
/// thread, so a builtin may hold heap refs in Zig locals freely (they can
/// never be observed by a collection). This is what makes writing a builtin
/// correct-by-default. Per-thread (not per-VM) because imports evaluate on
/// fresh VMs but the same OS thread; `import`/`scopedImport` are
/// depth-transparent (see `Evaluator.evaluateSource`) so a top-level import
/// still collects while an import nested inside another builtin does not.
pub threadlocal var native_depth: u32 = 0;

pub fn forceThunkImpl(self: *VM, thunk_val: Value, demand: bool) anyerror!Value {
    // GC safepoint (`-Dgc`, --workers=1). forceThunk is a clean unit
    // boundary; collect here, never mid-allocation. The value being forced
    // may be off the VM stack (passed by value), so root it explicitly
    // across the collection. See docs/gc-plan.md.
    if (comptime build_options.gc) {
        // Collect only at native-call depth 0: a bytecode-level force where
        // the root set is provably complete (operand stack + frames). Never
        // inside a native builtin, whose intermediates live in Zig locals.
        if (demand and native_depth == 0 and self.heap.gcCollectRequested()) {
            self.gc_extra_root = thunk_val;
            self.heap.gcRunCollect();
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
                // Bail out of in-flight speculation once the demanded
                // result is ready: rather than run a (possibly large,
                // never-needed) body to completion, abandon it at this safe
                // checkpoint and reset the thunk so a later real demand
                // recomputes it. Bounds the cost of a single wrong
                // speculative guess (see docs/parallel-redesign-plan.md).
                // Speculative path only — demand never bails — and the
                // atomic load is off the resolved fast path.
                if (self.in_speculation and self.scheduler.backgroundSuppressed()) {
                    publishThunkFailure(self, thunk, thunk_id, error.SpeculativeBail);
                    return error.SpeculativeBail;
                }
                // Thunk-result memo: reuse a previous identical pure
                // computation on this worker, skipping re-running the body.
                const memo_key: ?MemoKey = switch (thunk.targetKind()) {
                    .bytecode => memoKeyForBytecode(&thunk.payload.target.bytecode),
                    else => null,
                };
                if (memo_key) |k| {
                    const s = &thunk_memo[k.idx];
                    if (s.token == self.heap.token and s.chunk == k.chunk and
                        s.count == k.count and s.up0 == k.up0 and s.up1 == k.up1)
                    {
                        thunk.resolve(s.value);
                        recordResolve(self, thunk_id, s.value);
                        if (demand) thunk.markDemanded();
                        return s.value;
                    }
                }

                if (comptime trace_probe.enabled) {
                    if (thunk.targetKind() == .bytecode) {
                        if (self.registry.get(thunk.payload.target.bytecode.chunk_id)) |ch|
                            trace_probe.recordComputeBody(ch.code.len);
                    }
                }
                const pp = if (comptime prof_path.enabled) prof_path.enter(pathKey(self, &thunk.payload.target, thunk.targetKind())) else @as(usize, 0);
                defer prof_path.exit(pp);
                // Tracing-JIT force-inline hook: if we're recording and this is
                // a thunk the trace built, inline its body (see record.zig).
                if (comptime tjit_record.enabled) {
                    if (self.tjit_rec != null and thunk.targetKind() == .bytecode) {
                        tjit_record.onForceInline(self, thunk.payload.target.bytecode.chunk_id);
                    }
                }
                trace_log.forceEnter(self.vm_trace, self.workerId(), thunk_id);
                // Root this in-flight thunk (and thus its target closure /
                // upvalues) for the duration of its body: a collection
                // triggered by a nested force must not sweep it. See
                // docs/gc-plan.md (the force-chain root).
                if (comptime build_options.gc) {
                    self.gc_force_chain.append(self.allocator, thunk_id) catch {};
                }
                defer if (comptime build_options.gc) {
                    _ = self.gc_force_chain.pop();
                };
                // We own this thunk now; compute and publish (or
                // sticky-error / reset on failure).
                const result = evalThunkTarget(self, &thunk.payload.target, thunk.targetKind()) catch |err| {
                    publishThunkFailure(self, thunk, thunk_id, err);
                    trace_log.forceExit(self.vm_trace, self.workerId(), thunk_id, false);
                    return err;
                };
                thunk.resolve(result);
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
                const worker_fiber: *worker_mod.Fiber = @fieldParentPtr("inner", inner);
                if (thunk.enrollWaiter(&worker_fiber.waiter)) {
                    worker_fiber.state = .suspended;
                    const ty = prof.start(.wait_busy_thunk);
                    fiber_mod.Fiber.yield();
                    prof.end(.wait_busy_thunk, ty);
                    worker_fiber.state = .running;
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

/// Execute a compiled chunk body with `upvalues`, honoring the tracing
/// JIT and native JIT fast paths. Shared by the `.bytecode` and
/// `.deferred` thunk arms (a deferred thunk is a bytecode thunk whose
/// ChunkId is computed lazily).
fn runBytecodeChunk(self: *VM, ch: *const Chunk, chunk_id: ChunkId, upvalues: []const Value) anyerror!Value {
    // Tracing-JIT: run an installed trace for this thunk body instead
    // of interpreting it. A guard side-exit returns null → fall through.
    if (comptime tjit_exec.enabled) {
        if (try tjit_exec.tryRun(self, chunk_id, upvalues, Value.null_val)) |result| return result;
    }
    // JIT fast path: if the registry produced a native-code entry for
    // this chunk, call it instead of pushing a frame and dispatching.
    // Null jit_code (the universal case, including any build without
    // `-Djit`) falls through to the interpreter.
    if (ch.jit_code) |jit_fn| {
        const result = jit_fn(@ptrCast(self), upvalues.ptr, upvalues.len);
        if (result.error_code != 0) {
            return @errorFromInt(@as(std.meta.Int(.unsigned, @bitSizeOf(anyerror)), @intCast(result.error_code)));
        }
        return result.value;
    }
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
    if (shouldSpeculateClosure(self, closure)) {
        _ = self.scheduler.submit(.{ .force_thunk = id }, self.workerId());
    }
    return Value.thunk(id);
}

inline fn shouldSpeculateClosure(self: *VM, closure: Value) bool {
    // Bound the cascade: if we got here because a helper is *itself*
    // running speculative work, don't submit further speculation. The
    // helper's result may or may not be observed; chaining more
    // speculation off it would just multiply uncertain work.
    if (self.in_speculation) return false;
    return switch (closure.kind()) {
        .closure => isSpeculatableClosureChunk(self, closure),
        // map / mapAttrs / genList / zipAttrsWith all produce
        // builtin_closure thunks that wrap a *user* function. Real
        // evals create millions of these; if we wait for forceDeep to
        // submit them urgently, main is already on the critical path.
        // Speculate them now, gated on the inner function being
        // substantial (and on `in_speculation` above, so a helper
        // forcing one won't speculate the next one in the chain).
        .builtin_closure => isSpeculatableBuiltinClosure(self, closure),
        else => false,
    };
}

fn isSpeculatableClosureChunk(self: *VM, closure: Value) bool {
    // The eligibility bit is pre-computed at chunk registration time
    // (see Chunk.speculatable).
    const c = self.heap.getClosure(closure.asObjectId()) catch return false;
    const ch = self.registry.get(c.chunk_id) orelse return false;
    return ch.scheduling.body_is_substantial;
}

fn isSpeculatableBuiltinClosure(self: *VM, closure: Value) bool {
    const bc = self.heap.getBuiltinClosure(closure.asObjectId()) catch return false;
    return switch (@as(BuiltinId, @enumFromInt(bc.builtin_id))) {
        // Map-style fan-out: args[0] is the user function in each.
        // Speculate when it's either a user closure with a substantial
        // body (the chunk-size threshold filters trivial cases like
        // `x: x + 1`) or a builtin known to be expensive enough to
        // earn the scheduler hop — most importantly `import`, which
        // is how the NixOS module system parallelises file
        // resolution.
        .mapValue, .mapAttrValue, .zipAttrsValue => bc.args.len > 0 and
            isSpeculatableMapFunc(self, bc.args[0]),
        // A single lazy derivation attr is not trivial, but forcing it can
        // recursively evaluate arbitrary package inputs. Keep these
        // demand-driven so speculation does not wander into unobserved
        // package graphs (for example pandoc -> luaPackages on the NixOS
        // toplevel).
        .derivationLazyAttr => false,
        else => false,
    };
}

inline fn isSpeculatableMapFunc(self: *VM, func: Value) bool {
    if (func.isClosure()) return isSpeculatableClosureChunk(self, func);
    if (func.isBuiltin()) return isExpensiveBuiltin(@enumFromInt(func.asBuiltinId()));
    return false;
}

/// Builtins whose body is heavy enough that submitting a speculative
/// force task pays for itself: file I/O, network fetches, or full
/// nested evaluation. Lightweight ones (head, length, isList, ...)
/// stay off this list so `map builtins.head xs` doesn't burn helper
/// fibers on trivially-cheap work.
fn isExpensiveBuiltin(id: BuiltinId) bool {
    return switch (id) {
        .import,
        .scopedImport,
        .fetchurl,
        .fetchTarball,
        .fetchGit,
        .fetchTree,
        .readFile,
        .readFileType,
        .readDir,
        .derivation,
        => true,
        else => false,
    };
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
