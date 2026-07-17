//! Fiber-aware execution services. Blocking host work leaves the compute
//! worker while its calling fiber parks; this is evaluator execution
//! machinery, not bytecode-VM semantics.

const std = @import("std");
const future_mod = @import("runtime").future;
const rstore = @import("../host.zig").store;
const sync = @import("base").sync;
const fiber_mod = @import("base").fiber;
const worker_mod = @import("worker.zig");
const port = @import("port.zig");

const DaemonPool = rstore.DaemonPool;

pub const fiber_executor: port.FiberExecutor = .{
    .run_pool_fn = runOnPool,
    .park_future_fn = parkFuture,
    .run_blocking_fn = runBlocking,
};

pub fn runOnPool(ctx: *anyopaque, work: port.WorkFn, work_ctx: *anyopaque) void {
    const pool: *DaemonPool = @ptrCast(@alignCast(ctx));
    const inner = fiber_mod.currentFiber() orelse return pool.submitBlocking(work, work_ctx);
    const wf: *worker_mod.WorkerFiber = @fieldParentPtr("inner", inner);

    wf.io_future = future_mod.Future.initClaimed(future_mod.makeClaimer(wf.fiber_id));
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
    work: port.WorkFn,
    work_ctx: *anyopaque,
    future: *future_mod.Future,

    fn run(conn: ?*anyopaque, p: *anyopaque) void {
        const self: *PoolCell = @ptrCast(@alignCast(p));
        self.work(conn, self.work_ctx);
        self.future.publish();
    }
};

pub fn parkFuture(future: *future_mod.Future) bool {
    const inner = fiber_mod.currentFiber() orelse return false;
    const wf: *worker_mod.WorkerFiber = @fieldParentPtr("inner", inner);
    if (future.enrollWaiter(&wf.waiter)) {
        wf.state = .suspended;
        fiber_mod.Fiber.yield();
        wf.state = .running;
    }
    return true;
}

pub fn runBlocking(sem: ?*sync.Semaphore, work: port.BlockingFn, work_ctx: *anyopaque) void {
    const inner = fiber_mod.currentFiber() orelse {
        work(work_ctx);
        return;
    };
    const wf: *worker_mod.WorkerFiber = @fieldParentPtr("inner", inner);
    wf.io_future = future_mod.Future.initClaimed(future_mod.makeClaimer(wf.fiber_id));

    var cell: BlockingCell = .{ .work = work, .work_ctx = work_ctx, .future = &wf.io_future, .sem = sem };
    var thread = std.Thread.spawn(.{}, BlockingCell.run, .{&cell}) catch {
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

const BlockingCell = struct {
    work: port.BlockingFn,
    work_ctx: *anyopaque,
    future: *future_mod.Future,
    sem: ?*sync.Semaphore,

    fn run(p: *anyopaque) void {
        const self: *BlockingCell = @ptrCast(@alignCast(p));
        if (self.sem) |s| s.acquire();
        self.work(self.work_ctx);
        if (self.sem) |s| s.release();
        self.future.publish();
    }
};
