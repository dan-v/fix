//! Tail-calling bytecode virtual machine.
//!
//! Each worker thread gets its own VM instance. The VM executes bytecode chunks
//! in a loop until they return. Tail calls are optimized by reusing the current
//! frame instead of pushing a new one.
//!
//! Architecture:
//!   - Direct-threaded dispatch via switch statement
//!   - Value stack (growable, contiguous memory)
//!   - Frame stack (call frames with return info)
//!   - Integration with MemoCache for aggressive normalization
//!   - Atomic thunk integration for lazy evaluation

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const Value = @import("value.zig").Value;
const InternId = types.InternId;
const ChunkId = types.ChunkId;
const OpCode = @import("opcode.zig").OpCode;
const chunk = @import("chunk.zig");
const Chunk = chunk.Chunk;
const ChunkRegistry = chunk.ChunkRegistry;
const MemoCache = @import("cache.zig").MemoCache;
const Thunk = @import("thunk.zig").Thunk;
const Cell = @import("thunk.zig").Cell;
const InternTable = @import("intern.zig").InternTable;
const Scheduler = @import("scheduler.zig").Scheduler;

/// A single call frame.
pub const Frame = struct {
    /// The chunk being executed.
    chunk_ptr: *const Chunk,
    /// Instruction pointer (byte offset into chunk.code).
    ip: usize,
    /// Base index into the VM stack for local variables.
    frame_base: u32,
    /// Number of locals in this frame (for cleanup).
    local_count: u32,
    /// Closure currently executing, used for captured upvalue loads.
    closure_ptr: ?*u8,
};

