const std = @import("std");
const heap_mod = @import("../heap.zig");
const Value = @import("../value.zig").Value;
const ObjectHeap = heap_mod.ObjectHeap;
const InternId = heap_mod.InternId;
const ChunkId = heap_mod.ChunkId;
const OBJECTS_PER_PAGE = heap_mod.OBJECTS_PER_PAGE;
const VALUES_PER_PAGE = heap_mod.VALUES_PER_PAGE;
const ATTRS_PER_PAGE = heap_mod.ATTRS_PER_PAGE;

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
    try std.testing.expectEqual(@as(usize, 3), try heap.getListLen(list_id));
    try std.testing.expectEqual(@as(i64, 1), items[0].asInt());
    try std.testing.expectEqual(@as(i64, 3), items[2].asInt());
    try std.testing.expectEqual(@as(i64, 2), (try heap.getListItem(list_id, 1)).asInt());
    try std.testing.expectError(error.IndexOutOfBounds, heap.getListItem(list_id, 3));

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

test "object heap stores attr positions as object metadata" {
    var heap = ObjectHeap.init(std.testing.allocator);
    defer heap.deinit();

    const left_id = try heap.addAttrsWithPositions(
        &.{
            .{ .name = 10, .value = Value.int(1) },
            .{ .name = 20, .value = Value.int(2) },
        },
        &.{
            .{ .name = 20, .pos = .{ .file = 99, .line = 3, .column = 5 } },
            .{ .name = 10, .pos = .{ .file = 99, .line = 2, .column = 7 } },
        },
    );

    const left_pos = heap.getAttrPos(left_id, 10).?;
    try std.testing.expectEqual(@as(InternId, 99), left_pos.file);
    try std.testing.expectEqual(@as(u32, 2), left_pos.line);
    try std.testing.expectEqual(@as(u32, 7), left_pos.column);

    const right_id = try heap.addAttrs(&.{
        .{ .name = 10, .value = Value.int(3) },
        .{ .name = 30, .value = Value.int(4) },
    });
    const merged_id = try heap.addMergedAttrs(left_id, right_id);

    try std.testing.expectEqual(@as(i64, 3), (try heap.getAttrValue(merged_id, 10)).asInt());
    try std.testing.expectEqual(null, heap.getAttrPos(merged_id, 10));
    try std.testing.expect(heap.getAttrPos(merged_id, 20) != null);
}

test "object heap rejects duplicate attrs and rolls back side entries" {
    var heap = ObjectHeap.init(std.testing.allocator);
    defer heap.deinit();

    try std.testing.expectError(error.DuplicateAttribute, heap.addAttrs(&.{
        .{ .name = 10, .value = Value.int(1) },
        .{ .name = 20, .value = Value.int(2) },
        .{ .name = 10, .value = Value.int(3) },
    }));

    if (heap.attr_page_used.items.len > 0) {
        try std.testing.expectEqual(@as(u32, 0), heap.attr_page_used.items[0]);
    }

    const attrs_id = try heap.addAttrs(&.{
        .{ .name = 10, .value = Value.int(1) },
        .{ .name = 20, .value = Value.int(2) },
    });
    try std.testing.expectEqual(@as(i64, 1), (try heap.getAttrValue(attrs_id, 10)).asInt());
}

test "object heap preserves earlier ranges as side arenas grow" {
    var heap = ObjectHeap.init(std.testing.allocator);
    defer heap.deinit();

    const first_id = try heap.addList(&.{ Value.int(1), Value.int(2) });
    const first_ptr = (try heap.getList(first_id)).ptr;

    var i: usize = 0;
    while (i < VALUES_PER_PAGE * 3) : (i += 1) {
        _ = try heap.addList(&.{
            Value.int(@intCast(i)),
            Value.int(@intCast(i + 1)),
            Value.int(@intCast(i + 2)),
        });
    }

    const first = try heap.getList(first_id);
    try std.testing.expectEqual(first_ptr, first.ptr);
    try std.testing.expectEqual(@as(usize, 2), first.len);
    try std.testing.expectEqual(@as(i64, 1), first[0].asInt());
    try std.testing.expectEqual(@as(i64, 2), first[1].asInt());

    const attrs_id = try heap.addAttrs(&.{
        .{ .name = 1, .value = Value.int(1) },
        .{ .name = 2, .value = Value.int(2) },
    });
    const attrs_ptr = (try heap.getAttrs(attrs_id)).ptr;

    i = 0;
    while (i < ATTRS_PER_PAGE * 3) : (i += 1) {
        _ = try heap.addAttrs(&.{
            .{ .name = @intCast(i * 3 + 10), .value = Value.int(@intCast(i)) },
            .{ .name = @intCast(i * 3 + 11), .value = Value.int(@intCast(i + 1)) },
            .{ .name = @intCast(i * 3 + 12), .value = Value.int(@intCast(i + 2)) },
        });
    }

    const first_attrs = try heap.getAttrs(attrs_id);
    try std.testing.expectEqual(attrs_ptr, first_attrs.ptr);
    try std.testing.expectEqual(@as(i64, 2), (try heap.getAttrValue(attrs_id, 2)).asInt());
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
