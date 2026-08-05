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
- `TSAN_OPTIONS=halt_on_error=1:exitcode=66:suppressions=$PWD/test/tsan.supp
  zig build test-concurrency -Dtsan -Doptimize=ReleaseSafe` instruments the
  complete evaluator module graph on x86_64 Linux. Fiber switches use
  compiler-rt's fiber API so stacks remain attributed correctly when work
  migrates between kernel threads. TSan builds use ReleaseSafe: safety checks
  stay on, and the optimizer elides the dead whole-union operand copies that
  safe-Debug lowering emits for tag dispatch — those alias embedded atomics
  and would report as races on reads no source-level access performs.
  `test/tsan.supp` holds the single sanctioned advisory race
  (`Thunk.targetLeadingRacy`); anything else TSan reports is a real bug.
- `zig build stress-concurrency -- --seed 123 --iterations 25` runs seeded
  exact-once deque contention (both the plain-atomic and the u128 wide-slot
  transports, with tearing detection) and serial/parallel evaluator
  differentials over arithmetic, string, attrset, tryEval-recovery, and
  cached-failure workloads. Results are deep-forced and rendered so the
  comparison covers whole structures, not one scalar. It varies queue growth,
  worker counts, scheduler toggles, error caching, low-GC operation, and
  repeated startup/shutdown. Failures always print the seed and iteration for
  replay.

The ordinary CI matrix runs the focused tests on every supported architecture,
TLC and TSan on x86_64 Linux, and a scheduled workflow runs longer Debug and
ReleaseFast stress on x86_64/aarch64 Linux plus a seeded TSan stress pass.
The scheduled workflow also evaluates the real-world bench fixtures at
`--workers 8` as a parallel-eval differential against reference Nix — under
TSan on x86_64, and on aarch64 as the only weak-memory coverage of a real
evaluation (TSan on x86 cannot expose ordering bugs that TSO hides). This lane
complements synthetic stress workloads, which do not reproduce every
module-fixpoint shape.
