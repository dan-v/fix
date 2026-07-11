//! Work-stealing scheduler for parallel evaluation.
//!
//! Workers are symmetric (F1). Every `worker_id ∈ 0..worker_count-1`
//! owns:
//!   - A task queue (`queues[id]`), receiving speculative and urgent
//!     submissions from any worker.
//!   - A ready-fiber queue (`ready_queues[id]`), receiving fibers
//!     woken by thunk resolves (`wakeFiberWaiters`). Both task and
//!     ready queues are stealable across workers.
//!   - A wake word (`wake_words[id]`) for futex-based parking.
//!
//! Worker 0 runs on the calling OS thread (it's the one returning the
//! result to the user); worker_ids 1..N-1 are helper threads spawned
//! in `start()`. There is no behavioral asymmetry beyond who created
//! the thread — submissions, steals, wakes, and ready-fiber routing
//! all treat workers uniformly.
//!
//! Each worker's drain loop:
//!   1. Pop own ready fiber, or steal one from another worker.
//!   2. Pop own task, or steal one from another worker (FIFO at the
//!      victim).
//!   3. Park on its wake_word until a submitter / waker nudges.
//!
//! Submissions may fail (full queue). Speculative submissions are
//! best-effort and additionally gated by a backlog cap. Urgent
//! (demand-driven) submissions skip the cap.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("runtime").types;
const stable = @import("base").sync;
const gc = @import("runtime").gc;
const heap_mod = @import("runtime").heap;
const containers = @import("base");
const build_options = @import("build_options");

/// Idle-scan cost census (piggybacks on `-Dprof-main`, like the probes in
/// `probe/prof.zig` — the scheduler can't import that layer, so the tiny
/// rdtsc + flush machinery is local). Buckets the cycles each drain-loop
/// probe class burns (own pops vs the O(N) per-peer steal scans over the
/// ready queues / urgent deques / novel rings / spec rings / cont deques)
/// so the w>16 idle-churn work targets the structure that actually
/// dominates. Zero-cost when the build flag is off.
const scan_census_on = build_options.prof_main and builtin.cpu.arch == .x86_64;

pub const ScanCensus = struct {
    ready_pop_cy: u64 = 0,
    ready_pop_calls: u64 = 0,
    ready_pop_hits: u64 = 0,
    ready_steal_cy: u64 = 0,
    ready_steal_calls: u64 = 0,
    ready_steal_hits: u64 = 0,
    pop_own_cy: u64 = 0,
    pop_own_calls: u64 = 0,
    pop_own_hits: u64 = 0,
    urgent_steal_cy: u64 = 0,
    urgent_steal_calls: u64 = 0,
    urgent_steal_hits: u64 = 0,
    novel_steal_cy: u64 = 0,
    novel_steal_calls: u64 = 0,
    novel_steal_hits: u64 = 0,
    spec_steal_cy: u64 = 0,
    spec_steal_calls: u64 = 0,
    spec_steal_hits: u64 = 0,
    cont_steal_cy: u64 = 0,
    cont_steal_calls: u64 = 0,
    cont_steal_hits: u64 = 0,
};

threadlocal var scan_local: if (scan_census_on) ScanCensus else void = if (scan_census_on) ScanCensus{} else {};
var scan_totals_mu: std.atomic.Value(u8) = .init(0);
var scan_totals: ScanCensus = .{};

inline fn rdtscScan() u64 {
    if (comptime !scan_census_on) return 0;
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdtsc"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
        :
        : .{ .memory = true });
    return (@as(u64, high) << 32) | @as(u64, low);
}

inline fn scanEnd(comptime prefix: []const u8, t0: u64, hit: bool) void {
    if (comptime !scan_census_on) return;
    @field(scan_local, prefix ++ "_cy") += rdtscScan() -% t0;
    @field(scan_local, prefix ++ "_calls") += 1;
    if (hit) @field(scan_local, prefix ++ "_hits") += 1;
}

/// Merge this thread's census into the global totals. Called on every
/// park (natural batching point) and once from the quiescence barrier /
/// report so helper exit paths don't strand their counters.
fn scanFlush() void {
    if (comptime !scan_census_on) return;
    while (scan_totals_mu.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    defer scan_totals_mu.store(0, .release);
    inline for (@typeInfo(ScanCensus).@"struct".fields) |f| {
        @field(scan_totals, f.name) += @field(scan_local, f.name);
    }
    scan_local = .{};
}

/// `--print-sched-stats` (prof builds): dump the idle-scan cost breakdown.
pub fn reportScanCensus() void {
    if (comptime !scan_census_on) return;
    scanFlush(); // caller's (worker 0's) residue
    const t = &scan_totals;
    const total = t.ready_pop_cy + t.ready_steal_cy + t.pop_own_cy +
        t.urgent_steal_cy + t.novel_steal_cy + t.spec_steal_cy + t.cont_steal_cy;
    if (total == 0) return;
    std.debug.print("prof scan-census (all workers, drain-loop probe cycles, total={d}):\n", .{total});
    inline for (.{ "ready_pop", "ready_steal", "pop_own", "urgent_steal", "novel_steal", "spec_steal", "cont_steal" }) |name| {
        const cy = @field(t, name ++ "_cy");
        const calls = @field(t, name ++ "_calls");
        const hits = @field(t, name ++ "_hits");
        std.debug.print("  {s}: cy={d} ({d:.1}%) calls={d} hits={d} ({d:.2}% hit) avg_cy={d}\n", .{
            name,                cy,
            if (total == 0) @as(f64, 0) else 100.0 * @as(f64, @floatFromInt(cy)) / @as(f64, @floatFromInt(total)),
            calls,               hits,
            if (calls == 0) @as(f64, 0) else 100.0 * @as(f64, @floatFromInt(hits)) / @as(f64, @floatFromInt(calls)),
            if (calls == 0) 0 else cy / calls,
        });
    }
}

pub const Task = union(enum) {
    /// Speculatively force a thunk to its result. The thunk lives in the
    /// shared ObjectHeap; ObjectId identifies it.
    force_thunk: types.ObjectId,
    /// Force a contiguous range of items from a list. Used by consumer-
    /// side fan-out so each scheduled task pays the queue + wake overhead
    /// once for a meaningful chunk of work instead of once per thunk.
    /// The helper looks up `list_id` in the heap, iterates
    /// `items[offset..offset+len]`, and forces each thunk-typed slot.
    /// `len` is u8 — batches are O(10s) of items; longer lists submit
    /// multiple batched tasks.
    force_list_range: ForceListRange,
    /// Demand-sibling prefetch (`FIX_SIBLING`): speculatively force every
    /// still-unresolved thunk member of one attrset. Submitted (once per
    /// attrset — see `AttrsObject.sibling_swept`) when a DEMAND fiber's
    /// attr lookup misses the inline cache and lands on an unresolved
    /// member of a mid-sized attrset: reading one member of such a set
    /// strongly predicts reading its siblings (measured junk ratio
    /// 17-29% at 16-63 entries vs 99% at >=256 — hence the size gate).
    force_attrs_sweep: types.ObjectId,
    /// Force a contiguous range of an attrset's entries — the attrs
    /// analogue of `force_list_range` (the heap lays attrs out as a
    /// positional slice, so the same offset/len shape works). Used by
    /// the strict-attrset-walk fan-out so a NixOS option-merge burst
    /// costs the submitter one queue push per ~16 entries instead of
    /// one per thunk.
    force_attrs_range: ForceAttrsRange,
    /// Speculative import prefetch (`FIX_IMPORT_PREFETCH`): resolve +
    /// parse + compile + top-level-eval the `.nix` file named by this
    /// interned absolute path, populating the import registry ahead of
    /// the demand fiber. Discovered from `.path` constants of freshly
    /// compiled chunks (see `ChunkRegistry.register`); deduplicated
    /// per path by the Evaluator before submission. Holds no heap
    /// ObjectId — nothing to GC-mark.
    import_prefetch: types.InternId,
    /// Speculative readDir-children prefetch (`FIX_READDIR_PREFETCH`):
    /// when a COLD `builtins.readDir` returns a directory-of-directories
    /// (pkgs/by-name: 756 shard dirs, ~21K entries), the demand fiber is
    /// about to readDir each child sequentially on the critical chain.
    /// The submitter fans the child index space out as these range tasks;
    /// a helper re-reads the parent listing (warm FileCache hit) and
    /// readDirs the directory-kind children in `[offset, offset+len)`,
    /// warming the FileCache the demand fiber is about to walk. Pure
    /// cache population — no heap objects, no eval side effects, errors
    /// swallowed (failures are NOT cached, so demand replays them
    /// identically). Holds no heap ObjectId — nothing to GC-mark.
    readdir_prefetch: ReadDirPrefetch,
};

pub const ReadDirPrefetch = struct {
    /// Interned parent directory path (any spelling — the FileCache
    /// canonicalises, so helper and demand land on the same entry).
    dir: types.InternId,
    offset: u32,
    len: u16,
};

/// Which queue a popped/stolen task came from. Purely informational —
/// used by the `-Dprof-main` task census to attribute a `force_thunk`
/// to its submission class (urgent fan-out vs novel-lane vs bulk spec).
pub const Lane = enum(u8) { urgent, novel, spec };

pub const ForceListRange = struct {
    list_id: types.ObjectId,
    offset: u32,
    len: u8,
};

pub const ForceAttrsRange = struct {
    attrs_id: types.ObjectId,
    offset: u32,
    len: u8,
};

/// Work-first (Cilk/sparks) split-and-steal continuation — a half-open range
/// `[lo, hi)` of a collection's items exposed on the per-worker continuation
/// deque (`cont_queues`). `kind` distinguishes a list slot walk from an attr
/// slot walk (the heap stores each as a positional slice, so the range is
/// index-based either way). Owner-pushed/popped LIFO on the fast (unstolen)
/// path; FIFO-stolen by an idle worker that re-splits it. See
/// `force.forceRangeWorkFirst`.
pub const ContKind = enum(u8) { list, attrs };
pub const Continuation = struct {
    id: types.ObjectId,
    lo: u32,
    hi: u32,
    kind: ContKind,
};

/// Embeddable linked-list node for the per-worker ready queue.
/// Each Fiber struct (in worker.zig) inlines one of these; the
/// scheduler holds queues of `*ReadyNode` and the worker recovers
/// the parent Fiber via `@fieldParentPtr`.
///
/// `queued` is a CAS-protected dedup flag: `enqueueReady` only
/// pushes when it can transition 0→1, and `pop` resets to 0. This
/// keeps the node from being on the queue more than once even when
/// multiple wakers and runner-tail paths race to enqueue.
pub const ReadyNode = struct {
    next: ?*ReadyNode = null,
    queued: std.atomic.Value(u8) = .init(0),
};

/// Mutex-protected FIFO of fibers ready to resume. Sits on the
/// scheduler so any worker can push (when waking a fiber) or steal
/// (when its own queue is empty). Treiber stacks would suffice if
/// only the owner consumed, but stealing needs MPMC pop and Treiber's
/// CAS pop has ABA hazards under concurrent consumers.
const ReadyQueue = struct {
    /// `align(cache_line)`: one ready queue per destructive-interference
    /// block (128B). `mu`/`head`/`tail` are written together under the
    /// lock, so they SHOULD share a line — but at 24B packed, ~2.7
    /// queues shared one, and every idle worker's steal scan probes
    /// every peer's queue: worker i's push/pop invalidated the line
    /// under workers i±1's queues too.
    mu: stable.SpinMutex align(std.atomic.cache_line),
    /// Mutated only under `mu`; additionally probed lock-free by `pop`'s
    /// empty fast path (monotonic — the lock provides the real
    /// synchronization for any node actually taken).
    head: std.atomic.Value(?*ReadyNode),
    tail: ?*ReadyNode,

    comptime {
        std.debug.assert(@sizeOf(ReadyQueue) % std.atomic.cache_line == 0);
    }

    fn init() ReadyQueue {
        return .{ .mu = .{}, .head = .init(null), .tail = null };
    }

    fn push(self: *ReadyQueue, node: *ReadyNode) void {
        node.next = null;
        self.mu.lock();
        defer self.mu.unlock();
        if (self.tail) |t| {
            t.next = node;
        } else {
            self.head.store(node, .monotonic);
        }
        self.tail = node;
    }

    fn pop(self: *ReadyQueue) ?*ReadyNode {
        // Read-only empty probe BEFORE touching the lock. Idle workers'
        // steal scans call `pop` on every peer's (almost always empty)
        // queue each rescan; the unconditional `mu.lock()` CAS was a
        // read-for-ownership that ping-ponged the queue's line between
        // every scanning core even when nothing was queued. A stale null
        // here is benign — same outcome as scanning just before the
        // racing push; the wake/futex protocol re-engages parked workers.
        if (self.head.load(.monotonic) == null) return null;
        self.mu.lock();
        defer self.mu.unlock();
        const n = self.head.load(.monotonic) orelse return null;
        self.head.store(n.next, .monotonic);
        if (n.next == null) self.tail = null;
        n.next = null;
        // Mark off-queue so the next `enqueueReady` for this node can
        // win its CAS. Release-store so it's visible to the next
        // would-be enqueuer.
        n.queued.store(0, .release);
        return n;
    }
};

/// One worker's futex wake word, alone in its destructive-interference
/// block (128B). As a bare `[]std.atomic.Value(u32)`, 32 workers' wake
/// words all sat in ONE cache line: every park (store 0) and every wake
/// (swap 1) invalidated the line under every other parking/waking core.
pub const WakeWord = struct {
    word: std.atomic.Value(u32) align(std.atomic.cache_line) = .init(0),

    comptime {
        std.debug.assert(@sizeOf(WakeWord) % std.atomic.cache_line == 0);
    }
};

/// Lock-free Chase-Lev work-stealing deque, specialized to `Task`.
///
/// Owner-only `push` and `pop` (LIFO) — atomic stores on `bottom`
/// with no CAS on the hot path. `steal` is multi-consumer (FIFO),
/// CAS-on-`top` to claim a slot.
///
/// Memory ordering follows the standard Chase-Lev formulation
/// (Le-Pop-Cohen-Nardelli-Padua 2013 revision):
///   - `bottom` writes use release; reads in stealers use acquire.
///   - `top` writes use seq_cst (CAS) so the owner's `pop` race for
///     the last element synchronises with concurrent steals.
///   - The seq_cst fence in `pop` after writing `bottom` is what
///     prevents the owner from "seeing past" a stealer that has
///     already taken the slot.
///
/// Capacity is fixed power-of-two; full push returns false and the
/// caller drops the task (speculation is best-effort; urgent
/// submission's cap is enforced upstream by `pending_tasks`).
///
/// The generic engine lives in `containers.Deque` (extracted so GC mark
/// work can reuse the same lock-free ring for `Deque(ObjectId)`); this is a
/// thin alias plus the `Task`-specific `gcMark` helper.
/// A queued task plus the monotonic-ns timestamp of when it was pushed. The
/// timestamp is only populated when flow tracing is on (`trace_flows`) — it
/// costs one clock read per push and lets the timeline anchor the work-stealing
/// arrow's producer end to the quantum that actually *created* the task (see
/// `Worker.drainStep`). Off the tracing path it's a dead `0` (negligible: the
/// deque slot grows 8 bytes, no clock read).
pub const TracedTask = struct {
    task: Task,
    push_ts: u64 = 0,
};

const TaskQueue = containers.Deque(TracedTask);

/// Mutex-protected bounded ring of speculative tasks. Replaces the Chase-Lev
/// deque for the SPEC lane only (urgent stays lock-free): speculation is
/// low-volume (~20-50K submissions per NixOS eval, vs millions of forces), so
/// a SpinMutex ring is affordable, and it buys the two behaviors Chase-Lev
/// cannot express:
///   - ring overwrite (`FIX_SPEC_EVICT`): when full, drop the OLDEST queued
///     task to admit the fresh one (freshest ≈ nearest the demand head);
///   - newest-first stealing (`FIX_SPEC_LIFO`): stealers take the newest
///     task instead of Chase-Lev's oldest-first FIFO, so a just-submitted
///     seed is picked up in microseconds even under a saturated backlog.
/// With both knobs off it reproduces the old semantics exactly: owner pops
/// newest, stealers take oldest, full push rejects.
///
/// `head` is one past the newest slot; `tail` is the oldest. Both wrap; the
/// occupancy is `head -% tail`. All mutation is under `mu`; the GC mark walk
/// (`specQueueGcMark`) runs at the STW safepoint where no mutator is live.
const SpecQueue = struct {
    /// `align(cache_line)`: one spec ring per destructive-interference
    /// block (128B), same rationale as `ReadyQueue`. `mu`/`head`/`tail`
    /// are mutated together under the lock so they SHOULD share a line —
    /// but at ~40B packed, adjacent workers' rings shared one, and the
    /// idle steal scan (`stealSpecExcluding`, on both the novel and bulk
    /// lanes) locks every peer's ring each rescan: worker i's push/pop
    /// invalidated the line under workers i±1's rings too.
    mu: stable.SpinMutex align(std.atomic.cache_line),
    items: []TracedTask,
    mask: u32,
    head: u32,
    tail: u32,
    /// This ring's index in its lane (owner worker id), i.e. its bit in
    /// the lane's non-empty victim mask. Rings past bit 63 don't
    /// participate (the scan falls back to a full walk there).
    idx: u8,

    comptime {
        std.debug.assert(@sizeOf(SpecQueue) % std.atomic.cache_line == 0);
    }

    const PushResult = enum { pushed, pushed_evicted, full };

    fn init(allocator: std.mem.Allocator, capacity: u32, idx: u8) !SpecQueue {
        std.debug.assert(std.math.isPowerOfTwo(capacity));
        const items = try allocator.alloc(TracedTask, capacity);
        return .{ .mu = .{}, .items = items, .mask = capacity - 1, .head = 0, .tail = 0, .idx = idx };
    }

    fn deinit(self: *SpecQueue, allocator: std.mem.Allocator) void {
        allocator.free(self.items);
    }

    /// Set/clear this ring's bit in the lane's non-empty victim mask.
    /// Called ONLY while holding `mu`, so per-ring bit updates are
    /// ordered exactly with the occupancy transitions they mirror — the
    /// mask itself is never stale for a ring; only a scanner's loaded
    /// copy can be (benign: it re-probes an emptied ring and moves on).
    inline fn maskSet(self: *const SpecQueue, lane_mask: *std.atomic.Value(u64)) void {
        if (self.idx >= 64) return;
        _ = lane_mask.fetchOr(@as(u64, 1) << @intCast(self.idx), .release);
    }
    inline fn maskClear(self: *const SpecQueue, lane_mask: *std.atomic.Value(u64)) void {
        if (self.idx >= 64) return;
        _ = lane_mask.fetchAnd(~(@as(u64, 1) << @intCast(self.idx)), .release);
    }

    /// Append at the newest end. On a full ring: drop the oldest when
    /// `evict`, else reject.
    fn push(self: *SpecQueue, t: TracedTask, evict: bool, lane_mask: *std.atomic.Value(u64)) PushResult {
        self.mu.lock();
        defer self.mu.unlock();
        var evicted = false;
        if (self.head -% self.tail > self.mask) {
            if (!evict) return .full;
            self.tail +%= 1;
            evicted = true;
        }
        if (self.head == self.tail) self.maskSet(lane_mask);
        self.items[self.head & self.mask] = t;
        self.head +%= 1;
        return if (evicted) .pushed_evicted else .pushed;
    }

    /// Owner pop — newest first (matches the old deque's owner LIFO).
    fn popNewest(self: *SpecQueue, lane_mask: *std.atomic.Value(u64)) ?TracedTask {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.head == self.tail) return null;
        self.head -%= 1;
        if (self.head == self.tail) self.maskClear(lane_mask);
        return self.items[self.head & self.mask];
    }

    /// Stealer take: newest-first when `lifo` (demand-head-adjacent bets),
    /// oldest-first otherwise (historical FIFO).
    fn steal(self: *SpecQueue, lifo: bool, lane_mask: *std.atomic.Value(u64)) ?TracedTask {
        if (lifo) return self.popNewest(lane_mask);
        self.mu.lock();
        defer self.mu.unlock();
        if (self.head == self.tail) return null;
        const t = self.items[self.tail & self.mask];
        self.tail +%= 1;
        if (self.head == self.tail) self.maskClear(lane_mask);
        return t;
    }

    /// Drop the oldest queued task without running it (backlog-cap ring
    /// overwrite). Returns false when empty.
    fn evictOldest(self: *SpecQueue, lane_mask: *std.atomic.Value(u64)) bool {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.head == self.tail) return false;
        self.tail +%= 1;
        if (self.head == self.tail) self.maskClear(lane_mask);
        return true;
    }
};

