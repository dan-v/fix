//! Bytecode chunk — a sequence of opcodes and a constant pool.
//!
//! Chunks are immutable after construction. They are identified by ChunkId
//! in a global table, enabling cheap interning and cross-thread referencing.

const std = @import("std");
const types = @import("../types.zig");
const encoding = @import("encoding.zig");
const OpCode = @import("opcode.zig").OpCode;
const Value = @import("../value.zig").Value;
const AttrEntry = @import("../heap.zig").AttrEntry;
const ChunkId = types.ChunkId;
const ConstIdx = types.ConstIdx;

pub const Chunk = struct {
    pub const SourceSpan = struct {
        file: ?@import("../types.zig").InternId,
        offset: u32,
        len: u32,
        line: u32,
        column: u32,
    };

    pub const SourceMapEntry = struct {
        start: u32,
        end: u32,
        span: SourceSpan,
    };

    /// Bytecode stream.
    code: []u8,
    /// Constant pool.
    constants: []Value,
    /// Number of stack slots reserved for locals in each frame.
    local_count: u16,
    /// Attrset function parameter metadata for builtins.functionArgs.
    function_args: []const AttrEntry = &.{},
    /// Source span ranges for cold-path error traces.
    source_map: []const SourceMapEntry = &.{},

    pub fn deinit(self: *Chunk, allocator: std.mem.Allocator) void {
        allocator.free(self.code);
        allocator.free(self.constants);
        allocator.free(self.function_args);
        allocator.free(self.source_map);
    }
};

/// A mutable builder for constructing chunks.
pub const ChunkBuilder = struct {
    code: std.ArrayListUnmanaged(u8),
    constants: std.ArrayListUnmanaged(Value),
    function_args: std.ArrayListUnmanaged(AttrEntry),
    source_map: std.ArrayListUnmanaged(Chunk.SourceMapEntry),

    pub fn init(allocator: std.mem.Allocator) !ChunkBuilder {
        var code = try std.ArrayListUnmanaged(u8).initCapacity(allocator, types.CHUNK_CODE_CAP);
        errdefer code.deinit(allocator);

        var constants = try std.ArrayListUnmanaged(Value).initCapacity(allocator, types.CHUNK_CONSTANTS_CAP);
        errdefer constants.deinit(allocator);

        return .{
            .code = code,
            .constants = constants,
            .function_args = .empty,
            .source_map = .empty,
        };
    }

    pub fn deinit(self: *ChunkBuilder, allocator: std.mem.Allocator) void {
        self.code.deinit(allocator);
        self.constants.deinit(allocator);
        self.function_args.deinit(allocator);
        self.source_map.deinit(allocator);
    }

    /// Write a single opcode byte.
    pub fn writeOp(self: *ChunkBuilder, allocator: std.mem.Allocator, op: OpCode) !void {
        try self.code.append(allocator, @intFromEnum(op));
    }

    /// Write a single byte operand.
    pub fn writeByte(self: *ChunkBuilder, allocator: std.mem.Allocator, byte: u8) !void {
        try self.code.append(allocator, byte);
    }

    /// Write a two-byte operand (little-endian).
    pub fn writeU16(self: *ChunkBuilder, allocator: std.mem.Allocator, val: u16) !void {
        try encoding.writeU16(&self.code, allocator, val);
    }

    /// Write a four-byte operand (little-endian).
    pub fn writeU32(self: *ChunkBuilder, allocator: std.mem.Allocator, val: u32) !void {
        try encoding.writeU32(&self.code, allocator, val);
    }

    /// Add a constant to the pool and return its index.
    pub fn addConstant(self: *ChunkBuilder, allocator: std.mem.Allocator, val: Value) !ConstIdx {
        if (self.constants.items.len > std.math.maxInt(ConstIdx)) return error.TooManyConstants;
        try self.constants.append(allocator, val);
        return @intCast(self.constants.items.len - 1);
    }

    /// Emit a constant-loading instruction (op + 2-byte index).
    pub fn emitConstant(self: *ChunkBuilder, allocator: std.mem.Allocator, val: Value) !void {
        const idx = try self.addConstant(allocator, val);
        try self.writeOp(allocator, .constant);
        try self.writeU16(allocator, idx);
    }

    pub fn setFunctionArgs(self: *ChunkBuilder, allocator: std.mem.Allocator, args: []const AttrEntry) !void {
        self.function_args.clearRetainingCapacity();
        try self.function_args.appendSlice(allocator, args);
    }

    pub fn addSourceMapEntry(self: *ChunkBuilder, allocator: std.mem.Allocator, start: usize, end: usize, span: Chunk.SourceSpan) !void {
        if (start >= end) return;
        try self.source_map.append(allocator, .{
            .start = @intCast(start),
            .end = @intCast(end),
            .span = span,
        });
    }

    /// Finalize into an immutable Chunk.
    pub fn finish(self: *ChunkBuilder, allocator: std.mem.Allocator, local_count: u16) !Chunk {
        const code = try allocator.dupe(u8, self.code.items);
        errdefer allocator.free(code);
        const constants = try allocator.dupe(Value, self.constants.items);
        errdefer allocator.free(constants);
        const function_args = try allocator.dupe(AttrEntry, self.function_args.items);
        errdefer allocator.free(function_args);
        const source_map = try allocator.dupe(Chunk.SourceMapEntry, self.source_map.items);
        return Chunk{
            .code = code,
            .constants = constants,
            .local_count = local_count,
            .function_args = function_args,
            .source_map = source_map,
        };
    }
};

/// Global chunk registry. Chunks are stored here and referenced by ChunkId.
/// This is the "program" that the VM executes.
pub const ChunkRegistry = struct {
    allocator: std.mem.Allocator,
    chunks: std.ArrayListUnmanaged(*Chunk),
    mutex: std.atomic.Mutex,

    pub fn init(allocator: std.mem.Allocator) !ChunkRegistry {
        return .{
            .allocator = allocator,
            .chunks = .empty,
            .mutex = .unlocked,
        };
    }

    pub fn deinit(self: *ChunkRegistry) void {
        for (self.chunks.items) |chunk| {
            chunk.deinit(self.allocator);
            self.allocator.destroy(chunk);
        }
        self.chunks.deinit(self.allocator);
    }

    pub fn register(self: *ChunkRegistry, chunk: Chunk) !ChunkId {
        const stored = try self.allocator.create(Chunk);
        errdefer {
            stored.deinit(self.allocator);
            self.allocator.destroy(stored);
        }
        stored.* = chunk;

        while (!std.atomic.Mutex.tryLock(&self.mutex)) {
            std.atomic.spinLoopHint();
        }
        defer std.atomic.Mutex.unlock(&self.mutex);
        try self.chunks.append(self.allocator, stored);
        return @intCast(self.chunks.items.len - 1);
    }

    pub fn get(self: *const ChunkRegistry, id: ChunkId) ?*const Chunk {
        if (id >= self.chunks.items.len) return null;
        return self.chunks.items[id];
    }
};
