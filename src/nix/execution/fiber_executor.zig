//! Generic fiber-aware execution services. Blocking work leaves the compute
//! worker while its calling fiber parks; concrete host queues are adapted by
//! their owning subsystem.

const std = @import("std");
const future_mod = @import("runtime").future;
const fiber_mod = @import("base").fiber;
const worker_mod = @import("worker.zig");
const port = @import("port.zig");

pub const fiber_executor: port.FiberExecutor = .{
    .park_future_fn = parkFuture,
    .run_blocking_fn = runBlocking,
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

const BlockingPool = @import("blocking_pool.zig").BlockingPool;

pub fn runBlocking(pool: ?*BlockingPool, work: port.BlockingFn, work_ctx: *anyopaque) void {
    const inner = fiber_mod.currentFiber() orelse {
        if (pool) |bounded| bounded.submitBlocking(work, work_ctx) else work(work_ctx);
        return;
    };
    const wf: *worker_mod.WorkerFiber = @fieldParentPtr("inner", inner);
    wf.io_future = future_mod.Future.initClaimed(future_mod.makeClaimer(wf.fiber_id));

    var cell: BlockingCell = .{ .work = work, .work_ctx = work_ctx, .future = &wf.io_future };
    if (pool) |bounded| {
        var job: BlockingPool.Job = .{ .run = BlockingCell.run, .context = &cell };
        bounded.submit(&job);
        if (wf.io_future.enrollWaiter(&wf.waiter)) {
            wf.state = .suspended;
            fiber_mod.Fiber.yield();
            wf.state = .running;
        }
        return;
    }
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

    fn run(p: *anyopaque) void {
        const self: *BlockingCell = @ptrCast(@alignCast(p));
        self.work(self.work_ctx);
        self.future.publish();
    }
};
