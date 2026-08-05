const std = @import("std");
const heap_mod = @import("../heap.zig");
const heap_collector = @import("collector.zig");
const Value = @import("../value.zig").Value;
const ObjectHeap = heap_mod.ObjectHeap;
const InternId = heap_mod.InternId;
const ChunkId = heap_mod.ChunkId;
const Thunk = @import("../thunk.zig").Thunk;

test "object heap exposes cheap backing-store counts" {
    var heap = try ObjectHeap.init(std.testing.allocator, 1);
    defer heap.deinit();

    const empty = heap.counts();
    try std.testing.expectEqual(@as(u32, 0), empty.objects);
    try std.testing.expectEqual(@as(u32, 0), empty.values);
    try std.testing.expectEqual(@as(u32, 0), empty.attrs);
    try std.testing.expectEqual(@as(u32, 0), empty.attr_positions);
    _ = try heap.addList(&.{ Value.int(1), Value.int(2) });
    const with_list = heap.counts();
    try std.testing.expect(with_list.objects > empty.objects);
    try std.testing.expect(with_list.values > empty.values);
    try std.testing.expectEqual(empty.attrs, with_list.attrs);
    try std.testing.expectEqual(empty.attr_positions, with_list.attr_positions);

    _ = try heap.addAttrsWithPositions(
        &.{.{ .name = 10, .value = Value.int(3) }},
        &.{.{ .name = 10, .pos = .{ .file = 1, .line = 2, .column = 3 } }},
    );
    const with_attrs = heap.counts();
    try std.testing.expect(with_attrs.objects >= with_list.objects);
    try std.testing.expect(with_attrs.values >= with_list.values);
    try std.testing.expect(with_attrs.attrs > with_list.attrs);
    try std.testing.expect(with_attrs.attr_positions > with_list.attr_positions);
}

test "object heap stores list and attrs payloads behind object ids" {
    var heap = try ObjectHeap.init(std.testing.allocator, 1);
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

    const entries = try heap.materializeAttrs(attrs_id);
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqual(@as(InternId, 11), entries[0].name);
    try std.testing.expectEqual(@as(i64, 42), entries[0].value.asInt());
    try std.testing.expect(entries[1].value.asBool());
    try std.testing.expectEqual(@as(i64, 42), (try heap.getAttrValue(attrs_id, 11)).asInt());
    try std.testing.expectError(error.MissingAttribute, heap.getAttrValue(attrs_id, 13));
}

test "object construction abort restores the reserved slot" {
    var heap = try ObjectHeap.init(std.testing.allocator, 1);
    defer heap.deinit();

    const abandoned = try heap.beginObjectSlot();
    heap.abortObjectSlot(abandoned);

    const committed = try heap.addBoxedInt(42);
    try std.testing.expectEqual(abandoned.id, committed);
    var snapshot = try heap.objectSnapshot(std.testing.allocator);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(u32, 1), snapshot.live_count);
    try std.testing.expect(snapshot.isLive(committed));
}

test "object construction does not consume an id when young tracking allocation fails" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var heap = try ObjectHeap.init(failing.allocator(), 1);
    defer heap.deinit();
    heap_collector.enableCollect(&heap, 64 << 20, 0);

    const before = heap.counts();
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, heap.addBoxedInt(1));
    try std.testing.expectEqual(before.objects, heap.counts().objects);

    failing.fail_index = std.math.maxInt(usize);
    const id = try heap.addBoxedInt(2);
    try std.testing.expectEqual(@as(i64, 2), try heap.getBoxedInt(id));
}

test "object snapshot indexes only filled slots and exposes semantic details" {
    var heap = try ObjectHeap.init(std.testing.allocator, 1);
    defer heap.deinit();

    const list_id = try heap.addList(&.{ Value.int(1), Value.int(2) });
    const closure_id = try heap.addClosure(17, &.{Value.list(list_id)});

    var snapshot = try heap.objectSnapshot(std.testing.allocator);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(u32, 2), snapshot.live_count);
    try std.testing.expectEqual(closure_id + 1, snapshot.liveExtent());
    try std.testing.expectEqual(list_id, snapshot.nextLive(0).?);
    try std.testing.expectEqual(closure_id, snapshot.nextLive(list_id + 1).?);
    try std.testing.expect(snapshot.nextLive(closure_id + 1) == null);

    const list = try heap.inspectObject(&snapshot, list_id);
    try std.testing.expectEqual(@as(u32, 2), list.list.len);
    const closure = try heap.inspectObject(&snapshot, closure_id);
    try std.testing.expectEqual(@as(ChunkId, 17), closure.closure.chunk);
    try std.testing.expectEqual(@as(u32, 1), closure.closure.upvalues);
    try std.testing.expectError(error.InvalidObjectId, heap.inspectObject(&snapshot, snapshot.high_water - 1));
}

