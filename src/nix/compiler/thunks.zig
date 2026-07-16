//! Compiles a sub-expression into its own thunk chunk and chooses the
//! emission mode: plain lazy `thunk`, eager-spawn (strictness says
//! it will be forced), or runtime-adaptive `thunk_arg` (callee decides),
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
const lambda = @import("lambda.zig");

const ChunkId = @import("runtime").types.ChunkId;

/// Stamp strictness, terminate, and finish the child chunk WITHOUT
/// registering it — so callers can elide provably-trivial chunks before they
/// ever reach the registry.
fn finishChildChunk(child: *Compiler, child_builder: *ChunkBuilder, expr: *const Node) !chunk.Chunk {
    try strictness.stampOnBuilder(child, expr);
    try emit.emitRet(child);
    try emit.emitOp(child, .halt);
    return child_builder.finish(child.persistent, child.slot_count);
}

/// Shared tail of every child-body compile (eager thunks, apply-args, and
/// the force-time deferred-attr compile): stamp strictness, terminate,
/// finish, register. The caller has already run `child.compileNode(expr)`
/// (and handled diagnostics). Returns the registered ChunkId. This is the
/// "one funnel" so deferred compilation reuses the exact eager path. (The
/// deferred path never elides: its thunk is already live and must have a
/// chunk to run.)
pub fn finishCompiledChild(child: *Compiler, child_builder: *ChunkBuilder, expr: *const Node) !ChunkId {
    const child_chunk = try finishChildChunk(child, child_builder, expr);
    return try child.registerChunk(child_chunk);
}

/// Compile-time twin of the runtime trivial-body short-circuit
/// (`vm/closures.zig makeBytecodeThunkFromCaptures`): the classifier already
/// proved forcing this chunk's thunk produces a value we can express directly
/// in the PARENT, so emit that and never register the chunk. The runtime
/// short-circuit is the proof of semantic equivalence — it, too, never
/// dispatches these bodies. Returns true when elided (caller must deinit the
/// unregistered chunk).
fn elideTrivialChild(self: *Compiler, child: *Compiler, ch: *const chunk.Chunk) !bool {
    const caps = child.captures.items;
    switch (ch.scheduling.trivial) {
        .none => return false,
        .identity_upvalue => |idx| {
            // The thunk would force to capture #idx's value, unforced — the
            // parent can push that slot/upvalue directly (same laziness).
            if (idx >= caps.len) return false;
            switch (caps[idx].kind) {
                .local => try emit.emitCaptureLocal(self, caps[idx].index),
                .upvalue => try emit.emitOpU16(self, .up_grab, caps[idx].index),
            }
        },
        .attr_access => |aa| {
            // Same frameless attr-access thunk the runtime would create.
            if (aa.upvalue_index >= caps.len) return false;
            try emit.emitThunkAttr(self, caps[aa.upvalue_index], aa.name);
        },
        .literal => |val| try self.builder.emitConstant(self.allocator, val),
        .builtins => try emit.emitOp(self, .push_builtins),
        .closure_zero => |cl_id| try emit.emitClosure(self, cl_id, 0),
        .closure_captures => |info| {
            // Inner descriptors are all kind=upvalue indexing the child's
            // capture list (classifier guarantee); each maps to a parent-side
            // capture, so the composed closure emits directly in the parent.
            const inner = ch.code[info.inner_descriptors_offset..][0..info.inner_descriptors_len];
            var composed: [64]compiler_mod.Capture = undefined;
            const k = inner.len / 3;
            if (k > composed.len) return false;
            var i: usize = 0;
            while (i < k) : (i += 1) {
                if (inner[i * 3] != 1) return false;
                const idx = std.mem.readInt(u16, inner[i * 3 + 1 ..][0..2], .little);
                if (idx >= caps.len) return false;
                composed[i] = caps[idx];
            }
            try emit.emitClosureWithCaptures(self, info.closure_chunk_id, composed[0..k]);
        },
    }
    return true;
}

pub fn compileThunk(self: *Compiler, expr: *const Node) !void {
    return compileThunkEager(self, expr, false);
}

