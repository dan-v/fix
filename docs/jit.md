# JIT

*A generic tracing/inlining JIT that emits native x86-64 and stays byte-identical to the interpreter. STATUS: fully built, correct, native — and MEASURED-DEAD on nixpkgs (allocation-sink ceiling ~15 thunks/eval). Experimental, opt-in, off by default.*

Two experimental compilers gate behind build flags; the [interpreter](vm/dispatch.md) is canonical and always maintained:

| Flag | Kind | Verdict |
|------|------|---------|
| `-Djit` | legacy per-body (whole-chunk linear compile) | measured-dead — dispatch-only win, neutral/negative wall |
| `-Dtjit` | tracing/inlining (this doc) | built + correct + native + byte-identical; sink ceiling caps it at ~15 thunks → cannot beat the interpreter on nixpkgs |

**Invariant (load-bearing): the JIT never changes output.** Every native trace runs the *same* C-ABI helpers as the interpreter and is bit-exact; any guard failure deopts back to the interpreter, which is the correctness gate. `-Dtjit`/`-Djit` are off by default and can be removed without touching evaluation semantics.

## Mental model

The interpreter *watches itself* run a hot [chunk](compiler/pipeline.md). While it dispatches ops normally, a `Tracer` records a straight-line SSA trace of exactly what happened — following [`force`](runtime/thunks.md) and `call` edges *through* callee bodies by inlining them into one linear IR, with no VM call frame at trace time. Optimize the trace (the intended win is deleting thunk allocations whose results never leave the trace), lower a supported op subset to native code, and install it. Next time the chunk is entered hot, jump into native. When an observed assumption breaks (a guard), reconstruct the interpreter's frames from a snapshot and resume — output unchanged.

## Pipeline

```
hot-detect → record → optimize → codegen → execute
 (hot.zig)  (record/   (opt.zig) (codegen  (exec.zig
             recorder)            +linear)   + native)
```

### 1. Hot-detect — `hot.zig`
- One entry counter per chunk id. State machine `cold → armed → {traced | blacklisted}`.
- `cold → armed` is a single atomic CAS: exactly one worker wins and records the next execution through that chunk. Lock-free at any worker count; loads may be relaxed (a lost race just costs one extra count).
- On success the compiled-trace pointer is published atomically and the entry flips `traced`; the interpreter checks it on chunk entry and jumps in.
- Repeated recording aborts re-heat from cold, then give up (`blacklisted`) — the chunk is never retried.

### 2. Record — `record.zig` + `recorder.zig`
- The interpreter calls the recorder *before dispatching each op*; the recorder emits the corresponding SSA IR node.
- **Inline-frame stack (the key to inlining without VM frames):** a `call`/`force` pushes a recorder frame whose first local is the *caller's* argument `Ref`. Callee ops then read arguments straight out of the trace's dataflow — cross-boundary values thread through as SSA edges, so the trace observes one flat instruction stream with no interpreter frame.
- **Stop conditions:** trace-head re-entry (loop back-edge), length cap (~4K ops), an unsupported op, or unmodeled frame nesting.
- **Mid-inline truncation:** when an unhandled op is hit while only `call` frames are live, the recorder reconstructs the inlined call stack and emits a `side_exit` there. This lets *completed force-inlines survive* the abort — the prefix (including a sunk allocation) is kept instead of discarding the whole trace. `tail_call_n`/`call_n` are carved out of truncation (a frame-rebuild reconstruction bug, isolated).

### 3. IR — `ir.zig`
Linear SSA, `Ref = u32` indexes the producing instruction. Op families:

| Group | Ops |
|-------|-----|
| loads | `const_val`, `load_upvalue`, `load_upvalue_of`, `load_local`, `trace_arg` |
| lazy | `force` (guarded), `thunk_claim` (atomic), `thunk_resolve` |
| access/call | `get_attr` (guarded), `call` (guarded, inlined) |
| arith | `add_int`, `sub_int`, `mul_int`, `eq`, `lt`, `not` |
| alloc (sink candidates) | `alloc_thunk`, `alloc_attrs`, `alloc_list` |
| control | `guard`, `ret`, `side_exit`, `nop` |

