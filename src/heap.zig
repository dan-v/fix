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

const OBJECTS_PER_PAGE: u32 = 256;

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
    object_pages: std.ArrayListUnmanaged([]Object),
    object_count: u32,
    values: std.ArrayListUnmanaged(Value),
    attrs: std.ArrayListUnmanaged(AttrEntry),

    pub fn init(allocator: std.mem.Allocator) ObjectHeap {
        return .{
            .allocator = allocator,
            .object_pages = .empty,
            .object_count = 0,
            .values = .empty,
            .attrs = .empty,
        };
    }

    pub fn deinit(self: *ObjectHeap) void {
        for (self.object_pages.items) |page| {
            self.allocator.free(page);
        }
        self.object_pages.deinit(self.allocator);
        self.attrs.deinit(self.allocator);
        self.values.deinit(self.allocator);
    }

    pub fn add(self: *ObjectHeap, object: Object) !ObjectId {
        const id = self.object_count;
        try self.ensureObjectPage(id);
        self.objectSlot(id).* = object;
        self.object_count += 1;
        return id;
    }

    pub fn get(self: *ObjectHeap, id: ObjectId) *Object {
        std.debug.assert(id < self.object_count);
        return self.objectSlot(id);
    }

    pub fn getConst(self: *const ObjectHeap, id: ObjectId) *const Object {
        std.debug.assert(id < self.object_count);
        return self.objectSlotConst(id);
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

    pub fn getAttrValue(self: *const ObjectHeap, id: ObjectId, name: InternId) !Value {
        const entries = try self.getAttrs(id);
        var lo: usize = 0;
        var hi: usize = entries.len;

        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const entry = entries[mid];
            if (entry.name == name) return entry.value;
            if (entry.name < name) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }

        return error.MissingAttribute;
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
        self.sortAttrs(range);
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

        const range: AttrRange = .{
            .start = @intCast(start),
            .len = @intCast(pairs.len / 2),
        };
        self.sortAttrs(range);
        return self.add(.{ .attrs = range });
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

    fn attrSliceMut(self: *ObjectHeap, range: AttrRange) []AttrEntry {
        const start: usize = range.start;
        const end = start + range.len;
        return self.attrs.items[start..end];
    }

    fn sortAttrs(self: *ObjectHeap, range: AttrRange) void {
        std.mem.sort(AttrEntry, self.attrSliceMut(range), {}, attrEntryLessThan);
    }

    fn ensureObjectPage(self: *ObjectHeap, id: ObjectId) !void {
        const page_index: usize = @intCast(id / OBJECTS_PER_PAGE);
        if (page_index < self.object_pages.items.len) return;

        std.debug.assert(page_index == self.object_pages.items.len);
        const page = try self.allocator.alloc(Object, OBJECTS_PER_PAGE);
        try self.object_pages.append(self.allocator, page);
    }

    fn objectSlot(self: *ObjectHeap, id: ObjectId) *Object {
        const page_index: usize = @intCast(id / OBJECTS_PER_PAGE);
        const slot: usize = @intCast(id % OBJECTS_PER_PAGE);
        return &self.object_pages.items[page_index][slot];
    }

    fn objectSlotConst(self: *const ObjectHeap, id: ObjectId) *const Object {
        const page_index: usize = @intCast(id / OBJECTS_PER_PAGE);
        const slot: usize = @intCast(id % OBJECTS_PER_PAGE);
        return &self.object_pages.items[page_index][slot];
    }
};

fn attrEntryLessThan(_: void, lhs: AttrEntry, rhs: AttrEntry) bool {
    return lhs.name < rhs.name;
}

