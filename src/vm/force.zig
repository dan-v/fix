const std = @import("std");
const vm_mod = @import("../vm.zig");
const types = @import("../runtime/types.zig");
const Value = @import("../runtime/value.zig").Value;
const ObjectId = types.ObjectId;
const thunk_mod = @import("../runtime/thunk.zig");
const Thunk = thunk_mod.Thunk;
const ThunkTarget = thunk_mod.ThunkTarget;
const fiber_mod = @import("../fiber.zig");
const worker_mod = @import("../worker.zig");

const access = @import("access.zig");
const closures = @import("closures.zig");
const trace_log = @import("trace_log.zig");
const BuiltinId = @import("../builtins.zig").BuiltinId;
const prof = @import("../prof.zig");

const VM = vm_mod.VM;

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
        return thunk.future.result.result;
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

pub fn fanOutAttrsShallow(self: *VM, entries: []const @import("../runtime/heap.zig").AttrEntry) void {
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

pub fn forceThunkImpl(self: *VM, thunk_val: Value, demand: bool) anyerror!Value {
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
                trace_log.forceEnter(self.vm_trace, self.workerId(), thunk_id);
                // We own this thunk now; compute and publish (or
                // sticky-error / reset on failure).
                const result = evalThunkTarget(self, thunk.target) catch |err| {
                    publishThunkFailure(self, thunk, thunk_id, err);
                    trace_log.forceExit(self.vm_trace, self.workerId(), thunk_id, false);
                    return err;
                };
                thunk.resolve(result);
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

pub fn evalThunkTarget(self: *VM, target: ThunkTarget) anyerror!Value {
    return switch (target) {
        .closure => |closure| evalThunkClosure(self, closure),
        .bytecode => |bytecode| blk: {
            const ch = self.registry.get(bytecode.chunk_id) orelse return error.InvalidChunk;
            // JIT fast path: if the registry produced a native-code
            // entry for this chunk, call it instead of pushing a
            // frame and dispatching. Null jit_code (the universal
            // case, including any build without `-Djit`) falls
            // through to the interpreter.
            if (ch.jit_code) |jit_fn| {
                const result = jit_fn(@ptrCast(self), bytecode.upvalues.ptr, bytecode.upvalues.len);
                if (result.error_code != 0) {
                    return @errorFromInt(@as(std.meta.Int(.unsigned, @bitSizeOf(anyerror)), @intCast(result.error_code)));
                }
                break :blk result.value;
            }
            break :blk closures.runIsolatedFrame(self, ch, bytecode.chunk_id, 0, bytecode.upvalues);
        },
        .pass_through => |v| forceValueImpl(self, v, true),
    };
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
        // Derivation lazy attrs resolve drv/outPath via hashing —
        // never trivial.
        .derivationLazyAttr => true,
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

const CreatorFrame = struct { chunk_id: @import("../runtime/types.zig").ChunkId, ip: u32 };

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
        const target_kind: @import("../eval/thunk_trace.zig").TargetKind = switch (closure.kind()) {
            .closure => .closure,
            .builtin_closure => .builtin_closure,
            else => .closure,
        };
        const ckid: ?@import("../runtime/types.zig").ChunkId = if (closure.isClosure()) blk: {
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
