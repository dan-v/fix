//! Trace executor for the tracing JIT (`-Dtjit`).
//!
//! Runs a recorded+optimized `Trace` directly (in Zig — native codegen lowers
//! this later). It is the **correctness gate** for the whole front end: if the
//! recording / inlining / guards / optimizer are right, executing the trace
//! produces a byte-identical result to interpreting the chunk; if anything is
//! wrong, the `.drv` mismatches immediately. So this de-risks the
//! correctness-critical path in debuggable Zig before any assembly.
//!
//! Each op calls the *same* helper the interpreter's opcode handler calls, so
//! semantics (forcing, overflow, path/string `+`, Nix equality) are bit-exact.
//! A guard that fails — or any op we don't model — returns `null`: a
//! **deopt**, after which the caller interprets the chunk normally. Deopt is
//! always safe here: the only effects the trace performs are thunk forces
//! (memoized → idempotent) and attr reads (pure), so partial execution before
//! a side-exit never double-applies an effect.

const std = @import("std");
const ir = @import("ir.zig");
const vm_mod = @import("../vm.zig");
const Value = @import("../runtime/value.zig").Value;
const force = @import("../vm/force.zig");
const access = @import("../vm/access.zig");
const equality = @import("../vm/equality.zig");
const numeric = @import("../runtime/numeric.zig");
const strings = @import("../vm/strings.zig");

const VM = vm_mod.VM;
const GuardKind = ir.GuardKind;
const ChunkId = @import("../runtime/types.zig").ChunkId;
const jit = @import("../jit.zig");
const helpers = @import("jit_helpers.zig");

pub const enabled: bool = @import("build_options").tjit;

var native_count: std.atomic.Value(u64) = .{ .raw = 0 };
var exec_count: std.atomic.Value(u64) = .{ .raw = 0 };
var deopt_count: std.atomic.Value(u64) = .{ .raw = 0 };

pub fn report() void {
    if (comptime !enabled) return;
    const nat = native_count.load(.monotonic);
    const e = exec_count.load(.monotonic);
    const d = deopt_count.load(.monotonic);
    std.debug.print("=== tjit exec: {d} native runs, {d} interpreted runs, {d} side-exits (deopts) ===\n", .{ nat, e, d });
}

/// Entry point for the interpreter's execution hooks: if chunk `chunk_id` has
/// an installed trace and we're not currently recording, run it. Returns the
/// trace result, or `null` to fall back to interpreting the chunk (no trace,
/// recording in progress, or a guard side-exit). Errors propagate.
pub fn tryRun(vm: *VM, chunk_id: ChunkId, upvalues: []const Value, arg: Value) anyerror!?Value {
    if (vm.tjit_rec != null) return null; // don't execute a trace mid-recording
    const h = vm.registry.hot orelse return null;
    // Native-compiled trace takes priority over the exec.zig interpreter.
    const nbits = h.nativeOf(chunk_id);
    if (nbits != 0) {
        const native: jit.LambdaCompiledFn = @ptrFromInt(nbits);
        const r = native(@ptrCast(vm), upvalues.ptr, arg);
        if (r.error_code == 0) {
            _ = native_count.fetchAdd(1, .monotonic);
            return r.value;
        }
        if (r.error_code == helpers.DEOPT_CODE) {
            _ = deopt_count.fetchAdd(1, .monotonic);
            return null; // side-exit → caller interprets
        }
        return @errorFromInt(@as(std.meta.Int(.unsigned, @bitSizeOf(anyerror)), @intCast(r.error_code)));
    }
    const bits = h.traceOf(chunk_id);
    if (bits == 0) return null;
    const trace: *const ir.Trace = @ptrFromInt(bits);
    const result = try execute(vm, trace, upvalues, arg);
    if (result != null) {
        _ = exec_count.fetchAdd(1, .monotonic);
    } else {
        _ = deopt_count.fetchAdd(1, .monotonic);
    }
    return result;
}

/// Execute `trace`. Returns its result, or `null` to deopt (caller should
/// interpret the chunk normally). Errors are real eval errors and propagate
/// exactly as the interpreter would raise them.
pub fn execute(vm: *VM, trace: *const ir.Trace, upvalues: []const Value, arg: Value) anyerror!?Value {
    const instrs = trace.instrs.items;
    const vals = try vm.allocator.alloc(Value, instrs.len);
    defer vm.allocator.free(vals);

    for (instrs, 0..) |instr, i| {
        switch (instr.op) {
            .nop => {},
            .const_val => vals[i] = trace.consts.items[instr.aux],
            .load_upvalue => {
                if (instr.aux >= upvalues.len) return null;
                vals[i] = upvalues[instr.aux];
            },
            .load_upvalue_of => {
                const c = try force.forceValue(vm, vals[instr.a]);
                if (!c.isClosure()) return null;
                const cl = vm.heap.getClosure(c.asObjectId()) catch return null;
                if (instr.aux >= cl.upvalues.len) return null;
                vals[i] = cl.upvalues[instr.aux];
            },
            .trace_arg => vals[i] = arg,
            .add_int => {
                // Matches opAddInt: generic `+` over numbers / paths / strings.
                const a = try force.forceValue(vm, vals[instr.a]);
                const b = try force.forceValue(vm, vals[instr.b]);
                if (numeric.isNumeric(a) and numeric.isNumeric(b)) {
                    vals[i] = try numeric.add(vm.heap, a, b);
                } else if (a.isPath()) {
                    vals[i] = try strings.concatPathLike(vm, a, b);
                } else {
                    vals[i] = try strings.concatStringLike(vm, a, b);
                }
            },
            .sub_int => {
                const a = try force.forceValue(vm, vals[instr.a]);
                const b = try force.forceValue(vm, vals[instr.b]);
                vals[i] = try numeric.sub(vm.heap, a, b);
            },
            .mul_int => {
                const a = try force.forceValue(vm, vals[instr.a]);
                const b = try force.forceValue(vm, vals[instr.b]);
                vals[i] = try numeric.mul(vm.heap, a, b);
            },
            .eq => vals[i] = Value.boolVal(try equality.valuesEqual(vm, vals[instr.a], vals[instr.b])),
            .lt => vals[i] = Value.boolVal(try equality.compareValues(vm, vals[instr.a], vals[instr.b]) == .lt),
            .not => {
                const a = try force.forceValue(vm, vals[instr.a]);
                if (!a.isBool()) return null;
                vals[i] = Value.boolVal(!a.asBool());
            },
            .get_attr => {
                const attrs = try force.forceValue(vm, vals[instr.a]);
                vals[i] = try access.getAttrValue(vm, attrs, @intCast(instr.aux));
            },
            .guard => switch (@as(GuardKind, @enumFromInt(@as(u8, @intCast(instr.aux))))) {
                // The attr lookup itself (get_attr) does the real work and
                // raises identically on a missing attr, so the shape guard is
                // a no-op here (it exists for a future fast direct-slot load).
                .attr_shape => {},
                .chunk_id => {
                    const c = try force.forceValue(vm, vals[instr.a]);
                    if (!c.isClosure()) return null;
                    const cl = vm.heap.getClosure(c.asObjectId()) catch return null;
                    if (cl.chunk_id != instr.aux2) return null;
                },
                else => return null,
            },
            .ret => return vals[instr.a],
            // Allocations / calls-as-nodes / unmodeled ops: deopt.
            else => return null,
        }
    }
    return null; // fell off the end without a ret
}
