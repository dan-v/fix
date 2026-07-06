# Inlining + Demand-Directed Compilation — synthesis & staged plan

Status: **object-reduction thesis is measured-DEAD. Stage 1 census landed (86d535f); gate says STOP.**
Branch context: current working branch is `perf/thin-thunks`.

## MEASURED RESULT (Stage 1 census, `-Dthunk-census`, nixos_toplevel w=1)
`E` = unary-strict-builtin `apply_arg` × non-trivial arg = **9,435 = 0.21% of the 4.44M forced thunks** — an
order of magnitude under the pre-committed 2% GO gate. **STOP: Stage 2 formally abandoned by measurement.**
Corroborating: `arg=trivial` is 0 across every callee bucket (trivial args never reach `apply_arg` — the
trivial-body short-circuit already frees them), and the *entire* apply_arg thunk population (274,823) is only
6.2% of forced thunks — apply_arg is not even the dominant thunk source (attr values are). The feature is dead
by measurement, not argument, exactly as the adversarial design predicted.

---

## 0. Verdict (synthesizer)

Three independently-hardened designs (demand-first-minimal-inline, aggressive-inlining-IR, combinator-specialization),
each after two adversarial rounds *and code verification against this tree*, converge on the same conclusion:
**generic static inlining + demand-directed compilation cannot beat the graveyard on nixpkgs.** The reasons are
structural and confirmed in code, not speculative:

1. **The hot combinators are builtins or lib-inherited upvalues, not statically-visible callee bodies.**
   `mapAttrs`/`foldl'`/`zipAttrsWith`/`//`-merge resolve to `builtins.*` or `inherit (lib)` upvalues reached by
   attr-access — the compiler has no static edge to a body to inline. `calleeForcesArg` (closures.zig:167) returns
   `false` for every non-closure, so builtins never take the eager-arg path today. Runtime inlining across this
   boundary was already built (the tracing JIT) and hit `sink_ceiling ≈ 15/eval` — 362/377 alloc_thunks genuinely
   escape because nixpkgs builds a *shared* thunk graph. (memory: `project_tracing_jit`.)

2. **The dominant object population is inherently lazy.** 7.86M thunks (43% never forced), 1.85M attrsets, 1.37M
   lists. The bulk are attr-VALUE and list-ITEM thunks, routed through `unionIntoDeepOnly` in strictness.zig — they
   are *never* in a shallow/must-force set at their construction site because the consumer is a runtime-dispatched
   combinator in another module. Demand analysis at the producer site only knows lexical context; it legally cannot
   make these strict. The 43%-never-forced margin *must* stay lazy (forcing changes termination/error behavior).

3. **The one static handle co-occurs with already-object-free arguments.** The only *new* statically-recognizable
   sound strict promotion is on directly-written `builtins.<unary-strict>` calls. But bare-identifier args
   (`length xs`) already hit `compileImmediateContainerValue` (no thunk), and trivial-body args short-circuit in
   `makeBytecodeThunkFromCaptures` (closures.zig:128-152, no `addBytecodeThunk`). The residual is
   `builtins.<unary-strict> (non-trivial-expr)` — a leaf-accessor micro-op, not an HOF-boundary lever.

This is exactly the graveyard pattern: local/static optimizations have limited reach because nixpkgs is dynamic
(higher-order, cross-module) and the dominant objects are inherently lazy. Cardinality inlining (0.03%), deforestation
views (wall-neutral), thin thunks (unsound), sparks (no gain) all died here. Threaded demand + generic inlining joins
them for the same measured reason.

**Chosen design = the smallest worthwhile subset, gate-driven:**
- **Ship Stage 1** — a per-producer thunk census + `apply_arg` callee-bucket census + a `tryEval`/reorder soundness
  fuzzer. Cheap, byte-identical (no eval-path change), reusable, and it produces the empirical go/no-go signal that
  converts "the wall is unreachable" from an argument into a recorded measurement. This is the primary deliverable.
- **Stage 2 is conditional and narrow** — the single sound, buildable, verified-not-already-covered micro-lever:
  single-arg strict-*builtin* eager args (extend `calleeForcesArg`, reuse `evalArgEager`). Built *only if* Stage 1's
  addressable count clears a pre-committed threshold AND w=32 wall does not regress. Expected outcome per the code:
  it does not clear the threshold, and Stage 2 is formally abandoned by measurement.
- **Stage 3 (demand-threading refactor) and §G are NOT recommended by default** — a real compile-time cost for a
  measured-zero object win, and a fix for a non-manifesting bug. Kept documented as optional substrate only.