/// Per-worker deque of work-first split-and-steal continuations (see
/// `Continuation`). Same Chase-Lev engine as `TaskQueue`, distinct payload.
const ContQueue = containers.Deque(Continuation);

/// GC (`-Dgc`): mark the objects referenced by pending tasks. A queued
/// `force_thunk`/`force_list_range` is a live reference (a helper — or,
/// after this collection, demand — may still force it). Called only at
/// the STW safepoint, so `top..bottom` is stable.
fn taskQueueGcMark(q: *const TaskQueue, tr: *gc.Tracer, heap: *const heap_mod.ObjectHeap) void {
    const t = q.top.v.load(.monotonic);
    const b = q.bottom.v.load(.monotonic);
    var i = t;
    while (i != b) : (i +%= 1) {
        switch (q.items[@intCast(i & q.mask)].task) {
            .force_thunk => |id| tr.markObject(heap, id),
            .force_list_range => |r| tr.markObject(heap, r.list_id),
            .force_attrs_sweep => |id| tr.markObject(heap, id),
            .force_attrs_range => |r| tr.markObject(heap, r.attrs_id),
            .import_prefetch, .readdir_prefetch => {},
        }
    }
}

/// GC (`-Dgc`): same, for the mutexed spec ring. STW-only — no mutator holds
/// `mu`, so a plain `tail..head` walk is stable.
fn specQueueGcMark(q: *const SpecQueue, tr: *gc.Tracer, heap: *const heap_mod.ObjectHeap) void {
    var i = q.tail;
    while (i != q.head) : (i +%= 1) {
        switch (q.items[i & q.mask].task) {
            .force_thunk => |id| tr.markObject(heap, id),
            .force_list_range => |r| tr.markObject(heap, r.list_id),
            .force_attrs_sweep => |id| tr.markObject(heap, id),
            .force_attrs_range => |r| tr.markObject(heap, r.attrs_id),
            .import_prefetch, .readdir_prefetch => {},
        }
    }
}

