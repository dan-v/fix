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
const timeline = @import("../probe/timeline.zig");
const vm_errors = @import("errors.zig");
const prof_path = @import("../probe/prof_path.zig");
const trace_probe = @import("../probe/trace_probe.zig");
const depth0_probe = @import("../probe/depth0_probe.zig");
const tjit_exec = @import("../jit/exec.zig");
const tjit_record = @import("../jit/record.zig");
const Chunk = @import("../bytecode.zig").chunk.Chunk;
const heap_mod = @import("runtime").heap;
const gc = @import("runtime").gc;
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
    if (comptime !@import("runtime").gc.enabled) return;
    thunk_memo_registry[worker_id] = &thunk_memo;
}

/// Register this worker's thread-local GC caches (thunk memo + attr cache)
/// so the collector can mark them. Called once per worker before it runs.
pub fn gcRegisterWorkerCaches(worker_id: u8) void {
    if (comptime !@import("runtime").gc.enabled) return;
    gcRegisterThunkMemo(worker_id);
    access.gcRegisterAttrCache(worker_id);
}

/// Mark every registered worker's live memo entries. STW-only (peers parked).
pub fn gcMarkThunkMemo(tr: *@import("runtime").gc.Tracer, heap: *const heap_mod.ObjectHeap) void {
    if (comptime !@import("runtime").gc.enabled) return;
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
                fanOutListShallow(self, id, items);
                for (items) |item| try forceDeepInner(self, item, seen);
            } else {
                if (!try enterDeep(self, .attrs, id, seen)) return;
                const entries = try self.heap.getAttrs(id);
                fanOutAttrsShallow(self, entries);
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

/// Items-per-batch when submitting `force_list_range` tasks. With
/// average per-thunk force ≈ 15 µs, a 16-item batch lands at ~240 µs
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

// GC native-builtin call depth now lives on the VM (`VM.native_depth`), NOT a
// threadlocal: a fiber can yield mid-builtin and resume on a DIFFERENT OS
// thread, which would drift a per-thread counter (a builtin's `+1` and its
// `defer -1` landing on different threads). The VM travels with the fiber, so
// `self.native_depth` is fiber-local by construction. Imports evaluate on a
// fresh nested VM that inherits the caller's depth (depth-transparency — see
// `Evaluator.evaluateSource`), so a top-level import still collects (depth 0)
// while an import nested inside a builtin stays gated at that builtin's depth.

/// Rich source label for a thunk, as a `timeline.Subject` — an interned source
/// location (file id + line, resolved to "modules.nix:545" at dump) or a
/// literal ("mapAttrs" / "builtins.import foo.nix" / ".attr" / an applied fn's
/// location). Shared by the crit-wait track (force.zig) and the run quanta
/// (worker.zig).
///
/// Empty when unresolvable OR when the thunk has already RESOLVED: a resolved
/// thunk's bare target union is clobbered, so it must not be read
/// (state-guarded). Best-effort and bounds-safe against a concurrent resolve.
pub fn thunkLabel(self: *VM, thunk_id: ObjectId, buf: []u8) timeline.Subject {
    const th = self.heap.getThunkAssumeValid(thunk_id);
    if (th.future.state.load(.acquire) > @intFromEnum(thunk_mod.FutureState.evaluating)) return .{};
    return critTargetLabel(self, th, buf, true);
}

fn critWaitLabel(self: *VM, thunk_id: ObjectId, buf: []u8) timeline.Subject {
    const label = thunkLabel(self, thunk_id, buf);
    if (!label.isEmpty()) return label;
    // The crit track never shows a bare "wait". thunkLabel is empty either
    // because the thunk RESOLVED mid-read (the race — a short wait, target
    // clobbered) or because it's genuinely source-less; distinguish the two.
    const th = self.heap.getThunkAssumeValid(thunk_id);
    if (th.future.state.load(.acquire) > @intFromEnum(thunk_mod.FutureState.evaluating)) return timeline.Subject.lit("resolved");
    return timeline.Subject.lit(@tagName(th.targetKind()));
}

fn critTargetLabel(self: *VM, th: *thunk_mod.Thunk, buf: []u8, follow: bool) timeline.Subject {
    return switch (th.targetKind()) {
        .bytecode => blk: {
            const b = &th.payload.target.bytecode;
            const loc = critChunkLoc(self, b.chunk_id);
            if (!loc.isEmpty()) break :blk loc;
            // Source-less chunk — a compiler-generated apply-glue. The
            // well-known map/genList/mapAttrs stubs are the common ones; name
            // the operation and, where the applied function (upvalue 0) is
            // INLINE-safe to read, its location.
            //
            // Only the inline slot is read (upvalue_count <= INLINE_CAP) and via
            // a raw ptrCast (not the union field): a busy thunk can resolve
            // mid-read and clobber the union — an inline read then yields a
            // garbage Value (handled by critClosureLabel's bounds-checked
            // accessors), whereas the spilled slice would deref a garbage ptr.
            if (b.chunk_id == self.registry.well_known.mapattrs_apply) break :blk timeline.Subject.lit("mapAttrs"); // 3 ups → spilled
            if (b.upvalue_count >= 1 and b.upvalue_count <= thunk_mod.BytecodeThunk.INLINE_CAP) {
                const fn_val: Value = @as(*const Value, @ptrCast(@alignCast(&b.storage))).*;
                const fn_loc = critClosureLabel(self, fn_val, buf);
                if (!fn_loc.isEmpty()) break :blk fn_loc;
            }
            // genlist_apply is the SHARED single-arg-application stub — used by
            // both builtins.genList AND builtins.map — so name it for both.
            if (b.chunk_id == self.registry.well_known.genlist_apply) break :blk timeline.Subject.lit("map/genList");
            break :blk .{};
        },
        .closure => critClosureLabel(self, th.payload.target.closure, buf),
        .attr_access => timeline.Subject.lit(std.fmt.bufPrint(buf, ".{s}", .{self.intern.get(th.payload.target.attr_access.name)}) catch ""),
        .pass_through => blk: {
            // A cell forwards to another value; label what it points at (one
            // level, no further pass_through recursion). Guard the inner read:
            // it may already be resolved (target arm dead).
            if (!follow) break :blk .{};
            const pv = th.payload.target.pass_through;
            if (!pv.isThunk()) break :blk .{};
            const inner = self.heap.getThunkAssumeValid(pv.asObjectId());
            if (inner.future.state.load(.acquire) > @intFromEnum(thunk_mod.FutureState.evaluating)) break :blk .{};
            break :blk critTargetLabel(self, inner, buf, false);
        },
        // A lazy-compiled attr body — file id + line from its AST node via the
        // table's cached per-source line index (built once; `lineForOffset` is
        // cache-free so it's safe even while the compiler shares the index).
        .deferred => blk: {
            const table = self.deferred_table orelse break :blk timeline.Subject.lit("deferred");
            const entry = table.get(th.payload.target.deferred.deferred_id);
            const fid = entry.source_file_id orelse break :blk timeline.Subject.lit("deferred");
            const off = if (entry.node.span) |s| s.offset else break :blk timeline.Subject.src(fid, 0);
            const idx = table.lineIndexFor(entry.source) catch break :blk timeline.Subject.src(fid, 0);
            break :blk timeline.Subject.src(fid, idx.lineForOffset(off));
        },
    };
}

/// The chunk's source location as an interned ref (file id + line) — the
/// filename is resolved from the shared intern table only at dump. No buffer.
fn critChunkLoc(self: *VM, chunk_id: ChunkId) timeline.Subject {
    const ch = self.registry.get(chunk_id) orelse return .{};
    const span = vm_errors.chunkEntrySpan(ch) orelse return .{};
    const file_id = span.file orelse return .{};
    return timeline.Subject.src(file_id, span.line);
}

fn critClosureLabel(self: *VM, cv: Value, buf: []u8) timeline.Subject {
    return switch (cv.kind()) {
        .closure => blk: {
            const cl = self.heap.getClosure(cv.asObjectId()) catch break :blk .{};
            break :blk critChunkLoc(self, cl.chunk_id);
        },
        .builtin_closure => blk: {
            const bc = self.heap.getBuiltinClosure(cv.asObjectId()) catch break :blk .{};
            break :blk critBuiltinLabel(self, @enumFromInt(bc.builtin_id), bc.args, buf);
        },
        .builtin => critBuiltinLabel(self, @enumFromInt(cv.asBuiltinId()), &.{}, buf),
        else => .{},
    };
}

fn critBuiltinLabel(self: *VM, id: BuiltinId, args: []const Value, buf: []u8) timeline.Subject {
    const name = @tagName(id);
    // Path-taking builtins (import, readFile, ...) carry the file as arg[0] —
    // the "which giant file is main blocked on" bit worth surfacing.
    if (args.len > 0) {
        const a = args[0];
        if (a.kind() == .path or a.kind() == .string) {
            return timeline.Subject.lit(std.fmt.bufPrint(buf, "builtins.{s} {s}", .{ name, std.fs.path.basename(self.intern.get(a.asInternId())) }) catch name);
        }
    }
    return timeline.Subject.lit(std.fmt.bufPrint(buf, "builtins.{s}", .{name}) catch name);
}

pub fn forceThunkImpl(self: *VM, thunk_val: Value, demand: bool) anyerror!Value {
    // Concurrent-SATB feasibility probe (`-Ddepth0-probe`): tally this
    // safepoint by native_depth + allocation cursor. Independent of -Dgc.
    if (comptime build_options.depth0_probe)
        depth0_probe.onForceThunk(self.native_depth, self.heap.totalReservedBytes());
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
                self.heap.gcRunCollect(self.workerId());
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
                // Bail out of in-flight speculation once the demanded
                // result is ready: rather than run a (possibly large,
                // never-needed) body to completion, abandon it at this safe
                // checkpoint and reset the thunk so a later real demand
                // recomputes it. Bounds the cost of a single wrong
                // speculative guess (see docs/plans/parallel-redesign-plan.md).
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
                        self.heap.gcRecordEdge(thunk_id, s.value); // old→young barrier
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
                // upvalues / attr-access base) for the duration of its body:
                // a collection triggered by a nested force must not sweep it.
                // The thunk is `.evaluating` and off the operand stack while
                // its body runs, and `thunk_val` is dead here (only `thunk_id`
                // + the raw pointer remain), so the conservative scan can't
                // see it — the per-VM force chain is load-bearing. The tracer
                // follows an `.evaluating` thunk's target. See docs/plans/gc-plan.md.
                if (comptime build_options.gc) self.gc_force_chain.append(self.allocator, thunk_id) catch @panic("gc force chain oom");
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
                    // Timeline: if the DEMAND fiber blocks here, this wait is on
                    // the critical path — time it and record a labelled span on
                    // the crit track (the "main stalls on a giant file" signal).
                    // Resolve the label NOW (the busy thunk is still evaluating,
                    // so its target arm is live); after the yield it may be
                    // resolved and the union clobbered. `lbuf` lives on the
                    // fiber stack, preserved across the yield.
                    const crit_start = if (worker_fiber.is_demand) timeline.critWaitBegin() else 0;
                    var lbuf: [128]u8 = undefined;
                    const crit_label: timeline.Subject = if (crit_start != 0) critWaitLabel(self, thunk_id, &lbuf) else .{};
                    const ty = prof.start(.wait_busy_thunk);
                    fiber_mod.Fiber.yield();
                    prof.end(.wait_busy_thunk, ty);
                    worker_fiber.state = .running;
                    if (crit_start != 0) timeline.critWaitEnd(crit_label, crit_start);
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

// ---- tests ----
//
// force.zig has no lighter-weight VM-only constructor — every entry point
// (`forceThunk`, `forceThunkFallible`, `forceValueSpeculative`, `forceDeep`)
// only runs meaningfully behind a full bytecode-compiled evaluation, so
// these tests drive it through `Evaluator.evaluate`/`forceDeep`, matching
// the rest of the eval-level test suite (see src/eval/tests/core.zig).

const Evaluator = @import("../eval.zig").Evaluator;

test "forceThunk resolves an unresolved thunk and reuses the resolved fast path" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    // `y` is a thunk that isn't forced until referenced; `y + y` forces the
    // same (by-then-resolved) thunk object twice, exercising both the
    // claim-and-compute path and the already-resolved fast path in
    // `forceValueImpl`/`forceThunkImpl`.
    const result = try ev.evaluate("let y = 3 + 4; in y + y");
    try std.testing.expectEqual(@as(i64, 14), result.asInt());
}

test "a self-referential thunk raises RecursiveThunk without corrupting the VM" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    try std.testing.expectError(error.RecursiveThunk, ev.evaluate("let x = x; in x"));
    // Blackhole detection (`recordBlackhole`) must not leave any VM-global
    // state (claim identity, operand stack depth, ...) broken — the same
    // Evaluator has to keep serving unrelated evaluations afterward.
    const recovered = try ev.evaluate("1 + 1");
    try std.testing.expectEqual(@as(i64, 2), recovered.asInt());

    // A second, differently-shaped cycle (mutual recursion through two
    // bindings) should fail the same way and still leave the VM usable.
    try std.testing.expectError(error.RecursiveThunk, ev.evaluate("let a = b; b = a; in a"));
    const recovered_again = try ev.evaluate("\"still\" + \"-\" + \"alive\"");
    try std.testing.expectEqualStrings("still-alive", ev.intern.get(recovered_again.asInternId()));
}

