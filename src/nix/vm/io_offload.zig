//! Bridges blocking host operations off compute fibers, parking the fiber until
//! a daemon-pool worker or fetch thread completes the operation.
//!
//! No copies are needed: the fiber stays parked for the whole op, so the
//! `work` closure's arguments (which live on the parked fiber's stack, in
//! non-GC allocator memory) remain valid and stable throughout.

const std = @import("std");
const thunk_mod = @import("runtime").thunk;
const rstore = @import("../host.zig").store;
const sync = @import("base").sync;
const fiber_mod = @import("base").fiber;
const worker_mod = @import("worker.zig");

const DaemonPool = rstore.DaemonPool;

/// Submit one daemon op to the connection pool and park the caller until a
/// worker has run it on a warm connection. `work` receives that worker's
/// connection (null if the worker could not open one — the op must surface that
/// as unavailable). On a compute fiber this parks the fiber (yielding its worker,
/// exactly like forcing a `.busy` thunk); off a fiber (the main-thread terminal
/// build / `fix store`) it blocks the calling thread — which has nothing else to
/// do — via `runPoolBlocking`. Matches `RealizationStore.Offload.run`; `ctx` is
/// the `*DaemonPool`.
pub fn runOnPool(ctx: *anyopaque, work: *const fn (conn: ?*anyopaque, work_ctx: *anyopaque) void, work_ctx: *anyopaque) void {
    const pool: *DaemonPool = @ptrCast(@alignCast(ctx));

    const inner = fiber_mod.currentFiber() orelse return pool.submitBlocking(work, work_ctx);
    const wf: *worker_mod.WorkerFiber = @fieldParentPtr("inner", inner);

    wf.io_future = thunk_mod.Future.initClaimed(thunk_mod.makeClaimer(wf.fiber_id));

    var cell: PoolCell = .{ .work = work, .work_ctx = work_ctx, .future = &wf.io_future };
    var job: DaemonPool.Job = .{ .run = PoolCell.run, .ctx = &cell };
    pool.submit(&job);

    if (wf.io_future.enrollWaiter(&wf.waiter)) {
        wf.state = .suspended;
        fiber_mod.Fiber.yield();
        wf.state = .running;
    }
}

const PoolCell = struct {
    work: *const fn (conn: ?*anyopaque, work_ctx: *anyopaque) void,
    work_ctx: *anyopaque,
    future: *thunk_mod.Future,

    fn run(conn: ?*anyopaque, p: *anyopaque) void {
        const self: *PoolCell = @ptrCast(@alignCast(p));
        self.work(conn, self.work_ctx);
        self.future.publish();
    }
};

/// Park the current compute fiber on `future` until it is published (used for a
/// realization-claim wait: a fiber demanding a path another is realizing yields
/// instead of blocking). Returns false if not on a fiber — the caller then waits
/// on the thread itself (the main-thread realize / tests). Enrolls the fiber's
/// own waiter, exactly like forcing a `.busy` thunk; the publisher wakes it.
pub fn fiberPark(future: *thunk_mod.Future) bool {
    const inner = fiber_mod.currentFiber() orelse return false;
    const wf: *worker_mod.WorkerFiber = @fieldParentPtr("inner", inner);
    if (future.enrollWaiter(&wf.waiter)) {
        wf.state = .suspended;
        fiber_mod.Fiber.yield();
        wf.state = .running;
    }
    return true;
}

/// Like `run`, but spawns a dedicated thread for this one fetch instead of
/// queueing on the shared serial IO thread — fetches are independent and run in
/// parallel, bounded by `sem` (from `http-connections`; null = unlimited). The
/// blocking download/subprocess happens on the spawned thread; the fiber parks.
/// The CPU-cheap parts stay on the compute pool; only the syscall-blocking part
/// is offloaded, so a parked fetch thread costs no CPU.
pub fn runFetch(sem: ?*sync.Semaphore, work: *const fn (*anyopaque) void, work_ctx: *anyopaque) void {
    const inner = fiber_mod.currentFiber() orelse {
        work(work_ctx);
        return;
    };
    const wf: *worker_mod.WorkerFiber = @fieldParentPtr("inner", inner);
    wf.io_future = thunk_mod.Future.initClaimed(thunk_mod.makeClaimer(wf.fiber_id));

    var cell: FetchCell = .{ .work = work, .work_ctx = work_ctx, .future = &wf.io_future, .sem = sem };
    var thread = std.Thread.spawn(.{}, FetchCell.run, .{&cell}) catch {
        // Can't spawn a thread — run inline (blocks this worker, but correct).
        work(work_ctx);
        return;
    };
    thread.detach();

    if (wf.io_future.enrollWaiter(&wf.waiter)) {
        wf.state = .suspended;
        fiber_mod.Fiber.yield();
        wf.state = .running;
    }
}

const FetchCell = struct {
    work: *const fn (*anyopaque) void,
    work_ctx: *anyopaque,
    future: *thunk_mod.Future,
    sem: ?*sync.Semaphore,

    fn run(p: *anyopaque) void {
        const self: *FetchCell = @ptrCast(@alignCast(p));
        // Bound concurrent fetches: acquire a permit before the blocking work,
        // release after. A thread that blocks here is parked (free), so the cap
        // limits concurrent network ops without limiting thread count.
        if (self.sem) |s| s.acquire();
        self.work(self.work_ctx);
        if (self.sem) |s| s.release();
        // Publish last: after this the fiber may resume and reuse `self`'s frame.
        self.future.publish();
    }
};
