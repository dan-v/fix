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
//!   - Atomic thunk integration for lazy evaluation

const std = @import("std");
const types = @import("types.zig");
const Value = @import("value.zig").Value;
const InternId = types.InternId;
const ChunkId = types.ChunkId;
const ObjectId = types.ObjectId;
const OpCode = @import("opcode.zig").OpCode;
const chunk = @import("chunk.zig");
const Chunk = chunk.Chunk;
const ChunkRegistry = chunk.ChunkRegistry;
const InternTable = @import("intern.zig").InternTable;
const Thunk = @import("thunk.zig").Thunk;
const Scheduler = @import("scheduler.zig").Scheduler;
const heap_mod = @import("heap.zig");
const ObjectHeap = heap_mod.ObjectHeap;
const Closure = heap_mod.Closure;
const BuiltinId = @import("builtins.zig").BuiltinId;

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
    closure_id: ?ObjectId,
};

/// Per-thread VM state. Each worker thread has one of these.
pub const VM = struct {
    allocator: std.mem.Allocator,
    /// Global chunk registry (shared across all VMs).
    registry: *const ChunkRegistry,
    /// Global intern table (shared).
    intern: *InternTable,
    /// Runtime object heap.
    heap: *ObjectHeap,
    /// Global scheduler (for spawning work).
    scheduler: *Scheduler,
    /// Cached evaluator-owned builtins attrset.
    builtins: Value,
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
        heap: *ObjectHeap,
        scheduler: *Scheduler,
        builtins: Value,
        worker_id: u8,
    ) !VM {
        return .{
            .allocator = allocator,
            .registry = registry,
            .intern = intern,
            .heap = heap,
            .scheduler = scheduler,
            .builtins = builtins,
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

    pub fn forceListItem(self: *VM, list_val: Value, index: usize) !Value {
        if (list_val.discriminant != .list) return error.TypeError;
        return self.forceValue(try self.heap.getListItem(list_val.asObjectId(), index));
    }

    // ---- frame management ----

    fn pushFrame(self: *VM, ch: *const Chunk, arg_count: u32, closure_id: ?ObjectId) !void {
        if (self.frames.items.len >= types.MAX_FRAMES) return error.FrameOverflow;
        if (arg_count > ch.local_count) return error.InvalidCallFrame;
        const frame_base = self.sp - arg_count;
        const reserved = @as(u32, ch.local_count) - arg_count;
        var i: u32 = 0;
        while (i < reserved) : (i += 1) {
            try self.push(Value.null_val);
        }
        try self.frames.append(self.allocator, .{
            .chunk_ptr = ch,
            .ip = 0,
            .frame_base = frame_base,
            .local_count = ch.local_count,
            .closure_id = closure_id,
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
            if (self.stack.items.len >= types.VM_STACK_CAP) return error.StackOverflow;
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
                    const closure_id = frame.closure_id orelse return error.MissingClosure;
                    const closure = try self.getClosureById(closure_id);
                    try self.push(closure.upvalues[slot]);
                },

                .set_local => {
                    const slot = code[frame.ip];
                    frame.ip += 1;
                    const val = self.pop();
                    self.setStack(frame.frame_base + slot, val);
                },

                .set_cell_local => {
                    const slot = code[frame.ip];
                    frame.ip += 1;
                    const val = self.pop();
                    const cell_val = self.stack.items[frame.frame_base + slot];
                    if (cell_val.discriminant != .cell) return error.TypeError;
                    try self.heap.setCellValue(cell_val.asObjectId(), val);
                },

                .get_upvalue => {
                    const slot = code[frame.ip];
                    frame.ip += 1;
                    const closure_id = frame.closure_id orelse return error.MissingClosure;
                    const closure = try self.getClosureById(closure_id);
                    const val = try self.forceValue(closure.upvalues[slot]);
                    try self.push(val);
                },

                // ---- integer arithmetic ----
                .add_int => {
                    const b = self.pop();
                    const a = self.pop();
                    if (a.discriminant == .int and b.discriminant == .int) {
                        try self.push(Value.int(a.asInt() + b.asInt()));
                    } else if (isNumeric(a) and isNumeric(b)) {
                        try self.push(Value.float(try coerceToFloat(a) + try coerceToFloat(b)));
                    } else if (a.discriminant == .string and b.discriminant == .string) {
                        try self.push(try self.concatStrings(a, b));
                    } else {
                        return error.TypeError;
                    }
                },
                .sub_int => {
                    const b = self.pop();
                    const a = self.pop();
                    if (a.discriminant == .int and b.discriminant == .int) {
                        try self.push(Value.int(a.asInt() - b.asInt()));
                    } else if (isNumeric(a) and isNumeric(b)) {
                        try self.push(Value.float(try coerceToFloat(a) - try coerceToFloat(b)));
                    } else {
                        return error.TypeError;
                    }
                },
                .mul_int => {
                    const b = self.pop();
                    const a = self.pop();
                    if (a.discriminant == .int and b.discriminant == .int) {
                        try self.push(Value.int(a.asInt() * b.asInt()));
                    } else if (isNumeric(a) and isNumeric(b)) {
                        try self.push(Value.float(try coerceToFloat(a) * try coerceToFloat(b)));
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
                    } else if (isNumeric(a) and isNumeric(b)) {
                        try self.push(Value.float(try coerceToFloat(a) / try coerceToFloat(b)));
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
                    try self.push(Value.float(try coerceToFloat(a) + try coerceToFloat(b)));
                },
                .sub_float => {
                    const b = self.pop();
                    const a = self.pop();
                    try self.push(Value.float(try coerceToFloat(a) - try coerceToFloat(b)));
                },
                .mul_float => {
                    const b = self.pop();
                    const a = self.pop();
                    try self.push(Value.float(try coerceToFloat(a) * try coerceToFloat(b)));
                },
                .div_float => {
                    const b = self.pop();
                    const a = self.pop();
                    try self.push(Value.float(try coerceToFloat(a) / try coerceToFloat(b)));
                },
                .negate_float => {
                    const a = self.pop();
                    try self.push(Value.float(-try coerceToFloat(a)));
                },

                // ---- comparison ----
                .eq => {
                    const b = self.pop();
                    const a = self.pop();
                    try self.push(Value.boolVal(try self.valuesEqual(a, b)));
                },
                .neq => {
                    const b = self.pop();
                    const a = self.pop();
                    try self.push(Value.boolVal(!try self.valuesEqual(a, b)));
                },
                .lt => {
                    const b = self.pop();
                    const a = self.pop();
                    try self.push(Value.boolVal(try self.compareValues(a, b) == .lt));
                },
                .lte => {
                    const b = self.pop();
                    const a = self.pop();
                    const r = try self.compareValues(a, b);
                    try self.push(Value.boolVal(r == .lt or r == .eq));
                },
                .gt => {
                    const b = self.pop();
                    const a = self.pop();
                    try self.push(Value.boolVal(try self.compareValues(a, b) == .gt));
                },
                .gte => {
                    const b = self.pop();
                    const a = self.pop();
                    const r = try self.compareValues(a, b);
                    try self.push(Value.boolVal(r == .gt or r == .eq));
                },

                // ---- logical ----
                .not => {
                    const a = self.pop();
                    try self.push(Value.boolVal(!try self.expectBool(a)));
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
                    if (!try self.expectBool(cond)) {
                        frame.ip += @as(usize, offset);
                    }
                },
                .fail_assertion => return error.AssertionFailed,
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
                .merge_attrs => {
                    const right = self.pop();
                    const left = self.pop();
                    try self.push(try self.mergeAttrs(left, right));
                },
                .concat_lists => {
                    const right = self.pop();
                    const left = self.pop();
                    try self.push(try self.concatLists(left, right));
                },
                .push_builtins => try self.push(self.builtins),
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
                    const result = try self.getAttrValue(attrs_val, @intCast(name_id));
                    try self.push(result);
                },
                .get_attr_path_or => {
                    const segment_count = code[frame.ip];
                    frame.ip += 1;
                    const names_start = frame.ip;
                    frame.ip += @as(usize, segment_count) * 2;
                    const default_val = self.pop();
                    const attrs_val = self.pop();
                    const result = try self.getAttrPathOrValue(attrs_val, default_val, code[names_start..frame.ip]);
                    try self.push(result);
                },
                .has_attr_path => {
                    const segment_count = code[frame.ip];
                    frame.ip += 1;
                    const names_start = frame.ip;
                    frame.ip += @as(usize, segment_count) * 2;
                    const attrs_val = self.pop();
                    try self.push(Value.boolVal(try self.hasAttrPath(attrs_val, code[names_start..frame.ip])));
                },
                .validate_attrs => {
                    const allow_extra = code[frame.ip] != 0;
                    frame.ip += 1;
                    const expected_count = readU16(code, frame.ip);
                    frame.ip += 2;
                    const names_start = frame.ip;
                    frame.ip += @as(usize, expected_count) * 2;
                    const attrs_val = self.pop();
                    try self.validateAttrs(attrs_val, allow_extra, code[names_start..frame.ip]);
                },
                .lookup_with => {
                    const name_id: InternId = @intCast(readU16(code, frame.ip));
                    frame.ip += 2;
                    const scope_count = code[frame.ip];
                    frame.ip += 1;
                    try self.lookupWith(name_id, scope_count);
                },
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

    fn expectBool(self: *VM, val: Value) !bool {
        const forced = try self.forceValue(val);
        return switch (forced.discriminant) {
            .bool_false => false,
            .bool_true => true,
            else => error.TypeError,
        };
    }

    fn valuesEqual(self: *VM, a: Value, b: Value) anyerror!bool {
        const va = try self.forceValue(a);
        const vb = try self.forceValue(b);

        if (isNumeric(va) and isNumeric(vb)) {
            return try coerceToFloat(va) == try coerceToFloat(vb);
        }

        if (va.discriminant != vb.discriminant) return false;
        return switch (va.discriminant) {
            .null, .bool_false, .bool_true => true,
            .int => va.asInt() == vb.asInt(),
            .float => va.asFloat() == vb.asFloat(),
            .string, .path => va.asInternId() == vb.asInternId(),
            .list => try self.listsEqual(va.asObjectId(), vb.asObjectId()),
            .attrs => try self.attrsEqual(va.asObjectId(), vb.asObjectId()),
            .closure => false,
            .builtin => va.asBuiltinId() == vb.asBuiltinId(),
            .builtin_closure => false,
            .thunk, .cell => unreachable,
        };
    }

    const CompareResult = enum { lt, eq, gt };

    fn listsEqual(self: *VM, a_id: ObjectId, b_id: ObjectId) anyerror!bool {
        const a_items = try self.heap.getList(a_id);
        const b_items = try self.heap.getList(b_id);
        if (a_items.len != b_items.len) return false;

        for (a_items, b_items) |a_item, b_item| {
            if (!try self.valuesEqual(a_item, b_item)) return false;
        }
        return true;
    }

    fn attrsEqual(self: *VM, a_id: ObjectId, b_id: ObjectId) anyerror!bool {
        const a_entries = try self.heap.getAttrs(a_id);
        const b_entries = try self.heap.getAttrs(b_id);
        if (a_entries.len != b_entries.len) return false;

        for (a_entries, b_entries) |a_entry, b_entry| {
            if (a_entry.name != b_entry.name) return false;
            if (!try self.valuesEqual(a_entry.value, b_entry.value)) return false;
        }
        return true;
    }

    fn compareValues(self: *VM, a: Value, b: Value) !CompareResult {
        const va = try self.forceValue(a);
        const vb = try self.forceValue(b);

        switch (va.discriminant) {
            .int => {
                const ai = va.asInt();
                if (vb.discriminant == .float) {
                    const af: f64 = @floatFromInt(ai);
                    const bf = vb.asFloat();
                    if (af < bf) return .lt;
                    if (af > bf) return .gt;
                    return .eq;
                }
                if (vb.discriminant != .int) return error.TypeError;
                if (ai < vb.asInt()) return .lt;
                if (ai > vb.asInt()) return .gt;
                return .eq;
            },
            .float => {
                const af = va.asFloat();
                const bf = try coerceToFloat(vb);
                if (af < bf) return .lt;
                if (af > bf) return .gt;
                return .eq;
            },
            .string, .path => {
                if (vb.discriminant != va.discriminant) return error.TypeError;
                return switch (std.mem.order(u8, self.intern.get(va.asInternId()), self.intern.get(vb.asInternId()))) {
                    .lt => .lt,
                    .eq => .eq,
                    .gt => .gt,
                };
            },
            else => return error.TypeError,
        }
    }

    // ---- thunk management ----

    pub fn forceThunk(self: *VM, thunk_val: Value) !Value {
        return self.forceThunkFallible(thunk_val);
    }

    fn forceValue(self: *VM, value: Value) anyerror!Value {
        return switch (value.discriminant) {
            .thunk => try self.forceThunkFallible(value),
            .cell => {
                const cell_id = value.asObjectId();
                const raw = try self.heap.getCellValue(cell_id);
                const forced = try self.forceValue(raw);
                try self.heap.setCellValue(cell_id, forced);
                return forced;
            },
            else => value,
        };
    }

    fn forceThunkFallible(self: *VM, thunk_val: Value) anyerror!Value {
        const thunk_id = thunk_val.asObjectId();
        var closure: Value = undefined;
        const claimed = try self.heap.getThunk(thunk_id);
        switch (claimed.tryClaim()) {
            .already_resolved => return claimed.result,
            .claimed => closure = claimed.closure,
            .busy => return error.RecursiveThunk,
        }

        const result = self.evalThunkClosure(closure) catch |err| {
            const failed = try self.heap.getThunk(thunk_id);
            failed.reset();
            return err;
        };
        const resolved = try self.heap.getThunk(thunk_id);
        resolved.resolve(result);
        return result;
    }

    fn evalThunkClosure(self: *VM, closure_val: Value) anyerror!Value {
        if (closure_val.discriminant != .closure) return error.NotCallable;
        const closure_id = closure_val.asObjectId();
        const closure = try self.getClosureById(closure_id);
        const ch = self.registry.get(closure.chunk_id) orelse return error.InvalidChunk;
        const stop_depth = self.frames.items.len;
        try self.pushFrame(ch, 0, closure_id);
        return self.runUntil(stop_depth);
    }

    fn makeThunk(self: *VM, closure: Value) !Value {
        const id = try self.heap.addThunk(Thunk.init(closure));
        return Value.thunk(id);
    }

    fn makeCell(self: *VM, val: Value) !Value {
        const id = try self.heap.addCell(.{ .value = val });
        return Value.cell(id);
    }

    // ---- data structure builders ----

    fn buildAttrs(self: *VM, count: u16) !void {
        const value_count: u32 = @as(u32, count) * 2;
        const start = self.sp - value_count;
        const id = try self.heap.addAttrsFromStackPairs(self.stack.items[start..self.sp]);
        self.sp = start;
        try self.push(Value.attrs(id));
    }

    fn buildList(self: *VM, count: u16) !void {
        const start = self.sp - count;
        const id = try self.heap.addList(self.stack.items[start..self.sp]);
        self.sp = start;
        try self.push(Value.list(id));
    }

    fn mergeAttrs(self: *VM, left: Value, right: Value) !Value {
        if (left.discriminant != .attrs or right.discriminant != .attrs) return error.TypeError;
        return Value.attrs(try self.heap.addMergedAttrs(left.asObjectId(), right.asObjectId()));
    }

    fn concatLists(self: *VM, left: Value, right: Value) !Value {
        if (left.discriminant != .list or right.discriminant != .list) return error.TypeError;
        return Value.list(try self.heap.addConcatenatedLists(left.asObjectId(), right.asObjectId()));
    }

    fn concatStrings(self: *VM, a: Value, b: Value) !Value {
        const s_a = self.intern.get(a.asInternId());
        const s_b = self.intern.get(b.asInternId());

        const buf = try self.allocator.alloc(u8, s_a.len + s_b.len);
        defer self.allocator.free(buf);

        @memcpy(buf[0..s_a.len], s_a);
        @memcpy(buf[s_a.len..], s_b);

        return Value.string(try self.intern.intern(buf));
    }

    // ---- closures ----

    fn getClosureById(self: *VM, closure_id: ObjectId) !Closure {
        return self.heap.getClosure(closure_id);
    }

    fn makeClosure(self: *VM, chunk_id: u16, upvalue_count: u8) !void {
        const start = self.sp - upvalue_count;
        const id = try self.heap.addClosure(chunk_id, self.stack.items[start..self.sp]);
        self.sp = start;
        try self.push(Value.closure(id));
    }

    // ---- calls ----

    fn doCall(self: *VM, callee: Value, arg: Value) !void {
        if (callee.discriminant == .closure) {
            const closure_id = callee.asObjectId();
            const closure = try self.getClosureById(closure_id);
            const ch = self.registry.get(closure.chunk_id) orelse return error.InvalidChunk;
            try self.push(arg); // arg is first local
            try self.pushFrame(ch, 1, closure_id);
        } else if (callee.discriminant == .builtin) {
            try self.push(try self.callBuiltin(callee, arg));
        } else if (callee.discriminant == .builtin_closure) {
            try self.push(try self.callBuiltinClosure(callee, arg));
        } else {
            return error.NotCallable;
        }
    }

    fn callBuiltin(self: *VM, callee: Value, arg: Value) !Value {
        return switch (callee.asBuiltinId()) {
            @intFromEnum(BuiltinId.toString) => self.builtinToString(arg),
            @intFromEnum(BuiltinId.isAttrs) => self.builtinTypePredicate(arg, .attrs),
            @intFromEnum(BuiltinId.isList) => self.builtinTypePredicate(arg, .list),
            @intFromEnum(BuiltinId.isString) => self.builtinTypePredicate(arg, .string),
            @intFromEnum(BuiltinId.isInt) => self.builtinTypePredicate(arg, .int),
            @intFromEnum(BuiltinId.isBool) => self.builtinIsBool(arg),
            @intFromEnum(BuiltinId.isNull) => self.builtinTypePredicate(arg, .null),
            @intFromEnum(BuiltinId.isFloat) => self.builtinTypePredicate(arg, .float),
            @intFromEnum(BuiltinId.isFunction) => self.builtinIsFunction(arg),
            @intFromEnum(BuiltinId.isPath) => self.builtinTypePredicate(arg, .path),
            @intFromEnum(BuiltinId.length) => self.builtinLength(arg),
            @intFromEnum(BuiltinId.head) => self.builtinHead(arg),
            @intFromEnum(BuiltinId.tail) => self.builtinTail(arg),
            @intFromEnum(BuiltinId.attrNames) => self.builtinAttrNames(arg),
            @intFromEnum(BuiltinId.attrValues) => self.builtinAttrValues(arg),
            @intFromEnum(BuiltinId.typeOf) => self.builtinTypeOf(arg),
            @intFromEnum(BuiltinId.concatLists) => self.builtinConcatLists(arg),
            @intFromEnum(BuiltinId.listToAttrs) => self.builtinListToAttrs(arg),
            @intFromEnum(BuiltinId.hasAttr),
            @intFromEnum(BuiltinId.getAttr),
            @intFromEnum(BuiltinId.elemAt),
            @intFromEnum(BuiltinId.removeAttrs),
            @intFromEnum(BuiltinId.intersectAttrs),
            @intFromEnum(BuiltinId.elem),
            => self.makeBuiltinClosure(callee.asBuiltinId(), arg),
            else => error.InvalidBuiltin,
        };
    }

    fn makeBuiltinClosure(self: *VM, builtin_id: u16, arg: Value) !Value {
        return Value.builtinClosure(try self.heap.addBuiltinClosure(.{
            .builtin_id = builtin_id,
            .arg = arg,
        }));
    }

    fn callBuiltinClosure(self: *VM, callee: Value, arg: Value) !Value {
        const partial = try self.heap.getBuiltinClosure(callee.asObjectId());
        return switch (partial.builtin_id) {
            @intFromEnum(BuiltinId.hasAttr) => self.builtinHasAttr(partial.arg, arg),
            @intFromEnum(BuiltinId.getAttr) => self.builtinGetAttr(partial.arg, arg),
            @intFromEnum(BuiltinId.elemAt) => self.builtinElemAt(partial.arg, arg),
            @intFromEnum(BuiltinId.removeAttrs) => self.builtinRemoveAttrs(partial.arg, arg),
            @intFromEnum(BuiltinId.intersectAttrs) => self.builtinIntersectAttrs(partial.arg, arg),
            @intFromEnum(BuiltinId.elem) => self.builtinElem(partial.arg, arg),
            else => error.InvalidBuiltin,
        };
    }

    fn builtinTypePredicate(self: *VM, arg: Value, expected: @import("value.zig").ValueType) !Value {
        const value = try self.forceValue(arg);
        return Value.boolVal(value.discriminant == expected);
    }

    fn builtinIsBool(self: *VM, arg: Value) !Value {
        const value = try self.forceValue(arg);
        return Value.boolVal(value.isBool());
    }

    fn builtinIsFunction(self: *VM, arg: Value) !Value {
        const value = try self.forceValue(arg);
        return Value.boolVal(value.discriminant == .closure or value.discriminant == .builtin or value.discriminant == .builtin_closure);
    }

    fn builtinTypeOf(self: *VM, arg: Value) !Value {
        const value = try self.forceValue(arg);
        const name: []const u8 = switch (value.discriminant) {
            .null => "null",
            .bool_false, .bool_true => "bool",
            .int => "int",
            .float => "float",
            .string => "string",
            .path => "path",
            .list => "list",
            .attrs => "set",
            .closure, .builtin, .builtin_closure => "lambda",
            .thunk, .cell => unreachable,
        };
        return Value.string(try self.intern.intern(name));
    }

    fn builtinLength(self: *VM, arg: Value) !Value {
        const value = try self.forceValue(arg);
        if (value.discriminant != .list) return error.TypeError;
        return Value.int(@intCast(try self.heap.getListLen(value.asObjectId())));
    }

    fn builtinHead(self: *VM, arg: Value) !Value {
        const value = try self.forceValue(arg);
        if (value.discriminant != .list) return error.TypeError;
        const items = try self.heap.getList(value.asObjectId());
        if (items.len == 0) return error.IndexOutOfBounds;
        return self.forceValue(items[0]);
    }

    fn builtinTail(self: *VM, arg: Value) !Value {
        const value = try self.forceValue(arg);
        if (value.discriminant != .list) return error.TypeError;
        const items = try self.heap.getList(value.asObjectId());
        if (items.len == 0) return error.IndexOutOfBounds;
        return Value.list(try self.heap.addList(items[1..]));
    }

    fn builtinConcatLists(self: *VM, arg: Value) !Value {
        const value = try self.forceValue(arg);
        if (value.discriminant != .list) return error.TypeError;

        var out: std.ArrayListUnmanaged(Value) = .empty;
        defer out.deinit(self.allocator);

        const lists = try self.heap.getList(value.asObjectId());
        for (lists) |list_item| {
            const list = try self.forceValue(list_item);
            if (list.discriminant != .list) return error.TypeError;
            try out.appendSlice(self.allocator, try self.heap.getList(list.asObjectId()));
        }

        return Value.list(try self.heap.addList(out.items));
    }

    fn builtinListToAttrs(self: *VM, arg: Value) !Value {
        const value = try self.forceValue(arg);
        if (value.discriminant != .list) return error.TypeError;

        const name_id = try self.intern.intern("name");
        const value_id = try self.intern.intern("value");
        var entries: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
        defer entries.deinit(self.allocator);

        const items = try self.heap.getList(value.asObjectId());
        for (items) |item| {
            const item_value = try self.forceValue(item);
            if (item_value.discriminant != .attrs) return error.TypeError;

            const name_value = try self.forceValue(try self.heap.getAttrValue(item_value.asObjectId(), name_id));
            if (name_value.discriminant != .string) return error.TypeError;
            if (attrEntryNameIndex(entries.items, name_value.asInternId()) != null) continue;

            try entries.append(self.allocator, .{
                .name = name_value.asInternId(),
                .value = try self.heap.getAttrValue(item_value.asObjectId(), value_id),
            });
        }

        return Value.attrs(try self.heap.addAttrs(entries.items));
    }

    fn attrEntryNameIndex(entries: []const heap_mod.AttrEntry, name: InternId) ?usize {
        for (entries, 0..) |entry, i| {
            if (entry.name == name) return i;
        }
        return null;
    }

    fn builtinAttrNames(self: *VM, arg: Value) !Value {
        const entries = try self.sortedAttrEntries(arg);
        defer self.allocator.free(entries);

        const values = try self.allocator.alloc(Value, entries.len);
        defer self.allocator.free(values);

        for (entries, values) |entry, *value| {
            value.* = Value.string(entry.name);
        }
        return Value.list(try self.heap.addList(values));
    }

    fn builtinAttrValues(self: *VM, arg: Value) !Value {
        const entries = try self.sortedAttrEntries(arg);
        defer self.allocator.free(entries);

        const values = try self.allocator.alloc(Value, entries.len);
        defer self.allocator.free(values);

        for (entries, values) |entry, *value| {
            value.* = entry.value;
        }
        return Value.list(try self.heap.addList(values));
    }

    fn sortedAttrEntries(self: *VM, arg: Value) ![]heap_mod.AttrEntry {
        const value = try self.forceValue(arg);
        if (value.discriminant != .attrs) return error.TypeError;

        const entries = try self.heap.getAttrs(value.asObjectId());
        const sorted = try self.allocator.dupe(heap_mod.AttrEntry, entries);
        std.mem.sort(heap_mod.AttrEntry, sorted, self, attrEntryNameLessThan);
        return sorted;
    }

    fn builtinHasAttr(self: *VM, name_arg: Value, attrs_arg: Value) !Value {
        const name = try self.forceValue(name_arg);
        const attrs = try self.forceValue(attrs_arg);
        if (name.discriminant != .string or attrs.discriminant != .attrs) return error.TypeError;

        _ = self.heap.getAttrValue(attrs.asObjectId(), name.asInternId()) catch |err| switch (err) {
            error.MissingAttribute => return Value.boolVal(false),
            else => return err,
        };
        return Value.boolVal(true);
    }

    fn builtinGetAttr(self: *VM, name_arg: Value, attrs_arg: Value) !Value {
        const name = try self.forceValue(name_arg);
        const attrs = try self.forceValue(attrs_arg);
        if (name.discriminant != .string or attrs.discriminant != .attrs) return error.TypeError;

        return self.forceValue(try self.heap.getAttrValue(attrs.asObjectId(), name.asInternId()));
    }

    fn builtinElemAt(self: *VM, list_arg: Value, index_arg: Value) !Value {
        const list = try self.forceValue(list_arg);
        const index = try self.forceValue(index_arg);
        if (list.discriminant != .list or index.discriminant != .int) return error.TypeError;
        if (index.asInt() < 0) return error.IndexOutOfBounds;

        const items = try self.heap.getList(list.asObjectId());
        const i: usize = @intCast(index.asInt());
        if (i >= items.len) return error.IndexOutOfBounds;
        return self.forceValue(items[i]);
    }

    fn builtinElem(self: *VM, needle: Value, list_arg: Value) !Value {
        const list = try self.forceValue(list_arg);
        if (list.discriminant != .list) return error.TypeError;

        const items = try self.heap.getList(list.asObjectId());
        for (items) |item| {
            if (try self.valuesEqual(needle, item)) return Value.boolVal(true);
        }
        return Value.boolVal(false);
    }

    fn builtinRemoveAttrs(self: *VM, attrs_arg: Value, names_arg: Value) !Value {
        const attrs = try self.forceValue(attrs_arg);
        const names = try self.forceValue(names_arg);
        if (attrs.discriminant != .attrs or names.discriminant != .list) return error.TypeError;

        var entries: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
        defer entries.deinit(self.allocator);

        const attr_entries = try self.heap.getAttrs(attrs.asObjectId());
        for (attr_entries) |entry| {
            if (!try self.stringListContainsIntern(names.asObjectId(), entry.name)) {
                try entries.append(self.allocator, entry);
            }
        }

        return Value.attrs(try self.heap.addAttrs(entries.items));
    }

    fn builtinIntersectAttrs(self: *VM, left_arg: Value, right_arg: Value) !Value {
        const left = try self.forceValue(left_arg);
        const right = try self.forceValue(right_arg);
        if (left.discriminant != .attrs or right.discriminant != .attrs) return error.TypeError;

        var entries: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
        defer entries.deinit(self.allocator);

        const right_entries = try self.heap.getAttrs(right.asObjectId());
        for (right_entries) |entry| {
            _ = self.heap.getAttrValue(left.asObjectId(), entry.name) catch |err| switch (err) {
                error.MissingAttribute => continue,
                else => return err,
            };
            try entries.append(self.allocator, entry);
        }

        return Value.attrs(try self.heap.addAttrs(entries.items));
    }

    fn stringListContainsIntern(self: *VM, list_id: ObjectId, needle: InternId) !bool {
        const items = try self.heap.getList(list_id);
        for (items) |item| {
            const value = try self.forceValue(item);
            if (value.discriminant != .string) return error.TypeError;
            if (value.asInternId() == needle) return true;
        }
        return false;
    }

    fn attrEntryNameLessThan(self: *VM, a: heap_mod.AttrEntry, b: heap_mod.AttrEntry) bool {
        return std.mem.lessThan(u8, self.intern.get(a.name), self.intern.get(b.name));
    }

    fn builtinToString(self: *VM, arg: Value) !Value {
        const value = try self.forceValue(arg);
        switch (value.discriminant) {
            .string => return value,
            .path => return Value.string(value.asInternId()),
            .int => {
                const s = try std.fmt.allocPrint(self.allocator, "{}", .{value.asInt()});
                defer self.allocator.free(s);
                return Value.string(try self.intern.intern(s));
            },
            .float => {
                const s = try std.fmt.allocPrint(self.allocator, "{d}", .{value.asFloat()});
                defer self.allocator.free(s);
                return Value.string(try self.intern.intern(s));
            },
            .bool_false, .null => return Value.string(try self.intern.intern("")),
            .bool_true => return Value.string(try self.intern.intern("1")),
            else => return error.TypeError,
        }
    }

    fn getAttrValue(self: *VM, attrs_val: Value, name_id: InternId) !Value {
        if (attrs_val.discriminant != .attrs) return error.TypeError;
        return self.forceValue(try self.heap.getAttrValue(attrs_val.asObjectId(), name_id));
    }

    fn getAttrPathOrValue(self: *VM, attrs_val: Value, default_val: Value, encoded_names: []const u8) !Value {
        var current = try self.forceValue(attrs_val);
        var offset: usize = 0;
        while (offset < encoded_names.len) : (offset += 2) {
            if (current.discriminant != .attrs) return error.TypeError;
            const name_id: InternId = @intCast(readU16(encoded_names, offset));
            current = self.heap.getAttrValue(current.asObjectId(), name_id) catch |err| switch (err) {
                error.MissingAttribute => return self.forceValue(default_val),
                else => return err,
            };
            current = try self.forceValue(current);
        }
        return current;
    }

    fn hasAttrPath(self: *VM, attrs_val: Value, encoded_names: []const u8) !bool {
        var current = try self.forceValue(attrs_val);
        var offset: usize = 0;
        while (offset < encoded_names.len) : (offset += 2) {
            if (current.discriminant != .attrs) return false;
            const name_id: InternId = @intCast(readU16(encoded_names, offset));
            const attr = self.heap.getAttrValue(current.asObjectId(), name_id) catch |err| switch (err) {
                error.MissingAttribute => return false,
                else => return err,
            };
            if (offset + 2 >= encoded_names.len) return true;
            current = try self.forceValue(attr);
        }
        return false;
    }

    fn validateAttrs(self: *VM, attrs_val: Value, allow_extra: bool, encoded_names: []const u8) !void {
        const value = try self.forceValue(attrs_val);
        if (value.discriminant != .attrs) return error.TypeError;
        if (allow_extra) return;

        const entries = try self.heap.getAttrs(value.asObjectId());
        for (entries) |entry| {
            var found = false;
            var offset: usize = 0;
            while (offset < encoded_names.len) : (offset += 2) {
                const name_id: InternId = @intCast(readU16(encoded_names, offset));
                if (entry.name == name_id) {
                    found = true;
                    break;
                }
            }
            if (!found) return error.UnexpectedAttribute;
        }
    }

    fn lookupWith(self: *VM, name_id: InternId, scope_count: u8) !void {
        const start = self.sp - scope_count;
        const scopes = self.stack.items[start..self.sp];

        for (scopes) |scope| {
            const attrs_val = try self.forceValue(scope);
            if (attrs_val.discriminant != .attrs) return error.TypeError;

            const attr_val = self.heap.getAttrValue(attrs_val.asObjectId(), name_id) catch |err| switch (err) {
                error.MissingAttribute => continue,
                else => return err,
            };

            const result = try self.forceValue(attr_val);
            self.sp = start;
            try self.push(result);
            return;
        }

        self.sp = start;
        return error.UndefinedVariable;
    }
};

// ---- free functions (don't take self) ----

fn readU16(code: []const u8, ip: usize) u16 {
    return @as(u16, code[ip]) | (@as(u16, code[ip + 1]) << 8);
}

fn coerceToFloat(val: Value) !f64 {
    return switch (val.discriminant) {
        .int => @floatFromInt(val.asInt()),
        .float => val.asFloat(),
        else => error.TypeError,
    };
}

fn isNumeric(val: Value) bool {
    return val.discriminant == .int or val.discriminant == .float;
}
