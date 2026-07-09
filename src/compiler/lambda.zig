//! Lowers lambdas and function application into chunks: value-lambda
//! uncurrying (`a: b: …` → one multi-param chunk), attrset-pattern lambdas
//! (formal validation, defaults, mutually-recursive binding cells), and
//! call-spine flattening into `call_n`/`tail_call_n`.
//! Emits per-chunk strictness metadata (`strict_param`/`strict_params`/
//! forwarding upvalue) that drives eager-vs-lazy argument passing.

const std = @import("std");
const compiler_mod = @import("../compiler.zig");
const ast = @import("syntax").ast;
const bytecode = @import("bytecode");
const chunk = bytecode.chunk;
const heap_mod = @import("runtime").heap;
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const OpCode = bytecode.OpCode;
const emit = @import("emit.zig");
const scope = @import("scope.zig");
const thunks = @import("thunks.zig");
const diagnostics = @import("diagnostics.zig");
const access = @import("access.zig");
const control = @import("control.zig");
const strictness = @import("strictness.zig");
const let = @import("let.zig");
const refs_mod = @import("refs.zig");

const Compiler = compiler_mod.Compiler;
const Node = compiler_mod.Node;
const InternId = types.InternId;
const ChunkBuilder = chunk.ChunkBuilder;
const diagnostic_atom = @import("diagnostic_atom.zig");
const diagnosticAtom = diagnostic_atom.diagnosticAtom;
const unwrapParens = ast.unwrapParens;

pub fn compileApply(self: *Compiler, node: *const Node) !void {
    try compileApplyWithOp(self, node, .call);
}

pub fn compileTailExpression(self: *Compiler, node: *const Node) anyerror!void {
    const unwrapped = unwrapParens(node);
    switch (unwrapped.tag) {
        .apply, .if_else, .let_in, .assert, .with_expr => {},
        else => return self.compileNode(node),
    }

    {
        const start = self.builder.code.items.len;
        try compileTailNodeImpl(self, unwrapped);
        const end = self.builder.code.items.len;
        if (try diagnostics.sourceSpanForNode(self, node)) |span| {
            try self.builder.addSourceMapEntry(self.allocator, start, end, span);
        }
        return;
    }
}

fn compileTailNodeImpl(self: *Compiler, node: *const Node) anyerror!void {
    switch (node.tag) {
        .apply => try compileApplyWithOp(self, node, .tail_call),
        .if_else => try control.compileIfElseTail(self, node),
        .let_in => try let.compileLetInWithTailBody(self, node),
        .assert => try control.compileAssertTail(self, node),
        .with_expr => try control.compileWithTail(self, node),
        else => unreachable,
    }
}

/// Compile one argument of a flattened `call_n` spine. We deliberately do
/// NOT use the runtime-adaptive `apply_arg` op here: its eager-vs-thunk
/// check reads the callee at `stack[sp-1]`, which is the real callee only
/// for the *first* spine arg (later args would see the previous arg). So
/// immediate container values stay thunk-free and everything else becomes
/// a plain lazy thunk; the saturated `call_n` path then eagerly forces the
/// arg positions the callee chunk marks must-force (`strict_params`),
/// recovering eager-arg behavior with the callee actually known.
fn compileSpineArg(self: *Compiler, arg: *const Node) !void {
    if (try access.compileImmediateContainerValue(self, arg, .{})) return;
    try thunks.compileThunk(self, arg);
}

