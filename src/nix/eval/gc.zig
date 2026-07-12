//! GC (`-Dgc`) collector glue for the Evaluator: VM-root registration and
//! the stop-the-world minor-collect driver (mark roots, drive the parallel
//! evac, record stats). These are the Evaluator-side halves of the copying
//! nursery; the heap-side machinery lives in `runtime/heap` and the marking
//! tracer in `runtime.gc`.
//!
//! Every entry point takes `ev: anytype` (the Evaluator) so this file never
//! imports the Evaluator type — that would close a cycle in the `@import`
//! graph. The two function-pointer trampolines that the heap/scheduler hooks
//! expect (`*const fn(*anyopaque, u8) void`) stay in `eval.zig` next to the
//! `setGcHook`/`gcSetMarkHook` registration; they delegate to `collect` and
//! `helpMark` here.
//!
//! Guarded by `if (comptime !gc.enabled) return;` / `comptime gc.enabled`
//! so the whole cluster compiles to nothing in a default (non-`-Dgc`) build.

const std = @import("std");
const gc = @import("runtime").gc;
const types = @import("runtime").types;
const ObjectHeap = @import("runtime").heap.ObjectHeap;
const heap_gc = @import("runtime").heap.heap_gc;
const thunk_mod = @import("runtime").thunk;
const vm_force = @import("vm").force;
const vm_access = @import("vm").access;
const timeline = @import("probe").timeline;

/// Cap on the number of participants in a single collection's mark+evac.
/// The eval still runs `worker_count`-wide; only the STW mark/evac is
/// throttled (contention-bound past ~8). Set from `FIX_GC_PAR_CAP`.
pub var gc_par_cap: u32 = 8;

/// GC (`-Dgc`): register a stack-local VM (the top-level entry's VM, a
/// nested-eval VM, or an import VM) so the collector scans its roots.
/// These VMs are NOT in any worker's `fibers` list, so without this their
/// operand stack / frames / force-chain / temp-roots are invisible and
/// their live objects get swept. Concurrent imports at --workers>1
/// interleave, hence the mutex + remove-by-value.
pub fn registerVm(ev: anytype, vm: anytype) void {
    if (comptime !gc.enabled) return;
    ev.gc_import_vms_mu.lock();
    defer ev.gc_import_vms_mu.unlock();
    ev.gc_import_vms.append(ev.allocator, vm) catch {};
}
pub fn unregisterVm(ev: anytype, vm: anytype) void {
    if (comptime !gc.enabled) return;
    ev.gc_import_vms_mu.lock();
    defer ev.gc_import_vms_mu.unlock();
    for (ev.gc_import_vms.items, 0..) |ivm, i| {
        if (ivm == vm) {
            _ = ev.gc_import_vms.swapRemove(i);
            break;
        }
    }
}

/// Body of the scheduler's parallel-mark hook: a parked peer helps drain
/// marker slot `worker_id` to termination. The `eval.zig` trampoline
/// (`gcHelpMarkThunk`) casts `*anyopaque` and calls this.
pub fn helpMark(ev: anytype, worker_id: u8) void {
    _ = worker_id;
    // Grab a marker slot. The collection is capped at GC_PAR_CAP
    // participants (contention-bound past ~8); a peer over the cap parks
    // idle rather than piling on. The collector already grabbed slot 0.
    const marker_count = @min(@as(u32, ev.worker_count), gc_par_cap);
    const slot = ev.heap.gcMarkSlotGrab();
    if (slot >= marker_count) return;
    // Drain the mark to global termination, then help the second phase: a MINOR
    // evacuates the young-object lists; a MAJOR sweeps the whole id range. Both
    // are claim loops over a shared work queue that this peer joins alongside
    // the collector.
    ev.gc_tracer.drainParallel(&ev.heap, slot);
    if (ev.heap.gc_collecting_major)
        heap_gc.sweepClaimLoop(&ev.heap, ev.gc_tracer.mark_bits)
    else
        heap_gc.evacClaimLoop(&ev.heap, ev.gc_tracer.mark_bits);
}

