//! Work-stealing scheduler subsystem facade.

const core = @import("scheduler/core.zig");

pub const Config = core.Config;
pub const GcMarkHook = core.GcMarkHook;
pub const ScanCensus = core.ScanCensus;
pub const Task = core.Task;
pub const Lane = core.Lane;
pub const ReadyNode = core.ReadyNode;
pub const Scheduler = core.Scheduler;
pub const scanCensus = core.scanCensus;

test {
    _ = core;
}
