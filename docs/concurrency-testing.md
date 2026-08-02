# Concurrency verification

Concurrency confidence comes from complementary checks rather than one large,
timing-sensitive test.

- `zig build test-concurrency` runs deterministic protocol tests for Future
  enrollment/publication, ready-queue deduplication, wake-before-park, external
  completion teardown, repeated GC barriers, and serial/parallel semantics.
- `zig build check-models` runs the bounded TLA+ models in `model/` with
  deadlock detection enabled, checks liveness (waiters are woken, collections
  complete, shutdown finishes) alongside the safety invariants, and verifies
  that a deliberate protocol mutation per model is rejected.
- `TSAN_OPTIONS=halt_on_error=1:exitcode=66 zig build test-concurrency -Dtsan`
  instruments the complete evaluator module graph on x86_64 Linux. Fiber
  switches use compiler-rt's fiber API so stacks remain attributed correctly
  when work migrates between kernel threads.
- `zig build stress-concurrency -- --seed 123 --iterations 25` runs seeded
  exact-once deque contention and serial/parallel evaluator differentials. It
  varies queue growth, worker counts, scheduler toggles, error caching, low-GC
  operation, and repeated startup/shutdown. Failures always print the seed and
  iteration for replay.

The ordinary CI matrix runs the focused tests on every supported architecture,
TLC and TSan on x86_64 Linux, and a scheduled workflow runs longer Debug and
ReleaseFast stress on x86_64/aarch64 Linux plus a seeded TSan stress pass.
