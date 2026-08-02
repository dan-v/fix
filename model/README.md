# Concurrency models

These bounded TLA+ models specify the evaluator's concurrency protocols at
their state-machine joints. They deliberately do not model CPU registers,
inline assembly, or C/Zig atomic lowering; sanitizer and architecture stress
tests cover those layers.

- `FutureWait`: one-shot claim, enroll-under-lock, terminal publication, and
  waiter draining. It checks that every enrollment remains waiting or is
  woken exactly once and that evaluation eventually leaves its busy state.
- `FiberDispatch`: lifecycle publication, ready tokens, popped contenders,
  run ownership, suspension, wake-before-yield, finish, and recycle. Queue
  membership and run ownership are separate because a wake may be queued
  while another worker is still returning from `runFiber`. Ownership is
  modeled as a set per fiber so `ExclusiveRunOwner` can state — not assume —
  that no two workers ever run the same fiber, and `ClaimedTokenRuns` checks
  that a popped wake token always converts back into a run.
- `Shutdown`: helper quiescence plus external callbacks that retain pointers
  into suspended fiber stacks. No worker or scheduler resource may be
  destroyed until those callbacks have published and returned.
- `GcBarrier`: collecting, parallel mark, releasing, and the peer-flag drain
  that prevents generation overlap.

Run all models with:

```console
zig build check-models
```

The check also applies one deliberate mutation per model—removing the Future
enrollment recheck, the fiber run-ownership exclusivity guard, the
external-job drain, and the GC releasing phase—and requires TLC to reject
each weakened model.
