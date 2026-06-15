# Performance notes — road to 1s on the NixOS toplevel eval

Living record of what's been measured on `test/nixos_toplevel.nix`, so we
stop re-treading ruled-out ground. Bench with `./bench.sh <label> <workers>
<runs>` (best+median wall, clean ReleaseFast build).

## Current numbers (ReleaseFast, this machine, 32 cores)

| workers | wall (best) | note |
| --- | --- | --- |
| 1 | ~3.50s | fully throughput-bound, serial |
| 8 | ~1.77s | |
| 16 | ~1.77s | parallelism saturated here |
| 32 | ~1.72s | adding cores past ~16 does ~nothing |

Correctness oracle: the printed `.drv` store path is a hash of the entire
evaluated derivation graph. **Identical path == byte-identical evaluation.**
Any perf change must keep it unchanged (plus `zig build test`).

## Cumulative result (this session)

Controlled A/B, session-start (a984a99) vs HEAD, back-to-back:

| workers | session-start | now | Δ |
| --- | --- | --- | --- |
| 1 | 3.669 | 3.564 | −3.1% |
| 32 | 1.836 | 1.750 | **−5.4%** |

Committed wins that stack and **transfer to w=32**: heap object-shrink,
attr-position pre-sort (drop a runtime sort), strictness-driven eager
elision of must-forced `let` bindings, inline small thunk upvalues
(−60% values-store entries), and runtime-adaptive arg thunking
(`apply_arg`). Earlier "w=1 wins don't transfer" calls were noisy
single-change artifacts — the controlled cumulative shows they do.

## Strictness-based thunk reduction: surface is small (measured)

The architecture is right — defer thunk-vs-eager to runtime where the
callee is known (`apply_arg`) — and it's committed and correct. But the
*surface* on nixpkgs is small: must-forced `let` bindings 37K, direct-
strict args 94K, forwarding `x: f x` **0** (eta-expansion is rare). Most
args are trivial (short-circuited), immediate, or to builtin/non-strict
callees. So strictness can't make a big dent here.

## LANDED: layered `//` (lazy update) — −1.3% w=1, −1.6% w=32

The NixOS module/overlay fixpoints build a massive attrset by `//`-ing an
accumulator thousands of times. Materializing each step copied the whole
accumulator — ~18M of the 19.4M attr-store entries were these throwaway
copies, and the copy/alloc sat on the **serial fixpoint critical path**.

Fix (`heap.zig` `MergeAttrsObject` + `mergeAttrsLayered`, `vm/objects.zig`
`mergeAttrs`): `a // b` over a large `a` is now an O(1) layer node
`{base, overlay, depth, flattened?}` surfaced as `Value.attrs(id)`, so
every `isAttrs()`/`kind()==.attrs` reader is untouched. `//` is shallow
right-biased → `getAttrValueOpt` walks overlay-then-base (const, fed by the
existing (obj,name) inline cache); `getAttrs`/iteration flattens-and-memoizes
on demand. Small merges (left < 32) stay eager (no indirection on the cheap
common case); chains flatten past depth 8 (bounds lookup + per-flatten work).

Result (A/B, 10 runs × 3 rounds, layer wins every round):

| workers | base best/median | layered best/median | Δ |
| --- | --- | --- | --- |
| 1 | 3.483 / 3.518 | 3.436 / 3.474 | −1.3% |
| 32 | 1.710 / 1.774 | 1.680 / 1.746 | −1.6% |

Byte-identical `.drv`, full tests green. Attr store 19.41M → 17.48M entries
(~1.9M fewer copies); 30.5K large merges layered. Params `MERGE_LAYER_MIN=32`,
`MERGE_FLATTEN_DEPTH=8` (swept: deeper/lower-min `16/32` was worse).

**Follow-up — k-way flatten (`flattenMerge`):** the first cut flattened a
chain by *recursive pairwise* `addMergedAttrs` — a depth-8 chain did 8
sequential merges, each allocating an O(N) intermediate (so true flatten work
was ~depth·N and littered the store with throwaways). Replaced with a single
k-way right-biased merge over the collected chain leaves (`collectMergeLeaves`
+ `kwayMergeLeaves`): one pass, one allocation, newest-leaf-wins on a shared
name. Result: flatten count 9990→6420, flatten-entries 5.86M→2.41M, **attr
store 17.48M → 14.03M (−28% vs the 19.41M baseline)**; w=1 a further ~1.3%
(3.47→3.42 best), w=32 neutral-to-better within noise. Positions are dropped
on the flat object (getAttrPos walks the merge chain, not the flat).

This is
a **critical-path** win — unlike the throughput micro-opts, attacking the
serial fixpoint merge transfers to w=32. Reconciles the earlier "`//` merge
is 1.5% of cycles, a red herring" note: the merge *loop* is cheap, but the
*copy volume + allocation* it drives (and its position on the serial chain)
was not — eliminating the copies, not speeding the loop, is what paid.

### Merge family fully mined — adjacent levers measured & rejected
- **strict/recursive merge (`merge_attrs_strict`)**: 137,962 calls, 2.77M
  entries, avg ~20; only **8** calls have left≥32 (max 389). All tiny
  recursive merges — no large subpopulation to layer, and layering is
  recursive (complex). Not worth it.
- **list `++` (`addConcatenatedLists`)**: 128,717 calls, only 358K entries
  total (max 2037). The `foldl' (++)` quadratic isn't biting (nixpkgs lists
  are short). Not worth layering.
- **trivial single-param lambda short-circuit** (`x: x`, `x: c`, `x: <upval>`
  resolved at the call site without a frame): **regressed ~2-3% at w=1 AND
  w=32** and was reverted. `doCall`/`callValue`/`doTailCall` are the hottest
  paths (~4.5M calls); adding a per-call union load + branch cost more on the
  majority (non-trivial) than it saved on the trivial minority. Unlike the
  trivial-*thunk* short-circuit (which saves a heap alloc on the cooler
  thunk-creation path), the call path is too hot to tax for a minority win —
  this is JIT territory (compile the body, no per-call interpreter check).

