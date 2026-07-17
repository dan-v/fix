//! Fiber-aware adapter for store daemon-pool work.

const future_mod = @import("runtime").future;
const fiber_mod = @import("base").fiber;
const store = @import("store");
const worker_mod = @import("worker.zig");
const execution = @import("fiber_executor.zig");

const DaemonPool = store.daemon.DaemonPool;
const WorkFn = store.realization.daemon_execution.WorkFn;

pub const executor: store.realization.daemon_execution.Executor = .{
    .run_pool_fn = runOnPool,
    .park_future_fn = execution.parkFuture,
};

fn runOnPool(pool: *DaemonPool, work: WorkFn, work_ctx: *anyopaque) void {
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
    work: WorkFn,
    work_ctx: *anyopaque,
    future: *future_mod.Future,

    fn run(conn: ?*anyopaque, context: *anyopaque) void {
        const self: *PoolCell = @ptrCast(@alignCast(context));
        self.work(conn, self.work_ctx);
        self.future.publish();
    }
};