/// GC (`-Dgc`): one stop-the-world mark-sweep at a safepoint. Mark the
/// live graph from roots, sweep dead objects/ranges into the free
/// lists, set the next threshold from the surviving live set. Runs on
/// the lone mutator at --workers=1; see docs/plans/gc-plan.md for the roots.
pub fn collect(ev: anytype, collector_id: u8) void {
    if (comptime !gc.enabled) return;
    // Lazy policy (`enableBudget`): the first threshold (budget/2) crossing
    // arms tracking instead of collecting — everything allocated so far
    // becomes untracked/old, and the real collections start at the budget.
    // We are inside the STW (all peers parked), which `armTracking` needs
    // for the TLAB flush + flag publication.
    if (!ev.heap.gc_collect_enabled) {
        heap_gc.armLazy(&ev.heap);
        return;
    }
    // Escalate to a full collection once enough has tenured that a young-gated
    // minor can't recover the accumulated old-generation garbage (see
    // `gc_major_gate`). Same STW; the major reclaims old dead objects too.
    if (ev.heap.gcShouldMajor()) {
        collectMajor(ev, collector_id);
        return;
    }
    // Minor below: the marker slot is grabbed dynamically (capped participants),
    // so `collector_id` isn't needed past the major dispatch.
    // Timeline (`--timeline`): a `.gc` span on the collector's track so a pause
    // is visible in the trace, correlatable with the RSS/backlog counters. A
    // no-op single branch when tracing is off; nests inside the running quantum.
    timeline.begin(.gc, "minor", 0);
    defer timeline.end(.gc);
    // Copying minor collection (STW). The young-gated mark runs from roots +
    // the old→young remembered set. At --workers>1 the parked peers HELP the
    // mark (parallel young-gated drain); at --workers=1 it's serial.
    const tr = &ev.gc_tracer;
    const t0 = nowNs();
    const SeedCtx = struct { tr: *gc.Tracer, heap: *ObjectHeap };
    const Seed = struct {
        fn cb(ctx: SeedCtx, source: types.ObjectId) void {
            ctx.tr.markRemsetSource(ctx.heap, source);
        }
    };
    if (ev.worker_count > 1) {
        // Cap the collection's participants (contention-bound past ~8) —
        // the eval still runs `worker_count`-wide; only the mark+evac is
        // throttled. Peers over the cap park idle (see gcHelpMarkThunk).
        const marker_count = @min(@as(u32, ev.worker_count), gc_par_cap);
        tr.resetParallelMinor(ev.heap.objects.count(), marker_count) catch {
            heap_gc.afterCollect(&ev.heap, ev.heap.totalReservedBytes());
            return;
        };
        heap_gc.beginEvac(&ev.heap, ev.worker_count); // arm the evac work queue (resets slot dispenser)
        const collector_slot = ev.heap.gcMarkSlotGrab(); // grabbed before gcOpenMark ⇒ slot 0
        // Seed roots + remset into the collector's own marker deque, open
        // the mark so parked peers help drain it, then drain alongside them.
        tr.beginSeeding(collector_slot);
        markRoots(ev, tr);
        heap_gc.forEachRemsetSource(&ev.heap, SeedCtx{ .tr = tr, .heap = &ev.heap }, Seed.cb);
        tr.endSeeding();
        ev.scheduler.gcOpenMark();
        tr.drainParallel(&ev.heap, collector_slot); // returns at termination
        // Mark closed. Verify closure while peers spin (no range moves yet),
        // then open the evac phase and evacuate alongside them.
        heap_gc.verifyMinorClosure(&ev.heap, tr.mark_bits);
        heap_gc.openEvac(&ev.heap);
        heap_gc.evacClaimLoop(&ev.heap, tr.mark_bits);
        heap_gc.waitEvacDone(&ev.heap);
        ev.scheduler.gcCloseMark();
        tr.sumStats();
    } else {
        var remset_sources: u64 = 0;
        const CountSeedCtx = struct { tr: *gc.Tracer, heap: *ObjectHeap, n: *u64 };
        const CountSeed = struct {
            fn cb(ctx: CountSeedCtx, source: types.ObjectId) void {
                ctx.n.* += 1;
                ctx.tr.markRemsetSource(ctx.heap, source);
            }
        };
        tr.resetMinor(ev.heap.objects.count()) catch {
            heap_gc.afterCollect(&ev.heap, ev.heap.totalReservedBytes());
            return;
        };
        const p0 = nowNs();
        markRoots(ev, tr);
        const p1 = nowNs();
        heap_gc.forEachRemsetSource(&ev.heap, CountSeedCtx{ .tr = tr, .heap = &ev.heap, .n = &remset_sources }, CountSeed.cb);
        const p2 = nowNs();
        tr.drainMinor(&ev.heap);
        const p3 = nowNs();
        gc.recordMarkPhases(p0 - t0, p1 - p0, p2 - p1, p3 - p2, remset_sources);
    }
    const t1 = nowNs();
    // w>1 already evacuated in parallel (claim loop); just finish (verify +
    // reset nursery). w=1 runs the whole serial minor here.
    const st = if (ev.worker_count > 1)
        heap_gc.finishEvac(&ev.heap)
    else
        heap_gc.minorCollect(&ev.heap, tr.mark_bits);
    const t2 = nowNs();
    heap_gc.remsetClear(&ev.heap);
    // Charge this minor's tenurings against the major gate: once enough has
    // accumulated in the old generation, the next collection escalates.
    ev.heap.gcNoteMinorPromoted(st.promoted);
    heap_gc.afterCollect(&ev.heap, tr.stats.bytes);
    gc.recordCollection(st.freed, tr.stats.bytes, ev.heap.totalReservedBytes());
    gc.recordTiming(t1 - t0, t2 - t1);
    gc.recordBreakdown(.{
        .obj_live = tr.stats.objects,
        .obj_reserved = ev.heap.objects.count(),
        .val_live = tr.stats.values,
        .val_reserved = ev.heap.values.reservedSlots(),
        .attr_live = tr.stats.attrs,
        .attr_reserved = ev.heap.attrs.reservedSlots(),
    });
}

