//! Engine worker runtime: work-stealing scheduler, fiber workers,
//! fiber-scoped execution context, and blocking-work parking adapter.

pub const scheduler = @import("workers/scheduler.zig");
pub const context = @import("workers/context.zig");
pub const port = @import("workers/port.zig");
pub const worker = @import("workers/worker.zig");
pub const fiber_executor = @import("workers/fiber_executor.zig").fiber_executor;
pub const daemon_executor = @import("workers/daemon_executor.zig").executor;

pub const Config = scheduler.Config;
pub const GcMarkHook = scheduler.GcMarkHook;
pub const ScanCensus = scheduler.ScanCensus;
pub const Task = scheduler.Task;
pub const Lane = scheduler.Lane;
pub const ReadyNode = scheduler.ReadyNode;
pub const Scheduler = scheduler.Scheduler;
pub const scanCensus = scheduler.scanCensus;

pub const ExecutionContext = context.ExecutionContext;
pub const DemandRole = context.DemandRole;
pub const ScopedImportFrame = context.ScopedImportFrame;
pub const FiberExecutor = port.FiberExecutor;
pub const Worker = worker.Worker;
pub const WorkerFiber = worker.WorkerFiber;
pub const BlockingPool = @import("base").BlockingPool;

test {
    _ = scheduler;
    _ = worker;
    _ = fiber_executor;
    _ = daemon_executor;
    _ = @import("workers/tests/worker.zig");
    _ = @import("workers/concurrency_tests.zig");
}
