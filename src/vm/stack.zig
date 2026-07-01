const std = @import("std");
const vm_mod = @import("../vm.zig");
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const chunk = @import("../bytecode.zig").chunk;
const Chunk = chunk.Chunk;
const trace_log = @import("trace_log.zig");
const hot_mod = @import("../jit/hot.zig");
const record_mod = @import("../jit/record.zig");

const VM = vm_mod.VM;
const Frame = vm_mod.Frame;
const ChunkId = types.ChunkId;

// ---- frame management ----

pub fn pushFrame(self: *VM, ch: *const Chunk, chunk_id: ChunkId, arg_count: u32, upvalues: ?[]const Value) !void {
    // Tracing-JIT hot-anchor detection: every chunk entry (lambda calls and
    // thunk/closure forcing both route through here) bumps the chunk's hot
    // counter. Comptime-gated to `-Dtjit` — zero cost in normal builds.
    const tjit_armed = if (comptime hot_mod.enabled) blk: {
        if (self.registry.hot) |h| break :blk h.onEntry(chunk_id);
        break :blk false;
    } else false;
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
    if (new_sp > self.sp_high_water) self.sp_high_water = new_sp;

    self.frames[self.frames_len] = .{
        .chunk_ptr = ch,
        .chunk_id = chunk_id,
        .ip = 0,
        .frame_base = frame_base,
        .local_count = ch.local_count,
        .upvalues = upvalues,
    };
    self.frames_len += 1;
    trace_log.framePush(self.vm_trace, self.workerId(), self.frames_len, chunk_id, frame_base);
    // Begin recording this just-pushed frame if its chunk armed. `root_depth`
    // is the post-push frame depth; ops at any other depth abort the trace.
    if (comptime hot_mod.enabled) {
        // Only arity-1 anchors (curried lambdas / thunks) for now; the
        // recorder's frame model assumes a single trace argument.
        if (tjit_armed and ch.arity == 1) {
            record_mod.start(self, chunk_id, ch.local_count, ch.local_count >= 1, self.frames_len);
        }
    }
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
/// keeps reachable, so no write-back is needed. See docs/gc-plan.md.
pub inline fn binTop(self: *VM) struct { left: Value, right: Value } {
    return .{ .left = self.stack[self.sp - 2], .right = self.stack[self.sp - 1] };
}

pub inline fn dropBin(self: *VM) void {
    self.sp -= 2;
}