fn compileApplyWithOp(self: *Compiler, node: *const Node, op: OpCode) !void {
    // Flatten the application spine `f a1 a2 ... aK` and, for K >= 2, emit
    // one `call_n K` instead of K nested `call`s. When the callee is an
    // uncurried (merged) closure of arity K this runs the body in a single
    // frame with no intermediate closure/PAP allocation; otherwise it
    // folds one arg at a time (same result). K == 1 keeps the original
    // single-arg path below (which still carries the eager-strict-arg and
    // tail-call-frame-reuse optimizations).
    {
        var args: [256]*const Node = undefined;
        var k: usize = 0;
        var head: *const Node = unwrapParens(node);
        while (head.tag == .apply and k < args.len) {
            args[k] = head.data.apply.arg;
            k += 1;
            head = unwrapParens(head.data.apply.func);
        }
        if (k >= 2 and head.tag != .apply) {
            // `args` is in reverse (last-applied first); emit head then
            // a1..aK in application order.
            try self.compileNode(head);
            var i: usize = k;
            while (i > 0) {
                i -= 1;
                try compileSpineArg(self, args[i]);
            }
            const call_op: OpCode = if (op == .tail_call) .tail_call_n else .call_n;
            try emit.emitOpByte(self, call_op, @intCast(k));
            return;
        }
    }

    const ap = node.data.apply;
    try self.compileNode(ap.func);
    // Directly-applied lambda `(x: body) arg` whose body unconditionally
    // forces `x`: evaluate `arg` straight onto the stack instead of
    // thunking it. The lambda forces it regardless, so this is sound
    // (same success/failure; only error ordering in a failing eval can
    // differ). Structural-builder args stay lazy (isEagerEvalShape).
    if (let.isEagerEvalShape(ap.arg) and try directlyAppliedStrictLambda(self, ap.func)) {
        // Statically-known strict callee: eager arg, no runtime check.
        try self.compileNode(ap.arg);
    } else if (try access.compileImmediateContainerValue(self, ap.arg, .{})) {
        // Immediate value (literal/empty list/...): already thunk-free.
    } else {
        // Dynamically-dispatched call: defer the thunk-vs-eager decision
        // to runtime via `apply_arg`, which reads the callee's strictness.
        try thunks.compileApplyArgThunk(self, ap.arg);
    }
    try emit.emitOp(self, op);
}

/// Detect the forwarding shape `param: f param` where `f` is a captured
/// free variable, returning `f`'s upvalue index (its position in the
/// child's capture list). The lambda then forces its parameter iff `f`
/// does — resolved at the call site. `null` when the body is not this
/// exact shape.
fn forwardingUpvalue(self: *Compiler, child: *Compiler, body: *const Node, param_name: []const u8) ?u16 {
    const b = unwrapParens(body);
    if (b.tag != .apply) return null;
    const func = unwrapParens(b.data.apply.func);
    const arg = unwrapParens(b.data.apply.arg);
    if (func.tag != .identifier or arg.tag != .identifier) return null;
    const arg_name = self.source[arg.data.atom.offset .. arg.data.atom.offset + arg.data.atom.len];
    if (!std.mem.eql(u8, arg_name, param_name)) return null;
    const func_name = self.source[func.data.atom.offset .. func.data.atom.offset + func.data.atom.len];
    if (std.mem.eql(u8, func_name, param_name)) return null;
    // Upvalue index == position in the child's capture list (upvalues
    // are staged from captures in order).
    for (child.captures.items, 0..) |cap, idx| {
        if (std.mem.eql(u8, cap.name, func_name)) {
            return if (idx <= std.math.maxInt(u16)) @intCast(idx) else null;
        }
    }
    return null;
}

/// True iff `func` is a `x: body` lambda whose body must-force its
/// parameter (so a caller may pass its argument eagerly).
fn directlyAppliedStrictLambda(self: *Compiler, func: *const Node) !bool {
    if (func.tag != .lambda) return false;
    const lambda = func.data.lambda;
    const param_name = self.source[lambda.param_offset .. lambda.param_offset + lambda.param_len];
    const param_id = try self.intern.intern(param_name);
    return strictness.bodyMustForceName(self.allocator, self.intern, self.source, lambda.body, param_id);
}

