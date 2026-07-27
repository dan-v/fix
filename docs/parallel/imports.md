# Imports & the Discovery Floor

*Import resolution as a deduplicated Future registry — and why module discovery is the high-worker-count wall.*

## Mental model

`import <path>` is a memoized, coordinated computation keyed by resolved path.
Concurrent fibers importing the same file share the in-flight attempt through
an `ImportEntry` wrapping a `Future`. A completed value or deterministic error
is cached. A transient resource failure resets the entry and can therefore
lead to a later retry.

On the profiled NixOS workload, import discovery contributes to the serial
critical path: a file must be found, parsed, and compiled before work exposed by
that file can be scheduled. See [perf/model.md](../perf/model.md).

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

`forceImportEntry` drives the claim loop. Every fiber calls `tryClaim(myClaimerId)` and dispatches on the outcome:

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
A failed compile publishes an `ErrorInfo` sidecar via `publishErrored`, so the same error replays on every later force — imports that fail (file-not-found, parse error) fail deterministically. `OutOfMemory`, `StackOverflow`, and `SpeculativeBail` are the exceptions: they are not cached, and the future is reset so a later caller may retry. If even the `ErrorInfo` allocation fails, the future is likewise reset.

### Directories & corepkgs
`import <dir>` redirects to `<dir>/default.nix`. `<nix/fetchurl.nix>` resolves to the synthetic source in `eval/imports/corepkgs.zig`, so no corepkgs store path is needed on disk. Both flow back through the same registry.

### Speculative import prefetch
A spec-lane prefetch (`FIX_IMPORT_PREFETCH`) submits `import_prefetch` [tasks](scheduler.md) that resolve, parse, compile, and evaluate a `.nix` file ahead of demand. Paths come from freshly compiled chunks and are deduplicated before submission; `FIX_IMPORT_PREFETCH_MAX` bounds the per-evaluation budget. Prefetch populates the same registry, so demand either finds a resolved entry or joins its `Future`. Prefetch errors stay invisible until demand, where deterministic failures replay normally. It defaults on whenever helpers exist; `FIX_IMPORT_PREFETCH=0`/`1` overrides.

---

## Scoped imports

`scopedImport scope path` **bypasses dedup** — each call carries a distinct `scope` Value, so two scoped imports of the same path are genuinely different evaluations and must not share a registry entry.

Cycle detection therefore cannot rely on the Future. `scopedImportResolvedPath` walks the fiber's `ExecutionContext.scoped_import_top` chain and raises `error.ImportCycle` on a repeated path, then links a stack-local `ScopedImportFrame` for the evaluation and restores the previous head on return. The head travels with a stolen fiber, so migration cannot lose the active import chain; no lock is needed because only that fiber mutates it.

---

## Discovery and the critical path

The registry coordinates *duplicate* imports (many fibers, one evaluation),
and prefetch can start independent imports before demand. Discovery can still
form a serial dependency chain:

- to evaluate a module you must first know its imports;
- collecting them means **parsing and compiling** the file — largely single-threaded work;
- that parse+compile must finish before the module's contents can be forced N-ways.

For workloads with a deep import-discovery chain, parse and compile time on that
chain limits the work that additional workers can see. The `import_prefetch`
lane tries to expose some of it earlier by starting a file before demand. The
measured contribution for one NixOS workload is in
[perf/model.md](../perf/model.md).

---

## Invariants

- One resolved path has at most one non-scoped attempt in flight. A completed
  value or deterministic error is reused; transient failures may be retried.
- The claimer runs compile **inline**; waiters **park**, never spin — same protocol as [thunks](../runtime/thunks.md).
- Cycle = same-claimer recursion (non-scoped) or fiber-scoped frame hit (scoped) ⇒ `error.ImportCycle`.
- `result` is written **before** `publish()`; waiters read it after wake.
- Deterministic failures cache (`ErrorInfo`); resource-pressure failures fall back to transient `reset`.
- Scoped imports never touch the registry (distinct scope Value).

File & path caching is shared via the evaluator's `files` reader. See [workers](workers.md).

Code: evaluator-owned orchestration in `src/expr/evaluator.zig`, registry/entry state in `src/expr/eval/imports.zig`, compatibility sources in `src/expr/eval/imports/corepkgs.zig`, and parking in `src/expr/eval/workers/worker.zig`.
