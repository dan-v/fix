//! Bytecode VM facade: state, execution driver, and VM operations.

pub const context = @import("vm/context.zig");
pub const builtins = @import("vm/builtins.zig");
pub const run = @import("vm/run.zig");
pub const equality = @import("vm/equality.zig");
pub const force = @import("vm/force.zig");
pub const objects = @import("vm/objects.zig");
pub const strings = @import("vm/strings.zig");
pub const closures = @import("vm/closures.zig");
pub const errors = @import("vm/errors.zig");
pub const access = @import("vm/access.zig");
pub const stack = @import("vm/stack.zig");
pub const trace = @import("vm/trace.zig");
pub const debug = @import("vm/debug.zig");
pub const trace_log = @import("vm/trace_log.zig");

const driver_mod = @import("vm/driver.zig");

pub const VM = context.VM;
pub const Driver = context.Driver;
pub const driver = driver_mod.driver;
pub const BufferPool = context.BufferPool;
pub const Frame = context.Frame;
pub const ImportHost = context.ImportHost;
pub const BreakReason = context.BreakReason;
pub const BreakSink = context.BreakSink;
pub const no_spec_budget = context.no_spec_budget;
pub const thunks_log_enabled = context.thunks_log_enabled;
pub const readU16 = context.readU16;
pub const readU32 = context.readU32;
pub const readInternId = context.readInternId;

test {
    _ = driver;
    _ = builtins;
    _ = @import("vm/tests.zig");
}
