const std = @import("std");
const vm_mod = @import("../vm.zig");
const types = @import("../types.zig");
const Value = @import("../value.zig").Value;
const InternId = types.InternId;
const ChunkId = types.ChunkId;
const ObjectId = types.ObjectId;
const bytecode_mod = @import("../bytecode.zig");
const opcode = @import("../opcode.zig");
const OpCode = opcode.OpCode;
const chunk = @import("../chunk.zig");
const Chunk = chunk.Chunk;
const thunk_mod = @import("../thunk.zig");
const Thunk = thunk_mod.Thunk;
const ThunkTarget = thunk_mod.ThunkTarget;
const heap_mod = @import("../heap.zig");
const Closure = heap_mod.Closure;
const numeric = @import("../runtime/numeric.zig");
const source_paths = @import("../runtime/source_path.zig");
const vm_builtins = @import("builtins.zig");
const diagnostic = @import("../diagnostic.zig");

const VM = vm_mod.VM;
const Frame = vm_mod.Frame;
const opcode_profile_enabled = vm_mod.opcode_profile_enabled;
const readU16 = vm_mod.readU16;
const readU32 = vm_mod.readU32;
const readInternId = vm_mod.readInternId;

// ---- closures ----

pub fn getClosureById(self: *VM, closure_id: ObjectId) !Closure {
    return self.heap.getClosure(closure_id);
}

pub fn makeClosure(self: *VM, chunk_id: ChunkId, upvalue_count: u16) !void {
    const start = self.sp - upvalue_count;
    const id = try self.heap.addClosure(chunk_id, self.stack.items[start..self.sp]);
    self.sp = start;
    try self.push(Value.closure(id));
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
            0 => self.stack.items[frame.frame_base + capture_index],
            1 => value: {
                if (current_upvalues == null) {
                    current_upvalues = frame.upvalues orelse return error.MissingClosure;
                }
                break :value current_upvalues.?[capture_index];
            },
            else => return error.InvalidBytecode,
        };
        self.stack.items[out_index] = captured;
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
            0 => self.stack.items[frame.frame_base + capture_index],
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
    const upvalue_count = try self.stageCaptureDescriptors(descriptors, frame);
    try self.makeClosure(chunk_id, upvalue_count);
}

pub fn makeBytecodeThunkFromCaptures(self: *VM, chunk_id: ChunkId, descriptors: []const u8, frame: *const Frame) !void {
    const pending = try self.heap.beginBytecodeThunk(chunk_id, descriptors.len / 3);
    var committed = false;
    errdefer if (!committed) self.heap.rollbackBytecodeThunk(pending);
    try self.fillCaptureValues(descriptors, frame, self.heap.pendingBytecodeThunkUpvalues(pending));
    const id = try self.heap.commitBytecodeThunk(pending);
    committed = true;
    try self.push(Value.thunk(id));
}

// ---- calls ----

pub fn doCall(self: *VM, callee: Value, arg: Value) !void {
    if (callee.discriminant == .closure) {
        const closure_id = callee.asObjectId();
        const closure = try self.getClosureById(closure_id);
        const ch = self.registry.get(closure.chunk_id) orelse return error.InvalidChunk;
        try self.push(arg); // arg is first local
        try self.pushFrame(ch, 1, closure.upvalues);
    } else if (callee.discriminant == .builtin) {
        try self.push(try self.applyBuiltin(callee.asBuiltinId(), &.{arg}));
    } else if (callee.discriminant == .builtin_closure) {
        try self.push(try self.applyBuiltinClosure(callee, arg));
    } else if (callee.discriminant == .attrs) {
        const callable = try self.callAttrFunctor(callee);
        try self.doCall(callable, arg);
    } else return self.notCallableError(callee);
}

pub fn doTailCall(self: *VM, callee: Value, arg: Value) !void {
    var current = callee;
    while (true) {
        switch (current.discriminant) {
            .closure => {
                const closure_id = current.asObjectId();
                const closure = try self.getClosureById(closure_id);
                const ch = self.registry.get(closure.chunk_id) orelse return error.InvalidChunk;
                try self.replaceCurrentFrame(ch, arg, closure.upvalues);
                return;
            },
            .builtin => {
                try self.push(try self.applyBuiltin(current.asBuiltinId(), &.{arg}));
                return;
            },
            .builtin_closure => {
                try self.push(try self.applyBuiltinClosure(current, arg));
                return;
            },
            .attrs => current = try self.callAttrFunctor(current),
            else => return self.notCallableError(current),
        }
    }
}

pub fn replaceCurrentFrame(self: *VM, ch: *const Chunk, arg: Value, upvalues: []const Value) !void {
    if (ch.local_count == 0) return error.InvalidCallFrame;

    const stack_cap: u32 = @intCast(types.VM_STACK_CAP);
    const frame = self.currentFrame();
    const frame_base = frame.frame_base;
    const arg_end = frame_base + 1;
    if (arg_end > stack_cap) return error.StackOverflow;
    self.stack.items[frame_base] = arg;

    const reserved = @as(u32, ch.local_count) - 1;
    if (reserved > stack_cap - arg_end) return error.StackOverflow;
    const new_sp = arg_end + reserved;
    const arg_end_idx: usize = @intCast(arg_end);
    const new_sp_idx: usize = @intCast(new_sp);
    @memset(self.stack.items[arg_end_idx..new_sp_idx], Value.null_val);
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
        const closure = try self.getClosureById(closure_id);
        const ch = self.registry.get(closure.chunk_id) orelse return error.InvalidChunk;
        try self.push(arg);
        return self.runIsolatedFrame(ch, 1, closure.upvalues);
    }
    if (callee.discriminant == .builtin) {
        return self.applyBuiltin(callee.asBuiltinId(), &.{arg});
    }
    if (callee.discriminant == .builtin_closure) {
        return self.applyBuiltinClosure(callee, arg);
    }
    if (callee.discriminant == .attrs) {
        const callable = try self.callAttrFunctor(callee);
        return self.callValue(callable, arg);
    }
    return self.notCallableError(callee);
}

pub fn runIsolatedFrame(self: *VM, ch: *const Chunk, arg_count: u32, upvalues: ?[]const Value) anyerror!Value {
    const stop_depth = self.frames.items.len;
    const base_sp = self.sp - arg_count;
    self.pushFrame(ch, arg_count, upvalues) catch |err| {
        self.sp = base_sp;
        return err;
    };
    return self.runUntil(stop_depth) catch |err| {
        self.captureErrorTrace(err) catch {};
        self.frames.shrinkRetainingCapacity(stop_depth);
        self.sp = base_sp;
        return err;
    };
}
