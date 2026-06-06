//! fix — A blazing fast Nix evaluator.
//!
//! Public API surface. Re-exports the evaluator and types for consumers.

pub const types = @import("runtime/types.zig");
pub const value = @import("runtime/value.zig");
pub const stable_segments = @import("runtime/stable_segments.zig");
pub const token = @import("token.zig");
pub const scanner = @import("scanner.zig");
pub const string_syntax = @import("string_syntax.zig");
pub const ast = @import("ast.zig");
pub const parser = @import("parser.zig");
pub const bytecode = @import("bytecode.zig");
pub const opcode = bytecode.opcode;
pub const chunk = bytecode.chunk;
pub const heap = @import("runtime/heap.zig");
pub const compiler = @import("compiler.zig");
pub const intern = @import("runtime/intern.zig");
pub const thunk = @import("runtime/thunk.zig");
pub const scheduler = @import("scheduler.zig");
pub const file_cache = @import("file_cache.zig");
pub const vm = @import("vm.zig");
pub const eval = @import("eval.zig");
pub const builtins = @import("builtins.zig");
pub const derivation = @import("derivation.zig");
pub const diagnostic = @import("diagnostic.zig");

pub const Evaluator = eval.Evaluator;
pub const Value = value.Value;

test {
    _ = @import("root/tests.zig");
    _ = stable_segments;
}
