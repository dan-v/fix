//! Bridges a blocking operation (a nix-daemon store op) off the compute fiber
//! onto the shared `IoRuntime` thread, parking the fiber until it completes.
//!
//! `run` is the vtable entry injected into `DerivationStore.offload`: the store
//! calls it with an opaque `work` closure, and this module runs that closure on
//! the IO thread while the calling fiber yields — so the worker is free to run
//! other fibers meanwhile. Parking reuses the exact busy-thunk machinery: enroll
//! the fiber's `waiter` on a `Future`, yield, and get woken via `enqueueReady`
//! when the IO thread `publish()`es from inside the job closure.
//!
//! No copies are needed: the fiber stays parked for the whole op, so the
//! `work` closure's arguments (which live on the parked fiber's stack, in
//! non-GC allocator memory) remain valid and stable throughout.

const io_runtime = @import("runtime").io_runtime;
const thunk_mod = @import("runtime").thunk;
const fiber_mod = @import("base").fiber;
const worker_mod = @import("worker.zig");

/// Matches `DerivationStore.Offload.run`. `ctx` is the `*IoRuntime`.
pub fn run(ctx: *anyopaque, work: *const fn (*anyopaque) void, work_ctx: *anyopaque) void {
    const io: *io_runtime.IoRuntime = @ptrCast(@alignCast(ctx));

    const inner = fiber_mod.currentFiber() orelse {
        // Not on a worker fiber (defensive — store ops always run on fibers
        // during eval). Nothing to park; run inline on this thread.
        work(work_ctx);
        return;
    };
    const wf: *worker_mod.WorkerFiber = @fieldParentPtr("inner", inner);

    // Fresh completion cell on the stable WorkerFiber (claimed, so the IO
    // thread's `publish` wakes an enrolled waiter).
    wf.io_future = thunk_mod.Future.initClaimed(thunk_mod.makeClaimer(wf.fiber_id));

    var cell: Cell = .{ .work = work, .work_ctx = work_ctx, .future = &wf.io_future };
    var job: io_runtime.Job = .{ .run = Cell.run, .ctx = &cell };
    io.submit(&job);

    // Enroll + yield, exactly like forcing a `.busy` thunk. If the IO thread
    // already published (raced ahead of the enroll), `enrollWaiter` returns
    // false and we fall straight through — the result is already written.
    if (wf.io_future.enrollWaiter(&wf.waiter)) {
        wf.state = .suspended;
        fiber_mod.Fiber.yield();
        wf.state = .running;
    }
}

const Cell = struct {
    work: *const fn (*anyopaque) void,
    work_ctx: *anyopaque,
    future: *thunk_mod.Future,

    fn run(p: *anyopaque) void {
        const self: *Cell = @ptrCast(@alignCast(p));
        // Do the blocking work first (writes the caller's result slot), THEN
        // publish — `publish`'s release-store of the future state hands that
        // result to the resuming fiber. After this the cell may vanish (the
        // fiber resumes and reuses its frame); `publish` only touches
        // `future`, which lives on the stable WorkerFiber.
        self.work(self.work_ctx);
        self.future.publish();
    }
};