/// Per-thread VM state. Each worker thread has one of these.
pub const VM = struct {
    allocator: std.mem.Allocator,
    /// Global chunk registry (shared across all VMs).
    registry: *const ChunkRegistry,
    /// Global intern table (shared).
    intern: *InternTable,
    /// Global memoization cache (shared).
    cache: *MemoCache,
    /// Global scheduler (for spawning work).
    scheduler: *Scheduler,
    /// This VM's worker index.
    worker_id: u8,

    /// The value stack.
    stack: std.ArrayListUnmanaged(Value),
    /// Stack pointer (index into stack.items for next push).
    sp: u32,
    /// Call frames.
    frames: std.ArrayListUnmanaged(Frame),

    pub fn init(
        allocator: std.mem.Allocator,
        registry: *const ChunkRegistry,
        intern: *InternTable,
        cache: *MemoCache,
        scheduler: *Scheduler,
        worker_id: u8,
    ) !VM {
        return .{
            .allocator = allocator,
            .registry = registry,
            .intern = intern,
            .cache = cache,
            .scheduler = scheduler,
            .worker_id = worker_id,
            .stack = try std.ArrayListUnmanaged(Value).initCapacity(allocator, types.VM_STACK_CAP),
            .sp = 0,
            .frames = try std.ArrayListUnmanaged(Frame).initCapacity(allocator, types.MAX_FRAMES),
        };
    }

    pub fn deinit(self: *VM) void {
        self.stack.deinit(self.allocator);
        self.frames.deinit(self.allocator);
    }

    // ---- public entry ----

    /// Evaluate a chunk and return its result.
    pub fn eval(self: *VM, chunk_id: ChunkId) !Value {
        const ch = self.registry.get(chunk_id) orelse return error.InvalidChunk;

        // Push initial frame.
        try self.pushFrame(ch, 0, null);
        return self.run();
    }

    // ---- frame management ----

    fn pushFrame(self: *VM, ch: *const Chunk, local_count: u32, closure_ptr: ?*u8) !void {
        try self.frames.append(self.allocator, .{
            .chunk_ptr = ch,
            .ip = 0,
            .frame_base = self.sp - local_count,
            .local_count = local_count,
            .closure_ptr = closure_ptr,
        });
    }

    fn popFrame(self: *VM) Frame {
        return self.frames.pop().?;
    }

    fn currentFrame(self: *VM) *Frame {
        return &self.frames.items[self.frames.items.len - 1];
    }

    // ---- stack ops ----

    fn push(self: *VM, val: Value) !void {
        if (self.sp >= self.stack.items.len) {
            try self.stack.append(self.allocator, val);
            self.sp = @intCast(self.stack.items.len);
        } else {
            self.stack.items[self.sp] = val;
            self.sp += 1;
        }
    }

    fn pop(self: *VM) Value {
        self.sp -= 1;
        return self.stack.items[self.sp];
    }

    fn setStack(self: *VM, idx: u32, val: Value) void {
        self.stack.items[idx] = val;
    }

    // ---- main loop ----

    fn run(self: *VM) anyerror!Value {
        return self.runUntil(0);
    }

    fn runUntil(self: *VM, stop_depth: usize) anyerror!Value {
        while (true) {
            var frame = self.currentFrame();
            const code = frame.chunk_ptr.code;
            if (frame.ip >= code.len) break;

            const op: OpCode = @enumFromInt(code[frame.ip]);
            frame.ip += 1;

            switch (op) {
                .constant => {
                    const idx_low = code[frame.ip];
                    const idx_high = code[frame.ip + 1];
                    frame.ip += 2;
                    const idx: u16 = @as(u16, idx_low) | (@as(u16, idx_high) << 8);
                    try self.push(frame.chunk_ptr.constants[idx]);
                },

                .push_null => try self.push(Value.null_val),
                .push_true => try self.push(Value.boolVal(true)),
                .push_false => try self.push(Value.boolVal(false)),

                .pop => {
                    _ = self.pop();
                },

                .dup => {
                    const t = self.stack.items[self.sp - 1];
                    try self.push(t);
                },

                .get_local => {
                    const slot = code[frame.ip];
                    frame.ip += 1;
                    const raw = self.stack.items[frame.frame_base + slot];
                    const val = try self.forceValue(raw);
                    try self.push(val);
                },

                .capture_local => {
                    const slot = code[frame.ip];
                    frame.ip += 1;
                    const val = self.stack.items[frame.frame_base + slot];
                    try self.push(val);
                },

                .capture_upvalue => {
                    const slot = code[frame.ip];
                    frame.ip += 1;
                    const closure_ptr = frame.closure_ptr orelse return error.MissingClosure;
                    const upvalues = closureUpvalues(closure_ptr);
                    try self.push(upvalues[slot]);
                },

                .set_local => {
                    const slot = code[frame.ip];
                    frame.ip += 1;
                    const val = self.stack.items[self.sp - 1];
                    self.setStack(frame.frame_base + slot, val);
                },

                .set_cell_local => {
                    const slot = code[frame.ip];
                    frame.ip += 1;
                    const val = self.pop();
                    const cell_val = self.stack.items[frame.frame_base + slot];
                    if (cell_val.discriminant != .cell) return error.TypeError;
                    const cell = cell_val.asPtr(Cell);
                    cell.value = val;
                },

                .get_upvalue => {
                    const slot = code[frame.ip];
                    frame.ip += 1;
                    const closure_ptr = frame.closure_ptr orelse return error.MissingClosure;
                    const upvalues = closureUpvalues(closure_ptr);
                    const val = try self.forceValue(upvalues[slot]);
                    try self.push(val);
                },

                // ---- integer arithmetic ----
                .add_int => {
                    const b = self.pop();
                    const a = self.pop();
                    if (a.discriminant == .int and b.discriminant == .int) {
                        try self.push(Value.int(a.asInt() + b.asInt()));
                    } else {
                        return error.TypeError;
                    }
                },
                .sub_int => {
                    const b = self.pop();
                    const a = self.pop();
                    if (a.discriminant == .int and b.discriminant == .int) {
                        try self.push(Value.int(a.asInt() - b.asInt()));
                    } else {
                        return error.TypeError;
                    }
                },
                .mul_int => {
                    const b = self.pop();
                    const a = self.pop();
                    if (a.discriminant == .int and b.discriminant == .int) {
                        try self.push(Value.int(a.asInt() * b.asInt()));
                    } else {
                        return error.TypeError;
                    }
                },
                .div_int => {
                    const b = self.pop();
                    const a = self.pop();
                    if (a.discriminant == .int and b.discriminant == .int) {
                        if (b.asInt() == 0) return error.DivisionByZero;
                        try self.push(Value.int(@divTrunc(a.asInt(), b.asInt())));
                    } else {
                        return error.TypeError;
                    }
                },
                .negate_int => {
                    const a = self.pop();
                    if (a.discriminant == .int) {
                        try self.push(Value.int(-a.asInt()));
                    } else if (a.discriminant == .float) {
                        try self.push(Value.float(-a.asFloat()));
                    } else {
                        return error.TypeError;
                    }
                },

                // ---- float arithmetic ----
                .add_float => {
                    const b = self.pop();
                    const a = self.pop();
                    try self.push(Value.float(coerceToFloat(a) + coerceToFloat(b)));
                },
                .sub_float => {
                    const b = self.pop();
                    const a = self.pop();
                    try self.push(Value.float(coerceToFloat(a) - coerceToFloat(b)));
                },
                .mul_float => {
                    const b = self.pop();
                    const a = self.pop();
                    try self.push(Value.float(coerceToFloat(a) * coerceToFloat(b)));
                },
                .div_float => {
                    const b = self.pop();
                    const a = self.pop();
                    try self.push(Value.float(coerceToFloat(a) / coerceToFloat(b)));
                },
                .negate_float => {
                    const a = self.pop();
                    try self.push(Value.float(-coerceToFloat(a)));
                },

                // ---- comparison ----
                .eq => {
                    const b = self.pop();
                    const a = self.pop();
                    try self.push(Value.boolVal(self.valuesEqual(a, b)));
                },
                .neq => {
                    const b = self.pop();
                    const a = self.pop();
                    try self.push(Value.boolVal(!self.valuesEqual(a, b)));
                },
                .lt => {
                    const b = self.pop();
                    const a = self.pop();
                    try self.push(Value.boolVal(self.compareValues(a, b) == .lt));
                },
                .lte => {
                    const b = self.pop();
                    const a = self.pop();
                    const r = self.compareValues(a, b);
                    try self.push(Value.boolVal(r == .lt or r == .eq));
                },
                .gt => {
                    const b = self.pop();
                    const a = self.pop();
                    try self.push(Value.boolVal(self.compareValues(a, b) == .gt));
                },
                .gte => {
                    const b = self.pop();
                    const a = self.pop();
                    const r = self.compareValues(a, b);
                    try self.push(Value.boolVal(r == .gt or r == .eq));
                },

                // ---- logical ----
                .not => {
                    const a = self.pop();
                    try self.push(Value.boolVal(!isTruthy(a)));
                },

                // ---- control flow ----
                .jump => {
                    const offset: u16 = readU16(code, frame.ip);
                    frame.ip += 2;
                    frame.ip += @as(usize, offset);
                },
                .jump_if_false => {
                    const offset: u16 = readU16(code, frame.ip);
                    frame.ip += 2;
                    const cond = self.stack.items[self.sp - 1];
                    if (!isTruthy(cond)) {
                        frame.ip += @as(usize, offset);
                    }
                },
                .jump_back => {
                    const offset: u16 = readU16(code, frame.ip);
                    frame.ip = frame.ip + 2 - @as(usize, offset);
                },

                // ---- data structures ----
                .build_attrs => {
                    const count: u16 = readU16(code, frame.ip);
                    frame.ip += 2;
                    try self.buildAttrs(count);
                },
                .build_list => {
                    const count: u16 = readU16(code, frame.ip);
                    frame.ip += 2;
                    try self.buildList(count);
                },
                .concat_string => {
                    const b = self.pop();
                    const a = self.pop();
                    const result = try self.concatStrings(a, b);
                    try self.push(result);
                },
                .interpolate => {
                    const count: u16 = readU16(code, frame.ip);
                    frame.ip += 2;
                    // Pop count values, keep the template.
                    var i: u16 = 0;
                    while (i < count) : (i += 1) {
                        _ = self.pop();
                    }
                    // Template is below the popped values now — but since
                    // we popped everything above it, it's on top.
                    // For now: just push a placeholder.
                    try self.push(Value.string(0));
                },

                // ---- closure ----
                .closure => {
                    const ch_id: u16 = readU16(code, frame.ip);
                    frame.ip += 2;
                    const upvalue_count = code[frame.ip];
                    frame.ip += 1;
                    try self.makeClosure(ch_id, upvalue_count);
                },

                // ---- calls ----
                .call => {
                    const arg = self.pop();
                    const callee = self.pop();
                    try self.doCall(callee, arg);
                },
                .call_builtin => {
                    const idx: u16 = readU16(code, frame.ip);
                    frame.ip += 2;
                    _ = idx;
                    _ = self.pop();
                    try self.push(Value.null_val);
                },
                .tail_call => {
                    const arg = self.pop();
                    const callee = self.pop();
                    try self.doTailCall(callee, arg);
                },

                // ---- thunks ----
                .make_thunk => {
                    const closure = self.pop();
                    try self.push(try self.makeThunk(closure));
                },
                .make_cell => {
                    const val = self.pop();
                    try self.push(try self.makeCell(val));
                },

                // ---- attribute access ----
                .get_attr => {
                    const name_id: u16 = readU16(code, frame.ip);
                    frame.ip += 2;
                    const attrs_val = self.pop();
                    const result = try getAttrValue(attrs_val, @intCast(name_id));
                    try self.push(result);
                },
                .get_attr_or => {
                    const name_id: u16 = readU16(code, frame.ip);
                    frame.ip += 2;
                    const default_val = self.pop();
                    const attrs_val = self.pop();
                    const result = getAttrOrValue(attrs_val, @intCast(name_id), default_val);
                    try self.push(result);
                },

                // ---- environment (placeholders) ----
                .push_env => {},
                .pop_env => {},

                // ---- termination ----
                .ret => {
                    const result = self.pop();
                    const finished_frame = self.popFrame();
                    if (self.frames.items.len == stop_depth) {
                        return result;
                    }
                    self.sp = finished_frame.frame_base;
                    try self.push(result);
                },
                .halt => {
                    // Stop execution.
                    if (self.sp > 0) return self.pop();
                    return Value.null_val;
                },
            }
        }

        return if (self.sp > 0) self.pop() else Value.null_val;
    }

    // ---- helpers ----

    fn isTruthy(val: Value) bool {
        return switch (val.discriminant) {
            .null, .bool_false => false,
            else => true,
        };
    }

    fn valuesEqual(self: *VM, a: Value, b: Value) bool {
        const va = self.forceValue(a) catch Value.null_val;
        const vb = self.forceValue(b) catch Value.null_val;

        if (va.discriminant != vb.discriminant) return false;
        return switch (va.discriminant) {
            .null, .bool_false, .bool_true => true,
            .int => va.asInt() == vb.asInt(),
            .float => va.asFloat() == vb.asFloat(),
            .string, .path => va.asInternId() == vb.asInternId(),
            .list => va.asPtr(u8) == vb.asPtr(u8),
            .attrs => va.asPtr(u8) == vb.asPtr(u8),
            .closure, .builtin => false,
            .thunk, .cell => unreachable,
        };
    }

    const CompareResult = enum { lt, eq, gt };

    fn compareValues(self: *VM, a: Value, b: Value) CompareResult {
        const va = self.forceValue(a) catch Value.null_val;
        const vb = self.forceValue(b) catch Value.null_val;

        switch (va.discriminant) {
            .int => {
                const ai = va.asInt();
                const bi = if (vb.discriminant == .int) vb.asInt() else @as(i64, @intFromFloat(vb.asFloat()));
                if (ai < bi) return .lt;
                if (ai > bi) return .gt;
                return .eq;
            },
            .float => {
                const af = va.asFloat();
                const bf = coerceToFloat(vb);
                if (af < bf) return .lt;
                if (af > bf) return .gt;
                return .eq;
            },
            .string, .path => {
                const ia = va.asInternId();
                const ib = vb.asInternId();
                return if (ia < ib) .lt else if (ia > ib) .gt else .eq;
            },
            else => return .eq,
        }
    }

    // ---- thunk management ----

    pub fn forceThunk(self: *VM, thunk_val: Value) Value {
        return self.forceThunkFallible(thunk_val) catch Value.null_val;
    }

    fn forceValue(self: *VM, value: Value) anyerror!Value {
        return switch (value.discriminant) {
            .thunk => try self.forceThunkFallible(value),
            .cell => {
                const cell = value.asPtr(Cell);
                const forced = try self.forceValue(cell.value);
                cell.value = forced;
                return forced;
            },
            else => value,
        };
    }

    fn forceThunkFallible(self: *VM, thunk_val: Value) anyerror!Value {
        const t: *Thunk = thunk_val.asPtr(Thunk);
        switch (t.tryClaim()) {
            .already_resolved => return t.result,
            .claimed => {
                const result = try self.evalThunkClosure(t.closure);
                t.resolve(result);
                return result;
            },
            .busy => {
                return error.RecursiveThunk;
            },
        }
    }

    fn evalThunkClosure(self: *VM, closure: Value) anyerror!Value {
        if (closure.discriminant != .closure) return error.NotCallable;
        const id_ptr: *ChunkId = @ptrCast(@alignCast(closure.asPtr(u8)));
        const ch = self.registry.get(id_ptr.*) orelse return error.InvalidChunk;
        const stop_depth = self.frames.items.len;
        try self.pushFrame(ch, 0, closure.asPtr(u8));
        return self.runUntil(stop_depth);
    }

    fn makeThunk(self: *VM, closure: Value) !Value {
        const thunk = try self.allocator.create(Thunk);
        thunk.* = Thunk.init(closure);
        return Value.thunkPtr(thunk);
    }

    fn makeCell(self: *VM, val: Value) !Value {
        const cell = try self.allocator.create(Cell);
        cell.* = .{ .value = val };
        return Value.cell(cell);
    }

    // ---- data structure builders ----

    fn buildAttrs(self: *VM, count: u16) !void {
        const Attrs = extern struct {
            count: u16,
        };
        const AttrEntry = extern struct {
            name: InternId,
            value: Value,
        };

        const total = count;
        const entries_offset = std.mem.alignForward(usize, @sizeOf(Attrs), @alignOf(AttrEntry));
        const size = entries_offset + total * @sizeOf(AttrEntry);
        const ptr = self.allocator.alignedAlloc(u8, .fromByteUnits(@max(@alignOf(Attrs), @alignOf(AttrEntry))), size) catch return error.OutOfMemory;
        const attrs: *Attrs = @ptrCast(@alignCast(ptr));
        attrs.count = total;

        const entries: [*]AttrEntry = @ptrCast(@alignCast(ptr.ptr + entries_offset));
        var i: u16 = 0;
        while (i < total) : (i += 1) {
            const val = self.pop();
            const name_val = self.pop();
            entries[total - 1 - i] = .{
                .name = name_val.asInternId(),
                .value = val,
            };
        }

        try self.push(Value.attrs(ptr.ptr));
    }

    fn buildList(self: *VM, count: u16) !void {
        const List = extern struct {
            count: u32,
        };
        const items_offset = std.mem.alignForward(usize, @sizeOf(List), @alignOf(Value));
        const size = items_offset + @as(usize, count) * @sizeOf(Value);
        const ptr = self.allocator.alignedAlloc(u8, .fromByteUnits(@max(@alignOf(List), @alignOf(Value))), size) catch return error.OutOfMemory;
        const list: *List = @ptrCast(@alignCast(ptr));
        list.count = count;

        const items: [*]Value = @ptrCast(@alignCast(ptr.ptr + items_offset));
        var i: u16 = count;
        while (i > 0) {
            i -= 1;
            items[i] = self.pop();
        }

        try self.push(Value.list(ptr.ptr));
    }

    fn concatStrings(self: *VM, a: Value, b: Value) !Value {
        const id_a = a.asInternId();
        const id_b = b.asInternId();
        const s_a = self.intern.get(id_a);
        const s_b = self.intern.get(id_b);

        const buf = try self.allocator.alloc(u8, s_a.len + s_b.len);
        @memcpy(buf[0..s_a.len], s_a);
        @memcpy(buf[s_a.len..], s_b);
        defer self.allocator.free(buf);

        const new_id = try self.intern.intern(buf);
        return Value.string(new_id);
    }

    // ---- closures ----

    fn makeClosure(self: *VM, chunk_id: u16, upvalue_count: u8) !void {
        const upvalues_offset = std.mem.alignForward(usize, @sizeOf(ChunkId), @alignOf(Value));
        const closure_size = upvalues_offset + @as(usize, upvalue_count) * @sizeOf(Value);
        const ptr = self.allocator.alignedAlloc(u8, .fromByteUnits(@max(@alignOf(ChunkId), @alignOf(Value))), closure_size) catch return error.OutOfMemory;

        const chunk_id_ptr: *ChunkId = @ptrCast(@alignCast(ptr));
        chunk_id_ptr.* = chunk_id;

        const upvalues_ptr: [*]Value = @ptrCast(@alignCast(ptr.ptr + upvalues_offset));
        var i: u8 = upvalue_count;
        while (i > 0) {
            i -= 1;
            upvalues_ptr[i] = self.pop();
        }

        try self.push(Value.closure(ptr.ptr));
    }

    // ---- calls ----

    fn doCall(self: *VM, callee: Value, arg: Value) !void {
        if (callee.discriminant == .closure) {
            const id_ptr: *ChunkId = @ptrCast(@alignCast(callee.asPtr(u8)));
            const ch = self.registry.get(id_ptr.*) orelse return error.InvalidChunk;
            try self.push(arg); // arg is first local
            try self.pushFrame(ch, 1, callee.asPtr(u8));
        } else if (callee.discriminant == .builtin) {
            try self.push(arg);
            try self.push(callee);
            return;
        } else {
            return error.NotCallable;
        }
    }

    fn doTailCall(self: *VM, callee: Value, arg: Value) !void {
        if (callee.discriminant == .closure) {
            const id_ptr: *ChunkId = @ptrCast(@alignCast(callee.asPtr(u8)));
            const ch = self.registry.get(id_ptr.*) orelse return error.InvalidChunk;

            var frame = self.currentFrame();
            frame.chunk_ptr = ch;
            frame.ip = 0;
            frame.closure_ptr = callee.asPtr(u8);
            self.sp = frame.frame_base;
            try self.push(arg);
            frame.local_count = 1;
        } else {
            try self.push(callee);
            try self.push(arg);
            try self.doCall(self.stack.items[self.sp - 2], self.stack.items[self.sp - 1]);
        }
    }
};

