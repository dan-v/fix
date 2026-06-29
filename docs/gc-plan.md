# GC plan — bound peak RSS so `fix` runs on normal hardware

## Why

`fix` currently never reclaims heap objects during an eval. The object,
value, attr, and attr-pos stores are append-only bump allocators
(`FlatStore` / `StableSegments` in `src/runtime/stable_segments.zig`):
allocate forever, free everything at process exit. For the
`nixos_toplevel` benchmark that's ~6M objects and a few hundred MB — fine
on a 128 GB box. A full system-closure eval the way real Nix is used
allocates *multiple GB*, the overwhelming majority of it dead the moment
it's produced: the deforestation census (`-Dstruct-census`) measured
**83.5% of lists and 66.8% of attrsets are single-use intermediates**
(~2.4M structures), built by the module/overlay fixpoint and consumed
once. Real Nix bounds this with the Boehm GC. We don't, so peak RSS
tracks *total* allocation, not *live* set, and we OOM on machines that
can actually run Nix.

**Goal: bound peak RSS to ~live-set so `fix` runs on reasonable RAM —
*without* meaningfully regressing wall time.** The project's headline is
"fastest nix," so wall time is a hard constraint, not a budget we spend.
This is not a throughput play (the benchmark isn't memory-bound —
`project_not_memory_bound`, working set fits L3); the payoff is purely
the RSS ceiling on large evals, and it has to be ~free on the clock.
That constraint is what forces the measure-first approach below: the
collector model is chosen to fit the wall-cost ceiling, not assumed.

## What the architecture forces

- **Non-moving.** Objects are addressed by a dense `ObjectId` NaN-boxed
  directly into every `Value` (`src/runtime/value.zig`), and Values live
  on every fiber VM stack, in frames, upvalues, attr entries, thunk
  payloads, import results, the derivation cache, and thread-local
  caches. A moving collector would have to rewrite every ObjectId *and*
  every `(segment,offset,len)` Range stored inside objects, across all
  suspended fibers — defeating the flat `base[id]` store the whole perf
  design rests on. So: **mark, then sweep into free lists. No
  compaction.** We accept fragmentation; size classes bound it.

- **Concurrency model is NOT decided — it's chosen by Phase 0
  measurement.** The hard constraint: *bound peak RSS without
  meaningfully regressing wall time*, because the project's headline is
  "fastest nix." For a batch tool pause *latency* is irrelevant, but
  **total pause time IS wall time** — so a naive stop-the-world that
  pauses for a meaningful fraction of the eval is disqualified. The three
  candidate models and their wall costs:

  1. **STW + parallel-mark + lazy-sweep.** Pause ∝ *live set* (not total
     heap), marked in parallel across the idle workers, with sweep
     amortized lazily into allocation. Collected rarely at a high
     threshold, total pause *may* be <1% of wall — but that's a number to
     prove in Phase 0, not assume. Simplest; no hot-path barrier.
  2. **Concurrent mark on idle cores.** Memory: helpers are ~86% idle at
     w=32, cores ~75% idle — a *surplus of CPU* against a *scarce serial
     critical path*. Marking concurrently on idle helpers spends the free
     CPU instead of wall time → ~0 wall cost, except a write barrier on
     **thunk resolution** (`unresolved→resolved` publishes a new edge)
     and the `merge_attrs.flattened` memo, gated on a global "gc active"
     flag (predictable not-taken branch when idle). The risk is that even
     a gated branch sits on the serial floor.
  3. **Targeted reclamation (no tracing GC).** Free the *provably*
     single-use intermediates inline where they die — 83.5% of lists /
     66.8% of attrsets per the census. Zero pause, zero barrier, but only
     catches what the optimizer can prove dead; this is the
     `deforestation_ceiling` lever, needs optimizer reach.

  Given the machine profile (idle cores cheap, serial wall scarce), (2)
  is the natural fit and (1) is the simple baseline; Phase 0 decides.
  Refcounting is out regardless — it dies on the cyclic thunk graphs the
  module fixpoint builds and adds atomic contention to the shared graph.

