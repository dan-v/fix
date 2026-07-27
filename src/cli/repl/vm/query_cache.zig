//! Owned indexes used by bounded text-mode VM queries.

const std = @import("std");
const engine = @import("expr");
const runtime = @import("runtime");
const vm_refs = @import("refs.zig");

const Engine = engine.Engine;

pub const Cache = struct {
    names: ?engine.bytecode.inspect.NameIndex = null,
    objects: ?runtime.ObjectHeap.ObjectSnapshot = null,
    values: ?runtime.ObjectHeap.ObjectSnapshot = null,
    attrs: ?runtime.ObjectHeap.ObjectSnapshot = null,
    attr_positions: ?runtime.ObjectHeap.ObjectSnapshot = null,
    references: ?vm_refs.Graph = null,
    equivalence: ?engine.bytecode.inspect.ChunkEquivalenceIndex = null,

    pub fn deinit(self: *Cache) void {
        if (self.names) |*index| index.deinit();
        self.clearRuntime();
        if (self.equivalence) |*index| index.deinit();
        self.* = .{};
    }

    /// Invalidate every projection that depends on the live heap. Name and
    /// equivalence indexes validate their append-only registry generations
    /// lazily and can survive an ordinary evaluation.
    pub fn clearRuntime(self: *Cache) void {
        if (self.objects) |*snapshot| snapshot.deinit();
        if (self.values) |*snapshot| snapshot.deinit();
        if (self.attrs) |*snapshot| snapshot.deinit();
        if (self.attr_positions) |*snapshot| snapshot.deinit();
        if (self.references) |*graph| graph.deinit();
        self.objects = null;
        self.values = null;
        self.attrs = null;
        self.attr_positions = null;
        self.references = null;
    }

    pub fn objectSnapshot(self: *Cache, allocator: std.mem.Allocator, ev: *Engine) !*runtime.ObjectHeap.ObjectSnapshot {
        if (self.objects == null)
            self.objects = try ev.heapObjectSnapshot(allocator);
        return &self.objects.?;
    }

    pub fn storeSnapshot(
        self: *Cache,
        allocator: std.mem.Allocator,
        ev: *Engine,
        store: Store,
    ) !*runtime.ObjectHeap.ObjectSnapshot {
        const slot: *?runtime.ObjectHeap.ObjectSnapshot = switch (store) {
            .objects => &self.objects,
            .values => &self.values,
            .attrs => &self.attrs,
            .attr_positions => &self.attr_positions,
            .intern, .builtin => return error.DenseStoreHasNoSnapshot,
        };
        if (slot.* == null) slot.* = try switch (store) {
            .objects => ev.heapObjectSnapshot(allocator),
            .values => ev.heapValueSnapshot(allocator),
            .attrs => ev.heapAttrSnapshot(allocator),
            .attr_positions => ev.heapAttrPosSnapshot(allocator),
            .intern, .builtin => unreachable,
        };
        return &slot.*.?;
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

    pub fn referenceGraph(self: *Cache, allocator: std.mem.Allocator, ev: *Engine) !*vm_refs.Graph {
        const registry_count = ev.chunkRegistry().count();
        const object_high_water = ev.heapCounts().objects;
        if (self.references) |*graph| {
            if (graph.registry_count == registry_count and graph.object_high_water == object_high_water)
                return graph;
            graph.deinit();
            self.references = null;
        }
        self.references = try vm_refs.Graph.build(allocator, ev);
        return &self.references.?;
    }

    pub fn equivalenceIndex(
        self: *Cache,
        allocator: std.mem.Allocator,
        ev: *Engine,
    ) !*engine.bytecode.inspect.ChunkEquivalenceIndex {
        const registry = ev.chunkRegistry();
        if (self.equivalence) |*index| {
            if (index.total == registry.count()) return index;
            index.deinit();
            self.equivalence = null;
        }
        self.equivalence = try engine.bytecode.inspect.ChunkEquivalenceIndex.build(allocator, registry);
        return &self.equivalence.?;
    }
};

pub const Store = enum {
    objects,
    values,
    attrs,
    attr_positions,
    intern,
    builtin,
};
