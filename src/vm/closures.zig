const std = @import("std");
const vm_mod = @import("../vm.zig");
const types = @import("../runtime/types.zig");
const Value = @import("../runtime/value.zig").Value;
const ChunkId = types.ChunkId;
const ObjectId = types.ObjectId;
const chunk = @import("../bytecode.zig").chunk;
const Chunk = chunk.Chunk;
const heap_mod = @import("../runtime/heap.zig");
const Closure = heap_mod.Closure;

const access = @import("access.zig");
const errors = @import("errors.zig");
const stack = @import("stack.zig");
const trace = @import("trace.zig");

const VM = vm_mod.VM;
const Frame = vm_mod.Frame;
const readU16 = vm_mod.readU16;

// ---- closures ----

pub fn getClosureById(self: *VM, closure_id: ObjectId) !Closure {
    return self.heap.getClosure(closure_id);
}

pub fn makeClosure(self: *VM, chunk_id: ChunkId, upvalue_count: u16) !void {
    const start = self.sp - upvalue_count;
    const id = try self.heap.addClosure(chunk_id, self.stack[start..self.sp]);
    self.sp = start;
    try stack.push(self, Value.closure(id));
}

pub fn stageCaptureDescriptors(self: *VM, descriptors: []const u8, frame: *const Frame) !u16 {
    const upvalue_count = descriptors.len / 3;
    const stack_cap: u32 = @intCast(types.VM_STACK_CAP);
    if (upvalue_count > @as(usize, stack_cap - self.sp)) return error.StackOverflow;

    var current_upvalues: ?[]const Value = null;
    var out_index = self.sp;
    var i: usize = 0;
    while (i < descriptors.len) : (i += 3) {
        const capture_index = readU16(descriptors, i + 1);
        const captured = switch (descriptors[i]) {
            0 => self.stack[frame.frame_base + capture_index],
            1 => value: {
                if (current_upvalues == null) {
                    current_upvalues = frame.upvalues orelse return error.MissingClosure;
                }
                break :value current_upvalues.?[capture_index];
            },
            else => return error.InvalidBytecode,
        };
        self.stack[out_index] = captured;
        out_index += 1;
    }

    self.sp = out_index;
    return @intCast(upvalue_count);
}

pub fn fillCaptureValues(self: *VM, descriptors: []const u8, frame: *const Frame, out: []Value) !void {
    std.debug.assert(out.len == descriptors.len / 3);

    var current_upvalues: ?[]const Value = null;
    var out_index: usize = 0;
    var i: usize = 0;
    while (i < descriptors.len) : (i += 3) {
        const capture_index = readU16(descriptors, i + 1);
        out[out_index] = switch (descriptors[i]) {
            0 => self.stack[frame.frame_base + capture_index],
            1 => value: {
                if (current_upvalues == null) {
                    current_upvalues = frame.upvalues orelse return error.MissingClosure;
                }
                break :value current_upvalues.?[capture_index];
            },
            else => return error.InvalidBytecode,
        };
        out_index += 1;
    }
}

pub fn makeClosureFromCaptures(self: *VM, chunk_id: ChunkId, descriptors: []const u8, frame: *const Frame) !void {
    const upvalue_count = try stageCaptureDescriptors(self, descriptors, frame);
    try makeClosure(self, chunk_id, upvalue_count);
}

pub fn makeBytecodeThunkFromCaptures(self: *VM, chunk_id: ChunkId, descriptors: []const u8, frame: *const Frame) !void {
    const pending = try self.heap.beginBytecodeThunk(chunk_id, descriptors.len / 3);
    var committed = false;
    errdefer if (!committed) self.heap.rollbackBytecodeThunk(pending);
    try fillCaptureValues(self, descriptors, frame, self.heap.pendingBytecodeThunkUpvalues(pending));
    const id = try self.heap.commitBytecodeThunk(pending);
    committed = true;
    if (shouldSpeculate(self, chunk_id)) {
        _ = self.scheduler.submit(.{ .force_thunk = id });
    }
    try stack.push(self, Value.thunk(id));
}

/// Speculation pays off only when the thunk's body is long enough that a
/// helper finishing it ahead of the main thread saves more time than the
/// submit + scheduler overhead costs. Tiny chunks (one or two opcodes)
/// would just generate noise; the main thread can force them faster than
/// it takes to push the task and a helper to pop it.
const SPECULATION_MIN_CODE_BYTES: usize = 256;

