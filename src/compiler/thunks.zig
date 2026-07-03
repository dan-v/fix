const std = @import("std");
const compiler_mod = @import("../compiler.zig");
const ast = @import("syntax").ast;
const chunk = @import("../bytecode.zig").chunk;
const emit = @import("emit.zig");
const diagnostics = @import("diagnostics.zig");

const Compiler = compiler_mod.Compiler;
const Node = compiler_mod.Node;
const ChunkBuilder = chunk.ChunkBuilder;
const strictness = @import("strictness.zig");

const ChunkId = @import("runtime").types.ChunkId;

/// Shared tail of every child-body compile (eager thunks, apply-args, and
/// the force-time deferred-attr compile): stamp strictness, terminate,
/// finish, register. The caller has already run `child.compileNode(expr)`
/// (and handled diagnostics). Returns the registered ChunkId. This is the
/// "one funnel" so deferred compilation reuses the exact eager path.
pub fn finishCompiledChild(child: *Compiler, child_builder: *ChunkBuilder, expr: *const Node) !ChunkId {
    try strictness.stampOnBuilder(child, expr);
    try emit.emitRet(child);
    try emit.emitOp(child, .halt);
    const child_chunk = try child_builder.finish(child.persistent, child.slot_count);
    return try child.registry.register(child_chunk);
}

pub fn compileThunk(self: *Compiler, expr: *const Node) !void {
    return compileThunkEager(self, expr, false);
}

/// Same as `compileThunk`, but emits the eager-spawn variant if
/// `eager` is true — the resulting thunk gets submitted to the
/// scheduler's urgent queue at creation. Called from let-binding
/// compile when strictness analysis on the let-body confirms the
/// binding will be forced.
pub fn compileThunkEager(self: *Compiler, expr: *const Node, eager: bool) !void {
    var child_builder = try ChunkBuilder.init(self.allocator);
    defer child_builder.deinit(self.allocator);

    var child = Compiler.init(
        self.allocator,
        self.persistent,
        &child_builder,
        self.registry,
        self.source,
        self.intern,
        self.heap,
    );
    child.parent = self;
    child.base_path = self.base_path;
    child.source_path = self.source_path;
    child.source_file_id = self.source_file_id;
    defer child.deinit();

    child.compileNode(expr) catch |err| {
        try diagnostics.absorbChildDiagnostics(self, &child);
        return err;
    };
    const child_id = try finishCompiledChild(&child, &child_builder, expr);
    if (eager) {
        try emit.emitEagerThunkWithCaptures(self, child_id, child.captures.items);
    } else {
        try emit.emitThunkWithCaptures(self, child_id, child.captures.items);
    }
}

/// Compile a function argument as a runtime-adaptive `apply_arg` (the
/// callee, already on the stack, decides thunk-vs-eager at run time).
/// Trivial-body args fall back to a plain `thunk_captures`: they
/// short-circuit to a value with no thunk either way, so the adaptive
/// runtime check would be pure overhead.
pub fn compileApplyArgThunk(self: *Compiler, expr: *const Node) !void {
    var child_builder = try ChunkBuilder.init(self.allocator);
    defer child_builder.deinit(self.allocator);

    var child = Compiler.init(
        self.allocator,
        self.persistent,
        &child_builder,
        self.registry,
        self.source,
        self.intern,
        self.heap,
    );
    child.parent = self;
    child.base_path = self.base_path;
    child.source_path = self.source_path;
    child.source_file_id = self.source_file_id;
    defer child.deinit();

    child.compileNode(expr) catch |err| {
        try diagnostics.absorbChildDiagnostics(self, &child);
        return err;
    };
    try strictness.stampOnBuilder(&child, expr);
    try emit.emitRet(&child);
    try emit.emitOp(&child, .halt);

    const child_chunk = try child_builder.finish(self.persistent, child.slot_count);
    const trivial = child_chunk.scheduling.trivial != .none;
    const child_id = try self.registry.register(child_chunk);
    if (trivial) {
        try emit.emitThunkWithCaptures(self, child_id, child.captures.items);
    } else {
        try emit.emitApplyArg(self, child_id, child.captures.items);
    }
}

pub fn compileStringAtomThunk(self: *Compiler, atom: Node.Atom) !void {
    var node = Node{
        .tag = .string,
        .data = .{ .atom = atom },
        .span = atom,
    };
    try compileThunk(self, &node);
}

const fix = @import("../root.zig");
const Evaluator = fix.Evaluator;

test "an unforced let binding thunk never evaluates its erroring body" {
    // `compileThunk` defers the body; if `b` were compiled/run eagerly,
    // the division by zero would raise before `a` is even returned.
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    const result = try ev.evaluate("let a = 1; b = 1 / 0; in a");
    try std.testing.expectEqual(@as(i64, 1), result.asInt());
}

test "a strict let binding is still forced exactly to its value" {
    // Exercises the eager-thunk path (`compileThunkEager`) taken when
    // strictness analysis shows the binding is used unconditionally.
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    const result = try ev.evaluate("let a = 1 + 1; in a + a");
    try std.testing.expectEqual(@as(i64, 4), result.asInt());
}

test "function call arguments are compiled as adaptive apply-arg thunks" {
    // Exercises `compileApplyArgThunk`: the callee decides thunk-vs-eager
    // at runtime, but either way an unused argument must stay lazy...
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    const unused = try ev.evaluate("(x: 1) (1 / 0)");
    try std.testing.expectEqual(@as(i64, 1), unused.asInt());

    // ...and a used argument must still evaluate to the right value.
    const used = try ev.evaluate("(x: x + 1) 41");
    try std.testing.expectEqual(@as(i64, 42), used.asInt());
}
