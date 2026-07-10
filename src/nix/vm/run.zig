//! Threaded bytecode dispatcher.
//!
//! Every opcode is a small standalone function with the signature
//! `fn (vm, frame, code, ip, stop_depth) anyerror!Value`. Each handler
//! does its per-opcode work and tail-calls `dispatch`, which reads the
//! next opcode byte and tail-calls its handler via a static table.
//!
//! `@call(.always_tail, ...)` forces LLVM to emit a `jmp` rather than a
//! `call`, so handlers never push frames — the whole dispatch chain
//! reuses a single stack frame established by the outermost `runUntil`.
//!
//! Why threaded code rather than one giant switch: a 70-arm switch
//! becomes a single ~32 KB function. LLVM's register allocator gives up
//! aggressive slot coloring at that size, so adding a single case grew
//! the stack frame by 16 bytes for *every* arm. Splitting handlers into
//! small standalone functions lets the compiler allocate registers
//! locally per handler, eliminates the per-arm spill amortisation cost,
//! and makes adding cases genuinely free at the codegen level.

const std = @import("std");
const vm_mod = @import("../vm.zig");
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const InternId = types.InternId;
const ChunkId = types.ChunkId;
const bytecode_mod = @import("bytecode");
const opcode = bytecode_mod.opcode;
const OpCode = opcode.OpCode;
const heap_mod = @import("runtime").heap;
const numeric = @import("runtime").numeric;
const prof = @import("probe").prof;
const prof_census = @import("probe").prof_census;

const access = @import("access.zig");
const closures = @import("closures.zig");
const debug = @import("debug.zig");
const equality = @import("equality.zig");
const force = @import("force.zig");
const objects = @import("objects.zig");
const stack = @import("stack.zig");
const strings = @import("strings.zig");
const trace_log = @import("trace_log.zig");

const VM = vm_mod.VM;
const Frame = vm_mod.Frame;
const opcode_profile_enabled = vm_mod.opcode_profile_enabled;
const readU16 = vm_mod.readU16;
const readU32 = vm_mod.readU32;

const HandlerFn = *const fn (*VM, *Frame, []const u8, usize, usize) anyerror!void;

// ---- entry points ----
//
// Handlers return `anyerror!void` because `anyerror!Value` is 24 bytes
// on x86-64 SysV, which forces the ABI to return-by-sret-pointer,
// which in turn prevents LLVM from `musttail`-jumping between handlers
// (sret slot wouldn't match across the chain). Instead each handler
// either pushes its produced value onto the VM's value stack (the
// normal case) or leaves the dispatch chain via a normal return when
// the chunk's frame is popped. `runUntil` pops the final result off
// `vm.stack` and hands it back to its caller.

pub fn run(vm: *VM) anyerror!Value {
    return runUntil(vm, 0);
}

pub fn runUntil(vm: *VM, stop_depth: usize) anyerror!Value {
    const frame = stack.currentFrame(vm);
    try dispatchEntry(vm, frame, frame.chunk_ptr.code, frame.ip, stop_depth);
    return stack.pop(vm);
}

/// Non-inline trampoline so `runUntil` (sig: `(vm, stop_depth)`) can
/// kick off the dispatch chain without violating the
/// matching-signature requirement of `@call(.always_tail)`. The body
/// is just an inlined `dispatch`, which ends in a tail call to the
/// first handler — that tail call is *from* this function, whose sig
/// matches the handler sig.
fn dispatchEntry(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    return dispatch(vm, frame, code, ip, stop_depth);
}

// ---- dispatch ----

/// Read the next opcode at `code[ip]` and tail-call its handler with
/// `ip + 1` (so the handler sees `ip` pointing at the first operand
/// byte). Inlined into every handler's epilogue so the dispatch chain
/// is a sequence of direct tail-jumps — no per-handler stack frame.
inline fn dispatch(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    if (ip >= code.len) return endOfCode(vm);
    if (comptime debug.enabled) {
        debug.checkVm(vm, "dispatch");
        debug.checkFrameSync(vm, frame, code, "dispatch");
    }
    const op: OpCode = @enumFromInt(code[ip]);
    if (comptime opcode_profile_enabled) vm.opcode_counts[@intFromEnum(op)] += 1;
    if (comptime trace_log.enabled) {
        trace_log.op(vm.vm_trace, vm.workerId(), vm.frames_len, frame.chunk_id, @intCast(ip), op, vm.sp);
    }
    return @call(.always_tail, handlers[@intFromEnum(op)], .{ vm, frame, code, ip + 1, stop_depth });
}

/// End of chunk reached without a `ret` — ensure there's at least one
/// value on the stack for `runUntil` to pop.
fn endOfCode(vm: *VM) anyerror!void {
    if (vm.sp == 0) try stack.push(vm, Value.null_val);
}

// ---- handlers: stack ----

fn opConstant(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const idx = readU16(code, ip);
    try stack.push(vm, frame.chunk_ptr.constants[idx]);
    return dispatch(vm, frame, code, ip + 2, stop_depth);
}

