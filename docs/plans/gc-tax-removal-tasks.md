# GC Mutator-Tax Removal — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the redundant `-Dgc` mutator rooting tax (~5.6% w=1) by deleting `rootKeep` calls whose value is (or can be kept) on the operand stack, keeping only genuinely off-stack roots — byte-identical output throughout.

**Architecture — one rule, three buckets.** The operand stack is a precise GC root. A `rootKeep` is only needed when a live value is *off* the stack across a force. So for each site:
1. **Already on the stack → delete the `rootKeep`.** (No other change.)
2. **Popped off the stack → keep it on instead (force in place, drop after), then delete the `rootKeep`.** (This is what removes `doCall`'s roots and the `applyBuiltin` arg-loop.)
3. **Genuinely off the stack (a new object built in a Zig local) → keep the `rootKeep`.**

Primitives already exist: `stack.binTop`/`dropBin`, `force.forceTop`/`forceAt`; exemplars `opAddInt`, `doCallN`.

**Tech Stack:** Zig, the `fix` evaluator; `-Dgc` comptime flag; ReleaseSafe `-Dgc` UAF detector; `test/nixos_toplevel.nix` as the byte-identical oracle.

**Design + audit:** [gc-tax-removal-plan.md](gc-tax-removal-plan.md) (spec), [gc-tax-removal-audit.md](gc-tax-removal-audit.md) (per-site verdicts). Read both first.

## Global Constraints

- **Byte-identical output is the bar** — with `-Dgc` on (ReleaseSafe + ReleaseFast) and off, w=1 and w>1. Any diff = revert that deletion.
- **A wrong deletion is a use-after-free** (nondeterministic at w>1 / ReleaseFast). The ReleaseSafe `-Dgc` detector (reuse-off + alloc-bit assert + swept-range poison) is the oracle — it traps a missing root at the read.
- **`-Dgc` is comptime-gated**; the normal build stays byte-for-byte unaffected.
- **Don't touch a bucket-3 KEEP site** (list at the bottom) or the load-bearing GC invariants (non-moving, single-owner ranges, token-per-collection — see gc-plan.md).
- **Branch `gc-tax-removal`** off `main`; commit after each green task.

---

## Validation Protocol (the "test" for every deletion task)

Run at the end of each task; all must pass before commit.

- [ ] **V1 — normal build byte-identical + tests:**
  ```bash
  zig build -Doptimize=ReleaseFast
  ./zig-out/bin/fix --file test/nixos_toplevel.nix --workers=1 > /tmp/gc-tax-cur.txt 2>/dev/null
  diff /tmp/gc-tax-baseline.txt /tmp/gc-tax-cur.txt && echo "V1 OK"
  zig build test 2>&1 | tail -5
  ```
- [ ] **V2 — ReleaseFast `-Dgc` byte-identical at several thresholds** (reuse ON exposes a missing root as corruption):
  ```bash
  zig build -Dgc -Doptimize=ReleaseFast
  for mb in 0 600 256 64 8; do
    FIX_GC_STEP_MB=$mb ./zig-out/bin/fix --file test/nixos_toplevel.nix --workers=1 > /tmp/gc-tax-gc-$mb.txt 2>/dev/null
    diff /tmp/gc-tax-baseline.txt /tmp/gc-tax-gc-$mb.txt && echo "V2 step=$mb OK" || echo "V2 step=$mb FAIL"
  done
  ```
- [ ] **V3 — ReleaseSafe `-Dgc` detector, 0 UAF, aggressive threshold** (the decisive check):
  ```bash
  zig build -Dgc -Doptimize=ReleaseSafe
  FIX_GC_STEP_MB=8 ./zig-out/bin/fix --file test/nixos_toplevel.nix --workers=1 > /tmp/gc-tax-safe.txt 2>/tmp/gc-tax-safe.err
  diff /tmp/gc-tax-baseline.txt /tmp/gc-tax-safe.txt && echo "V3 byte-identical OK"
  grep -c "use-after-free" /tmp/gc-tax-safe.err || echo "V3 no UAF"
  ```
- [ ] **V4 — w>1 byte-identical** (call machinery is shared with speculative forcing), ×30:
  ```bash
  zig build -Dgc -Doptimize=ReleaseFast
  for i in $(seq 1 30); do
    FIX_GC_WN=1 FIX_GC_STEP_MB=64 ./zig-out/bin/fix --file test/nixos_toplevel.nix --workers=32 --no-progress > /tmp/gc-tax-w32-$i.txt 2>/dev/null
    diff /tmp/gc-tax-baseline.txt /tmp/gc-tax-w32-$i.txt >/dev/null || echo "V4 run $i FAIL"
  done; echo "V4 done"
  ```

If any step fails: the deletion removed a load-bearing root. Revert that specific deletion, re-run V3 green, and reclassify the site as KEEP (bucket 3) in the audit doc with the failure noted.

---

## Task 0: Branch + baseline

- [ ] **Step 1: Branch off main**
  ```bash
  git checkout -b gc-tax-removal
  ```
- [ ] **Step 2: Commit the design/audit/plan + the depth-0 probe already in the tree**
  ```bash
  git add docs/plans/gc-tax-removal-plan.md docs/plans/gc-tax-removal-audit.md docs/plans/gc-tax-removal-tasks.md \
          src/probe/depth0_probe.zig build.zig src/vm/access.zig src/eval.zig src/vm/force.zig
  git commit -m "docs(gc): mutator-tax removal spec + audit + depth-0 safepoint probe"
  ```
- [ ] **Step 3: Capture the byte-identical baseline** (deterministic regardless of flags)
  ```bash
  zig build -Doptimize=ReleaseFast
  ./zig-out/bin/fix --file test/nixos_toplevel.nix --workers=1 > /tmp/gc-tax-baseline.txt 2>/dev/null
  wc -l /tmp/gc-tax-baseline.txt
  ```
- [ ] **Step 4: Record the starting mutator overhead** (the tax to remove): 0-collection `-Dgc` vs no-`-Dgc`, best of 5.
  ```bash
  zig build -Dgc -Doptimize=ReleaseFast
  FIX_GC_STEP_MB=100000 ./bench.sh gc-0collect-before 1 5    # huge step ⇒ ~0 collections; the GC report should confirm collections: 0
  zig build -Doptimize=ReleaseFast && ./bench.sh nogc-before 1 5
  ```
  Record both medians; the gap is the tax.

---

## Task 1 — Bucket 1: delete the already-on-stack roots (clean, no conversion)

These ops already keep their operand on the operand stack across the whole helper; the `rootKeep`s are pure deletes.

**Files:**
- Modify: `src/vm/access.zig` — the attr-path-walk roots in `getAttrPathOrValue` (134,135,137,148), `getAttrPathDynamicOrValue` (154,155,157,168), `getAttrPathMixedOrValue` (181,182,184,211).
- Modify (optional, marginal): `src/vm/objects.zig:65-68` (strict-merge `//`).
- Verify (read): `src/vm/run.zig` — the calling ops keep the attrs (+ default/dyn-name) operands on the stack and `sp -= N` only after the helper returns (`hasAttrPath` at `:971` is the no-roots reference).

- [ ] **Step 1:** Read the three calling ops; confirm each keeps `attrs_val` (and any default/dyn-name operands) on the stack across the helper (`const attrs_val = vm.stack[vm.sp - N]; ... helper ...; vm.sp -= N`).
- [ ] **Step 2:** Delete the 12 `rootsBegin`/`defer rootsEnd`/`rootKeep(current)` lines in `access.zig`. Leave the `forceValue`/`cachedAttrLookup` calls untouched.
- [ ] **Step 3 (optional):** Delete `objects.zig:65-68` only if you want the marginal strict-merge saving (`opMergeAttrsStrict` keeps both operands on-stack; marking is transitive). If any doubt, leave as KEEP.
- [ ] **Step 4:** Run the Validation Protocol (V1-V4). These ops run mid-fixpoint at deep `native_depth`, so V3 with `FIX_GC_STEP_MB=8` exercises them hard.
- [ ] **Step 5: Commit**
  ```bash
  git add src/vm/access.zig src/vm/objects.zig
  git commit -m "perf(gc): drop attr-path-walk (and strict-merge) roots — operand stays on stack"
  ```

---

## Task 2: Measure the clean win

- [ ] **Step 1:** Re-measure the mutator overhead exactly as Task 0 Step 4. Record medians.
- [ ] **Step 2:** Note how much of the tax bucket 1 removed. (Bucket 2 is the bigger, fiddlier lever; this tells you the starting point before taking that risk.)

---

## Task 3 — Bucket 2: keep call operands on the stack, delete the roots that compensated

The call machinery pops callee+arg into locals, which is *why* `doCall`/`applyBuiltin` root them. Keep them on the stack across the call and the roots go. Do it in the smallest reversible steps; lean on V3/V4 after each. `doCallN`'s saturated branch (`closures.zig:651-666`) is the working template for the frame-push case.

**Files:**
- Modify: `src/vm/run.zig` (`opCall`/`opTailCall`), `src/vm/closures.zig` (`doCall`/`doTailCall`), `src/vm/builtins.zig:43-45` (the `applyBuiltin` arg-loop), optionally `src/vm/builtins/strings.zig:93,346,430` (arg re-roots that become stack-covered).

- [ ] **Step 1 — non-frame branches first.** Convert `opCall` to leave `[callee, arg]` on the stack; in `doCall`'s `isBuiltin`/`isPartialApp`/`isBuiltinClosure` branches compute `result` then `stack.dropBin(self); stack.push(self, result)`. Leave the closure branch and `doCall`'s `rootKeep`s for now.
- [ ] **Step 2 — delete the `applyBuiltin` arg-loop.** With builtin-call args now on the stack (and `callValue`/`doTailCall` still rooting theirs — bucket 3), `builtins.zig:43-45` is redundant; delete it (drop the now-dead `vm_force` import only if unused elsewhere — grep first). Confirm the `force.zig:617` `evalThunkClosure` path is covered (args reachable via the in-flight thunk on `gc_force_chain`; add a local `rootKeep(closure_val)` there if not).
- [ ] **Step 3:** Validation Protocol V1-V4. Expected green. **Commit.**
  ```bash
  git commit -am "perf(gc): keep builtin-call operands on the stack, drop applyBuiltin arg-loop"
  ```
- [ ] **Step 4 — measure.** Re-run Task 0 Step 4. This is the checkpoint before the fiddliest change.
- [ ] **Step 5 — the closure/frame-push branch.** Convert `doCall`/`doTailCall`'s closure branch using the `doCallN` template: keep args on-stack, `forceStrictArgs` in place, shift the callee out, `pushFrame` reusing the on-stack arg as first local; retain `rootKeep(callee)` across the `forceStrictArgs`/`pushFrame` window (the callee's `.upvalues` are read after its slot is consumed — see `doCallN:661`). Handle the JIT/tjit fast paths (`closures.zig:451-466`) — on-stack `arg` covers them.
- [ ] **Step 6 — delete `doCall`'s `rootKeep(arg)`** (`:438`); keep `rootKeep(callee)`. Optionally delete the `strings.zig:93,346,430` arg re-roots (forced arg now reachable via the on-stack arg). Run V1-V4, stressing V4 to ×50 (frame setup is the highest-risk change).
- [ ] **Step 7 — measure + commit**
  ```bash
  git commit -am "perf(gc): keep closure-call operands on the stack, drop doCall arg root"
  ```

