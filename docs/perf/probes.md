# Performance probes

*The headroom-measurement suite — quantify a lever's ceiling before building the optimizer.*

Each probe is a compile-time `-D` flag (see [build](../build.md)), **zero-cost when off** (dead code, no runtime branch). Run at `--workers=1` so instrumentation uses plain counters — no atomics, deterministic, no scheduler interference. Each answers exactly **one** headroom question by instrumenting eval; results print via `--print-sched-stats` (see [cli](../cli.md)) or a written file.

The governing philosophy: **measure headroom before building.** Every dead-end in the [performance model](./model.md) was probed first — the probe told us the ceiling, and the ceiling told us not to build. The two live levers (deforestation, GC) are likewise the output of a probe.

## The suite

| flag | question it answers | output | finding it produced |
| --- | --- | --- | --- |
| `-Dprof-main` | Where does main spend cycles, per C++-level op (e.g. `merge_attrs`, `apply_builtin`), and **does main ever wait**? | rdtsc excl-cycle breakdown via `--print-sched-stats` | DECISIVE: at w=32 main parks ~3× / waits ~2× — it runs the whole serial chain end-to-end; machinery ~7% of wall. See [model](./model.md) |
| `-Dprof-path` | What is the **force-call critical path** (per-chunk attribution), and what's the `w=∞` floor? | force-call tree + per-chunk self-time | Prof-path floor ~0.43s vs ~1.7s wall = the gap is discovery-serialization, not throughput; top self-time bodies are module-system drivers (irreducible) |
| `-Dtrace-probe` | Per-thunk **read-count** (single-use vs shared) + body-size distribution → tracing-[JIT](../jit.md) sink ceiling | read-count histogram + body-size dist | ~66.8% of thunks single-use BUT completed traces expose only ~15 sinkable allocs/eval (~362 escape — SHARED thunk graph). JIT sink dead |
| `-Dstruct-census` | Per-list/attrset **consume-count** + producer→consumer pairs → deforestation ceiling | consume histogram + producer/consumer pairs | LIVE lever: ~83.5% lists / ~66.8% attrsets single-use intermediates (~2.4M structures). Ceiling by **count**, opposite the thunk sink ceiling. See [model](./model.md) |
| `-Ddrv-probe` | Derivation-build **demand shape**: attr resolved-ahead vs forced-inline, fanout ok/rejected, input-DAG depth/fan-in | per-attr resolution counters + DAG stats | drv frontier ~92% already resolved-ahead at w=32, 0 fanout rejections → deep consumer fanout dead; dedup off-path. See [derivation/model](../derivation/model.md) |
| `-Dopcode-ngram` | Hottest **adjacent fall-through opcode pairs** → superinstruction candidates | top opcode-pair frequency table | Calibration proved dispatch is ~1.5% of wall (+10 instr/op ≈ +1.5–1.8%); fusion sub-noise → superinstructions dead. See [vm/dispatch](../vm/dispatch.md) |
| `-Dtimeline` | Per-worker **wall-clock timeline** — phases, fiber quanta, idle parks | Perfetto JSON via `--timeline[=path]` | Visualizes the ~86% helper idle + main's uninterrupted chain walk; corroborates the prof-main floor. See [cli](../cli.md) |
| `-Dgc` (Phase-0) | **Reclaimable-RSS headroom**: mark-only live-set sampling, peak-live vs total-allocated | peak-live vs total-allocated report | ~81% reclaimable on nixos_toplevel (w=1: ~1208MB allocated vs ~228MB peak-live); live set plateaus while total grows linearly → GC justified for RSS. See [gc](../gc.md) |

## How a probe result becomes a decision

- **Ceiling low → don't build.** `trace-probe` (~15 sinkable) and `opcode-ngram` (~1.5% dispatch) each killed a JIT direction before a line of optimizer was written.
- **Ceiling high by wall → build (with A/B).** `prof-main` at w=32 pointed the whole program at on-chain work-elimination (the layered-`//` and ATerm wins).
- **Ceiling high by count, not wall → live but caveated.** `struct-census` (deforestation) and `gc` Phase-0 (RSS) are large by structure count / allocated bytes but need an optimizer with reach (or off-clock mark) to convert into wall/RSS.

See the [performance model](./model.md) for the full live/dead ledger, and [`docs/plans/perf-notes.md`](../plans/perf-notes.md) for the running A/B log each probe fed.
