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
const types = @import("../runtime/types.zig");
const Value = @import("../runtime/value.zig").Value;
const InternId = types.InternId;
const ChunkId = types.ChunkId;
const bytecode_mod = @import("../bytecode.zig");
const opcode = bytecode_mod.opcode;
const OpCode = opcode.OpCode;
const heap_mod = @import("../runtime/heap.zig");
const numeric = @import("../runtime/numeric.zig");

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
    const val = try force.forceValue(vm, raw);
    try stack.push(vm, val);
    return dispatch(vm, frame, code, ip + 1, stop_depth);
}

fn opGetLocalLong(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const slot = readU16(code, ip);
    const raw = vm.stack[frame.frame_base + slot];
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
    return dispatch(vm, frame, code, ip + 2, stop_depth);
}

fn opGetUpvalue(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const slot = readU16(code, ip);
    const upvalues = frame.upvalues orelse return error.MissingClosure;
    const val = try force.forceValue(vm, upvalues[slot]);
    try stack.push(vm, val);
    return dispatch(vm, frame, code, ip + 2, stop_depth);
}

// ---- handlers: integer arithmetic ----

fn opAddInt(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const b = try force.forceValue(vm, stack.pop(vm));
    const a = try force.forceValue(vm, stack.pop(vm));
    if (numeric.isNumeric(a) and numeric.isNumeric(b)) {
        try stack.push(vm, try numeric.add(vm.heap, a, b));
    } else if (a.isPath()) {
        try stack.push(vm, try strings.concatPathLike(vm, a, b));
    } else {
        try stack.push(vm, try strings.concatStringLike(vm, a, b));
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
    const b = stack.pop(vm);
    const a = stack.pop(vm);
    try stack.push(vm, Value.boolVal(try equality.valuesEqual(vm, a, b)));
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opNeq(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const b = stack.pop(vm);
    const a = stack.pop(vm);
    try stack.push(vm, Value.boolVal(!try equality.valuesEqual(vm, a, b)));
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opLt(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const b = stack.pop(vm);
    const a = stack.pop(vm);
    try stack.push(vm, Value.boolVal(try equality.compareValues(vm, a, b) == .lt));
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opLte(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const b = stack.pop(vm);
    const a = stack.pop(vm);
    const r = try equality.compareValues(vm, a, b);
    try stack.push(vm, Value.boolVal(r == .lt or r == .eq));
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opGt(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const b = stack.pop(vm);
    const a = stack.pop(vm);
    try stack.push(vm, Value.boolVal(try equality.compareValues(vm, a, b) == .gt));
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opGte(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const b = stack.pop(vm);
    const a = stack.pop(vm);
    const r = try equality.compareValues(vm, a, b);
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
    const right = stack.pop(vm);
    const left = stack.pop(vm);
    try stack.push(vm, try objects.mergeAttrs(vm, left, right));
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opMergeAttrsStrict(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const right = stack.pop(vm);
    const left = stack.pop(vm);
    try stack.push(vm, try objects.mergeAttrsStrict(vm, left, right));
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opConcatLists(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const right = stack.pop(vm);
    const left = stack.pop(vm);
    try stack.push(vm, try objects.concatLists(vm, left, right));
    return dispatch(vm, frame, code, ip, stop_depth);
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

// ---- handlers: thunks ----

fn opMakeCell(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const val = stack.pop(vm);
    try stack.push(vm, try force.makeCell(vm, val));
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
    const attrs_val = stack.pop(vm);
    const result = try access.getAttrValue(vm, attrs_val, @intCast(name_id));
    try stack.push(vm, result);
    return dispatch(vm, frame, code, ip + 2, stop_depth);
}

fn opGetAttrLong(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const name_id: InternId = readU32(code, ip);
    const attrs_val = stack.pop(vm);
    const result = try access.getAttrValue(vm, attrs_val, name_id);
    try stack.push(vm, result);
    return dispatch(vm, frame, code, ip + 4, stop_depth);
}

fn opGetAttrDynamic(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const name_val = try force.forceValue(vm, stack.pop(vm));
    if (!name_val.isString()) return error.TypeError;
    const attrs_val = stack.pop(vm);
    const result = try access.getAttrValue(vm, attrs_val, name_val.asInternId());
    try stack.push(vm, result);
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opGetAttrDynamicOr(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const default_val = stack.pop(vm);
    const name_val = try force.forceValue(vm, stack.pop(vm));
    if (!name_val.isString()) return error.TypeError;
    const attrs_val = stack.pop(vm);
    const attrs = try force.forceValue(vm, attrs_val);
    if (!attrs.isAttrs()) {
        try stack.push(vm, try force.forceValue(vm, default_val));
    } else {
        const result = vm.heap.getAttrValue(attrs.asObjectId(), name_val.asInternId()) catch |err| switch (err) {
            error.MissingAttribute => try force.forceValue(vm, default_val),
            else => return err,
        };
        try stack.push(vm, try force.forceValue(vm, result));
    }
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opGetAttrPathDynamicOr(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const segment_count = code[ip];
    const names_start = ip + 1;
    const names_end = names_start + @as(usize, segment_count) * 2;
    const default_val = stack.pop(vm);
    const name_val = stack.pop(vm);
    const attrs_val = stack.pop(vm);
    const result = try access.getAttrPathDynamicOrValue(vm, attrs_val, name_val, default_val, code[names_start..names_end], false);
    try stack.push(vm, result);
    return dispatch(vm, frame, code, names_end, stop_depth);
}

fn opGetAttrPathDynamicOrLong(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const segment_count = code[ip];
    const names_start = ip + 1;
    const names_end = names_start + @as(usize, segment_count) * 4;
    const default_val = stack.pop(vm);
    const name_val = stack.pop(vm);
    const attrs_val = stack.pop(vm);
    const result = try access.getAttrPathDynamicOrValue(vm, attrs_val, name_val, default_val, code[names_start..names_end], true);
    try stack.push(vm, result);
    return dispatch(vm, frame, code, names_end, stop_depth);
}

fn opGetAttrPathOr(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const segment_count = code[ip];
    const names_start = ip + 1;
    const names_end = names_start + @as(usize, segment_count) * 2;
    const default_val = stack.pop(vm);
    const attrs_val = stack.pop(vm);
    const result = try access.getAttrPathOrValue(vm, attrs_val, default_val, code[names_start..names_end], false);
    try stack.push(vm, result);
    return dispatch(vm, frame, code, names_end, stop_depth);
}

fn opGetAttrPathOrLong(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const segment_count = code[ip];
    const names_start = ip + 1;
    const names_end = names_start + @as(usize, segment_count) * 4;
    const default_val = stack.pop(vm);
    const attrs_val = stack.pop(vm);
    const result = try access.getAttrPathOrValue(vm, attrs_val, default_val, code[names_start..names_end], true);
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
    const default_val = stack.pop(vm);
    const dynamic_names = try vm.allocator.alloc(Value, dynamic_count);
    defer vm.allocator.free(dynamic_names);
    var dynamic_i: usize = dynamic_count;
    while (dynamic_i > 0) {
        dynamic_i -= 1;
        dynamic_names[dynamic_i] = stack.pop(vm);
    }
    const attrs_val = stack.pop(vm);
    const result = try access.getAttrPathMixedOrValue(vm, attrs_val, dynamic_names, default_val, code[segments_start..cur_ip], segment_count);
    try stack.push(vm, result);
    return dispatch(vm, frame, code, cur_ip, stop_depth);
}

fn opHasAttrPath(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const segment_count = code[ip];
    const names_start = ip + 1;
    const names_end = names_start + @as(usize, segment_count) * 2;
    const attrs_val = stack.pop(vm);
    try stack.push(vm, Value.boolVal(try access.hasAttrPath(vm, attrs_val, code[names_start..names_end], false)));
    return dispatch(vm, frame, code, names_end, stop_depth);
}

fn opHasAttrPathLong(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const segment_count = code[ip];
    const names_start = ip + 1;
    const names_end = names_start + @as(usize, segment_count) * 4;
    const attrs_val = stack.pop(vm);
    try stack.push(vm, Value.boolVal(try access.hasAttrPath(vm, attrs_val, code[names_start..names_end], true)));
    return dispatch(vm, frame, code, names_end, stop_depth);
}

fn opHasAttrDynamic(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const name_val = try force.forceValue(vm, stack.pop(vm));
    if (!name_val.isString()) return error.TypeError;
    const attrs_val = try force.forceValue(vm, stack.pop(vm));
    if (!attrs_val.isAttrs()) {
        try stack.push(vm, Value.boolVal(false));
    } else {
        const present = if (vm.heap.getAttrValue(attrs_val.asObjectId(), name_val.asInternId())) |_|
            true
        else |err| switch (err) {
            error.MissingAttribute => false,
            else => return err,
        };
        try stack.push(vm, Value.boolVal(present));
    }
    return dispatch(vm, frame, code, ip, stop_depth);
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
    const dynamic_names = try vm.allocator.alloc(Value, dynamic_count);
    defer vm.allocator.free(dynamic_names);
    var dynamic_i: usize = dynamic_count;
    while (dynamic_i > 0) {
        dynamic_i -= 1;
        dynamic_names[dynamic_i] = stack.pop(vm);
    }
    const attrs_val = stack.pop(vm);
    try stack.push(vm, Value.boolVal(try access.hasAttrPathMixed(vm, attrs_val, dynamic_names, code[segments_start..cur_ip], segment_count)));
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
    table[@intFromEnum(OpCode.constant)] = opConstant;
    table[@intFromEnum(OpCode.push_null)] = opPushNull;
    table[@intFromEnum(OpCode.push_true)] = opPushTrue;
    table[@intFromEnum(OpCode.push_false)] = opPushFalse;
    table[@intFromEnum(OpCode.pop)] = opPop;
    table[@intFromEnum(OpCode.get_local)] = opGetLocal;
    table[@intFromEnum(OpCode.get_local_long)] = opGetLocalLong;
    table[@intFromEnum(OpCode.capture_local)] = opCaptureLocal;
    table[@intFromEnum(OpCode.capture_local_long)] = opCaptureLocalLong;
    table[@intFromEnum(OpCode.capture_upvalue)] = opCaptureUpvalue;
    table[@intFromEnum(OpCode.set_local)] = opSetLocal;
    table[@intFromEnum(OpCode.set_local_long)] = opSetLocalLong;
    table[@intFromEnum(OpCode.set_cell_local)] = opSetCellLocal;
    table[@intFromEnum(OpCode.set_cell_local_long)] = opSetCellLocalLong;
    table[@intFromEnum(OpCode.get_upvalue)] = opGetUpvalue;
    table[@intFromEnum(OpCode.add_int)] = opAddInt;
    table[@intFromEnum(OpCode.sub_int)] = opSubInt;
    table[@intFromEnum(OpCode.mul_int)] = opMulInt;
    table[@intFromEnum(OpCode.div_int)] = opDivInt;
    table[@intFromEnum(OpCode.negate_int)] = opNegateInt;
    table[@intFromEnum(OpCode.add_float)] = opAddFloat;
    table[@intFromEnum(OpCode.sub_float)] = opSubFloat;
    table[@intFromEnum(OpCode.mul_float)] = opMulFloat;
    table[@intFromEnum(OpCode.div_float)] = opDivFloat;
    table[@intFromEnum(OpCode.eq)] = opEq;
    table[@intFromEnum(OpCode.neq)] = opNeq;
    table[@intFromEnum(OpCode.lt)] = opLt;
    table[@intFromEnum(OpCode.lte)] = opLte;
    table[@intFromEnum(OpCode.gt)] = opGt;
    table[@intFromEnum(OpCode.gte)] = opGte;
    table[@intFromEnum(OpCode.not)] = opNot;
    table[@intFromEnum(OpCode.jump)] = opJump;
    table[@intFromEnum(OpCode.jump_if_false)] = opJumpIfFalse;
    table[@intFromEnum(OpCode.fail_assertion)] = opFailAssertion;
    table[@intFromEnum(OpCode.build_attrs)] = opBuildAttrs;
    table[@intFromEnum(OpCode.build_attrs_with_pos)] = opBuildAttrsWithPos;
    table[@intFromEnum(OpCode.build_list)] = opBuildList;
    table[@intFromEnum(OpCode.merge_attrs_strict)] = opMergeAttrsStrict;
    table[@intFromEnum(OpCode.merge_attrs)] = opMergeAttrs;
    table[@intFromEnum(OpCode.concat_lists)] = opConcatLists;
    table[@intFromEnum(OpCode.push_builtins)] = opPushBuiltins;
    table[@intFromEnum(OpCode.find_file)] = opFindFile;
    table[@intFromEnum(OpCode.find_file_long)] = opFindFileLong;
    table[@intFromEnum(OpCode.closure)] = opClosure;
    table[@intFromEnum(OpCode.closure_long)] = opClosureLong;
    table[@intFromEnum(OpCode.closure_captures)] = opClosureCaptures;
    table[@intFromEnum(OpCode.closure_captures_long)] = opClosureCapturesLong;
    table[@intFromEnum(OpCode.thunk_captures)] = opThunkCaptures;
    table[@intFromEnum(OpCode.thunk_captures_long)] = opThunkCapturesLong;
    table[@intFromEnum(OpCode.call)] = opCall;
    table[@intFromEnum(OpCode.tail_call)] = opTailCall;
    table[@intFromEnum(OpCode.constant_ret)] = opConstantRet;
    table[@intFromEnum(OpCode.get_local_ret)] = opGetLocalRet;
    table[@intFromEnum(OpCode.get_local_ret_long)] = opGetLocalRetLong;
    table[@intFromEnum(OpCode.get_upvalue_ret)] = opGetUpvalueRet;
    table[@intFromEnum(OpCode.make_cell)] = opMakeCell;
    table[@intFromEnum(OpCode.init_cell_slot)] = opInitCellSlot;
    table[@intFromEnum(OpCode.init_cell_slot_long)] = opInitCellSlotLong;
    table[@intFromEnum(OpCode.get_attr)] = opGetAttr;
    table[@intFromEnum(OpCode.get_attr_long)] = opGetAttrLong;
    table[@intFromEnum(OpCode.get_attr_dynamic)] = opGetAttrDynamic;
    table[@intFromEnum(OpCode.get_attr_dynamic_or)] = opGetAttrDynamicOr;
    table[@intFromEnum(OpCode.get_attr_path_dynamic_or)] = opGetAttrPathDynamicOr;
    table[@intFromEnum(OpCode.get_attr_path_dynamic_or_long)] = opGetAttrPathDynamicOrLong;
    table[@intFromEnum(OpCode.get_attr_path_or)] = opGetAttrPathOr;
    table[@intFromEnum(OpCode.get_attr_path_or_long)] = opGetAttrPathOrLong;
    table[@intFromEnum(OpCode.get_attr_path_mixed_or)] = opGetAttrPathMixedOr;
    table[@intFromEnum(OpCode.has_attr_path)] = opHasAttrPath;
    table[@intFromEnum(OpCode.has_attr_path_long)] = opHasAttrPathLong;
    table[@intFromEnum(OpCode.has_attr_dynamic)] = opHasAttrDynamic;
    table[@intFromEnum(OpCode.has_attr_path_mixed)] = opHasAttrPathMixed;
    table[@intFromEnum(OpCode.validate_attrs)] = opValidateAttrs;
    table[@intFromEnum(OpCode.validate_attrs_long)] = opValidateAttrsLong;
    table[@intFromEnum(OpCode.lookup_with)] = opLookupWith;
    table[@intFromEnum(OpCode.lookup_with_long)] = opLookupWithLong;
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
