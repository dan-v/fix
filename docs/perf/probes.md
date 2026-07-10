# Performance probes

*The instrumentation suite — quantify a lever's ceiling before building the optimizer.*

Every probe is a compile-time `-D` flag (see [build](../build.md)) and is **zero-cost when off**: each is a `build_options` boolean the compiler folds away, so the disabled build has no counters, no branches, no footprint. The cycle profilers keep their counters plain (no atomics): `-Dprof-main` writes only from worker 0, so it stays lock-free at any worker count — run it at `--workers=32` for the wait question and at `--workers=1` for the pathlength floor; `-Dprof-path` requires `--workers=1`, since its span nesting assumes a single fiber forcing LIFO. Results surface either through `--print-sched-stats` (see [cli](../cli.md)) or a written file.

The governing philosophy: **measure headroom before building.** Every dead-end in the [performance model](./model.md) was probed first — the probe told us the ceiling, and the ceiling told us not to build. The two live levers (deforestation, GC) are likewise the output of measurement.

## The suite

| flag | question it answers | output |
| --- | --- | --- |
| `-Dprof-main` | Where does main spend cycles, per C++-level op (e.g. `merge_attrs`, `force_value`, `do_call`), and **does main ever wait**? | rdtsc exclusive-cycle breakdown + piggyback censuses (below), via `--print-sched-stats` |
| `-Dprof-path` | What is the **force-call critical path** (per-chunk attribution), and what is the `w=∞` floor? | force-call tree + per-chunk self/span time, via `--print-sched-stats` |
| `-Dtimeline` | Per-worker **wall-clock timeline** — parse/compile/import phases, fiber-run quanta, idle parks, GC pauses | Perfetto JSON, written via `--timeline[=path]` |
| `-Dvm-opcode-profile` | Which **VM opcodes** execute most (raw dispatch counts) | per-opcode count table, sorted with each opcode's % of total, printed after evaluation |
| `-Dthunks-log` | What value did each thunk resolve to, and **where was it created** — for cross-run comparison | per-thunk lifecycle event log (create/claim/resolve/reset/errored/blackhole), written via `--thunks-log PATH`; two logs are compared with `fix thunks diff`, which reports the creator source locations whose resolve/errored/reset outcome multisets differ (keyed by creator location, which is stable across runs) |
| `-Dfiber-stack-probe` | **Peak fiber stack depth** — how much of each fiber's reserved stack is actually touched | sentinel-fills every fiber stack so `maxStackUsedBytes` can scan for the high-water mark |

### `-Dprof-main` and its piggyback censuses

`-Dprof-main` is the workhorse. Its core is a per-thread rdtsc stack profiler that charges each instrumented C++-level scope its **exclusive** cycles (inclusive delta minus time already attributed to nested instrumented scopes), so the printed number for a routine is time spent *inside it but not inside any inner instrumented routine* — the right shape for finding a bottleneck. Only worker 0 (main) updates counters; helpers pay one thread-local load + branch.

This is the probe that settled the floor question. At `--workers=32` main parks ~3× and waits ~2× while `force_value` drops from ~23M (w=1) to ~68K — it runs the whole serial chain end-to-end, and machinery is ~7% of the wall (see [model](./model.md)). A set of small counters ride the same flag, written only from worker 0:

- **Demand classification** — for each thunk main forces, was it *resolved-ahead* by a helper (win), *claimed by main* (main out-ran the helpers), or a *busy-wait* on a helper mid-compute; at a busy-wait, whether the awaited thunk was still speculative (a demand→spec promotion would pull it up).
- **Age-at-force** — the age of each thunk main claims, sizing the look-ahead ceiling of speculation.
- **Task-class census** — per scheduled work-item class: item counts, no-op rate, useful-cycle distribution.
- **Fiber cost/benefit** — dispatch + swap cycles per task vs. how many tasks suspend and the peak concurrent live-fiber count.
- **Attr-cache / thunk-memo / string** — inline-cache hit rates, thunk-result-memo hit and ineligibility breakdown, and string-machinery (`concat`) counts and bytes.

### `-Dprof-path`: the critical-path floor

`-Dprof-main` tells you which routines burn cycles, but not which *Nix source* the eval spends its time in, and nothing about the **critical path** — the longest chain of dependent thunk forces, the floor no worker count can beat. `-Dprof-path` runs at `--workers=1`, where forcing is cleanly nested (one fiber, LIFO on the C stack): every `forceThunkImpl` is a span containing exactly the spans of the thunks it forced, keyed by body chunk (≈ a Nix source location). Per span it computes `total` (subtree wall cycles), `self = total − Σ child totals`, and `span = self + max(child span)`. Using `max` (not `sum`) over children models the multi-worker floor — independent siblings would run in parallel — so the root `span` estimates what `w=∞` cannot beat. That floor lands ~0.43s vs. the ~1.7s w=32 wall: the gap is discovery-serialization, not throughput, and the top self-time bodies are module-system drivers (irreducible).

Attribution caveat: spans nest on thunk *forces* only, not on direct closure calls (`do_call`/`do_tail_call` keep running in the same dispatch loop). Work in a directly-called closure that forces no thunk is charged to the *forcing* chunk's self-time. Read the flat profile as "which forcing site drives the most call work", and use `-Dprof-main` for operation-level truth.

## `--print-sched-stats`

`--print-sched-stats` works in any build (it does not need a probe flag) and dumps the scheduler/registry/deferred counters plus worker utilisation and the speculation-precision census (of all resolved thunks, the undemanded fraction = speculative waste by count). When `-Dprof-main` or `-Dprof-path` is compiled in, this is also where their reports print.

## How a probe result becomes a decision

- **Ceiling low → don't build.** `-Dvm-opcode-profile` + dispatch calibration showed dispatch is ~1.5% of the wall (+10 instr/op ≈ +1.5–1.8%), killing superinstructions/fusion before any optimizer was written.
- **Ceiling high by wall → build (with A/B).** `-Dprof-main` at w=32 pointed the whole program at on-chain work-elimination (the layered-`//` and ATerm wins in [model](./model.md)).
- **Ceiling high by count/bytes, not wall → live but caveated.** Deforestation (single-use intermediates) and the GC RSS bound (see [gc](../gc.md)) are large by structure count / allocated bytes but need an optimizer with reach (or off-clock mark) to convert into wall/RSS.

See the [performance model](./model.md) for the full live/dead ledger.
