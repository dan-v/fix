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
const FileCache = @import("file_cache.zig").FileCache;
const builtins_mod = @import("builtins.zig");
const BuiltinId = builtins_mod.BuiltinId;
const derivation = @import("derivation.zig");
const numeric = @import("runtime/numeric.zig");
const path_ops = @import("runtime/paths.zig");
const nix_hash = @import("runtime/hash.zig");

fn searchPathSuffix(prefix: []const u8, name: []const u8) ?[]const u8 {
    if (prefix.len == 0) return name;
    if (std.mem.eql(u8, prefix, name)) return "";
    if (name.len <= prefix.len or name[prefix.len] != '/') return null;
    if (!std.mem.eql(u8, prefix, name[0..prefix.len])) return null;
    return name[prefix.len + 1 ..];
}

fn firstReplacementAt(input: []const u8, needles: []const []const u8) ?usize {
    for (needles, 0..) |needle, i| {
        if (std.mem.startsWith(u8, input, needle)) return i;
    }
    return null;
}

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

pub const ImportHost = struct {
    context: *anyopaque,
    import_value: *const fn (*anyopaque, []const u8) anyerror!Value,
    find_file: *const fn (*anyopaque, []const u8) anyerror!Value,
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
    /// Evaluator-owned filesystem cache.
    files: *FileCache,
    /// Global scheduler (for spawning work).
    scheduler: *Scheduler,
    import_host: ?ImportHost,
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
        files: *FileCache,
        scheduler: *Scheduler,
        import_host: ?ImportHost,
        builtins: Value,
        worker_id: u8,
    ) !VM {
        return .{
            .allocator = allocator,
            .registry = registry,
            .intern = intern,
            .heap = heap,
            .files = files,
            .scheduler = scheduler,
            .import_host = import_host,
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
                    if (a.discriminant == .string and b.discriminant == .string) {
                        try self.push(try self.concatStrings(a, b));
                    } else {
                        try self.push(try numeric.add(a, b));
                    }
                },
                .sub_int => {
                    const b = self.pop();
                    const a = self.pop();
                    try self.push(try numeric.sub(a, b));
                },
                .mul_int => {
                    const b = self.pop();
                    const a = self.pop();
                    try self.push(try numeric.mul(a, b));
                },
                .div_int => {
                    const b = self.pop();
                    const a = self.pop();
                    try self.push(try numeric.div(a, b));
                },
                .negate_int => {
                    const a = self.pop();
                    try self.push(try numeric.negate(a));
                },

                // ---- float arithmetic ----
                .add_float => {
                    const b = self.pop();
                    const a = self.pop();
                    try self.push(Value.float(try numeric.toFloat(a) + try numeric.toFloat(b)));
                },
                .sub_float => {
                    const b = self.pop();
                    const a = self.pop();
                    try self.push(Value.float(try numeric.toFloat(a) - try numeric.toFloat(b)));
                },
                .mul_float => {
                    const b = self.pop();
                    const a = self.pop();
                    try self.push(Value.float(try numeric.toFloat(a) * try numeric.toFloat(b)));
                },
                .div_float => {
                    const b = self.pop();
                    const a = self.pop();
                    try self.push(Value.float(try numeric.toFloat(a) / try numeric.toFloat(b)));
                },
                .negate_float => {
                    const a = self.pop();
                    try self.push(Value.float(-try numeric.toFloat(a)));
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
                .find_file => {
                    const name_id: u16 = readU16(code, frame.ip);
                    frame.ip += 2;
                    const host = self.import_host orelse return error.SearchPathUnavailable;
                    try self.push(try host.find_file(host.context, self.intern.get(@intCast(name_id))));
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
                        self.sp = finished_frame.frame_base;
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

        if (numeric.isNumeric(va) and numeric.isNumeric(vb)) {
            return try numeric.toFloat(va) == try numeric.toFloat(vb);
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
                const bf = try numeric.toFloat(vb);
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
            try self.push(try self.applyBuiltin(callee.asBuiltinId(), &.{arg}));
        } else if (callee.discriminant == .builtin_closure) {
            try self.push(try self.applyBuiltinClosure(callee, arg));
        } else {
            return error.NotCallable;
        }
    }

    fn callValue(self: *VM, callee: Value, arg: Value) !Value {
        if (callee.discriminant == .closure) {
            const closure_id = callee.asObjectId();
            const closure = try self.getClosureById(closure_id);
            const ch = self.registry.get(closure.chunk_id) orelse return error.InvalidChunk;
            const stop_depth = self.frames.items.len;
            try self.push(arg);
            try self.pushFrame(ch, 1, closure_id);
            return self.runUntil(stop_depth);
        }
        if (callee.discriminant == .builtin) {
            return self.applyBuiltin(callee.asBuiltinId(), &.{arg});
        }
        if (callee.discriminant == .builtin_closure) {
            return self.applyBuiltinClosure(callee, arg);
        }
        return error.NotCallable;
    }

    fn applyBuiltinClosure(self: *VM, callee: Value, arg: Value) !Value {
        const closure = try self.heap.getBuiltinClosure(callee.asObjectId());
        var args: [8]Value = undefined;
        if (closure.args.len + 1 > args.len) return error.TooManyArguments;
        @memcpy(args[0..closure.args.len], closure.args);
        args[closure.args.len] = arg;
        return self.applyBuiltin(closure.builtin_id, args[0 .. closure.args.len + 1]);
    }

    fn applyBuiltin(self: *VM, builtin_id: u16, args: []const Value) !Value {
        const id: BuiltinId = @enumFromInt(builtin_id);
        const arity = builtins_mod.arity(id);
        if (args.len < arity) return self.makeBuiltinClosure(builtin_id, args);
        if (args.len > arity) return error.TooManyArguments;

        return switch (id) {
            .toString => self.builtinToString(args[0]),
            .isAttrs => self.builtinTypePredicate(args[0], .attrs),
            .isList => self.builtinTypePredicate(args[0], .list),
            .isString => self.builtinTypePredicate(args[0], .string),
            .isInt => self.builtinTypePredicate(args[0], .int),
            .isBool => self.builtinIsBool(args[0]),
            .isNull => self.builtinTypePredicate(args[0], .null),
            .isFloat => self.builtinTypePredicate(args[0], .float),
            .isFunction => self.builtinIsFunction(args[0]),
            .isPath => self.builtinTypePredicate(args[0], .path),
            .length => self.builtinLength(args[0]),
            .head => self.builtinHead(args[0]),
            .tail => self.builtinTail(args[0]),
            .attrNames => self.builtinAttrNames(args[0]),
            .attrValues => self.builtinAttrValues(args[0]),
            .typeOf => self.builtinTypeOf(args[0]),
            .concatLists => self.builtinConcatLists(args[0]),
            .listToAttrs => self.builtinListToAttrs(args[0]),
            .pathExists => self.builtinPathExists(args[0]),
            .readFile => self.builtinReadFile(args[0]),
            .import => self.builtinImport(args[0]),
            .readDir => self.builtinReadDir(args[0]),
            .readFileType => self.builtinReadFileType(args[0]),
            .findFile => self.builtinFindFile(args[0], args[1]),
            .hasAttr => self.builtinHasAttr(args[0], args[1]),
            .getAttr => self.builtinGetAttr(args[0], args[1]),
            .elemAt => self.builtinElemAt(args[0], args[1]),
            .removeAttrs => self.builtinRemoveAttrs(args[0], args[1]),
            .intersectAttrs => self.builtinIntersectAttrs(args[0], args[1]),
            .elem => self.builtinElem(args[0], args[1]),
            .seq => self.builtinSeq(args[0], args[1]),
            .all => self.builtinAll(args[0], args[1]),
            .any => self.builtinAny(args[0], args[1]),
            .filter => self.builtinFilter(args[0], args[1]),
            .map => self.builtinMap(args[0], args[1]),
            .concatMap => self.builtinConcatMap(args[0], args[1]),
            .mapAttrs => self.builtinMapAttrs(args[0], args[1]),
            .genList => self.builtinGenList(args[0], args[1]),
            .stringLength => self.builtinStringLength(args[0]),
            .concatStringsSep => self.builtinConcatStringsSep(args[0], args[1]),
            .foldlStrict => self.builtinFoldlStrict(args[0], args[1], args[2]),
            .substring => self.builtinSubstring(args[0], args[1], args[2]),
            .replaceStrings => self.builtinReplaceStrings(args[0], args[1], args[2]),
            .deepSeq => self.builtinDeepSeq(args[0], args[1]),
            .throw => self.builtinThrow(args[0]),
            .abort => self.builtinAbort(args[0]),
            .tryEval => self.builtinTryEval(args[0]),
            .trace => self.builtinTrace(args[0], args[1]),
            .derivation => self.builtinDerivation(args[0]),
            .derivationStrict => self.builtinDerivation(args[0]),
            .storePath => self.builtinStorePath(args[0]),
            .path => self.builtinPath(args[0]),
            .sort => self.builtinSort(args[0], args[1]),
            .partition => self.builtinPartition(args[0], args[1]),
            .groupBy => self.builtinGroupBy(args[0], args[1]),
            .genericClosure => self.builtinGenericClosure(args[0]),
            .functionArgs => self.builtinFunctionArgs(args[0]),
            .unsafeGetAttrPos => self.builtinUnsafeGetAttrPos(args[0], args[1]),
            .add => self.builtinAdd(args[0], args[1]),
            .sub => self.builtinSub(args[0], args[1]),
            .mul => self.builtinMul(args[0], args[1]),
            .div => self.builtinDiv(args[0], args[1]),
            .lessThan => self.builtinLessThan(args[0], args[1]),
            .bitAnd => self.builtinBitAnd(args[0], args[1]),
            .bitOr => self.builtinBitOr(args[0], args[1]),
            .bitXor => self.builtinBitXor(args[0], args[1]),
            .floor => self.builtinFloor(args[0]),
            .ceil => self.builtinCeil(args[0]),
            .baseNameOf => self.builtinBaseNameOf(args[0]),
            .dirOf => self.builtinDirOf(args[0]),
            .catAttrs => self.builtinCatAttrs(args[0], args[1]),
            .zipAttrsWith => self.builtinZipAttrsWith(args[0], args[1]),
            .hashString => self.builtinHashString(args[0], args[1]),
            .hashFile => self.builtinHashFile(args[0], args[1]),
        };
    }

    fn makeBuiltinClosure(self: *VM, builtin_id: u16, args: []const Value) !Value {
        return Value.builtinClosure(try self.heap.addBuiltinClosure(builtin_id, args));
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

    fn builtinAdd(self: *VM, left: Value, right: Value) !Value {
        return numeric.add(try self.forceValue(left), try self.forceValue(right));
    }

    fn builtinSub(self: *VM, left: Value, right: Value) !Value {
        return numeric.sub(try self.forceValue(left), try self.forceValue(right));
    }

    fn builtinMul(self: *VM, left: Value, right: Value) !Value {
        return numeric.mul(try self.forceValue(left), try self.forceValue(right));
    }

    fn builtinDiv(self: *VM, left: Value, right: Value) !Value {
        return numeric.div(try self.forceValue(left), try self.forceValue(right));
    }

    fn builtinLessThan(self: *VM, left: Value, right: Value) !Value {
        return Value.boolVal(try self.compareValues(left, right) == .lt);
    }

    fn builtinBitAnd(self: *VM, left: Value, right: Value) !Value {
        return numeric.bitAnd(try self.forceValue(left), try self.forceValue(right));
    }

    fn builtinBitOr(self: *VM, left: Value, right: Value) !Value {
        return numeric.bitOr(try self.forceValue(left), try self.forceValue(right));
    }

    fn builtinBitXor(self: *VM, left: Value, right: Value) !Value {
        return numeric.bitXor(try self.forceValue(left), try self.forceValue(right));
    }

    fn builtinFloor(self: *VM, arg: Value) !Value {
        return numeric.floor(try self.forceValue(arg));
    }

    fn builtinCeil(self: *VM, arg: Value) !Value {
        return numeric.ceil(try self.forceValue(arg));
    }

    fn builtinBaseNameOf(self: *VM, arg: Value) !Value {
        const value = try self.forceValue(arg);
        const path = switch (value.discriminant) {
            .path, .string => self.intern.get(value.asInternId()),
            else => return error.TypeError,
        };
        return Value.string(try self.intern.intern(path_ops.baseName(path)));
    }

    fn builtinDirOf(self: *VM, arg: Value) !Value {
        const value = try self.forceValue(arg);
        const path = switch (value.discriminant) {
            .path, .string => self.intern.get(value.asInternId()),
            else => return error.TypeError,
        };
        const dir = try self.intern.intern(path_ops.dirOf(path));
        return switch (value.discriminant) {
            .path => Value.path(dir),
            .string => Value.string(dir),
            else => unreachable,
        };
    }

    fn builtinCatAttrs(self: *VM, name_arg: Value, list_arg: Value) !Value {
        const name = try self.forceValue(name_arg);
        const list = try self.forceValue(list_arg);
        if (name.discriminant != .string or list.discriminant != .list) return error.TypeError;

        var values: std.ArrayListUnmanaged(Value) = .empty;
        defer values.deinit(self.allocator);

        for (try self.heap.getList(list.asObjectId())) |item| {
            const attrs = try self.forceValue(item);
            if (attrs.discriminant != .attrs) return error.TypeError;
            const value = self.heap.getAttrValue(attrs.asObjectId(), name.asInternId()) catch |err| switch (err) {
                error.MissingAttribute => continue,
                else => return err,
            };
            try values.append(self.allocator, value);
        }

        return Value.list(try self.heap.addList(values.items));
    }

    fn builtinZipAttrsWith(self: *VM, func_arg: Value, list_arg: Value) !Value {
        const func = try self.forceValue(func_arg);
        const list = try self.forceValue(list_arg);
        if (list.discriminant != .list) return error.TypeError;

        const Group = struct {
            name: InternId,
            values: std.ArrayListUnmanaged(Value) = .empty,
        };
        var groups: std.ArrayListUnmanaged(Group) = .empty;
        defer {
            for (groups.items) |*group| group.values.deinit(self.allocator);
            groups.deinit(self.allocator);
        }

        for (try self.heap.getList(list.asObjectId())) |item| {
            const attrs = try self.forceValue(item);
            if (attrs.discriminant != .attrs) return error.TypeError;

            for (try self.heap.getAttrs(attrs.asObjectId())) |entry| {
                const index = groupIndex(groups.items, entry.name) orelse blk: {
                    try groups.append(self.allocator, .{ .name = entry.name });
                    break :blk groups.items.len - 1;
                };
                try groups.items[index].values.append(self.allocator, entry.value);
            }
        }

        const entries = try self.allocator.alloc(heap_mod.AttrEntry, groups.items.len);
        defer self.allocator.free(entries);
        for (groups.items, entries) |group, *entry| {
            const partial = try self.callValue(func, Value.string(group.name));
            entry.* = .{
                .name = group.name,
                .value = try self.callValue(partial, Value.list(try self.heap.addList(group.values.items))),
            };
        }
        return Value.attrs(try self.heap.addAttrs(entries));
    }

    fn builtinHashString(self: *VM, algorithm_arg: Value, string_arg: Value) !Value {
        const algorithm = try self.stringArg(algorithm_arg);
        const string = try self.stringArg(string_arg);
        const digest = try nix_hash.hashBytes(self.allocator, algorithm, string);
        defer self.allocator.free(digest);
        return Value.string(try self.intern.intern(digest));
    }

    fn builtinHashFile(self: *VM, algorithm_arg: Value, path_arg: Value) !Value {
        const algorithm = try self.stringArg(algorithm_arg);
        const contents = try self.files.readFile(try self.pathArg(path_arg));
        const digest = try nix_hash.hashBytes(self.allocator, algorithm, contents);
        defer self.allocator.free(digest);
        return Value.string(try self.intern.intern(digest));
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

    fn builtinPathExists(self: *VM, arg: Value) !Value {
        return Value.boolVal(try self.files.pathExists(try self.pathArg(arg)));
    }

    fn builtinReadFile(self: *VM, arg: Value) !Value {
        const contents = try self.files.readFile(try self.pathArg(arg));
        return Value.string(try self.intern.intern(contents));
    }

    fn builtinReadFileType(self: *VM, arg: Value) !Value {
        const kind = try self.files.fileType(try self.pathArg(arg));
        return Value.string(try self.intern.intern(kind.nixTypeName()));
    }

    fn builtinImport(self: *VM, arg: Value) !Value {
        const host = self.import_host orelse return error.ImportUnavailable;
        return host.import_value(host.context, try self.pathArg(arg));
    }

    fn builtinReadDir(self: *VM, arg: Value) !Value {
        const dir_entries = try self.files.readDir(try self.pathArg(arg));
        var attrs: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
        defer attrs.deinit(self.allocator);
        try attrs.ensureTotalCapacity(self.allocator, dir_entries.len);

        for (dir_entries) |dir_entry| {
            attrs.appendAssumeCapacity(.{
                .name = try self.intern.intern(dir_entry.name),
                .value = Value.string(try self.intern.intern(dir_entry.kind.nixTypeName())),
            });
        }

        return Value.attrs(try self.heap.addAttrs(attrs.items));
    }

    fn builtinFindFile(self: *VM, search_path_arg: Value, name_arg: Value) !Value {
        const search_path = try self.forceValue(search_path_arg);
        if (search_path.discriminant != .list) return error.TypeError;
        const name = try self.pathArg(name_arg);

        const path_id = try self.intern.intern("path");
        const prefix_id = try self.intern.intern("prefix");
        for (try self.heap.getList(search_path.asObjectId())) |item| {
            const entry = try self.forceValue(item);
            if (entry.discriminant != .attrs) return error.TypeError;

            const base_value = try self.forceValue(try self.heap.getAttrValue(entry.asObjectId(), path_id));
            const base = switch (base_value.discriminant) {
                .path, .string => self.intern.get(base_value.asInternId()),
                else => return error.TypeError,
            };

            const prefix_value = self.heap.getAttrValue(entry.asObjectId(), prefix_id) catch |err| switch (err) {
                error.MissingAttribute => Value.string(try self.intern.intern("")),
                else => return err,
            };
            const prefix_forced = try self.forceValue(prefix_value);
            if (prefix_forced.discriminant != .string) return error.TypeError;
            const prefix = self.intern.get(prefix_forced.asInternId());

            if (try self.findFileCandidate(base, prefix, name)) |candidate| {
                defer self.allocator.free(candidate);
                return Value.path(try self.intern.intern(candidate));
            }
        }
        return error.FileNotFound;
    }

    fn findFileCandidate(self: *VM, base: []const u8, prefix: []const u8, name: []const u8) !?[]u8 {
        const suffix = searchPathSuffix(prefix, name) orelse return null;
        const candidate = try std.fs.path.resolve(self.allocator, &.{ base, suffix });
        errdefer self.allocator.free(candidate);
        if (try self.files.pathExists(candidate)) return candidate;
        self.allocator.free(candidate);
        return null;
    }

    fn pathArg(self: *VM, arg: Value) ![]const u8 {
        const value = try self.forceValue(arg);
        return switch (value.discriminant) {
            .path, .string => self.intern.get(value.asInternId()),
            else => error.TypeError,
        };
    }

    fn attrEntryNameIndex(entries: []const heap_mod.AttrEntry, name: InternId) ?usize {
        for (entries, 0..) |entry, i| {
            if (entry.name == name) return i;
        }
        return null;
    }

    fn groupIndex(groups: anytype, name: InternId) ?usize {
        for (groups, 0..) |group, i| {
            if (group.name == name) return i;
        }
        return null;
    }

    fn callComparator(self: *VM, cmp: Value, left: Value, right: Value) !bool {
        const partial = try self.callValue(cmp, left);
        const result = try self.forceValue(try self.callValue(partial, right));
        if (result.discriminant != .bool_true and result.discriminant != .bool_false) return error.TypeError;
        return result.discriminant == .bool_true;
    }

    fn genericClosureAppend(
        self: *VM,
        item: Value,
        result: *std.ArrayListUnmanaged(Value),
        keys: *std.ArrayListUnmanaged(Value),
    ) !void {
        const forced = try self.forceValue(item);
        if (forced.discriminant != .attrs) return error.TypeError;
        const key = try self.forceValue(try self.heap.getAttrValue(forced.asObjectId(), try self.intern.intern("key")));
        for (keys.items) |seen| {
            if (try self.valuesEqual(seen, key)) return;
        }
        try keys.append(self.allocator, key);
        try result.append(self.allocator, item);
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

    fn builtinSeq(self: *VM, first: Value, second: Value) !Value {
        _ = try self.forceValue(first);
        return self.forceValue(second);
    }

    fn builtinDeepSeq(self: *VM, first: Value, second: Value) !Value {
        var seen: std.ArrayListUnmanaged(SeenDeepObject) = .empty;
        defer seen.deinit(self.allocator);
        try self.forceDeep(first, &seen);
        return self.forceValue(second);
    }

    const SeenDeepKind = enum { list, attrs };

    const SeenDeepObject = struct {
        kind: SeenDeepKind,
        id: ObjectId,
    };

    fn forceDeep(self: *VM, value: Value, seen: *std.ArrayListUnmanaged(SeenDeepObject)) anyerror!void {
        const forced = try self.forceValue(value);
        switch (forced.discriminant) {
            .list => {
                const id = forced.asObjectId();
                if (!try self.enterDeep(.list, id, seen)) return;
                for (try self.heap.getList(id)) |item| try self.forceDeep(item, seen);
            },
            .attrs => {
                const id = forced.asObjectId();
                if (!try self.enterDeep(.attrs, id, seen)) return;
                for (try self.heap.getAttrs(id)) |entry| try self.forceDeep(entry.value, seen);
            },
            else => {},
        }
    }

    fn enterDeep(self: *VM, kind: SeenDeepKind, id: ObjectId, seen: *std.ArrayListUnmanaged(SeenDeepObject)) !bool {
        for (seen.items) |item| {
            if (item.kind == kind and item.id == id) return false;
        }
        try seen.append(self.allocator, .{ .kind = kind, .id = id });
        return true;
    }

    fn builtinAll(self: *VM, pred_arg: Value, list_arg: Value) !Value {
        const pred = try self.forceValue(pred_arg);
        const list = try self.forceValue(list_arg);
        if (list.discriminant != .list) return error.TypeError;

        for (try self.heap.getList(list.asObjectId())) |item| {
            const result = try self.forceValue(try self.callValue(pred, item));
            if (result.discriminant != .bool_true and result.discriminant != .bool_false) return error.TypeError;
            if (result.discriminant == .bool_false) return Value.boolVal(false);
        }
        return Value.boolVal(true);
    }

    fn builtinAny(self: *VM, pred_arg: Value, list_arg: Value) !Value {
        const pred = try self.forceValue(pred_arg);
        const list = try self.forceValue(list_arg);
        if (list.discriminant != .list) return error.TypeError;

        for (try self.heap.getList(list.asObjectId())) |item| {
            const result = try self.forceValue(try self.callValue(pred, item));
            if (result.discriminant != .bool_true and result.discriminant != .bool_false) return error.TypeError;
            if (result.discriminant == .bool_true) return Value.boolVal(true);
        }
        return Value.boolVal(false);
    }

    fn builtinFilter(self: *VM, pred_arg: Value, list_arg: Value) !Value {
        const pred = try self.forceValue(pred_arg);
        const list = try self.forceValue(list_arg);
        if (list.discriminant != .list) return error.TypeError;

        var out: std.ArrayListUnmanaged(Value) = .empty;
        defer out.deinit(self.allocator);

        for (try self.heap.getList(list.asObjectId())) |item| {
            const result = try self.forceValue(try self.callValue(pred, item));
            if (result.discriminant != .bool_true and result.discriminant != .bool_false) return error.TypeError;
            if (result.discriminant == .bool_true) try out.append(self.allocator, item);
        }

        return Value.list(try self.heap.addList(out.items));
    }

    fn builtinMap(self: *VM, fn_arg: Value, list_arg: Value) !Value {
        const func = try self.forceValue(fn_arg);
        const list = try self.forceValue(list_arg);
        if (list.discriminant != .list) return error.TypeError;

        const items = try self.heap.getList(list.asObjectId());
        const out = try self.allocator.alloc(Value, items.len);
        defer self.allocator.free(out);

        for (items, out) |item, *mapped| {
            mapped.* = try self.callValue(func, item);
        }
        return Value.list(try self.heap.addList(out));
    }

    fn builtinConcatMap(self: *VM, fn_arg: Value, list_arg: Value) !Value {
        const func = try self.forceValue(fn_arg);
        const list = try self.forceValue(list_arg);
        if (list.discriminant != .list) return error.TypeError;

        var out: std.ArrayListUnmanaged(Value) = .empty;
        defer out.deinit(self.allocator);

        for (try self.heap.getList(list.asObjectId())) |item| {
            const mapped = try self.forceValue(try self.callValue(func, item));
            if (mapped.discriminant != .list) return error.TypeError;
            try out.appendSlice(self.allocator, try self.heap.getList(mapped.asObjectId()));
        }
        return Value.list(try self.heap.addList(out.items));
    }

    fn builtinMapAttrs(self: *VM, fn_arg: Value, attrs_arg: Value) !Value {
        const func = try self.forceValue(fn_arg);
        const attrs = try self.forceValue(attrs_arg);
        if (attrs.discriminant != .attrs) return error.TypeError;

        const attr_entries = try self.heap.getAttrs(attrs.asObjectId());
        const out = try self.allocator.alloc(heap_mod.AttrEntry, attr_entries.len);
        defer self.allocator.free(out);

        for (attr_entries, out) |entry, *mapped| {
            const partial = try self.callValue(func, Value.string(entry.name));
            mapped.* = .{
                .name = entry.name,
                .value = try self.callValue(partial, entry.value),
            };
        }
        return Value.attrs(try self.heap.addAttrs(out));
    }

    fn builtinGenList(self: *VM, fn_arg: Value, count_arg: Value) !Value {
        const func = try self.forceValue(fn_arg);
        const count = try self.forceValue(count_arg);
        if (count.discriminant != .int or count.asInt() < 0) return error.TypeError;

        const len: usize = @intCast(count.asInt());
        const out = try self.allocator.alloc(Value, len);
        defer self.allocator.free(out);

        for (out, 0..) |*value, i| {
            value.* = try self.callValue(func, Value.int(@intCast(i)));
        }
        return Value.list(try self.heap.addList(out));
    }

    fn builtinStringLength(self: *VM, arg: Value) !Value {
        return Value.int(@intCast((try self.stringArg(arg)).len));
    }

    fn builtinConcatStringsSep(self: *VM, sep_arg: Value, list_arg: Value) !Value {
        const sep = try self.stringArg(sep_arg);
        const list = try self.forceValue(list_arg);
        if (list.discriminant != .list) return error.TypeError;

        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(self.allocator);

        for (try self.heap.getList(list.asObjectId()), 0..) |item, i| {
            if (i > 0) try out.appendSlice(self.allocator, sep);
            try out.appendSlice(self.allocator, try self.stringArg(item));
        }

        return Value.string(try self.intern.intern(out.items));
    }

    fn builtinSubstring(self: *VM, start_arg: Value, len_arg: Value, string_arg: Value) !Value {
        const start_value = try self.forceValue(start_arg);
        const len_value = try self.forceValue(len_arg);
        if (start_value.discriminant != .int or len_value.discriminant != .int) return error.TypeError;
        if (start_value.asInt() < 0 or len_value.asInt() < 0) return error.TypeError;

        const string = try self.stringArg(string_arg);
        const start: usize = @intCast(start_value.asInt());
        if (start >= string.len) return Value.string(try self.intern.intern(""));
        const requested_len: usize = @intCast(len_value.asInt());
        const available = string.len - start;
        const end = start + @min(available, requested_len);
        return Value.string(try self.intern.intern(string[start..end]));
    }

    fn builtinReplaceStrings(self: *VM, from_arg: Value, to_arg: Value, string_arg: Value) !Value {
        const from = try self.stringListArg(from_arg);
        defer self.allocator.free(from);
        const to = try self.stringListArg(to_arg);
        defer self.allocator.free(to);
        if (from.len != to.len) return error.TypeError;

        const input = try self.stringArg(string_arg);
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(self.allocator);

        var index: usize = 0;
        while (index < input.len) {
            if (firstReplacementAt(input[index..], from)) |replacement_index| {
                const needle = from[replacement_index];
                if (needle.len == 0) return error.TypeError;
                try out.appendSlice(self.allocator, to[replacement_index]);
                index += needle.len;
            } else {
                try out.append(self.allocator, input[index]);
                index += 1;
            }
        }

        return Value.string(try self.intern.intern(out.items));
    }

    fn builtinThrow(self: *VM, message_arg: Value) !Value {
        _ = try self.stringArg(message_arg);
        return error.NixThrow;
    }

    fn builtinAbort(self: *VM, message_arg: Value) !Value {
        _ = try self.stringArg(message_arg);
        return error.NixAbort;
    }

    fn builtinTryEval(self: *VM, arg: Value) !Value {
        const value = self.forceValue(arg) catch |err| switch (err) {
            error.NixThrow,
            error.NixAbort,
            error.AssertionFailed,
            => return self.tryEvalResult(false, Value.boolVal(false)),
            else => return err,
        };
        return self.tryEvalResult(true, value);
    }

    fn builtinTrace(self: *VM, message_arg: Value, value_arg: Value) !Value {
        _ = try self.forceValue(message_arg);
        return self.forceValue(value_arg);
    }

    fn tryEvalResult(self: *VM, success: bool, value: Value) !Value {
        const entries = [_]heap_mod.AttrEntry{
            .{
                .name = try self.intern.intern("success"),
                .value = Value.boolVal(success),
            },
            .{
                .name = try self.intern.intern("value"),
                .value = value,
            },
        };
        return Value.attrs(try self.heap.addAttrs(&entries));
    }

    fn builtinDerivation(self: *VM, arg: Value) !Value {
        const attrs = try self.forceValue(arg);
        if (attrs.discriminant != .attrs) return error.TypeError;

        const name_id = try self.intern.intern("name");
        const name_value = try self.forceValue(try self.heap.getAttrValue(attrs.asObjectId(), name_id));
        if (name_value.discriminant != .string) return error.TypeError;
        const name = self.intern.get(name_value.asInternId());

        const output_names = try self.derivationOutputNames(attrs.asObjectId());
        defer self.allocator.free(output_names);

        const outputs = try self.allocator.alloc(derivation.Output, output_names.len);
        defer self.allocator.free(outputs);
        for (output_names, outputs) |output_name, *output| {
            output.* = .{
                .name = output_name,
                .out_path = try derivation.storePath(self.allocator, self.intern, name, self.intern.get(output_name)),
            };
        }

        const normalized_attrs = try self.normalizedDerivationAttrs(attrs.asObjectId(), outputs);
        defer self.allocator.free(normalized_attrs);

        return derivation.buildValue(self.allocator, self.intern, self.heap, .{
            .name = name,
            .drv_path = try derivation.drvPath(self.allocator, self.intern, name),
            .default_output = output_names[0],
            .outputs = outputs,
            .original_attrs = normalized_attrs,
        });
    }

    fn normalizedDerivationAttrs(self: *VM, attrs_id: ObjectId, outputs: []const derivation.Output) ![]heap_mod.AttrEntry {
        const original = try self.heap.getAttrs(attrs_id);
        const normalized = try self.allocator.alloc(heap_mod.AttrEntry, original.len);
        errdefer self.allocator.free(normalized);

        const structured_attrs_id = try self.intern.intern("__structuredAttrs");
        const pass_as_file_id = try self.intern.intern("passAsFile");
        const args_id = try self.intern.intern("args");
        const builder_id = try self.intern.intern("builder");
        const system_id = try self.intern.intern("system");

        for (original, normalized) |entry, *out| {
            if (derivation.isSyntheticName(self.intern, self.intern.get(entry.name), outputs)) {
                out.* = entry;
                continue;
            }

            if (entry.name == structured_attrs_id) {
                const value = try self.forceValue(entry.value);
                if (!value.isBool()) return error.TypeError;
                out.* = .{ .name = entry.name, .value = value };
                continue;
            }

            if (entry.name == pass_as_file_id or entry.name == args_id) {
                out.* = .{ .name = entry.name, .value = try self.coerceDerivationStringList(entry.value) };
                continue;
            }

            if (entry.name == builder_id or entry.name == system_id) {
                out.* = .{ .name = entry.name, .value = try self.coerceDerivationString(entry.value) };
                continue;
            }

            out.* = .{ .name = entry.name, .value = try self.coerceDerivationValue(entry.value) };
        }

        return normalized;
    }

    fn coerceDerivationValue(self: *VM, value: Value) !Value {
        const forced = try self.forceValue(value);
        return switch (forced.discriminant) {
            .string, .path, .int, .bool_true, .bool_false => self.coerceDerivationString(forced),
            .list => self.coerceDerivationStringList(forced),
            else => error.TypeError,
        };
    }

    fn coerceDerivationString(self: *VM, value: Value) !Value {
        const forced = try self.forceValue(value);
        return switch (forced.discriminant) {
            .string => forced,
            .path => Value.string(forced.asInternId()),
            .int => blk: {
                const text = try std.fmt.allocPrint(self.allocator, "{}", .{forced.asInt()});
                defer self.allocator.free(text);
                break :blk Value.string(try self.intern.intern(text));
            },
            .bool_true => Value.string(try self.intern.intern("1")),
            .bool_false => Value.string(try self.intern.intern("")),
            else => error.TypeError,
        };
    }

    fn coerceDerivationStringList(self: *VM, value: Value) !Value {
        const list = try self.forceValue(value);
        if (list.discriminant != .list) return error.TypeError;
        const items = try self.heap.getList(list.asObjectId());
        const coerced = try self.allocator.alloc(Value, items.len);
        defer self.allocator.free(coerced);
        for (items, coerced) |item, *out| out.* = try self.coerceDerivationString(item);
        return Value.list(try self.heap.addList(coerced));
    }

    fn derivationOutputNames(self: *VM, attrs_id: ObjectId) ![]InternId {
        const outputs_id = try self.intern.intern("outputs");
        const outputs_value = self.heap.getAttrValue(attrs_id, outputs_id) catch |err| switch (err) {
            error.MissingAttribute => {
                const names = try self.allocator.alloc(InternId, 1);
                names[0] = try self.intern.intern("out");
                return names;
            },
            else => return err,
        };

        const outputs_list = try self.forceValue(outputs_value);
        if (outputs_list.discriminant != .list) return error.TypeError;
        const items = try self.heap.getList(outputs_list.asObjectId());
        if (items.len == 0) return error.InvalidDerivationOutput;

        const names = try self.allocator.alloc(InternId, items.len);
        errdefer self.allocator.free(names);
        for (items, names) |item, *name| {
            const value = try self.forceValue(item);
            if (value.discriminant != .string) return error.TypeError;
            name.* = value.asInternId();
            if (self.intern.get(name.*).len == 0) return error.InvalidDerivationOutput;
        }
        return names;
    }

    fn builtinStorePath(self: *VM, arg: Value) !Value {
        const path = try self.pathArg(arg);
        if (!std.fs.path.isAbsolute(path)) return error.RelativePath;
        return Value.string(try self.intern.intern(path));
    }

    fn builtinPath(self: *VM, arg: Value) !Value {
        const attrs = try self.forceValue(arg);
        if (attrs.discriminant != .attrs) return error.TypeError;

        const path_id = try self.intern.intern("path");
        const path_value = try self.forceValue(try self.heap.getAttrValue(attrs.asObjectId(), path_id));
        const path = switch (path_value.discriminant) {
            .path, .string => self.intern.get(path_value.asInternId()),
            else => return error.TypeError,
        };
        if (!std.fs.path.isAbsolute(path)) return error.RelativePath;

        const name_id = try self.intern.intern("name");
        const name_value = self.heap.getAttrValue(attrs.asObjectId(), name_id) catch |err| switch (err) {
            error.MissingAttribute => Value.null_val,
            else => return err,
        };
        if (name_value.discriminant != .null) {
            const name = try self.forceValue(name_value);
            if (name.discriminant != .string) return error.TypeError;
        }

        return Value.string(try self.intern.intern(path));
    }

    fn builtinSort(self: *VM, cmp_arg: Value, list_arg: Value) !Value {
        const cmp = try self.forceValue(cmp_arg);
        const list = try self.forceValue(list_arg);
        if (list.discriminant != .list) return error.TypeError;

        const items = try self.heap.getList(list.asObjectId());
        const sorted = try self.allocator.dupe(Value, items);
        defer self.allocator.free(sorted);

        var i: usize = 1;
        while (i < sorted.len) : (i += 1) {
            var j = i;
            while (j > 0 and try self.callComparator(cmp, sorted[j], sorted[j - 1])) : (j -= 1) {
                std.mem.swap(Value, &sorted[j], &sorted[j - 1]);
            }
        }

        return Value.list(try self.heap.addList(sorted));
    }

    fn builtinPartition(self: *VM, pred_arg: Value, list_arg: Value) !Value {
        const pred = try self.forceValue(pred_arg);
        const list = try self.forceValue(list_arg);
        if (list.discriminant != .list) return error.TypeError;

        var right: std.ArrayListUnmanaged(Value) = .empty;
        defer right.deinit(self.allocator);
        var wrong: std.ArrayListUnmanaged(Value) = .empty;
        defer wrong.deinit(self.allocator);

        for (try self.heap.getList(list.asObjectId())) |item| {
            const result = try self.forceValue(try self.callValue(pred, item));
            if (result.discriminant != .bool_true and result.discriminant != .bool_false) return error.TypeError;
            if (result.discriminant == .bool_true) {
                try right.append(self.allocator, item);
            } else {
                try wrong.append(self.allocator, item);
            }
        }

        const entries = [_]heap_mod.AttrEntry{
            .{ .name = try self.intern.intern("right"), .value = Value.list(try self.heap.addList(right.items)) },
            .{ .name = try self.intern.intern("wrong"), .value = Value.list(try self.heap.addList(wrong.items)) },
        };
        return Value.attrs(try self.heap.addAttrs(&entries));
    }

    fn builtinGroupBy(self: *VM, fn_arg: Value, list_arg: Value) !Value {
        const func = try self.forceValue(fn_arg);
        const list = try self.forceValue(list_arg);
        if (list.discriminant != .list) return error.TypeError;

        const Group = struct {
            name: InternId,
            items: std.ArrayListUnmanaged(Value) = .empty,
        };
        var groups: std.ArrayListUnmanaged(Group) = .empty;
        defer {
            for (groups.items) |*group| group.items.deinit(self.allocator);
            groups.deinit(self.allocator);
        }

        for (try self.heap.getList(list.asObjectId())) |item| {
            const key = try self.forceValue(try self.callValue(func, item));
            if (key.discriminant != .string) return error.TypeError;
            const index = groupIndex(groups.items, key.asInternId()) orelse blk: {
                try groups.append(self.allocator, .{ .name = key.asInternId() });
                break :blk groups.items.len - 1;
            };
            try groups.items[index].items.append(self.allocator, item);
        }

        const entries = try self.allocator.alloc(heap_mod.AttrEntry, groups.items.len);
        defer self.allocator.free(entries);
        for (groups.items, entries) |group, *entry| {
            entry.* = .{
                .name = group.name,
                .value = Value.list(try self.heap.addList(group.items.items)),
            };
        }
        return Value.attrs(try self.heap.addAttrs(entries));
    }

    fn builtinGenericClosure(self: *VM, arg: Value) !Value {
        const attrs = try self.forceValue(arg);
        if (attrs.discriminant != .attrs) return error.TypeError;

        const start_set = try self.forceValue(try self.heap.getAttrValue(attrs.asObjectId(), try self.intern.intern("startSet")));
        const operator = try self.forceValue(try self.heap.getAttrValue(attrs.asObjectId(), try self.intern.intern("operator")));
        if (start_set.discriminant != .list) return error.TypeError;

        var result: std.ArrayListUnmanaged(Value) = .empty;
        defer result.deinit(self.allocator);
        var keys: std.ArrayListUnmanaged(Value) = .empty;
        defer keys.deinit(self.allocator);

        for (try self.heap.getList(start_set.asObjectId())) |item| {
            try self.genericClosureAppend(item, &result, &keys);
        }

        var index: usize = 0;
        while (index < result.items.len) : (index += 1) {
            const produced = try self.forceValue(try self.callValue(operator, result.items[index]));
            if (produced.discriminant != .list) return error.TypeError;
            for (try self.heap.getList(produced.asObjectId())) |item| {
                try self.genericClosureAppend(item, &result, &keys);
            }
        }

        return Value.list(try self.heap.addList(result.items));
    }

    fn builtinFunctionArgs(self: *VM, arg: Value) !Value {
        const func = try self.forceValue(arg);
        if (func.discriminant == .builtin or func.discriminant == .builtin_closure) {
            return Value.attrs(try self.heap.addAttrs(&.{}));
        }
        if (func.discriminant != .closure) return error.TypeError;

        const closure = try self.heap.getClosure(func.asObjectId());
        const ch = self.registry.get(closure.chunk_id) orelse return error.InvalidChunk;
        return Value.attrs(try self.heap.addAttrs(ch.function_args));
    }

    fn builtinUnsafeGetAttrPos(self: *VM, name_arg: Value, attrs_arg: Value) !Value {
        const name = try self.forceValue(name_arg);
        const attrs = try self.forceValue(attrs_arg);
        if (name.discriminant != .string or attrs.discriminant != .attrs) return error.TypeError;
        _ = self.heap.getAttrValue(attrs.asObjectId(), name.asInternId()) catch |err| switch (err) {
            error.MissingAttribute => return Value.null_val,
            else => return err,
        };
        return Value.null_val;
    }

    fn builtinFoldlStrict(self: *VM, op_arg: Value, nul_arg: Value, list_arg: Value) !Value {
        const op = try self.forceValue(op_arg);
        var acc = try self.forceValue(nul_arg);
        const list = try self.forceValue(list_arg);
        if (list.discriminant != .list) return error.TypeError;

        for (try self.heap.getList(list.asObjectId())) |item| {
            const partial = try self.callValue(op, acc);
            acc = try self.forceValue(try self.callValue(partial, item));
        }

        return acc;
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

    fn stringArg(self: *VM, arg: Value) ![]const u8 {
        const value = try self.forceValue(arg);
        if (value.discriminant != .string) return error.TypeError;
        return self.intern.get(value.asInternId());
    }

    fn stringListArg(self: *VM, arg: Value) ![][]const u8 {
        const list = try self.forceValue(arg);
        if (list.discriminant != .list) return error.TypeError;

        const items = try self.heap.getList(list.asObjectId());
        const strings = try self.allocator.alloc([]const u8, items.len);
        errdefer self.allocator.free(strings);
        for (items, strings) |item, *string| string.* = try self.stringArg(item);
        return strings;
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
