//! `fix thunks` command dispatch.

const std = @import("std");
const presentation = @import("../presentation.zig");
const render = @import("../render.zig");
const diff = @import("../thunks/diff.zig");

pub fn run(_: @import("../process_context.zig").ProcessContext, init: std.process.Init, args_iter: *std.process.Args.Iterator) !u8 {
    const subcommand = args_iter.next() orelse {
        render.usageError(init.io, init.environ_map, "missing subcommand", null, diff.usage);
        return 2;
    };
    if (std.mem.eql(u8, subcommand, "diff")) return diff.run(init, args_iter);
    if (presentation.isHelpFlag(subcommand)) {
        presentation.printHelp(init.io, diff.usage);
        return 0;
    }
    render.usageError(init.io, init.environ_map, "unknown subcommand", subcommand, diff.usage);
    return 2;
}