Do **not** build: the demand lattice through ~25 `compileNodeImpl` handlers (unless the team explicitly wants the
substrate for future work), any body inliner / cross-import splice / user-`lib` specialization (T2/T3/T4), multi-arg
builtin strict-arg (K≥2 routes through `call_n`/`callValue`, not `apply_arg`), any `deep`-demand emission outside
literal `deepSeq`/`forceDeep`, or `mapDeep`/`mapAttrsDeep`.

---

## 1. Ordered stages (one line each)

- **Stage 1 (SHIP NOW):** per-producer thunk census + `apply_arg` callee-bucket census + call-site-shape census + `tryEval`/reorder fuzzer — pure instrumentation, byte-identical, produces the go/no-go number.
- **Stage 2 (CONDITIONAL on Stage 1 gate):** single-arg strict-*builtin* eager args — extend `calleeForcesArg` with a comptime unary-strict-builtin table + reuse `evalArgEager`; the only sound object-eliding increment.
- **Stage 3 (OPTIONAL, not recommended by default):** thread a `Demand` lattice through `compileNode` as a byte-identical structural refactor unifying today's scattered elision hints — substrate only, ~0 object win, net compile-time cost.
- **§G (OPTIONAL correctness hardening, low priority, NOT banked):** narrow the multi-binding must-force let-elision to first-demanded-only, closing a non-manifesting source-order caught/uncaught reorder hole.

---

## 2. STAGE 1 — measurement probe (fully specified, implementable now)

### Goal
Produce, from a live `test/nixos_toplevel.nix --workers 1` run, three numbers that decide whether *any* demand/inline
object lever is worth building, plus a permanent soundness regression asset. All additive, behind a build flag, zero
eval-path change ⇒ byte-identical at w=1 and w=32 by construction.

### 1a. Per-producer thunk census (the decisive number)
**Mechanism.** Mirror the existing `src/runtime/struct_census.zig` producer-tag machinery (already proven for
lists/attrs) onto the thunk-creation path. Add a new probe module `src/probe/thunk_census.zig` (template:
`struct_census.zig` + `src/probe/trace_probe.zig`) that records, per created thunk object-id, a **producer bucket**:
`{ attr_value, list_item, apply_arg, let_binding, with_scope, or_default, attr_param, other }`.

- **Tagging.** The compiler already knows the construct at each thunk site. Thread a lightweight producer tag the same
  way `struct_census.setProducer`/`restoreProducer` bracket container construction — but here set it at the
  *compile-site → runtime* boundary. Cheapest correct implementation: stamp the producing op with a
  `producer_kind: u8` and record it in `recordBytecodeThunkCreate` (closures.zig:344) and the two other
  `recordBytecodeThunkCreate` call sites (closures.zig:155, 248, 337). Since the census runs at w=1, a global
  `producer_tag` (as `struct_census` does) set by the emitting op immediately before `thunk_captures*`/`apply_arg`
  dispatch is sufficient; simplest is to derive the bucket from the *chunk's* origin recorded at compile time (add a
  `producer_kind` field to the thunk-body `Chunk` scheduling metadata, set in `compileThunk`/`compileApplyArgThunk`/
  the attr/list value paths). Prefer the compile-time-stamped `Chunk` field: it is race-free and needs no runtime
  global.
- **Read count.** Reuse the `trace_probe` read-count histogram (force.zig:208 already calls `recordRead`) but bucket
  by producer_kind, so the report gives, per producer: allocated / never-forced / single-use / shared.
- **Report.** Extend the census `report()` to print the per-producer breakdown of the 7.86M created / 4.44M forced
  thunks. This is the artifact no prior probe has produced: it sizes the attr-value/drv-arg population exactly.

**Files:** new `src/probe/thunk_census.zig`; `build.zig` (add `-Dthunk-census` option, mirror lines 16/37);
`src/bytecode/chunk.zig` (add `producer_kind: ProducerKind = .other` to thunk scheduling metadata);
`src/compiler/thunks.zig`, `src/compiler/attrs.zig`, `src/compiler/access.zig`, `src/compiler/ops.zig`
(stamp `producer_kind` at each `compileThunk*` site); `src/vm/closures.zig` (record it in `recordBytecodeThunkCreate`
and at `makeBytecodeThunkFromCaptures`); `src/cli/stats.zig` (wire report).

### 1b. `apply_arg` callee-bucket census (sizes the Stage-2 addressable set)
**Mechanism.** In `opApplyArg` (run.zig:594-611), behind the same flag, bucket every executed `apply_arg` by callee
shape at `vm.stack[vm.sp-1]`: `{ concrete_unary_strict_builtin, other_builtin, strict_closure, other_closure,
non_callable }` × `{ arg_trivial_body, arg_thunk_worthy }`. The exact eliminable Stage-2 count = concrete unary-strict
builtin × thunk-worthy arg. Determine `arg_trivial_body` from `registry.get(ch_id).scheduling.trivial != .none`
(the same check `makeBytecodeThunkFromCaptures` uses).

