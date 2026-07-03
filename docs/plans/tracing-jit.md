# Tracing/inlining JIT for fix

Generic machinery. It knows **nothing** about nixpkgs or the module system —
it records whatever executes hottest and compiles it to native code with
deopt guards. The NixOS module fixpoint just happens to be the hot thing, so
it benefits; swap the workload and the JIT re-specializes. (This is the
explicit anti-goal of the abandoned `native_lib` source-line port — see
`project_native_module_merge` memory.)

Build flag: `-Dtjit` (separate from the existing per-body `-Djit`, which is
measured-dead — see `project_jit_body_dead`). Off by default, zero-cost when
off, interpreter stays canonical.

## Why this can beat the ~5% dispatch bound

Calibration (`project_superinstructions_dead`) showed dispatch is only ~1.5%
of wall and ops are heavyweight (~570 native instr / VM op). A per-body JIT
and superinstructions both died because they only remove *dispatch* — the
work (allocation, forces, frames) stays.

The tracing JIT's lever is different and bigger: **allocation sinking + force
CSE across inlined call/force boundaries.** The module system's 280 cy/op is
dominated by *building intermediate thunks/attrsets that are immediately
consumed* (trace-probe: 66.8% of forced thunks are single-use; ~44% of all
thunks are never forced). On a trace, an allocation whose result never escapes
the trace is **elided entirely** — never built, kept in registers. That
attacks the heavyweight allocation work itself, not the dispatch around it.
This is the one optimization class neither per-body JIT nor fusion can do, and
it's why the real ceiling is plausibly well above 5%.

## The two esoteric problems no existing tracing JIT solves

### 1. Laziness — traces through `force`

A trace inlines through `forceValue`. Two cases, split by the trace-probe data:

- **Single-use thunk (66.8%)** — created and forced once, here. The recorder
  inlines the thunk body directly into the trace and emits a guard that the
  thunk is still unresolved + **atomically claims it** (same CAS on
  `future.state` as `forceThunkImpl`). If the claim fails (another worker beat
  us) → side-exit to the interpreter wait path. Because we inline the body, the
  thunk object itself is a sink candidate: if nothing else reads it, the
  allocation + claim + memo-store all vanish.
- **Shared thunk** — guard `state == resolved` (acquire load) → load
  `payload.result`. Never recompute (that would change cost/semantics). Guard
  failure (not yet resolved) → side-exit.

Soundness: the trace forces *exactly* what the interpreter would, at the same
points. No speculative over-forcing. The `demand` bit is threaded as a trace
parameter so speculative (helper) execution doesn't mark thunks demanded.

### 2. Parallelism — traces run on every worker/fiber

Compiled traces are immutable native code in the shared `CodeBuffer`, read by
all workers (like `jit_code` today). The novelty is the *guards touching
shared mutable state*:

- Thunk claim/resolve inside a trace uses the **identical lock-free protocol**
  as the interpreter (`thunk.zig` claim → compute → publish-with-release →
  wake waiters). A trace is just an alternate code path to the same protocol.
- Guard reads use acquire ordering matching the interpreter.
- A guard/claim failure mid-trace is a **side-exit**, never a block: spill live
  state and resume interpreting (the interpreter then parks/steals as usual —
  see `project_import_fiber_park`, `project_fiber_resume_race` for the hazards
  this must respect).
- A trace must be safe to abandon at any guard for fiber suspension. Side-exit
  state reconstruction (below) is the mechanism.

## Architecture

```
 interpreter (canonical)
    │  per-chunk force/call counter crosses HOT threshold
    ▼
 RECORDER ── follows execution, inlining through force/call ──► linear trace IR
    │  stop at: trace-head re-entry (loop), excessive length, blacklisted op
    ▼
 OPTIMIZER ── guard CSE · force CSE · allocation sinking · const-fold · DCE
    ▼
 BACKEND (extends src/jit/linear.zig emitter) ── linear-scan regalloc ──► native
    │  install: chunk.tjit_code = fn; interpreter dispatches it next entry
    ▼
 EXECUTE ── guards pass → straight-line native; guard fails → SIDE-EXIT
                                                    │
                                                    ▼  reconstruct VM state, resume interp
```

### Trace anchors (Nix isn't loopy)

Unlike Python/Lua bytecode loops, Nix's hot pattern is the recursive
force/merge walk. Anchor traces at **hot chunk entries** (thunk bodies +
lambda bodies): a per-chunk u32 counter in the registry, bumped at force/call;
crossing a threshold flips the chunk to "recording on next entry." A trace is
an acyclic inlined path from the anchor until it re-enters an anchor (treated
as a loop edge → linkable trace), exits the hot region, or hits limits.
Trace trees / linking (à la LuaJIT side-trace stitching) is phase 2.

### IR

Linear SSA. Op set: `const`, `load_upvalue`, `load_local`, `force`(guarded),
`get_attr`(guarded by shape/IC), `call`(guarded by chunk-id, inlined),
arithmetic/compare, `alloc_thunk`/`alloc_attrs`/`alloc_list` (sink candidates),
`guard_*`, `side_exit`. Each guard carries a **snapshot**: the abstract VM
state (operand-stack contents + frame/ip) needed to resume the interpreter.

### Side-exit / deopt

Each guard owns a snapshot mapping live IR values → their interpreter location
(operand-stack slot / local / upvalue). On exit, the stub writes live values
into the VM operand stack in the interpreter's expected layout, sets the frame
ip to the guard's bytecode position, and tail-jumps to interpreter dispatch.
Allocation-sunk objects that become live at a side-exit are **materialized
on-exit** (the standard "sink, but rebuild if you deopt" trick).

### Key optimizations (in dependency order)

1. **Guard CSE / strengthening** — one shape/resolved guard dominates repeats.
2. **Force CSE** — forcing the same SSA value twice is one force.
3. **Allocation sinking** — the headline. An `alloc_*` whose result doesn't
   escape the trace (not stored to a heap object that outlives the trace, not
   live at a taken side-exit) is removed; its fields live in registers.
   Rebuild lazily at side-exits that need it.
4. **Const-fold / DCE / copy-prop.**

## Build-out order

1. **Foundation**: `-Dtjit` flag; `src/jit/ir.zig` (IR + snapshot types);
   per-chunk hot counters + anchor detection; `tjit_code` field + dispatch
   hook (mirrors `jit_code` at `force.zig:355`, but always-compiled when tjit
   is on). Recorder records → prints IR (no codegen yet); validate trace shapes
   on the toplevel.
2. **Backend MVP**: codegen for guard-free straight-line traces (force CSE
   only), side-exit stubs, deopt reconstruction. Byte-identical `.drv` gate.
3. **Allocation sinking** — the win. Measure.
4. **Trace linking / side-traces**, polymorphic guards, inline caches in
   guards.

Correctness gate at every step: byte-identical `.drv` at w=1 **and** w=32
(`42da4061…f15`). Never perf-gated up front.
```