- **Mark objects, not ranges.** Every `ValueRange`/`AttrRange`/
  `AttrPosRange` is **single-owner**: each belongs to exactly one
  object's field (a list's contents, an attrset's entries, a closure's
  upvalues). Every construction site reserves a *fresh* range and
  copies (`reserveValuesLocal`, `appendValues`, `prepareAttrsRange`, the
  merge/concat/flatten paths); none alias another object's range. So
  **range liveness == owning-object liveness** — we mark objects only,
  and a range is reclaimable iff its owner is unmarked. (Load-bearing;
  Phase 1 enforces it with an assertion, see Risks.)

## The object graph (trace map)

Authoritative field-by-field map, from `src/runtime/value.zig`,
`src/runtime/heap.zig`, `src/runtime/thunk.zig`.

**A `Value` references the heap** iff its tag is one of: `list`,
`attrs`, `thunk`, `closure` (primary tags 3–6), or MISC sub-tags
`builtin_closure`, `string_context`, `boxed_int`, `partial_app`.
Extract via `asObjectId()` (low 32 bits). `int`/`float`/`bool`/`null`/
`builtin` carry nothing; `string`/`path` carry an **InternId** — the
intern table is *not* GC'd, never follow it. Likewise **ChunkId** points
into the `ChunkRegistry`, not the GC heap — never follow it.

**Per `Object` variant, follow:**
| variant          | follow |
|------------------|--------|
| `list`           | each `Value` in `values.slice(range)` |
| `attrs`          | for each `AttrEntry` in `attrs.slice(range)`: the `.value` (the `.name` is InternId) |
| `merge_attrs`    | `base`, `overlay` (ObjectIds); `flattened` if `!= NO_FLAT` |
| `closure`        | each `Value` in `values.slice(upvalues)` |
| `builtin_closure`| each `Value` in `values.slice(args)` |
| `partial_app`    | `func` (Value); each `Value` in `values.slice(args)` |
| `context_string` | for each `AttrEntry` in `attrs.slice(context)`: `.value` |
| `boxed_int`      | nothing (raw i64) |
| `thunk`          | **state-dependent**, see below |

**Thunk** (`src/runtime/thunk.zig`) — the `payload` union has *no* tag;
discriminate by `future.state` then `target_kind`:
- `.resolved` → follow `payload.result` (a Value).
- `.errored` → follow nothing; `payload.result` bits are a `*ErrorInfo`,
  heap-owned via `errored_infos` (swept separately — see Risks).
- `.blackhole` → follow nothing.
- `.unresolved` / `.evaluating` → `payload.target`, by `target_kind`:
  - `.closure` → `target.closure` (Value)
  - `.pass_through` → `target.pass_through` (Value)
  - `.attr_access` → `target.attr_access.base` (Value)
  - `.bytecode` → `BytecodeThunk` upvalues: inline `[≤2]Value` if
    `upvalue_count<=2`, else the spilled `values.slice`
  - `.deferred` → `DeferredThunk` env: inline or spilled, same shape

## The root set

From `src/vm.zig`, `src/eval.zig`, `src/eval/worker.zig`,
`src/parallel/{fiber,scheduler}.zig`. At a safepoint, scan:

1. **Every fiber's VM** (`Worker.fibers.items` across all workers — fibers
   are unpinned and migrate, so iterate *all* workers' lists):
   - `vm.stack[0..vm.sp]` (operand stack, `vm.zig:139`)
   - `vm.frames[0..vm.frames_len]`, and each `Frame.upvalues` if non-null
     (`vm.zig:72,150`)
   - `vm.builtins`, `vm.native_upvalues` (tjit)
2. **Evaluator-level:** `builtins_value` (`eval.zig:72`); every
   `ImportEntry.result` in `imports.entries` (`eval/imports.zig:76`);
   every Value in `DerivationStore.lazy_drv_cache` (bitcast u64→Value,
   `derivation/store.zig:38`); error-trace frames in `run.trace` and each
   fiber's `local_trace` if they carry Values.
