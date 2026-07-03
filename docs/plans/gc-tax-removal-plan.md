# GC mutator-tax removal — Phase 1 (of "tax removal + concurrent SATB")

> **⚠ MEASURED OUTCOME (2026-07-03): the premise below is REFUTED.** An isolation
> experiment (stub every `rootKeep`/`rootsBegin`/`rootsEnd` to no-ops, 0
> collections, interleaved vs the real `-Dgc` build) measured the *rooting* cost
> at **~0.018s median / ~0.008s best = noise (~0.6%)**. The real ~0.09s (~3.3%)
> `-Dgc` mutator overhead is per-alloc `gcSetAllocBit`/threshold + per-force
> safepoint bookkeeping, **not rooting**. So "remove the tax by keeping operands
> on the stack" targets the wrong 0.6%. **Landed** the two clean, byte-identical
> deletions as correctness/simplification wins — access path-walk roots
> (`1351a4c`) and the `applyBuiltin` arg-loop (`d384c46`); **abandoned** the
> `opCall`/`doCall` keep-on-stack conversion (Step B — noise-level gain, real UAF
> risk). Real GC-wall lever = the mark cost (Phase 2), not this. The design below
> is kept for the record.

Status: DESIGN (2026-07-03). Sibling of [gc-plan.md](gc-plan.md) (the collector)
and the forthcoming `gc-concurrent-satb-plan.md` (Phase 2). This phase is
standalone, correctness-neutral, and independently shippable.

## Goal

Remove the ~5.6% / ~0.15s (w=1) **mutator rooting tax** — the explicit
`rootKeep` bookkeeping the `-Dgc` collector pays on the hot call paths, on every
run, even at zero collections. It sits on the **serial critical path**, so
concurrent mark (Phase 2) does *not* remove it; it must be removed directly.

The mechanism is not a new one: **keep live operands on the operand stack across
forces (force in place, drop only after), and explicitly root only a genuinely
off-stack object.** The operand stack + frames + force-chain are already a
precise root set; the tax is the cost of *redundantly* re-rooting things that
could just stay on the stack, plus a handful of ops that pop-then-force.

## Why now / why this shape (the motivating finding)

Measured 2026-07-03 (`-Ddepth0-probe`, nixos_toplevel w=1): of 4.44M forceThunk
safepoints, only **82** are at `native_depth == 0`, all clustered in the first
256 MB; the module fixpoint (256 MB → 1216 MB, ~78% of allocation) is a
`native_depth==0` **desert** (max gap 554 MB). See
[gc-depth0-snapshot-dead memory]. Consequence: nixpkgs eval runs at
`native_depth > 0` essentially the whole fixpoint, so we can never collect
"only at a clean depth-0 boundary." Every collection — STW today, concurrent
tomorrow — must have **precise roots while deep in builtins**.

The good news is that precise-at-any-depth roots do **not** require the
continuous tax *or* a conservative stack scan. If operands live on the operand
stack across forces, the stack *is* the precise root set at any depth, for free.
That is what this phase makes true everywhere, which simultaneously (a) deletes
the tax and (b) yields the precise-by-construction root set Phase-2's SATB
snapshot needs.

## Non-goals

- **No concurrent mark, no write barrier, no SATB** — that is Phase 2.
- **No conservative C-stack / register scanning** — explicitly rejected; the
  operand stack is the precise root set. Zero over-retention.
- **No behavior change.** Output stays byte-identical with and without `-Dgc`.

## The rule (already documented in `vm/force.zig` / `stack.zig`)

After any forcing call, every heap object you still need must be reachable from a
root. Achieve it by construction:

- **Force operands in their stack slot** with `force.forceTop` / `force.forceAt(n)`
  — never `forceValue(pop())`. Drop with `stack.dropBin` / `pop` only after the
  result exists. Exemplar: `opAddInt` (`run.zig`). Primitives: `stack.binTop` /
  `stack.dropBin`, `force.forceTop` / `force.forceAt`.
- **Pass builtin/call operands to helpers as the live stack slots**, not as an
  off-stack copy (`&.{arg}` / a `[N]Value` temp), so the arg objects stay
  reachable through the on-stack originals.
- **Explicitly `rootKeep` only a genuinely off-stack object** — a *new* value a
  builtin builds in a Zig local across a later force (an accumulator, a
  string-context list). That residue is correct and stays.

## Audit surface (the ~90 `rootKeep` sites, three buckets)

The detector is the oracle; these categories are the starting hypothesis, each
confirmed/refuted per-site during implementation.

### A. Call machinery — the per-call tax (delete by keep-on-stack)
The high-frequency cost; fires on essentially every call/apply.
- `vm/builtins.zig:45` — `for (args) |a| rootKeep(a)` in `applyBuiltin`. Delete
  once every caller hands `applyBuiltin` the live stack slots (or an arg whose
  object is on the stack). **Highest value** — one deletion, ~4.4M fewer roots.