/// Compile a list element into a genuine, unforced, lazy thunk — never
/// eager, and (unlike `compileThunk`) never elided to a folded literal.
/// Nix's `Expr::maybeThunk` wraps every non-trivial list element in a fresh
/// thunk, so a non-strict print renders it as `<CODE>`. fix's ordinary thunk
/// path folds/eliminates trivial bodies (e.g. `1 + 1` -> constant `2`), which
/// would print the value instead. Keeping the thunk unresolved here is what
/// makes `[ (1 + 1) ]` render `[ <CODE> ]` like Nix. In `--strict` mode the
/// thunk is forced anyway, so the observable result is unchanged there.
pub fn compileListElementThunk(self: *Compiler, expr: *const Node) !void {
    self.armNodeTagName(expr);
    var child_builder = try self.acquireBuilder();
    defer self.releaseBuilder(&child_builder);

    var child = self.initChild(&child_builder);
    defer child.deinit();

    child.compileNode(expr) catch |err| {
        try diagnostics.absorbChildDiagnostics(self, &child);
        return err;
    };
    var child_chunk = try finishChildChunk(&child, &child_builder, expr);
    // Suppress the runtime trivial-body short-circuit (`makeBytecodeThunkFromCaptures`):
    // a `.literal`/`.closure_zero` classification would push the folded value or
    // closure directly instead of allocating a thunk, so `[ (1 + 1) ]` / `[ (x: x) ]`
    // would print `[ 2 ]` / `[ <LAMBDA> ]`. Forcing `.none` keeps a genuine unforced
    // thunk, which renders as `<CODE>` (Nix parity). Under `--strict` the thunk is
    // forced regardless, so the value is unchanged.
    child_chunk.scheduling.trivial = .none;
    const child_id = try child.registerChunk(child_chunk);
    try emit.emitThunkWithCaptures(self, child_id, child.captures.items);
}

/// Same as `compileThunk`, but emits the eager-spawn variant if
/// `eager` is true — the resulting thunk gets submitted to the
/// scheduler's urgent queue at creation. Called from let-binding
/// compile when strictness analysis on the let-body confirms the
/// binding will be forced.
pub fn compileThunkEager(self: *Compiler, expr: *const Node, eager: bool) !void {
    self.armNodeTagName(expr);
    var child_builder = try self.acquireBuilder();
    defer self.releaseBuilder(&child_builder);

    var child = self.initChild(&child_builder);
    defer child.deinit();

    // A thunk body's final expression is in tail position (the chunk computes
    // it and returns), so compile it as a tail expression — matching lambda
    // bodies. A trailing apply becomes `call_tail`, reusing the thunk's frame
    // instead of pushing a callee frame that returns straight into a `ret`
    // (the `ret->ret` forwarding pattern). Gives thunk bodies O(1) tail-stack
    // like lambdas; perf-neutral, kept for consistency/robustness.
    lambda.compileTailExpression(&child, expr) catch |err| {
        try diagnostics.absorbChildDiagnostics(self, &child);
        return err;
    };
    var child_chunk = try finishChildChunk(&child, &child_builder, expr);
    // Trivial bodies never register: the parent emits the value directly
    // (eagerness is moot — there is nothing left to schedule).
    if (try elideTrivialChild(self, &child, &child_chunk)) {
        child_chunk.deinit(child.persistent);
        return;
    }
    const child_id = try child.registerChunk(child_chunk);
    if (eager) {
        try emit.emitEagerThunkWithCaptures(self, child_id, child.captures.items);
    } else {
        try emit.emitThunkWithCaptures(self, child_id, child.captures.items);
    }
}

/// Compile a function argument as a runtime-adaptive `thunk_arg` (the
/// callee, already on the stack, decides thunk-vs-eager at run time).
/// Trivial-body args are elided outright: they short-circuit to a value
/// with no thunk either way, so both the chunk and the adaptive runtime
/// check disappear.
pub fn compileApplyArgThunk(self: *Compiler, expr: *const Node) !void {
    self.armNodeTagName(expr);
    var child_builder = try self.acquireBuilder();
    defer self.releaseBuilder(&child_builder);

    var child = self.initChild(&child_builder);
    defer child.deinit();

    child.compileNode(expr) catch |err| {
        try diagnostics.absorbChildDiagnostics(self, &child);
        return err;
    };
    var child_chunk = try finishChildChunk(&child, &child_builder, expr);
    if (try elideTrivialChild(self, &child, &child_chunk)) {
        child_chunk.deinit(child.persistent);
        return;
    }
    const child_id = try child.registerChunk(child_chunk);
    try emit.emitApplyArg(self, child_id, child.captures.items);
}

pub fn compileStringAtomThunk(self: *Compiler, atom: Node.Atom) !void {
    var node = Node{
        .tag = .string,
        .data = .{ .atom = atom },
        .span = atom,
    };
    try compileThunk(self, &node);
}