test "forceDeep terminates and is correct over a DAG with a shared sub-list and sub-attrset" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    // `a` is a single thunk/list object reachable twice from `s` (once
    // directly in a list, once through an attrset field). If `forceDeep`
    // mishandled shared (but acyclic) structure it would either loop
    // forever or double-evaluate/corrupt the shared object; observing
    // prompt, correct termination with the value intact covers the
    // property we can assert from outside forceDeepInner's `seen` set
    // without touching its internals.
    const value = try ev.evaluate("let a = [ 1 2 3 ]; s = { l1 = a; l2 = a; both = [ a a ]; }; in s");
    try ev.forceDeep(value);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try ev.writeValue(&out.writer, value);
    const rendered = try out.toOwnedSlice();
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(
        "{ l1 = [ 1 2 3 ]; l2 = [ 1 2 3 ]; both = [ [ 1 2 3 ] [ 1 2 3 ] ]; }",
        rendered,
    );
}

test "forceDeep still raises RecursiveThunk through a genuinely cyclic attrset" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    // Distinguishes the DAG case above (shared, but acyclic — must
    // terminate normally) from an actual cycle (must still be detected
    // and reported, not silently "terminate" via the seen-set).
    try std.testing.expectError(error.RecursiveThunk, ev.evaluate("(rec { a = a; }).a"));
}

test "forceValueSpeculative agrees with demand-driven forceThunk (serial vs parallel workers)" {
    // forceValueSpeculative (used by scheduler helpers) and the plain
    // demand path (forceThunk/forceValue) must compute the same value for
    // the same thunk — speculation is only ever a scheduling decision, never
    // a semantic one. Comparing a workers=0 (no helpers, purely
    // demand-driven) run against a workers=8 run (helpers speculatively
    // force thunks via forceValueSpeculative ahead of demand) on the same
    // source is an outside observation of that agreement: if the two paths
    // ever disagreed, one of the two evaluations would produce a different
    // (or erroneous) result.
    const source =
        \\let
        \\  heavy = n: builtins.foldl' (a: b: a + b) 0 (builtins.genList (i: i + n) 64);
        \\in builtins.foldl' (a: b: a + b) 0 (builtins.genList heavy 40)
    ;

    var serial = try Evaluator.init(std.testing.allocator, 0);
    defer serial.deinit();
    const serial_result = try serial.evaluate(source);

    var parallel = try Evaluator.init(std.testing.allocator, 8);
    defer parallel.deinit();
    const parallel_result = try parallel.evaluate(source);

    try std.testing.expectEqual(serial_result.asInt(), parallel_result.asInt());
}
