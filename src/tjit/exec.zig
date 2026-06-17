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

/// Mirror of the recorder's capture cap (record.zig MAX_THUNK_CAPTURES).
const MAX_ALLOC_CAPTURES = 64;

/// Captured upvalues of a (claimed, not-yet-resolved) bytecode thunk — for an
/// inlined thunk body's `load_upvalue_of`. Null if it isn't a bytecode thunk.
fn bytecodeThunkUpvalues(vm: *VM, thunk_val: Value) ?[]const Value {
    const thunk = vm.heap.getThunkAssumeValid(thunk_val.asObjectId());
    const thunk_mod = @import("../runtime/thunk.zig");
    if (thunk.targetKind() != thunk_mod.TargetKind.bytecode) return null;
    return thunk.payload.target.bytecode.upvalues();
}

var native_count: std.atomic.Value(u64) = .{ .raw = 0 };
var exec_count: std.atomic.Value(u64) = .{ .raw = 0 };
var deopt_count: std.atomic.Value(u64) = .{ .raw = 0 };
var err_deopt_count: std.atomic.Value(u64) = .{ .raw = 0 }; // deopts from a trace raising

pub fn report() void {
    if (comptime !enabled) return;
    if (!@import("hot.zig").report_enabled) return;
    const nat = native_count.load(.monotonic);
    const e = exec_count.load(.monotonic);
    const d = deopt_count.load(.monotonic);
    const ed = err_deopt_count.load(.monotonic);
    std.debug.print("=== tjit exec: {d} native runs, {d} interpreted runs, {d} side-exits (deopts, {d} from raises) ===\n", .{ nat, e, d, ed });
}

/// Entry point for the interpreter's execution hooks: if chunk `chunk_id` has
/// an installed trace and we're not currently recording, run it. Returns the
/// trace result, or `null` to fall back to interpreting the chunk (no trace,
/// recording in progress, or a guard side-exit). A trace that *raises* an eval
/// error also side-exits (see `errorDeopt`): the interpreter is the oracle for
/// errors just as for control flow, so a spurious raise from an unguarded
/// value-kind divergence is recovered, and a genuine error is re-raised
/// identically by the interpreter.
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
            return null; // guard side-exit → caller interprets
        }
        return errorDeopt(vm); // trace raised → side-exit, interpreter re-decides
    }
    const bits = h.traceOf(chunk_id);
    if (bits == 0) return null;
    const trace: *const ir.Trace = @ptrFromInt(bits);
    const result = execute(vm, trace, upvalues, arg) catch return errorDeopt(vm);
    if (result != null) {
        _ = exec_count.fetchAdd(1, .monotonic);
    } else {
        _ = deopt_count.fetchAdd(1, .monotonic);
    }
    return result;
}

/// A trace raised an eval error. Discard any partial error context it built on
/// the VM's error trace (the interpreter rebuilds the authoritative one if it
/// genuinely errors) and side-exit. Safe because a trace's only side effects
/// are memoized forces + pure reads; a trace is only ever entered mid-force, so
/// `vm.trace` is clean (no in-flight error) at that point.
fn errorDeopt(vm: *VM) ?Value {
    if (vm.trace) |t| t.clear();
    _ = err_deopt_count.fetchAdd(1, .monotonic);
    _ = deopt_count.fetchAdd(1, .monotonic);
    return null;
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
                const src = vals[instr.a];
                // An inlined thunk body reads its captured upvalues from the
                // (claimed, not-yet-resolved) thunk directly — don't force it.
                if (src.isThunk()) {
                    const ups = bytecodeThunkUpvalues(vm, src) orelse return null;
                    if (instr.aux >= ups.len) return null;
                    vals[i] = ups[instr.aux];
                } else {
                    const c = try force.forceValue(vm, src);
                    if (!c.isClosure()) return null;
                    const cl = vm.heap.getClosure(c.asObjectId()) catch return null;
                    if (instr.aux >= cl.upvalues.len) return null;
                    vals[i] = cl.upvalues[instr.aux];
                }
            },
            .trace_arg => vals[i] = arg,
            .force => vals[i] = try force.forceValue(vm, vals[instr.a]),
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
            // Claim a trace-built thunk for an inlined body (interpreter's exact
            // protocol). Deopt unless we win the claim — the interpreter then
            // waits / loads the published value.
            .thunk_claim => {
                const tv = vals[instr.a];
                if (!tv.isThunk()) return null;
                const thunk = vm.heap.getThunkAssumeValid(tv.asObjectId());
                switch (thunk.tryForce(vm.claimer_id)) {
                    .claimed => {},
                    else => return null,
                }
            },
            // Publish the inlined body's result to the thunk + mark demanded
            // (mirrors forceThunkImpl's resolve).
            .thunk_resolve => {
                const tv = vals[instr.a];
                if (!tv.isThunk()) return null;
                const thunk = vm.heap.getThunkAssumeValid(tv.asObjectId());
                thunk.resolve(vals[instr.b]);
                thunk.markDemanded();
            },
            .alloc_thunk => {
                // Build a bytecode thunk capturing the (unforced) operand values,
                // exactly as makeBytecodeThunkFromCaptures' .none path does.
                const count: usize = instr.b;
                if (count > MAX_ALLOC_CAPTURES) return null;
                var buf: [MAX_ALLOC_CAPTURES]Value = undefined;
                var k: usize = 0;
                while (k < count) : (k += 1) buf[k] = vals[trace.extra.items[instr.a + k]];
                const id = vm.heap.addBytecodeThunk(@intCast(instr.aux), buf[0..count]) catch return null;
                vals[i] = Value.thunk(id);
            },
            .guard => switch (@as(GuardKind, @enumFromInt(@as(u8, @intCast(instr.aux))))) {
                // Validate the recorded attr shape: the operand must force to an
                // attrset that actually contains the recorded key. A divergent
                // instance (non-attrs, or missing the key) side-exits here —
                // otherwise the following `get_attr` would *raise*
                // MissingAttribute instead of deopting, mis-evaluating a chunk
                // whose attr shape varies across executions.
                .attr_shape => {
                    const a = try force.forceValue(vm, vals[instr.a]);
                    if (!a.isAttrs()) return null;
                    const found = vm.heap.getAttrValueOpt(a.asObjectId(), @intCast(instr.aux2)) catch return null;
                    if (found == null) return null;
                },
                .chunk_id => {
                    const c = try force.forceValue(vm, vals[instr.a]);
                    if (!c.isClosure()) return null;
                    const cl = vm.heap.getClosure(c.asObjectId()) catch return null;
                    if (cl.chunk_id != instr.aux2) return null;
                },
                .bool_is => {
                    const c = try force.forceValue(vm, vals[instr.a]);
                    if (!c.isBool()) return null;
                    if (@intFromBool(c.asBool()) != instr.aux2) return null; // branch flipped → deopt
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
