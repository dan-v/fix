//! Trace IR optimizer for the tracing JIT (`-Dtjit`).
//!
//! Runs over a recorded `Trace` in place. Inlining (call/force) produces
//! redundancy the passes here remove — repeated chunk guards, constants
//! exposed across inlined boundaries, and computations made dead by inlining.
//! Tightening matters: it's what makes inlining *pay*, and it's the substrate
//! allocation sinking plugs into. See `docs/tracing-jit.md`.
//!
//! Deletions are done by overwriting an instruction with `.nop` rather than
//! removing it, so SSA `Ref`s (array indices) never renumber — every existing
//! operand reference stays valid. Codegen skips `.nop`s.
//!
//! Pure module (operates only on IR) → fully unit-testable, no VM coupling.

const std = @import("std");
const ir = @import("ir.zig");
const Value = @import("../runtime/value.zig").Value;

const Trace = ir.Trace;
const Op = ir.Op;
const Ref = ir.Ref;

pub fn optimize(trace: *Trace, allocator: std.mem.Allocator) !void {
    constFold(trace, allocator);
    dedupeGuards(trace, allocator) catch {};
    elideRedundantForces(trace);
    try deadCodeElim(trace, allocator);
}

/// True if executing `op` forces its operand in field slot 0=`a` / 1=`b`. The
/// recorder emits a `force` after every forcing load (get_local/get_upvalue) so
/// values reach WHNF — but when that value's only consumers *already* force it
/// (get_attr's operand, an arithmetic/compare/guard input, another force), the
/// explicit `force` is redundant. Conservative: any op/slot not listed here is
/// treated as non-forcing, so the force is kept.
fn forcesOperand(op: Op, slot: u1) bool {
    return switch (op) {
        .get_attr, .force, .not, .load_upvalue_of => slot == 0, // operand `a`
        .add_int, .sub_int, .mul_int, .eq, .lt => true, // both `a` and `b`
        .guard => slot == 0, // guards force `a` before checking it
        else => false, // ret (and anything unmodeled) does NOT force
    };
}

/// Drop `force` instructions made redundant because every use of their result
/// is itself a forcing position. Redirect those uses to the force's input (an
/// earlier Ref, so SSA stays valid) and nop the force. A force with *no* uses
/// is kept — its demand side effect (marking the thunk demanded) matches the
/// interpreter, which forces the loaded value regardless of use.
fn elideRedundantForces(trace: *Trace) void {
    const n = trace.instrs.items.len;
    if (n == 0) return;
    const instrs = trace.instrs.items;
    for (instrs, 0..) |instr, f| {
        if (instr.op != .force) continue;
        const fref: Ref = @intCast(f);
        var uses: usize = 0;
        var all_forcing = true;
        for (instrs) |u| {
            if (ir.usesA(u.op) and u.a == fref) {
                uses += 1;
                if (!forcesOperand(u.op, 0)) all_forcing = false;
            }
            if (ir.usesB(u.op) and u.b == fref) {
                uses += 1;
                if (!forcesOperand(u.op, 1)) all_forcing = false;
            }
        }
        if (uses == 0 or !all_forcing) continue;
        const src = instr.a;
        for (instrs) |*u| {
            if (ir.usesA(u.op) and u.a == fref) u.a = src;
            if (ir.usesB(u.op) and u.b == fref) u.b = src;
        }
        instrs[f] = .{ .op = .nop };
    }
}

/// Fold integer arithmetic / comparison on constant operands into a constant.
/// Matches the interpreter's checked-overflow semantics by *declining* to fold
/// on overflow (the runtime path then raises, exactly as before).
fn constFold(trace: *Trace, allocator: std.mem.Allocator) void {
    const instrs = trace.instrs.items;
    for (instrs) |*instr| {
        if (!ir.usesA(instr.op) or !ir.usesB(instr.op)) continue;
        const ca = constIntOf(trace, instr.a) orelse continue;
        const cb = constIntOf(trace, instr.b) orelse continue;
        const folded: ?Value = switch (instr.op) {
            .add_int => if (addOvf(ca, cb)) |v| Value.int(v) else null,
            .sub_int => if (subOvf(ca, cb)) |v| Value.int(v) else null,
            .mul_int => if (mulOvf(ca, cb)) |v| Value.int(v) else null,
            .eq => Value.boolVal(ca == cb),
            .lt => Value.boolVal(ca < cb),
            else => null,
        };
        if (folded) |v| {
            // Reuse this slot as a const_val; appending the const can't fail
            // to keep folding infallible — fall back to leaving the op if it does.
            const idx = trace.consts.items.len;
            trace.consts.append(allocator, v) catch continue;
            instr.* = .{ .op = .const_val, .aux = @intCast(idx) };
        }
    }
}