/// GC (`-Dgc`): one stop-the-world MAJOR (full) collection at a safepoint.
/// Unlike `collect` (the young-gated minor), this marks the whole reachable
/// graph from roots and sweeps EVERY unmarked object — reclaiming the tenured
/// old-generation garbage a minor can't. At --workers>1 the parked peers help
/// the MARK (parallel, non-gated) just like a minor; the sweep stays serial.
pub fn collectMajor(ev: anytype, collector_id: u8) void {
    if (comptime !gc.enabled) return;
    _ = collector_id; // marker slot grabbed dynamically, like the minor
    // Same lazy-arm as the minor: the first crossing arms tracking (everything
    // so far becomes untracked/old) rather than collecting.
    if (!ev.heap.gc_collect_enabled) {
        heap_gc.armLazy(&ev.heap);
        return;
    }
    timeline.begin(.gc, "major", 0);
    defer timeline.end(.gc);
    const tr = &ev.gc_tracer;
    const t0 = nowNs();
    // Full mark from all roots. Rescan EVERY chunk's constants: the incremental
    // cursor (`gc_chunks_scanned`) only covers chunks compiled since the last
    // minor, but a non-gated mark must trace old referents too. No remembered
    // set is seeded — a non-gated mark traces through old objects directly.
    ev.gc_chunks_scanned = 0;
    var st: @import("runtime").heap.SweepStats = .{};
    if (ev.worker_count > 1) {
        // Parallel full mark: seed roots into the collector's marker deque, open
        // the mark so the parked peers help drain, then drain alongside them.
        // `gc_collecting_major` makes those peers skip the evac phase (`helpMark`).
        const marker_count = @min(@as(u32, ev.worker_count), gc_par_cap);
        tr.resetParallel(ev.heap.objects.count(), marker_count) catch {
            heap_gc.afterCollect(&ev.heap, ev.heap.totalReservedBytes());
            return;
        };
        ev.heap.gc_mark_slot.store(0, .release); // slot dispenser (minor does this in beginEvac)
        // Arm the parallel-sweep phase BEFORE opening the mark: each participant
        // flows drain→sweepClaimLoop inside one `helpMark`, so `gc_sweep_open`
        // must already be false when a peer reaches the sweep loop.
        ev.heap.gc_sweep_next.store(0, .monotonic);
        ev.heap.gc_sweep_done.store(0, .monotonic);
        ev.heap.gc_sweep_freed.store(0, .monotonic);
        ev.heap.gc_sweep_count = marker_count;
        ev.heap.gc_sweep_open.store(false, .release);
        ev.heap.gc_collecting_major = true;
        const collector_slot = ev.heap.gcMarkSlotGrab(); // grabbed before gcOpenMark ⇒ slot 0
        tr.beginSeeding(collector_slot);
        markRoots(ev, tr);
        tr.endSeeding();
        ev.scheduler.gcOpenMark();
        tr.drainParallel(&ev.heap, collector_slot); // returns at global termination
        ev.scheduler.gcCloseMark();
        tr.sumStats();
        // Parallel sweep: reconstruct the alloc bitmap (serial), then release the
        // peers — spinning in `sweepClaimLoop` since their drain returned — to
        // claim id-range chunks alongside the collector.
        heap_gc.sweepPrep(&ev.heap, tr.mark_bits);
        ev.heap.gc_sweep_open.store(true, .release);
        heap_gc.sweepClaimLoop(&ev.heap, tr.mark_bits);
        heap_gc.sweepWaitDone(&ev.heap);
        st = .{ .objects_freed = ev.heap.gc_sweep_freed.load(.acquire) };
    } else {
        tr.resetMajor(ev.heap.objects.count()) catch {
            heap_gc.afterCollect(&ev.heap, ev.heap.totalReservedBytes());
            return;
        };
        markRoots(ev, tr);
        tr.drain(&ev.heap);
        st = ev.heap.sweep(tr.mark_bits); // serial full sweep
    }
    const t1 = nowNs();
    // Tenure survivors + empty the nursery, then drop the now-stale remset
    // (young generation is empty ⇒ no old→young edges remain). Swept slots stay
    // round-robined across worker shards; the allocation path work-steals across
    // shards, so a demand-concentrated workload still reuses the whole pool.
    ev.heap.gcMajorReconcile(tr.mark_bits);
    heap_gc.remsetClear(&ev.heap);
    // Peers are long past their evac-phase check (drainParallel terminated
    // before the sweep) — safe to clear for the next (possibly minor) collection.
    ev.heap.gc_collecting_major = false;
    // Re-arm the major gate to the surviving live set: the next major fires once
    // the old generation has roughly doubled with fresh tenurings again.
    ev.heap.gcNoteMajor(tr.stats.objects);
    const t2 = nowNs();
    heap_gc.afterCollect(&ev.heap, tr.stats.bytes);
    gc.recordCollection(st.objects_freed, tr.stats.bytes, ev.heap.totalReservedBytes());
    gc.recordTiming(t1 - t0, t2 - t1);
}

