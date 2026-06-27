const std = @import("std");
const compiler_mod = @import("../compiler.zig");
const ast = @import("syntax").ast;
const bytecode = @import("../bytecode.zig");
const builtins = @import("../builtins.zig");
const chunk = bytecode.chunk;
const diagnostic = @import("syntax").diagnostic;
const heap_mod = @import("../runtime/heap.zig");
const string_syntax = @import("syntax").string_syntax;
const types = @import("../runtime/types.zig");
const Value = @import("../runtime/value.zig").Value;
const OpCode = bytecode.OpCode;
const emit = @import("emit.zig");
const scope = @import("scope.zig");
const thunks = @import("thunks.zig");
const diagnostics = @import("diagnostics.zig");
const attrs = @import("attrs.zig");
const access = @import("access.zig");
const control = @import("control.zig");
const strictness = @import("strictness.zig");

const Compiler = compiler_mod.Compiler;
const Node = compiler_mod.Node;
const NodeTag = compiler_mod.NodeTag;
const BinaryOp = compiler_mod.BinaryOp;
const Capture = compiler_mod.Capture;
const AttrEntryView = compiler_mod.AttrEntryView;
const AttrEntryGroup = compiler_mod.AttrEntryGroup;
const AttrEntryGroups = compiler_mod.AttrEntryGroups;
const ContainerValueOptions = compiler_mod.ContainerValueOptions;
const WithScope = compiler_mod.WithScope;
const InternId = types.InternId;
const ChunkBuilder = chunk.ChunkBuilder;
const diagnostic_atom = @import("diagnostic_atom.zig");
const diagnosticAtom = diagnostic_atom.diagnosticAtom;
const nodeMayEvaluateToFloat = ast.nodeMayEvaluateToFloat;
const unwrapParens = ast.unwrapParens;

pub fn compileBinary(self: *Compiler, node: *const Node) !void {
    const bin = node.data.binary;
    switch (bin.op) {
        .and_ => return compileAnd(self, bin.left, bin.right),
        .or_ => return compileOr(self, bin.left, bin.right),
        .impl => return compileImpl(self, bin.left, bin.right),
        else => {},
    }

    // Compile-time fold pure literal-on-literal expressions. Skips
    // operations that can error (`/`, `%`) since `{x = 1/0;}` is
    // valid Nix — only forcing `.x` is supposed to throw.
    if (try tryFoldNode(self, node)) |val| {
        return self.builder.emitConstant(self.allocator, val);
    }

    // Specialized comparison with literal `null`. Emit only the
    // non-null side and use `eq_null`/`neq_null` so the runtime
    // (and the eventual JIT) sees a type-monomorphic null check.
    if (bin.op == .eq or bin.op == .neq) {
        const left_null = unwrapParens(bin.left).tag == .null;
        const right_null = unwrapParens(bin.right).tag == .null;
        if (left_null != right_null) {
            try self.compileNode(if (left_null) bin.right else bin.left);
            try emit.emitOp(self, if (bin.op == .eq) .eq_null else .neq_null);
            return;
        }
    }

    try self.compileNode(bin.left);
    try self.compileNode(bin.right);

    switch (bin.op) {
        .add => try emit.emitOp(self, if (nodeMayEvaluateToFloat(bin.left) or nodeMayEvaluateToFloat(bin.right)) .add_float else .add_int),
        .sub => try emit.emitOp(self, if (nodeMayEvaluateToFloat(bin.left) or nodeMayEvaluateToFloat(bin.right)) .sub_float else .sub_int),
        .mul => try emit.emitOp(self, if (nodeMayEvaluateToFloat(bin.left) or nodeMayEvaluateToFloat(bin.right)) .mul_float else .mul_int),
        .div => try emit.emitOp(self, if (nodeMayEvaluateToFloat(bin.left) or nodeMayEvaluateToFloat(bin.right)) .div_float else .div_int),
        .eq => try emit.emitOp(self, .eq),
        .neq => try emit.emitOp(self, .neq),
        .lt => try emit.emitOp(self, .lt),
        .lte => try emit.emitOp(self, .lte),
        .gt => try emit.emitOp(self, .gt),
        .gte => try emit.emitOp(self, .gte),
        .and_, .or_ => unreachable,
        .update => try emit.emitOp(self, .merge_attrs),
        .impl => unreachable,
        .concat => try emit.emitOp(self, .concat_lists),
    }
}

