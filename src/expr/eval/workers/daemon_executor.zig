//! Fiber-aware adapter for store daemon-pool work.

const future_mod = @import("runtime").future;
const fiber_mod = @import("base").fiber;
const store = @import("store");
const worker_mod = @import("worker.zig");
const scheduler_mod = @import("scheduler.zig");
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
    wf.worker.scheduler.externalJobBegin();
    var cell: PoolCell = .{
        .work = work,
        .work_ctx = work_ctx,
        .future = &wf.io_future,
        .scheduler = wf.worker.scheduler,
    };
    var job: DaemonPool.Job = .{ .run = PoolCell.run, .ctx = &cell };
    pool.submit(&job);

    wf.parkOn(&wf.io_future);
}

const PoolCell = struct {
    work: WorkFn,
    work_ctx: *anyopaque,
    future: *future_mod.Future,
    scheduler: *scheduler_mod.Scheduler,

    fn run(conn: ?*anyopaque, context: *anyopaque) void {
        const self: *PoolCell = @ptrCast(@alignCast(context));
        // Copy every stack-cell field before publish: waking the fiber may let
        // another worker resume and recycle this stack immediately.
        const work = self.work;
        const work_ctx = self.work_ctx;
        const future = self.future;
        const scheduler = self.scheduler;
        work(conn, work_ctx);
        future.publish();
        scheduler.externalJobEnd();
    }
};
