//! Background snapshots used by the interactive VM explorer.
//!
//! Workers never mutate display state. They build an owned result with the
//! SMP allocator, publish it behind a mutex, and let the terminal thread adopt
//! it between frames. Keeping that lifecycle here leaves the explorer focused
//! on navigation and rendering.

const std = @import("std");
const sync = @import("base").sync;
const engine = @import("expr");
const runtime = @import("runtime");
const vm_tree = @import("tree.zig");
const vm_refs = @import("refs.zig");

const Engine = engine.Engine;
const bytecode = engine.bytecode;

/// All background work owned by one explorer session. The aggregate keeps
/// thread cleanup and command-boundary invalidation in one lifecycle object.
pub const Session = struct {
    names: NameIndex,
    heap: HeapCensus,
    objects: ObjectSnapshot,
    references: References,

    pub fn init(ev: *Engine) Session {
        return .{
            .names = .{
                .registry = ev.chunkRegistry(),
                .intern = ev.internTable(),
                .base_path = ev.basePath(),
            },
            .heap = .{ .ev = ev },
            .objects = .{ .ev = ev },
            .references = .{ .ev = ev },
        };
    }

    pub fn deinit(self: *Session) void {
        self.names.deinit();
        self.heap.deinit();
        self.objects.deinit();
        self.references.deinit();
    }

    pub fn finish(
        self: *Session,
        tree_index: *vm_tree.Index,
        stats: *?runtime.ObjectHeap.Stats,
        objects: *?runtime.ObjectHeap.ObjectSnapshot,
        references: *?vm_refs.Graph,
    ) void {
        _ = self.names.finish(tree_index);
        self.heap.finish(stats);
        self.objects.finish(objects);
        _ = self.references.finish(references);
    }

    pub fn clearFailures(self: *Session) void {
        self.names.failed.store(false, .release);
        self.objects.failed.store(false, .release);
        self.references.failed.store(false, .release);
    }

    pub fn hasThread(self: *const Session) bool {
        return self.names.thread != null or
            self.heap.thread != null or
            self.objects.thread != null or
            self.references.thread != null;
    }
};

pub const NameIndex = struct {
    registry: *const bytecode.ChunkRegistry,
    intern: *const runtime.InternTable,
    base_path: ?[]const u8,
    thread: ?std.Thread = null,
    mutex: sync.BlockingMutex = .{},
    ready: ?vm_tree.Index = null,
    running: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),

    pub fn start(self: *NameIndex) !void {
        if (self.thread != null) return;
        self.running.store(true, .release);
        self.thread = std.Thread.spawn(.{}, build, .{self}) catch |err| {
            self.failed.store(true, .release);
            self.running.store(false, .release);
            return err;
        };
    }

    fn build(self: *NameIndex) void {
        const result = vm_tree.Index.build(std.heap.smp_allocator, self.registry, self.intern, self.base_path) catch {
            self.failed.store(true, .release);
            self.running.store(false, .release);
            return;
        };
        self.mutex.lock();
        self.ready = result;
        self.mutex.unlock();
        self.running.store(false, .release);
    }

    pub fn poll(self: *NameIndex, current: *vm_tree.Index) bool {
        if (self.thread == null or self.running.load(.acquire)) return false;
        return self.finish(current);
    }

    pub fn finish(self: *NameIndex, current: *vm_tree.Index) bool {
        const thread = self.thread orelse return false;
        thread.join();
        self.thread = null;
        self.mutex.lock();
        const next = self.ready;
        self.ready = null;
        self.mutex.unlock();
        if (next) |index| {
            current.deinit();
            current.* = index;
            return true;
        }
        return false;
    }

    pub fn deinit(self: *NameIndex) void {
        if (self.thread) |thread| thread.join();
        self.thread = null;
        self.mutex.lock();
        if (self.ready) |*index| index.deinit();
        self.ready = null;
        self.mutex.unlock();
    }
};

