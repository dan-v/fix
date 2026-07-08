# Performance model

*Why the wall is dependency-chain depth, not throughput — and the only lever that moves it.*

The correctness oracle is byte-identical `.drv` (see [invariants](../invariants.md)); every figure below holds that fixed. Wall figures are on `test/nixos_toplevel.nix`, ReleaseFast, 32-core machine.

## The cost-model flip

The intuitive model — "parallel evaluator, so make the workers faster / do less redundant work" — is wrong for this workload. Measured reality:

- Cores are **mostly idle**. At `--workers=32`, helper [workers](../parallel/workers.md) are ~86% idle. Speculative CPU ([speculation](../parallel/speculation.md), [fanout](../parallel/scheduler.md)) is therefore **nearly free** — wasted spec work costs ~0 wall time because it runs on cores that had nothing to do.
- The real cost is **SCHEDULING / dependency depth**, not wasted work. A [fiber](../parallel/fibers.md)'s cost is run-to-completion latency on the critical chain, not the CPU it burns.

Consequence: "eliminate duplicate work" and "add more parallelism" are both largely inert. The wall is set by how deep the serial dependency chain is and how fast one worker walks it.

## The decisive finding: main is at the serial critical-path floor

`-Dprof-main` at `--workers=32` (records only worker 0, including waits/parks — see [probes](./probes.md)) settled the long-open "execution-speed problem or critical-path problem" question:

| main (worker 0) @ w=32 | count | meaning |
| --- | --- | --- |
| `wait_busy_thunk` | ~2 | blocked on a helper — **almost never** |
| `park_main_worker` | ~3 (~2 ms) | idle, queue empty — **almost never** |
| `force_value` | ~68K (vs **~23M** at w=1) | helpers offload **~99.7%** of forces |

**Main never waits.** It walks the entire critical chain end-to-end. Helpers offload ~99.7% of all forces — but only the work *off* the chain; the chain itself is a strict serial data-dependency main must traverse node by node, discovered just-in-time so helpers cannot get ahead of it.

**What's on the chain** (inherent to Nix semantics, not machinery):
- **drv-hashing DAG** — `derivationLazyAttr` computing outPath/drvPath SHA256 over the input-derivation graph (~477–828 drvs, ~3 ATerm serializations each), memoized O(N) via the [DerivationStore](../derivation/model.md) resolver. See [derivation/hashing](../derivation/hashing.md).
- **module-system fixpoint** — applying millions of user functions (`lib/modules.nix`) and option-merging the config tree. See [derivation/model](../derivation/model.md).

**Machinery is ~7% of the w=32 wall** (`run_isolated_frame` + `do_call` + `force_*` ≈ 100M excl cycles). That ~7% is the entire ceiling for any dispatch- or execution-speed optimization — the other ~93% is data-dependency latency the interpreter cannot outrun.

### Wall numbers

| config | wall | note |
| --- | --- | --- |
| w=1 serial | ~2.75s | throughput-bound |
| w=32 typical | ~1.7s | parallelism saturates by ~16 workers |
| w=32 best | ~1.25s | |

Parallelism buys ~0.69s of *earliness*, split ~50/50 between speculation and fanout — it does not raise the floor.

## The only lever: eliminate on-chain WORK