/// Monotonic-ns clock, matching `probe/timeline.zig`'s `nowNs` domain so the
/// push timestamps and the timeline's quantum spans share one time base. The
/// scheduler can't import the probe layer, so the formula is duplicated here.
fn monotonicNs() u64 {
    if (builtin.os.tag != .linux) return 0;
    var ts: std.os.linux.timespec = undefined;
    if (std.os.linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    const sec: u64 = if (ts.sec > 0) @intCast(ts.sec) else 0;
    const nsec: u64 = if (ts.nsec > 0) @intCast(ts.nsec) else 0;
    return sec * std.time.ns_per_s + nsec;
}

// Demand-driven fanout arrives in bursts: when the urgent queue rejects,
// the caller falls back to serially forcing the rest of the list/attrset.
// Keep enough room that a NixOS toplevel fanout wave does not collapse
// back onto the critical path at 32 workers.
const urgent_queue_capacity: u32 = 4096;
const spec_queue_capacity: u32 = 4096;
/// Work-first continuation deque capacity (power of two). A full push just
/// stops splitting (the range is forced inline), so this only bounds how much
/// parallelism is exposed at once, not correctness.
const cont_queue_capacity: u32 = 4096;
/// Per-helper speculation backlog cap. `var` (not `const`) so `FIX_SPEC_BACKLOG`
/// can sweep it — it's the primary control on how much speculative garbage runs
/// ahead of demand, i.e. the peak-RSS↔wall knob.
var spec_backlog_per_helper: u32 = 128;
pub fn setSpecBacklog(n: u32) void {
    spec_backlog_per_helper = n;
}
const burst_wake_budget: u32 = 4;

/// Cap on helpers concurrently in the idle spin-rescan loop (see
/// `Scheduler.spinners`). Never binds at w<=8 (7 helpers all spin, the
/// measured-optimal behavior there); past that, only a core's worth of
/// helpers keep scanning while the rest park until a submit wake.
inline fn maxSpinners(worker_count: u8) u32 {
    if (max_spinners_override != 0) return max_spinners_override;
    return @max(7, @as(u32, worker_count) / 4);
}

/// `FIX_MAX_SPINNERS`: overrides the `maxSpinners` idle-spinner quota when
/// nonzero (probe knob; 0 = the default worker-count formula).
pub var max_spinners_override: u32 = 0;

/// GC parallel-mark hook (`-Dgc`): the Evaluator installs this so a parked
/// peer can help drain the mark graph. Type-erased to keep `parallel` free of
/// an `eval`/`runtime.gc` import (mirrors the heap's `GcHook`).
pub const GcMarkHook = struct {
    ctx: *anyopaque,
    /// Run marker `worker_id`'s drain-and-steal loop to termination.
    help: *const fn (ctx: *anyopaque, worker_id: u8) void,
};

pub const Scheduler = struct {
    /// Per-worker, cache-line-padded activity counters. A worker only
    /// ever touches `worker_counters[its_own_id]`, so the adds need no
    /// atomics and generate no inter-core coherence traffic. The
    /// `align(cache_line)` on the first field (128B on x86_64) rounds
    /// `@sizeOf(Counters)` up to a whole interference block AND aligns
    /// the slice allocation — a trailing `_pad` alone left the array
    /// 8-aligned, so slot boundaries could straddle line pairs and
    /// adjacent workers still shared a line.
    pub const Counters = struct {
        spec_ok: u64 align(std.atomic.cache_line) = 0,
        spec_rej: u64 = 0,
        urgent_ok: u64 = 0,
        urgent_rej: u64 = 0,
        pops: u64 = 0,
        steals: u64 = 0,
        cont_steals: u64 = 0,
        cont_pushes: u64 = 0,
        parks: u64 = 0,
        scavenges: u64 = 0,
        sweeps: u64 = 0,
        evicts: u64 = 0,
        novel_ok: u64 = 0,
        spec_bails: u64 = 0,

        comptime {
            std.debug.assert(@sizeOf(Counters) % std.atomic.cache_line == 0);
        }
    };

    /// Record a speculative task abandoned at its root via
    /// `error.SpeculativeBail` (budget exhausted / demanded result already
    /// in hand). Called from the worker's task dispatch — off the hot
    /// path (once per bailed TASK, not per unwound thunk).
    pub fn noteSpecBail(self: *Scheduler, id: u8) void {
        self.bump(id, "spec_bails");
    }

    /// Bump one field of worker `id`'s own counter slot. `field` is the
    /// `Counters` field name. Bounds-guarded so a stray id can never
    /// corrupt memory — a miscounted stat is harmless, an OOB write is
    /// not. Off the atomics entirely: single-writer per slot.
    inline fn bump(self: *Scheduler, id: u8, comptime field: []const u8) void {
        if (id >= self.worker_count) return;
        @field(self.worker_counters[id], field) += 1;
    }

    /// Cumulative scheduler activity counters. Read via `stats()`.
    /// All values are advisory — monotonic loads are fine.
    pub const Stats = struct {
        speculative_submitted: u64,
        speculative_rejected: u64,
        urgent_submitted: u64,
        urgent_rejected: u64,
        pops: u64,
        steals: u64,
        cont_steals: u64 = 0,
        cont_pushes: u64 = 0,
        parks: u64,
        /// Thunks pre-forced by the idle scavenger (FIX_SCAVENGE).
        scavenges: u64 = 0,
        /// Attrset sibling sweeps submitted (FIX_SIBLING).
        sweeps: u64 = 0,
        /// Oldest-first spec-backlog evictions (FIX_SPEC_EVICT): queued
        /// speculative tasks dropped unrun to admit a fresher submission.
        evicts: u64 = 0,
        /// Novel-chunk speculative submissions (FIX_SPEC_NOVEL) — first-
        /// ever creation-time speculation of a code region, routed to the
        /// high-priority novel lane.
        novel_ok: u64 = 0,
        /// Speculative tasks abandoned at their root via
        /// `error.SpeculativeBail` (create/claim budget exhausted, or the
        /// demanded result arrived mid-task).
        spec_bails: u64 = 0,
        /// Deepest fiber native stack high-water seen across all workers
        /// since startup. Use to size `Fiber.min_stack_bytes` against a
        /// representative workload.
        max_fiber_stack_used_bytes: u64,
        /// Deepest VM value-stack sp seen across all workers, in Values.
        /// Multiply by `@sizeOf(Value)` (= 8) for a byte count.
        max_vm_sp: u64,
        /// Summed across all workers (main + helpers): time spent parked
        /// on the wake futex, in nanoseconds. Together with `busy_ns` and
        /// the wall-clock run time, this lets `fix inspect` show whether
        /// helpers were starved (idle ≫ busy ⇒ not enough parallel work)
        /// or saturated (busy ≈ wall × workers ⇒ CPU-bound).
        idle_ns: u64,
        /// Summed across all workers: time spent inside a fiber's
        /// `inner.resume_` (actual evaluation work). Excludes ready-queue
        /// pops and steal attempts — those are nanoseconds compared to
        /// either bucket and don't change the utilisation picture.
        busy_ns: u64,
    };

    allocator: std.mem.Allocator,
    /// Total number of workers, including worker 0 (main). After F1
    /// symmetrization there is no special main/helper split — every
    /// worker owns a queue, a wake word, and a ready-fiber stack. The
    /// only structural difference: worker 0 runs on the calling OS
    /// thread (it's the one delivering the result), so we spawn
    /// `worker_count - 1` helper threads in `start()`.
    worker_count: u8,
    /// Per-worker queue of *demand-driven* tasks — submitted via
    /// `submitUrgent`. Drained with priority over speculative tasks so
    /// fan-out and strictness-driven submissions don't sit behind a
    /// queued speculation backlog.
    // (GC hook defined below via gcMarkPendingTasks)
    urgent_queues: []TaskQueue,
    /// Per-worker queue of *speculative* tasks — submitted via
    /// `submit` when `makeThunk`'s heuristic suggests the body is
    /// substantial enough to pre-run. Drained only when there's no
    /// ready fiber or urgent task to handle. A mutexed ring (see
    /// `SpecQueue`) rather than Chase-Lev, so the backlog can ring-
    /// overwrite (`FIX_SPEC_EVICT`) and stealers can take newest-first
    /// (`FIX_SPEC_LIFO`).
    spec_queues: []SpecQueue,
    /// Per-worker high-priority speculative lane (`FIX_SPEC_NOVEL`):
    /// first-ever creation-time speculation of each chunk lands here (see
    /// `ChunkRegistry.markSpecSubmitted`). Drained after urgent, before
    /// the bulk spec lane; always newest-first and ring-overwriting, and
    /// exempt from the bulk backlog cap (volume is bounded at one task
    /// per chunk). Empty (and therefore free) when the knob is off.
    novel_queues: []SpecQueue,
    /// Per-worker deque of work-first split-and-steal continuations. Owner
    /// pushes/pops LIFO on the unstolen fast path; idle workers take FIFO.
    /// Separate from the eager task queues so the work-first pop-back never
    /// races the drain loop's task picks. Gated by `work_first`.
    cont_queues: []ContQueue,
    /// Per-worker ready-fiber queues. Producers are any thread waking a
    /// fiber (via thunk resolve → `Fiber.wakeImpl`); consumers are the
    /// owning worker (most often) or any worker stealing when its own
    /// queue is empty. Indexed by worker_id.
    ready_queues: []ReadyQueue,
    threads: []std.Thread,
    wake_words: []WakeWord,
    shutdown_flag: std.atomic.Value(bool),
    /// Count of helper threads that have stopped forcing (exited `run`)
    /// at shutdown. The quiescence barrier (`awaitHelpersQuiescent`) waits
    /// on this so no helper destroys its fibers while another could still
    /// resolve a thunk and wake a just-freed enrolled fiber.
    stopped_helpers: std.atomic.Value(u32) = .init(0),
    // The five globally-hot atomics below each get their own 128B
    // destructive-interference block (`align(cache_line)`), and the
    // comptime check at the end of the struct proves no other field
    // shares a block with any of them. Packed together (and next to
    // read-mostly fields like `worker_count` / `suppress_background`
    // that every drain-loop iteration reads), each `fetchAdd` here
    // invalidated its neighbors' lines on every submit/pop/steal scan
    // across all workers.
    next_victim: containers.Isolated(u32),
    /// Monotonic counter handing out fresh fiber ids at allocation.
    /// Fiber ids are scheduler-global so a fiber's identity doesn't
    /// change when it migrates across workers (F1 unpin). Used to
    /// construct `ClaimerId` and to label the fiber in traces.
    next_fiber_id: containers.Isolated(u32),
    started: std.atomic.Value(bool),
    /// Total tasks currently pending across all helper queues. Used to
    /// (a) skip submissions when the backlog already saturates helpers
    /// and (b) skip futex_wake syscalls when at least one helper has
    /// work to do and is therefore not parked.
    pending_tasks: containers.Isolated(u32),
    /// Number of helpers currently in the idle spin-rescan loop
    /// (parkAndAccount's pre-park spin + immediate rescan). Capped at
    /// `max_spinners` so at high worker counts the idle scan churn
    /// (O(N) queue probes per rescan, from every idle worker, burning
    /// the SMT siblings of busy workers) stays bounded: workers past
    /// the cap park on their futex immediately and are re-engaged by
    /// submit-side wakes. Worker 0 is exempt (it's the demand thread).
    spinners: containers.Isolated(u32),
    /// Net work-first continuations currently sitting on all `cont_queues`
    /// (pushed − popped/stolen). A single shared counter the pre-park spin
    /// reads to decide whether to keep spinning for stealable continuation
    /// work, without per-queue CAS probes (same design as `pending_tasks`).
    cont_pending: containers.Isolated(u32),
    /// Per-lane stealable-work summaries (scan-census-driven, see the
    /// w=32 idle-churn fix): net tasks currently sitting in each queue
    /// class across all workers. `pending_tasks` says work EXISTS but not
    /// in WHICH lane — so every idle drain pass paid an O(N) per-peer
    /// probe walk over all five classes even when a class was provably
    /// empty (at w=32 the novel + cont walks alone were ~48% of all scan
    /// cycles with a 0% hit rate). One read-mostly load per class now
    /// short-circuits the walk. Increments happen AFTER the queue push
    /// and decrements AFTER the take (same lag discipline as
    /// `pending_tasks`), so a zero is only ever transiently stale — the
    /// spin/wake protocol re-runs the scan within the same pass window.
    /// Purely advisory: a stale zero skips one scan pass, never a park
    /// decision (`pending_tasks` still gates those).
    ready_pending: containers.Isolated(u32),
    urgent_pending: containers.Isolated(u32),
    /// Non-empty VICTIM masks for the two mutexed spec-ring lanes: bit i
    /// set ⇔ ring i holds at least one task. Stronger than a count — the
    /// steal scan jumps straight to a non-empty victim instead of
    /// locking every peer's ring in turn to find one (the census showed
    /// even 60%-hit scans averaging thousands of cycles walking empty
    /// rings). Maintained exactly, under each ring's own mutex, on its
    /// empty↔non-empty transitions; flip volume is bounded by task
    /// throughput on lanes that are low-volume by design.
    novel_mask: containers.Isolated(u64),
    spec_mask: containers.Isolated(u64),
    /// Per-worker activity counters. Each worker writes ONLY its own
    /// slot — single-writer, plain non-atomic adds. This kills the
    /// cross-core cache-line contention that shared-atomic counters
    /// caused on the hot submit/pop/steal/park path: at high worker
    /// counts dozens of cores `fetchAdd`-ing the same lines was pure
    /// coherence traffic that scaled *against* us (slower past ~8).
    /// Summed at report time, after all workers have quiesced. Each
    /// slot is padded to a cache line so adjacent workers never share
    /// one (no false sharing).
    worker_counters: []Counters,
    n_max_fiber_stack: std.atomic.Value(u64),
    n_max_vm_sp: std.atomic.Value(u64),
    n_idle_ns: std.atomic.Value(u64),
    n_busy_ns: std.atomic.Value(u64),

    /// Measurement toggles. When set, the corresponding submission path
    /// short-circuits to false without touching the queues. Used by
    /// `--no-spec-thunks` / `--no-fanout` to A/B which kind of parallel
    /// work contributes how much to wall time.
    disable_speculation: bool,
    disable_fanout: bool,

    /// `FIX_WORK_FIRST`: route strict collection-force acceleration through the
    /// work-first split-and-steal primitive (`forceRangeWorkFirst`) instead of
    /// the eager `fanOut*Shallow`. Set once before helpers start, read-only
    /// during eval (plain bool — no atomic needed). Default off while landing.
    work_first: bool,

    /// `FIX_SCAVENGE`: idle helpers pre-force old unresolved thunks from
    /// the per-worker creation rings (`ObjectHeap.scavengeSteal`) —
    /// lowest-priority work, after ready fibers / tasks / continuations.
    /// Set once before helpers start, read-only during eval.
    scavenge_enabled: bool = false,
    /// Skip the newest N ring entries when scavenging (see
    /// `scavengeSteal`). `FIX_SCAV_MARGIN` overrides.
    scav_margin: u64 = 4096,
    /// Highest worker id allowed to scavenge. `FIX_SCAV_WORKERS` overrides.
    scav_workers: u8 = 7,

    /// Demand-sibling prefetch. On a demand fiber's inline-cache MISS
    /// landing on a still-unresolved thunk member of a plain attrset
    /// with entry count in `[sibling_min, sibling_max)`, submit ONE
    /// speculative `force_attrs_sweep` task for the whole set (deduped
    /// by `AttrsObject.sibling_swept`). ON by default when helpers exist
    /// (the evaluator sets it before `start`); `FIX_SIBLING=0` disables.
    /// Read-only during eval.
    sibling_prefetch: bool = false,
    /// Attrset entry-count gate. Defaults from the `-Dprof-main` sibling
    /// census: 16-63 entries = 17-29% junk; >=64 grows to 51%, >=256 is
    /// 99% junk (pkgs-like sets — sweeping those evaluates all of
    /// nixpkgs). `FIX_SIBLING_MIN`/`FIX_SIBLING_MAX` override.
    sibling_min: u32 = 16,
    sibling_max: u32 = 64,
    /// Per-member CREATION budget for sweep tasks (see
    /// `VM.spec_create_left`): a wrongly-predicted member's cascade is
    /// abandoned once it has created this many new thunks.
    /// `FIX_SIBLING_BUDGET` overrides.
    sibling_budget: u64 = 4096,
    /// Per-member CLAIMED-force budget, split from the creation budget
    /// (see `VM.spec_budget`; `FIX_SIBLING_CLAIMS` overrides). Claims
    /// re-force existing thunks (convergent chains — the etc/service
    /// tails need thousands of claims but few creations); creations are
    /// where junk cascades blow up (derivation bodies). A high claim
    /// budget with the default creation budget lets convergent chains
    /// finish without re-opening the junk-by-cost dragon.
    sibling_claim_budget: u64 = 4096,
    /// Submit sweeps to the urgent queue (drained before the speculative
    /// backlog) instead of the spec queue. Default ON — measured strictly
    /// better on the NixOS toplevel (w=8 median 1.24s→1.03s vs ~1.3s at
    /// spec priority, and LOWER RSS: urgent sweeps start early enough to
    /// win the race with main, and they displace never-demanded
    /// creation-time speculation). `FIX_SIBLING_URGENT=0` reverts to
    /// spec priority.
    sibling_urgent: bool = true,
    /// `FIX_SIBLING_LOG`: per-sweep stderr diagnostics (attrs id, size,
    /// member body locations, heap-growth delta). Debug-only.
    sibling_log: bool = false,
    /// Speculative readDir-children prefetch (`FIX_READDIR_PREFETCH`):
    /// a COLD `builtins.readDir` whose listing contains at least this
    /// many DIRECTORY children fans the children out as
    /// `readdir_prefetch` range tasks (helpers warm the FileCache the
    /// demand fiber is about to walk serially — pkgs/by-name is 756
    /// shard dirs read back-to-back on the chain). 0 = off (the w=1 and
    /// disabled default). Read-only during eval.
    readdir_prefetch_min: u32 = 0,
    /// Remaining child-listing budget (`FIX_READDIR_PREFETCH_MAX`);
    /// decremented per SUBMITTED child range so a pathological readDir
    /// fan-out can't flood the queues. Atomic — any worker's readDir
    /// may submit.
    readdir_prefetch_budget: containers.Isolated(u32) = .init(0),
    /// `FIX_SPEC_CREATE_BUDGET`: per-task thunk-CREATION budget for
    /// spec-lane `force_thunk` tasks (creation-time speculation + the
    /// novel lane), reusing the sweep-task bounded-speculation machinery
    /// (`VM.spec_create_left`; bail = transient reset, resolved
    /// sub-thunks kept). 0 = unbounded (historical behavior). Motivation:
    /// at w=32, spec-created thunks reach 10-13M/eval with ~49% never
    /// demanded — junk VOLUME, not discovery, is the residual w=32
    /// regression; a creation budget caps each wrong guess's cascade.
    /// Urgent-lane tasks are never budgeted (they're demand-adjacent).
    spec_task_create_budget: u64 = 0,
    /// `FIX_SPEC_CLAIMS`: per-task CLAIMED-force budget for spec-lane
    /// `force_thunk` tasks — the claims analogue of
    /// `spec_task_create_budget` (see `VM.spec_budget`; the sibling
    /// sweeps' per-member claim budget is separate,
    /// `sibling_claim_budget`). 0 = unbounded (default).
    spec_task_claim_budget: u64 = 0,
    /// `FIX_SPEC_BAND_BUDGET`: hard per-task creation budget for
    /// speculative `force_thunk` tasks whose ROOT chunk is below the
    /// trusted size (`ChunkSlot.spec_band_small`, effective size <
    /// `SPECULATION_TRUSTED_CODE_BYTES`) — the sub-256 combinator family
    /// whose single execution can recursively force multi-million-thunk
    /// never-demanded subgraphs. Default ON at 512: with the admission
    /// gate at its default (== trusted threshold) no band chunk is ever
    /// submitted, so this is dormant and free; it makes gate/encoding
    /// shifts and aged-pool drains of the band contained by construction
    /// (2026-07: gate 192 unbudgeted +15-52% w=8 wall; under this budget
    /// = baseline). 0 disables.
    spec_band_budget: u64 = 512,
    /// `FIX_SPEC_EVICT`: ring semantics for the speculation backlog. When
    /// the global backlog cap (or the submitter's own ring) is full, DROP
    /// THE OLDEST queued spec task and admit the fresh submission, instead
    /// of rejecting the newest. The newest submission was created nearest
    /// the demand head; the oldest queued task is the stalest bet. Measured
    /// motivation: the /etc per-file chain's seed thunk is submitted ONCE
    /// (creation-time speculation) ~40ms into a NixOS toplevel eval — when
    /// the cap-rejection lottery drops it, the whole ~300ms serial chain
    /// starts ~250ms later and w=8 wall goes 0.95 → 1.05-1.12s. Eviction
    /// is semantics-safe: a dropped spec task leaves its thunk unresolved
    /// for demand to force later (same as a rejected submit).
    spec_evict: bool = false,
    /// `FIX_SPEC_LIFO`: stealers take the NEWEST speculative task instead
    /// of the oldest. The owner already pops its own spec queue newest-
    /// first; oldest-first stealing handed helpers the STALEST bets — the
    /// exact inverse of demand-head adjacency. With this on, a fresh seed
    /// submission is picked up almost immediately even under a saturated
    /// backlog, instead of waiting behind (or being evicted with) hundreds
    /// of stale speculations.
    spec_lifo: bool = false,
    /// `FIX_SPEC_NOVEL`: route the FIRST-ever creation-time speculation of
    /// each chunk (a new code region — potential subsystem/chain root) to
    /// the high-priority `novel_queues` lane, drained before the bulk spec
    /// backlog and exempt from its cap. Repeat instances of already-seen
    /// chunks stay in the bulk lane. Measured motivation: the /etc chain
    /// seed (etc.nix:248) is the single first instance of its chunk; in
    /// the bulk lane it must win a pop/steal race against hundreds of
    /// repeat-instance junk tasks within ~1ms of submit or the whole
    /// ~300ms serial chain starts ~250ms late (w=8 wall 0.95 → 1.05-1.15).
    spec_novel: bool = false,
    /// `FIX_SPEC_HELPERS`: highest worker id allowed to take BULK-spec
    /// tasks (own-pop and steal). 255 = uncapped (default, the historical
    /// behavior). Urgent, novel, cont, ready and sweep work stay open to
    /// every worker — this only narrows who drains the bulk speculation
    /// backlog, so at high worker counts the junk-spec execution volume
    /// (spec_ok 3.1x at w=32 vs w=8, +32% thunks) stops scaling with the
    /// worker count. Workers past the cap use a lane-aware pre-park spin
    /// probe (`takableWork`) so they never busy-spin on a backlog they
    /// are not allowed to touch.
    spec_helper_cap: u8 = 255,
    /// `FIX_TOUCH_LOG=<file substring>`: diagnosis probe — log every thunk
    /// CLAIM whose source file basename matches, with timestamp, worker,
    /// and spec/demand context (see `vm/force.zig logTouch`). Debug-only;
    /// one null-check on the claim slow path when off.
    touch_log: ?[]const u8 = null,

    /// When set (by `setTraceFlows`, driven by `--timeline`), `pushOwn` stamps
    /// each task with its push time so the timeline can anchor the steal arrow
    /// to the producing quantum. Off by default — one dead branch per push.
    trace_flows: bool = false,

    /// Set once a top-level demanded result is ready, to stop workers
    /// from *starting* new background (speculative / fan-out) tasks while
    /// the drain loop waits for already-suspended fibers to retire. Bounds
    /// the worst case where speculation guessed a large, never-demanded
    /// body: without it, helpers keep pulling the dead backlog and extend
    /// wall time past when the answer was computed (a self-inflicted
    /// pathology — see docs/plans/parallel-redesign-plan.md). In-flight fibers
    /// still drain to completion (a suspended fiber only waits on an
    /// already-claimed thunk, never on a queued task), so correctness is
    /// unaffected; only un-started backlog work is skipped.
    suppress_background: std.atomic.Value(bool),

    /// GC stop-the-world barrier (`-Dgc`). When a worker crosses the
    /// collection threshold at a safepoint it CASes `gc_stop_requested`
    /// true and becomes the sole collector. Every other worker, on seeing
    /// the flag at its own safepoint, sets its per-worker `gc_worker_parked`
    /// flag and spins until the flag clears. The collector waits for all
    /// peers' flags to be set, runs mark+sweep alone (no concurrent
    /// mutation), clears the stop flag, then waits for all peers' flags to
    /// clear before returning — a full two-phase barrier, so a slow peer can
    /// never carry a stale parked state into the next collection (which a
    /// shared counter + epoch could). `void`-free but inert in non-`-Dgc`.
    gc_stop_requested: if (gc.enabled) std.atomic.Value(bool) else void,
    gc_worker_parked: if (gc.enabled) []std.atomic.Value(bool) else void,

    /// Parallel-mark phase gate (`-Dgc`, `--workers>1`). Once every peer is
    /// parked (`gcWaitAllParked`), the collector seeds the roots and then
    /// opens this flag; each parked peer, seeing it, calls the mark hook to
    /// help drain the graph (marker slot == its worker id) instead of merely
    /// spinning. It stays open for the whole mark and is closed only AFTER
    /// termination (when every marker has provably entered and returned), so
    /// no peer can miss the mark and hang the work-stealing terminator.
    gc_mark_open: if (gc.enabled) std.atomic.Value(bool) else void,
    /// Installed by the Evaluator: runs `Tracer.drainParallel(worker_id)` to
    /// termination. Lets the scheduler drive the marker without importing
    /// `eval`/`gc` (same type-erasure as the heap's collect hook).
    gc_mark_hook: if (gc.enabled) ?GcMarkHook else void,

    /// `worker_count` includes the main thread (worker 0). The
    /// scheduler spawns `worker_count - 1` helper threads in `start()`;
    /// worker 0 runs on the calling thread.
    pub fn init(allocator: std.mem.Allocator, worker_count: u8) !Scheduler {
        const safe_worker_count: u8 = if (worker_count == 0) 1 else worker_count;

        // Two queues per worker — urgent (demand-driven) and speculative.
        // Plus one ready-fiber queue and one wake word. Symmetric task
        // ownership; the only thing not symmetric is who spawned which
        // thread.
        const urgent_queues = try allocator.alloc(TaskQueue, safe_worker_count);
        errdefer allocator.free(urgent_queues);
        var urgent_init: usize = 0;
        errdefer for (urgent_queues[0..urgent_init]) |*q| q.deinit(allocator);
        for (urgent_queues) |*q| {
            q.* = try TaskQueue.init(allocator, urgent_queue_capacity);
            urgent_init += 1;
        }

        const spec_queues = try allocator.alloc(SpecQueue, safe_worker_count);
        errdefer allocator.free(spec_queues);
        var spec_init: usize = 0;
        errdefer for (spec_queues[0..spec_init]) |*q| q.deinit(allocator);
        for (spec_queues, 0..) |*q, i| {
            q.* = try SpecQueue.init(allocator, spec_queue_capacity, @intCast(i));
            spec_init += 1;
        }

        const novel_queues = try allocator.alloc(SpecQueue, safe_worker_count);
        errdefer allocator.free(novel_queues);
        var novel_init: usize = 0;
        errdefer for (novel_queues[0..novel_init]) |*q| q.deinit(allocator);
        for (novel_queues, 0..) |*q, i| {
            q.* = try SpecQueue.init(allocator, spec_queue_capacity, @intCast(i));
            novel_init += 1;
        }

        const cont_queues = try allocator.alloc(ContQueue, safe_worker_count);
        errdefer allocator.free(cont_queues);
        var cont_init: usize = 0;
        errdefer for (cont_queues[0..cont_init]) |*q| q.deinit(allocator);
        for (cont_queues) |*q| {
            q.* = try ContQueue.init(allocator, cont_queue_capacity);
            cont_init += 1;
        }

        const ready_queues = try allocator.alloc(ReadyQueue, safe_worker_count);
        errdefer allocator.free(ready_queues);
        for (ready_queues) |*r| r.* = ReadyQueue.init();

        const helper_thread_count: u8 = if (safe_worker_count > 1) safe_worker_count - 1 else 0;
        const threads = try allocator.alloc(std.Thread, helper_thread_count);
        errdefer allocator.free(threads);

        const wake_words = try allocator.alloc(WakeWord, safe_worker_count);
        errdefer allocator.free(wake_words);
        for (wake_words) |*w| w.* = .{};

        const worker_counters = try allocator.alloc(Counters, safe_worker_count);
        errdefer allocator.free(worker_counters);
        for (worker_counters) |*c| c.* = .{};

        const gc_worker_parked = if (gc.enabled) blk: {
            const ws = try allocator.alloc(std.atomic.Value(bool), safe_worker_count);
            for (ws) |*w| w.* = .init(false);
            break :blk ws;
        } else {};
        errdefer if (gc.enabled) allocator.free(gc_worker_parked);

        return .{
            .allocator = allocator,
            .worker_count = safe_worker_count,
            .urgent_queues = urgent_queues,
            .spec_queues = spec_queues,
            .novel_queues = novel_queues,
            .cont_queues = cont_queues,
            .ready_queues = ready_queues,
            .threads = threads,
            .wake_words = wake_words,
            .shutdown_flag = .init(false),
            .next_victim = .init(0),
            .next_fiber_id = .init(0),
            .started = .init(false),
            .pending_tasks = .init(0),
            .spinners = .init(0),
            .cont_pending = .init(0),
            .ready_pending = .init(0),
            .urgent_pending = .init(0),
            .novel_mask = .init(0),
            .spec_mask = .init(0),
            .worker_counters = worker_counters,
            .n_max_fiber_stack = .init(0),
            .n_max_vm_sp = .init(0),
            .n_idle_ns = .init(0),
            .n_busy_ns = .init(0),
            .disable_speculation = false,
            .disable_fanout = false,
            .work_first = false,
            .suppress_background = .init(false),
            .gc_stop_requested = if (gc.enabled) .init(false) else {},
            .gc_worker_parked = gc_worker_parked,
            .gc_mark_open = if (gc.enabled) .init(false) else {},
            .gc_mark_hook = if (gc.enabled) null else {},
        };
    }

    /// Toggle whether workers may start new background tasks. Set true
    /// once a demanded result is ready (see `suppress_background`); reset
    /// to false at the start of each top-level entry.
    pub inline fn setSuppressBackground(self: *Scheduler, v: bool) void {
        self.suppress_background.store(v, .release);
    }

    pub inline fn backgroundSuppressed(self: *const Scheduler) bool {
        return self.suppress_background.load(.acquire);
    }

    /// Allocate a fresh globally-unique fiber id. Called from
    /// `Worker.allocateFiber` so claimer identity doesn't depend on
    /// the worker that happened to create the fiber.
    pub fn allocFiberId(self: *Scheduler) u32 {
        return self.next_fiber_id.v.fetchAdd(1, .monotonic);
    }

    pub fn stats(self: *const Scheduler) Stats {
        // Sum the per-worker slots. Called at report time, after the
        // eval has quiesced, so plain loads are fine.
        var c: Counters = .{};
        for (self.worker_counters) |w| {
            c.spec_ok += w.spec_ok;
            c.spec_rej += w.spec_rej;
            c.urgent_ok += w.urgent_ok;
            c.urgent_rej += w.urgent_rej;
            c.pops += w.pops;
            c.steals += w.steals;
            c.cont_steals += w.cont_steals;
            c.cont_pushes += w.cont_pushes;
            c.parks += w.parks;
            c.scavenges += w.scavenges;
            c.sweeps += w.sweeps;
            c.evicts += w.evicts;
            c.novel_ok += w.novel_ok;
            c.spec_bails += w.spec_bails;
        }
        return .{
            .speculative_submitted = c.spec_ok,
            .speculative_rejected = c.spec_rej,
            .urgent_submitted = c.urgent_ok,
            .urgent_rejected = c.urgent_rej,
            .pops = c.pops,
            .steals = c.steals,
            .cont_steals = c.cont_steals,
            .cont_pushes = c.cont_pushes,
            .parks = c.parks,
            .scavenges = c.scavenges,
            .sweeps = c.sweeps,
            .evicts = c.evicts,
            .novel_ok = c.novel_ok,
            .spec_bails = c.spec_bails,
            .max_fiber_stack_used_bytes = self.n_max_fiber_stack.load(.monotonic),
            .max_vm_sp = self.n_max_vm_sp.load(.monotonic),
            .idle_ns = self.n_idle_ns.load(.monotonic),
            .busy_ns = self.n_busy_ns.load(.monotonic),
        };
    }

    /// Worker shutdown reports the deepest fiber stack and VM sp it
    /// observed. We monotonically max into the scheduler counters so
    /// `fix inspect` can show the high-water across the whole eval.
    pub fn reportFiberHighWater(self: *Scheduler, max_fiber_stack: u64, max_vm_sp: u64) void {
        atomicMax(&self.n_max_fiber_stack, max_fiber_stack);
        atomicMax(&self.n_max_vm_sp, max_vm_sp);
    }

    /// Worker shutdown reports its accumulated idle (parked) and busy
    /// (fiber-resume) nanoseconds. Summed across all workers so the
    /// scheduler stats expose total CPU-time spent each way.
    pub fn reportWorkerTiming(self: *Scheduler, idle_ns: u64, busy_ns: u64) void {
        _ = self.n_idle_ns.fetchAdd(idle_ns, .monotonic);
        _ = self.n_busy_ns.fetchAdd(busy_ns, .monotonic);
    }

    fn atomicMax(slot: *std.atomic.Value(u64), value: u64) void {
        while (true) {
            const current = slot.load(.monotonic);
            if (value <= current) return;
            if (slot.cmpxchgWeak(current, value, .monotonic, .monotonic) == null) return;
        }
    }

    /// GC (`-Dgc`): mark all objects referenced by pending tasks across
    /// every worker's urgent + spec queues. Roots for the collector — a
    /// queued task will still be forced. STW-only.
    pub fn gcMarkPendingTasks(self: *const Scheduler, tr: *gc.Tracer, heap: *const heap_mod.ObjectHeap) void {
        if (comptime !gc.enabled) return;
        for (self.urgent_queues) |*q| taskQueueGcMark(q, tr, heap);
        for (self.spec_queues) |*q| specQueueGcMark(q, tr, heap);
        for (self.novel_queues) |*q| specQueueGcMark(q, tr, heap);
        // Work-first continuations reference a live collection each; mark it
        // (the range's items are reachable through the list/attrs). STW-only.
        for (self.cont_queues) |*q| {
            const t = q.top.v.load(.monotonic);
            const b = q.bottom.v.load(.monotonic);
            var i = t;
            while (i != b) : (i +%= 1) tr.markObject(heap, q.items[@intCast(i & q.mask)].id);
        }
    }

    pub fn deinit(self: *Scheduler) void {
        self.shutdown();
        self.allocator.free(self.wake_words);
        for (self.urgent_queues) |*q| q.deinit(self.allocator);
        self.allocator.free(self.urgent_queues);
        for (self.spec_queues) |*q| q.deinit(self.allocator);
        self.allocator.free(self.spec_queues);
        for (self.novel_queues) |*q| q.deinit(self.allocator);
        self.allocator.free(self.novel_queues);
        for (self.cont_queues) |*q| q.deinit(self.allocator);
        self.allocator.free(self.cont_queues);
        self.allocator.free(self.ready_queues);
        self.allocator.free(self.threads);
        self.allocator.free(self.worker_counters);
        if (comptime gc.enabled) self.allocator.free(self.gc_worker_parked);
    }

    /// Push a woken fiber's ReadyNode onto the target worker's
    /// ready queue and nudge it. A no-op if the node is already
    /// queued — the CAS lets multiple racing wakers / runner tails
    /// safely call this for the same fiber; only the first push
    /// takes effect, the rest are dropped.
    pub fn enqueueReady(self: *Scheduler, target_worker_id: u8, node: *ReadyNode) void {
        if (node.queued.cmpxchgStrong(0, 1, .acq_rel, .monotonic) != null) {
            return;
        }
        self.ready_queues[target_worker_id].push(node);
        _ = self.ready_pending.v.fetchAdd(1, .release);
        self.wakeWorker(target_worker_id);
    }

    /// Pop from the given worker's own ready queue.
    pub fn popReady(self: *Scheduler, worker_id: u8) ?*ReadyNode {
        const t0 = rdtscScan();
        const n = self.ready_queues[worker_id].pop();
        scanEnd("ready_pop", t0, n != null);
        if (n != null) _ = self.ready_pending.v.fetchSub(1, .monotonic);
        return n;
    }

    /// Try to steal a ready fiber from any other worker's queue. Used
    /// when the caller's own ready + task queues are empty so a fiber
    /// woken on a busy worker still gets resumed promptly.
    pub fn stealReady(self: *Scheduler, my_worker_id: u8) ?*ReadyNode {
        if (self.worker_count < 2) return null;
        // Stealable-work summary: no woken fiber is sitting anywhere —
        // skip the O(N) per-peer queue walk (see `ready_pending`).
        if (self.ready_pending.v.load(.monotonic) == 0) return null;
        const t0 = rdtscScan();
        const start_idx: u8 = @intCast(self.next_victim.v.fetchAdd(1, .monotonic) % self.worker_count);
        var i: u8 = 0;
        while (i < self.worker_count) : (i += 1) {
            const idx = (start_idx + i) % self.worker_count;
            if (idx == my_worker_id) continue;
            if (self.ready_queues[idx].pop()) |n| {
                _ = self.ready_pending.v.fetchSub(1, .monotonic);
                scanEnd("ready_steal", t0, true);
                return n;
            }
        }
        scanEnd("ready_steal", t0, false);
        return null;
    }

    /// Spawn helper threads. Each runs `workerFn(worker_id, sched, ctx)`
    /// where worker_id ∈ 1..worker_count-1. Worker 0 runs on the
    /// calling thread and is not spawned here.
    /// Idempotent: subsequent calls return immediately.
    pub fn start(self: *Scheduler, comptime workerFn: anytype, ctx: anytype) !void {
        if (self.started.cmpxchgStrong(false, true, .acq_rel, .monotonic) != null) return;
        if (self.threads.len == 0) return;

        var spawned: usize = 0;
        errdefer {
            self.shutdown_flag.store(true, .release);
            var i: usize = 0;
            while (i < spawned) : (i += 1) self.wakeWorker(@intCast(i + 1));
            for (self.threads[0..spawned]) |t| t.join();
            self.started.store(false, .release);
        }

        const Worker = struct {
            fn run(worker_id: u8, sched: *Scheduler, c: @TypeOf(ctx)) void {
                workerFn(worker_id, sched, c);
            }
        };

        for (self.threads, 0..) |*t, i| {
            t.* = try std.Thread.spawn(.{}, Worker.run, .{
                @as(u8, @intCast(i + 1)),
                self,
                ctx,
            });
            spawned += 1;
        }
    }

    /// Quiescence barrier for shutdown: each helper calls this AFTER its
    /// `run` loop exits and BEFORE it destroys its fibers, so all forcing
    /// has stopped before any fiber is freed. Without it, a helper could
    /// `Worker.deinit` (free) a still-enrolled speculative fiber while
    /// another helper, finishing its last quantum, resolves that fiber's
    /// thunk and wakes the freed fiber → use-after-free. Once every helper
    /// is past this point, no `wakeFiberWaiters` can run, so the orphaned
    /// dangling waiters are never walked.
    pub fn awaitHelpersQuiescent(self: *Scheduler) void {
        if (comptime scan_census_on) scanFlush();
        const helpers: u32 = self.worker_count - 1;
        if (helpers == 0) return;
        _ = self.stopped_helpers.fetchAdd(1, .acq_rel);
        while (self.stopped_helpers.load(.acquire) < helpers) std.atomic.spinLoopHint();
    }

    /// Signal helpers to exit and wait for them. Idempotent.
    pub fn shutdown(self: *Scheduler) void {
        if (!self.started.swap(false, .acq_rel)) return;
        // Tell any in-flight speculative force to bail at its next
        // checkpoint instead of running a possibly-huge body to completion
        // — otherwise shutdown blocks on a helper finishing dead work the
        // result never needed (see force.zig SpeculativeBail).
        self.setSuppressBackground(true);
        self.shutdown_flag.store(true, .release);
        var i: u8 = 1;
        while (i < self.worker_count) : (i += 1) self.wakeWorker(i);
        for (self.threads) |t| t.join();
    }

    /// Enable push-time stamping for the work-stealing flow arrows. Called
    /// once at startup when `--timeline` is active.
    pub fn setTraceFlows(self: *Scheduler, on: bool) void {
        self.trace_flows = on;
    }

    /// Enable/disable the work-first collection-force path. Set once before
    /// helpers start (from `FIX_WORK_FIRST`); read-only during eval.
    pub fn setWorkFirst(self: *Scheduler, v: bool) void {
        self.work_first = v;
    }
    pub inline fn workFirst(self: *const Scheduler) bool {
        return self.work_first;
    }

    /// Enable/configure the idle-helper thunk scavenger. Set once before
    /// helpers start (from `FIX_SCAVENGE` / `FIX_SCAV_MARGIN`).
    pub fn setScavenge(self: *Scheduler, on: bool, margin: u64) void {
        self.scavenge_enabled = on;
        self.scav_margin = margin;
    }
    pub inline fn scavengeEnabled(self: *const Scheduler) bool {
        return self.scavenge_enabled;
    }
    pub inline fn bumpScavenges(self: *Scheduler, id: u8) void {
        self.bump(id, "scavenges");
    }

    /// Enable/configure demand-sibling prefetch. Set once before helpers
    /// start (from `FIX_SIBLING` / `FIX_SIBLING_MIN` / `FIX_SIBLING_MAX`).
    pub fn setSiblingPrefetch(self: *Scheduler, on: bool, min: u32, max: u32) void {
        self.sibling_prefetch = on;
        self.sibling_min = min;
        self.sibling_max = max;
    }
    pub inline fn bumpSweeps(self: *Scheduler, id: u8) void {
        self.bump(id, "sweeps");
    }

    /// Enable/configure readDir-children prefetch. Set once before helpers
    /// start (from `FIX_READDIR_PREFETCH` / `_MIN` / `_MAX`). min = 0
    /// disables.
    pub fn setReadDirPrefetch(self: *Scheduler, min: u32, budget: u32) void {
        self.readdir_prefetch_min = min;
        self.readdir_prefetch_budget.v.store(budget, .monotonic);
    }

    /// Claim up to `want` child listings from the readDir-prefetch budget.
    /// Returns the granted count (0 when exhausted or disabled).
    pub fn readDirPrefetchTake(self: *Scheduler, want: u32) u32 {
        var cur = self.readdir_prefetch_budget.v.load(.monotonic);
        while (true) {
            if (cur == 0) return 0;
            const grant = @min(cur, want);
            cur = self.readdir_prefetch_budget.v.cmpxchgWeak(cur, cur - grant, .monotonic, .monotonic) orelse return grant;
        }
    }

    /// Push a work-first continuation onto `worker_id`'s own continuation deque
    /// (owner-only). Returns false when full — the caller then forces the range
    /// inline. Bumps `cont_pending` and, at the start of a burst, wakes one
    /// worker so a parked helper picks up continuation work even without other
    /// traffic (bounded, like `pushOwn`).
    pub fn pushCont(self: *Scheduler, worker_id: u8, cont: Continuation) bool {
        if (worker_id >= self.worker_count) return false;
        if (!self.cont_queues[worker_id].push(cont)) return false;
        self.bump(worker_id, "cont_pushes");
        const prev = self.cont_pending.v.fetchAdd(1, .release);
        if (self.worker_count > 1) {
            const wake_budget = @min(@as(u32, self.worker_count - 1), burst_wake_budget);
            if (prev < wake_budget) {
                const wake_idx: u8 = @intCast(self.next_victim.v.fetchAdd(1, .monotonic) % self.worker_count);
                const target = if (wake_idx == worker_id) (wake_idx + 1) % self.worker_count else wake_idx;
                self.wakeWorker(target);
            }
        }
        return true;
    }

    /// Pop the newest continuation from `worker_id`'s own deque (LIFO), or null
    /// if empty (all were stolen / never pushed).
    pub fn popCont(self: *Scheduler, worker_id: u8) ?Continuation {
        if (worker_id >= self.worker_count) return null;
        const c = self.cont_queues[worker_id].pop() orelse return null;
        _ = self.cont_pending.v.fetchSub(1, .monotonic);
        return c;
    }

    /// Steal one continuation from another worker's deque (FIFO — takes the
    /// oldest/biggest exposed range for best load balancing), excluding the
    /// caller's own. Null if none available.
    pub fn stealCont(self: *Scheduler, worker_id: u8) ?Continuation {
        if (self.worker_count < 2) return null;
        // Stealable-work summary: `cont_pending` (already maintained for
        // the pre-park spin) now also short-circuits the scan itself —
        // with `work_first` off it is permanently zero, yet the walk was
        // ~8% of all idle-scan cycles at w=32.
        if (self.cont_pending.v.load(.monotonic) == 0) return null;
        const t0 = rdtscScan();
        const start_idx: u8 = @intCast(self.next_victim.v.fetchAdd(1, .monotonic) % self.worker_count);
        var i: u8 = 0;
        while (i < self.worker_count) : (i += 1) {
            const idx = (start_idx + i) % self.worker_count;
            if (idx == worker_id) continue;
            if (self.cont_queues[idx].steal()) |c| {
                _ = self.cont_pending.v.fetchSub(1, .monotonic);
                self.bump(worker_id, "cont_steals");
                scanEnd("cont_steal", t0, true);
                return c;
            }
        }
        scanEnd("cont_steal", t0, false);
        return null;
    }

    /// Pre-park spin probe: is there stealable continuation work outstanding?
    pub inline fn contPending(self: *const Scheduler) u32 {
        return self.cont_pending.v.load(.monotonic);
    }

    /// Try to become one of the `max_spinners` idle spinners. Returns
    /// false when the quota is taken — the caller should park directly
    /// instead of spin-rescanning.
    pub fn tryBeginSpin(self: *Scheduler) bool {
        const cap = maxSpinners(self.worker_count);
        var cur = self.spinners.v.load(.monotonic);
        while (cur < cap) {
            if (self.spinners.v.cmpxchgWeak(cur, cur + 1, .acquire, .monotonic)) |actual| {
                cur = actual;
            } else return true;
        }
        return false;
    }

    pub fn endSpin(self: *Scheduler) void {
        _ = self.spinners.v.fetchSub(1, .release);
    }

    /// Submit a *speculative* task. With Chase-Lev work-stealing the
    /// submitter pushes onto its own queue: lock-free SPMC `push` is
    /// the hot path. Idle helpers will steal when their own queue is
    /// empty. The previous "push to a peer" model required a MPMC
    /// mutex on the hot path; this trades that for a steal
    /// round-trip on the cold path, which has been hidden by spin-
    /// before-park (project-tier1-perf-session).
    pub fn submit(self: *Scheduler, task: Task, submitter_id: u8) bool {
        if (self.worker_count <= 1) return false;
        if (self.disable_speculation) return false;
        if (submitter_id >= self.worker_count) return false;
        const cap: u32 = @as(u32, self.worker_count - 1) * spec_backlog_per_helper;
        if (self.pending_tasks.v.load(.monotonic) >= cap) {
            // At the cap: with `FIX_SPEC_EVICT`, make room by dropping the
            // oldest queued spec task (ring semantics — see `spec_evict`);
            // otherwise reject the fresh submission (historical behavior).
            if (!self.evictOldestSpec(submitter_id)) {
                self.bump(submitter_id, "spec_rej");
                return false;
            }
        }
        const push_ts: u64 = if (self.trace_flows) monotonicNs() else 0;
        const prev: u32 = switch (self.spec_queues[submitter_id].push(
            .{ .task = task, .push_ts = push_ts },
            self.spec_evict,
            &self.spec_mask.v,
        )) {
            .full => {
                self.bump(submitter_id, "spec_rej");
                return false;
            },
            .pushed => self.pending_tasks.v.fetchAdd(1, .release),
            // Ring overwrite inside our own queue: one task dropped, one
            // added — pending count is unchanged.
            .pushed_evicted => blk: {
                self.bump(submitter_id, "evicts");
                break :blk self.pending_tasks.v.load(.monotonic);
            },
        };
        // Same burst-ramp + periodic re-wake as `pushOwn` (see there).
        const wake_budget = @min(@as(u32, self.worker_count - 1), burst_wake_budget);
        if (prev < wake_budget or (prev & 63) == 0) {
            const wake_idx: u8 = @intCast(self.next_victim.v.fetchAdd(1, .monotonic) % self.worker_count);
            const target = if (wake_idx == submitter_id) (wake_idx + 1) % self.worker_count else wake_idx;
            self.wakeWorker(target);
        }
        self.bump(submitter_id, "spec_ok");
        return true;
    }

    /// Submit a NOVEL-chunk speculative task (`FIX_SPEC_NOVEL`) — the
    /// first-ever creation-time speculation of its chunk. Bypasses the
    /// bulk backlog cap (total volume is bounded at one per chunk) and
    /// lands on the high-priority novel ring, which always ring-overwrites
    /// on full and is consumed newest-first by owner and stealers alike.
    pub fn submitNovel(self: *Scheduler, task: Task, submitter_id: u8) bool {
        if (self.worker_count <= 1) return false;
        if (self.disable_speculation) return false;
        if (submitter_id >= self.worker_count) return false;
        const push_ts: u64 = if (self.trace_flows) monotonicNs() else 0;
        const prev: u32 = switch (self.novel_queues[submitter_id].push(
            .{ .task = task, .push_ts = push_ts },
            true,
            &self.novel_mask.v,
        )) {
            .full => unreachable, // evicting push never reports full
            .pushed => self.pending_tasks.v.fetchAdd(1, .release),
            .pushed_evicted => blk: {
                self.bump(submitter_id, "evicts");
                break :blk self.pending_tasks.v.load(.monotonic);
            },
        };
        const wake_budget = @min(@as(u32, self.worker_count - 1), burst_wake_budget);
        if (prev < wake_budget or (prev & 63) == 0) {
            const wake_idx: u8 = @intCast(self.next_victim.v.fetchAdd(1, .monotonic) % self.worker_count);
            const target = if (wake_idx == submitter_id) (wake_idx + 1) % self.worker_count else wake_idx;
            self.wakeWorker(target);
        }
        self.bump(submitter_id, "novel_ok");
        return true;
    }

    /// Ring-overwrite the speculation backlog (`FIX_SPEC_EVICT`): drop the
    /// OLDEST queued spec task — the submitter's own queue first (usually
    /// where its backlog lives, and the cheapest probe), then any peer's —
    /// so a fresh submission can take its place. Returns false when
    /// eviction is off or every spec queue is empty (the standing
    /// `pending_tasks` are all urgent — never evict demand work for
    /// speculation).
    fn evictOldestSpec(self: *Scheduler, submitter_id: u8) bool {
        if (!self.spec_evict) return false;
        if (self.spec_queues[submitter_id].evictOldest(&self.spec_mask.v)) {
            _ = self.pending_tasks.v.fetchSub(1, .monotonic);
            self.bump(submitter_id, "evicts");
            return true;
        }
        const start_idx: u8 = @intCast(self.next_victim.v.fetchAdd(1, .monotonic) % self.worker_count);
        var i: u8 = 0;
        while (i < self.worker_count) : (i += 1) {
            const idx = (start_idx + i) % self.worker_count;
            if (idx == submitter_id) continue;
            if (self.spec_queues[idx].evictOldest(&self.spec_mask.v)) {
                _ = self.pending_tasks.v.fetchSub(1, .monotonic);
                self.bump(submitter_id, "evicts");
                return true;
            }
        }
        return false;
    }

    /// Submit a *demand-driven* task. Goes to the urgent queue —
    /// drained before any speculative backlog so fan-out work
    /// bypasses queued speculation.
    pub fn submitUrgent(self: *Scheduler, task: Task, submitter_id: u8) bool {
        if (self.worker_count <= 1) return false;
        if (self.disable_fanout) return false;
        if (self.pushOwn(self.urgent_queues, task, submitter_id)) {
            self.bump(submitter_id, "urgent_ok");
            return true;
        }
        self.bump(submitter_id, "urgent_rej");
        return false;
    }

    fn pushOwn(self: *Scheduler, queues: []TaskQueue, task: Task, submitter_id: u8) bool {
        // Chase-Lev `push` is owner-only — submitter must own its
        // queue. Helpers always set their threadlocal worker_id;
        // non-worker callers (none today) would need their own
        // submission path.
        if (submitter_id >= self.worker_count) return false;
        // Stamp the push time only when tracing flows — the timeline anchors
        // the steal arrow's producer end here (the creating quantum). Submits
        // always happen inside a fiber quantum, so this ts falls within the
        // submitter's open span and the arrow binds cleanly.
        const push_ts: u64 = if (self.trace_flows) monotonicNs() else 0;
        if (!queues[submitter_id].push(.{ .task = task, .push_ts = push_ts })) return false;
        _ = self.urgent_pending.v.fetchAdd(1, .release);
        // Ramp worker wakeups at the start of a burst. A single submit
        // only needs one wake, but fanout submits dozens or thousands of
        // tasks back-to-back; waking only on 0 -> 1 leaves the burst at
        // the mercy of whichever helpers happened to be awake already.
        //
        // Bound this so steady backlog does not turn every submit into
        // a futex wake. These wake words also pre-signal workers that
        // are between the pre-park spin and the futex call.
        const prev = self.pending_tasks.v.fetchAdd(1, .release);
        const wake_budget = @min(@as(u32, self.worker_count - 1), burst_wake_budget);
        // Burst ramp (prev < budget) plus a periodic re-wake under steady
        // backlog: once prev >= budget the ramp alone never wakes anyone,
        // so a helper whose pre-park spin expired during a lull would stay
        // parked for the rest of the eval no matter how much stealable
        // work piles up (measured: helper utilization FALLS as workers
        // rise). Every 64th submit into a standing backlog re-nudges one
        // worker — bounded futex traffic, keeps parked helpers engaged.
        if (prev < wake_budget or (prev & 63) == 0) {
            const wake_idx: u8 = @intCast(self.next_victim.v.fetchAdd(1, .monotonic) % self.worker_count);
            const target = if (wake_idx == submitter_id) (wake_idx + 1) % self.worker_count else wake_idx;
            self.wakeWorker(target);
        }
        return true;
    }

    /// Pop a task from `worker_id`'s own queues — urgent first, then
    /// speculative. Every worker — main and helpers — owns both
    /// queues post-F1.
    pub fn pop(self: *Scheduler, worker_id: u8) ?Task {
        return self.popLane(worker_id, null);
    }

    /// `pop`, additionally reporting which lane the task came from (for
    /// the `-Dprof-main` task census). `lane` may be null.
    pub fn popLane(self: *Scheduler, worker_id: u8, lane: ?*Lane) ?Task {
        if (worker_id >= self.worker_count) return null;
        const t0 = rdtscScan();
        const traced: TracedTask = blk: {
            if (self.urgent_queues[worker_id].pop()) |t| {
                _ = self.urgent_pending.v.fetchSub(1, .monotonic);
                if (lane) |l| l.* = .urgent;
                break :blk t;
            }
            // Lane masks also spare the OWN-pop mutex locks: the novel
            // ring is empty for almost the entire eval (and permanently at
            // w>16, where the lane is gated off), and stealers hammering
            // an owner's ring line made even an empty-own-ring lock a
            // cache miss. Own-bit test is exact (maintained under the
            // ring's mutex) modulo a racing steal, which the pop re-checks.
            const own_bit: u64 = if (worker_id < 64) @as(u64, 1) << @intCast(worker_id) else 0;
            if (worker_id >= 64 or self.novel_mask.v.load(.monotonic) & own_bit != 0) {
                if (self.novel_queues[worker_id].popNewest(&self.novel_mask.v)) |t| {
                    if (lane) |l| l.* = .novel;
                    break :blk t;
                }
            }
            if (worker_id <= self.spec_helper_cap and
                (worker_id >= 64 or self.spec_mask.v.load(.monotonic) & own_bit != 0))
            {
                if (self.spec_queues[worker_id].popNewest(&self.spec_mask.v)) |t| {
                    if (lane) |l| l.* = .spec;
                    break :blk t;
                }
            }
            scanEnd("pop_own", t0, false);
            return null;
        };
        scanEnd("pop_own", t0, true);
        _ = self.pending_tasks.v.fetchSub(1, .monotonic);
        self.bump(worker_id, "pops");
        return traced.task;
    }

    /// Try to steal one task from any worker's queues, urgent first
    /// then speculative, excluding the caller's own (`worker_id`).
    pub fn stealForWorker(self: *Scheduler, worker_id: u8) ?Task {
        return self.stealAnyVictimOpt(worker_id, null, null, null);
    }

    /// Alias for `stealForWorker` — workers use this from their drain
    /// loop. Kept as a separate name so the call site reads as
    /// "steal anything I can find," not "steal for some specific id."
    pub fn stealAny(self: *Scheduler, worker_id: u8) ?Task {
        return self.stealForWorker(worker_id);
    }

    /// Like `stealForWorker`, but reports the victim worker id and the stolen
    /// task's push timestamp so a timeline-capable caller can draw the work-
    /// stealing flow arrow anchored to the producing quantum. The scheduler
    /// stays free of the probe layer (it returns data, not events).
    pub fn stealAnyVictim(self: *Scheduler, worker_id: u8, victim: *u8, push_ts: *u64) ?Task {
        return self.stealAnyVictimOpt(worker_id, victim, push_ts, null);
    }

    /// `stealAnyVictim`, additionally reporting the lane (task census).
    pub fn stealAnyVictimLane(self: *Scheduler, worker_id: u8, victim: *u8, push_ts: *u64, lane: ?*Lane) ?Task {
        return self.stealAnyVictimOpt(worker_id, victim, push_ts, lane);
    }

    fn stealAnyVictimOpt(self: *Scheduler, worker_id: u8, victim: ?*u8, push_ts: ?*u64, lane: ?*Lane) ?Task {
        if (self.worker_count < 2) return null;
        // Per-lane stealable-work summaries: one load per class replaces
        // the O(N) per-peer probe walk when the class has nothing queued
        // (the dominant case for every class but spec — see scan census).
        if (self.urgent_pending.v.load(.monotonic) != 0) {
            const t0 = rdtscScan();
            if (self.stealExcluding(self.urgent_queues, worker_id, victim, push_ts)) |t| {
                _ = self.urgent_pending.v.fetchSub(1, .monotonic);
                scanEnd("urgent_steal", t0, true);
                if (lane) |l| l.* = .urgent;
                return t;
            }
            scanEnd("urgent_steal", t0, false);
        }
        // Novel lane before the bulk backlog; always newest-first.
        if (self.novel_mask.v.load(.monotonic) != 0 or self.worker_count > 64) {
            const t1 = rdtscScan();
            if (self.stealSpecExcluding(self.novel_queues, &self.novel_mask.v, worker_id, true, victim, push_ts)) |t| {
                scanEnd("novel_steal", t1, true);
                if (lane) |l| l.* = .novel;
                return t;
            }
            scanEnd("novel_steal", t1, false);
        }
        if (worker_id <= self.spec_helper_cap and
            (self.spec_mask.v.load(.monotonic) != 0 or self.worker_count > 64))
        {
            const t2 = rdtscScan();
            if (self.stealSpecExcluding(self.spec_queues, &self.spec_mask.v, worker_id, self.spec_lifo, victim, push_ts)) |t| {
                scanEnd("spec_steal", t2, true);
                if (lane) |l| l.* = .spec;
                return t;
            }
            scanEnd("spec_steal", t2, false);
        }
        return null;
    }

    /// Lane-aware pre-park spin probe: is there any work THIS worker is
    /// allowed to take? For workers within the bulk-spec cap this is the
    /// historical single `pending_tasks` load; workers past the cap must
    /// not busy-spin on a bulk backlog they cannot drain, so they probe
    /// the urgent counter, the novel mask, and the cont counter instead.
    pub inline fn takableWork(self: *const Scheduler, worker_id: u8) bool {
        if (worker_id <= self.spec_helper_cap)
            return self.pending_tasks.v.load(.monotonic) > 0 or self.contPending() > 0;
        return self.urgent_pending.v.load(.monotonic) != 0 or
            self.novel_mask.v.load(.monotonic) != 0 or
            self.contPending() > 0;
    }

    /// Spec-lane steal: newest-first when `lifo` (demand-head-adjacent
    /// bets), oldest-first otherwise. Victim-mask-guided: walks only the
    /// rings whose non-empty bit is set (one mask load instead of locking
    /// every peer's ring), rotating the start the same way the full walk
    /// did. Rings past bit 63 (worker_count > 64) get the historical full
    /// walk as a tail.
    fn stealSpecExcluding(self: *Scheduler, queues: []SpecQueue, lane_mask: *std.atomic.Value(u64), exclude: u8, lifo: bool, victim: ?*u8, push_ts: ?*u64) ?Task {
        const start_idx: u8 = @intCast(self.next_victim.v.fetchAdd(1, .monotonic) % self.worker_count);
        var m: u64 = lane_mask.load(.monotonic);
        if (exclude < 64) m &= ~(@as(u64, 1) << @intCast(exclude));
        while (m != 0) {
            // Next set bit at or past the rotated start, wrapping.
            const hi = m & (~@as(u64, 0) << @intCast(@min(start_idx, 63)));
            const idx: u8 = @intCast(@ctz(if (hi != 0) hi else m));
            m &= ~(@as(u64, 1) << @intCast(idx));
            if (queues[idx].steal(lifo, lane_mask)) |traced| {
                _ = self.pending_tasks.v.fetchSub(1, .monotonic);
                self.bump(exclude, "steals");
                if (victim) |v| v.* = idx;
                if (push_ts) |p| p.* = traced.push_ts;
                return traced.task;
            }
        }
        // Rings without a mask bit (only when worker_count > 64).
        if (self.worker_count > 64) {
            var i: u8 = 64;
            while (i < self.worker_count) : (i += 1) {
                if (i == exclude) continue;
                if (queues[i].steal(lifo, lane_mask)) |traced| {
                    _ = self.pending_tasks.v.fetchSub(1, .monotonic);
                    self.bump(exclude, "steals");
                    if (victim) |v| v.* = i;
                    if (push_ts) |p| p.* = traced.push_ts;
                    return traced.task;
                }
            }
        }
        return null;
    }

    fn stealExcluding(self: *Scheduler, queues: []TaskQueue, exclude: u8, victim: ?*u8, push_ts: ?*u64) ?Task {
        const start_idx: u8 = @intCast(self.next_victim.v.fetchAdd(1, .monotonic) % self.worker_count);
        var i: u8 = 0;
        while (i < self.worker_count) : (i += 1) {
            const idx = (start_idx + i) % self.worker_count;
            if (idx == exclude) continue;
            if (queues[idx].steal()) |traced| {
                _ = self.pending_tasks.v.fetchSub(1, .monotonic);
                self.bump(exclude, "steals");
                if (victim) |v| v.* = idx;
                if (push_ts) |p| p.* = traced.push_ts;
                return traced.task;
            }
        }
        return null;
    }

    /// Park `worker_id`'s thread on its wake word until awoken or
    /// shutdown. Works for any worker, including worker 0.
    pub fn parkWorker(self: *Scheduler, worker_id: u8) void {
        if (comptime scan_census_on) scanFlush();
        self.bump(worker_id, "parks");
        const word = &self.wake_words[worker_id].word;
        // Try to atomically transition 0 → "waiting" (still 0; we just check
        // before sleeping). The futex syscall's "expected" param is the safe
        // way to avoid lost wakeups: if a wake arrives between our check and
        // the syscall, the syscall returns immediately.
        if (word.load(.acquire) != 0) {
            word.store(0, .release);
            return;
        }
        if (self.shutdown_flag.load(.acquire)) return;
        switch (builtin.os.tag) {
            .linux => {
                _ = std.os.linux.futex_4arg(
                    @ptrCast(word),
                    .{ .cmd = .WAIT, .private = true },
                    0,
                    null,
                );
            },
            else => {
                std.atomic.spinLoopHint();
                std.Thread.yield() catch {};
            },
        }
        // Drain any wake signal that arrived.
        word.store(0, .release);
    }

    pub fn isShutdown(self: *const Scheduler) bool {
        return self.shutdown_flag.load(.acquire);
    }

    /// Wake the given worker's wake_word and futex_wake it. Public so
    /// remote thunk-resolvers (in worker.zig's wake_fn) can nudge a
    /// worker whose suspended fiber just became resumable.
    pub fn wakeWorkerPublic(self: *Scheduler, worker_id: u8) void {
        self.wakeWorker(worker_id);
    }

    // --- GC stop-the-world barrier (`-Dgc`) ---

    /// Fast check: has a collection been requested? Called at safepoints.
    pub inline fn gcStopRequested(self: *const Scheduler) bool {
        if (comptime !gc.enabled) return false;
        return self.gc_stop_requested.load(.acquire);
    }

    /// Try to become the sole collector for this cycle. Returns true to
    /// exactly one worker (the CAS winner); losers should `gcSafepointPark`.
    pub fn gcTryBeginCollection(self: *Scheduler) bool {
        if (comptime !gc.enabled) return false;
        return self.gc_stop_requested.cmpxchgStrong(false, true, .acq_rel, .monotonic) == null;
    }

    /// Collector (worker `collector_id`): wake every worker so parked ones
    /// loop to a safepoint, then spin until every *peer* has set its parked
    /// flag. On return the caller is the only running mutator — safe to mark
    /// and sweep.
    pub fn gcWaitAllParked(self: *Scheduler, collector_id: u8) void {
        if (comptime !gc.enabled) return;
        var id: u8 = 0;
        while (id < self.worker_count) : (id += 1) self.wakeWorker(id);
        id = 0;
        while (id < self.worker_count) : (id += 1) {
            if (id == collector_id) continue;
            while (!self.gc_worker_parked[id].load(.acquire)) std.atomic.spinLoopHint();
        }
    }

    /// Collector: release the peers, then wait until every peer has observed
    /// the release and cleared its parked flag. The second wait is what makes
    /// this robust across back-to-back collections — no peer can still be
    /// parked (or about to re-park with a stale flag) when the next
    /// collection begins.
    pub fn gcEndCollection(self: *Scheduler, collector_id: u8) void {
        if (comptime !gc.enabled) return;
        self.gc_stop_requested.store(false, .release);
        var id: u8 = 0;
        while (id < self.worker_count) : (id += 1) {
            if (id == collector_id) continue;
            while (self.gc_worker_parked[id].load(.acquire)) std.atomic.spinLoopHint();
        }
    }

    /// Evaluator installs the parallel-mark hook (see `GcMarkHook`) once, at
    /// startup, so parked peers can help drain the mark.
    pub fn gcSetMarkHook(self: *Scheduler, hook: GcMarkHook) void {
        if (comptime !gc.enabled) return;
        self.gc_mark_hook = hook;
    }

    /// Collector: the roots are seeded — release the parked peers to help
    /// mark. Paired with `gcCloseMark` after the mark terminates.
    pub fn gcOpenMark(self: *Scheduler) void {
        if (comptime !gc.enabled) return;
        self.gc_mark_open.store(true, .release);
    }

    /// Collector: the mark has terminated (every marker entered and returned).
    /// Close the phase so the next collection starts from a clean gate — must
    /// happen before `gcEndCollection` releases the peers.
    pub fn gcCloseMark(self: *Scheduler) void {
        if (comptime !gc.enabled) return;
        self.gc_mark_open.store(false, .release);
    }

    /// Peer (worker `worker_id`): park in the barrier until the collector
    /// finishes this cycle. Must be called only at a safepoint (native_depth
    /// 0, no un-rooted in-flight allocation) — the collector scans this
    /// worker's fibers for roots. Once the collector opens the mark, this peer
    /// helps drain the graph (marker slot == `worker_id`) instead of spinning
    /// idle; the mark stays open until termination so no peer can miss it (a
    /// missed marker would hang the work-stealing terminator).
    pub fn gcSafepointPark(self: *Scheduler, worker_id: u8) void {
        if (comptime !gc.enabled) return;
        self.gc_worker_parked[worker_id].store(true, .release);
        if (self.gc_mark_hook) |hook| {
            while (self.gc_stop_requested.load(.acquire) and
                !self.gc_mark_open.load(.acquire)) std.atomic.spinLoopHint();
            if (self.gc_mark_open.load(.acquire)) hook.help(hook.ctx, worker_id);
        }
        while (self.gc_stop_requested.load(.acquire)) std.atomic.spinLoopHint();
        self.gc_worker_parked[worker_id].store(false, .release);
    }

    fn wakeWorker(self: *Scheduler, worker_id: u8) void {
        const word = &self.wake_words[worker_id].word;
        // Already signalled → a prior waker's futex_wake is still in
        // flight for this word; skip the redundant syscall. (If the
        // sleeper consumed the old signal it also cleared the word, so
        // this swap would see 0 and we fall through to the wake.)
        if (word.swap(1, .release) == 1) return;
        switch (builtin.os.tag) {
            .linux => {
                _ = std.os.linux.futex_3arg(
                    @ptrCast(word),
                    .{ .cmd = .WAKE, .private = true },
                    1,
                );
            },
            else => {},
        }
    }

    comptime {
        // Prove the isolation the `Isolated` wrappers intend:
        // each globally write-hot atomic sits alone in its 128B block —
        // no pair shares one, and no other (read-mostly or cold) field
        // lands inside one. Layout is otherwise the compiler's business,
        // so this is what keeps a future field-shuffle honest.
        @setEvalBranchQuota(8000);
        const hot = .{ "next_victim", "next_fiber_id", "pending_tasks", "spinners", "cont_pending", "ready_pending", "urgent_pending", "novel_mask", "spec_mask" };
        const blk = std.atomic.cache_line;
        for (@typeInfo(Scheduler).@"struct".fields) |f| {
            if (@sizeOf(f.type) == 0) continue;
            const lo = @offsetOf(Scheduler, f.name) / blk;
            const hi = (@offsetOf(Scheduler, f.name) + @sizeOf(f.type) - 1) / blk;
            for (hot) |h| {
                if (std.mem.eql(u8, f.name, h)) continue;
                const h_blk = @offsetOf(Scheduler, h) / blk;
                std.debug.assert(lo > h_blk or hi < h_blk);
            }
        }
    }
};

test "scheduler push/pop/steal work for a single worker" {
    var sched = try Scheduler.init(std.testing.allocator, 2);
    defer sched.deinit();
    try std.testing.expectEqual(@as(u8, 2), sched.worker_count);

    const t1: TracedTask = .{ .task = .{ .force_thunk = 7 } };
    const t2: TracedTask = .{ .task = .{ .force_thunk = 13 } };
    // Push directly to worker 1's urgent queue. Direct pushes bypass
    // `pushOwn`, so mirror its lane-summary bookkeeping by hand.
    try std.testing.expect(sched.urgent_queues[1].push(t1));
    try std.testing.expect(sched.urgent_queues[1].push(t2));
    sched.urgent_pending.v.store(2, .release);

    // LIFO from owner.
    const popped = sched.pop(1).?;
    try std.testing.expectEqual(@as(types.ObjectId, 13), popped.force_thunk);

    // Steal sees the older one.
    const stolen = sched.urgent_queues[1].steal().?;
    try std.testing.expectEqual(@as(types.ObjectId, 7), stolen.task.force_thunk);

    try std.testing.expectEqual(@as(?Task, null), sched.pop(1));
}

test "scheduler.submit round-robins across workers" {
    var sched = try Scheduler.init(std.testing.allocator, 4);
    defer sched.deinit();
    try std.testing.expectEqual(@as(u8, 4), sched.worker_count);

    var i: types.ObjectId = 0;
    while (i < 6) : (i += 1) {
        try std.testing.expect(sched.submit(.{ .force_thunk = i }, 0));
    }

    // submit pushes to spec_queues.
    var total: u32 = 0;
    for (sched.spec_queues) |*q| {
        var count: u32 = 0;
        while (q.steal(false, &sched.spec_mask.v)) |_| count += 1;
        total += count;
    }
    try std.testing.expectEqual(@as(u32, 6), total);
}

test "submitUrgent bypasses the speculation backlog cap" {
    var sched = try Scheduler.init(std.testing.allocator, 2);
    defer sched.deinit();
    try std.testing.expectEqual(@as(u8, 2), sched.worker_count);

    // Fill the speculation cap via `submit` and confirm the next
    // speculative task is rejected.
    var i: types.ObjectId = 0;
    while (i < spec_backlog_per_helper) : (i += 1) try std.testing.expect(sched.submit(.{ .force_thunk = i }, 0));
    try std.testing.expect(!sched.submit(.{ .force_thunk = 999 }, 0));

    // `submitUrgent` should still go through — it lives on a separate
    // queue with its own capacity (`urgent_queue_capacity`).
    try std.testing.expect(sched.submitUrgent(.{ .force_thunk = 100 }, 0));
    try std.testing.expect(sched.submitUrgent(.{ .force_thunk = 101 }, 0));

    var drained: u32 = 0;
    for (sched.urgent_queues) |*q| while (q.steal()) |_| { drained += 1; };
    for (sched.spec_queues) |*q| while (q.steal(false, &sched.spec_mask.v)) |_| { drained += 1; };
    // spec_backlog_per_helper (128) speculative tasks + 2 urgent tasks
    // that bypassed the cap. This was 66 (64 + 2) back when the cap was
    // helper_count * 64; when the cap was raised to 128 (commit
    // 7ad94c5, "Raise scheduler burst headroom") the fill loop bound was
    // updated to the new `spec_backlog_per_helper` constant but this
    // expected total was left stale at the old value.
    try std.testing.expectEqual(spec_backlog_per_helper + 2, drained);
}

test "spec ring: LIFO owner pop, FIFO steal, reject when full (knobs off)" {
    var sched = try Scheduler.init(std.testing.allocator, 2);
    defer sched.deinit();

    try std.testing.expect(sched.submit(.{ .force_thunk = 1 }, 0));
    try std.testing.expect(sched.submit(.{ .force_thunk = 2 }, 0));
    try std.testing.expect(sched.submit(.{ .force_thunk = 3 }, 0));

    // Owner pops newest.
    try std.testing.expectEqual(@as(types.ObjectId, 3), sched.pop(0).?.force_thunk);
    // Default steal takes oldest.
    try std.testing.expectEqual(@as(types.ObjectId, 1), sched.spec_queues[0].steal(false, &sched.spec_mask.v).?.task.force_thunk);
    // LIFO steal takes newest.
    try std.testing.expectEqual(@as(types.ObjectId, 2), sched.spec_queues[0].steal(true, &sched.spec_mask.v).?.task.force_thunk);
    try std.testing.expectEqual(@as(?TracedTask, null), sched.spec_queues[0].steal(false, &sched.spec_mask.v));
}

test "spec ring: FIX_SPEC_EVICT admits at the cap by dropping the oldest" {
    var sched = try Scheduler.init(std.testing.allocator, 2);
    defer sched.deinit();
    sched.spec_evict = true;

    // Fill to the backlog cap.
    var i: types.ObjectId = 0;
    while (i < spec_backlog_per_helper) : (i += 1)
        try std.testing.expect(sched.submit(.{ .force_thunk = i }, 0));

    // At the cap the submit must still succeed (ring semantics), dropping
    // the oldest (id 0) and keeping the count at the cap.
    try std.testing.expect(sched.submit(.{ .force_thunk = 999 }, 0));
    try std.testing.expectEqual(spec_backlog_per_helper, sched.pending_tasks.v.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), sched.stats().evicts);

    // The oldest remaining is now id 1; the newest is the fresh 999.
    try std.testing.expectEqual(@as(types.ObjectId, 1), sched.spec_queues[0].steal(false, &sched.spec_mask.v).?.task.force_thunk);
    try std.testing.expectEqual(@as(types.ObjectId, 999), sched.spec_queues[0].steal(true, &sched.spec_mask.v).?.task.force_thunk);
}