pub fn nowNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

// --- collection policy (the automatic line) -------------------------------
//
// One coarse decision, made once, from one stable number — total RAM. We keep
// the object stores under `clamp(fraction × MemTotal, floor, ceiling)`:
//   - below the line, never collect: small evals, and any eval on a roomy
//     machine, run flat-out (no pauses, no tracking) — the "waste" is RAM you
//     weren't going to use;
//   - above it, collect so the stores stop ballooning (a tight machine reclaims
//     before it OOMs; a roomy one never gets there);
//   - the CLAMP scales it: a floor so a tiny box doesn't thrash small evals, a
//     ceiling so a huge box doesn't sit on absurd garbage (bounded absolute
//     waste). After a major the collector floats the threshold up toward the
//     true live set (see `heap_gc.afterCollect`), so a genuinely big heap
//     doesn't thrash the line.
//
// Deliberately NOT consulted: swap, hugetlb accounting, RSS-vs-reserved,
// moment-to-moment MemAvailable. Those are diagnostics; if an eval genuinely
// outgrows RAM that's the kernel's job (swap / OOM), not ours to micro-manage.
// The flag/env is a pure OVERRIDE — pin a ceiling (CI) or `0` to disable.

/// Fraction of RAM the stores may reach before collecting (num/den), and the
/// default clamp bounds. The bounds are overridable per run via `FIX_GC_FLOOR`
/// / `FIX_GC_CEILING` (same SIZE syntax as `--max-memory`).
pub const GC_LINE_NUM: u64 = 1;
pub const GC_LINE_DEN: u64 = 2; // half of RAM
pub const GC_LINE_FLOOR: u64 = 256 << 20; // 256 MB — below this, don't bother
pub const GC_LINE_CEILING: u64 = 8 << 30; // 8 GB — cap absolute garbage on big boxes

/// Parse a `--max-memory` / `FIX_MAX_MEMORY` size: a decimal integer with an
/// optional k/m/g (KiB/MiB/GiB) suffix; a bare integer is MiB. Returns bytes,
/// or null if malformed.
pub fn parseMemorySize(text: []const u8) ?u64 {
    if (text.len == 0) return null;
    var num = text;
    var mult: u64 = 1 << 20; // bare integer = MiB
    switch (text[text.len - 1]) {
        'k', 'K' => {
            mult = 1 << 10;
            num = text[0 .. text.len - 1];
        },
        'm', 'M' => {
            mult = 1 << 20;
            num = text[0 .. text.len - 1];
        },
        'g', 'G' => {
            mult = 1 << 30;
            num = text[0 .. text.len - 1];
        },
        else => {},
    }
    const n = std.fmt.parseInt(u64, num, 10) catch return null;
    return n *| mult;
}

