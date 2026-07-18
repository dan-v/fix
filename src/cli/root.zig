//! `fix` command-line application boundary.

pub const commands = @import("commands/root.zig");
pub const command_match = @import("command_match.zig");
pub const presentation = @import("presentation.zig");
pub const ProcessContext = @import("process_context.zig").ProcessContext;
pub const thunks_log_enabled = @import("expr").vm.thunks_log_enabled;
pub const vm_trace_enabled = @import("expr").vm.trace_log.enabled;

test {
    _ = commands;
    _ = command_match;
    _ = @import("args.zig");
    _ = @import("build_progress.zig");
    _ = @import("debugger.zig");
    _ = @import("eval_support.zig");
    _ = @import("fileish.zig");
    _ = @import("nix_conf.zig");
    _ = presentation;
    _ = @import("progress.zig");
    _ = @import("realize.zig");
    _ = @import("render.zig");
    _ = @import("setup.zig");
    _ = @import("stats.zig");
    _ = @import("trace_setup.zig");
}