3. **Scheduler pending work:** `ObjectId`s in queued tasks
   (`.force_thunk`, `.force_list_range`) in the urgent/spec queues — a
   pending task's target must survive (`scheduler.zig:33-45,269-279`).

**Thread-local caches are NOT roots and are NOT traced.** The thunk-result
memo (`vm/force.zig:74`), attr IC (`vm/access.zig:78`), call IC
(`vm/closures.zig:375`) all key on `ObjectHeap.token`. **Bump the token
at the start of every collection** → all stale slots self-invalidate on
next access. Free, and it also covers the case where a swept slot's
ObjectId gets reused.

**Precise-safepoint invariant (load-bearing).** We collect *only* at
the existing cooperative poll points (the `suppress_background` bail
sites), chosen so that all live heap Values are reachable from
`vm.stack`/`frames`/known roots — none stranded only in a Zig local on
the raw fiber C-stack. If the audit (Phase 3) finds that invariant can't
be guaranteed, the fallback is a *conservative* scan of each suspended
fiber's `stack:[]u8` from `ctx.rsp` up — safe precisely because we never
move (misidentified words only over-retain). Precise is preferred;
conservative is the safety net.

## Decision (2026-06-29): tight bound → concurrent SATB mark

Target chosen: **RSS near the ~230 MB live floor at ~zero wall.** That
requires the mark **off the wall clock** (concurrent on the idle helpers),
paid for with a gated SATB write-barrier on the three mutation sites
(thunk resolve `unresolved→resolved`; `merge_attrs.flattened` memo; cell
publish), ~<1% hot path. Build order is still **STW-first** (the tracer,
root scan, sweep + free-lists, and safepoint barrier are all reused);
concurrent mark is the final step.

### The safepoint / in-flight-allocation crux (drives the whole structure)
A collection must not free an object that is built but **not yet rooted**
— e.g. an object filled into its slot before its id is pushed to the VM
stack, or a live intermediate a loop-allocating builtin (`genList`,
`foldl'`) holds in a Zig local across a nested force. A naive
collect-from-alloc would corrupt the result.

- **STW mitigation:** collect only at a safepoint where every live Value
  is in an enumerable root (`vm.stack`/`frames`/registered temps). Op
  boundaries are *mostly* safe but builtins holding live temps in Zig
  locals across nested forces are not — would need a temp-root stack.
- **SATB dissolves it (another reason the tight-bound choice is right):**
  with **allocate-black** (objects created during a mark cycle are born
  marked) in-flight allocations are live by construction, and the
  write-barrier catches edges published into already-scanned objects. So
  the concurrent design is also the *cleaner* correctness model — build
  toward it, don't bolt it on. The brief root-snapshot STW scans the VM
  stacks precisely (the existing safepoint poll points); the final
  re-scan drains the SATB buffer.

## Phasing

Each phase is independently landable, gated behind `-Dgc` (off by
default; canonical path untouched, mirroring `-Djit`/`-Dtjit`/
`-Dstruct-census`). **Byte-identical `.drv` output is the correctness
bar at every phase.**

### Phase 0 — measure, and let the numbers pick the architecture
This phase exists *because* the wall-cost ceiling makes the collector
model evidence-dependent. Deliver the numbers that decide between STW /
concurrent-mark / targeted-reclamation, before committing to one.
- `-Dgc` build flag; `src/runtime/gc.zig` skeleton; `--gc-stats`.
- **Peak RSS** and where in the eval it occurs (high-water timeline).
- **Live set at the high-water mark** — run a non-reclaiming mark there
  and count reachable objects/bytes. This *is* the per-collection mark
  cost; it tells us whether an STW pause is sub-ms or tens of ms.
- **Reclaimable fraction** at peak (allocated − live) — the ceiling on
  what any collector can buy.
- **Allocation rate / threshold-crossing frequency** — how often a given
  threshold would trigger, i.e. how many pauses.
- **Worker slack during the high-water window** — idle-core fraction
  while RSS is peaking, i.e. headroom for concurrent marking.