/// Resolve the collection line: `--max-memory` if given, else `FIX_MAX_MEMORY`,
/// else the automatic `clamp(fraction × MemTotal, floor, ceiling)`. An explicit
/// value is taken verbatim (including `0` = never collect) — a hard override of
/// the auto policy; the auto path never returns `0`.
pub fn memoryBudget(ev: anytype) u64 {
    if (ev.max_memory_bytes) |b| return b;
    if (envSize(ev, "FIX_MAX_MEMORY")) |b| return b;
    return autoCollectLine(ev);
}

/// CONSTRAINED MODE: is memory tight enough that the collector will plausibly
/// ARM (cross budget/2 during a real eval)? Only then does the pre-arming
/// reclaim matter — and only then is it worth keeping the transient-root gates
/// live from eval start (~1.9%, `heap.gc_root_active`) to make that reclaim
/// sound. True iff an explicit `--max-memory`/`FIX_MAX_MEMORY` was given (the
/// user opted into a limit), OR the auto line came in below the default ceiling
/// (a RAM-limited box). A roomy auto machine (line clamped to the ceiling) never
/// arms → stays exactly zero-cost with the reclaim off (moot there anyway).
pub fn constrainedMode(ev: anytype, budget: u64) bool {
    if (comptime !gc.enabled) return false;
    const explicit = ev.max_memory_bytes != null or envSize(ev, "FIX_MAX_MEMORY") != null;
    const ceiling = envSize(ev, "FIX_GC_CEILING") orelse GC_LINE_CEILING;
    return constrainedFor(budget, explicit, ceiling);
}

/// Pure core of `constrainedMode`, so the policy is testable. Constrained iff a
/// collection line is set (`budget != 0`) AND either the user asked for a limit
/// (`explicit`) or the auto line came in under the ceiling (a RAM-limited box).
/// The roomy-auto case (line clamped to the ceiling) is the ONLY non-constrained
/// collecting case — it never arms, so the reclaim is moot and stays off.
fn constrainedFor(budget: u64, explicit: bool, ceiling: u64) bool {
    if (budget == 0) return false; // never-collect override
    return explicit or budget < ceiling;
}

test "constrained mode: explicit limit or sub-ceiling auto line" {
    const c = GC_LINE_CEILING;
    try std.testing.expect(!constrainedFor(0, false, c)); // never-collect override
    try std.testing.expect(!constrainedFor(0, true, c)); // even explicit 0 = never
    try std.testing.expect(!constrainedFor(c, false, c)); // roomy auto (line == ceiling)
    try std.testing.expect(constrainedFor(c, true, c)); // explicit at the ceiling
    try std.testing.expect(constrainedFor(2 << 30, false, c)); // RAM-limited auto (< ceiling)
    try std.testing.expect(constrainedFor(800 << 20, false, c)); // small auto line
    try std.testing.expect(!constrainedFor(16 << 30, false, c)); // auto above ceiling (defensive)
    try std.testing.expect(constrainedFor(16 << 30, true, c)); // explicit big limit still opts in
}

/// The automatic line: a fraction of physical RAM, clamped. MemTotal (not the
/// fluctuating MemAvailable) so it's stable and read exactly once. The clamp
/// bounds default to `GC_LINE_FLOOR`/`GC_LINE_CEILING`, overridable per run via
/// `FIX_GC_FLOOR`/`FIX_GC_CEILING`. Fallback: a conservative 4 GiB assumption
/// when /proc/meminfo is unreadable.
fn autoCollectLine(ev: anytype) u64 {
    const floor = envSize(ev, "FIX_GC_FLOOR") orelse GC_LINE_FLOOR;
    const ceiling = envSize(ev, "FIX_GC_CEILING") orelse GC_LINE_CEILING;
    return lineFor(systemMemoryTotal() orelse (4 << 30), floor, ceiling);
}

/// A `SIZE`-syntax env override (same grammar as `--max-memory`), or null.
fn envSize(ev: anytype, key: []const u8) ?u64 {
    if (ev.env_map) |em| if (em.get(key)) |s| return parseMemorySize(s);
    return null;
}

