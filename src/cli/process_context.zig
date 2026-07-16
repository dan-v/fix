//! Process-owned capabilities handed explicitly to subcommands.

const std = @import("std");
const engine = @import("nix");

pub const ProcessContext = struct {
    allocator: std.mem.Allocator,
    eval_release: ?engine.ReleaseHook = null,

    pub fn bindEvaluator(self: ProcessContext, ev: *engine.Evaluator) void {
        ev.setReleaseHook(self.eval_release);
    }
};