- Ship the probe right (`feedback_tooling_quality`). **Decision gate:**
  pick the concurrency model from these numbers and record it here before
  Phase 1.

#### Phase 0 RESULTS (2026-06-29, `nixos_toplevel`, w=1) — GC strongly justified
`-Dgc` periodic mark-from-roots (no reclaim), every 1M object allocs:

| metric | value |
|---|---|
| total allocated (no-GC peak RSS) | **1208 MB** (14.0M objects, 17.0M values, 17.1M attrs, 4.7M attr-pos) |
| **peak live set** (RSS ceiling a GC could hold) | **228 MB** (1.95M objects) |
| **reclaimable** | **~81%** — peak-live is 19% of total → a GC caps RSS at ~5× lower |
| live-set shape | **plateaus at ~225 MB from ~40% of the eval onward** while total climbs linearly to 1.2 GB |
| per-collection mark cost | **~1.95M objects** (random heap walk) |

Read: the eval has a **bounded, stable ~228 MB working set** but churns ~1
GB of throwaway garbage past it — exactly the deforestation-census
signature (single-use intermediates) at the byte level. A collector
triggered at, say, `total > 2–3× live` (~500–700 MB) would hold RSS near
there and collect only a handful of times. **This is the case for the
GC.**

**Architecture implication:** the live set (~2M objects) is large enough
that a *serial* mark on the wall clock would be tens of ms × several
collections — unacceptable against "fastest nix." So the mark must be
**off the wall clock**: concurrent on idle cores (overlap demand) or
parallel STW across the idle workers. Either is viable; the serial-STW
strawman is out. **Still to measure before the final pick:** w=32 idle-
core slack during the high-water window (room for concurrent marking) and
real parallel-mark throughput (objects/sec/core). Those settle
concurrent-mark vs parallel-STW; the *headroom* case is now proven.

**Caveats (w=1 probe):** scans the main worker's fibers only; skips
scheduler pending-task ObjectIds and trace frames (small, transient) — so
live is a slight *under*count, i.e. reclaimable is if anything slightly
*over*stated, but ±20% on live doesn't move the conclusion.

#### Phase 0 RESULTS, part 2 — parallel-mark scaling (the STW-pause question)
End-of-eval timed serial mark + a parallel memory-walk microbench (random/
graph-order access, the real mark pattern):

| | time | speedup |
|---|---|---|
| serial mark (full discovery) | **~53 ms** | — |
| walk T=1 | ~38 ms | 1.0× |
| walk T=4 | ~13 ms | 3.0× |
| **walk T=8** | **~10.5 ms** | **3.7× (best)** |
| walk T=16 | ~11 ms | 3.5× |
| walk T=32 | ~13 ms | 3.0× (degrades) |

**Marking is memory-latency/bandwidth-bound.** Parallel mark scales to
**~3.7× at ~8 threads, then degrades** (DRAM bandwidth saturates; >8 adds
cross-core/NUMA traffic — 32 threads are *slower* than 8). So "do as much
on the workers as possible" tops out at **~8 markers, not 32**. Parallel
mark cuts a collection from ~50 ms to a **~10–15 ms floor** (incl. real
work-steal/CAS overhead).

**The RSS-vs-wall tradeoff (parallel-STW), from the plateau:**
- collect at ~2–3× live (~500–600 MB) → ~3 collections → **~2× RSS cut for
  ~3% wall**. Defensible first cut.
- collect tightly (~300 MB) → ~13 collections → ~5× RSS cut but **~12%
  wall**. Too steep for "fastest nix".

**Architecture decision:** parallel-STW (capped at ~8 markers) is the
**simple, no-barrier first cut** and buys a *moderate* RSS bound cheaply.
A *tight* bound at ~zero wall needs the mark **off the clock** —
mostly-concurrent mark on the idle helpers, paid for with a gated SATB
write-barrier on thunk-resolve + `flattened` (~<1% hot path). Plan:
**build parallel-STW first** (Phases 1–3 below, marker pool capped at 8);
keep mostly-concurrent mark as the Phase-4 upgrade if the moderate bound
isn't tight enough.