fn opPushNull(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    try stack.push(vm, Value.null_val);
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opPushTrue(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    try stack.push(vm, Value.boolVal(true));
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opPushFalse(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    try stack.push(vm, Value.boolVal(false));
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opPop(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    _ = stack.pop(vm);
    return dispatch(vm, frame, code, ip, stop_depth);
}

// ---- handlers: locals ----

fn opGetLocal(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const slot = code[ip];
    const raw = vm.stack[frame.frame_base + slot];
    if (comptime prof.enabled) {
        if (vm.workerId() == 0 and force.profIsResolvedThunk(vm, raw)) prof_census.rf_local += 1;
    }
    const val = try force.forceValue(vm, raw);
    try stack.push(vm, val);
    return dispatch(vm, frame, code, ip + 1, stop_depth);
}

fn opGetLocalLong(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const slot = readU16(code, ip);
    const raw = vm.stack[frame.frame_base + slot];
    if (comptime prof.enabled) {
        if (vm.workerId() == 0 and force.profIsResolvedThunk(vm, raw)) prof_census.rf_local += 1;
    }
    const val = try force.forceValue(vm, raw);
    try stack.push(vm, val);
    return dispatch(vm, frame, code, ip + 2, stop_depth);
}

fn opCaptureLocal(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const slot = code[ip];
    try stack.push(vm, vm.stack[frame.frame_base + slot]);
    return dispatch(vm, frame, code, ip + 1, stop_depth);
}

fn opCaptureLocalLong(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const slot = readU16(code, ip);
    try stack.push(vm, vm.stack[frame.frame_base + slot]);
    return dispatch(vm, frame, code, ip + 2, stop_depth);
}

fn opCaptureUpvalue(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const slot = readU16(code, ip);
    const upvalues = frame.upvalues orelse return error.MissingClosure;
    try stack.push(vm, upvalues[slot]);
    return dispatch(vm, frame, code, ip + 2, stop_depth);
}

fn opSetLocal(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const slot = code[ip];
    const val = stack.pop(vm);
    stack.setStack(vm, frame.frame_base + slot, val);
    return dispatch(vm, frame, code, ip + 1, stop_depth);
}

fn opSetLocalLong(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const slot = readU16(code, ip);
    const val = stack.pop(vm);
    stack.setStack(vm, frame.frame_base + slot, val);
    return dispatch(vm, frame, code, ip + 2, stop_depth);
}

fn opSetCellLocal(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const slot = code[ip];
    const val = stack.pop(vm);
    const cell_val = vm.stack[frame.frame_base + slot];
    if (!cell_val.isThunk()) return error.TypeError;
    const thunk = vm.heap.getThunkAssumeValid(cell_val.asObjectId());
    // Cell was born `.evaluating` claimed by us (see initBindingCell):
    // publishCellBinding installs pass_through(val), drops the claim,
    // and transitions back to `.unresolved` so future forces run the
    // pass_through path lazily. Any helper that parked while we held
    // the claim wakes here.
    thunk.publishCellBinding(val);
    vm.heap.gcRecordEdge(cell_val.asObjectId(), val); // old→young barrier
    return dispatch(vm, frame, code, ip + 1, stop_depth);
}

fn opSetCellLocalLong(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const slot = readU16(code, ip);
    const val = stack.pop(vm);
    const cell_val = vm.stack[frame.frame_base + slot];
    if (!cell_val.isThunk()) return error.TypeError;
    const thunk = vm.heap.getThunkAssumeValid(cell_val.asObjectId());
    thunk.publishCellBinding(val);
    vm.heap.gcRecordEdge(cell_val.asObjectId(), val); // old→young barrier
    return dispatch(vm, frame, code, ip + 2, stop_depth);
}

fn opGetUpvalue(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const slot = readU16(code, ip);
    const upvalues = frame.upvalues orelse return error.MissingClosure;
    if (comptime prof.enabled) {
        if (vm.workerId() == 0 and force.profIsResolvedThunk(vm, upvalues[slot])) prof_census.rf_upvalue += 1;
    }
    const val = try force.forceValue(vm, upvalues[slot]);
    try stack.push(vm, val);
    return dispatch(vm, frame, code, ip + 2, stop_depth);
}

// ---- handlers: integer arithmetic ----

fn opAddInt(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    // Force both operands in place (they stay on the stack, so a GC at
    // either force keeps both rooted); drop only after. `forceAt` is the
    // GC-safe primitive — never `forceValue(pop())`. See vm/force.zig.
    const b = try force.forceTop(vm);
    const a = try force.forceAt(vm, 1);
    if (numeric.isNumeric(a) and numeric.isNumeric(b)) {
        stack.dropBin(vm);
        try stack.push(vm, try numeric.add(vm.heap, a, b));
    } else {
        // GC: the string/path concat helpers force BOTH operands again
        // (coerceLanguageStringValue → forceValue + possible callValue/
        // getAttrValue on a `__toString`/`outPath` attrset — GC safepoints)
        // while the other operand is held only in a Zig local. Keep both on
        // the operand stack across the concat so they stay precise roots;
        // drop only after. Compiles away without -Dgc.
        const result = if (a.isPath())
            try strings.concatPathLike(vm, a, b)
        else
            try strings.concatStringLike(vm, a, b);
        stack.dropBin(vm);
        try stack.push(vm, result);
    }
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opSubInt(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const b = stack.pop(vm);
    const a = stack.pop(vm);
    try stack.push(vm, try numeric.sub(vm.heap, a, b));
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opMulInt(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const b = stack.pop(vm);
    const a = stack.pop(vm);
    try stack.push(vm, try numeric.mul(vm.heap, a, b));
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opDivInt(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const b = stack.pop(vm);
    const a = stack.pop(vm);
    try stack.push(vm, try numeric.div(vm.heap, a, b));
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opNegateInt(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const a = stack.pop(vm);
    try stack.push(vm, try numeric.negate(vm.heap, a));
    return dispatch(vm, frame, code, ip, stop_depth);
}

// ---- handlers: float arithmetic ----

fn opAddFloat(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const b = stack.pop(vm);
    const a = stack.pop(vm);
    try stack.push(vm, Value.float(try numeric.toFloat(a, vm.heap) + try numeric.toFloat(b, vm.heap)));
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opSubFloat(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const b = stack.pop(vm);
    const a = stack.pop(vm);
    try stack.push(vm, Value.float(try numeric.toFloat(a, vm.heap) - try numeric.toFloat(b, vm.heap)));
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opMulFloat(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const b = stack.pop(vm);
    const a = stack.pop(vm);
    try stack.push(vm, Value.float(try numeric.toFloat(a, vm.heap) * try numeric.toFloat(b, vm.heap)));
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opDivFloat(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const b = stack.pop(vm);
    const a = stack.pop(vm);
    const bf = try numeric.toFloat(b, vm.heap);
    // Parity with Nix: float division by zero raises rather than
    // producing IEEE Inf/NaN. The `numeric.div` path enforces the same
    // rule for the fallthrough cases; `opDivFloat` is the hot path the
    // compiler emits when either operand is statically a float.
    if (bf == 0.0) return error.DivisionByZero;
    try stack.push(vm, Value.float(try numeric.toFloat(a, vm.heap) / bf));
    return dispatch(vm, frame, code, ip, stop_depth);
}

// ---- handlers: comparison ----

fn opEq(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    // Operands stay on the stack across valuesEqual (which forces deeply, a
    // GC safepoint) so they remain precise roots; drop only after.
    const ops = stack.binTop(vm);
    const result = try equality.valuesEqual(vm, ops.left, ops.right);
    stack.dropBin(vm);
    try stack.push(vm, Value.boolVal(result));
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opNeq(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const ops = stack.binTop(vm);
    const result = try equality.valuesEqual(vm, ops.left, ops.right);
    stack.dropBin(vm);
    try stack.push(vm, Value.boolVal(!result));
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opEqNull(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const v = try force.forceValue(vm, stack.pop(vm));
    try stack.push(vm, Value.boolVal(v.kind() == .null));
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opNeqNull(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const v = try force.forceValue(vm, stack.pop(vm));
    try stack.push(vm, Value.boolVal(v.kind() != .null));
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opLt(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const ops = stack.binTop(vm);
    const r = try equality.compareValues(vm, ops.left, ops.right);
    stack.dropBin(vm);
    try stack.push(vm, Value.boolVal(r == .lt));
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opLte(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const ops = stack.binTop(vm);
    const r = try equality.compareValues(vm, ops.left, ops.right);
    stack.dropBin(vm);
    try stack.push(vm, Value.boolVal(r == .lt or r == .eq));
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opGt(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const ops = stack.binTop(vm);
    const r = try equality.compareValues(vm, ops.left, ops.right);
    stack.dropBin(vm);
    try stack.push(vm, Value.boolVal(r == .gt));
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opGte(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const ops = stack.binTop(vm);
    const r = try equality.compareValues(vm, ops.left, ops.right);
    stack.dropBin(vm);
    try stack.push(vm, Value.boolVal(r == .gt or r == .eq));
    return dispatch(vm, frame, code, ip, stop_depth);
}

// ---- handlers: logical ----

fn opNot(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const a = stack.pop(vm);
    try stack.push(vm, Value.boolVal(!try expectBool(vm, a)));
    return dispatch(vm, frame, code, ip, stop_depth);
}

// ---- handlers: control flow ----

fn opJump(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const offset = readU32(code, ip);
    return dispatch(vm, frame, code, ip + 4 + @as(usize, offset), stop_depth);
}

fn opJumpIfFalse(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const offset = readU32(code, ip);
    var next_ip = ip + 4;
    const cond = vm.stack[vm.sp - 1];
    if (!try expectBool(vm, cond)) {
        next_ip += @as(usize, offset);
    }
    return dispatch(vm, frame, code, next_ip, stop_depth);
}

fn opFailAssertion(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    _ = vm;
    _ = frame;
    _ = code;
    _ = ip;
    _ = stop_depth;
    return error.AssertionFailed;
}

// ---- handlers: data structures ----

fn opBuildAttrs(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const count = readU16(code, ip);
    try objects.buildAttrs(vm, count);
    return dispatch(vm, frame, code, ip + 2, stop_depth);
}

fn opBuildAttrsWithPos(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    return buildAttrsWithPosImpl(vm, frame, code, ip, stop_depth, false);
}

fn opBuildAttrsSorted(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const count = readU16(code, ip);
    try objects.buildAttrsSorted(vm, count, &.{});
    return dispatch(vm, frame, code, ip + 2, stop_depth);
}

fn opBuildAttrsWithPosSorted(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    return buildAttrsWithPosImpl(vm, frame, code, ip, stop_depth, true);
}

inline fn buildAttrsWithPosImpl(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize, comptime presorted: bool) anyerror!void {
    frame.ip = ip;
    const count = readU16(code, ip);
    var cur_ip = ip + 2;
    const pos_count = readU16(code, cur_ip);
    cur_ip += 2;

    var stack_positions: [32]heap_mod.AttrPosEntry = undefined;
    const positions = if (pos_count <= stack_positions.len)
        stack_positions[0..pos_count]
    else
        try vm.allocator.alloc(heap_mod.AttrPosEntry, pos_count);
    defer if (positions.ptr != stack_positions[0..].ptr) vm.allocator.free(positions);

    for (positions) |*position| {
        position.* = .{
            .name = readU32(code, cur_ip),
            .pos = .{
                .file = readU32(code, cur_ip + 4),
                .line = readU32(code, cur_ip + 8),
                .column = readU32(code, cur_ip + 12),
            },
        };
        cur_ip += 16;
    }
    if (comptime presorted)
        try objects.buildAttrsSorted(vm, count, positions)
    else
        try objects.buildAttrsWithPositions(vm, count, positions);
    return dispatch(vm, frame, code, cur_ip, stop_depth);
}

fn opBuildList(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const count = readU16(code, ip);
    try objects.buildList(vm, count);
    return dispatch(vm, frame, code, ip + 2, stop_depth);
}

fn opMergeAttrs(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    // Keep both operands on the stack across mergeAttrs (forces + allocates,
    // a GC safepoint) so they stay precise roots; drop only after.
    const ops = stack.binTop(vm);
    const t = prof.start(.merge_attrs);
    const merged = try objects.mergeAttrs(vm, ops.left, ops.right);
    prof.end(.merge_attrs, t);
    stack.dropBin(vm);
    try stack.push(vm, merged);
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opMergeAttrsStrict(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const ops = stack.binTop(vm);
    const t = prof.start(.merge_attrs);
    const merged = try objects.mergeAttrsStrict(vm, ops.left, ops.right);
    prof.end(.merge_attrs, t);
    stack.dropBin(vm);
    try stack.push(vm, merged);
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opConcatLists(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const ops = stack.binTop(vm);
    const result = try objects.concatLists(vm, ops.left, ops.right);
    stack.dropBin(vm);
    try stack.push(vm, result);
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opConcatStrings(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const count = readU16(code, ip);
    // Operands stay on the stack across the coercions/forces inside
    // (precise GC roots); drop only after the result is built.
    const result = try strings.concatStackStrings(vm, count);
    stack.dropN(vm, count);
    try stack.push(vm, result);
    return dispatch(vm, frame, code, ip + 2, stop_depth);
}

fn opPushBuiltins(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    try stack.push(vm, vm.builtins);
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opFindFile(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const name_id = readU16(code, ip);
    const host = vm.import_host orelse return error.SearchPathUnavailable;
    try stack.push(vm, try host.find_file(host.context, vm.intern.get(@intCast(name_id))));
    return dispatch(vm, frame, code, ip + 2, stop_depth);
}

fn opFindFileLong(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const name_id: InternId = readU32(code, ip);
    const host = vm.import_host orelse return error.SearchPathUnavailable;
    try stack.push(vm, try host.find_file(host.context, vm.intern.get(name_id)));
    return dispatch(vm, frame, code, ip + 4, stop_depth);
}

// ---- handlers: closures and thunks ----

fn opClosure(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const ch_id = readU16(code, ip);
    const upvalue_count = readU16(code, ip + 2);
    try closures.makeClosure(vm, ch_id, upvalue_count);
    return dispatch(vm, frame, code, ip + 4, stop_depth);
}

fn opClosureLong(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const ch_id: ChunkId = readU32(code, ip);
    const upvalue_count = readU16(code, ip + 4);
    try closures.makeClosure(vm, ch_id, upvalue_count);
    return dispatch(vm, frame, code, ip + 6, stop_depth);
}

fn opClosureCaptures(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const ch_id = readU16(code, ip);
    const upvalue_count = readU16(code, ip + 2);
    const descriptors_start = ip + 4;
    const descriptor_len = @as(usize, upvalue_count) * 3;
    if (descriptor_len > code.len - descriptors_start) return error.InvalidBytecode;
    const descriptors = code[descriptors_start .. descriptors_start + descriptor_len];
    try closures.makeClosureFromCaptures(vm, ch_id, descriptors, frame);
    return dispatch(vm, frame, code, descriptors_start + descriptor_len, stop_depth);
}

fn opClosureCapturesLong(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const ch_id: ChunkId = readU32(code, ip);
    const upvalue_count = readU16(code, ip + 4);
    const descriptors_start = ip + 6;
    const descriptor_len = @as(usize, upvalue_count) * 3;
    if (descriptor_len > code.len - descriptors_start) return error.InvalidBytecode;
    const descriptors = code[descriptors_start .. descriptors_start + descriptor_len];
    try closures.makeClosureFromCaptures(vm, ch_id, descriptors, frame);
    return dispatch(vm, frame, code, descriptors_start + descriptor_len, stop_depth);
}

fn opApplyArg(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const ch_id: ChunkId = readU32(code, ip);
    const upvalue_count = readU16(code, ip + 4);
    const descriptors_start = ip + 6;
    const descriptor_len = @as(usize, upvalue_count) * 3;
    if (descriptor_len > code.len - descriptors_start) return error.InvalidBytecode;
    const descriptors = code[descriptors_start .. descriptors_start + descriptor_len];
    // The callee is already on the stack just below where the argument
    // goes. If it forces its parameter, evaluate the argument eagerly to
    // a value; otherwise materialise the usual thunk.
    const callee = vm.stack[vm.sp - 1];
    const forces = closures.calleeForcesArg(vm, callee);
    if (forces) {
        try closures.evalArgEager(vm, ch_id, descriptors, frame);
    } else {
        try closures.makeBytecodeThunkFromCaptures(vm, ch_id, descriptors, frame);
    }
    return dispatch(vm, frame, code, descriptors_start + descriptor_len, stop_depth);
}

fn opThunkCaptures(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const ch_id = readU16(code, ip);
    const upvalue_count = readU16(code, ip + 2);
    const descriptors_start = ip + 4;
    const descriptor_len = @as(usize, upvalue_count) * 3;
    if (descriptor_len > code.len - descriptors_start) return error.InvalidBytecode;
    const descriptors = code[descriptors_start .. descriptors_start + descriptor_len];
    try closures.makeBytecodeThunkFromCaptures(vm, ch_id, descriptors, frame);
    return dispatch(vm, frame, code, descriptors_start + descriptor_len, stop_depth);
}

fn opThunkCapturesLong(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const ch_id: ChunkId = readU32(code, ip);
    const upvalue_count = readU16(code, ip + 4);
    const descriptors_start = ip + 6;
    const descriptor_len = @as(usize, upvalue_count) * 3;
    if (descriptor_len > code.len - descriptors_start) return error.InvalidBytecode;
    const descriptors = code[descriptors_start .. descriptors_start + descriptor_len];
    try closures.makeBytecodeThunkFromCaptures(vm, ch_id, descriptors, frame);
    return dispatch(vm, frame, code, descriptors_start + descriptor_len, stop_depth);
}

fn opDeferAttrValue(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const deferred_id: u32 = readU32(code, ip);
    const env_count = readU16(code, ip + 4);
    const descriptors_start = ip + 6;
    const descriptor_len = @as(usize, env_count) * 3;
    if (descriptor_len > code.len - descriptors_start) return error.InvalidBytecode;
    const descriptors = code[descriptors_start .. descriptors_start + descriptor_len];
    try closures.makeDeferredThunkFromCaptures(vm, deferred_id, descriptors, frame);
    return dispatch(vm, frame, code, descriptors_start + descriptor_len, stop_depth);
}

fn opThunkCapturesEager(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const ch_id = readU16(code, ip);
    const upvalue_count = readU16(code, ip + 2);
    const descriptors_start = ip + 4;
    const descriptor_len = @as(usize, upvalue_count) * 3;
    if (descriptor_len > code.len - descriptors_start) return error.InvalidBytecode;
    const descriptors = code[descriptors_start .. descriptors_start + descriptor_len];
    try closures.makeBytecodeThunkFromCapturesEager(vm, ch_id, descriptors, frame);
    return dispatch(vm, frame, code, descriptors_start + descriptor_len, stop_depth);
}

fn opThunkCapturesEagerLong(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const ch_id: ChunkId = readU32(code, ip);
    const upvalue_count = readU16(code, ip + 4);
    const descriptors_start = ip + 6;
    const descriptor_len = @as(usize, upvalue_count) * 3;
    if (descriptor_len > code.len - descriptors_start) return error.InvalidBytecode;
    const descriptors = code[descriptors_start .. descriptors_start + descriptor_len];
    try closures.makeBytecodeThunkFromCapturesEager(vm, ch_id, descriptors, frame);
    return dispatch(vm, frame, code, descriptors_start + descriptor_len, stop_depth);
}

fn opThunkCapturesStoreCellLocal(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const ch_id = readU16(code, ip);
    const upvalue_count = readU16(code, ip + 2);
    const descriptors_start = ip + 4;
    const descriptor_len = @as(usize, upvalue_count) * 3;
    if (descriptor_len > code.len - descriptors_start) return error.InvalidBytecode;
    const descriptors = code[descriptors_start .. descriptors_start + descriptor_len];
    try closures.makeBytecodeThunkFromCaptures(vm, ch_id, descriptors, frame);
    // Slot byte is at end of operand. Pop value just pushed, publish
    // into cell at slot.
    const slot_offset = descriptors_start + descriptor_len;
    const slot = code[slot_offset];
    const val = stack.pop(vm);
    const cell_val = vm.stack[frame.frame_base + slot];
    if (!cell_val.isThunk()) return error.TypeError;
    vm.heap.getThunkAssumeValid(cell_val.asObjectId()).publishCellBinding(val);
    vm.heap.gcRecordEdge(cell_val.asObjectId(), val); // old→young barrier
    return dispatch(vm, frame, code, slot_offset + 1, stop_depth);
}

fn opThunkCapturesStoreLocal(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const ch_id = readU16(code, ip);
    const upvalue_count = readU16(code, ip + 2);
    const descriptors_start = ip + 4;
    const descriptor_len = @as(usize, upvalue_count) * 3;
    if (descriptor_len > code.len - descriptors_start) return error.InvalidBytecode;
    const descriptors = code[descriptors_start .. descriptors_start + descriptor_len];
    try closures.makeBytecodeThunkFromCaptures(vm, ch_id, descriptors, frame);
    const slot_offset = descriptors_start + descriptor_len;
    const slot = code[slot_offset];
    stack.setStack(vm, frame.frame_base + slot, stack.pop(vm));
    return dispatch(vm, frame, code, slot_offset + 1, stop_depth);
}

fn opThunkCapturesEagerStoreCellLocal(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const ch_id = readU16(code, ip);
    const upvalue_count = readU16(code, ip + 2);
    const descriptors_start = ip + 4;
    const descriptor_len = @as(usize, upvalue_count) * 3;
    if (descriptor_len > code.len - descriptors_start) return error.InvalidBytecode;
    const descriptors = code[descriptors_start .. descriptors_start + descriptor_len];
    try closures.makeBytecodeThunkFromCapturesEager(vm, ch_id, descriptors, frame);
    const slot_offset = descriptors_start + descriptor_len;
    const slot = code[slot_offset];
    const val = stack.pop(vm);
    const cell_val = vm.stack[frame.frame_base + slot];
    if (!cell_val.isThunk()) return error.TypeError;
    vm.heap.getThunkAssumeValid(cell_val.asObjectId()).publishCellBinding(val);
    vm.heap.gcRecordEdge(cell_val.asObjectId(), val); // old→young barrier
    return dispatch(vm, frame, code, slot_offset + 1, stop_depth);
}

fn opThunkCapturesEagerStoreLocal(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const ch_id = readU16(code, ip);
    const upvalue_count = readU16(code, ip + 2);
    const descriptors_start = ip + 4;
    const descriptor_len = @as(usize, upvalue_count) * 3;
    if (descriptor_len > code.len - descriptors_start) return error.InvalidBytecode;
    const descriptors = code[descriptors_start .. descriptors_start + descriptor_len];
    try closures.makeBytecodeThunkFromCapturesEager(vm, ch_id, descriptors, frame);
    const slot_offset = descriptors_start + descriptor_len;
    const slot = code[slot_offset];
    stack.setStack(vm, frame.frame_base + slot, stack.pop(vm));
    return dispatch(vm, frame, code, slot_offset + 1, stop_depth);
}

// ---- handlers: calls ----

fn opCall(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    // Sync ip back so doCall's pushed frame sits on a caller frame
    // whose ip points at the next opcode.
    _ = code;
    frame.ip = ip;
    const arg = stack.pop(vm);
    const callee = stack.pop(vm);
    try closures.doCall(vm, callee, arg);
    const new_frame = stack.currentFrame(vm);
    return dispatch(vm, new_frame, new_frame.chunk_ptr.code, new_frame.ip, stop_depth);
}

fn opTailCall(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    _ = code;
    frame.ip = ip;
    const arg = stack.pop(vm);
    const callee = stack.pop(vm);
    try closures.doTailCall(vm, callee, arg);
    const new_frame = stack.currentFrame(vm);
    return dispatch(vm, new_frame, new_frame.chunk_ptr.code, new_frame.ip, stop_depth);
}

fn opCallN(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    const n = code[ip];
    // Resume past the 1-byte operand when the callee frame rets (fast
    // path) or immediately (fold path pushes a value, no new frame).
    frame.ip = ip + 1;
    try closures.doCallN(vm, n);
    const new_frame = stack.currentFrame(vm);
    return dispatch(vm, new_frame, new_frame.chunk_ptr.code, new_frame.ip, stop_depth);
}

fn opTailCallN(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    const n = code[ip];
    frame.ip = ip + 1;
    try closures.doTailCallN(vm, n);
    const new_frame = stack.currentFrame(vm);
    return dispatch(vm, new_frame, new_frame.chunk_ptr.code, new_frame.ip, stop_depth);
}

// ---- handlers: thunks ----

fn opMakeCell(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const val = stack.pop(vm);
    try stack.push(vm, try force.makeCell(vm, val));
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opMakeLazyShell(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    // The lazy-shell wrap exists solely so the lazy-XML renderer can show
    // eagerly-built shapes as `<unevaluated />` until demanded. Outside
    // that mode (the common default/JSON/`.drv`/strict path) it's pure
    // overhead — leave the value on the stack instead of allocating a
    // throwaway thunk (millions on the NixOS toplevel).
    if (vm.lazy_shells_visible) {
        const val = stack.pop(vm);
        const id = try vm.heap.addLazyShell(val);
        try stack.push(vm, Value.thunk(id));
    }
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opInitCellSlot(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const slot = code[ip];
    const cell = try force.makeBindingCell(vm);
    vm.stack[frame.frame_base + slot] = cell;
    return dispatch(vm, frame, code, ip + 1, stop_depth);
}

fn opInitCellSlotLong(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const slot = readU16(code, ip);
    const cell = try force.makeBindingCell(vm);
    vm.stack[frame.frame_base + slot] = cell;
    return dispatch(vm, frame, code, ip + 2, stop_depth);
}

// ---- handlers: attribute access ----

fn opGetAttr(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const name_id = readU16(code, ip);
    // Keep attrs_val on the stack across getAttrValue (which forces the
    // attrset AND the looked-up value — the second force would otherwise
    // expose a popped attrs_val). Replace it in place with the result.
    const attrs_val = vm.stack[vm.sp - 1];
    const result = try access.getAttrValue(vm, attrs_val, @intCast(name_id));
    vm.stack[vm.sp - 1] = result;
    return dispatch(vm, frame, code, ip + 2, stop_depth);
}

fn opGetAttrLong(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const name_id: InternId = readU32(code, ip);
    const attrs_val = vm.stack[vm.sp - 1];
    const result = try access.getAttrValue(vm, attrs_val, name_id);
    vm.stack[vm.sp - 1] = result;
    return dispatch(vm, frame, code, ip + 4, stop_depth);
}

fn opGetAttrDynamic(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    // [attrs, name] both stay on the stack across the forces.
    const name_val = try force.forceValue(vm, vm.stack[vm.sp - 1]);
    if (!name_val.isString()) return error.TypeError;
    const attrs_val = vm.stack[vm.sp - 2];
    const result = try access.getAttrValue(vm, attrs_val, name_val.asInternId());
    vm.sp -= 2;
    try stack.push(vm, result);
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opGetAttrDynamicOr(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    // Operands [attrs, name, default] stay on the stack across all forces
    // (GC safepoints) so they remain precise roots; drop only after.
    const default_val = vm.stack[vm.sp - 1];
    const name_val = try force.forceValue(vm, vm.stack[vm.sp - 2]);
    if (!name_val.isString()) return error.TypeError;
    const attrs = try force.forceValue(vm, vm.stack[vm.sp - 3]);
    var result: Value = undefined;
    if (!attrs.isAttrs()) {
        result = try force.forceValue(vm, default_val);
    } else {
        result = vm.heap.getAttrValue(attrs.asObjectId(), name_val.asInternId()) catch |err| switch (err) {
            error.MissingAttribute => try force.forceValue(vm, default_val),
            else => return err,
        };
        result = try force.forceValue(vm, result);
    }
    vm.sp -= 3;
    try stack.push(vm, result);
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opGetAttrPathDynamicOr(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const segment_count = code[ip];
    const names_start = ip + 1;
    const names_end = names_start + @as(usize, segment_count) * 2;
    // [attrs, name, default] stay on the stack across the (internally
    // forcing) helper so they remain precise GC roots; drop only after.
    const default_val = vm.stack[vm.sp - 1];
    const name_val = vm.stack[vm.sp - 2];
    const attrs_val = vm.stack[vm.sp - 3];
    const result = try access.getAttrPathDynamicOrValue(vm, attrs_val, name_val, default_val, code[names_start..names_end], false);
    vm.sp -= 3;
    try stack.push(vm, result);
    return dispatch(vm, frame, code, names_end, stop_depth);
}

fn opGetAttrPathDynamicOrLong(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const segment_count = code[ip];
    const names_start = ip + 1;
    const names_end = names_start + @as(usize, segment_count) * 4;
    const default_val = vm.stack[vm.sp - 1];
    const name_val = vm.stack[vm.sp - 2];
    const attrs_val = vm.stack[vm.sp - 3];
    const result = try access.getAttrPathDynamicOrValue(vm, attrs_val, name_val, default_val, code[names_start..names_end], true);
    vm.sp -= 3;
    try stack.push(vm, result);
    return dispatch(vm, frame, code, names_end, stop_depth);
}

fn opGetAttrPathOr(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const segment_count = code[ip];
    const names_start = ip + 1;
    const names_end = names_start + @as(usize, segment_count) * 2;
    // [attrs, default] stay on the stack across the (internally forcing)
    // helper so they remain precise GC roots; drop only after.
    const default_val = vm.stack[vm.sp - 1];
    const attrs_val = vm.stack[vm.sp - 2];
    const result = try access.getAttrPathOrValue(vm, attrs_val, default_val, code[names_start..names_end], false);
    vm.sp -= 2;
    try stack.push(vm, result);
    return dispatch(vm, frame, code, names_end, stop_depth);
}

fn opGetAttrPathOrLong(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const segment_count = code[ip];
    const names_start = ip + 1;
    const names_end = names_start + @as(usize, segment_count) * 4;
    const default_val = vm.stack[vm.sp - 1];
    const attrs_val = vm.stack[vm.sp - 2];
    const result = try access.getAttrPathOrValue(vm, attrs_val, default_val, code[names_start..names_end], true);
    vm.sp -= 2;
    try stack.push(vm, result);
    return dispatch(vm, frame, code, names_end, stop_depth);
}

fn opGetAttrPathMixedOr(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const segment_count = code[ip];
    const dynamic_count = code[ip + 1];
    const segments_start = ip + 2;
    var cur_ip = segments_start;
    for (0..segment_count) |_| {
        const tag = code[cur_ip];
        cur_ip += 1;
        switch (tag) {
            @intFromEnum(bytecode_mod.MixedAttrSegmentTag.static) => cur_ip += 4,
            @intFromEnum(bytecode_mod.MixedAttrSegmentTag.dynamic) => {},
            else => return error.InvalidBytecode,
        }
    }
    // Stack layout (bottom→top): [attrs, dyn0, dyn1, …, dynN-1, default].
    // Read them in place (a slice into the operand stack for the dynamic
    // names — no heap alloc, and they stay rooted across the internally-
    // forcing helper); drop all N+2 only after.
    const default_val = vm.stack[vm.sp - 1];
    const dyn_base = vm.sp - 1 - dynamic_count;
    const dynamic_names = vm.stack[dyn_base .. vm.sp - 1];
    const attrs_val = vm.stack[dyn_base - 1];
    const result = try access.getAttrPathMixedOrValue(vm, attrs_val, dynamic_names, default_val, code[segments_start..cur_ip], segment_count);
    vm.sp -= (2 + dynamic_count);
    try stack.push(vm, result);
    return dispatch(vm, frame, code, cur_ip, stop_depth);
}

fn opHasAttrPath(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const segment_count = code[ip];
    const names_start = ip + 1;
    const names_end = names_start + @as(usize, segment_count) * 2;
    const attrs_val = vm.stack[vm.sp - 1]; // stays on stack across the path walk
    const r = try access.hasAttrPath(vm, attrs_val, code[names_start..names_end], false);
    vm.stack[vm.sp - 1] = Value.boolVal(r);
    return dispatch(vm, frame, code, names_end, stop_depth);
}

fn opHasAttrPathLong(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const segment_count = code[ip];
    const names_start = ip + 1;
    const names_end = names_start + @as(usize, segment_count) * 4;
    const attrs_val = vm.stack[vm.sp - 1];
    const r = try access.hasAttrPath(vm, attrs_val, code[names_start..names_end], true);
    vm.stack[vm.sp - 1] = Value.boolVal(r);
    return dispatch(vm, frame, code, names_end, stop_depth);
}

fn opHasAttrPathMixed(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const segment_count = code[ip];
    const dynamic_count = code[ip + 1];
    const segments_start = ip + 2;
    var cur_ip = segments_start;
    for (0..segment_count) |_| {
        const tag = code[cur_ip];
        cur_ip += 1;
        switch (tag) {
            @intFromEnum(bytecode_mod.MixedAttrSegmentTag.static) => cur_ip += 4,
            @intFromEnum(bytecode_mod.MixedAttrSegmentTag.dynamic) => {},
            else => return error.InvalidBytecode,
        }
    }
    // [attrs, dyn0, …, dynN-1] stay on the stack across the (forcing) walk;
    // pass a stack slice for the dynamic names (no heap alloc), drop after.
    const dyn_base = vm.sp - dynamic_count;
    const dynamic_names = vm.stack[dyn_base..vm.sp];
    const attrs_val = vm.stack[dyn_base - 1];
    const r = try access.hasAttrPathMixed(vm, attrs_val, dynamic_names, code[segments_start..cur_ip], segment_count);
    vm.sp -= (1 + dynamic_count);
    try stack.push(vm, Value.boolVal(r));
    return dispatch(vm, frame, code, cur_ip, stop_depth);
}

fn opValidateAttrs(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const allow_extra = code[ip] != 0;
    const expected_count = readU16(code, ip + 1);
    const names_start = ip + 3;
    const names_end = names_start + @as(usize, expected_count) * 2;
    const attrs_val = stack.pop(vm);
    try access.validateAttrs(vm, attrs_val, allow_extra, code[names_start..names_end], false);
    return dispatch(vm, frame, code, names_end, stop_depth);
}

fn opValidateAttrsLong(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const allow_extra = code[ip] != 0;
    const expected_count = readU16(code, ip + 1);
    const names_start = ip + 3;
    const names_end = names_start + @as(usize, expected_count) * 4;
    const attrs_val = stack.pop(vm);
    try access.validateAttrs(vm, attrs_val, allow_extra, code[names_start..names_end], true);
    return dispatch(vm, frame, code, names_end, stop_depth);
}

fn opLookupWith(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const name_id: InternId = @intCast(readU16(code, ip));
    const scope_count = code[ip + 2];
    try access.lookupWith(vm, name_id, scope_count);
    return dispatch(vm, frame, code, ip + 3, stop_depth);
}

fn opLookupWithLong(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const name_id: InternId = readU32(code, ip);
    const scope_count = code[ip + 4];
    try access.lookupWith(vm, name_id, scope_count);
    return dispatch(vm, frame, code, ip + 5, stop_depth);
}

// ---- handlers: termination ----

fn opRet(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    _ = frame;
    _ = code;
    _ = ip;
    const result = stack.pop(vm);
    return retEpilogue(vm, stop_depth, result);
}

fn opConstantRet(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    const idx = readU16(code, ip);
    const result = frame.chunk_ptr.constants[idx];
    return retEpilogue(vm, stop_depth, result);
}

fn opGetLocalRet(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    const slot = code[ip];
    const raw = vm.stack[frame.frame_base + slot];
    const result = try force.forceValue(vm, raw);
    return retEpilogue(vm, stop_depth, result);
}

fn opGetLocalRetLong(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    const slot = readU16(code, ip);
    const raw = vm.stack[frame.frame_base + slot];
    const result = try force.forceValue(vm, raw);
    return retEpilogue(vm, stop_depth, result);
}

fn opGetUpvalueRet(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    const slot = readU16(code, ip);
    const upvalues = frame.upvalues orelse return error.MissingClosure;
    const result = try force.forceValue(vm, upvalues[slot]);
    return retEpilogue(vm, stop_depth, result);
}

fn opGetUpvalueAttr(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const slot = readU16(code, ip);
    const name_id = readU16(code, ip + 2);
    const upvalues = frame.upvalues orelse return error.MissingClosure;
    const result = try access.getAttrValue(vm, upvalues[slot], @intCast(name_id));
    try stack.push(vm, result);
    return dispatch(vm, frame, code, ip + 4, stop_depth);
}

fn opGetLocalAttr(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const slot = code[ip];
    const name_id = readU16(code, ip + 1);
    const result = try access.getAttrValue(vm, vm.stack[frame.frame_base + slot], @intCast(name_id));
    try stack.push(vm, result);
    return dispatch(vm, frame, code, ip + 3, stop_depth);
}

fn opGetLocalAttrLong(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const slot = readU16(code, ip);
    const name_id = readU16(code, ip + 2);
    const result = try access.getAttrValue(vm, vm.stack[frame.frame_base + slot], @intCast(name_id));
    try stack.push(vm, result);
    return dispatch(vm, frame, code, ip + 4, stop_depth);
}

fn opHalt(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    _ = frame;
    _ = code;
    _ = ip;
    _ = stop_depth;
    if (vm.sp == 0) try stack.push(vm, Value.null_val);
}

/// Pop the current frame and either leave the result on the stack
/// for `runUntil` to retrieve (when frames_len has reached
/// `stop_depth`) or push it onto the resumed caller frame and
/// continue dispatching. `inline` so the tail call to `dispatch`
/// lands in the caller (an opRet-like handler) whose signature
/// matches handler sig — required by `@call(.always_tail)`.
inline fn retEpilogue(vm: *VM, stop_depth: usize, result: Value) anyerror!void {
    const finished_frame = stack.popFrame(vm);
    if (comptime trace_log.enabled) {
        if (vm.frames_len == 0) {
            trace_log.framePop(vm.vm_trace, vm.workerId(), vm.frames_len, types.CHUNK_ID_NONE, 0);
        } else {
            const ret_frame = stack.currentFrame(vm);
            trace_log.framePop(vm.vm_trace, vm.workerId(), vm.frames_len, ret_frame.chunk_id, @intCast(ret_frame.ip));
        }
    }
    vm.sp = finished_frame.frame_base;
    try stack.push(vm, result);
    if (vm.frames_len == stop_depth) return;
    const new_frame = stack.currentFrame(vm);
    return dispatch(vm, new_frame, new_frame.chunk_ptr.code, new_frame.ip, stop_depth);
}

// ---- handler table ----

const handlers: [opcode.count]HandlerFn = blk: {
    var table: [opcode.count]HandlerFn = undefined;
    table[@intFromEnum(OpCode.push_const)] = opConstant;
    table[@intFromEnum(OpCode.push_null)] = opPushNull;
    table[@intFromEnum(OpCode.push_true)] = opPushTrue;
    table[@intFromEnum(OpCode.push_false)] = opPushFalse;
    table[@intFromEnum(OpCode.pop)] = opPop;
    table[@intFromEnum(OpCode.loc_get)] = opGetLocal;
    table[@intFromEnum(OpCode.loc_get_w)] = opGetLocalLong;
    table[@intFromEnum(OpCode.loc_grab)] = opCaptureLocal;
    table[@intFromEnum(OpCode.loc_grab_w)] = opCaptureLocalLong;
    table[@intFromEnum(OpCode.up_grab)] = opCaptureUpvalue;
    table[@intFromEnum(OpCode.loc_set)] = opSetLocal;
    table[@intFromEnum(OpCode.loc_set_w)] = opSetLocalLong;
    table[@intFromEnum(OpCode.cell_set)] = opSetCellLocal;
    table[@intFromEnum(OpCode.cell_set_w)] = opSetCellLocalLong;
    table[@intFromEnum(OpCode.up_get)] = opGetUpvalue;
    table[@intFromEnum(OpCode.int_add)] = opAddInt;
    table[@intFromEnum(OpCode.int_sub)] = opSubInt;
    table[@intFromEnum(OpCode.int_mul)] = opMulInt;
    table[@intFromEnum(OpCode.int_div)] = opDivInt;
    table[@intFromEnum(OpCode.int_neg)] = opNegateInt;
    table[@intFromEnum(OpCode.flt_add)] = opAddFloat;
    table[@intFromEnum(OpCode.flt_sub)] = opSubFloat;
    table[@intFromEnum(OpCode.flt_mul)] = opMulFloat;
    table[@intFromEnum(OpCode.flt_div)] = opDivFloat;
    table[@intFromEnum(OpCode.cmp_eq)] = opEq;
    table[@intFromEnum(OpCode.cmp_ne)] = opNeq;
    table[@intFromEnum(OpCode.cmp_eq_null)] = opEqNull;
    table[@intFromEnum(OpCode.cmp_ne_null)] = opNeqNull;
    table[@intFromEnum(OpCode.cmp_lt)] = opLt;
    table[@intFromEnum(OpCode.cmp_le)] = opLte;
    table[@intFromEnum(OpCode.cmp_gt)] = opGt;
    table[@intFromEnum(OpCode.cmp_ge)] = opGte;
    table[@intFromEnum(OpCode.bool_not)] = opNot;
    table[@intFromEnum(OpCode.jump)] = opJump;
    table[@intFromEnum(OpCode.jump_false)] = opJumpIfFalse;
    table[@intFromEnum(OpCode.fail)] = opFailAssertion;
    table[@intFromEnum(OpCode.attrs_new)] = opBuildAttrs;
    table[@intFromEnum(OpCode.attrs_new_pos)] = opBuildAttrsWithPos;
    table[@intFromEnum(OpCode.attrs_new_srt)] = opBuildAttrsSorted;
    table[@intFromEnum(OpCode.attrs_new_pos_srt)] = opBuildAttrsWithPosSorted;
    table[@intFromEnum(OpCode.list_new)] = opBuildList;
    table[@intFromEnum(OpCode.attrs_merge_strict)] = opMergeAttrsStrict;
    table[@intFromEnum(OpCode.attrs_merge)] = opMergeAttrs;
    table[@intFromEnum(OpCode.list_cat)] = opConcatLists;
    table[@intFromEnum(OpCode.str_cat)] = opConcatStrings;
    table[@intFromEnum(OpCode.push_builtins)] = opPushBuiltins;
    table[@intFromEnum(OpCode.file_find)] = opFindFile;
    table[@intFromEnum(OpCode.file_find_w)] = opFindFileLong;
    table[@intFromEnum(OpCode.closure)] = opClosure;
    table[@intFromEnum(OpCode.closure_w)] = opClosureLong;
    table[@intFromEnum(OpCode.closure_cap)] = opClosureCaptures;
    table[@intFromEnum(OpCode.closure_cap_w)] = opClosureCapturesLong;
    table[@intFromEnum(OpCode.thunk_arg)] = opApplyArg;
    table[@intFromEnum(OpCode.thunk)] = opThunkCaptures;
    table[@intFromEnum(OpCode.thunk_w)] = opThunkCapturesLong;
    table[@intFromEnum(OpCode.thunk_eag)] = opThunkCapturesEager;
    table[@intFromEnum(OpCode.thunk_eag_w)] = opThunkCapturesEagerLong;
    table[@intFromEnum(OpCode.thunk_st_cell)] = opThunkCapturesStoreCellLocal;
    table[@intFromEnum(OpCode.thunk_st)] = opThunkCapturesStoreLocal;
    table[@intFromEnum(OpCode.thunk_eag_st_cell)] = opThunkCapturesEagerStoreCellLocal;
    table[@intFromEnum(OpCode.thunk_eag_st)] = opThunkCapturesEagerStoreLocal;
    table[@intFromEnum(OpCode.call)] = opCall;
    table[@intFromEnum(OpCode.call_tail)] = opTailCall;
    table[@intFromEnum(OpCode.call_n)] = opCallN;
    table[@intFromEnum(OpCode.call_tail_n)] = opTailCallN;
    table[@intFromEnum(OpCode.push_const_ret)] = opConstantRet;
    table[@intFromEnum(OpCode.loc_get_ret)] = opGetLocalRet;
    table[@intFromEnum(OpCode.loc_get_ret_w)] = opGetLocalRetLong;
    table[@intFromEnum(OpCode.up_get_ret)] = opGetUpvalueRet;
    table[@intFromEnum(OpCode.up_get_attr)] = opGetUpvalueAttr;
    table[@intFromEnum(OpCode.loc_get_attr)] = opGetLocalAttr;
    table[@intFromEnum(OpCode.loc_get_attr_w)] = opGetLocalAttrLong;
    table[@intFromEnum(OpCode.cell_new)] = opMakeCell;
    table[@intFromEnum(OpCode.thunk_shell)] = opMakeLazyShell;
    table[@intFromEnum(OpCode.cell_init)] = opInitCellSlot;
    table[@intFromEnum(OpCode.cell_init_w)] = opInitCellSlotLong;
    table[@intFromEnum(OpCode.attr_get)] = opGetAttr;
    table[@intFromEnum(OpCode.attr_get_w)] = opGetAttrLong;
    table[@intFromEnum(OpCode.attr_get_dyn)] = opGetAttrDynamic;
    table[@intFromEnum(OpCode.attr_get_dyn_or)] = opGetAttrDynamicOr;
    table[@intFromEnum(OpCode.attr_get_path_dyn_or)] = opGetAttrPathDynamicOr;
    table[@intFromEnum(OpCode.attr_get_path_dyn_or_w)] = opGetAttrPathDynamicOrLong;
    table[@intFromEnum(OpCode.attr_get_path_or)] = opGetAttrPathOr;
    table[@intFromEnum(OpCode.attr_get_path_or_w)] = opGetAttrPathOrLong;
    table[@intFromEnum(OpCode.attr_get_path_mix_or)] = opGetAttrPathMixedOr;
    table[@intFromEnum(OpCode.attr_has_path)] = opHasAttrPath;
    table[@intFromEnum(OpCode.attr_has_path_w)] = opHasAttrPathLong;
    table[@intFromEnum(OpCode.attr_has_path_mix)] = opHasAttrPathMixed;
    table[@intFromEnum(OpCode.attr_check)] = opValidateAttrs;
    table[@intFromEnum(OpCode.attr_check_w)] = opValidateAttrsLong;
    table[@intFromEnum(OpCode.with_lookup)] = opLookupWith;
    table[@intFromEnum(OpCode.with_lookup_w)] = opLookupWithLong;
    table[@intFromEnum(OpCode.thunk_defer)] = opDeferAttrValue;
    table[@intFromEnum(OpCode.ret)] = opRet;
    table[@intFromEnum(OpCode.halt)] = opHalt;
    break :blk table;
};

// ---- helpers ----

pub fn expectBool(self: *VM, val: Value) !bool {
    const forced = try force.forceValue(self, val);
    return switch (forced.kind()) {
        .bool_false => false,
        .bool_true => true,
        else => error.TypeError,
    };
}
