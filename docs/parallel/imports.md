# Imports & the Discovery Floor

*Import resolution as a deduplicated Future registry — and why module discovery is the high-worker-count wall.*

## Mental model

`import <path>` is a memoized, coordinated computation keyed by resolved path. Two independent fibers importing the same file must **share** one evaluation, not race two. The machinery is the [thunk claim/wait/wake protocol](../runtime/thunks.md) applied to paths instead of thunks: a path maps to an `ImportEntry` wrapping a `Future`, and *a Future is a Future* whether it backs a thunk or a file. There is no main/helper asymmetry.

But import resolution is also the **serialization floor** for the whole evaluator: discovering a module's imports and compiling them is largely single-threaded, and must complete *before* the N-way parallel eval of that module's contents can begin. See [perf/model.md](../perf/model.md).

---

## The registry

A path-keyed table (`StringHashMapUnmanaged(path → *ImportEntry)`). A brief `SpinMutex` guards only lookup/insert; all *actual* coordination lives in the entry's `Future`, held with no lock.

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

      .already_resolved → return entry.result             # someone finished it
      .blackhole        → return error.ImportCycle        # same-claimer recursion
      .errored          → return entry.error_info.err     # deterministic replay
      .busy:                                              # another fiber owns it
          enrollWaiter(&wf.waiter)                         # onto future.waiters_head
          fiber.state = suspended; yield()                # park, don't spin
          fiber.state = running;   continue               # re-try on wake
      .claimed:                                           # WE own it
          value = compileImportPath(path)  else:
                      publish failure (cache) ; return err
          entry.result = value
          entry.future.publish()                          # wakes waiters
          return value
```

- **First claimer** runs `compileImportPath` **inline**: read file → `evaluateSource` (parse + compile + eval) → value. No task handoff; the claimer *is* the evaluator for that file.
- **Concurrent fibers** enroll on the future's waiter list via `enrollWaiter` (linked through `Future.waiters_head`, guarded by `waiters_mu`) and park (the [import fiber-park](workers.md), symmetric with thunk waiting). On `publish()`, woken fibers are enqueued on their **home-worker** ready [queue](scheduler.md).
- **Cycles** come for free: a `ClaimerId` is stable across [fiber migration](fibers.md), so `A imports B imports A` reaches a slot the *same claimer* already owns → `Future` returns `.blackhole` → `error.ImportCycle`.

### Failure caching
A failed compile publishes an `ErrorInfo` sidecar via `publishErrored`, so the same error replays on every later force — imports that fail (file-not-found, parse error) fail deterministically. Resource-pressure failures (`OutOfMemory`, `StackOverflow`) are the exception: they are **never** cached — the future is `reset` (transient) so the next caller retries — because a speculative prefetch fiber hitting a memory/stack limit must not poison the path for real demand. If even the `ErrorInfo` allocation fails, the future is likewise `reset`.

### Directories & corepkgs
`import <dir>` redirects to `<dir>/default.nix`. `<nix/fetchurl.nix>` resolves to a hard-coded synthetic source (`corepkgsSource`), so no corepkgs store path is needed on disk. Both flow back through the same registry.

### Speculative import prefetch
A spec-lane prefetch (`FIX_IMPORT_PREFETCH`) submits `import_prefetch` [tasks](scheduler.md) that resolve + parse + compile + top-level-eval a `.nix` file ahead of demand — discovered from the `.path` constants of freshly compiled chunks (via `ChunkRegistry.path_const_sink`) and deduplicated per path before submission, capped at `FIX_IMPORT_PREFETCH_MAX` = **8192** submissions per eval. It populates the *same* registry, so the demand fiber later hits `.already_resolved` (or joins the in-flight `Future`) instead of paying parse+compile on the critical chain. Errors are swallowed on the prefetch path; deterministic failures still cache on the entry and replay identically on real demand. It is **on by default at `2..16` workers** (the same gate as the [novel lane](speculation.md)): at `--workers=1` nothing drains it, and past 16 workers the extra spec-lane volume chases junk rather than shortening the chain. `FIX_IMPORT_PREFETCH=0`/`1` overrides.

---

## Scoped imports

`scopedImport scope path` **bypasses dedup** — each call carries a distinct `scope` Value, so two scoped imports of the same path are genuinely different evaluations and must not share a registry entry.

Cycle detection therefore cannot rely on the Future. Instead each in-progress scoped path is pushed onto a **thread-local linked list** (`ScopedFrame`) threaded through the import call stack:

- `pushScopedFrame` links a frame and returns the prior top (restored on scope exit);
- `checkScopedCycle` walks the chain for the path before evaluating → `error.ImportCycle`.

Thread-local, no locking: `scoped_stack_top` is a `threadlocal` pointer and each `ScopedFrame` is a local on the evaluating call stack (a scoped import is compiled inline by its claimer, so the chain never leaves that native stack).

---

## The discovery serialization floor

The registry parallelizes *duplicate* imports (many fibers, one eval) and lets independent import subtrees [fan out](speculation.md). What it **cannot** parallelize is the shape of discovery itself:

- to evaluate a module you must first know its imports;
- collecting them means **parsing and compiling** the file — largely single-threaded work;
- that parse+compile must finish before the module's contents can be forced N-ways.

So the critical path is a **serial chain of parse+compile through the import graph**, and it is the high-worker-count floor. Adding cores speeds up the *forcing* of already-discovered work; it does not speed up discovering it. The `import_prefetch` lane above attacks exactly this chain by running a file's parse+compile ahead of demand, which is why it is gated to `2..16` workers — past that the helpers spend their scan budget on speculative volume that never shortens the chain. See [perf/model.md](../perf/model.md).

---

## Invariants

- One resolved path ⇒ at most one non-scoped evaluation (registry dedup).
- The claimer runs compile **inline**; waiters **park**, never spin — same protocol as [thunks](../runtime/thunks.md).
- Cycle = same-claimer recursion (non-scoped) or thread-local frame hit (scoped) ⇒ `error.ImportCycle`.
- `result` is written **before** `publish()`; waiters read it after wake.
- Deterministic failures cache (`ErrorInfo`); resource-pressure failures fall back to transient `reset`.
- Scoped imports never touch the registry (distinct scope Value).

File & path caching is shared via the evaluator's `files` reader. See [workers](workers.md).

Code: `src/eval/imports.zig`, `src/eval/worker.zig`
