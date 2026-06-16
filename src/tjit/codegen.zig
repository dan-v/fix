//! Native x86-64 codegen for the tracing JIT (`-Dtjit`).
//!
//! Lowers a recorded+optimized trace IR to a `LambdaCompiledFn`
//! (`fn(vm, upvalues_ptr, arg) -> JitResult`), reusing the proven
//! `jit_linear.Emitter` (stack-slot model, C-ABI helper calls, error/epilogue
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
const jit = @import("../jit.zig");
const helpers = @import("jit_helpers.zig");
const Emitter = @import("../jit_linear.zig").Emitter;
const Value = @import("../runtime/value.zig").Value;

const CodeBuffer = jit.CodeBuffer;
const GuardKind = ir.GuardKind;

/// Slot 8 bytes; cap the trace so the emitter's fixed code buffer + the
/// reserved native-stack frame stay bounded (bigger traces use exec.zig).
const MAX_INSTRS: usize = 400;

fn supported(trace: *const ir.Trace) bool {
    for (trace.instrs.items) |instr| {
        switch (instr.op) {
            .nop, .const_val, .load_upvalue, .load_upvalue_of, .trace_arg, .force, .add_int, .sub_int, .mul_int, .get_attr, .ret => {},
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
            else => return null,
        }
        if (e.overflow) return null;
    }

    e.bindEpilogue(reserve);
    if (e.overflow) return null;
    return @ptrCast(@alignCast(buf.append(e.buf[0..e.len]) orelse return null));
}
