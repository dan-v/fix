# File IO Plan

The evaluator should not let evaluation workers block on cold filesystem reads.
For nixpkps-scale workloads, file access needs to be an evaluator subsystem, not
a builtin-side syscall.

## Ownership

- `Evaluator` owns a `FileCache`.
- `FileCache` owns canonical path keys, existence results, and file contents.
- The VM only calls `FileCache.pathExists` and `FileCache.readFile`; it does not
  normalize paths or talk to `std.Io` directly.
- Path literals are resolved during compilation when the evaluator has a base
  path. Hot file-cache lookups first check the exact path key before doing any
  normalization.

## Async Backend Target

Cold cache misses should become requests in an IO backend:

1. Evaluation worker asks `FileCache` for a path.
2. Cache hit returns immediately.
3. Cache miss creates or joins an in-flight request keyed by canonical path.
4. Request is submitted to an IO lane/thread pool.
5. Evaluation worker parks the current continuation and returns to runnable
   evaluator work instead of blocking on the filesystem.
6. IO completion publishes the cache entry and reschedules waiters.

Important details:

- Coalesce concurrent reads of the same path.
- Keep canonical path strings interned/owned by the cache.
- Publish cache entries with acquire/release ordering once workers are
  concurrent.
- Preserve Nix semantics: `readFile` contents are cached by path during one
  evaluation, and `pathExists` does not force unrelated evaluation.
- Keep the sync `std.Io` backend as the test/simple backend behind the same
  `FileCache` API.

## Scheduler Work Needed

The current scheduler queues thunk tasks, but VM execution does not yet expose a
park/resume continuation. Before true nonblocking file imports, add:

- A runnable evaluation task type broader than raw thunk pointers.
- A way for VM/native builtins to suspend the current task on an async result.
- A completion path that queues suspended tasks back to workers.
- Worker wait loops that steal/run available evaluation tasks while IO is in
  flight.

