//! fix — A blazing fast Nix evaluator.
//!
//! Public API surface. Re-exports the evaluator and types for consumers.

pub const types = @import("runtime").types;
pub const value = @import("runtime").value;
pub const stable_segments = @import("base").segments;
pub const token = @import("syntax").token;
pub const scanner = @import("syntax").scanner;
pub const string_syntax = @import("syntax").string_syntax;
pub const ast = @import("syntax").ast;
pub const parser = @import("syntax").parser;
pub const bytecode = @import("bytecode");
pub const opcode = bytecode.opcode;
pub const chunk = bytecode.chunk;
pub const heap = @import("runtime").heap;
pub const compiler = @import("compiler");
pub const intern = @import("runtime").intern;
pub const thunk = @import("runtime").thunk;
pub const scheduler = @import("scheduler");
pub const fiber = @import("base").fiber;
pub const worker = @import("vm").worker;
pub const file_cache = @import("host").file_cache;
pub const host = @import("host");
pub const vm = @import("vm");
pub const probe = @import("probe");
pub const eval = @import("eval.zig");
pub const eval_gc = @import("eval/gc.zig");
pub const eval_progress = @import("observ").progress;
pub const builtins = @import("runtime").builtins;
pub const derivation = @import("derivation");
pub const diagnostic = @import("syntax").diagnostic;

pub const Evaluator = eval.Evaluator;
pub const Value = value.Value;
pub const DebugSession = eval.DebugSession;
pub const DebugFrame = eval.DebugFrame;
pub const BreakReason = eval.BreakReason;

test {
    _ = @import("root/tests.zig");
    _ = stable_segments;
    _ = fiber;
    _ = worker;
}