**Files:** `src/probe/thunk_census.zig` (counters + report); `src/vm/run.zig` (`opApplyArg` records the bucket).

### 1c. Call-site-shape census (confirms the lib boundary is opaque)
**Mechanism.** At `call`/`call_n` dispatch, bucket callee resolution: `{ ambient_builtin, builtins_dot,
local_lambda, upvalue_closure, attr_access_closure, with_lookup }`. Confirms empirically that hot combinators resolve
as upvalue/attr-access closures (`inherit (lib)`), i.e. no static body to inline. Cheapest at compile time: stamp the
call op's resolution class in `compileApplyWithOp`/`compileIdent` and count at runtime, or count purely at runtime
from the callee Value kind. Runtime-only is simpler and sufficient.

**Files:** `src/probe/thunk_census.zig`; `src/vm/run.zig` (call/call_n handlers).

### 1d. `tryEval`/reorder soundness fuzzer (permanent regression asset)
**Mechanism.** A test generator (new `test/fuzz_strictness.zig` or a `src/tests/` module wired into `build.zig` test
step) that emits random strict-context expressions mixing caught (`throw`/`abort`/`assert`/missing-file) and uncaught
(`1/0`, type errors) failures across multi-binding `let`, `if`, `&&`/`||`/`->`, `with`, `x.a or d`, and differentially
compares `.drv`/error outcome against the current build **and** the Lix oracle (system nix = Lix 2.95.2, per memory
`reference_lix_oracle`). Retained permanently: any future strictness/demand work regresses against it. Crucially it
exercises the caught/uncaught partition from FINDINGS-3 §G (the source-order eager-elision hole).

**Files:** new fuzzer module; `build.zig` test wiring (mirror the test-wiring fix from memory
`project_unit_test_coverage_sweep`).

### Soundness gate (Stage 1)
No emitted-bytecode change; census is compile-time metadata + runtime counters behind `-Dthunk-census`; the fuzzer is
test-only. Byte-identity is trivial and enforced: **a non-flagged build must produce byte-identical `.drv`**
(the `producer_kind` chunk field must not alter any code bytes — assert `Chunk.code` unchanged by adding a debug
comparison of a flagged vs non-flagged compile of `nixos_toplevel.nix`).

### Measurement (Stage 1)
1. `.drv` equality: `-Doptimize=ReleaseSafe` build (no flag) vs pre-change, `--workers 1` and `--workers 32`, diff the
   emitted `.drv`. Must be byte-identical.
2. `-Dgc` ReleaseSafe gauntlet: run the GC root/edge verifier at w=1 and w=32 (the census flag OFF for this — it is a
   correctness gauntlet on the shipped path).
3. Run `-Dthunk-census --workers 1` on `test/nixos_toplevel.nix`; record the per-producer thunk table (1a), the
   `apply_arg` callee-bucket table (1b), the call-site-shape table (1c).
4. Run the fuzzer (1d) to N≥100k cases; must be 0 divergences vs current build and vs Lix.

### Go/No-Go (Stage 1 → Stage 2) — PRE-COMMITTED
Let `E` = eliminable Stage-2 set = (concrete unary-strict-builtin callee) × (thunk-worthy, non-trivial arg) from 1b,
as a fraction of the 4.44M forced thunks.
- **GO to Stage 2 iff `E ≥ 2%` of forced thunks.** (Below 2% it is another cardinality-class 0.03% niche and not worth
  a correctness budget.)
- **Else: STOP.** Land Stage 1, write the memory note recording that the drv-arg/attr-value thunk population is past
  the static wall (reachable only by real cross-`lib`-boundary inlining, which this project's tracing-JIT sink ceiling
  already showed does not pay), and do not spend budget on Stages 2/3. **This is the expected outcome** given
  closures.zig:128 (trivial args already free) + the builtins-are-not-ambient-resolvable wall.

---

## 3. Stage 2 — single-arg strict-builtin eager args (CONDITIONAL)

Build **only if** Stage 1 gate says GO.

**Mechanism.** Extend `calleeForcesArg` (closures.zig:167) so that when `callee.isBuiltin()` and the builtin id is in
a comptime `BUILTIN_UNARY_STRICT` table, it returns `true`; then `opApplyArg` (run.zig:605) already routes to the
no-alloc `evalArgEager` path. No new op, no new object kind, no GC surface (reuses the `strict_param` eager path that
is already `-Dgc`/w=32-proven).