test "spec ring: push evict wraps correctly at ring capacity" {
    var sched = try Scheduler.init(std.testing.allocator, 2);
    defer sched.deinit();

    // Drive the RING (not the cap) to full and overwrite: push directly.
    var q = &sched.spec_queues[0];
    var i: types.ObjectId = 0;
    while (i < spec_queue_capacity) : (i += 1)
        try std.testing.expectEqual(SpecQueue.PushResult.pushed, q.push(.{ .task = .{ .force_thunk = i } }, true, &sched.spec_mask.v));
    // Full: non-evicting push rejects, evicting push overwrites the oldest.
    try std.testing.expectEqual(SpecQueue.PushResult.full, q.push(.{ .task = .{ .force_thunk = 7777 } }, false, &sched.spec_mask.v));
    try std.testing.expectEqual(SpecQueue.PushResult.pushed_evicted, q.push(.{ .task = .{ .force_thunk = 8888 } }, true, &sched.spec_mask.v));
    try std.testing.expectEqual(@as(types.ObjectId, 1), q.steal(false, &sched.spec_mask.v).?.task.force_thunk);
    try std.testing.expectEqual(@as(types.ObjectId, 8888), q.steal(true, &sched.spec_mask.v).?.task.force_thunk);
}

test "stealForWorker: each worker excludes its own queue" {
    var sched = try Scheduler.init(std.testing.allocator, 3);
    defer sched.deinit();
    try std.testing.expectEqual(@as(u8, 3), sched.worker_count);

    // Put one task in each of worker 1 and worker 2's urgent queues.
    // (Direct pushes — mirror `pushOwn`'s lane-summary bookkeeping.)
    try std.testing.expect(sched.urgent_queues[1].push(.{ .task = .{ .force_thunk = 100 } }));
    try std.testing.expect(sched.urgent_queues[2].push(.{ .task = .{ .force_thunk = 200 } }));
    sched.pending_tasks.v.store(2, .release);
    sched.urgent_pending.v.store(2, .release);

    // Worker 1 must not steal from its own queue.
    const stolen_by_w1 = sched.stealForWorker(1).?;
    try std.testing.expectEqual(@as(types.ObjectId, 200), stolen_by_w1.force_thunk);

    // Worker 2 must not steal from its own queue.
    const stolen_by_w2 = sched.stealForWorker(2).?;
    try std.testing.expectEqual(@as(types.ObjectId, 100), stolen_by_w2.force_thunk);

    // No more tasks anywhere.
    try std.testing.expectEqual(@as(?Task, null), sched.stealForWorker(0));

    // Worker 0 (main) likewise excludes its own queue but can take
    // from any other.
    try std.testing.expect(sched.urgent_queues[1].push(.{ .task = .{ .force_thunk = 7 } }));
    sched.pending_tasks.v.store(1, .release);
    sched.urgent_pending.v.store(1, .release);
    const stolen_by_main = sched.stealForWorker(0).?;
    try std.testing.expectEqual(@as(types.ObjectId, 7), stolen_by_main.force_thunk);
}

