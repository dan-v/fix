# Performance model

*Why the measured wall is dependency-chain depth, not throughput, and which lever moves it.*

The correctness oracle is byte-identical `.drv` (see [invariants](../invariants.md)); every figure below holds that fixed. Wall figures are point-in-time measurements from 2026-07-11 on `test/nixos_toplevel.nix`, ReleaseFast, on a 16-core/32-thread host; they are evidence, not performance guarantees.

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

**Main almost never waits on this snapshot.** It walks the critical chain end-to-end. Helpers offload ~99.7% of all forces — but only the work *off* the chain; the chain itself is a strict serial data-dependency main must traverse node by node, discovered just-in-time so helpers cannot get ahead of it.

**What's on the chain** (inherent to Nix semantics, not machinery):
- **drv-hashing DAG** — `derivationLazyAttr` computing outPath/drvPath SHA256 over the input-derivation graph (~477–828 drvs, ~3 ATerm serializations each), memoized O(N) via the derivation `Registry` hosted by the realization store. See [derivation/hashing](../derivation/hashing.md).
- **module-system fixpoint** — applying millions of user functions (`lib/modules.nix`) and option-merging the config tree. See [derivation/model](../derivation/model.md).

**Machinery is ~7% of the w=32 wall** (`run_isolated_frame` + `do_call` + `force_*` ≈ 100M excl cycles). That ~7% is the entire ceiling for any dispatch- or execution-speed optimization — the other ~93% is data-dependency latency the interpreter cannot outrun.

### Wall numbers

| config | wall | note |
| --- | --- | --- |
| w=1 serial | ~2.26s | throughput-bound |
| w=8 typical | ~0.61s | the sweet spot; w=16 matches it |
| w=32 typical | ~0.70s | parallelism saturates by ~16 workers on this 16c/32t host; the residual w>16 tax is scheduling/latency-shaped, not SMT, kernel, or footprint (2026-07-11 diagnosis) |

Parallelism buys ~0.69s of *earliness*, split ~50/50 between speculation and fanout — it does not raise the floor.

## The lever: eliminate on-chain work

Since main runs the chain and rarely waits, the direct lever on this workload is removing real work *on the chain* (structurally — remove it rather than adding a per-op runtime check). Landed wins, all byte-identical, all transfer to w=32:

| win | effect | doc |
| --- | --- | --- |
| layered `//` merge (O(1) layer node, k-way flatten) | ~-1.6% w=32; attr store -41% | [runtime/heap](../runtime/heap.md), [vm/access](../vm/access.md) |
| direct formal binding (skip binding cells) | ~-1.5% w=1 & w=32 | [vm/calls](../vm/calls.md) |
| frameless `attr_access` thunk (no frame/dispatch) | ~-2% w=32 | [runtime/thunks](../runtime/thunks.md) |
| ATerm bulk-copy on drv-hash path | ~-3.7% best w=32 | [derivation/hashing](../derivation/hashing.md) |
| then-current thunk compaction | ~-2.4% w=32 | [runtime/thunks](../runtime/thunks.md) |
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
| Burst dispatch / batched submit / long-spin | Wall-neutral or worse; wake/dispatch mechanics aren't the bottleneck — helpers idle because work doesn't exist yet |
| Deep-fanout / dedup of duplicate drv builds | drv frontier ~92% already resolved-ahead at w=32; in-flight dedup byte-identical + stable but WALL-NEUTRAL (dups off-path on idle helpers) |
| Parallel drv-hashing as an "option B" | ~95% of drv builds already run on helpers at w=32; main only ~5% — refuted; floor is serial module discovery |

## Remaining headroom

Both are large by **count / bytes**, not by wall — the opposite shape of an on-chain win — and both are caveated.

- **Deforestation.** The module fixpoint builds single-use intermediate lists and attrsets by the million and consumes most exactly once. The ceiling is by **count, not wall**; realizing it needs an optimizer with reach (targeted fusion, or a trace deforester), and a naive lazy-materialization attempt already regressed (see dead-ends).
- **GC policy for peak RSS.** The collector already bounds retained storage; budget and generation-policy changes trade pause cost against reserved memory. On this snapshot, `--gc-budget=512m` held nixos_toplevel at ~850 MB reserved versus ~1.4 GB with collection disabled. See [gc](../gc.md).

## Methodology

1. **Measure headroom before building.** Every direction above was probed first — see [perf/probes](./probes.md). The philosophy is: quantify the ceiling of a lever before writing the optimizer.
2. **A/B at both ends.** Controlled A/B at w=1 (ReleaseFast, throughput floor) and w=32 (critical-path floor), back-to-back, best+median. w=1-only wins that don't touch the chain do not transfer.
3. **Byte-identical `.drv` gate, always.** Plus `zig build test`. A perf change that alters the store path is a bug, not a win.
4. **`-Dprof-path` runs at `--workers=1`** (its span nesting assumes one fiber forcing LIFO); **`-Dprof-main` writes counters only from worker 0**, so they stay plain (no atomics) at any worker count — that is how it profiles main's serial pathlength at `--workers=32` (above) as well as at `--workers=1`.
