//! Neutral fiber execution-domain capability used by higher layers without
//! importing concrete worker machinery.

const Future = @import("runtime").future.Future;
const BlockingPool = @import("base").BlockingPool;

pub const BlockingFn = *const fn (context: *anyopaque) void;

pub const FiberExecutor = struct {
    park_future_fn: *const fn (future: *Future) bool,
    run_blocking_fn: *const fn (pool: ?*BlockingPool, work: BlockingFn, context: *anyopaque) void,

    pub fn parkFuture(self: FiberExecutor, future: *Future) bool {
        return self.park_future_fn(future);
    }

    pub fn runBlocking(self: FiberExecutor, pool: ?*BlockingPool, work: BlockingFn, context: *anyopaque) void {
        self.run_blocking_fn(pool, work, context);
    }
};
