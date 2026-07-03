# GC mutator-tax removal — audit findings (2026-07-03)

> **⚠ OUTCOME:** the per-site classification below is correct, but the overall
> effort was stopped — a later isolation experiment showed *all* rooting is only
> ~0.6% of wall (noise); the real `-Dgc` tax is per-alloc/safepoint bookkeeping.
> Only the two safe DELETEs were applied (access path-walks `1351a4c`,
> `applyBuiltin` loop `d384c46`); the `doCall` keep-on-stack conversion was
> abandoned. See `gc-tax-removal-plan.md` outcome note.

Converged result of a 6-subagent read-only audit of all ~90 `rootKeep`/`rootsBegin`
sites (see [gc-tax-removal-plan.md](gc-tax-removal-plan.md)). Each site classified
DELETE (redundant) / KEEP (load-bearing) / NEEDS-OP-CHANGE. The ReleaseSafe `-Dgc`
detector is the final oracle for every DELETE.

**Headline:** the win is smaller and more concentrated than the spec assumed. Two
clean, high-confidence deletions; the bulk of the per-call tax needs a fiddly
op-side conversion that should be gated on measurement; almost everything else is
genuinely load-bearing.

## DELETE — clean, no op change (Tier 1, high confidence)

- **`builtins.zig:43-45` — the `applyBuiltin` per-arg root loop.** Redundant: every
  caller already roots the args. Verified callers: `doCall`/`doTailCall`/`callValue`
  builtin branches (each `rootKeep`s its `arg`); `applyBuiltinClosure` (args reach
  transitively through the on-stack/rooted callee `builtin_closure` — trace map
  `gc.zig:154` follows `builtin_closure → args`); **`force.zig:617` `evalThunkClosure`**
  (args reach via the in-flight thunk on `gc_force_chain` — MUST confirm, or add a
  local `rootKeep(closure_val)`). Fires on every builtin call → the single biggest
  redundant-root deletion.
- **`access.zig` attr-path-walk roots** — 12 lines: `134,135,137,148`
  (`getAttrPathOrValue`), `154,155,157,168` (`getAttrPathDynamicOrValue`),
  `181,182,184,211` (`getAttrPathMixedOrValue`). Redundant: all three calling ops
  (`opGetAttrPathOr[Long]`, `...DynamicOr[Long]`, `...MixedOr`) keep the attrs (and
  default/dyn-name) operands on the operand stack for the whole helper and `sp -= N`
  only after; each `current` cursor is transitively reachable from the on-stack
  attrs via in-place-resolved attr edges. `hasAttrPath`/`hasAttrPathMixed` already
  carry no roots and are the proof-of-pattern. High confidence, no op change.

## DELETE — marginal, verify with detector (Tier 1b)

- **`builtins/strings.zig:93, 346, 430`** — the three `rootKeep(self, attrs)` arg
  re-roots in `coerceAttrsStringContextValue`/`coerceAttrsToStringValue`/
  `coerceDerivationAttrsToStringValue`. Redundant with the caller's arg root (the
  forced attrs is reachable through the builtin arg the caller roots). Low value
  (only `toString`/`toJSON` of `__toString`/`outPath` attrsets). Confirm via detector,
  incl. the JSON/XML-walk callers (`serial.zig:138/149`) where coverage is via the
  enclosing `writeJson/XmlAttrs` KEEP scope.
- **`objects.zig:65-68`** — strict-merge `//` roots left+right. Redundant
  (`opMergeAttrsStrict` keeps both operands on-stack; marking is transitive through
  the recursion). Low value; KEEP is equally defensible.

## DELETE — needs op conversion (Tier 2, RISKY — gate on measurement)

