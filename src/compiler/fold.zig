//! Lowers unary and binary operators, with compile-time constant folding
//! of pure literal-on-literal arithmetic/comparison/logic.
//! Folding is strictly conservative: it never folds operations that could
//! trap (`/`, `%`, i64 overflow), since `{ x = 1/0; }` is valid Nix and
//! only forcing `.x` may throw.

const std = @import("std");
const compiler_mod = @import("../compiler.zig");
const ast = @import("syntax").ast;
const Value = @import("runtime").value.Value;
const emit = @import("emit.zig");
const int_ops = @import("runtime").int;

const Compiler = compiler_mod.Compiler;
const Node = compiler_mod.Node;
const BinaryOp = compiler_mod.BinaryOp;
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
            return try int_ops.make(self.heap, val);
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
                break :blk try int_ops.make(self.heap, -i);
            },
            .boxed_int => blk: {
                const i = self.heap.getBoxedInt(v.asObjectId()) catch break :blk null;
                if (i == std.math.minInt(i64)) break :blk null;
                break :blk try int_ops.make(self.heap, -i);
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
        return int_ops.make(self.heap, result[0]) catch null;
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
                .lt => af < bf,
                .lte => af <= bf,
                .gt => af > bf,
                .gte => af >= bf,
            });
        }
        const ai = a.asInt();
        const bi = b.asInt();
        return Value.boolVal(switch (op) {
            .lt => ai < bi,
            .lte => ai <= bi,
            .gt => ai > bi,
            .gte => ai >= bi,
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

fn compileAnd(self: *Compiler, left: *const Node, right: *const Node) !void {
    try self.compileNode(left);

    const end_jump = self.builder.code.items.len;
    try emit.emitOpU32(self, .jump_if_false, 0);
    try emit.emitOp(self, .pop);

    try self.compileNode(right);
    emit.patchJump(self, end_jump, self.builder.code.items.len);
}

fn compileOr(self: *Compiler, left: *const Node, right: *const Node) !void {
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

fn compileImpl(self: *Compiler, left: *const Node, right: *const Node) !void {
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
