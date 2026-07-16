//! The VM operand-stack and call-frame machinery: push/pop, frame reservation
//! and teardown, and the GC-precise in-place binary-operand peek (`binTop`/`dropBin`).
const std = @import("std");
const vm_mod = @import("context.zig");
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const chunk = @import("../bytecode.zig").chunk;
const Chunk = chunk.Chunk;
const trace_log = @import("trace_log.zig");
const trace = @import("trace.zig");

const VM = vm_mod.VM;
const Frame = vm_mod.Frame;
const ChunkId = types.ChunkId;

// ---- frame management ----

/// `is_call` marks a genuine function application (as opposed to the
/// top-level entry frame or a thunk-force / eager-argument isolated
/// frame). A call frame is one logical call-depth deeper than the frame
/// that pushed it and is subject to the `max-call-depth` cap; a
/// passthrough frame inherits its parent's depth unchanged.
///
/// `inline` so `is_call` folds to a compile-time constant at each call
/// site (every caller passes a literal), collapsing the depth-accounting
/// branches. Before the call-depth work landed this was small enough that
/// LLVM inlined it into the hot callers (`doCall`, `runIsolatedFrame`,
/// `opApplyArg`); the added bookkeeping pushed it just over the inline
/// threshold, turning every frame push into an out-of-line call (~+9%
/// instructions on call-heavy code). Forcing inline restores that.
pub inline fn pushFrame(self: *VM, ch: *const Chunk, chunk_id: ChunkId, arg_count: u32, upvalues: ?[]const Value, is_call: bool) !void {
    if (self.frames_len >= types.max_frames) return error.FrameOverflow;
    if (arg_count > ch.local_count) return error.InvalidCallFrame;
    const parent_depth: u32 = if (self.frames_len > 0) self.frames[self.frames_len - 1].call_depth else 0;
    const new_depth: u32 = if (is_call) parent_depth + 1 else parent_depth;
    if (is_call and new_depth > self.policy.max_call_depth) return trace.callDepthExceeded(self);
    const frame_base = self.sp - arg_count;
    const reserved = @as(u32, ch.local_count) - arg_count;

    const stack_cap: u32 = @intCast(types.vm_stack_capacity);
    if (reserved > stack_cap - self.sp) return error.StackOverflow;
    const start = self.sp;
    const new_sp = start + reserved;
    @memset(self.stack[start..new_sp], Value.null_val);
    self.sp = new_sp;
    if (new_sp > self.sp_high_water) self.sp_high_water = new_sp;

    self.frames[self.frames_len] = .{
        .chunk_ptr = ch,
        .chunk_id = chunk_id,
        .ip = 0,
        .frame_base = frame_base,
        .local_count = ch.local_count,
        .upvalues = upvalues,
        .call_depth = new_depth,
    };
    self.frames_len += 1;
    trace_log.framePush(self.vm_trace, self.workerId(), self.frames_len, chunk_id, frame_base);
}

pub fn popFrame(self: *VM) Frame {
    self.frames_len -= 1;
    return self.frames[self.frames_len];
}

pub fn currentFrame(self: *VM) *Frame {
    return &self.frames[self.frames_len - 1];
}

// ---- stack ops ----

pub fn push(self: *VM, val: Value) !void {
    if (@as(usize, self.sp) >= types.vm_stack_capacity) return error.StackOverflow;
    self.stack[self.sp] = val;
    self.sp += 1;
    if (self.sp > self.sp_high_water) self.sp_high_water = self.sp;
}

pub fn pop(self: *VM) Value {
    self.sp -= 1;
    return self.stack[self.sp];
}

pub fn setStack(self: *VM, idx: u32, val: Value) void {
    self.stack[idx] = val;
}

/// The top two operands (`left` = second-from-top, `right` = top) WITHOUT
/// popping. A binary op reads them, calls a helper that may force them
/// (a GC safepoint), and only then drops via `dropBin` — so the operands
/// stay on the operand stack (precise GC roots) across the force. Forcing
/// a thunk memoises its result into the thunk, which the on-stack slot
/// keeps reachable, so no write-back is needed. See docs/gc.md.
pub inline fn binTop(self: *VM) struct { left: Value, right: Value } {
    return .{ .left = self.stack[self.sp - 2], .right = self.stack[self.sp - 1] };
}

pub inline fn dropBin(self: *VM) void {
    self.sp -= 2;
}

/// Drop the top `n` operands (same contract as `dropBin`: only after
/// all forcing/allocation that needs them rooted has finished).
pub inline fn dropN(self: *VM, n: u32) void {
    self.sp -= n;
}
