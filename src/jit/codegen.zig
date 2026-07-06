//! Native x86-64 codegen for the tracing JIT (`-Dtjit`).
//!
//! Lowers a recorded+optimized trace IR to a `LambdaCompiledFn`
//! (`fn(vm, upvalues_ptr, arg) -> JitResult`), reusing the proven
//! shared `emit.Emitter` (stack-slot model, C-ABI helper calls, error/epilogue
//! patching) and the C-ABI op helpers in `jit_helpers.zig`. Each SSA `Ref` is
//! given one native-stack slot (`Ref i` → `[rsp + i*8]`); ops load operands
//! from slots and store results to their own. Guards and errors funnel through
//! the shared epilogue carrying `JitResult.error_code`; `exec.tryRun`
//! distinguishes value / error / deopt (`DEOPT_CODE`).
//!
//! Coverage is intentionally a subset (arithmetic, attr read, inlined-call
//! guards + upvalue reads). Any unsupported op → return null → the trace stays
//! on the `exec.zig` interpreter (still byte-identical, just not native).
//! `exec.zig` is the correctness oracle this is diffed against.

const std = @import("std");
const ir = @import("ir.zig");
const jit = @import("native.zig");
const helpers = @import("jit_helpers.zig");
const Emitter = @import("emit.zig").Emitter;
const Value = @import("runtime").value.Value;

const CodeBuffer = jit.CodeBuffer;
const GuardKind = ir.GuardKind;

/// Slot 8 bytes; cap the trace so the emitter's fixed code buffer + the
/// reserved native-stack frame stay bounded (bigger traces use exec.zig).
const MAX_INSTRS: usize = 400;

fn supported(trace: *const ir.Trace) bool {
    for (trace.instrs.items) |instr| {
        switch (instr.op) {
            .nop, .const_val, .load_upvalue, .load_upvalue_of, .trace_arg, .force, .add_int, .sub_int, .mul_int, .get_attr, .ret, .side_exit => {},
            .guard => switch (@as(GuardKind, @enumFromInt(@as(u8, @intCast(instr.aux))))) {
                .attr_shape, .chunk_id, .bool_is => {},
                else => return false,
            },
            else => return false, // eq/lt/not/alloc/… → exec.zig
        }
    }
    return true;
}

/// Compile `trace`, or null to fall back to `exec.zig`.
pub fn compile(buf: *CodeBuffer, trace: *const ir.Trace) ?*const anyopaque {
    if (comptime !jit.code_enabled) return null;
    const instrs = trace.instrs.items;
    const n = instrs.len;
    if (n == 0 or n > MAX_INSTRS) return null;
    if (!supported(trace)) return null;

    const reserve: u32 = std.mem.alignForward(u32, @as(u32, @intCast(n)) * 8, 16);
    var e: Emitter = .{};
    e.prologue(reserve);

    for (instrs, 0..) |instr, idx| {
        const i: u32 = @intCast(idx);
        switch (instr.op) {
            .nop => {},
            .const_val => {
                e.movRaxImm64(@bitCast(trace.consts.items[instr.aux]));
                e.storeRaxToStack(i);
            },
            .load_upvalue => {
                e.loadUpvalueToRax(instr.aux);
                e.storeRaxToStack(i);
            },
            .trace_arg => e.storeR15ToStack(i), // r15 = arg (set by prologue)
            .add_int, .sub_int, .mul_int => {
                e.loadStackToRsi(instr.a);
                e.loadStackToRdx(instr.b);
                e.movRdiRbx();
                e.callHelper(@intFromPtr(switch (instr.op) {
                    .add_int => &helpers.tjitAdd,
                    .sub_int => &helpers.tjitSub,
                    else => &helpers.tjitMul,
                }));
                e.errCheckToEpilogue();
                e.storeRaxToStack(i);
            },
            .get_attr => {
                e.loadStackToRsi(instr.a);
                e.movEdxImm32(instr.aux); // name InternId
                e.movRdiRbx();
                e.callHelper(@intFromPtr(&helpers.tjitGetAttr));
                e.errCheckToEpilogue();
                e.storeRaxToStack(i);
            },
            .force => {
                e.loadStackToRsi(instr.a);
                e.movRdiRbx();
                e.callHelper(@intFromPtr(&helpers.tjitForce));
                e.errCheckToEpilogue();
                e.storeRaxToStack(i);
            },
            .load_upvalue_of => {
                e.loadStackToRsi(instr.a); // the closure Ref
                e.movEdxImm32(instr.aux); // slot
                e.movRdiRbx();
                e.callHelper(@intFromPtr(&helpers.tjitLoadUpvalueOf));
                e.errCheckToEpilogue();
                e.storeRaxToStack(i);
            },
            .guard => switch (@as(GuardKind, @enumFromInt(@as(u8, @intCast(instr.aux))))) {
                .attr_shape => {
                    e.loadStackToRsi(instr.a); // the attrs Ref
                    e.movEdxImm32(instr.aux2); // expected attr name
                    e.movRdiRbx();
                    e.callHelper(@intFromPtr(&helpers.tjitGuardAttrShape));
                    e.errCheckToEpilogue(); // deopt (missing/non-attrs) or error → epilogue
                },
                .chunk_id => {
                    e.loadStackToRsi(instr.a); // the func Ref
                    e.movEdxImm32(instr.aux2); // expected chunk id
                    e.movRdiRbx();
                    e.callHelper(@intFromPtr(&helpers.tjitGuardChunkId));
                    e.errCheckToEpilogue(); // deopt or error → epilogue
                },
                .bool_is => {
                    e.loadStackToRsi(instr.a); // the condition Ref
                    e.movEdxImm32(instr.aux2); // expected bool (1/0)
                    e.movRdiRbx();
                    e.callHelper(@intFromPtr(&helpers.tjitGuardBool));
                    e.errCheckToEpilogue();
                },
                else => return null,
            },
            .ret => {
                e.loadStackToRax(instr.a);
                e.xorEdxEdx();
                e.jmpEpilogue();
            },
            .side_exit => {
                // Hand the snapshot + the live slot array (rsp) to the helper,
                // which reconstructs the frame and resumes interpreting. On
                // success rax=value/rdx=0; deopt/error → nonzero rdx → epilogue.
                e.movRdiRbx(); // vm
                e.movRsiImm64(@intFromPtr(&trace.snapshots.items[instr.snapshot])); // snapshot
                e.movRdxRsp(); // slots base
                e.callHelper(@intFromPtr(&helpers.tjitSideExit));
                e.errCheckToEpilogue(); // nonzero error_code (deopt/error) → epilogue
                e.jmpEpilogue(); // success: rax=value, rdx=0
            },
            else => return null,
        }
        if (e.overflow) return null;
    }

    e.bindEpilogue(reserve);
    if (e.overflow) return null;
    return @ptrCast(@alignCast(buf.append(e.buf[0..e.len]) orelse return null));
}

