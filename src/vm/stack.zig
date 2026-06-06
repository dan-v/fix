const std = @import("std");
const vm_mod = @import("../vm.zig");
const types = @import("../types.zig");
const Value = @import("../value.zig").Value;
const chunk = @import("../chunk.zig");
const Chunk = chunk.Chunk;

const VM = vm_mod.VM;
const Frame = vm_mod.Frame;

// ---- frame management ----

pub fn pushFrame(self: *VM, ch: *const Chunk, arg_count: u32, upvalues: ?[]const Value) !void {
    if (self.frames.items.len >= types.MAX_FRAMES) return error.FrameOverflow;
    if (arg_count > ch.local_count) return error.InvalidCallFrame;
    const frame_base = self.sp - arg_count;
    const reserved = @as(u32, ch.local_count) - arg_count;

    // Stack and frame buffers are preallocated in init; reserve hot-path
    // slots directly instead of re-entering ArrayList growth checks.
    const stack_cap: u32 = @intCast(types.VM_STACK_CAP);
    if (reserved > stack_cap - self.sp) return error.StackOverflow;
    const start = self.sp;
    const new_sp = start + reserved;
    const start_idx: usize = @intCast(start);
    const new_sp_idx: usize = @intCast(new_sp);
    @memset(self.stack.items[start_idx..new_sp_idx], Value.null_val);
    self.sp = new_sp;

    const frame_index = self.frames.items.len;
    self.frames.items.len = frame_index + 1;
    self.frames.items[frame_index] = .{
        .chunk_ptr = ch,
        .ip = 0,
        .frame_base = frame_base,
        .local_count = ch.local_count,
        .upvalues = upvalues,
    };
}

pub fn popFrame(self: *VM) Frame {
    return self.frames.pop().?;
}

pub fn currentFrame(self: *VM) *Frame {
    return &self.frames.items[self.frames.items.len - 1];
}

// ---- stack ops ----

pub fn push(self: *VM, val: Value) !void {
    if (@as(usize, self.sp) >= types.VM_STACK_CAP) return error.StackOverflow;
    const index: usize = @intCast(self.sp);
    self.stack.items[index] = val;
    self.sp += 1;
}

pub fn pop(self: *VM) Value {
    self.sp -= 1;
    return self.stack.items[self.sp];
}

pub fn setStack(self: *VM, idx: u32, val: Value) void {
    self.stack.items[idx] = val;
}
