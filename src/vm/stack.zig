const std = @import("std");
const vm_mod = @import("../vm.zig");
const types = @import("../runtime/types.zig");
const Value = @import("../runtime/value.zig").Value;
const chunk = @import("../bytecode.zig").chunk;
const Chunk = chunk.Chunk;
const trace_log = @import("trace_log.zig");

const VM = vm_mod.VM;
const Frame = vm_mod.Frame;
const ChunkId = types.ChunkId;

// ---- frame management ----

pub fn pushFrame(self: *VM, ch: *const Chunk, chunk_id: ChunkId, arg_count: u32, upvalues: ?[]const Value) !void {
    if (self.frames_len >= types.MAX_FRAMES) return error.FrameOverflow;
    if (arg_count > ch.local_count) return error.InvalidCallFrame;
    const frame_base = self.sp - arg_count;
    const reserved = @as(u32, ch.local_count) - arg_count;

    const stack_cap: u32 = @intCast(types.VM_STACK_CAP);
    if (reserved > stack_cap - self.sp) return error.StackOverflow;
    const start = self.sp;
    const new_sp = start + reserved;
    @memset(self.stack[start..new_sp], Value.null_val);
    self.sp = new_sp;

    self.frames[self.frames_len] = .{
        .chunk_ptr = ch,
        .chunk_id = chunk_id,
        .ip = 0,
        .frame_base = frame_base,
        .local_count = ch.local_count,
        .upvalues = upvalues,
    };
    self.frames_len += 1;
    trace_log.framePush(self.vm_trace, self.worker_id, self.frames_len, chunk_id, frame_base);
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
    if (@as(usize, self.sp) >= types.VM_STACK_CAP) return error.StackOverflow;
    self.stack[self.sp] = val;
    self.sp += 1;
}

pub fn pop(self: *VM) Value {
    self.sp -= 1;
    return self.stack[self.sp];
}

pub fn setStack(self: *VM, idx: u32, val: Value) void {
    self.stack[idx] = val;
}