/// `clamp(fraction × ram, floor, ceiling)` — pure, so the policy is testable.
/// `@max(floor, ceiling)` guards a floor set above the ceiling.
fn lineFor(ram: u64, floor: u64, ceiling: u64) u64 {
    return std.math.clamp(ram / GC_LINE_DEN *| GC_LINE_NUM, floor, @max(floor, ceiling));
}

test "auto collection line: fraction of RAM, clamped to [floor, ceiling]" {
    const f = GC_LINE_FLOOR;
    const c = GC_LINE_CEILING;
    // Floor: tiny boxes don't thrash small evals.
    try std.testing.expectEqual(f, lineFor(256 << 20, f, c)); // ½·256MB=128MB → floor
    try std.testing.expectEqual(f, lineFor(512 << 20, f, c)); // ½·512MB=256MB → floor
    // Mid-range: scales at the fraction.
    try std.testing.expectEqual(@as(u64, 1 << 30), lineFor(2 << 30, f, c)); // 2GB → 1GB
    try std.testing.expectEqual(@as(u64, 2 << 30), lineFor(4 << 30, f, c)); // 4GB → 2GB
    try std.testing.expectEqual(@as(u64, 4 << 30), lineFor(8 << 30, f, c)); // 8GB → 4GB
    // Ceiling: huge boxes don't sit on absurd garbage.
    try std.testing.expectEqual(c, lineFor(16 << 30, f, c)); // 16GB → 8GB (cap)
    try std.testing.expectEqual(c, lineFor(128 << 30, f, c)); // 128GB → 8GB (cap)
    // Overridden bounds: a raised ceiling lets a big box hold more before GC.
    try std.testing.expectEqual(@as(u64, 32 << 30), lineFor(64 << 30, f, 64 << 30)); // ½·64=32GB, under raised 64GB cap
    try std.testing.expectEqual(@as(u64, 64 << 30), lineFor(256 << 30, f, 64 << 30)); // ½·256=128GB → capped at 64GB
    // A floor set above the ceiling collapses to the floor (guarded).
    try std.testing.expectEqual(@as(u64, 2 << 30), lineFor(8 << 30, 2 << 30, 1 << 30));
}

/// MemTotal from /proc/meminfo, in bytes.
fn systemMemoryTotal() ?u64 {
    var buf: [8192]u8 = undefined;
    const linux = std.os.linux;
    const fd_raw = linux.open("/proc/meminfo", .{ .ACCMODE = .RDONLY }, 0);
    const fd: i32 = @intCast(@as(isize, @bitCast(fd_raw)));
    if (fd < 0) return null;
    defer _ = linux.close(fd);
    const n = linux.read(fd, &buf, buf.len);
    const rd: isize = @bitCast(n);
    if (rd <= 0) return null;
    const text = buf[0..@intCast(rd)];
    if (meminfoKb(text, "MemTotal:")) |kb| return kb << 10;
    return null;
}

/// Extract `<key>   <n> kB` from /proc/meminfo text.
fn meminfoKb(text: []const u8, key: []const u8) ?u64 {
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, key)) continue;
        var it = std.mem.tokenizeScalar(u8, line[key.len..], ' ');
        const tok = it.next() orelse return null;
        return std.fmt.parseInt(u64, tok, 10) catch null;
    }
    return null;
}

test "parseMemorySize accepts bare-MiB and k/m/g suffixes, rejects junk" {
    try std.testing.expectEqual(@as(?u64, 512 << 20), parseMemorySize("512"));
    try std.testing.expectEqual(@as(?u64, 4 << 30), parseMemorySize("4g"));
    try std.testing.expectEqual(@as(?u64, 4 << 30), parseMemorySize("4G"));
    try std.testing.expectEqual(@as(?u64, 64 << 20), parseMemorySize("64m"));
    try std.testing.expectEqual(@as(?u64, 128 << 10), parseMemorySize("128k"));
    try std.testing.expectEqual(@as(?u64, 0), parseMemorySize("0"));
    try std.testing.expectEqual(@as(?u64, null), parseMemorySize(""));
    try std.testing.expectEqual(@as(?u64, null), parseMemorySize("g"));
    try std.testing.expectEqual(@as(?u64, null), parseMemorySize("12x"));
    try std.testing.expectEqual(@as(?u64, null), parseMemorySize("-1"));
}