test "object reference inspection follows objects and chunks without recursion" {
    var heap = try ObjectHeap.init(std.testing.allocator, 1);
    defer heap.deinit();

    const child_id = try heap.addList(&.{Value.int(7)});
    const parent_id = try heap.addAttrs(&.{
        .{ .name = 10, .value = Value.list(child_id) },
        .{ .name = 20, .value = Value.function(0x2a) },
        .{ .name = 30, .value = Value.string(99) },
    });
    const closure_id = try heap.addClosure(0x31, &.{
        Value.attrs(parent_id),
        Value.function(0x32),
    });

    var snapshot = try heap.objectSnapshot(std.testing.allocator);
    defer snapshot.deinit();

    var refs: std.ArrayListUnmanaged(heap_mod.HeapReference) = .empty;
    defer refs.deinit(std.testing.allocator);
    try @import("edges.zig").collectReferences(&heap, &snapshot, parent_id, std.testing.allocator, &refs);
    try std.testing.expectEqualSlices(heap_mod.HeapReference, &.{
        .{ .object = child_id },
        .{ .chunk = 0x2a },
    }, refs.items);

    refs.clearRetainingCapacity();
    try @import("edges.zig").collectReferences(&heap, &snapshot, closure_id, std.testing.allocator, &refs);
    try std.testing.expectEqualSlices(heap_mod.HeapReference, &.{
        .{ .chunk = 0x31 },
        .{ .object = parent_id },
        .{ .chunk = 0x32 },
    }, refs.items);

    const position_table = [_]heap_mod.AttrPosEntry{.{
        .name = 40,
        .pos = .{ .file = 1, .line = 2, .column = 3 },
    }};
    const Resolver = struct {
        fn resolve(ctx: *anyopaque, _: u32) []const heap_mod.AttrPosEntry {
            const table: *const [1]heap_mod.AttrPosEntry = @ptrCast(@alignCast(ctx));
            return table;
        }
    };
    heap.setChunkAttrPosResolver(.{
        .ctx = @ptrCast(@constCast(&position_table)),
        .resolve = Resolver.resolve,
    });
    const positioned_id = try heap.addAttrsFromValuesSorted(
        &.{40},
        &.{Value.list(child_id)},
        heap_mod.AttrPositions.fromChunk(0x44, 0, 1),
    );

    snapshot.deinit();
    snapshot = try heap.objectSnapshot(std.testing.allocator);
    refs.clearRetainingCapacity();
    try @import("edges.zig").collectReferences(&heap, &snapshot, positioned_id, std.testing.allocator, &refs);
    try std.testing.expectEqualSlices(heap_mod.HeapReference, &.{
        .{ .object = child_id },
        .{ .chunk = 0x44 },
    }, refs.items);
}

test "range-store snapshots index only live records, not reserved capacity" {
    var heap = try ObjectHeap.init(std.testing.allocator, 1);
    defer heap.deinit();

    // A 3-element list fills 3 value slots; the rest of the worker's value TLAB
    // is reserved but unfilled and must NOT show up as live.
    _ = try heap.addList(&.{ Value.int(1), Value.int(2), Value.int(3) });
    const value_count = heap.counts().values;

    var values = try heap.valueSnapshot(std.testing.allocator);
    defer values.deinit();
    try std.testing.expectEqual(value_count, values.high_water);
    // The 3 filled slots are live; the reserved TLAB tail is excluded.
    try std.testing.expectEqual(@as(u32, 3), values.live_count);
    try std.testing.expectEqual(@as(u32, 3), values.liveExtent());
    try std.testing.expect(values.live_count <= values.high_water);
    try std.testing.expect(values.nextLive(0) != null);

    _ = try heap.addAttrs(&.{
        .{ .name = 10, .value = Value.int(1) },
        .{ .name = 20, .value = Value.int(2) },
    });
    var attrs = try heap.attrSnapshot(std.testing.allocator);
    defer attrs.deinit();
    try std.testing.expectEqual(@as(u32, 2), attrs.live_count);
    try std.testing.expect(attrs.live_count <= attrs.high_water);
}

