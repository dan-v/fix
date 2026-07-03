# GC Parallel-STW Mark (Phase 2a) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the `-Dgc` mark run in parallel across idle workers during the stop-the-world pause, and enable collection at `--workers>1` — so the pause drops toward mark/~3.7× and the RSS bound becomes usable in the real config.

**Architecture:** Extract the scheduler's Chase-Lev deque into a generic `Deque(T)`; give the `Tracer` an atomic mark-bitmap + per-marker `Deque(ObjectId)` with stealing; turn the STW peers' spin into a help-mark loop with idle-count termination; flip the w>1 gate. Still stop-the-world — only the *mark* is parallel.

**Tech Stack:** Zig, the `fix` evaluator; `-Dgc` comptime flag; `test/nixos_toplevel.nix` byte-identical `.drv` oracle; `FIX_GC_WN=1` (enable w>1 collect), `FIX_GC_STEP_MB` (collection frequency).

**Design:** [gc-parallel-mark-plan.md](gc-parallel-mark-plan.md). Read it first.

## Global Constraints

- **Byte-identical `.drv`** with `-Dgc` on/off, w=1/w=8/w=32 — the primary correctness bar. A parallel-mark data race manifests as a swept-live-object corruption → a diff or crash.
- **`-Dgc` is comptime-gated**; the normal build stays byte-for-byte unaffected.
- **The `Deque(T)` extraction must be a pure no-op refactor** — preserve every atomic ordering and the `mfence` verbatim. Validate byte-identical before building anything on it.
- **Non-moving / single-owner-range / token-per-collection invariants unchanged** (gc-plan.md).
- **Cap active markers at `min(worker_count, 8)`** (Phase 0: bandwidth-bound past ~8).
- **Branch `gc-parallel-mark`** off `main`; commit after each green task.

---

## Validation Protocol

