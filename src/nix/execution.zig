//! Compatibility facade for the evaluator-owned worker runtime.

const workers = @import("eval/workers.zig");

pub const context = workers.context;
pub const port = workers.port;
pub const worker = workers.worker;
pub const fiber_executor = workers.fiber_executor;
pub const BlockingPool = workers.BlockingPool;

pub const ExecutionContext = workers.ExecutionContext;
pub const DemandRole = workers.DemandRole;
pub const ScopedImportFrame = workers.ScopedImportFrame;
pub const FiberExecutor = workers.FiberExecutor;
pub const Worker = workers.Worker;
pub const WorkerFiber = workers.WorkerFiber;