**Admissible table (each entry hand-proved against its `src/vm/builtins/*` body):** arity==1, unconditionally forces
its sole arg to WHNF on every path, and **never forces inside a catch/error-transform** (excludes `tryEval`,
`addErrorContext`). Candidates: `head`, `tail`, `length`, `attrNames`, `attrValues`, `stringLength`, `typeOf`, the
`is*` predicates, `floor`, `ceil`. **Excluded** (force a non-trigger position first / K≥2 / catch): `map`, `filter`,
`elemAt`, `getAttr`, `foldl'`, `seq`, `deepSeq`, `hashString`, `tryEval`, `zipAttrsWith`, `mapAttrs`.

**Soundness gate.** Each entry carries a one-line proof of (arity-1 ∧ unconditional-force ∧ not-in-catch). Because
arity is 1, there is no sibling-arg reorder hazard: `apply_arg` executes ⟺ saturating WHNF is demanded ⟺ the unary
force-first builtin forces the arg anyway. Non-saturating partial applications never eager-fire. `.drv` byte-identical
at w=1 AND w=32; `-Dgc` gauntlet clean.

**Measurement.** `-Dthunk-census` thunk count drops by ~`E`; `.drv` identical w=1/w=32; **w=32 wall non-regression**
(Stage-2 removes a speculation opportunity for `body_is_substantial` args by running them synchronously — since
speculation ≈ 50% of the parallel win, "forced-anyway ⇒ wall-neutral" is not guaranteed; measure, do not assume);
`FIX_MEM_REPORT` RSS.

**Go/No-Go (ship Stage 2).** Ship iff: `.drv` byte-identical both workers, gauntlet clean, thunk count measurably
down, AND w=32 wall not worse than noise. If w=32 regresses (lost speculation), gate the eager path to
`!body_is_substantial` args or revert.

---

## 4. Stage 3 — demand-threading refactor (OPTIONAL, not recommended by default)

Thread `demand: Demand = {lazy, whnf, deep}` through `compileNode`/`compileNodeImpl` (compiler.zig:188-227),
generalizing today's scattered elision (`compileLetInBody` must-force elision ops.zig:842; `directlyAppliedStrictLambda`
ops.zig:420; `strict_param`/`strict_params`). **Byte-identical by construction** (default `lazy`, degrade-to-`lazy` at
every red-line: `&&`/`||`/`->`-right, untaken `if` branch, `assert`-body, `with`-scope/body, `x.a or d`, recursive
cells, structural builders via `isEagerEvalShape`, `tryEval` barrier; demand resets to `lazy` at every chunk boundary
and the deferred-attr boundary).

**Why not recommended by default:** it is a large per-site-manual-proof change (~25 handlers + thunk builders) that
adds a second top-down demand pass on top of the retained bottom-up `strictness.analyzeInto`, landing on the hottest
w=1 phase (compile ~10% of wall, identifier resolution ~13%). Object win over Stages 1–2 is **~0** — every strict
context it can see statically either is already elided or takes an already-object-free arg. Build it **only** if the
team wants a single strictness substrate for future eval-strategy work, judged on that merit, not on object count.

**Gate if built:** `shallow_must` oracle-equality assertion (ReleaseSafe); `.drv` byte-identical w=1/w=32; gauntlet
clean; compile-time non-regression (measure — this is the real risk).

---

## 5. §G — narrowed let-elision (OPTIONAL correctness, low priority, NOT banked)

FINDINGS-3 §G: `compileLetInBody` (ops.zig:838-848) evaluates must-forced `.uncaptured` bindings in **source order**,
which can reorder a caught error ahead of an uncaught one across a `tryEval` boundary
(`let a = throw "A"; b = 1/0; in b + a`). Non-manifesting on `nixos_toplevel` (current build byte-identical). The only
sound fix is a **narrowing**: elide only the *first-demanded* must-force binding, keep the rest lazy (never reorder two
eager bindings whose error partitions are statically incomparable). This costs objects, not saves them. Justify purely
on correctness; do not fold into any object-reduction claim; low priority since it fixes a latent, non-triggering bug.
Ship only with the Stage-1 fuzzer (1d) exercising the hoisted case.

---

## 6. Correctness bar (all stages)

Every landed stage: byte-identical `.drv` for `test/nixos_toplevel.nix` at `--workers=1` AND `--workers=32`; passes the
`-Doptimize=ReleaseSafe -Dgc` verifier gauntlet (GC root/edge completeness). Nix laziness preserved: eager evaluation
only where a sound must-force under-approximation proves it cannot turn success→error, termination→non-termination, or
change which observable error-class surfaces (the `tryEval` caught set `{throw, abort, assert, FileNotFound}` treated as
one indistinguishable class; every other error and each `trace`/side effect as itself). Stage 1 is correctness-inert by
construction; Stage 2 rests on the arity-1 invariant; Stage 3 on degrade-to-lazy; §G on strict narrowing.
