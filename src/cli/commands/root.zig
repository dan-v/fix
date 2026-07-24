//! User-facing `fix` subcommands.

const thunks_log_enabled = @import("expr").vm.thunks_log_enabled;
const vm_trace_enabled = @import("expr").vm.trace_log.enabled;

pub const eval = @import("eval.zig");
pub const flake = @import("flake.zig");
pub const completions = @import("completions.zig");
pub const parse = @import("parse.zig");
pub const instantiate = @import("instantiate.zig");
pub const build = @import("build.zig");
pub const run = @import("run.zig");
pub const shell = @import("shell.zig");
pub const @"switch" = @import("switch.zig");
pub const repl = @import("repl.zig");
pub const disasm = @import("disasm.zig");
pub const trace = if (vm_trace_enabled) @import("trace.zig") else struct {};
pub const thunks = if (thunks_log_enabled) @import("thunks.zig") else struct {};
