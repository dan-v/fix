//! CLI facade: commands plus shared presentation and workflow modules.

pub const args = @import("args.zig");
pub const eval_support = @import("eval_support.zig");
pub const setup = @import("setup.zig");
pub const nix_conf = @import("nix_conf.zig");
pub const eval = @import("eval.zig");
pub const parse = @import("parse.zig");
pub const instantiate = @import("instantiate.zig");
pub const build = @import("build.zig");
pub const run = @import("run.zig");
pub const shell = @import("shell.zig");
pub const @"switch" = @import("switch.zig");
pub const build_progress = @import("build_progress.zig");
pub const repl = @import("repl.zig");
pub const disasm = @import("disasm.zig");
pub const inspect = @import("inspect.zig");
pub const trace = @import("trace.zig");
pub const thunks = @import("thunks.zig");
pub const store = @import("store.zig");
pub const stats = @import("stats.zig");
pub const trace_setup = @import("trace_setup.zig");
pub const render = @import("render.zig");
pub const presentation = @import("presentation.zig");
pub const progress = @import("progress.zig");
pub const realization = @import("realize.zig");

pub const When = presentation.When;
pub const Style = presentation.Style;
pub const Stderr = presentation.Stderr;
pub const EvalProgress = progress.EvalProgress;
pub const Realized = realization.Realized;
pub const RealizeResult = realization.Result;

pub const parseWhen = presentation.parseWhen;
pub const printHelp = presentation.printHelp;
pub const isHelpFlag = presentation.isHelpFlag;
pub const isStderrInteractive = presentation.isStderrInteractive;
pub const shouldColor = presentation.shouldColor;
pub const autoColor = presentation.autoColor;
pub const shouldProgress = presentation.shouldProgress;
pub const styleCode = presentation.styleCode;
pub const resetCode = presentation.resetCode;
pub const style = presentation.style;
pub const reset = presentation.reset;
pub const writeLabel = presentation.writeLabel;
pub const lockStderr = presentation.lockStderr;
pub const writeMaybePath = presentation.writeMaybePath;
pub const isPathLike = presentation.isPathLike;
pub const realize = realization.realize;

test {
    _ = presentation;
    _ = progress;
    _ = realization;
}
