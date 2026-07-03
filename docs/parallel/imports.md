# Imports & the Discovery Floor

*Import resolution as a deduplicated Future registry — and why module discovery is the w=32 wall.*

## Mental model

`import <path>` is a memoized, coordinated computation keyed by resolved path. Two independent fibers importing the same file must **share** one evaluation, not race two. The machinery is the [thunk claim/wait/wake protocol](../runtime/thunks.md) applied to paths instead of thunks: a path maps to an `ImportEntry` wrapping a `Future`, and *a Future is a Future* whether it backs a thunk or a file. There is no main/helper asymmetry.

But import resolution is also the **serialization floor** for the whole evaluator: discovering a module's imports and compiling them is largely single-threaded, and must complete *before* the N-way parallel eval of that module's contents can begin. See [perf/model.md](../perf/model.md).

---

## The registry

A path-keyed table `StringHashMap(path → *ImportEntry)`. A brief `SpinMutex` guards only lookup/insert; all *actual* coordination lives in the entry's `Future`, held with no lock.

```
ImportEntry {
    future     : Future          # claim/wait/wake state machine
    result     : Value           # Future is value-less → entry owns the slot
    error_info : ?*ErrorInfo     # sidecar for a cached deterministic failure
}
```

Because `Future` is value-less, the entry carries its own `result`, written *before* `future.publish()` so waiters see it on wake.

---

## Resolution state machine

`forceEntry` drives the claim loop. Every fiber calls `tryClaim(myClaimerId)` and dispatches on the outcome:

```
loop:
    switch entry.future.tryClaim(me):

      .already_resolved → return entry.result          # someone finished it
      .errored          → return cached error           # deterministic replay
      .blackhole        → return error.ImportCycle       # same-claimer recursion
      .busy:                                             # another fiber owns it
          enroll on future.waiter_list
          fiber.state = suspended; yield()               # park, don't spin
          fiber.state = running;   continue              # re-try on wake
      .claimed:                                          # WE own it
          value = compileImportPath(path)  else:
                      publish failure (cache) ; return err
          entry.result = value
          entry.future.publish()                         # wakes waiters
          return value
```

- **First claimer** runs `compileImportPath` **inline**: read file → `evaluateSource` (parse + compile + eval) → value. No task handoff; the claimer *is* the evaluator for that file.
- **Concurrent fibers** enroll on `future.waiter_list` and park (the [import fiber-park](../parallel/workers.md), symmetric with thunk waiting). On `publish()`, woken fibers are enqueued on their **home-worker** ready [queue](scheduler.md).
- **Cycles** come for free: a `ClaimerId` is stable across [fiber migration](fibers.md), so `A imports B imports A` reaches a slot the *same claimer* already owns → `Future` returns `.blackhole` → `error.ImportCycle`.

### Failure caching
A failed compile publishes an `ErrorInfo` sidecar via `publishErrored`, so the same error replays on every later force — imports that fail (file-not-found, parse error) fail deterministically. If even the `ErrorInfo` allocation fails, the future is `reset` (transient) so the next caller simply retries.

### Directories & corepkgs
`import <dir>` redirects to `<dir>/default.nix`. `<nix/fetchurl.nix>` resolves to a hard-coded synthetic source, so no corepkgs store path is needed on disk. Both flow back through the same registry.

---

## Scoped imports

`scopedImport scope path` **bypasses dedup** — each call carries a distinct `scope` Value, so two scoped imports of the same path are genuinely different evaluations and must not share a registry entry.

Cycle detection therefore cannot rely on the Future. Instead each in-progress scoped path is pushed onto a **thread-local linked list** (`ScopedFrame`) threaded through the import call stack:

- `pushScopedFrame` links a frame and returns the prior top (restored on scope exit);
- `checkScopedCycle` walks the chain for the path before evaluating → `error.ImportCycle`.

Per-fiber, no locking — the frame stack lives only on the evaluating fiber's stack.

---

## The discovery serialization floor

The registry parallelizes *duplicate* imports (many fibers, one eval) and lets independent import subtrees [fan out](speculation.md). What it **cannot** parallelize is the shape of discovery itself:

- to evaluate a module you must first know its imports;
- collecting them means **parsing and compiling** the file — largely single-threaded work;
- that parse+compile must finish before the module's contents can be forced N-ways.

So the critical path is a **serial chain of parse+compile through the import graph**, and it is the w=32 floor. Adding cores speeds up the *forcing* of already-discovered work; it does not speed up discovering it. Speculative parse+compile prefetch was tried and *regressed* — helpers are not free during discovery. See [perf/model.md](../perf/model.md).

---

## Invariants

- One resolved path ⇒ at most one non-scoped evaluation (registry dedup).
- The claimer runs compile **inline**; waiters **park**, never spin — same protocol as [thunks](../runtime/thunks.md).
- Cycle = same-claimer recursion (non-scoped) or thread-local frame hit (scoped) ⇒ `error.ImportCycle`.
- `result` is written **before** `publish()`; waiters read it after wake.
- Failures cache deterministically (`ErrorInfo`); only allocation failure falls back to transient `reset`.
- Scoped imports never touch the registry (distinct scope Value).

File & path caching is shared via the evaluator's `files` reader. See [parallel/workers.md](workers.md).

Code: src/eval/imports.zig, src/vm/force.zig