pub fn compileLambda(self: *Compiler, node: *const Node) !void {
    // Uncurry: collect the maximal chain of adjacent *value* lambdas
    // `a: b: ...: body` into ONE chunk with N params (each a frame local)
    // and `arity = N`. The historical compilation nested each as its own
    // closure, so every extra param cost a throwaway intermediate closure
    // alloc + frame at every application. Merging makes nested lambdas
    // that reference an outer param capture it as a *local* (not an
    // upvalue) — that's the alloc we drop. A call site supplying N args
    // (`call_n`) then runs the body in one frame. Stops at the first
    // non-value-lambda (attrset-pattern lambda or non-lambda body), at the
    // `MAX_UNCURRY_ARITY` cap, or at a repeated param name (so we never
    // rely on within-frame shadow ordering of identically-named locals).
    const MAX = types.MAX_UNCURRY_ARITY;
    var params: [MAX][]const u8 = undefined;
    var param_ids: [MAX]InternId = undefined;
    var n: u16 = 0;
    var cur: *const Node = node;
    while (n < MAX and cur.tag == .lambda) {
        const lam = cur.data.lambda;
        const name = self.source[lam.param_offset .. lam.param_offset + lam.param_len];
        const id = try self.intern.intern(name);
        var dup = false;
        var k: u16 = 0;
        while (k < n) : (k += 1) {
            if (param_ids[k] == id) {
                dup = true;
                break;
            }
        }
        if (dup) break;
        params[n] = name;
        param_ids[n] = id;
        n += 1;
        cur = unwrapParens(lam.body);
    }
    const body = cur;

    var child_builder = try self.acquireBuilder();
    defer self.releaseBuilder(&child_builder);

    var child = self.initChild(&child_builder);
    defer child.deinit();

    var pi: u16 = 0;
    while (pi < n) : (pi += 1) {
        _ = try scope.declareLocal(&child, params[pi], param_ids[pi]);
    }
    compileTailExpression(&child, body) catch |err| {
        try diagnostics.absorbChildDiagnostics(self, &child);
        return err;
    };
    try strictness.stampOnBuilder(&child, body);
    // Strict-param / forwarding analysis only applies to the single-param
    // (curried) shape — `finish` gates `strict_param` to `local_count == 1`
    // anyway, and an uncurried chunk's params are locals, not upvalues.
    if (n == 1) {
        // Does the body unconditionally force its single parameter? Lets a
        // caller evaluate the argument eagerly instead of thunking it.
        child_builder.strict_param = try strictness.bodyMustForceName(self.allocator, self.intern, self.source, body, param_ids[0]);
        // Forwarding `x: f x` forces x iff `f` does — record `f`'s upvalue
        // index so the caller can resolve it at the call site.
        if (!child_builder.strict_param) {
            child_builder.strict_via_upvalue = forwardingUpvalue(self, &child, body, params[0]);
        }
    } else {
        // Uncurried chunk: a per-param must-force bitmask. The saturated
        // `call_n` path forces these arg positions eagerly, recovering the
        // eager-arg behavior `apply_arg` gives the single-param shape (and
        // avoiding lazy-thunk-chain buildup in accumulator recursion).
        var mask: u8 = 0;
        var si: u16 = 0;
        while (si < n) : (si += 1) {
            if (try strictness.bodyMustForceName(self.allocator, self.intern, self.source, body, param_ids[si])) {
                mask |= @as(u8, 1) << @intCast(si);
            }
        }
        child_builder.strict_params = mask;
    }
    child_builder.arity = n;
    try emit.emitRet(&child);
    try emit.emitOp(&child, .halt);

    const child_chunk = try child_builder.finish(self.persistent, child.slot_count);
    const child_id = try self.registry.register(child_chunk);
    try emit.emitClosureWithCaptures(self, child_id, child.captures.items);
}

