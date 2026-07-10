//! Compiles a sub-expression into its own thunk chunk and chooses the
//! emission mode: plain lazy `thk`, eager-spawn (strictness says
//! it will be forced), or runtime-adaptive `thk_arg` (callee decides),
//! with trivial-bodied args falling back to a plain thunk.
//! `finishCompiledChild` is the shared funnel so the force-time deferred
//! compile reuses the exact eager child-body path.

const std = @import("std");
const compiler_mod = @import("../compiler.zig");
const ast = @import("syntax").ast;
const chunk = @import("bytecode").chunk;
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
    return try child.registerChunk(child_chunk);
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
    var child_builder = try self.acquireBuilder();
    defer self.releaseBuilder(&child_builder);

    var child = self.initChild(&child_builder);
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

/// Compile a function argument as a runtime-adaptive `thk_arg` (the
/// callee, already on the stack, decides thunk-vs-eager at run time).
/// Trivial-body args fall back to a plain `thk`: they
/// short-circuit to a value with no thunk either way, so the adaptive
/// runtime check would be pure overhead.
pub fn compileApplyArgThunk(self: *Compiler, expr: *const Node) !void {
    var child_builder = try self.acquireBuilder();
    defer self.releaseBuilder(&child_builder);

    var child = self.initChild(&child_builder);
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
    const child_id = try child.registerChunk(child_chunk);
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