Post-merge-win operation profile (`-Dprof-main`, w=1): cost is now dominated
by the **call/frame/dispatch machinery** — `apply_builtin` ~4B, `run_isolated
_frame` ~3.3B, `do_call` ~2B excl cycles — i.e. the module system applying
millions of functions (`modules.nix:450`). No single hot op; the remaining
big lever is the **method-JIT** (compile hot lambda bodies, remove per-call
frame+dispatch overhead). `merge_attrs` excl is now only 187M (was the lever,
now mined).

## Wait-chain analysis: fix is at the SERIAL CRITICAL-PATH FLOOR (decisive)

Ran the existing main-thread profiler (`-Dprof-main`, which records *only*
worker 0 / main, including `wait_busy_thunk` = main blocked on a helper and
`park_main_worker` = main idle) at **workers=32** for the first time. The
result settles the long-open question "is the w=32 wall a JIT problem or a
critical-path problem":

| main (worker 0) @ w=32 | calls |
| --- | --- |
| `wait_busy_thunk` (blocked on a helper) | **2** |
| `park_main_worker` (idle, queue empty) | **3** (~2 ms) |
| `force_value` | 68 K (vs **23 M** at w=1) |
| `force_thunk_slow` (main computes the thunk itself) | 13.7 K |
| `run_isolated_frame` | 14 K |
| `apply_builtin` | 10 K |

**Main never waits.** It runs the entire critical path itself, end-to-end,
and almost never blocks on a helper or idles. Helpers offload 99.7% of
forces (23 M → main only does 68 K) — everything *off* the critical path —
but the path itself is a strict serial chain main must walk node by node.
So **the w=32 wall ≈ main's serial execution of the critical chain**, which
is exactly why work-elimination *on that chain* (the layered-`//` merge win)
transferred to w=32 while throughput/parallelism work didn't.

**What's on the chain** (`prof builtins` @ w=32, by what main runs):
`derivationLazyAttr` (drv/outPath SHA256 over the input-drv DAG — memoized
O(N) via the `DerivationStore` resolver, inherent crypto), and the
map-family (`mapAttrValue`/`map`/`mapAttrs`/`any`/`length`/`concatMap`)
whose cost is the *user functions* they drive. Both inherent.

**Strategic consequences (this is the important part):**
1. **More parallelism is useless** — main never waits, helpers are 86% idle;
   the chain is genuine data-dependency, discovered just-in-time, so helpers
   can't get ahead of it (confirms Plan-2 / burst-dispatch dead ends).
2. **A JIT cannot reach the 1 s goal** — main's *machinery* (force + frame +
   dispatch: `run_isolated_frame`+`force_thunk_slow`+`force_value`+`do_call`
   ≈ 100 M excl cycles) is only ~7% of the w=32 wall; the rest is inherent
   builtin/user-fn/hashing work. Even a perfect tracing JIT only attacks the
   ~7%. (Matches the measured-neutral per-body JIT.)
3. **The only lever left is eliminating real *work* on the serial chain** —
   the merge win was that; the big remaining items (drv hashing, module-system
   user functions) are inherent. The cheap and medium work-elimination wins
   are spent.

Bottom line: fix (parallel bytecode VM, ~1.7 s w=32 / ~3.4 s w=1) sits at
its serial-critical-path floor for the NixOS toplevel. Going materially
below ~1.7 s needs a *fundamentally* different evaluation strategy (e.g.
caching module/option evaluation at the Nix-semantic level, or reducing how
much of the option tree is forced) — not VM micro-architecture. Versus
single-threaded tree-walking C++ Nix, fix is almost certainly already far
ahead; the 1 s-at-w=32 target is bounded by inherent serial dependencies.

## On-chain work reduction (LANDED) — structural frame/cell elimination