- **`closures.zig:435-438` `doCall` `arg` (and maybe `callee`)** + convert
  `opCall`/`opTailCall` to keep `[callee, arg]` on the operand stack across the call
  (drop+push result after — the `binTop`/`dropBin` shape generalized to a call).
  This is where the bulk of the **closure-call** tax lives (closure calls dominate
  nixpkgs eval), but:
  - The **closure/frame-push branch is fiddly**: `doCallN`'s saturated branch
    (`closures.zig:651-666`) is the working template — it keeps args on-stack, forces
    them in place, shifts the callee out, and `pushFrame`s. Its retained
    `rootKeep(callee)` at `:661` exists because the callee's `.upvalues` are read by
    `pushFrame` *after* the shift consumes its stack slot — so `callee` likely must
    stay rooted across the frame push even after conversion (only `arg` cleanly
    becomes the on-stack first-local).
  - JIT/tjit fast paths in `doCall` (`:451-466`) call with `arg` — on-stack retention
    covers them, but must be checked.

## KEEP — load-bearing (do not touch)

- `closures.zig:517,566` (doTailCall functor-walk `current` — freshly-produced
  attrsets, off-stack), `659-661` (doCallN callee, the template), `717-720`
  (`callValue` — called from many off-stack contexts: strict folds, functor
  recursion, builtins applying user fns; **and keeping these is what makes the
  `applyBuiltin`-loop deletion safe for map/filter/foldl re-entering via callValue**).
- `access.zig:24-26` (`callAttrFunctor` — functor held in a Zig local off-stack).
- **`equality.zig:91-116`** — reachable from the JIT trace executor
  (`jit/exec.zig:233` `.eq`), which passes operands from a `vals[]` buffer that is
  **NOT a GC root**. Under `-Dgc -Djit`/`-Dtjit` deleting these is a UAF. The
  bytecode callers (`opEq`/`opNeq`) *are* on-stack, so this only bites the JIT path.
  KEEP (low value); see landmine #1.
- All of `strings.zig` (8 sites), `builtins/string_context.zig`, `builtins/serial.zig`,
  `builtins/collections.zig` (map/genList/foldl' accumulators), `builtins/derivation.zig`,
  `builtins/fetch.zig`, `force.zig:244` (`forceDeepInner` deep-walk), `worker.zig:587`
  (speculative scheduler-task list, the `8f2fe1a` fix). All genuine off-stack
  new-object / raw-slice-across-force-walk roots.

## Cross-cutting landmines (must respect / document)

1. **The JIT executor (`jit/exec.zig`) has its own operand model** — a
   `vm.allocator`-alloc'd `vals[]` buffer that is NOT a GC root. Any shared helper
   reached from a JIT op that forces needs explicit roots. This blocks deleting
   `equality.zig`'s roots under `-Dgc+JIT`. Decision: KEEP equality roots (low value);
   document that `-Dgc` + `-Djit`/`-Dtjit` requires the JIT to root `vals[]` before any
   equality/merge/container-op roots can be shed.
2. **All DELETEs rest on: collection fires ONLY at the `forceThunk` safepoint**
   (`force.zig:403`), never mid-allocation / mid-`flattenMerge`. If a future change
   makes allocation itself collect, several deletions (and existing `hasAttrPath`)
   break. Treat as a load-bearing invariant.
3. **Pre-existing latent under-rooting in `strings.zig`** (separate bug, not this
   work): its `concatStringLike`/`mergeContextValues` do NOT root the running context
   accumulator, unlike the `string_context.zig` mirror (`:103,117-118,178-179`). A
   collection mid multi-entry context-merge could sweep an accumulated context value.
   Follow-up: port the mirror's accumulator rooting. Be conservative in `strings.zig`.
4. **Trust-but-verify:** the accumulators subagent wrongly reported `applyBuiltin`
   doesn't root args (it read the header, missed the loop at `:43-45`). Confirm claims
   against source.

## Refined strategy

`callValue`'s rooting stays (hot — every user-fn application in the module fixpoint),
so it **caps** the reduction achievable without the deeper Tier-2 conversion. Order:
land the two Tier-1 clean deletions (`applyBuiltin` loop + `access.zig` path walks),
run the gauntlet + measure the w=1 `-Dgc` mutator overhead, and only then decide
whether the fiddly Tier-2 `opCall` conversion (the closure-call tax) is worth the risk.
