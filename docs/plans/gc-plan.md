# GC — status and what to do next

`-Dgc` opt-in, off by default (all GC code is `comptime`-gated, so the normal
build is byte-for-byte unaffected). Non-moving mark-sweep with size-classed
free lists. Goal: **bound peak RSS to ~live-set so `fix` runs on normal RAM,
without meaningfully regressing wall time** ("fastest nix" — wall is a hard
constraint, not a budget).

## Status (2026-07-02, commit 181fbfa)

**DONE: precise collection at any native depth**, byte-identical. The collector
fires at `native_depth > 0` — mid-builtin, during the deep module fixpoint where
the garbage actually churns — not just at the rare depth-0 demand safepoints.
Fully precise: **no C-stack or register scanning**.

Validated on `nixos_toplevel` w=1:
- ReleaseFast (slot-reuse ON, production): byte-identical at every threshold.
- ReleaseSafe + range-poison detector: byte-identical, 0 UAF, to 728 collections.
- normal build (no `-Dgc`): byte-identical.

**The catch — wall.** Serial stop-the-world mark at w=1 costs **~0.2s per
collection** (higher than depth-0's ~90ms: mid-fixpoint live sets are larger and
it fires more often) plus a **~5.6% mutator tax** (the root-keeping on hot paths
— `callValue`/`doCall`/`applyBuiltin`). Measured w=1:

| config | wall | peak RSS |
|---|---|---|
| nogc | 2.756s | 1745 MB |
| gc, 1 collection (step≈600MB) | 3.174s (+15%) | 1507 MB (−14%) |
| gc, 3 collections (step≈256MB) | 3.472s (+26%) | 1355 MB (−22%) |
| gc, default (18 collections) | 5.48s (2×!) | 1162 MB (−33%) |

So today **the RSS bound costs more wall than it saves** at w=1 — worse than the
depth-0 collector's −16%-for-free. This is Phase-0's conclusion made concrete:
the mark must go **off the wall clock**. The precise foundation above is what
unblocks that. **Next lever is off-clock mark, not more per-site rooting.**

## How it stays correct — the rule for new ops and builtins

The collector marks from a fixed root set (below) and nothing else. A collection
can fire at ANY forcing call: `force.forceValue/forceTop/forceAt/forceThunk/
forceDeep`, `closures.callValue/doCall`, `access.getAttrValue`, and anything that
transitively calls those. So: **after any forcing call, every heap object you
still need must be reachable from a root.**

**Bytecode ops (`vm/run.zig`).** Operands live on the VM operand stack, which is
a precise root. Force operands *in place* — `force.forceTop(vm)` / `force.forceAt(vm, n)`
— so they stay on the stack across the force; drop with `stack.dropBin`/pop only
after. Never `forceValue(pop())` while another live operand sits off-stack. This
is why almost every op is already safe; copy an existing forcing op (e.g.
`opAddInt`, `opEq`, `opGetAttr`) when adding a new one.

**Native builtins / helpers.** Your arguments are auto-rooted (`applyBuiltin`
roots all args; `callValue`/`doCall` root callee+arg). Values reached *through* a
rooted arg (list elements, attr values) are covered. You only need to root:
- a container you hold as a raw `getList`/`getAttrs` slice or bare `ObjectId`
  across a force, and
- a **newly produced** heap value you stash in a Zig-side collection across a
  later force (a strict-fold accumulator; lists a user fn returns mid-loop; a
  string-**context** accumulator merged across an outer forcing loop).

Use the `comptime`-gated helpers in `vm/force.zig` (zero cost without `-Dgc`):

```zig
const gc_roots = force.rootsBegin(self);
defer force.rootsEnd(self, gc_roots);
force.rootKeep(self, held);            // bare id: force.rootKeep(self, Value.list(id)) / Value.attrs(id)
// loop-reassigned value: rootKeep each new value inside the loop
```

Exemplars to mirror: `collections.builtinFoldlStrict`/`builtinConcatMap`/
`builtinGenericClosure`; `builtins/strings.coerce*ListToStringValue` (roots the
list AND re-roots the `ctx` accumulator per item); `force.forceDeepInner`;
`access.getAttrPathOrValue`; `builtins/derivation.buildForcedDerivationValue`.

**ObjectId-keyed caches must carry the heap token.** A cache keyed by a raw
`ObjectId` is a reuse-only correctness bug: a swept id gets handed to a different
object, so a stale entry returns the wrong value. The reuse-OFF ReleaseSafe
detector can't see this — only ReleaseFast corrupts. `lazy_drv_cache` learned
this (now token-guarded); the thunk-memo/attr-IC/call-IC already key on token.