test "object heap sorts attrs for binary lookup" {
    var heap = try ObjectHeap.init(std.testing.allocator, 1);
    defer heap.deinit();

    const attrs_id = try heap.addAttrs(&.{
        .{ .name = 30, .value = Value.int(3) },
        .{ .name = 10, .value = Value.int(1) },
        .{ .name = 20, .value = Value.int(2) },
    });

    const entries = try heap.materializeAttrs(attrs_id);
    try std.testing.expectEqual(@as(InternId, 10), entries[0].name);
    try std.testing.expectEqual(@as(InternId, 20), entries[1].name);
    try std.testing.expectEqual(@as(InternId, 30), entries[2].name);
    try std.testing.expectEqual(@as(i64, 1), (try heap.getAttrValue(attrs_id, 10)).asInt());
    try std.testing.expectEqual(@as(i64, 2), (try heap.getAttrValue(attrs_id, 20)).asInt());
    try std.testing.expectEqual(@as(i64, 3), (try heap.getAttrValue(attrs_id, 30)).asInt());
}

test "object heap stores attr positions as object metadata" {
    var heap = try ObjectHeap.init(std.testing.allocator, 1);
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

test "object heap rejects duplicate attrs" {
    var heap = try ObjectHeap.init(std.testing.allocator, 1);
    defer heap.deinit();

    try std.testing.expectError(error.DuplicateAttribute, heap.addAttrs(&.{
        .{ .name = 10, .value = Value.int(1) },
        .{ .name = 20, .value = Value.int(2) },
        .{ .name = 10, .value = Value.int(3) },
    }));

    var objects_after_error = try heap.objectSnapshot(std.testing.allocator);
    defer objects_after_error.deinit();
    var attrs_after_error = try heap.attrSnapshot(std.testing.allocator);
    defer attrs_after_error.deinit();
    try std.testing.expectEqual(@as(u32, 0), objects_after_error.live_count);
    try std.testing.expectEqual(@as(u32, 0), attrs_after_error.live_count);

    // Subsequent non-duplicate adds still work.
    const attrs_id = try heap.addAttrs(&.{
        .{ .name = 10, .value = Value.int(1) },
        .{ .name = 20, .value = Value.int(2) },
    });
    try std.testing.expectEqual(@as(i64, 1), (try heap.getAttrValue(attrs_id, 10)).asInt());
}

test "multi-store attr construction rolls back when positions allocation fails" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var heap = try ObjectHeap.init(failing.allocator(), 1);
    defer heap.deinit();

    // Prewarm object and attr TLABs; the first attr-position segment remains
    // the next allocation point.
    _ = try heap.addAttrs(&.{.{ .name = 1, .value = Value.int(1) }});
    var before_objects = try heap.objectSnapshot(std.testing.allocator);
    defer before_objects.deinit();
    var before_attrs = try heap.attrSnapshot(std.testing.allocator);
    defer before_attrs.deinit();

    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, heap.addAttrsWithPositions(
        &.{.{ .name = 2, .value = Value.int(2) }},
        &.{.{ .name = 2, .pos = .{ .file = 3, .line = 4, .column = 5 } }},
    ));
    var after_objects = try heap.objectSnapshot(std.testing.allocator);
    defer after_objects.deinit();
    var after_attrs = try heap.attrSnapshot(std.testing.allocator);
    defer after_attrs.deinit();
    try std.testing.expectEqual(before_objects.live_count, after_objects.live_count);
    try std.testing.expectEqual(before_attrs.live_count, after_attrs.live_count);

    failing.fail_index = std.math.maxInt(usize);
    _ = try heap.addAttrsWithPositions(
        &.{.{ .name = 2, .value = Value.int(2) }},
        &.{.{ .name = 2, .pos = .{ .file = 3, .line = 4, .column = 5 } }},
    );
}

