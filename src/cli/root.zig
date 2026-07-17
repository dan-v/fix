//! `fix` command-line application boundary.

pub const commands = @import("commands/root.zig");
pub const presentation = @import("presentation.zig");
pub const ProcessContext = @import("process_context.zig").ProcessContext;

test {
    _ = commands;
    _ = @import("args.zig");
    _ = @import("build_progress.zig");
    _ = @import("debugger.zig");
    _ = @import("derivation_debug.zig");
    _ = @import("eval_support.zig");
    _ = @import("nix_conf.zig");
    _ = presentation;
    _ = @import("progress.zig");
    _ = @import("realize.zig");
    _ = @import("render.zig");
    _ = @import("setup.zig");
    _ = @import("stats.zig");
    _ = @import("trace_setup.zig");
}