### Phase 1 — mark only, w=1, no sweep (prove the tracer)
- Side mark-bitmap indexed by ObjectId (1 bit/object; the FlatStore makes
  `bit[i] ↔ object i` trivial).
- Precise root scan (single VM at w=1) + graph mark via the trace map.
- `--gc-verify`: mark from roots, assert the top-level result object is
  marked, report marked/unmarked counts. No mutation → still
  byte-identical. **Enforce single-owner ranges here** (assert on sweep-
  candidate ranges).

### Phase 2 — sweep + free lists, w=1 (the real reclaim)
- **Object store:** intrusive free list (a dead `Object` slot holds the
  freelist next-link). `reserveObjectSlot` pulls from the free list
  before bumping.
- **Value/attr/attr-pos stores:** size-classed free lists keyed by range
  length; a dead object's range returns to its class; reserve checks the
  class first. Non-moving ⇒ fragmentation; size classes bound it.
  `StableSegments` gains a freelist-aware reserve.
- Handle `errored` thunks: sweep must release `*ErrorInfo` via the
  existing `errored_infos` tracking, not double-free.
- Trigger on occupancy threshold (and `--gc` for tests). Optional lazy
  sweep (amortize sweep into allocation).
- **Gate: byte-identical `.drv` on `nixos_toplevel` w=1 with an
  aggressively low threshold** (dozens of collections mid-eval). If the
  graph survives that, roots+tracer are right. Debug divergence with
  `fix thunks diff` / trace-diff.

### Phase 3 — go parallel, w>1 (shape set by the Phase 0 decision)
Phases 1–2 (correct tracer + free-list sweep) are model-agnostic; this is
where the chosen model lands. Both variants share: trigger on TLAB refill
over threshold *after* releasing `write_mu` (no deadlock vs mark/sweep);
audit the precise-safepoint invariant with the conservative fiber-stack
scan as the non-moving-safe fallback; bump `ObjectHeap.token` per cycle.
- **If STW:** safepoint barrier extending `suppress_background` — a
  `gc_request` flag polled at the existing cooperative points (after
  `runFiber` in `drainStep`; the genList checkpoint; thunk claim);
  workers park via the existing futex infra; last in marks. **Parallel
  mark** across the parked workers (split roots / work-stealing mark
  stack) to keep the pause live-set-proportional and short.
- **If concurrent-mark:** brief STW only to snapshot roots + bump token,
  then mark on idle helpers while demand proceeds, guarded by the
  thunk-resolve / `flattened` write barrier (SATB). Reclaim (lazy sweep)
  after the concurrent mark drains.
- **Gate: byte-identical `.drv` at w=8 and w=32, aggressive threshold,
  ≥30 runs, 0 failures** (the bar used for the fiber-park / resume-race
  fixes) — *and* a measured wall delta within the agreed ceiling.

### Phase 4 — tuning + decide default
- Adaptive heap target (collect when live·k reached); lazy sweep on by
  default; report peak-RSS reduction (the goal metric) vs throughput
  cost at w=1/w=8/w=32. Decide a default-on threshold or keep opt-in.

## Risks / load-bearing assumptions
1. **Single-owner ranges** — if any path aliases a range into two
   objects, sweeping one frees the other's payload. Strongly indicated
   by the construction-site audit; enforce with a Phase-1 assertion.
2. **Precise-safepoint invariant** — a live heap Value stranded only in a
   Zig local at a safepoint would be collected. Audit in Phase 3;
   conservative fiber-stack scan is the safe fallback (non-moving makes
   it sound).
3. **`merge_attrs.flattened`** — written lazily (a memo). In STW no
   mutation occurs during the pause, so safe; this is another reason STW
   beats concurrent-mark.
4. **`errored` thunk `*ErrorInfo`** — not a Value; swept via
   `errored_infos`, must not double-free.
5. **Token reuse** — a swept ObjectId reused later must not match a stale
   IC entry; the per-collection `token` bump covers it.