pub const HeapCensus = struct {
    ev: *Engine,
    thread: ?std.Thread = null,
    mutex: sync.BlockingMutex = .{},
    ready: ?runtime.ObjectHeap.Stats = null,
    running: std.atomic.Value(bool) = .init(false),

    pub fn start(self: *HeapCensus) !void {
        if (self.thread != null) return;
        self.running.store(true, .release);
        self.thread = std.Thread.spawn(.{}, build, .{self}) catch |err| {
            self.running.store(false, .release);
            return err;
        };
    }

    fn build(self: *HeapCensus) void {
        const result = self.ev.heapStats();
        self.mutex.lock();
        self.ready = result;
        self.mutex.unlock();
        self.running.store(false, .release);
    }

    pub fn poll(self: *HeapCensus, target: *?runtime.ObjectHeap.Stats) bool {
        if (self.thread == null or self.running.load(.acquire)) return false;
        self.finish(target);
        return true;
    }

    pub fn finish(self: *HeapCensus, target: *?runtime.ObjectHeap.Stats) void {
        if (self.thread) |thread| thread.join();
        self.thread = null;
        self.mutex.lock();
        if (self.ready) |stats| target.* = stats;
        self.ready = null;
        self.mutex.unlock();
        self.running.store(false, .release);
    }

    pub fn deinit(self: *HeapCensus) void {
        var discard: ?runtime.ObjectHeap.Stats = null;
        self.finish(&discard);
    }
};

pub const ObjectSnapshot = struct {
    ev: *Engine,
    thread: ?std.Thread = null,
    mutex: sync.BlockingMutex = .{},
    ready: ?runtime.ObjectHeap.ObjectSnapshot = null,
    running: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),

    pub fn start(self: *ObjectSnapshot) !void {
        if (self.thread != null) return;
        self.running.store(true, .release);
        self.thread = std.Thread.spawn(.{}, build, .{self}) catch |err| {
            self.failed.store(true, .release);
            self.running.store(false, .release);
            return err;
        };
    }

    fn build(self: *ObjectSnapshot) void {
        const result = self.ev.heapObjectSnapshot(std.heap.smp_allocator) catch {
            self.failed.store(true, .release);
            self.running.store(false, .release);
            return;
        };
        self.mutex.lock();
        self.ready = result;
        self.mutex.unlock();
        self.running.store(false, .release);
    }

    pub fn poll(self: *ObjectSnapshot, target: *?runtime.ObjectHeap.ObjectSnapshot) bool {
        if (self.thread == null or self.running.load(.acquire)) return false;
        self.finish(target);
        return true;
    }

    pub fn finish(self: *ObjectSnapshot, target: *?runtime.ObjectHeap.ObjectSnapshot) void {
        if (self.thread) |thread| thread.join();
        self.thread = null;
        self.mutex.lock();
        if (self.ready) |snapshot| {
            if (target.*) |*old| old.deinit();
            target.* = snapshot;
        }
        self.ready = null;
        self.mutex.unlock();
        self.running.store(false, .release);
    }

    pub fn deinit(self: *ObjectSnapshot) void {
        var discard: ?runtime.ObjectHeap.ObjectSnapshot = null;
        self.finish(&discard);
        if (discard) |*snapshot| snapshot.deinit();
    }
};

pub const References = struct {
    ev: *Engine,
    thread: ?std.Thread = null,
    mutex: sync.BlockingMutex = .{},
    ready: ?vm_refs.Graph = null,
    running: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),

    pub fn start(self: *References) !void {
        if (self.thread != null) return;
        self.running.store(true, .release);
        self.thread = std.Thread.spawn(.{}, build, .{self}) catch |err| {
            self.failed.store(true, .release);
            self.running.store(false, .release);
            return err;
        };
    }

    fn build(self: *References) void {
        const result = vm_refs.Graph.build(std.heap.smp_allocator, self.ev) catch {
            self.failed.store(true, .release);
            self.running.store(false, .release);
            return;
        };
        self.mutex.lock();
        self.ready = result;
        self.mutex.unlock();
        self.running.store(false, .release);
    }

    pub fn poll(self: *References, target: *?vm_refs.Graph) bool {
        if (self.thread == null or self.running.load(.acquire)) return false;
        return self.finish(target);
    }

    pub fn finish(self: *References, target: *?vm_refs.Graph) bool {
        const thread = self.thread orelse return false;
        thread.join();
        self.thread = null;
        self.mutex.lock();
        const next = self.ready;
        self.ready = null;
        self.mutex.unlock();
        if (next) |graph| {
            if (target.*) |*old| old.deinit();
            target.* = graph;
            return true;
        }
        return false;
    }

    pub fn deinit(self: *References) void {
        if (self.thread) |thread| thread.join();
        self.thread = null;
        self.mutex.lock();
        if (self.ready) |*graph| graph.deinit();
        self.ready = null;
        self.mutex.unlock();
    }
};
