//! Runtime object heap.
//!
//! Values refer to boxed runtime objects by ObjectId rather than by host
//! pointers. This keeps the value representation position-independent and
//! centralizes object layout behind heap accessors.

const std = @import("std");
const types = @import("types.zig");
const Value = @import("value.zig").Value;
const Thunk = @import("thunk.zig").Thunk;
const Cell = @import("thunk.zig").Cell;

pub const ObjectId = types.ObjectId;
pub const ChunkId = types.ChunkId;
pub const InternId = types.InternId;

pub const AttrEntry = struct {
    name: InternId,
    value: Value,
};

const ValueRange = struct {
    start: u32,
    len: u32,
};

const AttrRange = struct {
    start: u32,
    len: u32,
};

pub const Closure = struct {
    chunk_id: ChunkId,
    upvalues: []const Value,
};

const ClosureObject = struct {
    chunk_id: ChunkId,
    upvalues: ValueRange,
};

pub const Object = union(enum) {
    list: ValueRange,
    attrs: AttrRange,
    closure: ClosureObject,
    thunk: Thunk,
    cell: Cell,
};

pub const ObjectHeap = struct {
    allocator: std.mem.Allocator,
    objects: std.ArrayListUnmanaged(Object),
    values: std.ArrayListUnmanaged(Value),
    attrs: std.ArrayListUnmanaged(AttrEntry),

    pub fn init(allocator: std.mem.Allocator) ObjectHeap {
        return .{
            .allocator = allocator,
            .objects = .empty,
            .values = .empty,
            .attrs = .empty,
        };
    }

    pub fn deinit(self: *ObjectHeap) void {
        self.attrs.deinit(self.allocator);
        self.values.deinit(self.allocator);
        self.objects.deinit(self.allocator);
    }

    pub fn add(self: *ObjectHeap, object: Object) !ObjectId {
        try self.objects.append(self.allocator, object);
        return @intCast(self.objects.items.len - 1);
    }

    pub fn get(self: *ObjectHeap, id: ObjectId) *Object {
        return &self.objects.items[id];
    }

    pub fn getConst(self: *const ObjectHeap, id: ObjectId) *const Object {
        return &self.objects.items[id];
    }

    pub fn getList(self: *const ObjectHeap, id: ObjectId) ![]const Value {
        return switch (self.getConst(id).*) {
            .list => |range| self.valueSlice(range),
            else => error.InvalidObjectType,
        };
    }

    pub fn getAttrs(self: *const ObjectHeap, id: ObjectId) ![]const AttrEntry {
        return switch (self.getConst(id).*) {
            .attrs => |range| self.attrSlice(range),
            else => error.InvalidObjectType,
        };
    }

    pub fn getClosure(self: *const ObjectHeap, id: ObjectId) !Closure {
        return switch (self.getConst(id).*) {
            .closure => |closure| .{
                .chunk_id = closure.chunk_id,
                .upvalues = self.valueSlice(closure.upvalues),
            },
            else => error.InvalidObjectType,
        };
    }

    pub fn getThunk(self: *ObjectHeap, id: ObjectId) !*Thunk {
        return switch (self.get(id).*) {
            .thunk => |*thunk| thunk,
            else => error.InvalidObjectType,
        };
    }

    pub fn getCellValue(self: *const ObjectHeap, id: ObjectId) !Value {
        return switch (self.getConst(id).*) {
            .cell => |cell| cell.value,
            else => error.InvalidObjectType,
        };
    }

    pub fn setCellValue(self: *ObjectHeap, id: ObjectId, value: Value) !void {
        switch (self.get(id).*) {
            .cell => |*cell| cell.value = value,
            else => return error.InvalidObjectType,
        }
    }

    pub fn addList(self: *ObjectHeap, items: []const Value) !ObjectId {
        const range = try self.appendValues(items);
        return self.add(.{ .list = range });
    }

    pub fn addAttrs(self: *ObjectHeap, entries: []const AttrEntry) !ObjectId {
        const range = try self.appendAttrs(entries);
        return self.add(.{ .attrs = range });
    }

    pub fn addAttrsFromStackPairs(self: *ObjectHeap, pairs: []const Value) !ObjectId {
        std.debug.assert(pairs.len % 2 == 0);
        const start = self.attrs.items.len;
        try self.attrs.ensureUnusedCapacity(self.allocator, pairs.len / 2);

        var i: usize = 0;
        while (i < pairs.len) : (i += 2) {
            self.attrs.appendAssumeCapacity(.{
                .name = pairs[i].asInternId(),
                .value = pairs[i + 1],
            });
        }

        return self.add(.{ .attrs = .{
            .start = @intCast(start),
            .len = @intCast(pairs.len / 2),
        } });
    }

    pub fn addClosure(self: *ObjectHeap, chunk_id: ChunkId, upvalues: []const Value) !ObjectId {
        const range = try self.appendValues(upvalues);
        return self.add(.{ .closure = .{
            .chunk_id = chunk_id,
            .upvalues = range,
        } });
    }

    pub fn addThunk(self: *ObjectHeap, thunk: Thunk) !ObjectId {
        return self.add(.{ .thunk = thunk });
    }

    pub fn addCell(self: *ObjectHeap, cell: Cell) !ObjectId {
        return self.add(.{ .cell = cell });
    }

    fn appendValues(self: *ObjectHeap, items: []const Value) !ValueRange {
        const start = self.values.items.len;
        try self.values.appendSlice(self.allocator, items);
        return .{
            .start = @intCast(start),
            .len = @intCast(items.len),
        };
    }

    fn appendAttrs(self: *ObjectHeap, entries: []const AttrEntry) !AttrRange {
        const start = self.attrs.items.len;
        try self.attrs.appendSlice(self.allocator, entries);
        return .{
            .start = @intCast(start),
            .len = @intCast(entries.len),
        };
    }

    fn valueSlice(self: *const ObjectHeap, range: ValueRange) []const Value {
        const start: usize = range.start;
        const end = start + range.len;
        return self.values.items[start..end];
    }

    fn attrSlice(self: *const ObjectHeap, range: AttrRange) []const AttrEntry {
        const start: usize = range.start;
        const end = start + range.len;
        return self.attrs.items[start..end];
    }
};