---

## Bucket 3 — genuinely off the stack: KEEP (do NOT delete)

New objects built in Zig locals, or operands their callers never put on the operand stack. Full list in [gc-tax-removal-audit.md](gc-tax-removal-audit.md):

- `closures.zig:717-720` **`callValue`** — a shared primitive; some callers (a builtin applying a user fn to a freshly-produced value, PAP folds) hand it values never on the operand stack. Keeping it is also what makes the `applyBuiltin`-loop deletion safe for `map`/`filter`/`foldl'` re-entry.
- `closures.zig:517,566` (doTailCall functor-walk `current`), `659-661` (doCallN callee, the template), `access.zig:24-26` (callAttrFunctor).
- `equality.zig:91-116` — reachable from the JIT trace executor (`jit/exec.zig:233`), which runs ops against its own `vals[]` array (NOT the operand stack). Under `-Dgc+JIT` these are load-bearing even though the bytecode operand is on the stack.
- All accumulators and raw-slice-across-walk roots: `strings.zig` (context merge chain), `builtins/string_context.zig`, `builtins/serial.zig` (JSON/XML), `builtins/collections.zig` (map/genList/foldl'), `builtins/derivation.zig`, `builtins/fetch.zig`, `force.zig:244` (forceDeep), `worker.zig:587` (speculative scheduler-task list, the `8f2fe1a` fix).

## Landmines (respect / document)

1. **`-Dgc + -Djit/-Dtjit`** needs the JIT to root its `vals[]` operands before any equality/merge/container-op roots can be shed — out of scope here; keep those roots.
2. Every deletion assumes **collection fires only at the `forceThunk` safepoint** (`force.zig:403`), never mid-allocation.
3. **Pre-existing latent under-rooting in `strings.zig`** (context accumulator not rooted, unlike the `string_context.zig` mirror) — separate follow-up bug; don't conflate. Be conservative in `strings.zig`.
