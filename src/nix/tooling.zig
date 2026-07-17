//! Explicit expert/tooling surface for CLI diagnostics and introspection.
//!
//! Ordinary consumers should use the narrow declarations in `root.zig`.
//! Commands that intentionally inspect bytecode, VM traces, scheduler state,
//! or runtime representation opt into those unstable details through here.

pub const runtime = @import("runtime");
pub const syntax = @import("syntax");
pub const bytecode = @import("tooling/bytecode.zig");
pub const compiler = @import("compiler.zig");
pub const scheduler = @import("scheduler.zig");
pub const execution = @import("execution.zig");
pub const workers = @import("eval/workers.zig");
pub const host = @import("host.zig");
pub const vm = @import("vm.zig");
pub const probe = @import("probe.zig");
pub const observ = @import("observ.zig");
pub const eval = @import("eval.zig");
pub const derivation = @import("derivation.zig");
pub const realization = @import("realization.zig");
pub const language = @import("language.zig");
