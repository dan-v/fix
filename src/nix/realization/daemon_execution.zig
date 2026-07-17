//! Fiber-aware adapter for nix-daemon pool work.
//!
//! This is deliberately realization-owned: unlike the generic execution port,
//! the capability names the concrete daemon pool and its connection callback.

const future_mod = @import("runtime").future;
const fiber_mod = @import("base").fiber;
const execution = @import("../execution.zig");
const worker_mod = @import("../eval/workers/worker.zig");
const DaemonPool = @import("../host.zig").store.DaemonPool;

pub const WorkFn = *const fn (connection: ?*anyopaque, context: *anyopaque) void;

pub const Executor = struct {
    fibers: execution.FiberExecutor,
    run_pool_fn: *const fn (pool: *DaemonPool, work: WorkFn, context: *anyopaque) void,

    pub fn runPool(self: Executor, pool: *DaemonPool, work: WorkFn, context: *anyopaque) void {
        self.run_pool_fn(pool, work, context);
    }

    pub fn parkFuture(self: Executor, future: *future_mod.Future) bool {
        return self.fibers.parkFuture(future);
    }
};

pub const fiber_executor: Executor = .{
    .fibers = execution.fiber_executor,
    .run_pool_fn = runOnPool,
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

    fn run(conn: ?*anyopaque, p: *anyopaque) void {
        const self: *PoolCell = @ptrCast(@alignCast(p));
        self.work(conn, self.work_ctx);
        self.future.publish();
    }
};
