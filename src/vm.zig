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
const FetchCache = @import("fetch_cache.zig").FetchCache;
const numeric = @import("runtime/numeric.zig");
const vm_builtins = @import("vm/builtins.zig");

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
    scoped_import: *const fn (*anyopaque, Value, []const u8) anyerror!Value,
    find_file: *const fn (*anyopaque, []const u8) anyerror!Value,
    get_env: *const fn (*anyopaque, []const u8) anyerror![]const u8,
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
    /// Evaluator-owned network/source fetch cache.
    fetchers: *FetchCache,
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
        fetchers: *FetchCache,
        scheduler: *Scheduler,
        import_host: ?ImportHost,
        builtins: Value,
        worker_id: u8,
    ) !VM {
        var stack = try std.ArrayListUnmanaged(Value).initCapacity(allocator, types.VM_STACK_CAP);
        errdefer stack.deinit(allocator);

        var frames = try std.ArrayListUnmanaged(Frame).initCapacity(allocator, types.MAX_FRAMES);
        errdefer frames.deinit(allocator);

        return .{
            .allocator = allocator,
            .registry = registry,
            .intern = intern,
            .heap = heap,
            .files = files,
            .fetchers = fetchers,
            .scheduler = scheduler,
            .import_host = import_host,
            .builtins = builtins,
            .worker_id = worker_id,
            .stack = stack,
            .sp = 0,
            .frames = frames,
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
                    const b = try self.forceValue(self.pop());
                    const a = try self.forceValue(self.pop());
                    if (numeric.isNumeric(a) and numeric.isNumeric(b)) {
                        try self.push(try numeric.add(a, b));
                    } else if (a.discriminant == .path) {
                        const b_id = try self.stringLikeInternId(b);
                        try self.push(try self.concatInternedPath(a.asInternId(), b_id));
                    } else {
                        const a_id = try self.stringLikeInternId(a);
                        const b_id = try self.stringLikeInternId(b);
                        try self.push(Value.string(try self.concatInternedString(a_id, b_id)));
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
                .find_file_long => {
                    const name_id: InternId = readU32(code, frame.ip);
                    frame.ip += 4;
                    const host = self.import_host orelse return error.SearchPathUnavailable;
                    try self.push(try host.find_file(host.context, self.intern.get(name_id)));
                },
                // ---- closure ----
                .closure => {
                    const ch_id: u16 = readU16(code, frame.ip);
                    frame.ip += 2;
                    const upvalue_count = code[frame.ip];
                    frame.ip += 1;
                    try self.makeClosure(ch_id, upvalue_count);
                },
                .closure_long => {
                    const ch_id: ChunkId = readU32(code, frame.ip);
                    frame.ip += 4;
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
                .get_attr_long => {
                    const name_id: InternId = readU32(code, frame.ip);
                    frame.ip += 4;
                    const attrs_val = self.pop();
                    const result = try self.getAttrValue(attrs_val, name_id);
                    try self.push(result);
                },
                .get_attr_dynamic => {
                    const name_val = try self.forceValue(self.pop());
                    if (name_val.discriminant != .string) return error.TypeError;
                    const attrs_val = self.pop();
                    const result = try self.getAttrValue(attrs_val, name_val.asInternId());
                    try self.push(result);
                },
                .get_attr_dynamic_or => {
                    const default_val = self.pop();
                    const name_val = try self.forceValue(self.pop());
                    if (name_val.discriminant != .string) return error.TypeError;
                    const attrs_val = self.pop();
                    const attrs = try self.forceValue(attrs_val);
                    if (attrs.discriminant != .attrs) return try self.forceValue(default_val);
                    const result = self.heap.getAttrValue(attrs.asObjectId(), name_val.asInternId()) catch |err| switch (err) {
                        error.MissingAttribute => try self.forceValue(default_val),
                        else => return err,
                    };
                    try self.push(try self.forceValue(result));
                },
                .get_attr_path_or => {
                    const segment_count = code[frame.ip];
                    frame.ip += 1;
                    const names_start = frame.ip;
                    frame.ip += @as(usize, segment_count) * 2;
                    const default_val = self.pop();
                    const attrs_val = self.pop();
                    const result = try self.getAttrPathOrValue(attrs_val, default_val, code[names_start..frame.ip], false);
                    try self.push(result);
                },
                .get_attr_path_or_long => {
                    const segment_count = code[frame.ip];
                    frame.ip += 1;
                    const names_start = frame.ip;
                    frame.ip += @as(usize, segment_count) * 4;
                    const default_val = self.pop();
                    const attrs_val = self.pop();
                    const result = try self.getAttrPathOrValue(attrs_val, default_val, code[names_start..frame.ip], true);
                    try self.push(result);
                },
                .has_attr_path => {
                    const segment_count = code[frame.ip];
                    frame.ip += 1;
                    const names_start = frame.ip;
                    frame.ip += @as(usize, segment_count) * 2;
                    const attrs_val = self.pop();
                    try self.push(Value.boolVal(try self.hasAttrPath(attrs_val, code[names_start..frame.ip], false)));
                },
                .has_attr_path_long => {
                    const segment_count = code[frame.ip];
                    frame.ip += 1;
                    const names_start = frame.ip;
                    frame.ip += @as(usize, segment_count) * 4;
                    const attrs_val = self.pop();
                    try self.push(Value.boolVal(try self.hasAttrPath(attrs_val, code[names_start..frame.ip], true)));
                },
                .has_attr_dynamic => {
                    const name_val = try self.forceValue(self.pop());
                    if (name_val.discriminant != .string) return error.TypeError;
                    const attrs_val = try self.forceValue(self.pop());
                    if (attrs_val.discriminant != .attrs) {
                        try self.push(Value.boolVal(false));
                    } else {
                        const present = if (self.heap.getAttrValue(attrs_val.asObjectId(), name_val.asInternId())) |_|
                            true
                        else |err| switch (err) {
                            error.MissingAttribute => false,
                            else => return err,
                        };
                        try self.push(Value.boolVal(present));
                    }
                },
                .validate_attrs => {
                    const allow_extra = code[frame.ip] != 0;
                    frame.ip += 1;
                    const expected_count = readU16(code, frame.ip);
                    frame.ip += 2;
                    const names_start = frame.ip;
                    frame.ip += @as(usize, expected_count) * 2;
                    const attrs_val = self.pop();
                    try self.validateAttrs(attrs_val, allow_extra, code[names_start..frame.ip], false);
                },
                .validate_attrs_long => {
                    const allow_extra = code[frame.ip] != 0;
                    frame.ip += 1;
                    const expected_count = readU16(code, frame.ip);
                    frame.ip += 2;
                    const names_start = frame.ip;
                    frame.ip += @as(usize, expected_count) * 4;
                    const attrs_val = self.pop();
                    try self.validateAttrs(attrs_val, allow_extra, code[names_start..frame.ip], true);
                },
                .lookup_with => {
                    const name_id: InternId = @intCast(readU16(code, frame.ip));
                    frame.ip += 2;
                    const scope_count = code[frame.ip];
                    frame.ip += 1;
                    try self.lookupWith(name_id, scope_count);
                },
                .lookup_with_long => {
                    const name_id: InternId = readU32(code, frame.ip);
                    frame.ip += 4;
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

    pub fn valuesEqual(self: *VM, a: Value, b: Value) anyerror!bool {
        var seen: std.ArrayListUnmanaged(EqualityPair) = .empty;
        defer seen.deinit(self.allocator);
        return self.valuesEqualSeen(a, b, &seen);
    }

    const EqualityPair = struct {
        left: Value,
        right: Value,
    };

    fn valuesEqualSeen(self: *VM, a: Value, b: Value, seen: *std.ArrayListUnmanaged(EqualityPair)) anyerror!bool {
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
            .list => try self.listsEqual(va, vb, seen),
            .attrs => try self.attrsEqual(va, vb, seen),
            .closure => va.asObjectId() == vb.asObjectId(),
            .builtin => va.asBuiltinId() == vb.asBuiltinId(),
            .builtin_closure => va.asObjectId() == vb.asObjectId(),
            .thunk, .cell => unreachable,
        };
    }

    const CompareResult = enum { lt, eq, gt };

    fn listsEqual(self: *VM, a: Value, b: Value, seen: *std.ArrayListUnmanaged(EqualityPair)) anyerror!bool {
        if (a.asObjectId() == b.asObjectId()) return true;
        if (try self.equalityPairSeen(a, b, seen)) return true;

        const a_items = try self.heap.getList(a.asObjectId());
        const b_items = try self.heap.getList(b.asObjectId());
        if (a_items.len != b_items.len) return false;

        for (a_items, b_items) |a_item, b_item| {
            if (!try self.valuesEqualSeen(a_item, b_item, seen)) return false;
        }
        return true;
    }

    fn attrsEqual(self: *VM, a: Value, b: Value, seen: *std.ArrayListUnmanaged(EqualityPair)) anyerror!bool {
        if (a.asObjectId() == b.asObjectId()) return true;
        if (try self.equalityPairSeen(a, b, seen)) return true;

        const a_entries = try self.heap.getAttrs(a.asObjectId());
        const b_entries = try self.heap.getAttrs(b.asObjectId());
        if (a_entries.len != b_entries.len) return false;

        for (a_entries, b_entries) |a_entry, b_entry| {
            if (a_entry.name != b_entry.name) return false;
            if (!try self.valuesEqualSeen(a_entry.value, b_entry.value, seen)) return false;
        }
        return true;
    }

    fn equalityPairSeen(self: *VM, left: Value, right: Value, seen: *std.ArrayListUnmanaged(EqualityPair)) !bool {
        for (seen.items) |pair| {
            if ((pair.left.memoEq(left, self.intern) and pair.right.memoEq(right, self.intern)) or
                (pair.left.memoEq(right, self.intern) and pair.right.memoEq(left, self.intern)))
            {
                return true;
            }
        }
        try seen.append(self.allocator, .{ .left = left, .right = right });
        return false;
    }

    pub fn compareValues(self: *VM, a: Value, b: Value) !CompareResult {
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

    pub fn forceValue(self: *VM, value: Value) anyerror!Value {
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
        switch (closure_val.discriminant) {
            .closure => {
                const closure_id = closure_val.asObjectId();
                const closure = try self.getClosureById(closure_id);
                const ch = self.registry.get(closure.chunk_id) orelse return error.InvalidChunk;
                const stop_depth = self.frames.items.len;
                try self.pushFrame(ch, 0, closure_id);
                return self.runUntil(stop_depth);
            },
            .builtin_closure => {
                const closure = try self.heap.getBuiltinClosure(closure_val.asObjectId());
                return self.applyBuiltin(closure.builtin_id, closure.args);
            },
            else => return error.NotCallable,
        }
    }

    pub fn makeThunk(self: *VM, closure: Value) !Value {
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
        return Value.string(try self.concatInternedString(a.asInternId(), b.asInternId()));
    }

    fn concatPath(self: *VM, a: Value, b: Value) !Value {
        return Value.path(try self.concatInternedString(a.asInternId(), b.asInternId()));
    }

    fn concatInternedString(self: *VM, a: InternId, b: InternId) !InternId {
        const s_a = self.intern.get(a);
        const s_b = self.intern.get(b);
        const buf = try self.allocator.alloc(u8, s_a.len + s_b.len);
        defer self.allocator.free(buf);

        @memcpy(buf[0..s_a.len], s_a);
        @memcpy(buf[s_a.len..], s_b);

        return self.intern.intern(buf);
    }

    fn concatInternedPath(self: *VM, a: InternId, b: InternId) !Value {
        return Value.path(try self.concatInternedString(a, b));
    }

    fn stringLikeInternId(self: *VM, value: Value) !InternId {
        const forced = try self.forceValue(value);
        return switch (forced.discriminant) {
            .string, .path => forced.asInternId(),
            .attrs => try self.attrsStringLikeInternId(forced),
            else => error.TypeError,
        };
    }

    fn attrsStringLikeInternId(self: *VM, attrs: Value) !InternId {
        const to_string_id = try self.intern.intern("__toString");
        if (self.heap.getAttrValue(attrs.asObjectId(), to_string_id)) |to_string| {
            return self.stringLikeInternId(try self.callValue(try self.forceValue(to_string), attrs));
        } else |err| switch (err) {
            error.MissingAttribute => {},
            else => return err,
        }

        const out_path_id = try self.intern.intern("outPath");
        const out_path = self.heap.getAttrValue(attrs.asObjectId(), out_path_id) catch |err| switch (err) {
            error.MissingAttribute => return error.TypeError,
            else => return err,
        };
        return self.stringLikeInternId(out_path);
    }

    // ---- closures ----

    fn getClosureById(self: *VM, closure_id: ObjectId) !Closure {
        return self.heap.getClosure(closure_id);
    }

    fn makeClosure(self: *VM, chunk_id: ChunkId, upvalue_count: u8) !void {
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
        } else if (callee.discriminant == .attrs) {
            const callable = try self.callAttrFunctor(callee);
            try self.doCall(callable, arg);
        } else {
            return error.NotCallable;
        }
    }

    pub fn callValue(self: *VM, callee: Value, arg: Value) !Value {
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
        if (callee.discriminant == .attrs) {
            const callable = try self.callAttrFunctor(callee);
            return self.callValue(callable, arg);
        }
        return error.NotCallable;
    }

    fn callAttrFunctor(self: *VM, callee: Value) !Value {
        const functor_id = try self.intern.intern("__functor");
        const functor = self.heap.getAttrValue(callee.asObjectId(), functor_id) catch |err| switch (err) {
            error.MissingAttribute => return error.NotCallable,
            else => return err,
        };
        return self.callValue(try self.forceValue(functor), callee);
    }

    fn applyBuiltin(self: *VM, builtin_id: u16, args: []const Value) !Value {
        return vm_builtins.applyBuiltin(self, builtin_id, args);
    }

    fn applyBuiltinClosure(self: *VM, callee: Value, arg: Value) !Value {
        const closure = try self.heap.getBuiltinClosure(callee.asObjectId());
        var args: [8]Value = undefined;
        if (closure.args.len + 1 > args.len) return error.TooManyArguments;
        @memcpy(args[0..closure.args.len], closure.args);
        args[closure.args.len] = arg;
        return self.applyBuiltin(closure.builtin_id, args[0 .. closure.args.len + 1]);
    }

    fn getAttrValue(self: *VM, attrs_val: Value, name_id: InternId) !Value {
        if (attrs_val.discriminant != .attrs) return error.TypeError;
        return self.forceValue(try self.heap.getAttrValue(attrs_val.asObjectId(), name_id));
    }

    fn getAttrPathOrValue(self: *VM, attrs_val: Value, default_val: Value, encoded_names: []const u8, wide: bool) !Value {
        var current = try self.forceValue(attrs_val);
        var offset: usize = 0;
        const stride: usize = if (wide) 4 else 2;
        while (offset < encoded_names.len) : (offset += stride) {
            if (current.discriminant != .attrs) return self.forceValue(default_val);
            const name_id = readInternId(encoded_names, offset, wide);
            current = self.heap.getAttrValue(current.asObjectId(), name_id) catch |err| switch (err) {
                error.MissingAttribute => return self.forceValue(default_val),
                else => return err,
            };
            current = try self.forceValue(current);
        }
        return current;
    }

    fn hasAttrPath(self: *VM, attrs_val: Value, encoded_names: []const u8, wide: bool) !bool {
        var current = try self.forceValue(attrs_val);
        var offset: usize = 0;
        const stride: usize = if (wide) 4 else 2;
        while (offset < encoded_names.len) : (offset += stride) {
            if (current.discriminant != .attrs) return false;
            const name_id = readInternId(encoded_names, offset, wide);
            const attr = self.heap.getAttrValue(current.asObjectId(), name_id) catch |err| switch (err) {
                error.MissingAttribute => return false,
                else => return err,
            };
            if (offset + stride >= encoded_names.len) return true;
            current = try self.forceValue(attr);
        }
        return false;
    }

    fn validateAttrs(self: *VM, attrs_val: Value, allow_extra: bool, encoded_names: []const u8, wide: bool) !void {
        const value = try self.forceValue(attrs_val);
        if (value.discriminant != .attrs) return error.TypeError;
        if (allow_extra) return;

        const entries = try self.heap.getAttrs(value.asObjectId());
        const stride: usize = if (wide) 4 else 2;
        for (entries) |entry| {
            var found = false;
            var offset: usize = 0;
            while (offset < encoded_names.len) : (offset += stride) {
                const name_id = readInternId(encoded_names, offset, wide);
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

fn readU32(code: []const u8, ip: usize) u32 {
    return @as(u32, code[ip]) |
        (@as(u32, code[ip + 1]) << 8) |
        (@as(u32, code[ip + 2]) << 16) |
        (@as(u32, code[ip + 3]) << 24);
}

fn readInternId(code: []const u8, ip: usize, wide: bool) InternId {
    return if (wide) readU32(code, ip) else @intCast(readU16(code, ip));
}