/// Attempt to compute a pure-arithmetic / comparison / logical
/// expression's value at compile time. Returns null when:
///   - the expression isn't a literal-on-literal pattern (recursive
///     folding handles nested cases like `1 + 2 + 3`);
///   - the operation might error at runtime (division, modulo);
///   - integer arithmetic would overflow i64 (leave for runtime so
///     the user sees the real error site);
///   - the operator is a structural one (`//`, `++`).
///
/// CRITICAL Nix-semantics constraint: `{x = 1/0;}` is valid; only
/// `{x = 1/0;}.x` is supposed to throw. So we MUST NOT fold any
/// operation that could trap — division, modulo, anything that could
/// throw. Folding is purely conservative: when in doubt, don't fold.
fn tryFoldNode(self: *Compiler, node: *const Node) anyerror!?Value {
    const n = unwrapParens(node);
    switch (n.tag) {
        .integer => {
            const span = self.source[n.data.atom.offset .. n.data.atom.offset + n.data.atom.len];
            const val = std.fmt.parseInt(i64, span, 10) catch return null;
            return try @import("../runtime/int.zig").make(self.heap, val);
        },
        .float_val => {
            const span = self.source[n.data.atom.offset .. n.data.atom.offset + n.data.atom.len];
            const val = std.fmt.parseFloat(f64, span) catch return null;
            return Value.float(val);
        },
        .bool_true => return Value.boolVal(true),
        .bool_false => return Value.boolVal(false),
        .null => return Value.null_val,
        .binary_op => {
            const bin = n.data.binary;
            return tryFoldBinaryOp(self, bin.op, bin.left, bin.right);
        },
        .unary_op => {
            const u = n.data.unary;
            return tryFoldUnaryOp(self, u.op, u.expr);
        },
        else => return null,
    }
}

fn tryFoldBinaryOp(self: *Compiler, op: BinaryOp, left_node: *const Node, right_node: *const Node) anyerror!?Value {
    // Logical short-circuit operators: a single literal side can
    // determine the result without evaluating the other operand. But
    // *only* when we know the short-circuit side has no side effects
    // — which here means it's also a fully-folded literal. We already
    // recurse on both sides via tryFoldNode below; if both fold,
    // computing the boolean is safe.
    const left = try tryFoldNode(self, left_node) orelse return null;
    const right = try tryFoldNode(self, right_node) orelse return null;
    return switch (op) {
        .add => foldArith(self, left, right, .add),
        .sub => foldArith(self, left, right, .sub),
        .mul => foldArith(self, left, right, .mul),
        // .div / .modulo intentionally omitted (could trap on /0).
        .eq => Value.boolVal(literalsEqual(left, right)),
        .neq => Value.boolVal(!literalsEqual(left, right)),
        .lt => foldCompare(left, right, .lt),
        .lte => foldCompare(left, right, .lte),
        .gt => foldCompare(left, right, .gt),
        .gte => foldCompare(left, right, .gte),
        .and_ => if (left.isBool() and right.isBool()) Value.boolVal(left.asBool() and right.asBool()) else null,
        .or_ => if (left.isBool() and right.isBool()) Value.boolVal(left.asBool() or right.asBool()) else null,
        .impl => if (left.isBool() and right.isBool()) Value.boolVal(!left.asBool() or right.asBool()) else null,
        // .update / .concat are structural — never fold.
        .update, .concat, .div => null,
    };
}

fn tryFoldUnaryOp(self: *Compiler, op: ast.UnaryOp, expr: *const Node) anyerror!?Value {
    const v = try tryFoldNode(self, expr) orelse return null;
    return switch (op) {
        .not => if (v.isBool()) Value.boolVal(!v.asBool()) else null,
        .negate => switch (v.kind()) {
            .int => blk: {
                const i = v.asInt();
                // i64.min has no positive counterpart — let runtime
                // handle the saturation/error semantics.
                if (i == std.math.minInt(i64)) break :blk null;
                break :blk try @import("../runtime/int.zig").make(self.heap, -i);
            },
            .boxed_int => blk: {
                const i = self.heap.getBoxedInt(v.asObjectId()) catch break :blk null;
                if (i == std.math.minInt(i64)) break :blk null;
                break :blk try @import("../runtime/int.zig").make(self.heap, -i);
            },
            .float => Value.float(-v.asFloat()),
            else => null,
        },
    };
}

const ArithOp = enum { add, sub, mul };

fn foldArith(self: *Compiler, a: Value, b: Value, op: ArithOp) ?Value {
    const a_kind = a.kind();
    const b_kind = b.kind();
    // Both numbers? Promote to float if either is float; otherwise
    // checked i64 op.
    const a_is_int = a_kind == .int or a_kind == .boxed_int;
    const b_is_int = b_kind == .int or b_kind == .boxed_int;
    if ((a_is_int or a_kind == .float) and (b_is_int or b_kind == .float)) {
        if (a_kind == .float or b_kind == .float) {
            const af = toFloat(self, a) orelse return null;
            const bf = toFloat(self, b) orelse return null;
            return Value.float(switch (op) {
                .add => af + bf,
                .sub => af - bf,
                .mul => af * bf,
            });
        }
        const ai = toInt(self, a) orelse return null;
        const bi = toInt(self, b) orelse return null;
        const result = switch (op) {
            .add => @addWithOverflow(ai, bi),
            .sub => @subWithOverflow(ai, bi),
            .mul => @mulWithOverflow(ai, bi),
        };
        // Don't fold across an overflow — leave it to runtime so the
        // error site matches the user's source.
        if (result[1] != 0) return null;
        return @import("../runtime/int.zig").make(self.heap, result[0]) catch null;
    }
    return null;
}

