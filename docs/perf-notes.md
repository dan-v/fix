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
