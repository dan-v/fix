//! Bytecode chunk — a sequence of opcodes and a constant pool.
//!
//! Chunks are immutable after construction. They are identified by ChunkId
//! in a global table, enabling cheap interning and cross-thread referencing.

const std = @import("std");
const types = @import("types.zig");
const OpCode = @import("opcode.zig").OpCode;
const Value = @import("value.zig").Value;
const ChunkId = types.ChunkId;
const ConstIdx = types.ConstIdx;

pub const Chunk = struct {
    /// Bytecode stream.
    code: []u8,
    /// Constant pool.
    constants: []Value,
    /// Number of stack slots reserved for locals in each frame.
    local_count: u16,

    pub fn deinit(self: *Chunk, allocator: std.mem.Allocator) void {
        allocator.free(self.code);
        allocator.free(self.constants);
    }
};

/// A mutable builder for constructing chunks.
pub const ChunkBuilder = struct {
    code: std.ArrayListUnmanaged(u8),
    constants: std.ArrayListUnmanaged(Value),

    pub fn init(allocator: std.mem.Allocator) !ChunkBuilder {
        return .{
            .code = try std.ArrayListUnmanaged(u8).initCapacity(allocator, types.CHUNK_CODE_CAP),
            .constants = try std.ArrayListUnmanaged(Value).initCapacity(allocator, types.CHUNK_CONSTANTS_CAP),
        };
    }

    pub fn deinit(self: *ChunkBuilder, allocator: std.mem.Allocator) void {
        self.code.deinit(allocator);
        self.constants.deinit(allocator);
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
        try self.code.append(allocator, @truncate(val));
        try self.code.append(allocator, @truncate(val >> 8));
    }

    /// Add a constant to the pool and return its index.
    pub fn addConstant(self: *ChunkBuilder, allocator: std.mem.Allocator, val: Value) !ConstIdx {
        try self.constants.append(allocator, val);
        return @intCast(self.constants.items.len - 1);
    }

    /// Emit a constant-loading instruction (op + 2-byte index).
    pub fn emitConstant(self: *ChunkBuilder, allocator: std.mem.Allocator, val: Value) !void {
        const idx = try self.addConstant(allocator, val);
        try self.writeOp(allocator, .constant);
        try self.writeU16(allocator, idx);
    }

    /// Finalize into an immutable Chunk.
    pub fn finish(self: *ChunkBuilder, allocator: std.mem.Allocator, local_count: u16) !Chunk {
        const code = try allocator.dupe(u8, self.code.items);
        const constants = try allocator.dupe(Value, self.constants.items);
        return Chunk{
            .code = code,
            .constants = constants,
            .local_count = local_count,
        };
    }
};

/// Global chunk registry. Chunks are stored here and referenced by ChunkId.
/// This is the "program" that the VM executes.
pub const ChunkRegistry = struct {
    allocator: std.mem.Allocator,
    chunks: std.ArrayListUnmanaged(Chunk),
    mutex: std.atomic.Mutex,

    pub fn init(allocator: std.mem.Allocator) !ChunkRegistry {
        return .{
            .allocator = allocator,
            .chunks = .empty,
            .mutex = .unlocked,
        };
    }

    pub fn deinit(self: *ChunkRegistry) void {
        for (self.chunks.items) |*chunk| {
            chunk.deinit(self.allocator);
        }
        self.chunks.deinit(self.allocator);
    }

    pub fn register(self: *ChunkRegistry, chunk: Chunk) !ChunkId {
        while (!std.atomic.Mutex.tryLock(&self.mutex)) {
            std.atomic.spinLoopHint();
        }
        defer std.atomic.Mutex.unlock(&self.mutex);
        try self.chunks.append(self.allocator, chunk);
        return @intCast(self.chunks.items.len - 1);
    }

    pub fn get(self: *const ChunkRegistry, id: ChunkId) ?*const Chunk {
        if (id >= self.chunks.items.len) return null;
        return &self.chunks.items[id];
    }
};