test "scheduler helpers run their loop and shut down cleanly" {
    var sched = try Scheduler.init(std.testing.allocator, 3);
    defer sched.deinit();

    const Ctx = struct {
        // Indexed by worker_id; entry 0 unused since main doesn't run
        // this loop in the test (no caller is driving worker 0).
        observed: [3]std.atomic.Value(u32) = [_]std.atomic.Value(u32){ .init(0), .init(0), .init(0) },
    };
    var ctx: Ctx = .{};

    const Worker = struct {
        fn run(worker_id: u8, s: *Scheduler, c: *Ctx) void {
            while (!s.isShutdown()) {
                const task = s.pop(worker_id) orelse s.stealAny(worker_id) orelse {
                    s.parkWorker(worker_id);
                    continue;
                };
                _ = c.observed[worker_id].fetchAdd(switch (task) {
                    .force_thunk => |id| @as(u32, @intCast(id)),
                    .force_list_range, .force_attrs_sweep, .force_attrs_range, .import_prefetch, .readdir_prefetch => 0,
                }, .acq_rel);
            }
        }
    };

    try sched.start(Worker.run, &ctx);

    try std.testing.expect(sched.submit(.{ .force_thunk = 5 }, 0));
    try std.testing.expect(sched.submit(.{ .force_thunk = 7 }, 0));

    // Spin until the total is observed. Futex wake latency can easily
    // dominate a tight spin loop, so we yield to the OS on every probe.
    var spins: u32 = 0;
    while (true) : (spins += 1) {
        const total = ctx.observed[1].load(.acquire) + ctx.observed[2].load(.acquire);
        if (total == 12) break;
        if (spins > 100_000) return error.HelpersDidNotProcess;
        std.Thread.yield() catch {};
    }

    // shutdown via deinit join
}

