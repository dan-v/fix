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