## The root set (`eval.zig:gcMarkRoots` / `gcMarkVm`)

At a safepoint mark:
1. **Every VM** — worker fibers' `f.vm` (all workers), the registered eval VMs
   (`gc_import_vms`: top-level entry, nested eval, imports — see the VM note in
   "Next"), for each: `vm.stack[0..sp]`, `frames` + `Frame.upvalues`,
   `vm.builtins`, `vm.native_upvalues`, plus the two precise native roots:
   `vm.gc_force_chain` (in-flight thunks) and `vm.gc_temp_roots` (builtin roots).
2. **Evaluator:** `builtins_value`; resolved `imports.entries` results; chunk
   constants (chunks never GC'd); `lazy_drv_cache` — only current-token entries.
3. **Scheduler:** queued `.force_thunk`/`.force_list_range` targets; each fiber's
   `current_task`.
4. **Thread-local caches are NOT traced** — thunk-memo / attr-IC / call-IC key on
   `ObjectHeap.token`, bumped every collection so stale slots self-invalidate.

## The object graph (trace map)

Authoritative, from `runtime/value.zig`, `runtime/heap.zig`, `runtime/thunk.zig`.

A `Value` references the heap iff its tag is `list`/`attrs`/`thunk`/`closure` or
MISC sub-tag `builtin_closure`/`string_context`/`boxed_int`/`partial_app`; extract
via `asObjectId()`. `int`/`float`/`bool`/`null`/`builtin` carry nothing;
`string`/`path` carry an **InternId** (intern table not GC'd — never follow);
**ChunkId** points into the registry (never follow).

| variant | follow |
|---|---|
| `list` | each `Value` in `values.slice(range)` |
| `attrs` | each `AttrEntry.value` in `attrs.slice(range)` (`.name` is InternId) |
| `merge_attrs` | `base`, `overlay`; `flattened` if `!= NO_FLAT` |
| `closure` | `values.slice(upvalues)` |
| `builtin_closure` | `values.slice(args)` |
| `partial_app` | `func`; `values.slice(args)` |
| `context_string` | each `AttrEntry.value` in `attrs.slice(context)` |
| `boxed_int` | nothing |
| `thunk` | state-dependent ↓ |

Thunk: discriminate by `future.state` then `target_kind`.
`.resolved` → `payload.result`. `.errored` (bits are a heap-owned `*ErrorInfo`,
swept via `errored_infos`) / `.blackhole` → nothing. `.unresolved`/`.evaluating`
→ `payload.target` by kind: `.closure`→`target.closure`; `.pass_through`→
`target.pass_through`; `.attr_access`→`target.attr_access.base`; `.bytecode`→
`BytecodeThunk.upvalues()` (inline ≤2, else spilled slice); `.deferred`→
`DeferredThunk.env()` (same shape).

## Correctness tooling

- **UAF detector** (`gc_debug` = ReleaseSafe + `-Dgc`): freed object slots are not
  reused; every object read asserts the alloc-bit → a swept-then-read traps with a
  stack trace instead of a later nondeterministic segfault.
- **Swept-range poison** (detector): a freed value/attr range is overwritten with a
  thunk-to-unallocated-id, so a dangling raw `getList`/`getAttrs` slice traps on
  next access instead of silently reading stale-but-intact data. This is what
  catches the raw-slice class the reuse-off assert alone can't.
- **`FIX_GC_STEP_MB`** env: collect every N MB of fresh allocation. Drives the
  aggressive-threshold runs (small N → hundreds of collections → exhaustive
  coverage). The completeness bar is: ReleaseFast byte-identical at several
  thresholds AND ReleaseSafe+poison byte-identical + 0 UAF at a small step.

## What to do next (priority order)

1. **Off-the-clock mark — the whole ballgame.** Serial STW mark is the wall cost.
   Two viable shapes (Phase-0 measured parallel mark tops out ~3.7× at ~8 threads,
   memory-bandwidth-bound):
   - **Parallel-STW across idle workers.** The w>1 stop-the-world barrier is
     CORRECT (2026-07-03: the earlier w>1 crash was NOT the barrier — mark-only
     is byte-identical at w=32 — but a missing GC root in the speculative
     `force_list_range` path; fixed in `worker.zig`). Collection is enabled only
     at `worker_count==1` because serial-STW mark is ~8–11× wall at w=32 (29
     collections: 6.7s serial mark + ~6.7s all-cores-spinning STW convergence —
     the barrier busy-spins rather than futex-parks). Split roots / work-steal
     the mark stack across the parked workers instead of spinning: pause becomes
     live-set-proportional and ~8× shorter (Phase-0: parallel mark ~3.7× at ~8
     threads, bandwidth-bound), and the idle cores do useful work instead of
     burning CPU at the barrier.
   - **Concurrent mark on idle helpers (SATB).** Brief STW to snapshot roots +
     bump token, then mark on idle cores while demand proceeds, guarded by a
     gated write barrier on thunk-resolve + `merge_attrs.flattened` (+ cell
     publish), with allocate-black. ~0 wall on the serial critical path; the risk
     is the gated branch on the alloc/resolve hot path.
   Either makes the RSS bound wall-viable. Parallel-STW is the smaller step (reuses
   the STW machinery); do it first, keep concurrent as the tight-bound upgrade.

2. **Cut the mutator tax. → MEASURED 2026-07-03: the tax is NOT the rooting.**
   An isolation experiment (stub every `rootKeep`/`rootsBegin`/`rootsEnd` to
   no-ops, 0 collections, interleaved vs the real `-Dgc` build) put the *rooting*
   cost at **~0.018s median / ~0.008s best ≈ noise (~0.6%)**. The real ~0.09s
   (~3.3%) 0-collection overhead is the **per-alloc `gcSetAllocBit`/threshold +
   per-force safepoint bookkeeping** (and the diffuse cost of the compiled-in GC
   branches) — not the root-keeping. Two redundant root deletions landed
   byte-identical anyway (attr-path-walk roots, the `applyBuiltin` arg-loop) but
   moved the wall ~0; the `opCall`/`doCall` keep-on-stack conversion was
   abandoned (noise-level gain, real UAF risk). So if this tax is worth cutting,
   the lever is the per-alloc/safepoint bookkeeping, **not** the rooting. Full
   write-up: docs/plans/gc-tax-removal-{plan,audit,tasks}.md.

3. **Threshold / default policy.** The additive `reserved + HEADROOM` default
   collects ~18× (2× wall). Switch to an adaptive `reserved > k·live` target so
   the default collects a few times (a "defensible first cut": ~−20% RSS for a
   modest wall once the mark is off-clock). Until (1) lands, the honest default is
   conservative (1–2 collections) or the depth-0 gate.

4. **Unify the VMs (removes a whole bug class).** The root-cause bug this session
   was that `runWithVm` runs eval on a *stack-local* VM, not the worker fiber's
   `f.vm` — invisible to the collector until registered. The top-level entry's own
   VM is vestigial (should use `f.vm`); imports make a fresh VM only because the
   `import` callback doesn't carry the current VM (thread it through and run the
   imported chunk via `runIsolatedFrame`). Collapsing to one-VM-per-fiber deletes
   the "unregistered VM" class entirely.

5. **Reclaim executing closure/thunk ranges.** `gcFreeObjectRanges` deliberately
   leaks `.closure`/`.thunk` ranges: a running frame aliases its `upvalues` slice
   (owned by the closure/thunk), so freeing it mid-run would dangle. Root the
   executing closure/thunk in the frame (a temp-root at frame push) and reclaim.
   Modest extra RSS.

6. **w>1 enablement.** The barrier + roots are correct (w=32 byte-identical,
   2026-07-03); collection at `--workers>1` is dormant only because serial-STW
   mark is ~8–11× wall there. Turn it on once (1) makes the mark parallel/
   off-clock. The per-worker root marking, import-VM registry, and suspended-
   fiber coverage are built and verified.

## Load-bearing invariants (don't break)

- **Non-moving.** Objects are addressed by dense `ObjectId` NaN-boxed into every
  Value and by `(segment,offset,len)` Ranges inside objects. A moving collector
  would have to rewrite all of them across suspended fibers — defeating the flat
  `base[id]` store. So: mark, sweep into size-classed free lists, accept
  fragmentation.
- **Single-owner ranges.** Every `ValueRange`/`AttrRange`/`AttrPosRange` belongs
  to exactly one object's field (construction sites reserve fresh + copy). Range
  liveness == owning-object liveness → we mark objects only and free a range iff
  its owner is unmarked. If any path ever aliased a range into two objects,
  sweeping one would free the other's payload.
- **Token bump per collection** covers thread-local caches AND swept-then-reused
  ObjectIds. Any new ObjectId-keyed structure must carry the token (see above).