test "ReadyNode.queued CAS guard makes a second enqueue a no-op" {
    // Regression coverage for the double-resume race: multiple racing
    // wakers (or a waker racing a runner-tail path) may call
    // `enqueueReady` for the same node. Only the first should land the
    // node on the queue; the rest must be dropped so the same fiber is
    // never resumable from two places at once.
    var sched = try Scheduler.init(std.testing.allocator, 2);
    defer sched.deinit();

    var node: ReadyNode = .{};
    sched.enqueueReady(1, &node);
    try std.testing.expectEqual(@as(u8, 1), node.queued.load(.monotonic));

    // A second enqueue for the still-queued node must not push it again
    // (which would corrupt the singly-linked `next` pointer and/or hand
    // the same node to two poppers).
    sched.enqueueReady(1, &node);

    const first = sched.popReady(1);
    try std.testing.expectEqual(@as(?*ReadyNode, &node), first);
    // Queue is empty — proof there was only ever one entry.
    try std.testing.expectEqual(@as(?*ReadyNode, null), sched.popReady(1));
}

test "popReady resets queued so the node can be re-enqueued later" {
    var sched = try Scheduler.init(std.testing.allocator, 2);
    defer sched.deinit();

    var node: ReadyNode = .{};
    sched.enqueueReady(1, &node);
    _ = sched.popReady(1);
    try std.testing.expectEqual(@as(u8, 0), node.queued.load(.monotonic));

    // Now that it's off-queue, a fresh enqueue must succeed again.
    sched.enqueueReady(1, &node);
    try std.testing.expectEqual(@as(u8, 1), node.queued.load(.monotonic));
    try std.testing.expectEqual(@as(?*ReadyNode, &node), sched.popReady(1));
}

