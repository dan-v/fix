//! Neutral execution-domain capability used by realization without importing
//! VM implementation details.

const Future = @import("runtime").future.Future;
const Semaphore = @import("base").sync.Semaphore;

pub const WorkFn = *const fn (connection: ?*anyopaque, context: *anyopaque) void;
pub const BlockingFn = *const fn (context: *anyopaque) void;

pub const FiberExecutor = struct {
    run_pool_fn: *const fn (pool: *anyopaque, work: WorkFn, context: *anyopaque) void,
    park_future_fn: *const fn (future: *Future) bool,
    run_blocking_fn: *const fn (semaphore: ?*Semaphore, work: BlockingFn, context: *anyopaque) void,

    pub fn runPool(self: FiberExecutor, pool: *anyopaque, work: WorkFn, context: *anyopaque) void {
        self.run_pool_fn(pool, work, context);
    }

    pub fn parkFuture(self: FiberExecutor, future: *Future) bool {
        return self.park_future_fn(future);
    }

    pub fn runBlocking(self: FiberExecutor, semaphore: ?*Semaphore, work: BlockingFn, context: *anyopaque) void {
        self.run_blocking_fn(semaphore, work, context);
    }
};
