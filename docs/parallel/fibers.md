# Fibers

*Stackful user-space coroutines whose yielded state is fully captured and thus stealable — the unit of work the [scheduler](scheduler.md) moves between threads.*

## Mental model

A **fiber** is a computation running on its own stack. Its owner (a [worker](workers.md) thread) calls `resume_` to switch onto the fiber's stack; the fiber calls `yield` to switch back, suspending itself for later resumption. The key property: **once a fiber yields, its entire live state is captured in its `Context` + stack** — immutable until the next resume. Nothing lives in thread-local or register state that the resumer must reconstruct. That is what makes a suspended fiber a *value* the scheduler can hand to any thread.

Each fiber carries **its own VM**. The VM's shared pointers reference the [`Evaluator`](workers.md) tables (chunk registry, [intern](../runtime/interning.md) table, [heap](../runtime/heap.md), scheduler, file/import caches); the per-fiber part is the interpreter value stack, the frame chain, and a private scratch arena backing the VM's run-path allocations. So resuming a fiber on a different thread is sound: the shared state is shared, the private state travels in the stack.

### Why fibers, not OS threads or "steal-while-waiting"

When a thunk force blocks on an in-flight [`Future`](../runtime/thunks.md), the blocked computation must be parked so its worker can do other work. Two rejected alternatives:

- **OS threads / blocking:** parking on a futex burns a whole OS thread per blocked force; at realistic fan-out that is thousands of threads. A yielded fiber's incremental switch state is a 56-byte `Context`; its stack stays mapped but demand-paged (committed RSS tracks only the depth touched), and overflow fibers hand their pages back to the OS.
- **Steal-while-waiting** (a worker, while blocked, dives into the scheduler to run unrelated work on the *same* stack): this pins the resumption to the waiting thread and grows the stack unboundedly with nested unrelated frames. Fibers instead *yield the frame away* — the waiter becomes a stealable object and its thread returns to the drain loop clean.

Payoff and cost profile: at high `--workers` counts helpers are mostly idle (see the [critical-path floor](../perf/model.md)); the wall is dependency-chain depth, not throughput. So the machinery that matters is *low-overhead, affinity-free resumption of blocked work*, exactly what a yielded fiber gives. Fiber creation is amortized by recycling (below), so parking/resuming is close to a `swap` + a queue push.

## The swap primitive

`Context` is the minimal saved state — six callee-saved registers plus the stack pointer (7×8 = **56 bytes**):

```
Context (extern struct, layout matches swap_x86_64.S exactly)
  rbx rbp r12 r13 r14 r15 rsp
```

Caller-saved registers are *not* saved: the Zig calling convention already treats the `fix_swap_context(from, to)` call as clobbering them, so the compiler spills anything live across the call site. `fix_swap_context` is naked assembly:

```
fix_swap_context(from: *Context, to: *Context):
    save rbx,rbp,r12..r15,rsp  → *from     ; freeze the current fiber
    load rbx,rbp,r12..r15,rsp  ← *to        ; adopt the target's registers + stack
    ret                                      ; pops return addr off the NEW rsp
                                             ;   → execution continues in `to`
```

The final `ret` is the switch: it pops a return address from the *just-loaded* `rsp`, so control resumes wherever `to` last swapped out (or, for a never-run fiber, at the trampoline written to the top of its fresh stack). Naked assembly is mandatory here — a compiler prologue/epilogue would leave saved registers straddling the swap whose lifetime does not match the function's, corrupting state on resume.

The trampoline can't receive arguments through the ABI (naked switching bypasses it), so a fiber finds itself via a thread-local `current` pointer that `resume_` sets before swapping in and restores on return.

## Stacks

Each fiber reserves an **8 MiB** anonymous mapping (`mmap` with `PROT_READ|PROT_WRITE`, `MAP_ANONYMOUS|MAP_PRIVATE`, demand-paged). The kernel commits pages only as the fiber recurses, so **RSS tracks actual depth, not the reservation**. 8 MiB buys thousands of frames of headroom on any realistic Nix eval while costing ~0 physical memory for shallow fibers. The mapping is registered with the [RSS attributor](../runtime/heap.md) (`vma`) so the process's most numerous large mappings don't merge into an unattributable anonymous blob.

