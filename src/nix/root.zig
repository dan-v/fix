//! Nix language implementation and evaluation engine.
//!
//! This is the public group facade. The files below it are namespaces, not
//! separate build modules; consumers reach them through `@import("nix")`.

pub const base = @import("base");
pub const runtime = @import("runtime");
pub const syntax = @import("syntax");
pub const types = runtime.types;
pub const value = runtime.value;
pub const stable_segments = base.segments;
pub const token = syntax.token;
pub const scanner = syntax.scanner;
pub const string_syntax = syntax.string_syntax;
pub const ast = syntax.ast;
pub const parser = syntax.parser;
pub const bytecode = @import("bytecode.zig");
pub const opcode = bytecode.opcode;
pub const chunk = bytecode.chunk;
pub const heap = runtime.heap;
pub const gc = runtime.gc;
pub const compiler = @import("compiler.zig");
pub const intern = runtime.intern;
pub const thunk = runtime.thunk;
pub const scheduler = @import("scheduler.zig");
pub const fiber = base.fiber;
pub const worker = @import("vm.zig").worker;
pub const file_cache = @import("host.zig").file_cache;
pub const host = @import("host.zig");
pub const vm = @import("vm.zig");
pub const probe = @import("probe.zig");
pub const observ = @import("observ.zig");
pub const eval = @import("eval.zig");
pub const eval_gc = @import("eval/gc.zig");
pub const eval_progress = observ.progress;
pub const builtins = runtime.builtins;
pub const derivation = @import("derivation.zig");
pub const realization = @import("realization.zig");
pub const diagnostic = syntax.diagnostic;
pub const process_support = @import("process_support.zig");

pub const Evaluator = eval.Evaluator;
pub const Value = value.Value;
pub const DebugSession = eval.DebugSession;
pub const DebugFrame = eval.DebugFrame;
pub const BreakReason = eval.BreakReason;

pub fn reportSchedulerScanCensus() void {
    scheduler.reportScanCensus();
}

test {
    _ = @import("root/tests.zig");
    _ = @import("realization/tests.zig");
    _ = @import("realization/recipe_tests.zig");
    _ = @import("test_daemon.zig");
    _ = stable_segments;
    _ = fiber;
    _ = worker;
}