Since main runs the chain and never waits, the sole thing that moves the wall is removing real work *on the chain* (structurally — remove it, don't gate it behind a per-op runtime check, which taxes the hot majority). Landed wins, all byte-identical, all transfer to w=32:

| win | effect | doc |
| --- | --- | --- |
| layered `//` merge (O(1) layer node, k-way flatten) | ~-1.6% w=32; attr store -41% | [runtime/heap](../runtime/heap.md), [vm/access](../vm/access.md) |
| direct formal binding (skip binding cells) | ~-1.5% w=1 & w=32 | [vm/calls](../vm/calls.md) |
| frameless `attr_access` thunk (no frame/dispatch) | ~-2% w=32 | [runtime/thunks](../runtime/thunks.md) |
| ATerm bulk-copy on drv-hash path | ~-3.7% best w=32 | [derivation/hashing](../derivation/hashing.md) |
| lean thunk 64→48B | ~-2.4% w=32 | [runtime/thunks](../runtime/thunks.md) |
| thunk-result memo (skip recomputing same chunk+ups) | ~-2% w=32, ~-2.5–3% w=1 | [runtime/thunks](../runtime/thunks.md) |
| uncurry value-lambda chains + PAP + per-param strictness | ~-1.5% w=1 | [vm/calls](../vm/calls.md) |
| flat object store (`get(id)=base[id]`) | ~-3–4% w=1 | [runtime/heap](../runtime/heap.md) |
| trivial-body short-circuit (skip thunk alloc) | ~-5% w=32 | [compiler/lazy-compile](../compiler/lazy-compile.md) |

Cumulative session ~-5.5% w=32. The cheap and medium on-chain work-elimination wins are spent; the big remaining chain items (drv hashing, module user-fns) are inherent.

## Dead-ends — measured neutral or regressive, do NOT re-explore

| direction tried | measured result |
| --- | --- |
| Superinstructions / opcode fusion | Dispatch is ~1.5% of wall (ngram calibration: +10 instr/op ≈ +1.5–1.8%); fusion is sub-noise → [vm/dispatch](../vm/dispatch.md) |
| Locality: nursery / SoA / prefetch / THP | NOT memory-bound. cachegrind LL read-miss ~0% (working set fits L3). Bottleneck is instructions + dependent-latency + branch-mispredict (IPC ~1.2–1.5) |
| SHA-NI / faster crypto | Swap SHA256→free hash = w=1 0.6%, w=32 0%. drv-hash cost is ATerm build + encoding + alloc, not compression |
| Lazy-attr materialization (lazy mapAttrs, mapped_attrs object) | Byte-identical but +1–2% REGRESSION w=1 AND w=32 (merge materializes immediately) |
| Thunk-result memo past ≤2 upvalues | 3–4 ups ~0.1% redundant, 5+ ~0%, closure thunks 0 forces → nothing to gain |
| Import prefetch (speculative parse+compile) | +10–17% REGRESSION w=32 (helper compiles contend during discovery); harvest-only cap=0 neutral → can't break the serial-eval floor → [imports](../parallel/imports.md) |
| Burst dispatch / batched submit / long-spin | Wall-neutral or worse; wake/dispatch mechanics aren't the bottleneck — helpers idle because work doesn't exist yet |
| Deep-fanout / dedup of duplicate drv builds | drv frontier ~92% already resolved-ahead at w=32; in-flight dedup byte-identical + stable but WALL-NEUTRAL (dups off-path on idle helpers) |
| Parallel drv-hashing as an "option B" | ~95% of drv builds already run on helpers at w=32; main only ~5% — refuted; floor is serial module discovery |

## Live headroom

Both are large by **count / bytes**, not by wall — the opposite shape of an on-chain win — and both are caveated.

- **Deforestation.** The module fixpoint builds single-use intermediate lists and attrsets by the million and consumes most exactly once. The ceiling is by **count, not wall**; realizing it needs an optimizer with reach (targeted fusion, or a trace deforester), and a naive lazy-materialization attempt already regressed (see dead-ends).
- **GC for peak RSS.** The live set plateaus while total allocation grows linearly, so a collector bounds RSS (~-16% w=1; see [gc](../gc.md)). Mark is a wall tax, so the win is **RSS, not wall**.

## Methodology

1. **Measure headroom before building.** Every direction above was probed first — see [perf/probes](./probes.md). The philosophy is: quantify the ceiling of a lever before writing the optimizer.
2. **A/B at both ends.** Controlled A/B at w=1 (ReleaseFast, throughput floor) and w=32 (critical-path floor), back-to-back, best+median. w=1-only wins that don't touch the chain do not transfer.
3. **Byte-identical `.drv` gate, always.** Plus `zig build test`. A perf change that alters the store path is a bug, not a win.
4. **Probes run at `--workers=1`** — plain counters, no atomics, deterministic.