The critical-path analysis said the only remaining lever is eliminating
real *work* on the serial chain. Two such wins landed, both byte-identical
`.drv` (w=1 and w=32), both transferring to w=32 (they're on the chain):

1. **Direct formal binding** (`72f2638`): every attrset-pattern lambda
   (`{ config, lib, pkgs, ... }: body` — every NixOS module fn) gave each
   formal a binding *cell* (`init_cell_slot`: a heap alloc + a force
   indirection per access). Cells are only needed for mutually-recursive
   defaults (`{ a, b ? a }`). The common case (no defaults / no sibling
   refs) now binds formals directly via `set_local`. ~0.5–1.5% w=1 & w=32.
   NB an earlier whole-body *dead-formal* analysis regressed ~4% — the
   `collectReferencedNames` body walk cost more than it saved; the shipped
   version walks only the (tiny/absent) defaults.

2. **Frameless `attr_access` thunk** (`012f829`): the most common thunk
   shape is `someUpvalue.attr` (`config.foo`, `lib.bar`, param lookups) — a
   bytecode thunk over a 7-byte `get_upvalue_attr; ret` chunk that forced
   by pushing an *isolated frame* + dispatch. New `ThunkTarget.attr_access
   {base, name}` (classified at chunk-finish, built frameless at thunk
   creation) forces via a direct `getAttrValue` — no frame, no dispatch.
   **~2% w=32** (median, 16-run×4).

These **refine the floor finding**: the per-node machinery (`run_isolated_
frame` etc.) *is* partially reducible on the chain — but only by
**structural** elimination (the thunk genuinely has no frame), NOT by
per-op/per-call runtime checks (the trivial-lambda short-circuit added an
`if jit/trivial` test to every call and regressed). The distinction is the
lesson: remove the work, don't gate it. Possible next in the same vein:
2-level `attr_access` (`config.foo.bar`, ~20% as common as 1-level).

## Proper work reduction: thunk-result memo (eliminate redundant computation)

The "VM-level exhausted" call below was premature in one dimension: it
looked at machinery, not *redundant work*. Measured the redundant-force
rate — bytecode-thunk forces whose `(chunk_id, upvalue-bits)` key was
already computed by an earlier *distinct* thunk (same pure inputs → same
result, which the per-object thunk memoization can't share): **10.8% of
bytecode-thunk computations**, spread across the `lib` helpers
(`lib.types.*`, `lib.mkXxx`) that nixpkgs re-evaluates with identical args
across thousands of modules (top single chunk only ~5%, so it needs a
general memo, not a targeted patch).

Landed (`05359c7`): a bounded **thread-local** (per-worker, zero-contention)
cache `(heap_token, chunk_id, ≤2 upvalues) → resolved Value`, checked on the
freshly-claimed force path; a hit resolves the thunk to the cached value and
skips re-running the body. Sound (pure fns), exact key compare (no hash-only
false hits), `heap_token`-guarded for multi-eval (the attr-cache trick).
Direct-mapped 16K slots (64K was *worse* — 2.5MB/thread blows L2); only taxes
the slow force path (`force_thunk_slow` ~2.9M), not the 23M resolved-fast
hits. Byte-identical w=1 & w=32, tests green. **~2.5–3% w=1, ~2% w=32.**

This is the genuine non-incremental lever: not faster machinery, *less
computation*. The redundancy is inherent to the nixpkgs source (it re-writes
`types.bool` etc. inline everywhere; C++ Nix re-evaluates it too) — we just
stop recomputing identical pure suspensions within a run.

**Cumulative session** (049fa0f → 05359c7): layered `//` + k-way flatten,
direct formal binding, frameless `attr_access`, thunk-result memo ≈
**−5.5% w=32 / −5.4% w=1** (median), all byte-identical `.drv`.

## Post-wins re-profile — VM-level work reduction is exhausted for this eval

After the three on-chain wins, re-profiled main at w=32 and systematically
checked the remaining candidates. The result: VM-level work reduction is
spent for the NixOS toplevel.

- **Machinery is mined out.** The frameless `attr_access` win halved on-path
  `run_isolated_frame` excl (38M → 19.7M); total main-path machinery
  (`run_isolated_frame`+`do_call`+`force_*`) is now ~28M excl — small.
  `apply_builtin` excl (541M) is the dominant bucket and it's **builtin
  *bodies*** (drv-hash SHA256/ATerm self, string interning), i.e. inherent.
- **Hot builtins are clean** — checked for over-forcing / over-fan-out:
  `length` is O(1) (no element force); `any`/`all` short-circuit and do NOT
  fan out; `filter`/`concatMap` fan out only because they walk the whole
  list; `substring`/`toString`/`length` high *inclusive* is inherent
  arg-forcing (big strings, drv hashing), not waste.
- **drv hashing**: 828 distinct drvs = exactly the toplevel's necessary drv
  closure, memoized O(N) via the `DerivationStore` resolver, 3 genuinely
  distinct ATerm serializations each. No redundancy.
- **No over-forcing** found: lazy eval forces only what's demanded;
  speculation "waste" is helper-side and helpers are 86% idle (no wall
  contention). The drv closure and assertion-forcing are required for
  correctness (`.drv`-identical), so there's no semantic slack to cut.

Measured-and-rejected this round (neutral/negative on the toplevel — the
levers don't *bite* this workload):
- **Deeper `attr_access` chains** (`config.foo.bar(.baz)`): ~0.7% w=32 (in
  noise) but a consistent ~0.5% w=1 regression from the wider struct +
  bigger `TrivialBody` on every chunk. Reverted.
- **`zipAttrsWith` linear-scan → hashmap**: it IS a latent O(total ×
  unique_keys) quadratic (module def-merge core), but it isn't hot here —
  the attrsets it zips are small, so the hashmap's alloc/hash overhead
  slightly *loses* the common case (neutral best, ~0.5% worse median).
  Reverted; keep the linear scan. (Worth revisiting only if a config ever
  makes `zipAttrsWith` hot on large key sets.)

Conclusion: the cheap/medium *and* the algorithmic on-chain work-reduction
wins are now harvested (cumulative session: layered `//` + k-way flatten,
direct formals, frameless attr_access ≈ **−4.5% w=32 / −2.5% w=1**). What
remains on the serial chain is inherent (drv-hash DAG + module-system user
functions + required assertion evaluation). Below the current floor needs a
different evaluation model, not VM micro-architecture.

## Method-JIT (per-body) is measured-dead — the cost is in the call graph

Built the ambitious version the prof-main profile pointed at: a real
**linear whole-body JIT compiler** (`jit_linear.zig`, committed 09ebe5f) —
a stack machine that emits native code for an arbitrary straight-line chunk
body op-by-op (operand stack in native-stack memory, no VM-layout coupling;
`rbx`=vm/`r14`=upvalues/`r15`=arg; complex ops tail into the existing C-ABI
helpers), falling back to the interpreter on any unhandled op. Covers
constant/push_lit/capture+get upvalue+local/call/tail_call/ret. **~3× the
peephole matcher's chunk coverage.** Byte-identical `.drv` at w=1 and w=32,
all tests green, no parallel race.

**Two independent expansions, both measured WALL-NEUTRAL** (3-way A/B,
no-JIT vs peephole vs linear, 10×N runs):
- linear compiler (3× coverage): neutral at w=32, ~2% *slower* at w=1.
- + inlined `force` fast path (non-thunk → no helper call): still neutral.

| | w=1 best | w=32 best |
| --- | --- | --- |
| no-JIT | 3.41–3.44 | 1.72–1.76 |
| JIT peephole | 3.48 | 1.74–1.77 |
| JIT +linear | 3.46 | 1.72–1.77 |
| JIT +linear +inline-force | 3.55 (drift) | 1.73–1.75 |

**Root cause (conclusive):** the per-body JIT removes bytecode *dispatch*
from chunk bodies, but the dominant cost is NOT body dispatch — it's
(a) the helpers the body calls (`callValue`→`runIsolatedFrame` for the
*callee*, `forceValue` of substantial thunks), (b) the callee frame
machinery, and (c) a per-call `if ch.jit_code` dispatch-check tax the
marginally-faster bodies don't recover (the ~2% w=1 regression). The JIT'd
bodies are thin wrappers; the time is in the *call graph* they drive, which
a per-body compiler cannot touch. Tripling coverage and inlining the force
fast path both confirmed it: neither moved the wall.

**What this means for a winning JIT:** only a **tracing / cross-procedure
inlining JIT** — record a hot force-chain *across call boundaries* and
compile it to straight-line native with guards + deopt — collapses the
call-graph/frame/dispatch overhead that dominates. That's the PyPy/LuaJIT
shape; it's research-grade (trace recording, guard/side-exit, deopt) and
multi-month. The committed linear compiler + emitter + C-ABI helpers are a
usable substrate for it, but the per-body approach alone is a dead end for
this workload. (`-Djit` stays opt-in / off by default; zero impact on real
builds.)

## The real remaining lever: the 5M never-forced thunks

44% of the 5.9M thunks are **created and never forced** — attrset values
(the config option tree) and cells, built eagerly at attrset-build time
but never accessed. This is the "we don't need it at all" case: we only
know which attrs are needed at *access* time. The architectural shift is
**lazy attrset values** — store a way to compute each value on demand
instead of materialising a thunk per attr at build time, so never-
accessed attrs cost nothing. Major change (attrset representation, build
op, getAttr, every attr reader) but it targets the biggest waste, and
the never-forced thunks are why thunk_captures is the top opcode (15.5%).

## Lazy-attr ceiling — Phase 1 measured (decisive go)

`fix inspect` now reports an "attr-value thunk ceiling" table: every
`.attrs` object is binned by attr count, and for each thunk-valued entry
we check whether its thunk is still `.unresolved` at teardown (created,
never forced). On `test/nixos_toplevel.nix --workers 1`:

| attrset size | attrsets | thunk-vals | never-forced | %unforced | %of-unforced |
| --- | --- | --- | --- | --- | --- |
| 1 | 247K | 159K | 54K | 33.9% | 0.5% |
| 2-4 | 394K | 763K | 351K | 46.0% | 3.0% |
| 5-8 | 101K | 547K | 242K | 44.3% | 2.1% |
| 9-16 | 63K | 576K | 261K | 45.3% | 2.2% |
| 17-32 | 127K | 3.04M | 674K | 22.2% | 5.8% |
| 33-64 | 56K | 2.33M | 437K | 18.8% | 3.8% |
| 65-128 | 4.8K | 319K | 127K | 39.7% | 1.1% |
| 129-256 | 223 | 36K | 32K | 88.1% | 0.3% |
| 257-512 | 131 | 45K | 37K | 82.1% | 0.3% |
| **513+** | **638** | **9.48M** | **9.39M** | **99.1%** | **80.9%** |

**The waste is overwhelmingly concentrated in a handful of huge
attrsets.** 80.9% of never-forced attr thunks live in the 638 attrsets
with ≥513 attrs (99.1% of those are never forced — the config option
tree / whole-nixpkgs package set). 86.4% live in attrsets ≥33 attrs.

Implication for the gate: a **high size threshold (≥256, maybe ≥512)**
captures ~81% of the win while making only ~640–770 attrsets lazy — so
the per-access "is this pending?" overhead (regression risk #2) is
exposed to almost nothing, and every hot small attrset stays eager. The
worry that the win is "spread across small sets" is disproven; build it.

Caveat (honest): the per-entry scan double-counts thunks shared across
`//`-merged attrs objects (17.3M entries vs 5.8M live thunks; 2.78M
unique unresolved = the canonical 47.9% never-forced). But dedup only
*strengthens* "concentrated in large sets" — merges replicate large
attrsets' thunks, so the entry-weighted distribution is the relevant one
for a build-site gate.

## Lazy-attr ceiling — Phase 1.5: provenance (the gate doesn't hold)

`fix inspect` also now reports attrs-object provenance (per creation path
— literal `build_attrs` / runtime `//` merge / builtin like
`mapAttrs`/`listToAttrs` — a size histogram of objects and thunk-valued
entries). This was added to answer: are the giant never-forced attrsets
compile-time literals (gateable) or runtime-built? The 513+ bucket (which
holds 80.9% of all never-forced entries):

| origin | objects | thunk-vals |
| --- | --- | --- |
| literal | 68 | 310K |
| **merge** | **491** | **8.52M** (89.8%) |
| builtin | 79 | 654K |

**The giant attrsets are ~90% `//`-merge results, not literals.** And
merge *copies* value references — the thunks it counts were *created*
elsewhere. Creation-site totals (merge excluded as copies):
- **literal** attr-value thunks ≈ 1.5M, but **spread across small
  attrsets** (575K in size 2-4, 256K in 5-8, …; only 310K in 513+).
- **builtin** attr-value thunks ≈ 2.27M, concentrated in size 33-64
  (983K, mapAttrs over option trees) and 513+ (654K).

**Consequences for the spec's Phase-3 design (high-threshold literal
gate):**
1. A `build_lazy_attrs` gate at ≥256/512 on *literals* touches only the
   68 big literal objects (~310K entries) — ~3% of the giant-bucket win.
   To capture literal-created never-forced thunks you'd need a *low*
   threshold (≥2), exposing the per-access pending-check broadly.
2. The real never-forced thunks are born at literal (small sets) +
   builtin (`mapAttrs`) sites, then *replicated by merge* into the giant
   hot attrsets. Capturing the win therefore needs lazy creation at those
   sites **plus** merge that preserves pending values — which makes the
   **hot, name-accessed merge-results (the `pkgs` set / option tree)**
   carry the lazy representation. That pushes the per-access overhead onto
   the *hottest* attr lookups in the program — the exact failure mode that
   regressed the attr pre-sort +7.5% at w=32.

This is Phase 1's stated "reconsider before building" trigger: the win is
**not** a handful of cold large literals; it's spread across creation
sites and concentrated (post-merge) in the hottest attrsets. The clean,
low-risk "make 638 cold literals lazy" story does not hold. A lazy-attr
build is still *possible* but is a broad, high-risk change (low-threshold
literal gate + lazy `mapAttrs`/`listToAttrs` + pending-preserving merge,
with the overhead landing on hot lookups), not the contained Phase-3 cut.

NOTE: the `recordAttrOrigin` instrumentation runs on every attrs build
(an isThunk loop + per-thunk tag write + atomic) and allocates a 32M-byte
`thunk_origin` side buffer — measurement-only; gate or remove before any
A/B bench.

## Lazy-attr ceiling — Phase 1.6: creation-origin × forced-state join

Tagged every attr-value thunk by the origin of the attrset it was
*created* in (first-writer-wins; merge copies already-tagged thunks), then
bucketed all 5.8M thunks by tag × unresolved at teardown. The sum of
never-forced across tags = 2,779,949 = exactly the unresolved count, so
the tagging is complete:

| creation origin | thunks | never-forced | waste rate |
| --- | --- | --- | --- |
| untagged (non-attr: let/list/arg/cell) | 3.39M | 1.18M | 34.8% |
| literal attr-value | 1.40M | 794K | 56.6% |
| builtin attr-value (`mapAttrs`/`listToAttrs`) | 1.01M | 808K | **79.9%** |
| merge | 0 | 0 | — (pure copies — validates the method) |

So the 2.78M unique never-forced thunks split: **42% non-attr, 28%
literal-attr, 29% builtin-attr.** The most contained, highest-yield lever
is **lazy builtin-attr (`mapAttrs`/`listToAttrs`)**: 808K never-forced at
the highest waste rate (79.9%), confined to a couple of builtins. (Those
`mapattrs_apply` thunks carry 3 upvalues → they *spill* to the values
store, so each is heavier than an inline thunk: eliding them saves more
per thunk.) Literal-attr is comparable in size but spread across small
attrsets (needs a low threshold → broad overhead); non-attr is the single
largest slice — the spec's "cells/let-binding" follow-on, plus list items.

**The deeper caveat (re-stated, decisive for the w=32 goal):** these are
*never-forced* thunks — by definition OFF the critical path. Eliding them
is a **throughput + RSS** win (fewer allocations; `thunk_captures`/`addAttrs`
churn), not a critical-path win. This file already establishes that
throughput wins barely transfer to w=32, which IS the serial fixpoint
critical path. So the expected w=32 wall impact of *any* lazy-attr variant
is ~0; the realistic upside is w=1 throughput and peak memory. Pursue only
if w=1/RSS is the objective — for w=32→1s this whole direction is
predicted to be neutral.

## Lazy-attr ceiling — Phase 1.7: full decomposition + closing verdict

Split the non-attr slice further (apply_arg tagged at its op; let vs cell
via ThunkTarget variant). Full never-forced decomposition (sums to exactly
2,779,949 = the unresolved count):

| creation origin | thunks | never-forced | waste rate |
| --- | --- | --- | --- |
| builtin attr (`mapAttrs`/`listToAttrs`) | 1.01M | 808K | **79.9%** |
| literal attr | 1.34M | 779K | 58.3% |
| let-binding (bytecode) | 1.65M | 710K | 43.1% |
| cell (recursive-attr / `make_cell`) | 963K | 330K | 34.3% |
| apply_arg | 786K | 143K | 18.1% |
| list item | 54K | 9K | 17.3% |
| merge | 0 | 0 | — (pure copies) |

**Closing verdict — the never-forced direction has no clean win left.**
Every cheap creation-elision is ALREADY harvested:
- **let dead-binding elimination** is already done — `classifyLetBindings`
  (compiler/ops.zig) marks statically-unreferenced bindings `.unreferenced`
  and skips them. So the 710K never-forced let thunks are all *referenced*
  handles whose value-path isn't taken at runtime (laziness working).
- **must-force let bindings** are already eagerly elided (no thunk).
- **trivial-body thunks** are already short-circuited (no alloc).
- **apply_arg** is already runtime-adaptive (18% waste — working).

What remains (the 2.78M) is "laziness working as intended": referenced
handles the program legitimately never forces. Eliding their *creation*
requires deferred-creation / lazy-slot materialization, which moves cost to
a per-access "is this materialized?" check on the **hottest paths** — attr
lookups (`getAttr`), let-local reads, recursive-attr reads. That is the
exact regression mode that cost the attr pre-sort +7.5% at w=32. And these
are never-forced → off the force critical path; the only creation that
would transfer to w=32 (trivial-body precedent) is already short-circuited.

## Lazy-attr ceiling — Phase 2: BUILT lazy `mapAttrs`, measured a regression

Rather than keep predicting, implemented lazy `mapAttrs` end-to-end and
A/B'd it. Design: a `mapped_attrs` heap object (func + source + per-entry
value slots born `Value.pending`), surfaced as `Value.attrs(id)` so every
`isAttrs()`/`kind()==.attrs` reader is untouched; `getAttrValue`
materializes one slot on access (CAS pending→element-thunk), `getAttrs`
materializes all. Correct: byte-identical `.drv`, full test suite green.

**A/B (this machine, interleaved, 6 runs):**

| workers | baseline best/med | lazy best/med | Δ |
| --- | --- | --- | --- |
| 1 | 3.408 / 3.428 | 3.441 / 3.495 | **+1–2% slower** |
| 32 | 1.673 / 1.717 | 1.690 / 1.756 | **+1–2% slower** |

**Root cause (measured, not predicted):** the NixOS module system merges
option-tree attrsets constantly, and `addMergedAttrs`/`mergeAttrLiteralObjects`
read operands via `getAttrs`, which **materializes a `mapped_attrs` in full
on the first merge**. So the laziness almost never survives to a never-access
— the element thunks get created at merge time anyway, and we additionally
pay the `mapped_attrs` machinery (extra object + pending slots + per-access
variant dispatch) and lose `mapAttrs`'s speculative pre-forcing (hence the
w=32 cost too). Reverted.

The only variant that could win needs **pending-preserving merge** —
per-entry self-describing descriptors so a merged attrset stays lazy — which
makes every merge-result (the hot `pkgs`/option tree, accessed by name
constantly) carry the lazy representation and pay the per-access check. That
is the broad, hottest-path change the Phase 1.x analysis flagged; given a
contained version already measures **negative**, it is not worth the risk for
the w=32 goal.

**Verdict: the lazy-attrset / never-forced-thunk-elimination direction is
closed, now with a measured regression, not just a prediction.** All
diagnostic scaffolding (mapped_attrs, `recordAttrOrigin`, `thunk_origin`
buffer, provenance/origin-join + ceiling inspect tables) was reverted; the
tree is clean. The real lever stays critical-path/wait-chain work (below).

## The shape of the problem

- **Parallelism is saturated at ~16 workers**; helpers are ~87% idle at
  w=32 (util 12.8%). The w=32 wall (~1.7s) *is* the serial critical
  dependency chain through the NixOS module-system fixpoint. More cores /
  more speculation submission does not help (see memory).
- **w=1 throughput wins barely transfer to w=32.** The −2% from the
  object-shrink below moved w=32 by ~0 (noise). Reaching 1s is a
  *critical-path* problem, not a throughput problem. Throughput work helps
  only insofar as it speeds the specific forces *on* the longest chain.

## Object / allocation mix (from `fix inspect`, w=8)

- objects 20.2M: **thunk 11.3M** (of which **~5M never forced**),
  builtin_closure 2.5M, closure 2.3M, attrs 2.25M, list 1.67M.
- **44% of thunks are allocated and never forced** (lazy NixOS option trees).
- `attr_positions`: 11.3M entries — diagnostic-only, off the eval path.

## Hypotheses tested

| idea | result |
| --- | --- |
| Per-thunk atomic sync is the cost (every thunk is a `Future`) | **FALSE.** Stripped hot-path atomics to plain `.raw` at w=1: 3.556 vs 3.568 = noise. On x86 acquire/release are plain `mov`; the LOCK CMPXCHG claim is ~0.5%. |
| `.apply` thunk target for map/genList/mapAttrs (kill apply-chunk frame + value-store upvalues) | **Neutral / slightly worse.** `callValue` runs each application as its own `runIsolatedFrame`; the old apply-chunk kept it in one dispatch loop via tail_call, so 2-arg mapAttrs did *more* frame-runs. Per-element thunk machinery is not on the hot path; the user-fn body dominates. Reverted. |
| Eager-evaluate strict non-recursive `let` bindings into the slot (skip the thunk) | **Unsafe as specified.** The existing `shallow` strictness set (strictness.zig) is a *may-force* set tuned for the harmless speculative-submit hint — its `assert`/`with` rules over-approximate. Eager *elision* would raise errors that lazy eval wouldn't (or turn a non-error into an error). A sound *must-force* analysis is so conservative it barely beats the existing `.literal` path. Not shipped. |
| Shrink every heap object 20% by removing the per-object `meta` field | **Landed, small win.** −2% w=1, ~0 w=32, ~320MB less heap, net code reduction. Confirms locality is a *small* factor at w=1, not the w=32 lever. |
| Combinator fusion of map/mapAttrs/genList (eliminate intermediate structures / never-forced element thunks) | **Dead end, measured.** Tagged map-family element thunks and counted them in the heap scan: at w=1 they are **194K of 5.93M thunks (3.3%)** and **99.97% are forced** (52 never forced). So there is essentially no build-then-discard waste to fuse, and intermediate-elimination is just cheap lazy-thunk allocation (the apply-thunk experiment was neutral). Even perfect pattern-discovery reclaims ~0. NOTE: 2.78M thunks (47%) *are* never forced — but they're module-system option-tree thunks (attrset values, `let` bindings), not combinators; eliding those isn't fusion and a deferred computation *is* a thunk. |

## Source-level profile (`-Dprof-path`, workers=1)

The `-Dprof-path` profiler attributes serial self-cycles to Nix source
locations (`fix --workers=1 --print-sched-stats`). First run on the
toplevel — where the ~3.5s serial time goes:

| self cycles | calls | location / builtin |
| --- | --- | --- |
| 1.66B | 2.2K | `lib/modules.nix:450` — apply each module fn to args |
| 1.58B | 261 | `lib/fixed-points.nix:331` — `prev // overlay final prev` (overlay-fixpoint `//` merge) |
| 1.03B | 6.9K | builtin `derivationLazyAttr` (drvPath/outPath hashing) |
| 574M | 342K | builtin `mapAttrValue` (recursive mapAttrs over option trees) |
| ~1B+ | — | many more `lib/modules.nix` lines (888 option-decl merge, 570, 536, 891, 1265, 880) |

Read: the serial cost is the **NixOS module system** (module application
+ option merging, all attrset-heavy) and the **overlay fixpoint `//`
merge** over whole-nixpkgs attrsets, plus derivation hashing. Much of
this is *our* evaluator's attrset machinery (`merge_attrs`/`//`,
`mapAttrs`, attr lookup) running on very large attrsets — and the
fixpoint/module-merge is inherently the serial critical path, so
speeding those specific operations should transfer to w=32 (unlike
generic throughput wins). Concrete next targets: the `//` large-attrset
merge and `mapAttrValue`.

