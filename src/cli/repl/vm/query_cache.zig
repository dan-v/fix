//! Owned indexes used by bounded text-mode VM queries.

const std = @import("std");
const engine = @import("expr");
const runtime = @import("runtime");

const Engine = engine.Engine;

pub const Cache = struct {
    names: ?engine.bytecode.inspect.NameIndex = null,
    objects: ?runtime.ObjectHeap.ObjectSnapshot = null,

    pub fn deinit(self: *Cache) void {
        if (self.names) |*index| index.deinit();
        if (self.objects) |*snapshot| snapshot.deinit();
        self.* = .{};
    }

    pub fn clearObjects(self: *Cache) void {
        if (self.objects) |*snapshot| snapshot.deinit();
        self.objects = null;
    }

    pub fn objectSnapshot(self: *Cache, allocator: std.mem.Allocator, ev: *Engine) !*runtime.ObjectHeap.ObjectSnapshot {
        if (self.objects == null)
            self.objects = try ev.heapObjectSnapshot(allocator);
        return &self.objects.?;
    }

    pub fn nameIndex(self: *Cache, allocator: std.mem.Allocator, ev: *Engine) !*engine.bytecode.inspect.NameIndex {
        const registry = ev.chunkRegistry();
        if (self.names) |*index| {
            if (index.registry_count == registry.count() and index.name_count == registry.nameCount())
                return index;
            index.deinit();
            self.names = null;
        }
        self.names = try engine.bytecode.inspect.NameIndex.build(allocator, registry);
        return &self.names.?;
    }
};
