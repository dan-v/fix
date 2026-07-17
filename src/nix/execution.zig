//! Evaluator execution substrate: fiber workers, fiber-scoped context, and
//! capabilities for parking blocking host work off compute workers.

pub const context = @import("execution/context.zig");
pub const port = @import("execution/port.zig");
pub const worker = @import("execution/worker.zig");
pub const fiber_executor = @import("execution/fiber_executor.zig").fiber_executor;
pub const BlockingPool = @import("execution/blocking_pool.zig").BlockingPool;

pub const ExecutionContext = context.ExecutionContext;
pub const DemandRole = context.DemandRole;
pub const ScopedImportFrame = context.ScopedImportFrame;
pub const FiberExecutor = port.FiberExecutor;
pub const Worker = worker.Worker;
pub const WorkerFiber = worker.WorkerFiber;

test {
    _ = worker;
    _ = fiber_executor;
    _ = @import("execution/tests/worker.zig");
}
