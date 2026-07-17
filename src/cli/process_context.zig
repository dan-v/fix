//! Process-owned capabilities handed explicitly to subcommands.

const std = @import("std");
const engine = @import("nix");

pub const ProcessContext = struct {
    allocator: std.mem.Allocator,
    eval_release: ?engine.ReleaseAction = null,
};