fn constIntOf(trace: *const Trace, ref: Ref) ?i64 {
    if (ref >= trace.instrs.items.len) return null;
    const instr = trace.instrs.items[ref];
    if (instr.op != .const_val) return null;
    if (instr.aux >= trace.consts.items.len) return null;
    const v = trace.consts.items[instr.aux];
    if (!v.isInt()) return null;
    return v.asInt();
}

fn addOvf(a: i64, b: i64) ?i64 {
    const r = @addWithOverflow(a, b);
    return if (r[1] != 0) null else r[0];
}
fn subOvf(a: i64, b: i64) ?i64 {
    const r = @subWithOverflow(a, b);
    return if (r[1] != 0) null else r[0];
}
fn mulOvf(a: i64, b: i64) ?i64 {
    const r = @mulWithOverflow(a, b);
    return if (r[1] != 0) null else r[0];
}

/// Remove guards proven redundant by an earlier identical guard. Because the
/// IR is SSA (a Ref's value never changes), a guard `(kind, ref, aux2)` that
/// already fired upstream cannot fail again — nop the repeat.
fn dedupeGuards(trace: *Trace, allocator: std.mem.Allocator) !void {
    const Seen = struct { ref: Ref, kind: u32, aux2: u32 };
    var seen: std.ArrayListUnmanaged(Seen) = .empty;
    defer seen.deinit(allocator);
    for (trace.instrs.items) |*instr| {
        if (instr.op != .guard) continue;
        var dup = false;
        for (seen.items) |s| {
            if (s.ref == instr.a and s.kind == instr.aux and s.aux2 == instr.aux2) {
                dup = true;
                break;
            }
        }
        if (dup) {
            instr.* = .{ .op = .nop };
        } else {
            try seen.append(allocator, .{ .ref = instr.a, .kind = instr.aux, .aux2 = instr.aux2 });
        }
    }
}

/// Nop out pure instructions whose results are never used. Liveness flows from
/// the `ret` and from effectful/control ops (which are always kept) backward
/// to their operands; since SSA operands have smaller indices than their uses,
/// a single high→low pass computes final liveness.
fn deadCodeElim(trace: *Trace, allocator: std.mem.Allocator) !void {
    const n = trace.instrs.items.len;
    if (n == 0) return;
    var live = try allocator.alloc(bool, n);
    defer allocator.free(live);
    @memset(live, false);

    const instrs = trace.instrs.items;
    var i: usize = n;
    while (i > 0) {
        i -= 1;
        const instr = instrs[i];
        if (instr.op == .nop) continue;
        // Effectful/control ops are kept regardless of whether their result is
        // used; pure ops are kept only if a later live op uses them.
        const kept = !ir.isPure(instr.op);
        if (!kept and !live[i]) {
            instrs[i] = .{ .op = .nop };
            continue;
        }
        if (ir.usesA(instr.op) and instr.a < n) live[instr.a] = true;
        if (ir.usesB(instr.op) and instr.b < n) live[instr.b] = true;
    }
}

/// Count non-nop instructions (for diagnostics / tests).
pub fn liveLen(trace: *const Trace) usize {
    var c: usize = 0;
    for (trace.instrs.items) |instr| {
        if (instr.op != .nop) c += 1;
    }
    return c;
}