`releaseStackPages(retain_top, lazy)` gives a dead fiber's stack pages back to the OS — `MADV_FREE` (reclaimed only under pressure) or `MADV_DONTNEED` (immediate). It is only ever called on a `.finished`/`.ready` fiber, whose frames are garbage by definition: a later re-fault reading zeros is indistinguishable from a fresh stack (`reset` rewrites the trampoline slot, and running code always writes a frame before reading it). The [worker](workers.md) uses this to trim spike-overflow fibers when it parks.

Sentinel-fill high-water tracking (`maxStackUsedBytes`) exists under `-Dfiber-stack-probe`; off by default because the fill forces eager commit and defeats lazy paging.

## Lifecycle

```
   init                resume_            yield / block
  ─────▶ .ready ───────────────▶ .running ───────────────▶ .suspended
                                    │  ▲                        │
                              entry │  └────────────────────────┘
                              returns│         resume_
                                    ▼
                                .finished ──reset(entry,arg)──▶ .ready   (recycle)
```

- **`.ready`** — initialized, never resumed; `entry` runs on first resume.
- **`.running`** — executing on its owner's thread.
- **`.suspended`** — yielded; `ctx` holds the resumable state.
- **`.finished`** — `entry` returned; not resumable. `entry`/`arg` are cleared so a finished fiber holds no dangling capture.

**Recycling.** `reset(entry, arg)` rewinds a `.finished` (or never-run `.ready`) fiber's `rsp` to the top of its existing stack and reinstalls entry/arg, returning it to `.ready`. This reuses the 8 MiB mapping and its already-committed pages instead of re-`mmap`ing — the [worker](workers.md)'s fiber free-list is built on this. Resuming a `.finished` or `.running` fiber is a caller bug (debug asserts guard it).

## Cross-thread resume safety (load-bearing invariants)

Fibers migrate — a fiber allocated on worker A may be stolen and resumed on worker B. Three invariants make concurrent/serial resumption from arbitrary threads correct. They are not optimizations; each closes a race that produces real corruption (see the resume-race and waiter-race analysis in [invariants](../invariants.md)).

1. **Fresh `caller_ctx` per resume.** `caller_ctx` — where the fiber swaps *back* to on yield/finish — points into the *resumer's* current stack frame. `resume_` sets it fresh on every call and clears it on return. So the "return path" is always the current resumer's, never a stale pointer into a thread that has since moved on. A resume from a different thread than the previous one is therefore safe by construction.

2. **Per-slot `run_mu` (SpinMutex) serializes concurrent `resume_`.** A wake can enqueue a fiber onto a worker's ready queue at the same instant the fiber's previous owner is still unwinding out of it. Without serialization two threads could `resume_` the same fiber concurrently — two live stacks, one `Context`. The [worker](workers.md) holds `run_mu` on the fiber slot around the run; the loser waits, observes the fiber `.finished`/`.suspended`, and does the right thing. `ReadyNode.queued` (below) independently prevents the double-enqueue, so in normal flow `run_mu` is uncontended.

3. **`ReadyNode.queued` 0→1 CAS gate.** A fiber must appear on the ready queues **at most once**. `enqueueReady` only pushes when it wins the `queued` CAS from 0→1; `pop` resets it to 0. This prevents double-enqueue — two dequeues of the same node racing into `resume_` — even when several wakers fire for the same fiber simultaneously.

Corollary — **ownership returns home:** a stolen fiber, once `.finished`, is returned to its *allocator*-worker's free-list, not the thief's (see [workers](workers.md)). Thread-affinity is a property of the wake/dispatch layer above fibers; the primitive itself imposes none.

---

Code: `src/base/fiber.zig`, `src/base/fiber/swap_x86_64.S`, `src/nix/vm/worker.zig`
