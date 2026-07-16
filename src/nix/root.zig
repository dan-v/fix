//! Nix language implementation and evaluation engine.
//!
//! This is the public group facade. The files below it are namespaces, not
//! separate build modules; consumers reach them through `@import("nix")`.

pub const runtime = @import("runtime");
pub const syntax = @import("syntax");
pub const bytecode = @import("bytecode.zig");
pub const compiler = @import("compiler.zig");
pub const policy = @import("policy.zig");
pub const scheduler = @import("scheduler.zig");
pub const host = @import("host.zig");
pub const vm = @import("vm.zig");
pub const probe = @import("probe.zig");
pub const observ = @import("observ.zig");
pub const eval = @import("eval.zig");
pub const derivation = @import("derivation.zig");
pub const realization = @import("realization.zig");
pub const process_support = @import("process_support.zig");

pub const Evaluator = eval.Evaluator;
pub const StoreState = eval.StoreState;
pub const BuildSession = eval.BuildSession;
pub const Value = runtime.value.Value;
pub const DebugSession = eval.DebugSession;
pub const DebugFrame = eval.DebugFrame;
pub const BreakReason = eval.BreakReason;

pub fn reportSchedulerScanCensus() void {
    scheduler.reportScanCensus();
}

test {
    _ = @import("root/tests.zig");
    _ = @import("realization/tests.zig");
    _ = @import("realization/recipe_tests.zig");
    _ = @import("test_daemon.zig");
}