test "ready queue is FIFO" {
    var sched = try Scheduler.init(std.testing.allocator, 2);
    defer sched.deinit();

    var a: ReadyNode = .{};
    var b: ReadyNode = .{};
    var c: ReadyNode = .{};
    sched.enqueueReady(1, &a);
    sched.enqueueReady(1, &b);
    sched.enqueueReady(1, &c);

    try std.testing.expectEqual(@as(?*ReadyNode, &a), sched.popReady(1));
    try std.testing.expectEqual(@as(?*ReadyNode, &b), sched.popReady(1));
    try std.testing.expectEqual(@as(?*ReadyNode, &c), sched.popReady(1));
    try std.testing.expectEqual(@as(?*ReadyNode, null), sched.popReady(1));
}

test "stealReady finds a ready fiber on another worker's queue" {
    var sched = try Scheduler.init(std.testing.allocator, 3);
    defer sched.deinit();

    var node: ReadyNode = .{};
    sched.enqueueReady(2, &node);

    // Worker 1 has no ready work of its own but can steal worker 2's.
    try std.testing.expectEqual(@as(?*ReadyNode, null), sched.popReady(1));
    const stolen = sched.stealReady(1);
    try std.testing.expectEqual(@as(?*ReadyNode, &node), stolen);

    // Gone now — nothing left to steal.
    try std.testing.expectEqual(@as(?*ReadyNode, null), sched.stealReady(1));
}