// ---- free functions (don't take self) ----

fn readU16(code: []const u8, ip: usize) u16 {
    return @as(u16, code[ip]) | (@as(u16, code[ip + 1]) << 8);
}

fn coerceToFloat(val: Value) f64 {
    return switch (val.discriminant) {
        .int => @floatFromInt(val.asInt()),
        .float => val.asFloat(),
        else => 0.0,
    };
}

fn getAttrValue(attrs_val: Value, name_id: InternId) !Value {
    if (attrs_val.discriminant != .attrs) return error.TypeError;
    const Attrs = extern struct { count: u16 };
    const AttrEntry = extern struct { name: InternId, value: Value };

    const attrs: *Attrs = @ptrCast(@alignCast(attrs_val.asPtr(u8)));
    const entries_offset = std.mem.alignForward(usize, @sizeOf(Attrs), @alignOf(AttrEntry));
    const entries: [*]AttrEntry = @ptrCast(@alignCast(@as([*]u8, @ptrCast(attrs)) + entries_offset));

    var i: u16 = 0;
    while (i < attrs.count) : (i += 1) {
        if (entries[i].name == name_id) {
            return entries[i].value;
        }
    }
    return error.MissingAttribute;
}

fn getAttrOrValue(attrs_val: Value, name_id: InternId, default_val: Value) Value {
    return getAttrValue(attrs_val, name_id) catch default_val;
}

fn closureUpvalues(ptr: *u8) [*]Value {
    const upvalues_offset = std.mem.alignForward(usize, @sizeOf(ChunkId), @alignOf(Value));
    return @ptrCast(@alignCast(@as([*]u8, @ptrCast(ptr)) + upvalues_offset));
}