test "codegen: empty trace is rejected" {
    if (!jit.code_enabled) return error.SkipZigTest;
    var trace = ir.Trace.init(1, true);
    defer trace.deinit(std.testing.allocator);
    var buf = try CodeBuffer.init(4096);
    defer buf.deinit();
    try std.testing.expectEqual(@as(?*const anyopaque, null), compile(&buf, &trace));
}

test "codegen: an unmodeled op (eq) is rejected" {
    if (!jit.code_enabled) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var trace = ir.Trace.init(1, true);
    defer trace.deinit(allocator);
    const a = try trace.emit(allocator, .{ .op = .trace_arg });
    const eq = try trace.emit(allocator, .{ .op = .eq, .a = a, .b = a });
    _ = try trace.emit(allocator, .{ .op = .ret, .a = eq });

    var buf = try CodeBuffer.init(4096);
    defer buf.deinit();
    try std.testing.expectEqual(@as(?*const anyopaque, null), compile(&buf, &trace));
}

test "codegen: a guard with an unsupported kind is rejected" {
    if (!jit.code_enabled) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var trace = ir.Trace.init(1, true);
    defer trace.deinit(allocator);
    const a = try trace.emit(allocator, .{ .op = .trace_arg });
    // thunk_resolved isn't one of the codegen-supported guard kinds.
    _ = try trace.emit(allocator, .{ .op = .guard, .a = a, .aux = @intFromEnum(GuardKind.thunk_resolved) });
    _ = try trace.emit(allocator, .{ .op = .ret, .a = a });

    var buf = try CodeBuffer.init(4096);
    defer buf.deinit();
    try std.testing.expectEqual(@as(?*const anyopaque, null), compile(&buf, &trace));
}

test "codegen: const_val + ret compiles and executes to the constant" {
    if (!jit.code_enabled) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var trace = ir.Trace.init(1, true);
    defer trace.deinit(allocator);
    const cidx = try trace.addConst(allocator, Value.int(11));
    const c = try trace.emit(allocator, .{ .op = .const_val, .aux = cidx });
    _ = try trace.emit(allocator, .{ .op = .ret, .a = c });

    var buf = try CodeBuffer.init(4096);
    defer buf.deinit();
    const raw = compile(&buf, &trace) orelse return error.CodegenFailed;
    const fn_ptr: jit.LambdaCompiledFn = @ptrCast(@alignCast(raw));
    // const_val + ret never touch vm/upvalues — safe to call with dummy args.
    const result = fn_ptr(undefined, undefined, Value.null_val);
    try std.testing.expectEqual(@as(u64, 0), result.error_code);
    try std.testing.expectEqual(@as(i64, 11), result.value.asInt());
}

test "codegen: trace_arg + ret echoes the passed-in argument" {
    if (!jit.code_enabled) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var trace = ir.Trace.init(1, true);
    defer trace.deinit(allocator);
    const a = try trace.emit(allocator, .{ .op = .trace_arg });
    _ = try trace.emit(allocator, .{ .op = .ret, .a = a });

    var buf = try CodeBuffer.init(4096);
    defer buf.deinit();
    const raw = compile(&buf, &trace) orelse return error.CodegenFailed;
    const fn_ptr: jit.LambdaCompiledFn = @ptrCast(@alignCast(raw));
    const result = fn_ptr(undefined, undefined, Value.int(5));
    try std.testing.expectEqual(@as(u64, 0), result.error_code);
    try std.testing.expectEqual(@as(i64, 5), result.value.asInt());
}

test "codegen: a trace longer than MAX_INSTRS is rejected" {
    if (!jit.code_enabled) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var trace = ir.Trace.init(1, true);
    defer trace.deinit(allocator);
    var last: ir.Ref = try trace.emit(allocator, .{ .op = .trace_arg });
    var i: usize = 0;
    while (i < MAX_INSTRS + 1) : (i += 1) {
        last = try trace.emit(allocator, .{ .op = .force, .a = last });
    }
    _ = try trace.emit(allocator, .{ .op = .ret, .a = last });

    var buf = try CodeBuffer.init(1 << 20);
    defer buf.deinit();
    try std.testing.expectEqual(@as(?*const anyopaque, null), compile(&buf, &trace));
}