Caveat: `-Dprof-path`'s "heaviest force subtree" span is an OPTIMISTIC
bound (models independent sibling forces as parallel); the flat
self-cycle table is the ground truth.

**Bigger caveat — `prof-path` self-time over-attributes to driver chunks.**
Spans nest on thunk *forces* only, not direct closure calls. So a driver
like `lib/fixed-points.nix:331` (`prev // overlay final prev`) shows
1.58B self that is really the *overlays it calls*, not the `//` merge.
Verified by adding a `merge_attrs` counter to `-Dprof-main`: the `//`
merge is only **247M cycles** (1.5%), 261K calls at 947 cyc — NOT a
hotspot. Lesson: use `prof-path` for "which forcing site drives call
work", `prof-main` for operation-level truth. The operation-level truth
remains: cost is broadly distributed across force machinery (~4.2B),
builtin bodies (~3.7B), and frame/dispatch (~2.5B) — no single hot
operation. The only big levers stay a method-JIT or force-volume
reduction; the `//`-merge lead was a red herring.

## What this points at

The 1s target needs the **critical path** at high worker count:
1. **Critical-path / wait-chain tooling** (next): at w=32, attribute wall
   time to the longest dependency chain — what each blocking force waits
   on and what resolves it. Today's `-Dprof-main` measures main's serial
   cost but main *parks* ~waiting for helpers; the chain threads through
   fibers and isn't visible. This is the general-form tool to build before
   more guessing.