- **V-refactor** (Task 1 — the deque must be a no-op): `zig build test` (scheduler push/pop/steal tests pass); normal + `-Dgc` builds byte-identical at w=1 and w=32 vs a captured baseline. No behavior change.
- **V-unit** (Task 2): the multi-thread Tracer unit test passes under `zig build test` (run several times — it's concurrent).
- **V-gc** (Tasks 3–4): `-Dgc` ReleaseFast, `FIX_GC_WN=1`, byte-identical `.drv` at w=8 and w=32, ≥30 runs each, 0 diffs/crashes, at `FIX_GC_STEP_MB` ∈ {256, 64} (several collections). Capture baseline from a normal build first.
- **Measure**: GC report's `mark time (total) / collections` = mean pause; target ~0.2s → ~0.05–0.06s at w=32.

Baseline capture (once, Task 0):
```bash
zig build -Doptimize=ReleaseFast
./zig-out/bin/fix --file test/nixos_toplevel.nix --workers=1 > /tmp/pm-baseline.txt 2>/dev/null
```

---

## Task 0: Branch + baseline

- [ ] **Step 1:** `git checkout -b gc-parallel-mark`
- [ ] **Step 2:** Capture the byte-identical baseline (command above); `wc -l /tmp/pm-baseline.txt` (expect 1 line, the toplevel `.drv`).

---

## Task 1: Extract `Deque(T)`; migrate scheduler to `Deque(Task)`

Pure refactor — no behavior change.

**Files:**
- Create: `src/parallel/deque.zig`
- Modify: `src/parallel/scheduler.zig` (replace the `TaskQueue` struct body with a thin use of `Deque(Task)`; keep `gcMark` as a method/free-fn that iterates `top..bottom`)
- Modify: `src/parallel.zig` (export `deque` if the module system needs it — follow how `fiber`/`scheduler` are exported)

**Interfaces:**
- Produces: `Deque(comptime T: type)` with `init(allocator, capacity: u32) !Self`, `deinit(allocator)`, `push(T) bool`, `pop() ?T`, `steal() ?T`, and public fields `items: []T`, `mask: u64`, `bottom`/`top: std.atomic.Value(u64)` (so `gcMark` can iterate the ring).

- [ ] **Step 1: Create `src/parallel/deque.zig`.** Copy the exact bodies of `TaskQueue.push`/`pop`/`steal`/`init`/`deinit` from `scheduler.zig`, replacing `Task`→`T` and `tasks`→`items`. Preserve the `mfence` in `pop` and the acquire/release/seq_cst orderings **verbatim** — do not "clean them up".

```zig
const std = @import("std");

/// Lock-free Chase-Lev work-stealing deque, generic over payload `T`.
/// Owner-only push/pop (LIFO); multi-consumer FIFO steal. Orderings and the
/// `mfence` are load-bearing — extracted verbatim from the scheduler's
/// TaskQueue. Fixed power-of-two capacity; full push returns false.
pub fn Deque(comptime T: type) type {
    return struct {
        const Self = @This();
        items: []T,
        mask: u64,
        bottom: std.atomic.Value(u64),
        top: std.atomic.Value(u64),

        pub fn init(allocator: std.mem.Allocator, capacity: u32) !Self {
            std.debug.assert(std.math.isPowerOfTwo(capacity));
            const items = try allocator.alloc(T, capacity);
            @memset(items, undefined);
            return .{ .items = items, .mask = @as(u64, capacity) - 1, .bottom = .init(0), .top = .init(0) };
        }
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.items);
        }
        pub fn push(self: *Self, item: T) bool {
            const b = self.bottom.load(.monotonic);
            const t = self.top.load(.acquire);
            if (b - t > self.mask) return false;
            self.items[@intCast(b & self.mask)] = item;
            self.bottom.store(b + 1, .release);
            return true;
        }
        pub fn pop(self: *Self) ?T {
            const b = self.bottom.load(.monotonic) -% 1;
            self.bottom.store(b, .monotonic);
            asm volatile ("mfence" ::: .{ .memory = true });
            const t = self.top.load(.monotonic);
            if (@as(i64, @bitCast(b -% t)) < 0) {
                self.bottom.store(t, .monotonic);
                return null;
            }
            const item = self.items[@intCast(b & self.mask)];
            if (b != t) return item;
            if (self.top.cmpxchgStrong(t, t + 1, .seq_cst, .monotonic) != null) {
                self.bottom.store(t + 1, .monotonic);
                return null;
            }
            self.bottom.store(t + 1, .monotonic);
            return item;
        }
        // steal(): port the CURRENT `TaskQueue.steal` body verbatim (it was
        // partially below line 216 in scheduler.zig — copy it exactly),
        // replacing Task→T, tasks→items. Keep its acquire load + fence + seq_cst CAS.
        pub fn steal(self: *Self) ?T {
            // <-- paste the exact existing steal body here, renamed
        }
    };
}
```

- [ ] **Step 2: Port `steal` verbatim.** Read `scheduler.zig`'s `TaskQueue.steal` in full and paste its exact body into the stub above (rename only). Do not reconstruct from memory.
- [ ] **Step 3: Migrate the scheduler.** In `scheduler.zig`, replace the `TaskQueue` struct with `const TaskQueue = Deque(Task);` (import `Deque` from `deque.zig`), and move `gcMark` to a free function `taskQueueGcMark(q: *const Deque(Task), tr, heap)` iterating `q.top`/`q.bottom`/`q.items`/`q.mask` (same loop as today). Update call sites.
- [ ] **Step 4: Add a Deque unit test** in `deque.zig` mirroring the existing "scheduler push/pop/steal" test but on `Deque(u64)`.
- [ ] **Step 5: V-refactor.** `zig build test` green; `zig build -Doptimize=ReleaseFast` then byte-identical vs `/tmp/pm-baseline.txt` at w=1 and w=32. **Commit.**
```bash
git add src/parallel/deque.zig src/parallel/scheduler.zig src/parallel.zig
git commit -m "refactor(parallel): extract Chase-Lev deque into generic Deque(T)"
```

---

## Task 2: Parallel-safe `Tracer` (atomic bitmap + per-marker deques + stats)

**Files:**
- Modify: `src/runtime/gc.zig` (the `Tracer`)
- Test: add a multi-thread mark test in `gc.zig`

**Interfaces:**
- Consumes: `Deque(ObjectId)` from Task 1.
- Produces: `Tracer` that supports N concurrent markers: `markObjectAtomic`, a per-marker `Marker` view holding a `Deque(ObjectId)` + local `LiveStats`, a `drainParallel(marker_id)` loop, and `sumStats()`.

- [ ] **Step 1: Atomic `testAndSet`.** Change the mark bitmap set to an atomic OR + old-bit check, so two markers racing the same object is safe and exactly one enqueues:

```zig
fn testAndSet(self: *Tracer, id: ObjectId) bool {
    const word = id >> 6;
    if (word >= self.mark_bits.len) return false;
    const mask = @as(u64, 1) << @intCast(id & 63);
    const prev = @atomicRmw(u64, &self.mark_bits[word], .Or, mask, .acq_rel);
    return prev & mask == 0;
}
```

- [ ] **Step 2: Per-marker deques + stats.** Replace the single `stack` with `markers: []Marker`, where `Marker = struct { deque: Deque(ObjectId), stats: LiveStats }`. `markObject` pushes to the *calling marker's* deque (thread it a `marker_id` or a `*Marker`). Accounting (`addValues`/`addAttrs`/etc.) writes the calling marker's local `stats` — never a shared field.
- [ ] **Step 3: Parallel drain.** `drainParallel(self, heap, marker_id)`: loop { pop own deque; if empty, steal from a random other marker; if still empty and termination says done, return; else scan the object (the existing trace-map switch, pushing children to own deque) }. Termination is Task 3's `active_markers`; for the unit test, use a simple "all deques empty" barrier across the test's threads.
- [ ] **Step 4: `sumStats`** — after all markers finish, sum `markers[i].stats` into `self.stats`.
- [ ] **Step 5: Multi-thread unit test.** Build a known graph (a wide+deep tree of lists so stealing actually happens), spawn K=4 threads each running `drainParallel(marker_id)` seeded round-robin from the roots, and assert the summed `stats.objects` equals the known live count and every live id is marked. Run the test body in a loop (e.g. 50×) to shake out races.

```zig
test "tracer: parallel mark reaches exactly the live set" {
    if (comptime !enabled) return;
    // ... build graph, seed K deques, spawn K threads on drainParallel,
    //     join, sumStats, expect stats.objects == known_live ...
}
```

- [ ] **Step 6: V-unit.** `zig build test` (run a few times — concurrent). **Commit.**
```bash
git add src/runtime/gc.zig
git commit -m "feat(gc): parallel-safe Tracer — atomic bitmap + per-marker deques + stealing"
```

---

## Task 3: STW help-mark + idle-count termination

**Files:**
- Modify: `src/parallel/scheduler.zig` (the STW barrier: `gcWaitAllParked`/`gcSafepointPark`/`gcEndCollection` + an `active_markers` count and a `stealMarkWork`/termination helper)
- Modify: `src/eval.zig` (`gcCollect`/`gcMarkRoots` — seed the markers' deques from the roots, run the collector as marker 0, designate ≤8 markers)
- Modify: `src/eval/worker.zig` (`gcSafepoint` path — a designated peer runs the mark loop instead of parking)

**Interfaces:**
- Consumes: `Tracer.drainParallel`, `Marker` deques from Task 2.
- Produces: a collection where ≤`min(worker_count,8)` workers mark in parallel and the rest park, with correct termination before sweep.

- [ ] **Step 1: Marker roster.** At `gcTryBeginCollection` success, the collector designates marker ids `0..min(worker_count,8)` (collector = 0). Store the count on the scheduler for peers to read.
- [ ] **Step 2: Seed roots into deques.** In `gcMarkRoots`, `markObject` currently pushes to one stack; now push round-robin across the marker deques (or all to marker 0 and let stealing spread — simpler; start there). Root-scan stays serial (collector only).
- [ ] **Step 3: Peers help-mark.** In `worker.zig gcSafepoint` / `scheduler.gcSafepointPark`: a peer whose id is a designated marker runs `Tracer.drainParallel(marker_id)` until termination; non-marker peers park as today.
- [ ] **Step 4: Idle-count termination.** Add `active_markers: Atomic(u32)` (init = marker count). A marker that finds its deque empty AND all steals fail decrements and spins on `active_markers==0`; a successful steal that transitions it back to active re-increments — mirror the last-item-steal race handling the scheduler already uses for eval termination (read `scheduler.zig`'s existing termination and copy its shape). When `active_markers==0` all deques are provably empty → mark done.
- [ ] **Step 5: Sweep unchanged.** Collector (marker 0), after termination, calls `sumStats` then the existing serial `heap.sweep` + `gcAfterCollect`, then `gcEndCollection` releases the peers.
- [ ] **Step 6: Validate at w>1 (gated behind Task 4's enablement — until then, keep the w=1 path working).** `zig build -Dgc`; confirm w=1 still byte-identical (marker count = 1 degenerates to serial). **Commit.**
```bash
git add src/parallel/scheduler.zig src/eval.zig src/eval/worker.zig
git commit -m "feat(gc): STW help-mark — parked peers mark in parallel with idle-count termination"
```

---

## Task 4: Enable at w>1 + gauntlet + measure

**Files:**
- Modify: `src/eval.zig` (`ensureMainWorker` — remove the `worker_count == 1`-only gate on `gcEnableCollect`)

- [ ] **Step 1:** In `ensureMainWorker`, enable `gcEnableCollect` for `worker_count >= 1` (drop the `if (self.worker_count == 1)`), keeping the `FIX_GC_STEP_MB` wiring.
- [ ] **Step 2: V-gc gauntlet.** `zig build -Dgc -Doptimize=ReleaseFast`. For w in {8, 32}, `FIX_GC_STEP_MB` in {256, 64}: run ≥30× with `FIX_GC_WN=1 --no-progress`, diff each vs `/tmp/pm-baseline.txt`, expect 0 diffs and 0 non-zero exits.
```bash
fail=0; for i in $(seq 1 30); do FIX_GC_WN=1 FIX_GC_STEP_MB=64 ./zig-out/bin/fix --file test/nixos_toplevel.nix --workers=32 --no-progress > /tmp/pm-$i.txt 2>/dev/null || { echo "run $i crash"; fail=$((fail+1)); }; diff -q /tmp/pm-baseline.txt /tmp/pm-$i.txt >/dev/null || { echo "run $i DIFF"; fail=$((fail+1)); }; done; echo "fail=$fail/30"
```
- [ ] **Step 3: Measure the pause.** Run once at w=32 with the GC report visible; record `mark time (total)` / `collections` = mean pause. Compare to the ~0.2s serial baseline; success = ~0.05–0.06s. If it does NOT scale (atomic-bitmap or steal contention dominates), STOP and report — that's the signal to reconsider before Phase 2b.
```bash
FIX_GC_WN=1 FIX_GC_STEP_MB=64 ./zig-out/bin/fix --file test/nixos_toplevel.nix --workers=32 --no-progress 2>&1 >/dev/null | grep -iE 'mark time|collections|peak RSS'
```
- [ ] **Step 4: Commit + update the docs' status** (gc.md w>1 row, gc-plan.md "off-the-clock mark" lever) with the measured pause + that w>1 collection is now enabled.
```bash
git add -A && git commit -m "feat(gc): enable parallel-STW collection at --workers>1"
```

## Notes / risk reminders

- The `Deque(T)` extraction is the one step that MUST be behavior-preserving — if V-refactor isn't byte-identical, stop and diff the orderings before proceeding.
- The termination mechanism (Task 3 Step 4) is the classic work-stealing hazard — mirror the scheduler's existing eval-termination rather than inventing one.
- The ReleaseSafe detector is unreliable at w>1; the w=8/w=32 ReleaseFast byte-identical stress is the real gate.