test "pending attr merges return storage before collection is armed" {
    var heap = try ObjectHeap.init(std.testing.allocator, 1);
    defer heap.deinit();

    const first = try heap.reserveAttrsForMerge(7);
    heap.abortMergedAttrs(first);
    const second = try heap.reserveAttrsForMerge(7);
    defer heap.abortMergedAttrs(second);
    try std.testing.expectEqual(first.range.segment, second.range.segment);
    try std.testing.expectEqual(first.range.offset, second.range.offset);
}

test "object heap preserves earlier ranges as side arenas grow" {
    var heap = try ObjectHeap.init(std.testing.allocator, 1);
    defer heap.deinit();

    const first_id = try heap.addList(&.{ Value.int(1), Value.int(2) });
    const first_ptr = (try heap.getList(first_id)).ptr;

    // Cross a few segment boundaries.
    var i: usize = 0;
    while (i < 4096) : (i += 1) {
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
    const attrs_ptr = (try heap.materializeAttrs(attrs_id)).ptr;

    i = 0;
    while (i < 4096) : (i += 1) {
        _ = try heap.addAttrs(&.{
            .{ .name = @intCast(i * 3 + 10), .value = Value.int(@intCast(i)) },
            .{ .name = @intCast(i * 3 + 11), .value = Value.int(@intCast(i + 1)) },
            .{ .name = @intCast(i * 3 + 12), .value = Value.int(@intCast(i + 2)) },
        });
    }

    const first_attrs = try heap.materializeAttrs(attrs_id);
    try std.testing.expectEqual(attrs_ptr, first_attrs.ptr);
    try std.testing.expectEqual(@as(i64, 2), (try heap.getAttrValue(attrs_id, 2)).asInt());
}

test "object heap keeps object addresses stable across segment growth" {
    var heap = try ObjectHeap.init(std.testing.allocator, 1);
    defer heap.deinit();

    const first_id = try heap.addThunk(Thunk.initPassThrough(Value.int(1)));
    const first_ptr = heap.get(first_id);
    const first_addr = @intFromPtr(first_ptr);

    var i: usize = 0;
    while (i < 4096) : (i += 1) {
        _ = try heap.addThunk(Thunk.initPassThrough(Value.int(@intCast(i))));
    }

    try std.testing.expectEqual(first_addr, @intFromPtr(heap.get(first_id)));
}

test "object heap stores closures" {
    var heap = try ObjectHeap.init(std.testing.allocator, 1);
    defer heap.deinit();

    const closure_id = try heap.addClosure(7, &.{ Value.int(10), Value.boolVal(false) });
    const closure = try heap.getClosure(closure_id);
    try std.testing.expectEqual(@as(ChunkId, 7), closure.chunk_id);
    try std.testing.expectEqual(@as(usize, 2), closure.upvalues.len);
    try std.testing.expectEqual(@as(i64, 10), closure.upvalues[0].asInt());
    try std.testing.expect(!closure.upvalues[1].asBool());
}

test "object heap supports empty lists and empty attrs" {
    var heap = try ObjectHeap.init(std.testing.allocator, 1);
    defer heap.deinit();

    const list_id = try heap.addList(&.{});
    try std.testing.expectEqual(@as(usize, 0), try heap.getListLen(list_id));
    try std.testing.expectError(error.IndexOutOfBounds, heap.getListItem(list_id, 0));

    const attrs_id = try heap.addAttrs(&.{});
    const entries = try heap.materializeAttrs(attrs_id);
    try std.testing.expectEqual(@as(usize, 0), entries.len);
    try std.testing.expectError(error.MissingAttribute, heap.getAttrValue(attrs_id, 1));
}

test "empty lists and attrs are interned to shared singletons after bootstrap" {
    var heap = try ObjectHeap.init(std.testing.allocator, 1);
    defer heap.deinit();

    // Before bootstrap: every empty construction allocates a fresh slot, so
    // direct-heap unit tests keep their old object identities.
    const pre_list = try heap.addList(&.{});
    const pre_attrs = try heap.addAttrs(&.{});
    try std.testing.expect(pre_list != try heap.addList(&.{}));
    try std.testing.expect(pre_attrs != try heap.addAttrs(&.{}));

    try heap.ensureEmptySingletons();
    try std.testing.expect(heap.empty_list_id != null);
    try std.testing.expect(heap.empty_attrs_id != null);

    // After bootstrap every empty (across all construction paths) collapses to
    // the one shared id, and it still reads back as an empty container.
    const a = try heap.addList(&.{});
    const b = try heap.addList(&.{});
    try std.testing.expectEqual(heap.empty_list_id.?, a);
    try std.testing.expectEqual(a, b);
    try std.testing.expectEqual(@as(usize, 0), try heap.getListLen(a));

    const p = try heap.addAttrs(&.{});
    const q = try heap.addAttrsSorted(&.{});
    const r = try heap.addAttrsFromValuesSorted(&.{}, &.{}, .none);
    const s = try heap.addAttrsFromStackPairs(&.{});
    try std.testing.expectEqual(heap.empty_attrs_id.?, p);
    try std.testing.expectEqual(p, q);
    try std.testing.expectEqual(p, r);
    try std.testing.expectEqual(p, s);
    try std.testing.expectEqual(@as(usize, 0), (try heap.materializeAttrs(p)).len);

    // Bootstrapping again is a no-op — the ids are stable.
    const list_before = heap.empty_list_id.?;
    try heap.ensureEmptySingletons();
    try std.testing.expectEqual(list_before, heap.empty_list_id.?);
}

test "object heap supports a single-entry attrs object" {
    var heap = try ObjectHeap.init(std.testing.allocator, 1);
    defer heap.deinit();

    const attrs_id = try heap.addAttrs(&.{
        .{ .name = 5, .value = Value.int(99) },
    });

    const entries = try heap.materializeAttrs(attrs_id);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqual(@as(InternId, 5), entries[0].name);
    try std.testing.expectEqual(@as(i64, 99), (try heap.getAttrValue(attrs_id, 5)).asInt());
    try std.testing.expectError(error.MissingAttribute, heap.getAttrValue(attrs_id, 6));
}

test "object heap sweep frees unmarked objects and lets ids be reused" {
    var heap = try ObjectHeap.init(std.testing.allocator, 1);
    defer heap.deinit();
    heap_collector.enableCollect(&heap, 64 << 20, 0);

    // Two live (reachable) lists, two dead (unreferenced) lists.
    const live_a = try heap.addList(&.{Value.int(1)});
    const live_b = try heap.addList(&.{Value.int(2)});
    _ = try heap.addList(&.{Value.int(3)});
    _ = try heap.addList(&.{Value.int(4)});

    var tr = @import("../gc.zig").Tracer.init(std.testing.allocator);
    defer tr.deinit();
    try tr.reset(heap.objects.count());
    tr.markValue(&heap, Value.list(live_a));
    tr.markValue(&heap, Value.list(live_b));
    tr.drain(&heap);

    const st = heap_collector.sweep(&heap, tr.mark_bits);
    try std.testing.expectEqual(@as(u64, 2), st.objects_freed);

    var snapshot = try heap.objectSnapshot(std.testing.allocator);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(u32, 2), snapshot.live_count);
    try std.testing.expect(snapshot.isLive(live_a));
    try std.testing.expect(snapshot.isLive(live_b));

    // The marked objects still read back their original contents.
    try std.testing.expectEqual(@as(i64, 1), (try heap.getListItem(live_a, 0)).asInt());
    try std.testing.expectEqual(@as(i64, 2), (try heap.getListItem(live_b, 0)).asInt());

    // A subsequent allocation reuses a freed slot without growing the store.
    const objects_before_reuse = heap.objects.count();
    const reused_attrs = try heap.addAttrs(&.{
        .{ .name = 1, .value = Value.int(7) },
    });
    try std.testing.expectEqual(objects_before_reuse, heap.objects.count());
    const reused_entries = try heap.materializeAttrs(reused_attrs);
    try std.testing.expectEqual(@as(usize, 1), reused_entries.len);
    try std.testing.expectEqual(@as(i64, 7), (try heap.getAttrValue(reused_attrs, 1)).asInt());
}