test "redundant force feeding only forcing consumers is elided" {
    const allocator = std.testing.allocator;
    var trace = Trace.init(1, false);
    defer trace.deinit(allocator);
    // load_upvalue 0; force; get_attr(force, "x"); ret(get_attr)
    const up = try trace.emit(allocator, .{ .op = .load_upvalue, .aux = 0 });
    const fr = try trace.emit(allocator, .{ .op = .force, .a = up });
    const ga = try trace.emit(allocator, .{ .op = .get_attr, .a = fr, .aux = 7 });
    _ = try trace.emit(allocator, .{ .op = .ret, .a = ga });

    try optimize(&trace, allocator);
    const ops = trace.instrs.items;
    // get_attr already forces its operand → the force is redundant and removed,
    // get_attr now reads the raw upvalue directly.
    try std.testing.expectEqual(Op.nop, ops[fr].op);
    try std.testing.expectEqual(Op.get_attr, ops[ga].op);
    try std.testing.expectEqual(up, ops[ga].a);
}

test "force feeding ret (a non-forcing consumer) is kept" {
    const allocator = std.testing.allocator;
    var trace = Trace.init(1, false);
    defer trace.deinit(allocator);
    // load_upvalue 0; force; ret(force) — the force IS the WHNF guarantee, keep it
    const up = try trace.emit(allocator, .{ .op = .load_upvalue, .aux = 0 });
    const fr = try trace.emit(allocator, .{ .op = .force, .a = up });
    _ = try trace.emit(allocator, .{ .op = .ret, .a = fr });

    try optimize(&trace, allocator);
    const ops = trace.instrs.items;
    try std.testing.expectEqual(Op.force, ops[fr].op); // kept: ret doesn't force
}

test "const folding collapses constant arithmetic" {
    const allocator = std.testing.allocator;
    var trace = Trace.init(1, false);
    defer trace.deinit(allocator);
    const c2 = try trace.addConst(allocator, Value.int(2));
    const c3 = try trace.addConst(allocator, Value.int(3));
    const a = try trace.emit(allocator, .{ .op = .const_val, .aux = c2 });
    const b = try trace.emit(allocator, .{ .op = .const_val, .aux = c3 });
    const sum = try trace.emit(allocator, .{ .op = .add_int, .a = a, .b = b });
    _ = try trace.emit(allocator, .{ .op = .ret, .a = sum });

    try optimize(&trace, allocator);

    // add_int folded to const 5; the two operand consts are now dead → nop.
    const ops = trace.instrs.items;
    try std.testing.expectEqual(Op.const_val, ops[sum].op);
    try std.testing.expectEqual(@as(i64, 5), trace.consts.items[ops[sum].aux].asInt());
    try std.testing.expectEqual(Op.nop, ops[a].op);
    try std.testing.expectEqual(Op.nop, ops[b].op);
    // live: folded const + ret.
    try std.testing.expectEqual(@as(usize, 2), liveLen(&trace));
}

test "redundant guard on the same ref is removed" {
    const allocator = std.testing.allocator;
    var trace = Trace.init(7, true);
    defer trace.deinit(allocator);
    const arg = try trace.emit(allocator, .{ .op = .trace_arg });
    _ = try trace.emit(allocator, .{ .op = .guard, .a = arg, .aux = 3, .aux2 = 9 });
    _ = try trace.emit(allocator, .{ .op = .guard, .a = arg, .aux = 3, .aux2 = 9 }); // dup
    const ga = try trace.emit(allocator, .{ .op = .get_attr, .a = arg, .aux = 9 });
    _ = try trace.emit(allocator, .{ .op = .ret, .a = ga });

    try optimize(&trace, allocator);
    const ops = trace.instrs.items;
    try std.testing.expectEqual(Op.guard, ops[1].op);
    try std.testing.expectEqual(Op.nop, ops[2].op); // duplicate removed
    try std.testing.expectEqual(Op.get_attr, ops[3].op); // kept (effectful)
}

test "dead pure computation is eliminated, live kept" {
    const allocator = std.testing.allocator;
    var trace = Trace.init(1, true);
    defer trace.deinit(allocator);
    const arg = try trace.emit(allocator, .{ .op = .trace_arg });
    const up = try trace.emit(allocator, .{ .op = .load_upvalue, .aux = 0 }); // unused
    _ = up;
    _ = try trace.emit(allocator, .{ .op = .ret, .a = arg });

    try optimize(&trace, allocator);
    const ops = trace.instrs.items;
    try std.testing.expectEqual(Op.trace_arg, ops[0].op); // live (ret uses it)
    try std.testing.expectEqual(Op.nop, ops[1].op); // dead upvalue load
    try std.testing.expectEqual(Op.ret, ops[2].op);
}