- `vm/closures.zig` — `doCall` (435-438 callee+arg), `doCallN` (513-517, 566),
  `callValue` (659-661, 717-720).
- `vm/access.zig:24-26` — `applyBuiltinClosure` / callee apply. Note the
  multi-arg C-array is fine: its contents are reachable via the on-stack
  callee-closure + arg, so no per-element root is needed.

Mechanism: the *caller* op (`opCall`/`opCallN` in `run.zig`, and the closure
dispatch) keeps callee+arg on the stack across the call and drops+pushes the
result afterward (the `binTop`/`dropBin` shape, generalized to the call — the
closure/frame path is subtler; see Risks).

### B. Container roots already reachable via an on-stack operand (delete if the op keeps it on-stack)
The rooted container is a descendant of, or identical to, an operand the calling
op already holds. Redundant once that operand stays on the stack across the
helper; load-bearing only if the op drops it first.
- `vm/access.zig:134-211` — `getAttrPath*` roots each `current` path node; each
  is a descendant of the on-stack attrs operand.
- `vm/equality.zig:91-116` — deep-eq roots `a`/`b`; they come from `opEq`'s
  `binTop`. **Audit:** confirm whether `opEq`/`opNeq` drop before or after the
  deep-eq helper — that decides redundant-vs-load-bearing.
- `vm/objects.zig:65-68` — `//` merge roots left+right; check the merge op keeps
  them on-stack.

### C. Genuine off-stack accumulators (keep)
New heap values built in Zig locals across forces — not on any stack.
- `vm/builtins/collections.zig` (map `mapped` 379, genList `produced` 597,
  foldl' `acc` 669).
- String-context lists: `vm/strings.zig`, `vm/builtins/string_context.zig`,
  `vm/builtins/strings.zig` (the `ctx`/`item_values` accumulators),
  `vm/builtins/serial.zig` (JSON/XML context).
- Derivation build intermediates: `vm/builtins/derivation.zig`.
- `vm/builtins/fetch.zig` (source_info/attrs held across fetch forces — audit:
  some may be args, i.e. bucket B).
- `eval/worker.zig:585-587` — the speculative `force_list_range` task list
  (off-stack, from a scheduler task; the missing root fixed in `8f2fe1a`).

## Validation gauntlet (the correctness bar — a wrong deletion is a UAF)

Per the established GC discipline:
1. **ReleaseSafe `-Dgc` detector** (reuse-off + alloc-bit assert on every read +
   swept-range poison): byte-identical + 0 UAF on nixos_toplevel, at the default
   threshold **and** `FIX_GC_STEP_MB=8` (hundreds of collections → exhaustive
   safepoint coverage). This traps any deleted-but-load-bearing root at the read.
2. **ReleaseFast `-Dgc`** (reuse ON): byte-identical at several `FIX_GC_STEP_MB`
   thresholds (reuse is what exposes a missing root as corruption).
3. **Normal build** (no `-Dgc`): byte-identical; all tests pass.
4. **w>1**: byte-identical at w=8/w=32 with collection forced on (≥30 runs, 0
   failures), since the call machinery is shared with speculative forcing.
5. **Wall**: confirm the goal — measure w=1 ReleaseFast `-Dgc` mutator overhead
   (0-collection run vs no-`-Dgc`) drops from ~+5.6% toward ~0. This is the
   headline success metric.

Work the buckets in order A → B → C-verify, rebuilding the ReleaseSafe detector
after each site (each iter ~34s). Delete a root only after the detector stays
silent across the gauntlet with it gone.

## Risks

- **The closure/frame call path is subtler than a binary op.** `doCall`'s closure
  branch pushes a frame and leans on the frame rooting `closure.upvalues` +
  arg-as-local, and on the deliberately-leaked closure range
  (`gcFreeObjectRanges` skips `.closure`/`.thunk`). Keeping callee on-stack there
  interacts with gc-plan lever #5 (root the executing closure in the frame).
  Treat the closure path carefully; the builtin path (the bulk of the tax) is the
  clean, high-value first cut.
- **Fragility:** a missed root is nondeterministic corruption at w>1/ReleaseFast.
  Mitigated by the detector-as-oracle + byte-identical gauntlet after every site.
- **Partial win:** if bucket A alone recovers most of the 5.6% and B/C are small,
  stop there — measure after A before grinding B.

## Relationship to Phase 2 (concurrent SATB)

Phase 1's end-state — the operand stack/frames/force-chain + a tiny
accumulator-root residue as the *complete precise root set at any native_depth* —
is exactly the snapshot Phase 2 needs: workers park at any `forceThunk` poll
(no depth-0 requirement), the collector scans these precise roots, flips the SATB
write barrier, and marks off-clock on idle helpers. Phase 2 gets its own spec.
