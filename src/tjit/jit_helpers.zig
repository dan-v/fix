//! C-ABI helpers called by JIT-compiled traces (`-Dtjit`). Each mirrors the
//! corresponding `exec.zig` op exactly (same underlying helpers as the
//! interpreter's opcode handlers) so native traces are bit-identical to both.
//!
//! Return convention is `jit.JitResult{value, error_code}` (rax:rdx):
//!   error_code == 0           → success, `value` is the result
//!   error_code == DEOPT_CODE  → guard side-exit; caller re-runs interpreted
//!   else                      → a real eval error (`@intFromError`)
//! The emitter routes any nonzero `error_code` to the epilogue; `exec.tryRun`
//! distinguishes deopt from error.

const std = @import("std");
const jit = @import("../jit.zig");
const vm_mod = @import("../vm.zig");
const Value = @import("../runtime/value.zig").Value;
const force = @import("../vm/force.zig");
const access = @import("../vm/access.zig");
const numeric = @import("../runtime/numeric.zig");
const strings = @import("../vm/strings.zig");
const ir = @import("ir.zig");

const VM = vm_mod.VM;
const JitResult = jit.JitResult;
const InternId = @import("../runtime/types.zig").InternId;

/// Reserved `error_code` meaning "guard failed, deopt" (distinct from any
/// real `@intFromError`, which are small).
pub const DEOPT_CODE: u64 = std.math.maxInt(u64);

inline fn ok(v: Value) JitResult {
    return .{ .value = v, .error_code = 0 };
}
inline fn errResult(e: anyerror) JitResult {
    return .{ .value = Value.null_val, .error_code = @intFromError(e) };
}
inline fn deopt() JitResult {
    return .{ .value = Value.null_val, .error_code = DEOPT_CODE };
}

/// Generic `+` (matches opAddInt: numbers / paths / strings).
pub fn tjitAdd(vm: *anyopaque, a: Value, b: Value) callconv(.c) JitResult {
    const self: *VM = @ptrCast(@alignCast(vm));
    const av = force.forceValue(self, a) catch |e| return errResult(e);
    const bv = force.forceValue(self, b) catch |e| return errResult(e);
    if (numeric.isNumeric(av) and numeric.isNumeric(bv)) {
        return ok(numeric.add(self.heap, av, bv) catch |e| return errResult(e));
    } else if (av.isPath()) {
        return ok(strings.concatPathLike(self, av, bv) catch |e| return errResult(e));
    } else {
        return ok(strings.concatStringLike(self, av, bv) catch |e| return errResult(e));
    }
}

pub fn tjitSub(vm: *anyopaque, a: Value, b: Value) callconv(.c) JitResult {
    const self: *VM = @ptrCast(@alignCast(vm));
    const av = force.forceValue(self, a) catch |e| return errResult(e);
    const bv = force.forceValue(self, b) catch |e| return errResult(e);
    return ok(numeric.sub(self.heap, av, bv) catch |e| return errResult(e));
}

pub fn tjitMul(vm: *anyopaque, a: Value, b: Value) callconv(.c) JitResult {
    const self: *VM = @ptrCast(@alignCast(vm));
    const av = force.forceValue(self, a) catch |e| return errResult(e);
    const bv = force.forceValue(self, b) catch |e| return errResult(e);
    return ok(numeric.mul(self.heap, av, bv) catch |e| return errResult(e));
}

/// Native `side_exit`: reconstruct the anchor frame from `snap` (reading live
/// values from the trace's native stack slots `slots[ref]`) and resume the
/// interpreter — the same logic the exec.zig interpreter runs. Returns the
/// resumed result, `deopt()` if reconstruction can't proceed, or the eval error.
pub fn tjitSideExit(vm: *anyopaque, snap: *const ir.Snapshot, slots: [*]const Value) callconv(.c) JitResult {
    const self: *VM = @ptrCast(@alignCast(vm));
    const exec = @import("exec.zig");
    const result = exec.sideExitImpl(self, snap, slots, self.native_upvalues) catch |e| return errResult(e);
    return if (result) |v| ok(v) else deopt();
}

/// Force `v` to WHNF (matches the interpreter's forcing loads). Errors
/// propagate as error_code → the trace side-exits.
pub fn tjitForce(vm: *anyopaque, v: Value) callconv(.c) JitResult {
    const self: *VM = @ptrCast(@alignCast(vm));
    return ok(force.forceValue(self, v) catch |e| return errResult(e));
}

/// `attrs.name` — force the attrs operand then look it up (matches exec.zig).
pub fn tjitGetAttr(vm: *anyopaque, attrs: Value, name: u32) callconv(.c) JitResult {
    const self: *VM = @ptrCast(@alignCast(vm));
    const av = force.forceValue(self, attrs) catch |e| return errResult(e);
    return ok(access.getAttrValue(self, av, @as(InternId, name)) catch |e| return errResult(e));
}

/// Guard that `attrs` forces to an attrset that actually contains `name`.
/// Deopt otherwise (non-attrs, or a different-shaped instance missing the
/// recorded key). Without this the following `get_attr` would *raise*
/// `MissingAttribute` on a divergent shape instead of cleanly side-exiting —
/// the soundness hole that blocks tracing variable-shape chunks.
pub fn tjitGuardAttrShape(vm: *anyopaque, attrs: Value, name: u32) callconv(.c) JitResult {
    const self: *VM = @ptrCast(@alignCast(vm));
    const av = force.forceValue(self, attrs) catch |e| return errResult(e);
    if (!av.isAttrs()) return deopt();
    const found = self.heap.getAttrValueOpt(av.asObjectId(), @as(InternId, name)) catch return deopt();
    if (found == null) return deopt();
    return ok(av);
}

/// Guard that `func` resolves to a closure of `chunk_id`. Deopt on mismatch.
pub fn tjitGuardChunkId(vm: *anyopaque, func: Value, chunk_id: u32) callconv(.c) JitResult {
    const self: *VM = @ptrCast(@alignCast(vm));
    const c = force.forceValue(self, func) catch |e| return errResult(e);
    if (!c.isClosure()) return deopt();
    const cl = self.heap.getClosure(c.asObjectId()) catch return deopt();
    if (cl.chunk_id != chunk_id) return deopt();
    return ok(c);
}

/// Guard that `cond` is a bool equal to `expected` (1/0). Deopt on a flipped
/// branch (or non-bool).
pub fn tjitGuardBool(vm: *anyopaque, cond: Value, expected: u32) callconv(.c) JitResult {
    const self: *VM = @ptrCast(@alignCast(vm));
    const c = force.forceValue(self, cond) catch |e| return errResult(e);
    if (!c.isBool()) return deopt();
    if (@intFromBool(c.asBool()) != expected) return deopt();
    return ok(c);
}

/// Upvalue `slot` of inlined closure `func`. Deopt if not the expected shape.
pub fn tjitLoadUpvalueOf(vm: *anyopaque, func: Value, slot: u32) callconv(.c) JitResult {
    const self: *VM = @ptrCast(@alignCast(vm));
    const c = force.forceValue(self, func) catch |e| return errResult(e);
    if (!c.isClosure()) return deopt();
    const cl = self.heap.getClosure(c.asObjectId()) catch return deopt();
    if (slot >= cl.upvalues.len) return deopt();
    return ok(cl.upvalues[slot]);
}