test "stealReady never returns the caller's own queue" {
    var sched = try Scheduler.init(std.testing.allocator, 2);
    defer sched.deinit();

    var node: ReadyNode = .{};
    sched.enqueueReady(0, &node);

    // Only worker 0 has ready work, and worker 0 is asking — must not
    // steal from itself.
    try std.testing.expectEqual(@as(?*ReadyNode, null), sched.stealReady(0));

    // A worker that isn't 0 can still steal it.
    try std.testing.expectEqual(@as(?*ReadyNode, &node), sched.stealReady(1));
}

test "pop drains urgent tasks before speculative ones" {
    // Documented priority: "Pop a task from `worker_id`'s own queues —
    // urgent first, then speculative." Fan-out (demand-driven) work must
    // not sit behind a queued speculation backlog.
    var sched = try Scheduler.init(std.testing.allocator, 2);
    defer sched.deinit();

    try std.testing.expect(sched.submit(.{ .force_thunk = 1 }, 1));
    try std.testing.expect(sched.submitUrgent(.{ .force_thunk = 2 }, 1));

    const first = sched.pop(1).?;
    try std.testing.expectEqual(@as(types.ObjectId, 2), first.force_thunk);
    const second = sched.pop(1).?;
    try std.testing.expectEqual(@as(types.ObjectId, 1), second.force_thunk);
    try std.testing.expectEqual(@as(?Task, null), sched.pop(1));
}

test "parkWorker returns immediately when already woken" {
    // Single-threaded regression for the lost-wakeup guard: if a wake
    // arrives (word set to 1) before the worker parks, `parkWorker` must
    // observe it and return without blocking on the futex syscall.
    var sched = try Scheduler.init(std.testing.allocator, 2);
    defer sched.deinit();

    sched.wakeWorkerPublic(1);
    try std.testing.expectEqual(@as(u32, 1), sched.wake_words[1].word.load(.monotonic));

    // Must return promptly (no real wait to service) and drain the word.
    sched.parkWorker(1);
    try std.testing.expectEqual(@as(u32, 0), sched.wake_words[1].word.load(.monotonic));
}

test "parkWorker returns immediately once shutdown is flagged" {
    var sched = try Scheduler.init(std.testing.allocator, 2);
    defer sched.deinit();

    sched.shutdown_flag.store(true, .release);
    // No wake pending and shutdown is set — parkWorker must not block
    // waiting for a wake that will never come.
    sched.parkWorker(1);
}
