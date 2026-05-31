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

pub const Closure = struct {
    chunk_id: ChunkId,
    upvalues: []Value,
};

pub const Object = union(enum) {
    list: []Value,
    attrs: []AttrEntry,
    closure: Closure,
    thunk: Thunk,
    cell: Cell,
};

pub const ObjectHeap = struct {
    allocator: std.mem.Allocator,
    objects: std.ArrayListUnmanaged(Object),

    pub fn init(allocator: std.mem.Allocator) ObjectHeap {
        return .{
            .allocator = allocator,
            .objects = .empty,
        };
    }

    pub fn deinit(self: *ObjectHeap) void {
        for (self.objects.items) |object| {
            switch (object) {
                .list => |items| self.allocator.free(items),
                .attrs => |entries| self.allocator.free(entries),
                .closure => |closure| self.allocator.free(closure.upvalues),
                .thunk, .cell => {},
            }
        }
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
            .list => |items| items,
            else => error.InvalidObjectType,
        };
    }

    pub fn getAttrs(self: *const ObjectHeap, id: ObjectId) ![]const AttrEntry {
        return switch (self.getConst(id).*) {
            .attrs => |entries| entries,
            else => error.InvalidObjectType,
        };
    }

    pub fn getClosure(self: *const ObjectHeap, id: ObjectId) !Closure {
        return switch (self.getConst(id).*) {
            .closure => |closure| closure,
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

    pub fn addList(self: *ObjectHeap, items: []Value) !ObjectId {
        return self.add(.{ .list = items });
    }

    pub fn addAttrs(self: *ObjectHeap, entries: []AttrEntry) !ObjectId {
        return self.add(.{ .attrs = entries });
    }

    pub fn addClosure(self: *ObjectHeap, chunk_id: ChunkId, upvalues: []Value) !ObjectId {
        return self.add(.{ .closure = .{
            .chunk_id = chunk_id,
            .upvalues = upvalues,
        } });
    }

    pub fn addThunk(self: *ObjectHeap, thunk: Thunk) !ObjectId {
        return self.add(.{ .thunk = thunk });
    }

    pub fn addCell(self: *ObjectHeap, cell: Cell) !ObjectId {
        return self.add(.{ .cell = cell });
    }
};
