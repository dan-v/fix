//! Generic fiber-aware execution services. Blocking work leaves the compute
//! worker while its calling fiber parks; concrete host queues are adapted by
//! their owning subsystem.

const std = @import("std");
const future_mod = @import("runtime").future;
const fiber_mod = @import("base").fiber;
const worker_mod = @import("worker.zig");
const scheduler_mod = @import("scheduler.zig");
const port = @import("port.zig");

pub const fiber_executor: port.FiberExecutor = .{
    .park_future_fn = parkFuture,
    .run_blocking_fn = runBlocking,
};

pub fn parkFuture(future: *future_mod.Future) bool {
    const inner = fiber_mod.currentFiber() orelse return false;
    const wf: *worker_mod.WorkerFiber = @fieldParentPtr("inner", inner);
    wf.parkOn(future);
    return true;
}

const BlockingPool = @import("base").BlockingPool;

pub fn runBlocking(pool: ?*BlockingPool, work: port.BlockingFn, work_ctx: *anyopaque) void {
    const inner = fiber_mod.currentFiber() orelse {
        if (pool) |bounded| bounded.submitBlocking(work, work_ctx) else work(work_ctx);
        return;
    };
    const wf: *worker_mod.WorkerFiber = @fieldParentPtr("inner", inner);
    wf.io_future = future_mod.Future.initClaimed(future_mod.makeClaimer(wf.fiber_id));

    wf.worker.scheduler.externalJobBegin();
    var cell: BlockingCell = .{
        .work = work,
        .work_ctx = work_ctx,
        .future = &wf.io_future,
        .scheduler = wf.worker.scheduler,
    };
    if (pool) |bounded| {
        var job: BlockingPool.Job = .{ .run = BlockingCell.run, .context = &cell };
        bounded.submit(&job);
        wf.parkOn(&wf.io_future);
        return;
    }
    var thread = std.Thread.spawn(.{}, BlockingCell.run, .{&cell}) catch {
        wf.worker.scheduler.externalJobEnd();
        work(work_ctx);
        return;
    };
    thread.detach();

    wf.parkOn(&wf.io_future);
}

const BlockingCell = struct {
    work: port.BlockingFn,
    work_ctx: *anyopaque,
    future: *future_mod.Future,
    scheduler: *scheduler_mod.Scheduler,

    fn run(p: *anyopaque) void {
        const self: *BlockingCell = @ptrCast(@alignCast(p));
        // Copy every stack-cell field before publish: waking the fiber may let
        // another worker resume and recycle this stack immediately.
        const work = self.work;
        const work_ctx = self.work_ctx;
        const future = self.future;
        const scheduler = self.scheduler;
        work(work_ctx);
        future.publish();
        scheduler.externalJobEnd();
    }
};