**Guards** encode the assumptions the recording depended on: `thunk_resolved` / `thunk_claimed` (atomic — these guard [laziness](runtime/thunks.md) itself), `value_kind`, `attr_shape`, `chunk_id`, `bool_is`. Each guard carries a **`Snapshot`**: anchor down to the deepest inlined frame, live locals + operands per frame, and per-frame resume IPs — everything needed to rebuild the interpreter state at that point.

### 4. Optimize — `opt.zig`
- **Guard/force CSE:** redundant shape/`resolved` guards on the same SSA collapse; forcing the same `Ref` twice becomes one `force`.
- **Allocation sinking (the intended win):** an `alloc_thunk` used *only* by `thunk_claim`/`thunk_resolve`/upvalue-reads never escapes the trace — delete it, keep its fields in registers, and rebuild it *only* on a `side_exit`. Eliminates the create-and-consume thunk churn a fixpoint generates.
- const-fold, DCE, copy-prop.
- `sink_ceiling` counts allocs used only by force ops — these *would* be sinkable but need implicit-force inlining to reach; it measures the residual headroom (see status).

### 5. Codegen — `codegen.zig` → `linear.zig`
- Lowers a supported op subset to native x86-64 via the `linear.zig` `Emitter` (a proven substrate: stack-slot model, `Ref i → [rsp + i*8]`, C-ABI helper calls).
- Supported: arithmetic, attr/upvalue loads, inlined-`call`/thunk guards, `ret`, `side_exit`.
- Any unsupported op → codegen returns null → the trace falls back to the Zig executor. `native.zig` is the tracing layer that drives detection/record/install; `linear.zig` is the native substrate underneath.

### 6. Execute — `exec.zig` + native
- The Zig trace executor is the **correctness gate**: it interprets the trace IR using the *same helpers* as the interpreter → bit-exact. A guard failing here returns null → deopt.
- `sideExitImpl` reconstructs all active frames from a guard's `Snapshot` + live operands and resumes the interpreter *at the unhandled op*.
- Native `side_exit` runs through the `tjitSideExit` C-ABI helper (measured ~1.86M native side-exit runs, byte-identical) — so even deopting traces stay on the native path until the guard actually breaks.

## Status & ceiling — MEASURED-DEAD

The full chain is built, correct, native, and **byte-identical at w=1 and w=32**. It still cannot beat the interpreter on nixpkgs eval, and this is *measured, not predicted*:

- **Allocation-sink ceiling ≈ 15 thunks/eval.** Of ~377 `alloc_thunk`s appearing in *completed* traces, only ~15 are sinkable; ~362 **genuinely escape**. nixpkgs builds a **shared thunk graph** (a giant module fixpoint), not local create-and-consume — most thunks are referenced by other thunks outside the trace. See [perf/model.md](perf/model.md): the w=32 wall is a serial critical chain of inherent work, and the deforestation ceiling shows structures escape by the million.
- **Per-body JIT and superinstructions are separately dead:** dispatch is only ~1.5% of wall (see [vm/dispatch.md](vm/dispatch.md), the opcode-ngram calibration). A dispatch-elimination technique has nowhere to go.
- Truncated traces are reconstruct-bound (rebuilding inlined frames on side-exit, not interpreting the prefix), so the *only* possible net win is the sink — and the sink's ceiling is the workload's, ~15/eval → negligible.

**Conclusion:** a generic tracing/inlining JIT is architecturally complete and correct here, but the shared-graph structure of nixpkgs eval leaves no allocation to eliminate. The lever is a different eval strategy or on-chain work-elimination ([perf/model.md](perf/model.md)), not code generation.

See [docs/plans/tracing-jit.md](plans/tracing-jit.md) and [docs/plans/tjit-mid-inline-truncation-plan.md](plans/tjit-mid-inline-truncation-plan.md) for the design history.

Code: `src/jit/`
