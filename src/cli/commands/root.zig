//! User-facing `fix` subcommands.

pub const eval = @import("eval.zig");
pub const parse = @import("parse.zig");
pub const instantiate = @import("instantiate.zig");
pub const build = @import("build.zig");
pub const run = @import("run.zig");
pub const shell = @import("shell.zig");
pub const @"switch" = @import("switch.zig");
pub const repl = @import("repl.zig");
pub const disasm = @import("disasm.zig");
pub const inspect = @import("inspect.zig");
pub const trace = @import("trace.zig");
pub const thunks = @import("thunks.zig");
pub const store = @import("store.zig");