/// Mark all GC roots into `tr` (without draining). See docs/plans/gc-plan.md.
pub fn markRoots(ev: anytype, tr: *gc.Tracer) void {
    if (ev.builtins_value) |b| tr.markValue(&ev.heap, b);
    // Caller-held external roots (repl scope bindings / last results —
    // values alive between evaluations with no VM holding them).
    for (ev.gc_extra_roots.items) |v| tr.markValue(&ev.heap, v);
    // Every worker's fibers' VM stack/frames/upvalues. At a stop-the-
    // world every live worker is parked at a safepoint, so its fiber
    // list is stable and its fibers' VMs hold that worker's roots. The
    // registry is published by each worker before it can allocate.
    for (ev.gc_workers) |*slot| {
        const w = slot.load(.acquire) orelse continue;
        for (w.fibers.items) |f| {
            // Precise, for every fiber: operand stack + frames + upvalues +
            // in-flight force chain + builtin temp-roots (see force.zig).
            markVm(tr, &ev.heap, &f.vm);
            // A task assigned to a fiber is out of the scheduler queue
            // but still a live reference until the fiber processes it.
            if (f.current_task) |task| switch (task) {
                .force_thunk => |id| tr.markObject(&ev.heap, id),
                .force_list_range => |r| tr.markObject(&ev.heap, r.list_id),
                .force_attrs_sweep => |id| tr.markObject(&ev.heap, id),
                .force_attrs_range => |r| tr.markObject(&ev.heap, r.attrs_id),
                .import_prefetch, .readdir_prefetch => {},
            };
        }
    }
    // Transient import VMs (not in any fiber list).
    ev.gc_import_vms_mu.lock();
    for (ev.gc_import_vms.items) |ivm| markVm(tr, &ev.heap, ivm);
    ev.gc_import_vms_mu.unlock();
    // Pending scheduler tasks reference thunks/lists that will be forced.
    ev.scheduler.gcMarkPendingTasks(tr, &ev.heap);
    // Thread-local caches hold Values that can be the momentary sole
    // reference to a shared object during forcing — mark them.
    vm_force.gcMarkThunkMemo(tr, &ev.heap);
    vm_access.gcMarkAttrCache(tr, &ev.heap);
    // Chunk constants can hold heap references (e.g. a scoped-import's
    // ambient-scope attrset baked in via emitConstant). Chunks are never
    // GC'd, so their constants are permanent roots — but INCREMENTALLY:
    // only chunks compiled since the last minor can reference a still-young
    // object (earlier ones' referents were promoted at their first scan;
    // post-promotion young refs come via the remembered set). See
    // `gc_chunks_scanned`.
    const chunk_count = ev.registry.count();
    var cid: types.ChunkId = ev.gc_chunks_scanned;
    while (cid < chunk_count) : (cid += 1) {
        const ch = ev.registry.get(cid) orelse continue;
        for (ch.constants) |c| tr.markValue(&ev.heap, c);
    }
    ev.gc_chunks_scanned = chunk_count;
    // Resolved import results.
    var it = ev.imports.entries.iterator();
    while (it.next()) |e| {
        const entry = e.value_ptr.*;
        if (entry.future.state.load(.monotonic) == @intFromEnum(thunk_mod.FutureState.resolved))
            tr.markValue(&ev.heap, entry.result);
    }
    // Lazy-derivation cache (Value bits keyed by attrs id). Only current-
    // token entries are live roots; stale ones (pre-GC id, now reused) are
    // dead and will miss on lookup, so don't retain them.
    var dit = ev.derivations.lazy_drv_cache.iterator();
    while (dit.next()) |e| if (e.value_ptr.token == ev.heap.token)
        tr.markValue(&ev.heap, .{ .bits = e.value_ptr.bits });
}

pub fn markVm(tr: *gc.Tracer, heap: *ObjectHeap, vm: anytype) void {
    if (comptime !gc.enabled) return;
    tr.markValue(heap, vm.builtins);
    tr.markValue(heap, vm.gc_extra_root); // value in-flight at the safepoint
    for (vm.gc_force_chain.items) |id| tr.markObject(heap, id); // in-flight force chain
    for (vm.gc_temp_roots.items) |v| tr.markValue(heap, v); // native builtin roots
    for (vm.stack[0..vm.sp]) |v| tr.markValue(heap, v);
    for (vm.frames[0..vm.frames_len]) |frame| {
        if (frame.upvalues) |ups| for (ups) |v| tr.markValue(heap, v);
    }
}