const CmpOp = enum { lt, lte, gt, gte };

fn foldCompare(a: Value, b: Value, op: CmpOp) ?Value {
    const a_kind = a.kind();
    const b_kind = b.kind();
    const a_is_int = a_kind == .int or a_kind == .boxed_int;
    const b_is_int = b_kind == .int or b_kind == .boxed_int;
    if ((a_is_int or a_kind == .float) and (b_is_int or b_kind == .float)) {
        // Need access to heap for boxed_int — skip for now if either is boxed.
        if (a_kind == .boxed_int or b_kind == .boxed_int) return null;
        if (a_kind == .float or b_kind == .float) {
            const af: f64 = if (a_kind == .float) a.asFloat() else @floatFromInt(a.asInt());
            const bf: f64 = if (b_kind == .float) b.asFloat() else @floatFromInt(b.asInt());
            return Value.boolVal(switch (op) {
                .lt => af < bf, .lte => af <= bf, .gt => af > bf, .gte => af >= bf,
            });
        }
        const ai = a.asInt();
        const bi = b.asInt();
        return Value.boolVal(switch (op) {
            .lt => ai < bi, .lte => ai <= bi, .gt => ai > bi, .gte => ai >= bi,
        });
    }
    return null;
}

fn literalsEqual(a: Value, b: Value) bool {
    const a_kind = a.kind();
    const b_kind = b.kind();
    // Nix: different types of value compare unequal (no implicit
    // conversion between int and bool, etc.).
    if (a_kind == .null and b_kind == .null) return true;
    if (a.isBool() and b.isBool()) return a.asBool() == b.asBool();
    const a_is_int = a_kind == .int;
    const b_is_int = b_kind == .int;
    if (a_is_int and b_is_int) return a.asInt() == b.asInt();
    if ((a_is_int or a_kind == .float) and (b_is_int or b_kind == .float)) {
        const af: f64 = if (a_kind == .float) a.asFloat() else @floatFromInt(a.asInt());
        const bf: f64 = if (b_kind == .float) b.asFloat() else @floatFromInt(b.asInt());
        return af == bf;
    }
    // Cross-type compare → false (matches Nix runtime semantics).
    return false;
}

fn toInt(self: *Compiler, v: Value) ?i64 {
    return switch (v.kind()) {
        .int => v.asInt(),
        .boxed_int => self.heap.getBoxedInt(v.asObjectId()) catch null,
        else => null,
    };
}

fn toFloat(self: *Compiler, v: Value) ?f64 {
    return switch (v.kind()) {
        .float => v.asFloat(),
        .int => @floatFromInt(v.asInt()),
        .boxed_int => blk: {
            const i = self.heap.getBoxedInt(v.asObjectId()) catch break :blk null;
            break :blk @floatFromInt(i);
        },
        else => null,
    };
}

pub fn compileAnd(self: *Compiler, left: *const Node, right: *const Node) !void {
    try self.compileNode(left);

    const end_jump = self.builder.code.items.len;
    try emit.emitOpU32(self, .jump_if_false, 0);
    try emit.emitOp(self, .pop);

    try self.compileNode(right);
    emit.patchJump(self, end_jump, self.builder.code.items.len);
}

pub fn compileOr(self: *Compiler, left: *const Node, right: *const Node) !void {
    try self.compileNode(left);

    const false_jump = self.builder.code.items.len;
    try emit.emitOpU32(self, .jump_if_false, 0);

    const end_jump = self.builder.code.items.len;
    try emit.emitOpU32(self, .jump, 0);

    emit.patchJump(self, false_jump, self.builder.code.items.len);
    try emit.emitOp(self, .pop);

    try self.compileNode(right);
    emit.patchJump(self, end_jump, self.builder.code.items.len);
}

pub fn compileImpl(self: *Compiler, left: *const Node, right: *const Node) !void {
    try self.compileNode(left);

    const false_jump = self.builder.code.items.len;
    try emit.emitOpU32(self, .jump_if_false, 0);
    try emit.emitOp(self, .pop);

    try self.compileNode(right);
    const end_jump = self.builder.code.items.len;
    try emit.emitOpU32(self, .jump, 0);

    emit.patchJump(self, false_jump, self.builder.code.items.len);
    try emit.emitOp(self, .pop);
    try emit.emitOp(self, .push_true);

    emit.patchJump(self, end_jump, self.builder.code.items.len);
}

