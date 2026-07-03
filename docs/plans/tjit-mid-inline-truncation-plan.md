# Plan: mid-inline truncation → fire the sink → the win

## The one fact that makes this tractable

The allocation **sink** (`opt.zig:sinkThunks`) needs a force-inlined thunk to
**survive into a completed trace**: `alloc_thunk → thunk_claim → [body that RETs]
→ thunk_resolve`, non-escaping. Today force-inline survives **0** traces.

The reason is **not** that thunk bodies are untraceable. It's case (b): a
force-inline that *did complete* (body ret'd, `thunk_resolve` emitted) sits
inside an **inlined call frame**, and when that call's continuation hits an
unsupported op the trace aborts — because only **anchor-depth** (`inlineDepth==1`)
truncates today. The completed force-inline is thrown away with it.

So the unblock is **mid-inline truncation for CALL frames**: at a side-exit with
`inlineDepth>1` where every active inline frame is a *call* frame, reconstruct
the whole inlined call stack as real VM frames and resume. Completed
force-inlines (which already popped) are kept → they survive → the sink fires.

**We do NOT need force-inline-frame reconstruction for the sink.** If a
force-inline frame is still *active* at the truncation point (case a — an
unsupported op inside the thunk body), keep aborting: a truncated body emits no
`thunk_resolve`, so it can't be sunk anyway. (That's a later, harder phase.)

## Design

### 1. Per-frame return IP (recorder)

Add to `InlineFrame` (recorder.zig):
```
call_return_ip: u32 = 0,  // where THIS frame resumes after its callee RETs
```
Set it when the frame is *created* as a call inline, from the call op's
continuation (verified against opCall/opCallN):
- `enterCall`  (op `call`):       `call_return_ip = observe_ip + 1`
- `enterCallN` (op `call_n`):     `call_return_ip = observe_ip + 2`  (store in
  `PendingCall`, apply in `activatePendingCall`)
- `replaceTail*`: tail calls reuse the frame (no new frame) — N/A.
- anchor frame & force-inline frames: leave 0 (only the deepest frame uses the
  side-exit ip; non-deepest are always call frames here).

The driver passes `return_ip` into `enterCall`/`enterCallN`.

### 2. Multi-frame snapshot (ir.zig)

Generalize `Snapshot` from one frame to a list (anchor → deepest). Unify the
depth-1 path through the same shape so there's a single reconstruct path.
```
pub const SnapshotFrame = struct {
    chunk: ChunkId,
    upvalue_src: ?Ref,   // null = anchor's own upvalues
    resume_ip: u32,      // call_return_ip, or side-exit ip for the deepest frame
    local_entries: []SnapshotEntry,   // loc = .local
    operand_entries: []SnapshotEntry, // loc = .stack, in order
};
pub const Snapshot = struct { frames: []SnapshotFrame };
```
`Trace.addSnapshot` builds this. `deinit` frees the nested slices.

### 3. emitSideExit → multi-frame (recorder.zig)

Replace the `inlineDepth()==1` guard. New logic:
- If **any** active frame has `resolve_thunk != null` (a force-inline frame is
  live) → `return error.TraceAborted` (caller aborts; case a).
- Else, for each frame `k` in `0..D`:
  - `chunk = frames[k].chunk_id`, `upvalue_src = frames[k].upvalue_src`.
  - `resume_ip = (k == D-1) ? self.ip : frames[k].call_return_ip`.
  - `local_entries` = `{slot, ref}` for each non-null `frames[k].locals[slot]`.
  - `operand_entries` = `operand[frames[k].operand_base .. nextBase]` where
    `nextBase = (k+1<D) ? frames[k+1].operand_base : operand.len`, indexed
    0..len as `.stack(i)`.
- Emit `side_exit` with this snapshot; `done = true`.

The driver's truncation branch drops its `inlineDepth()==1` check and just calls
`emitSideExit()` (which self-aborts on a live force-inline frame).

### 4. Reconstruction (closures.zig + exec.zig)