2. **Method-JIT of substantial chunks** (high ceiling, large): the
   peephole JIT shapes are wall-neutral because they only cover tiny
   chunks. Only helps if the hot chunks are *on* the critical path.

Throughput micro-optimizations (allocation shape, sync, object size) are
largely spent for the w=32 goal — they help w=1 by single-digit % and
don't transfer.

## Lean thunk: value-less Future + result/target union (LANDED, byte-identical)

Premise from a fresh baseline: **fix w=1 (3.25s) is measurably SLOWER than
C++ `nix-instantiate` (2.75s)** on the identical eval (byte-identical
`.drv`), and 32 cores buy only ~1.9×. `-Dprof-main` at w=1 showed the thunk
machinery is **~4.5B cy / ~28% of w=1** and cache-bound: the resolved
fast-path `force_value` is **99 cy/call** over 16M calls ≈ one cache miss
per force, because every heap `Object` slot was **64 B** (`Thunk`
dominates the union → every object pays Thunk's size).

Shrank the hottest, most-numerous heap object **64 B → 48 B** in two
byte-identical steps:
1. `Future` is now **value-less** — the embedder (`Thunk`/`ImportEntry`)
   owns its typed result slot. In `Thunk`, `result` and `target` share a
   bare union (never live at once: read `target` to compute, overwrite
   with `result` at resolution; `future.state` is the discriminant). 64→56.
2. `ThunkTarget` is a **bare union**; its 1-byte discriminant moved to a
   plain `target_kind` in `Future`'s padding (Zig packs it free). Drops the
   8-aligned enum-tag rounding. 56→48. No atomic-transition change.

Controlled A/B, back-to-back n=10, vs `fff7b31`:

| workers | baseline (64 B) | now (48 B) | Δ median |
| --- | --- | --- | --- |
| 1 | 3.254 / 3.287 | 3.179 / 3.215 | −2.2% |
| 32 | 1.588 / 1.652 | 1.554 / 1.613 | **−2.4%** |

So object-shrink **does transfer to w=32** (~2.4%), consistent with the
earlier "controlled cumulative shows transfer" finding — main's
critical-path forces are equally cache-bound.

**Diminishing returns / where it stops.** Step 1 (64→56) carried most of
the w=1 win; step 2 (56→48) was perf-neutral alone (real only cumulatively
at w=32). The working set of live thunks (5.86M × 48 B ≈ 281 MB) ≫ L3, so
most forces miss to DRAM regardless of size — shrinking helps residency
second-order, not miss *rate*. Size is **not** the dominant w=1→C++ gap;
the bigger w=1 self-time is `apply_builtin` (3.74B cy) and
`run_isolated_frame` (2.04B cy) — builtin dispatch + frame machinery.

**Next shrink is gated on risk.** 48→32 B requires evicting the 8-byte
`waiters_head` pointer (the only field left that costs size — the 1-byte
fields hide in alignment padding) into a side-table with an intricate
lock-free enroll/wake protocol. This is the exact code behind multiple
past race fixes (`speculation_race_threshold128`, `fiber_resume_race`);
high-risk for ~2-3%. Deferred. For the headline w=32 number the higher-EV
ambitious lever is **parallel derivation-DAG hashing** (offload the 828-node
drv-hash DAG — all required, a pure function of built attrsets — onto the
86%-idle helpers, moving ~13% of work off main's serial chain).

## Flat object store: one-load `get(id)` (LANDED, byte-identical)

The w=1 gap vs C++ `nix-instantiate` (3.2s vs 2.75s) is per-op overhead,
not inherent work (49.9M opcodes ≈ 290 cy/op). One pervasive contributor:
**every `heap.get(id)` decoded a flat ObjectId into `(segment, offset)`**
via `StableSegments.locationOf` (a `clz` + shifts), then did an atomic
segment-pointer load, then the object load — ~5-7 cy of pure indirection
on top of the load, repeated *tens of millions* of times (16.06M from
`force_value` alone), where C++ does a single deref.

The object store is referenced **only by flat ObjectId** — unlike the
value/attr/attr_pos stores it never hands out a `Range`/`slice`
externally — so it doesn't need segmentation at all. Backed it with a new
`stable.FlatStore`: one `mmap`-reserved contiguous region (`MAP_NORESERVE`,
`1<<30` slots ≈ 60 GB virtual but only touched pages cost physical memory),
mapped once at `ObjectHeap.init` before any worker spawns and **never
relocated**. `get(id)` collapses to `base[id]` — one load, no decode, no
per-access atomic (the base is immutable, so reads need no synchronization;
`reserve` still bumps a cursor under `write_mu`). The `Range`/`globalIdOf`
shape mirrors `StableSegments` (segment always 0, offset = global id) so
the heap's per-worker TLAB code is store-agnostic and unchanged.

Pointer stability under concurrent append at w=32 is free: the mapping
never moves, and a reader only ever touches an id published through the
value/state release that made it reachable (happens-after the fill).
`MAP_NORESERVE` pages commit on first write — same fault-in behavior as
the allocator-backed segments, so no commit-ordering subtlety.

`-Dprof-main` w=1, identical 16,064,708 calls: `force_value` exclusive
**100 → 95 cy/call** (−5%, total excl 1.61B → 1.53B cy) — exactly the
decode overhead removed; the load itself still misses to DRAM (the ~95 cy
floor). The wall win is larger than force_value's slice because *every*
consumer (`getConst`, `getAttrValueOpt`, closure/list access) shed the
same decode.

Controlled A/B, back-to-back n=10, vs `de587cd`:

| workers | baseline | flat store | Δ best / median |
| --- | --- | --- | --- |
| 1 | 3.205 / 3.248 | 3.071 / 3.140 | **−4.2% / −3.3%** |
| 32 | 1.613 / 1.661 | 1.561 / 1.630 | −3.2% / −1.9% |

Byte-identical `.drv` at w=1 and w=32; `zig build test` green (added
`FlatStore` round-trip / contiguity / capacity-error / concurrent-reserve
tests). The value/attr/attr_pos stores stay segmented (they hand out
`Range`s); only the object store moved.

## Uncurrying multi-arg lambdas + PAP (LANDED, byte-identical)

`compileLambda` historically compiled `a: b: body` as *nested* closures:
the outer chunk existed only to allocate an intermediate closure capturing
`a`, then call it with `b`. Every 2+-arg application paid a throwaway
closure alloc + frame (`call` 4.3M, `closure_captures` 1.8M on the
toplevel). Uncurrying merges an adjacent *value*-lambda chain into ONE
chunk with N params (`Chunk.arity = N`, capped at
`types.MAX_UNCURRY_ARITY = 4`); a nested lambda referencing an outer param
now captures it as a frame *local* instead of an upvalue — the alloc we
drop.

The calling convention stays additive via a **partial-application (PAP)**
value (`MISC_SUB_PARTIAL_APP` → `Object.partial_app = {func, args}`,
modeled on `builtin_closure`): applying one arg to an arity-N>1 closure
yields a PAP; applying to a PAP extends it or, at arity, runs the body.
`callValue` (the universal applier all builtins route through) handles
both, so `mapAttrs`/`map`/`foldl'`/overlays transparently get the merged
body via PAP saturation. A new `call_n N` / `tail_call_n N` op (emitted for
saturated syntactic spines `f a b`) runs the body in a single frame with
**zero** intermediate alloc on the fast path (`arity == N`);
`tail_call_n` reuses the current frame so deep multi-arg tail recursion
doesn't grow the stack. Under/over-application and non-closure callees fold
one arg at a time (same result).

PAP behaves as a function everywhere: `isFunction`/`typeOf "lambda"`,
`isCallable`, `functionArgs → {}` (merged value-lambdas carry no formal
metadata); JSON/XML/equality mirror the closure arms.

**Per-param strictness recovery (the piece that makes it pay).** A first
cut left uncurried-chunk args fully lazy (uncurried chunks don't carry the
single-param `strict_param`), so they became lazy thunks — extra allocs
that mostly cancelled the saved closure allocs (~0–1%), and an accumulator
like `go = acc: n: ... go (acc+n) (n-1)` built a thunk chain instead of the
eager `n` the curried form produced. Fix: `compileLambda` stamps a
per-param must-force bitmask `Chunk.strict_params` (`bodyMustForceName` per
param — the exact analysis the single-param `strict_param` uses), and the
saturated run sites (`call_n` fast path, `tail_call_n` reuse, PAP
saturation in `doCall`/`callValue`) eagerly force those arg positions
before the body runs. Value-preserving (sound must-force), and it
reproduces the curried form's eager-arg behavior exactly.

Spine args are compiled with a plain lazy thunk (`compileThunk`), **not**
the runtime-adaptive `apply_arg`: `apply_arg` decides eager-vs-thunk from
`stack[sp-1]`, which is the real callee only for the *first* spine arg
(later args would inspect the previous arg) — a latent
laziness/over-eager bug `call_n` flattening would otherwise introduce. The
`strict_params` forcing recovers the eager arg with the callee actually
known.

Controlled back-to-back A/B, n=12, vs `c7dfccd` (flat store):

| workers | flat store | + uncurry | Δ best / median |
| --- | --- | --- | --- |
| 1 | 3.132 / 3.186 | 3.105 / 3.138 | −0.9% / −1.5% |
| 32 | 1.576 / 1.624 | 1.544 / 1.583 | **−2.0% / −2.5%** |

Real and **transfers to w=32** (−2.5% median — the headline). Below the
hypothesized "leap past C++", but a solid critical-path win on top of the
flat store. Byte-identical `.drv` at w=1/w=32; tests green.