test "object heap stores list and attrs payloads behind object ids" {
    var heap = ObjectHeap.init(std.testing.allocator);
    defer heap.deinit();

    const list_id = try heap.addList(&.{
        Value.int(1),
        Value.int(2),
        Value.int(3),
    });

    const attrs_id = try heap.addAttrs(&.{
        .{ .name = 11, .value = Value.int(42) },
        .{ .name = 12, .value = Value.boolVal(true) },
    });

    const items = try heap.getList(list_id);
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqual(@as(i64, 1), items[0].asInt());
    try std.testing.expectEqual(@as(i64, 3), items[2].asInt());

    const entries = try heap.getAttrs(attrs_id);
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqual(@as(InternId, 11), entries[0].name);
    try std.testing.expectEqual(@as(i64, 42), entries[0].value.asInt());
    try std.testing.expect(entries[1].value.asBool());
    try std.testing.expectEqual(@as(i64, 42), (try heap.getAttrValue(attrs_id, 11)).asInt());
    try std.testing.expectError(error.MissingAttribute, heap.getAttrValue(attrs_id, 13));
}

test "object heap sorts attrs for binary lookup" {
    var heap = ObjectHeap.init(std.testing.allocator);
    defer heap.deinit();

    const attrs_id = try heap.addAttrs(&.{
        .{ .name = 30, .value = Value.int(3) },
        .{ .name = 10, .value = Value.int(1) },
        .{ .name = 20, .value = Value.int(2) },
    });

    const entries = try heap.getAttrs(attrs_id);
    try std.testing.expectEqual(@as(InternId, 10), entries[0].name);
    try std.testing.expectEqual(@as(InternId, 20), entries[1].name);
    try std.testing.expectEqual(@as(InternId, 30), entries[2].name);
    try std.testing.expectEqual(@as(i64, 1), (try heap.getAttrValue(attrs_id, 10)).asInt());
    try std.testing.expectEqual(@as(i64, 2), (try heap.getAttrValue(attrs_id, 20)).asInt());
    try std.testing.expectEqual(@as(i64, 3), (try heap.getAttrValue(attrs_id, 30)).asInt());
}

test "object heap preserves earlier ranges as side arenas grow" {
    var heap = ObjectHeap.init(std.testing.allocator);
    defer heap.deinit();

    const first_id = try heap.addList(&.{ Value.int(1), Value.int(2) });

    var i: usize = 0;
    while (i < 256) : (i += 1) {
        _ = try heap.addList(&.{
            Value.int(@intCast(i)),
            Value.int(@intCast(i + 1)),
            Value.int(@intCast(i + 2)),
        });
    }

    const first = try heap.getList(first_id);
    try std.testing.expectEqual(@as(usize, 2), first.len);
    try std.testing.expectEqual(@as(i64, 1), first[0].asInt());
    try std.testing.expectEqual(@as(i64, 2), first[1].asInt());
}

test "object heap keeps object addresses stable across page growth" {
    var heap = ObjectHeap.init(std.testing.allocator);
    defer heap.deinit();

    const first_id = try heap.addCell(.{ .value = Value.int(1) });
    const first_ptr = heap.get(first_id);
    const first_addr = @intFromPtr(first_ptr);

    var i: usize = 0;
    while (i < OBJECTS_PER_PAGE * 3) : (i += 1) {
        _ = try heap.addCell(.{ .value = Value.int(@intCast(i)) });
    }

    try std.testing.expectEqual(first_addr, @intFromPtr(heap.get(first_id)));
    try heap.setCellValue(first_id, Value.int(99));
    try std.testing.expectEqual(@as(i64, 99), (try heap.getCellValue(first_id)).asInt());
}

test "object heap stores closures and mutable runtime cells" {
    var heap = ObjectHeap.init(std.testing.allocator);
    defer heap.deinit();

    const closure_id = try heap.addClosure(7, &.{ Value.int(10), Value.boolVal(false) });
    const closure = try heap.getClosure(closure_id);
    try std.testing.expectEqual(@as(ChunkId, 7), closure.chunk_id);
    try std.testing.expectEqual(@as(usize, 2), closure.upvalues.len);
    try std.testing.expectEqual(@as(i64, 10), closure.upvalues[0].asInt());
    try std.testing.expect(!closure.upvalues[1].asBool());

    const cell_id = try heap.addCell(.{ .value = Value.int(1) });
    try std.testing.expectEqual(@as(i64, 1), (try heap.getCellValue(cell_id)).asInt());
    try heap.setCellValue(cell_id, Value.int(2));
    try std.testing.expectEqual(@as(i64, 2), (try heap.getCellValue(cell_id)).asInt());
}