pub fn compileLambdaAttrs(self: *Compiler, node: *const Node) !void {
    const lambda = node.data.lambda_attrs;

    var child_builder = try self.acquireBuilder();
    defer self.releaseBuilder(&child_builder);

    var child = self.initChild(&child_builder);
    defer child.deinit();

    const arg_slot = try scope.declareLocal(&child, "\x00args", try self.intern.intern("\x00args"));
    if (lambda.bind_name) |bind_name| {
        const name = self.source[bind_name.offset .. bind_name.offset + bind_name.len];
        const name_id = try self.intern.intern(name);
        const slot = try scope.declareLocal(&child, name, name_id);
        try emit.emitCaptureLocal(&child, arg_slot);
        try emit.emitSetLocal(&child, slot);
    }

    var wide_params = false;
    for (lambda.params) |param| {
        const name = self.source[param.name.offset .. param.name.offset + param.name.len];
        if (try self.intern.intern(name) > std.math.maxInt(u16)) wide_params = true;
    }

    try emit.emitGetLocal(&child, arg_slot);
    try emit.emitOp(&child, if (wide_params) .validate_attrs_long else .validate_attrs);
    try child.builder.writeByte(child.allocator, if (lambda.allow_extra) 1 else 0);
    const param_count = try diagnostics.requireU16At(self, lambda.params.len, diagnosticAtom(node), "too many function parameters");
    try child.builder.writeU16(child.allocator, param_count);
    var function_args: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer function_args.deinit(self.allocator);
    try function_args.ensureTotalCapacity(self.allocator, lambda.params.len);
    for (lambda.params) |param| {
        const name = self.source[param.name.offset .. param.name.offset + param.name.len];
        const name_id = try self.intern.intern(name);
        try emit.writeInternId(&child, name_id, wide_params);
        function_args.appendAssumeCapacity(.{
            .name = name_id,
            .value = Value.boolVal(param.default != null),
        });
    }
    try child_builder.setFunctionArgs(self.allocator, function_args.items);

    // Binding cells are only needed when a formal's default references
    // another formal (mutually-recursive defaults, e.g. `{ a, b ? a }`):
    // the cell gives each formal a mutable handle the others can capture.
    // The overwhelmingly common case — no defaults at all, or defaults
    // that don't reference sibling formals (every NixOS module function,
    // `{ config, lib, pkgs, ... }`) — needs no cells: each formal binds
    // directly to its lookup thunk via `set_local`, skipping a per-formal
    // binding-cell heap alloc plus a force-indirection on every param
    // access. This lands on the hot critical path (module application,
    // modules.nix:450). The check only walks DEFAULTS (tiny / absent),
    // never bodies, so it adds negligible compile cost.
    const needs_cells = attrParamsNeedCells(self, lambda.params);

    if (needs_cells) {
        for (lambda.params) |param| {
            const name = self.source[param.name.offset .. param.name.offset + param.name.len];
            const name_id = try self.intern.intern(name);
            const slot = try scope.declareLocal(&child, name, name_id);
            try emit.emitInitCellSlot(&child, slot);
        }
        for (lambda.params) |param| {
            const name = self.source[param.name.offset .. param.name.offset + param.name.len];
            const name_id = try self.intern.intern(name);
            const slot = scope.resolveLocal(&child, name) orelse return error.UndefinedVariable;
            try compileAttrParamThunk(&child, arg_slot, name_id, param.default);
            try emit.emitSetCellLocal(&child, slot);
        }
    } else {
        for (lambda.params) |param| {
            const name = self.source[param.name.offset .. param.name.offset + param.name.len];
            const name_id = try self.intern.intern(name);
            const slot = try scope.declareLocal(&child, name, name_id);
            try compileAttrParamThunk(&child, arg_slot, name_id, param.default);
            try emit.emitSetLocal(&child, slot);
        }
    }

    compileTailExpression(&child, lambda.body) catch |err| {
        try diagnostics.absorbChildDiagnostics(self, &child);
        return err;
    };
    try strictness.stampOnBuilder(&child, lambda.body);
    try emit.emitRet(&child);
    try emit.emitOp(&child, .halt);

    const child_chunk = try child_builder.finish(self.persistent, child.slot_count);
    const child_id = try self.registry.register(child_chunk);
    try emit.emitClosureWithCaptures(self, child_id, child.captures.items);
}

/// Do this attrset pattern's formals need binding cells? Only when a
/// formal's default references another formal (mutually-recursive
/// defaults). Walks only the (usually absent / tiny) defaults, so it's
/// cheap; conservatively returns true on any analysis failure.
fn attrParamsNeedCells(self: *Compiler, params: []const Node.LambdaAttrParam) bool {
    var has_default = false;
    for (params) |p| {
        if (p.default != null) {
            has_default = true;
            break;
        }
    }
    if (!has_default) return false;

    var refs: std.StringHashMapUnmanaged(void) = .empty;
    defer refs.deinit(self.allocator);
    for (params) |p| {
        if (p.default) |d| refs_mod.collectReferencedNames(self, d, &refs) catch return true;
    }
    for (params) |p| {
        const name = self.source[p.name.offset .. p.name.offset + p.name.len];
        if (refs.contains(name)) return true;
    }
    return false;
}

fn compileAttrParamThunk(self: *Compiler, arg_slot: u16, name_id: InternId, default: ?*const Node) !void {
    var child_builder = try self.acquireBuilder();
    defer self.releaseBuilder(&child_builder);

    var child = self.initChild(&child_builder);
    defer child.deinit();

    _ = try scope.addCapture(&child, "\x00args", .local, arg_slot);
    try emit.emitOpU16(&child, .get_upvalue, 0);
    if (default) |default_expr| {
        try thunks.compileThunk(&child, default_expr);
        try emit.emitOp(&child, if (name_id > std.math.maxInt(u16)) .get_attr_path_or_long else .get_attr_path_or);
        try child.builder.writeByte(child.allocator, 1);
        try emit.writeInternId(&child, name_id, name_id > std.math.maxInt(u16));
    } else {
        try emit.emitGetAttr(&child, name_id);
    }
    try emit.emitRet(&child);
    try emit.emitOp(&child, .halt);

    const child_chunk = try child_builder.finish(self.persistent, child.slot_count);
    const child_id = try self.registry.register(child_chunk);
    try emit.emitThunkWithCaptures(self, child_id, child.captures.items);
}