inline fn shouldSpeculate(self: *VM, chunk_id: ChunkId) bool {
    const ch = self.registry.get(chunk_id) orelse return false;
    return ch.code.len >= SPECULATION_MIN_CODE_BYTES;
}

// ---- calls ----

pub fn doCall(self: *VM, callee: Value, arg: Value) !void {
    if (callee.discriminant == .closure) {
        const closure_id = callee.asObjectId();
        const closure = try getClosureById(self, closure_id);
        const ch = self.registry.get(closure.chunk_id) orelse return error.InvalidChunk;
        try stack.push(self, arg); // arg is first local
        try stack.pushFrame(self, ch, 1, closure.upvalues);
    } else if (callee.discriminant == .builtin) {
        try stack.push(self, try access.applyBuiltin(self, callee.asBuiltinId(), &.{arg}));
    } else if (callee.discriminant == .builtin_closure) {
        try stack.push(self, try access.applyBuiltinClosure(self, callee, arg));
    } else if (callee.discriminant == .attrs) {
        const callable = try access.callAttrFunctor(self, callee);
        try doCall(self, callable, arg);
    } else return trace.notCallableError(self, callee);
}

pub fn doTailCall(self: *VM, callee: Value, arg: Value) !void {
    var current = callee;
    while (true) {
        switch (current.discriminant) {
            .closure => {
                const closure_id = current.asObjectId();
                const closure = try getClosureById(self, closure_id);
                const ch = self.registry.get(closure.chunk_id) orelse return error.InvalidChunk;
                try replaceCurrentFrame(self, ch, arg, closure.upvalues);
                return;
            },
            .builtin => {
                try stack.push(self, try access.applyBuiltin(self, current.asBuiltinId(), &.{arg}));
                return;
            },
            .builtin_closure => {
                try stack.push(self, try access.applyBuiltinClosure(self, current, arg));
                return;
            },
            .attrs => current = try access.callAttrFunctor(self, current),
            else => return trace.notCallableError(self, current),
        }
    }
}

pub fn replaceCurrentFrame(self: *VM, ch: *const Chunk, arg: Value, upvalues: []const Value) !void {
    if (ch.local_count == 0) return error.InvalidCallFrame;

    const stack_cap: u32 = @intCast(types.VM_STACK_CAP);
    const frame = stack.currentFrame(self);
    const frame_base = frame.frame_base;
    const arg_end = frame_base + 1;
    if (arg_end > stack_cap) return error.StackOverflow;
    self.stack[frame_base] = arg;

    const reserved = @as(u32, ch.local_count) - 1;
    if (reserved > stack_cap - arg_end) return error.StackOverflow;
    const new_sp = arg_end + reserved;
    const arg_end_idx: usize = @intCast(arg_end);
    const new_sp_idx: usize = @intCast(new_sp);
    @memset(self.stack[arg_end_idx..new_sp_idx], Value.null_val);
    self.sp = new_sp;

    frame.* = .{
        .chunk_ptr = ch,
        .ip = 0,
        .frame_base = frame_base,
        .local_count = ch.local_count,
        .upvalues = upvalues,
    };
}

pub fn callValue(self: *VM, callee: Value, arg: Value) !Value {
    if (callee.discriminant == .closure) {
        const closure_id = callee.asObjectId();
        const closure = try getClosureById(self, closure_id);
        const ch = self.registry.get(closure.chunk_id) orelse return error.InvalidChunk;
        try stack.push(self, arg);
        return runIsolatedFrame(self, ch, 1, closure.upvalues);
    }
    if (callee.discriminant == .builtin) {
        return access.applyBuiltin(self, callee.asBuiltinId(), &.{arg});
    }
    if (callee.discriminant == .builtin_closure) {
        return access.applyBuiltinClosure(self, callee, arg);
    }
    if (callee.discriminant == .attrs) {
        const callable = try access.callAttrFunctor(self, callee);
        return callValue(self, callable, arg);
    }
    return trace.notCallableError(self, callee);
}

pub fn runIsolatedFrame(self: *VM, ch: *const Chunk, arg_count: u32, upvalues: ?[]const Value) anyerror!Value {
    const run_mod = @import("run.zig");
    const stop_depth = self.frames_len;
    const base_sp = self.sp - arg_count;
    stack.pushFrame(self, ch, arg_count, upvalues) catch |err| {
        self.sp = base_sp;
        return err;
    };
    return run_mod.runUntil(self, stop_depth) catch |err| {
        errors.captureErrorTrace(self, err) catch {};
        self.frames_len = stop_depth;
        self.sp = base_sp;
        return err;
    };
}
