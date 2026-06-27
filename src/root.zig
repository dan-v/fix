//! fix — A blazing fast Nix evaluator.
//!
//! Public API surface. Re-exports the evaluator and types for consumers.

pub const types = @import("runtime/types.zig");
pub const value = @import("runtime/value.zig");
pub const stable_segments = @import("runtime/stable_segments.zig");
pub const token = @import("syntax").token;
pub const scanner = @import("syntax").scanner;
pub const string_syntax = @import("syntax").string_syntax;
pub const ast = @import("syntax").ast;
pub const parser = @import("syntax").parser;
pub const bytecode = @import("bytecode.zig");
pub const opcode = bytecode.opcode;
pub const chunk = bytecode.chunk;
pub const heap = @import("runtime/heap.zig");
pub const compiler = @import("compiler.zig");
pub const intern = @import("runtime/intern.zig");
pub const thunk = @import("runtime/thunk.zig");
pub const scheduler = @import("scheduler.zig");
pub const fiber = @import("fiber.zig");
pub const worker = @import("eval/worker.zig");
pub const file_cache = @import("file_cache.zig");
pub const vm = @import("vm.zig");
pub const eval = @import("eval.zig");
pub const builtins = @import("builtins.zig");
pub const derivation = @import("derivation.zig");
pub const diagnostic = @import("syntax").diagnostic;

pub const Evaluator = eval.Evaluator;
pub const Value = value.Value;

test {
    _ = @import("root/tests.zig");
    _ = stable_segments;
    _ = fiber;
    _ = worker;
}