Generalize `resumeTrace` → `resumeTraceMulti(vm, frames_desc[], getValue)`.
`getValue(ref)` is `vals[ref]` (exec) or `slots[ref]` (native) — already unified
via `sideExitImpl(slots: [*]const Value)`. Push the D frames **bottom-up**:
```
stop_depth = vm.frames_len
for k in 0..D:
    ch = registry.get(frame[k].chunk)
    upv = if frame[k].upvalue_src |s| forceValue(slots[s]).closure.upvalues
          else if k==0 anchor_upvalues else <error: only anchor lacks a src>
    // pushFrame(ch, chunk, arg_count=0, upv) reserves local_count nulls
    write live locals into [frame_base + slot]
    push operand_entries above the locals (bounds-check VM_STACK_CAP)
    currentFrame.ip = frame[k].resume_ip
runUntil(stop_depth)   // deepest runs; each RET pushes its result to the
                        // parent's stack and resumes it at call_return_ip;
                        // anchor's RET → frames_len==stop_depth → return value
```
On any push/reconstruct failure → unwind to `stop_depth`, restore `sp`, return
the same deopt/error contract as today (re-interpret whole chunk).

Key invariant already established: frame[k]'s operands are frozen at the
post-call-pop state (func+arg already popped by enterCall, call result not yet
pushed), so when frame[k+1] RETs, retEpilogue pushes the result and frame[k]
continues at `call_return_ip` — exactly as a real call would.

### 5. Optimizer (opt.zig)

`deadCodeElim`: mark live every Ref in every `SnapshotFrame`'s
`local_entries`/`operand_entries` **and** each frame's `upvalue_src`.
`elideRedundantForces`: a force named by any frame's entries/upvalue_src is a
non-forcing use → keep it (same rule as today, extended to the frame list).

### 6. Native (codegen.zig) — no change needed

Native already passes `&snapshot` + `rsp` to `tjitSideExit`, which calls
`sideExitImpl`. The multi-frame work lives entirely in `sideExitImpl`/the helper.
`supported()` already allows `side_exit`. (A native trace with a `side_exit`
whose prefix has only native ops compiles; otherwise exec.zig — unchanged.)

## Correctness gates (every step)

- `.drv` **byte-identical** at w=1 AND w=32 on `test/nixos_toplevel.nix`
  (`nilcr61…`), `zig build test` green. Never perf-gate up front.
- Self-validation harness (reuse the one from the truncation work): on each
  side-exit, optionally also interpret the whole chunk and compare — pin any
  divergence to its anchor before trusting it.
- Force-inline-frame guard: assert no `resolve_thunk` frame at emit time.

## Measurement gates (the actual goal)

After mid-inline truncation lands byte-identical:
1. `--print-sched-stats`: **force-inline survived > 0** (the whole point) and
   **sink count > 0** (add a counter in `sinkThunks`).
2. ReleaseFast A/B vs default at w=1. The sink removes alloc+claim+publish from
   the prefix; this is the first chance the JIT has to do LESS work than the
   interpreter. Expect: regression shrinks, ideally flips at w=1.
3. If sink count is high but w=1 still regresses, the reconstruct tax dominates →
   add **selective install** (don't install a truncated trace unless its sunk
   allocations outweigh its reconstruct cost; e.g. require ≥1 sink, or a prefix
   length floor).

## Phase order

- **P1 (this plan): mid-inline truncation, call frames only.** Unblocks
  force-inline survival (case b) → sink fires. The win attempt.
- **P2: selective install** (if P1 sinks but still regresses).
- **P3: force-inline-frame reconstruction** (case a) — run the claimed thunk's
  body to a side-exit, resolve it, resume the caller re-forcing it. Harder
  (mid-claim thunk), and only widens coverage; the sink win comes from P1.
- **P4: broaden force-inline firing** — catch implicit forces (get_attr/binop
  operands) of trace-built thunks, not just get_local/get_upvalue, so more
  single-use thunks become sink candidates.

## Why this is the path to "beat the interpreter" (and toward v8-class)

Every prior lever (coverage, suppression, native side_exit) was neutral/negative
because it computed the *same* work faster-or-slower. Sinking is the first lever
that **removes work** — and on this workload the removable work (single-use thunk
alloc/claim/publish, 66.8% of forced thunks) is large. P1 is the minimal change
that lets it fire. If P1's A/B shows the sink paying, P3/P4 scale it; if it
doesn't, we have a decisive measurement that the reconstruct tax is the floor and
the generic-JIT ceiling on this workload is confirmed.