pub fn compileUnary(self: *Compiler, node: *const Node) !void {
    if (try tryFoldNode(self, node)) |val| {
        return self.builder.emitConstant(self.allocator, val);
    }
    const un = node.data.unary;
    try self.compileNode(un.expr);
    switch (un.op) {
        .negate => try emit.emitOp(self, .negate_int),
        .not => try emit.emitOp(self, .not),
    }
}

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

pub fn compileTailNodeImpl(self: *Compiler, node: *const Node) anyerror!void {
    switch (node.tag) {
        .apply => try compileApplyWithOp(self, node, .tail_call),
        .if_else => try control.compileIfElseTail(self, node),
        .let_in => try compileLetInWithTailBody(self, node),
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
    try @import("thunks.zig").compileThunk(self, arg);
}

pub fn compileApplyWithOp(self: *Compiler, node: *const Node, op: OpCode) !void {
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
    if (isEagerEvalShape(ap.arg) and try directlyAppliedStrictLambda(self, ap.func)) {
        // Statically-known strict callee: eager arg, no runtime check.
        try self.compileNode(ap.arg);
    } else if (try access.compileImmediateContainerValue(self, ap.arg, .{})) {
        // Immediate value (literal/empty list/...): already thunk-free.
    } else {
        // Dynamically-dispatched call: defer the thunk-vs-eager decision
        // to runtime via `apply_arg`, which reads the callee's strictness.
        try @import("thunks.zig").compileApplyArgThunk(self, ap.arg);
    }
    try emit.emitOp(self, op);
}

/// Detect the forwarding shape `param: f param` where `f` is a captured
/// free variable, returning `f`'s upvalue index (its position in the
/// child's capture list). The lambda then forces its parameter iff `f`
/// does — resolved at the call site. `null` when the body is not this
/// exact shape.
fn forwardingUpvalue(self: *Compiler, child: *Compiler, body: *const Node, param_name: []const u8) ?u16 {
    const b = @import("syntax").ast.unwrapParens(body);
    if (b.tag != .apply) return null;
    const func = @import("syntax").ast.unwrapParens(b.data.apply.func);
    const arg = @import("syntax").ast.unwrapParens(b.data.apply.arg);
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

    var child_builder = try ChunkBuilder.init(self.allocator);
    defer child_builder.deinit(self.allocator);

    var child = Compiler.init(
        self.allocator,
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

    const child_chunk = try child_builder.finish(self.allocator, child.slot_count);
    const child_id = try self.registry.register(child_chunk);
    try emit.emitClosureWithCaptures(self, child_id, child.captures.items);
}

pub fn compileLambdaAttrs(self: *Compiler, node: *const Node) !void {
    const lambda = node.data.lambda_attrs;

    var child_builder = try ChunkBuilder.init(self.allocator);
    defer child_builder.deinit(self.allocator);

    var child = Compiler.init(
        self.allocator,
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

    const child_chunk = try child_builder.finish(self.allocator, child.slot_count);
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
        if (p.default) |d| collectReferencedNames(self, d, &refs) catch return true;
    }
    for (params) |p| {
        const name = self.source[p.name.offset .. p.name.offset + p.name.len];
        if (refs.contains(name)) return true;
    }
    return false;
}

pub fn compileAttrParamThunk(self: *Compiler, arg_slot: u16, name_id: InternId, default: ?*const Node) !void {
    var child_builder = try ChunkBuilder.init(self.allocator);
    defer child_builder.deinit(self.allocator);

    var child = Compiler.init(
        self.allocator,
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

    const child_chunk = try child_builder.finish(self.allocator, child.slot_count);
    const child_id = try self.registry.register(child_chunk);
    try emit.emitThunkWithCaptures(self, child_id, child.captures.items);
}

pub fn compileLetIn(self: *Compiler, node: *const Node) !void {
    try compileLetInBody(self, node, false);
}

pub fn compileLetInWithTailBody(self: *Compiler, node: *const Node) anyerror!void {
    try compileLetInBody(self, node, true);
}

pub fn compileLetInBody(self: *Compiler, node: *const Node, tail_body: bool) anyerror!void {
    const let_in = node.data.let_in;

    scope.beginScope(self);

    // For each unique binding root, classify how it should be
    // compiled. Four kinds:
    //   .unreferenced      — nothing else in this let (or its body)
    //                        mentions the name; skip the binding
    //                        entirely. Nix is pure and lazy: if no
    //                        one forces the RHS, its side-effects
    //                        never fire, so omitting it is observably
    //                        equivalent.
    //   .literal           — RHS is a pure literal; eagerly bind value
    //                        directly into the slot (no cell).
    //   .uncaptured        — non-literal RHS, no earlier binding in
    //                        this let references the name; we can skip
    //                        the cell and just `set_local` the lazy
    //                        thunk value in pass 2. The body and any
    //                        later binding's RHS will see the bound
    //                        thunk and force normally.
    //   .needs_cell        — non-literal RHS that *is* referenced by
    //                        an earlier binding (forward reference);
    //                        the cell exists so the earlier RHS can
    //                        capture a mutable handle that this
    //                        binding's pass 2 mutates.
    const kinds = try classifyLetBindings(self, let_in.bindings, let_in.body);
    defer self.allocator.free(kinds);

    // Strictness-driven eagerness. Two analyses over the body:
    //   `eager_flags`      — may-force shallow set; drives the eager
    //                        *thunk* submit hint (helpers race ahead).
    //   `must_force_flags` — sound must-force set; drives eager
    //                        *elision* (pass 2): a non-recursive binding
    //                        the body unconditionally forces is compiled
    //                        straight into its slot, with no thunk at
    //                        all. Sound because lazy eval would force it
    //                        regardless — can't turn a success into an
    //                        error (only reorder which error surfaces in
    //                        an already-failing eval).
    const binding_name_ids = try self.allocator.alloc(InternId, let_in.bindings.len);
    defer self.allocator.free(binding_name_ids);
    for (let_in.bindings, binding_name_ids) |binding, *nid| {
        const name = attrs.attrSegmentSpan(self, binding.path[0]);
        nid.* = try self.intern.intern(name);
    }
    // Earliest source index of each binding root — the forward-ref guard
    // for eager elision (a binding can't be eagerly evaluated if its RHS
    // references a binding defined later, whose slot isn't filled yet).
    var earliest_index: std.AutoHashMapUnmanaged(InternId, usize) = .empty;
    defer earliest_index.deinit(self.allocator);
    for (binding_name_ids, 0..) |nid, i| {
        if (!earliest_index.contains(nid)) try earliest_index.put(self.allocator, nid, i);
    }

    const eager_flags = try self.allocator.alloc(bool, let_in.bindings.len);
    defer self.allocator.free(eager_flags);
    const must_force_flags = try self.allocator.alloc(bool, let_in.bindings.len);
    defer self.allocator.free(must_force_flags);
    try @import("strictness.zig").analyzeLetEagerness(
        self.allocator, self.intern, self.source, let_in.body, binding_name_ids, eager_flags,
    );
    try @import("strictness.zig").analyzeLetMustForce(
        self.allocator, self.intern, self.source, let_in.body, binding_name_ids, must_force_flags,
    );

    for (let_in.bindings, kinds, 0..) |binding, kind, index| {
        if (bindingRootSeen(self, let_in.bindings[0..index], binding.path[0])) continue;
        if (kind == .unreferenced) continue;
        const name = attrs.attrSegmentSpan(self, binding.path[0]);
        const name_id = try self.intern.intern(name);
        const slot = try scope.declareLocal(self, name, name_id);
        switch (kind) {
            .literal => {
                const leaf = singleLeafBinding(self, let_in.bindings, binding.path[0]).?;
                try access.compileContainerValue(self, leaf.expr, .{});
                try emit.emitSetLocal(self, slot);
            },
            .uncaptured => {}, // pass 2 will fill the slot directly
            .needs_cell => try emit.emitInitCellSlot(self, slot),
            .unreferenced => unreachable,
        }
    }

    for (let_in.bindings, kinds, 0..) |binding, kind, index| {
        if (bindingRootSeen(self, let_in.bindings[0..index], binding.path[0])) continue;
        if (kind == .literal or kind == .unreferenced) continue;
        const name = attrs.attrSegmentSpan(self, binding.path[0]);
        const slot = scope.resolveLocal(self, name) orelse return error.UndefinedVariable;

        // Eager elision: a non-recursive (`.uncaptured`) binding that the
        // body unconditionally forces, with a computational RHS that
        // references no later binding — evaluate it straight into the
        // slot, skipping the thunk alloc + force + frame entirely.
        if (kind == .uncaptured and must_force_flags[index]) {
            if (eligibleEagerLeaf(self, let_in.bindings, binding.path[0], &earliest_index, index)) |leaf| {
                try self.compileNode(leaf.expr);
                try emit.emitSetLocal(self, slot);
                continue;
            }
        }

        try compileLetRootBinding(self, let_in.bindings, binding.path[0], slot, eager_flags[index]);
        switch (kind) {
            .needs_cell => try emit.emitSetCellLocal(self, slot),
            .uncaptured => try emit.emitSetLocal(self, slot),
            .literal, .unreferenced => unreachable,
        }
    }

    if (tail_body) {
        try compileTailExpression(self, let_in.body);
    } else {
        try self.compileNode(let_in.body);
    }

    scope.endScope(self);
}

const LetBindingKind = enum { unreferenced, literal, uncaptured, needs_cell };

/// Decide for each binding whether it can skip the cell. A binding
/// needs a cell iff some *earlier* binding (which gets compiled first
/// in pass 2) references it by name — only then is the cell's
/// mutable-handle behaviour load-bearing. Later bindings and the body
/// always see the bound value because pass 2 fills slots in source
/// order before the body emits.
///
/// To keep compile cost reasonable on big lets the analysis builds
/// per-RHS reference hashsets once up front. Per-binding membership
/// checks are then O(1) instead of O(total source bytes) — a
/// measurable `mem.eql`-dominance saving on workloads with hundreds
/// of let bindings (e.g. nixpkgs).
fn classifyLetBindings(self: *Compiler, bindings: []const Node.Binding, body: *const Node) ![]LetBindingKind {
    const kinds = try self.allocator.alloc(LetBindingKind, bindings.len);
    errdefer self.allocator.free(kinds);

    var body_refs: std.StringHashMapUnmanaged(void) = .empty;
    defer body_refs.deinit(self.allocator);
    try collectReferencedNames(self, body, &body_refs);

    const rhs_refs = try self.allocator.alloc(std.StringHashMapUnmanaged(void), bindings.len);
    defer {
        for (rhs_refs) |*s| s.deinit(self.allocator);
        self.allocator.free(rhs_refs);
    }
    for (rhs_refs) |*s| s.* = .empty;
    var any_path_nested = false;
    for (bindings, 0..) |binding, i| {
        if (binding.path.len > 1) {
            // Nested-path bindings synthesise an attr-set thunk
            // whose captures we don't statically track; conservative:
            // any such binding "references" every other.
            any_path_nested = true;
        }
        try collectReferencedNames(self, binding.expr, &rhs_refs[i]);
    }

    for (bindings, 0..) |binding, i| {
        if (bindingRootSeen(self, bindings[0..i], binding.path[0])) {
            kinds[i] = .needs_cell;
            continue;
        }
        const name = attrs.attrSegmentSpan(self, binding.path[0]);

        const externally_referenced = body_refs.contains(name) or any_path_nested or
            referencedByOtherRhs(rhs_refs, i, name);
        if (!externally_referenced) {
            kinds[i] = .unreferenced;
            continue;
        }
        if (isLiteralLeafBinding(self, bindings, binding.path[0])) {
            kinds[i] = .literal;
            continue;
        }
        if (groupNeedsCellFromSets(rhs_refs, i, name)) {
            kinds[i] = .needs_cell;
        } else {
            kinds[i] = .uncaptured;
        }
    }
    return kinds;
}

fn referencedByOtherRhs(
    rhs_refs: []const std.StringHashMapUnmanaged(void),
    target_index: usize,
    name: []const u8,
) bool {
    for (rhs_refs, 0..) |s, i| {
        if (i == target_index) continue;
        if (s.contains(name)) return true;
    }
    return false;
}

/// Cell-needed predicate using the precomputed reference sets. A
/// binding's name is "earlier-or-self referenced" when any binding
/// in `0..=target_index` mentions it: that's exactly the set whose
/// pass-2 compile would either capture before the slot is filled
/// (earlier sibling) or during its own thunk construction (self).
fn groupNeedsCellFromSets(
    rhs_refs: []const std.StringHashMapUnmanaged(void),
    target_index: usize,
    name: []const u8,
) bool {
    var i: usize = 0;
    while (i <= target_index) : (i += 1) {
        if (rhs_refs[i].contains(name)) return true;
    }
    return false;
}

/// Walk `node` and add every identifier name encountered to `out`,
/// including textual matches inside `${...}` interpolation in atoms.
/// Conservatively mirrors `nodeReferencesName`'s coverage — false
/// positives just keep cells (and bindings) around, never break
/// semantics.
fn collectReferencedNames(self: *Compiler, node: *const Node, out: *std.StringHashMapUnmanaged(void)) anyerror!void {
    switch (node.tag) {
        .integer, .float_val, .bool_true, .bool_false, .null, .search_path => {},
        .string, .path => try collectIdentifiersInSpan(self, node.data.atom, out),
        .identifier => {
            const ident = self.source[node.data.atom.offset .. node.data.atom.offset + node.data.atom.len];
            try out.put(self.allocator, ident, {});
        },
        .unary_op => try collectReferencedNames(self, node.data.unary.expr, out),
        .binary_op => {
            try collectReferencedNames(self, node.data.binary.left, out);
            try collectReferencedNames(self, node.data.binary.right, out);
        },
        .apply => {
            try collectReferencedNames(self, node.data.apply.func, out);
            try collectReferencedNames(self, node.data.apply.arg, out);
        },
        .lambda => try collectReferencedNames(self, node.data.lambda.body, out),
        .lambda_attrs => {
            const la = node.data.lambda_attrs;
            for (la.params) |param| {
                if (param.default) |default| try collectReferencedNames(self, default, out);
            }
            try collectReferencedNames(self, la.body, out);
        },
        .let_in => {
            const li = node.data.let_in;
            for (li.bindings) |b| try collectReferencedNames(self, b.expr, out);
            try collectReferencedNames(self, li.body, out);
        },
        .if_else => {
            const ie = node.data.if_else;
            try collectReferencedNames(self, ie.cond, out);
            try collectReferencedNames(self, ie.then_branch, out);
            try collectReferencedNames(self, ie.else_branch, out);
        },
        .assert => {
            try collectReferencedNames(self, node.data.assert.cond, out);
            try collectReferencedNames(self, node.data.assert.body, out);
        },
        .with_expr => {
            try collectReferencedNames(self, node.data.with_expr.attr_set, out);
            try collectReferencedNames(self, node.data.with_expr.body, out);
        },
        .attr_set => {
            for (node.data.attr_set.entries) |entry| {
                if (entry.dynamic_name) |dn| try collectReferencedNames(self, dn, out);
                for (entry.path) |seg| try collectIdentifiersInSpan(self, seg, out);
                try collectReferencedNames(self, entry.expr, out);
            }
        },
        .attr_path => {
            try collectReferencedNames(self, node.data.attr_path.root, out);
            for (node.data.attr_path.segments) |seg| try collectIdentifiersInSpan(self, seg, out);
        },
        .attr_dynamic => {
            try collectReferencedNames(self, node.data.attr_dynamic.root, out);
            try collectReferencedNames(self, node.data.attr_dynamic.name, out);
        },
        .attr_or => {
            try collectReferencedNames(self, node.data.attr_or.attr_path, out);
            try collectReferencedNames(self, node.data.attr_or.default, out);
        },
        .has_attr => {
            try collectReferencedNames(self, node.data.has_attr.root, out);
            for (node.data.has_attr.segments) |seg| try collectIdentifiersInSpan(self, seg, out);
        },
        .has_attr_dynamic => {
            try collectReferencedNames(self, node.data.has_attr_dynamic.root, out);
            try collectReferencedNames(self, node.data.has_attr_dynamic.name, out);
        },
        .has_attr_mixed => {
            const ham = node.data.has_attr_mixed;
            try collectReferencedNames(self, ham.root, out);
            for (ham.segments) |seg| switch (seg) {
                .static => |a| try collectIdentifiersInSpan(self, a, out),
                .dynamic => |n| try collectReferencedNames(self, n, out),
            };
        },
        .list => {
            for (node.data.list.items) |item| try collectReferencedNames(self, item, out);
        },
        .parens => try collectReferencedNames(self, node.data.parens, out),
    }
}

/// Pull out every identifier-shaped substring from a source span and
/// add it to `out`. Catches references inside `${...}` interpolation
/// in atom-typed fields without expanding through the string parser.
fn collectIdentifiersInSpan(self: *Compiler, atom: Node.Atom, out: *std.StringHashMapUnmanaged(void)) !void {
    const text = self.source[atom.offset .. atom.offset + atom.len];
    var i: usize = 0;
    while (i < text.len) {
        if (isIdentStart(text[i])) {
            const start = i;
            while (i < text.len and isIdentChar(text[i])) : (i += 1) {}
            try out.put(self.allocator, text[start..i], {});
        } else {
            i += 1;
        }
    }
}

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '_' or c == '\'' or c == '-';
}

/// True when the binding group sharing `root` is exactly one leaf
/// (no nested attr paths, no duplicates) and that leaf's RHS is a
/// pure literal — i.e. eager evaluation can replace the cell-wrap
/// without changing observable behaviour.
fn isLiteralLeafBinding(self: *Compiler, bindings: []const Node.Binding, root: Node.Atom) bool {
    const leaf = singleLeafBinding(self, bindings, root) orelse return false;
    return access.isLiteralContainerValue(self, leaf.expr);
}

fn singleLeafBinding(self: *Compiler, bindings: []const Node.Binding, root: Node.Atom) ?Node.Binding {
    var found: ?Node.Binding = null;
    for (bindings) |binding| {
        if (!attrs.attrSegmentsEqual(self, binding.path[0], root)) continue;
        if (binding.path.len != 1) return null;
        if (binding.inherit_outer) return null;
        if (found != null) return null;
        found = binding;
    }
    return found;
}

pub fn compileLetRootBinding(self: *Compiler, bindings: []const Node.Binding, root: Node.Atom, slot: u16, eager: bool) !void {
    var leaf: ?Node.Binding = null;
    var tail_count: usize = 0;

    for (bindings) |binding| {
        if (!attrs.attrSegmentsEqual(self, binding.path[0], root)) continue;
        if (binding.path.len == 1) {
            if (leaf) |previous| {
                try diagnostics.reportCompileError(self, binding.name_offset, binding.name_len, "duplicate let binding");
                try diagnostics.reportCompileNote(self, previous.name_offset, previous.name_len, "first binding defined here");
                return error.DuplicateBinding;
            }
            leaf = binding;
        } else {
            tail_count += 1;
        }
    }

    if (tail_count == 0) {
        const binding = leaf orelse return error.UndefinedVariable;
        const previous_skip = self.skip_local_slot;
        if (binding.inherit_outer) self.skip_local_slot = slot;
        const compile_result = access.compileContainerValue(self, binding.expr, .{ .eager = eager });
        self.skip_local_slot = previous_skip;
        return compile_result;
    }

    const tails = try self.allocator.alloc(AttrEntryView, tail_count);
    defer self.allocator.free(tails);
    var i: usize = 0;
    for (bindings) |binding| {
        if (!attrs.attrSegmentsEqual(self, binding.path[0], root) or binding.path.len == 1) continue;
        tails[i] = .{
            .path = binding.path[1..],
            .expr = binding.expr,
            .inherit_outer = binding.inherit_outer,
        };
        i += 1;
    }

    if (leaf) |root_leaf| {
        if (root_leaf.expr.tag != .attr_set) {
            try attrs.reportDuplicateAttribute(self, tails[0].path[0], root_leaf.path[0]);
            return error.DuplicateAttribute;
        }
        const leaves = [_]AttrEntryView{.{
            .path = root_leaf.path,
            .expr = root_leaf.expr,
            .inherit_outer = root_leaf.inherit_outer,
        }};
        return attrs.compileExtendedAttrSetLiteralThunk(self, &leaves, tails);
    }

    return attrs.compileAttrEntriesThunk(self, tails, true);
}

/// Eager-elision eligibility for a let binding. Returns the single-leaf
/// binding iff (a) it is a single leaf (not a nested attr path),
/// (b) its RHS is a computational shape — not a structural builder we
/// keep lazy (attrset/lambda/list) — and (c) its RHS references no
/// binding defined later in the same `let` (which would read an
/// unfilled slot when evaluated eagerly here). The caller guarantees
/// the binding is non-recursive (`.uncaptured`) and must-forced.
fn eligibleEagerLeaf(
    self: *Compiler,
    bindings: []const Node.Binding,
    root: Node.Atom,
    earliest: *const std.AutoHashMapUnmanaged(InternId, usize),
    index: usize,
) ?Node.Binding {
    const leaf = singleLeafBinding(self, bindings, root) orelse return null;
    if (!isEagerEvalShape(leaf.expr)) return null;
    if (rhsHasForwardRef(self, leaf.expr, earliest, index)) return null;
    return leaf;
}

/// Structural builders (attrset/lambda/list) stay lazy: they're already
/// inlined thunk-free where eager, and eagerly building an attrset value
/// can perturb module fixpoints. Everything else is a scalar/
/// computational expression whose strict evaluation is exactly what
/// forcing the binding-thunk would have done.
fn isEagerEvalShape(expr: *const Node) bool {
    return switch (expr.tag) {
        .attr_set, .lambda, .lambda_attrs, .list => false,
        else => true,
    };
}

/// Conservative forward-reference check: true if `expr` references any
/// `let` binding root whose earliest definition index is > `index`. On
/// collection failure returns true so the caller keeps the lazy path.
fn rhsHasForwardRef(
    self: *Compiler,
    expr: *const Node,
    earliest: *const std.AutoHashMapUnmanaged(InternId, usize),
    index: usize,
) bool {
    var refs: std.StringHashMapUnmanaged(void) = .empty;
    defer refs.deinit(self.allocator);
    collectReferencedNames(self, expr, &refs) catch return true;
    var it = refs.keyIterator();
    while (it.next()) |k| {
        const id = self.intern.intern(k.*) catch return true;
        if (earliest.get(id)) |first| {
            if (first > index) return true;
        }
    }
    return false;
}

pub fn bindingRootSeen(self: *const Compiler, bindings: []const Node.Binding, root: Node.Atom) bool {
    for (bindings) |binding| {
        if (binding.path.len > 0 and attrs.attrSegmentsEqual(self, binding.path[0], root)) return true;
    }
    return false;
}
