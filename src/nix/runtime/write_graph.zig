//! WriteGraph: a concurrent dependency-DAG executor for store writes.
//!
//! Each node is one store write (a `.drv` `addTextToStore`). An edge X -> Y means
//! "Y must be written before X" — i.e. X references Y, and the daemon enforces
//! referential integrity (a path's references must be valid when it is added).
//! A node becomes eligible only when all its deps are `done`; a pool of
//! connection-worker threads then applies eligible nodes in parallel.
//!
//! Why this replaces "force order + a serial FIFO": on ONE connection, dispatch
//! order equals submission order equals force order (a derivation's value isn't
//! returned until its write is submitted, so dependents always submit after
//! their inputs), so ordering is implicit and a graph would be inert. The graph
//! earns its keep the moment writes run on MULTIPLE connections in parallel:
//! processing order no longer matches submission order, and only the explicit
//! reference edges keep the daemon from seeing a `.drv` whose input isn't valid
//! yet. Correctness comes from the edges, not from force order.
//!
//! The instantiating fiber does NOT block: `submit` creates the node (taking
//! ownership of the payload) and returns; the write happens later on a worker.
//! Errors are therefore asynchronous — surfaced by `finish`.
//!
//! `Backend` is a vtable so the scheduler is unit-testable with a mock apply
//! (see tests); the real backend opens a `DaemonStore` per worker and calls
//! `addTextToStore`.

const std = @import("std");
const stable = @import("base").sync;

/// Per-worker connection lifecycle + the apply operation. `open` runs once per
/// worker thread (its own connection); `apply` performs one write on it.
pub const Backend = struct {
    ctx: *anyopaque,
    open: *const fn (ctx: *anyopaque) anyerror!*anyopaque,
    close: *const fn (ctx: *anyopaque, conn: *anyopaque) void,
    apply: *const fn (ctx: *anyopaque, conn: *anyopaque, store_path: []const u8, text: []const u8, refs: []const []const u8) anyerror!void,
};

const State = enum { blocked, ready, running, done, failed };

const Node = struct {
    store_path: []u8,
    text: []u8,
    references: [][]u8,
    pending: u32 = 0,
    dependents: std.ArrayListUnmanaged(u32) = .empty,
    state: State = .blocked,

    fn deinit(self: *Node, alloc: std.mem.Allocator) void {
        alloc.free(self.store_path);
        alloc.free(self.text);
        for (self.references) |r| alloc.free(r);
        alloc.free(self.references);
        self.dependents.deinit(alloc);
    }
};

pub const WriteGraph = struct {
    allocator: std.mem.Allocator,
    backend: Backend,
    worker_count: usize,

    mu: stable.BlockingMutex = .{},
    seq: std.atomic.Value(u32) = .init(0),
    nodes: std.ArrayListUnmanaged(Node) = .empty,
    /// store path -> node id. Owns no keys (borrows the node's `store_path`).
    index: std.StringHashMapUnmanaged(u32) = .empty,
    ready: std.ArrayListUnmanaged(u32) = .empty,
    /// Nodes handed to a worker but not yet complete — `finish` waits for this
    /// plus `ready` to drain.
    in_flight: usize = 0,
    threads: std.ArrayListUnmanaged(std.Thread) = .empty,
    started: bool = false,
    done: bool = false,
    first_error: ?anyerror = null,

    pub fn init(allocator: std.mem.Allocator, backend: Backend, worker_count: usize) WriteGraph {
        return .{ .allocator = allocator, .backend = backend, .worker_count = @max(worker_count, 1) };
    }

    /// Submit a write. Takes ownership of `text` (moved). `store_path` and
    /// `references` are borrowed and copied. Dedupes by store path (a re-submit
    /// of an already-known path frees `text` and returns). Never blocks.
    /// Edges: this node depends on the still-pending write node of each ref.
    pub fn submit(self: *WriteGraph, store_path: []const u8, text: []u8, references: []const []const u8) !void {
        self.mu.lock();
        defer self.mu.unlock();

        if (self.index.contains(store_path)) {
            self.allocator.free(text);
            return;
        }

        const owned_path = try self.allocator.dupe(u8, store_path);
        errdefer self.allocator.free(owned_path);
        const owned_refs = try self.allocator.alloc([]u8, references.len);
        var nrefs: usize = 0;
        errdefer {
            for (owned_refs[0..nrefs]) |r| self.allocator.free(r);
            self.allocator.free(owned_refs);
        }
        for (references) |r| {
            owned_refs[nrefs] = try self.allocator.dupe(u8, r);
            nrefs += 1;
        }

        const id: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, .{
            .store_path = owned_path,
            .text = text,
            .references = owned_refs,
        });
        errdefer _ = self.nodes.pop();
        try self.index.put(self.allocator, owned_path, id);

        // Wire edges to any referenced node that isn't done yet.
        var pending: u32 = 0;
        for (references) |r| {
            const dep_id = self.index.get(r) orelse continue;
            if (self.nodes.items[dep_id].state == .done) continue;
            try self.nodes.items[dep_id].dependents.append(self.allocator, id);
            pending += 1;
        }
        self.nodes.items[id].pending = pending;

        if (pending == 0) {
            self.nodes.items[id].state = .ready;
            try self.ready.append(self.allocator, id);
            self.wakeAll();
        }
    }

    /// Spawn the worker pool. Call once, after the graph is at its final address.
    pub fn start(self: *WriteGraph) !void {
        self.started = true;
        errdefer self.stopThreads();
        var i: usize = 0;
        while (i < self.worker_count) : (i += 1) {
            const t = try std.Thread.spawn(.{}, worker, .{self});
            try self.threads.append(self.allocator, t);
        }
    }

    /// Drain all pending writes, join the pool, and return the first error.
    /// Idempotent. After this the graph has flushed every submitted write.
    pub fn finish(self: *WriteGraph) ?anyerror {
        if (!self.started) {
            self.freeGraph();
            return self.first_error;
        }
        self.mu.lock();
        self.done = true;
        self.mu.unlock();
        self.wakeAll();
        self.stopThreads();
        const err = self.first_error;
        self.freeGraph();
        return err;
    }

    fn stopThreads(self: *WriteGraph) void {
        for (self.threads.items) |t| t.join();
        self.threads.clearRetainingCapacity();
        self.started = false;
    }

    fn wakeAll(self: *WriteGraph) void {
        _ = self.seq.fetchAdd(1, .release);
        stable.Futex.wake(&self.seq, std.math.maxInt(u32));
    }

    fn worker(self: *WriteGraph) void {
        const conn = self.backend.open(self.backend.ctx) catch |err| {
            // Can't open a connection: record the error and let `finish` surface
            // it. Drain the ready queue so producers/`finish` don't hang.
            self.mu.lock();
            if (self.first_error == null) self.first_error = err;
            self.mu.unlock();
            self.drainDead();
            return;
        };
        defer self.backend.close(self.backend.ctx, conn);

        while (true) {
            self.mu.lock();
            while (self.ready.items.len == 0 and !self.done) {
                const s = self.seq.load(.acquire);
                self.mu.unlock();
                stable.Futex.wait(&self.seq, s);
                self.mu.lock();
            }
            if (self.ready.items.len == 0 and self.done) {
                self.mu.unlock();
                return;
            }
            const id = self.ready.orderedRemove(0);
            self.nodes.items[id].state = .running;
            self.in_flight += 1;
            const failed = self.first_error != null;
            // Snapshot borrowed slices; node memory is stable (append-only, no
            // reallocation frees — ArrayList may realloc, so copy the slices out
            // under the lock before releasing it).
            const sp = self.nodes.items[id].store_path;
            const tx = self.nodes.items[id].text;
            const refs = self.nodes.items[id].references;
            self.mu.unlock();

            var apply_err: ?anyerror = null;
            if (!failed) {
                const refs_const: []const []const u8 = refs;
                self.backend.apply(self.backend.ctx, conn, sp, tx, refs_const) catch |err| {
                    apply_err = err;
                };
            }
            self.complete(id, apply_err);
        }
    }

    /// Mark node `id` finished; propagate to dependents (decrement, enqueue
    /// newly-eligible), record the first error.
    fn complete(self: *WriteGraph, id: u32, apply_err: ?anyerror) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.in_flight -= 1;
        if (apply_err) |err| {
            if (self.first_error == null) self.first_error = err;
            self.nodes.items[id].state = .failed;
        } else {
            self.nodes.items[id].state = .done;
        }
        // Even on failure, release dependents so the graph drains (they'll be
        // skipped because `first_error` is set — see the worker loop).
        var woke = false;
        for (self.nodes.items[id].dependents.items) |dep| {
            self.nodes.items[dep].pending -= 1;
            if (self.nodes.items[dep].pending == 0) {
                self.nodes.items[dep].state = .ready;
                self.ready.append(self.allocator, dep) catch {};
                woke = true;
            }
        }
        if (woke) self.wakeAll();
    }

    /// A dead worker (couldn't open a connection) still drains ready nodes so the
    /// graph reaches quiescence — it just fails them.
    fn drainDead(self: *WriteGraph) void {
        while (true) {
            self.mu.lock();
            while (self.ready.items.len == 0 and !self.done) {
                const s = self.seq.load(.acquire);
                self.mu.unlock();
                stable.Futex.wait(&self.seq, s);
                self.mu.lock();
            }
            if (self.ready.items.len == 0 and self.done) {
                self.mu.unlock();
                return;
            }
            const id = self.ready.orderedRemove(0);
            self.in_flight += 1;
            self.mu.unlock();
            self.complete(id, error.StoreUnavailable);
        }
    }

    fn freeGraph(self: *WriteGraph) void {
        for (self.nodes.items) |*n| n.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.index.deinit(self.allocator);
        self.ready.deinit(self.allocator);
        self.threads.deinit(self.allocator);
    }
};

// ---------------------------------------------------------------------------
// Tests: validate DAG scheduling with a mock backend that records apply order
// and asserts every node's dependencies were applied before it.
// ---------------------------------------------------------------------------

const testing = std.testing;

const MockBackend = struct {
    mu: stable.BlockingMutex = .{},
    /// Applied store paths, in completion order.
    applied: std.ArrayListUnmanaged([]const u8) = .empty,
    /// Set of paths already applied (for the "deps-first" invariant check).
    seen: std.StringHashMapUnmanaged(void) = .empty,
    violation: bool = false,
    allocator: std.mem.Allocator,

    fn backend(self: *MockBackend) Backend {
        return .{ .ctx = self, .open = open, .close = close, .apply = apply };
    }
    fn open(ctx: *anyopaque) anyerror!*anyopaque {
        return ctx; // the connection is just the mock itself
    }
    fn close(_: *anyopaque, _: *anyopaque) void {}
    fn apply(ctx: *anyopaque, _: *anyopaque, store_path: []const u8, _: []const u8, refs: []const []const u8) anyerror!void {
        const self: *MockBackend = @ptrCast(@alignCast(ctx));
        // Simulate variable work so the pool actually interleaves.
        stable.sleepNs(100_000);
        self.mu.lock();
        defer self.mu.unlock();
        // Invariant: every reference must already have been applied.
        for (refs) |r| {
            if (!self.seen.contains(r)) self.violation = true;
        }
        self.applied.append(self.allocator, store_path) catch {};
        self.seen.put(self.allocator, store_path, {}) catch {};
    }
    fn deinit(self: *MockBackend) void {
        self.applied.deinit(self.allocator);
        self.seen.deinit(self.allocator);
    }
};

fn dupeText(alloc: std.mem.Allocator, s: []const u8) []u8 {
    return alloc.dupe(u8, s) catch unreachable;
}

test "write graph: diamond deps applied bottom-up, no reference-integrity violation" {
    const alloc = testing.allocator;
    var mock: MockBackend = .{ .allocator = alloc };
    defer mock.deinit();

    var g = WriteGraph.init(alloc, mock.backend(), 4);
    try g.start();

    // Diamond: A -> {B, C} -> D. Submit in force order (D, B, C, A): a dependent
    // is always submitted after its deps (structural), but the 4-worker pool may
    // apply them out of submission order — the edges must still hold.
    try g.submit("D", dupeText(alloc, "d"), &.{});
    try g.submit("B", dupeText(alloc, "b"), &.{"D"});
    try g.submit("C", dupeText(alloc, "c"), &.{"D"});
    try g.submit("A", dupeText(alloc, "a"), &.{ "B", "C" });

    const err = g.finish();
    try testing.expect(err == null);
    try testing.expect(!mock.violation);
    try testing.expectEqual(@as(usize, 4), mock.applied.items.len);
}

test "write graph: wide independent writes all applied, dedup on re-submit" {
    const alloc = testing.allocator;
    var mock: MockBackend = .{ .allocator = alloc };
    defer mock.deinit();

    var g = WriteGraph.init(alloc, mock.backend(), 4);
    try g.start();

    var buf: [16]u8 = undefined;
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const name = std.fmt.bufPrint(&buf, "n{d}", .{i}) catch unreachable;
        try g.submit(name, dupeText(alloc, "x"), &.{});
    }
    // Re-submit an existing path: deduped (text freed, no new node).
    try g.submit("n0", dupeText(alloc, "x"), &.{});

    try testing.expect(g.finish() == null);
    try testing.expect(!mock.violation);
    try testing.expectEqual(@as(usize, 50), mock.applied.items.len);
}

test "write graph: chain of 100 stays ordered" {
    const alloc = testing.allocator;
    var mock: MockBackend = .{ .allocator = alloc };
    defer mock.deinit();

    var g = WriteGraph.init(alloc, mock.backend(), 8);
    try g.start();

    var namebuf: [16]u8 = undefined;
    var prevbuf: [16]u8 = undefined;
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const name = std.fmt.bufPrint(&namebuf, "c{d}", .{i}) catch unreachable;
        if (i == 0) {
            try g.submit(name, dupeText(alloc, "x"), &.{});
        } else {
            const prev = std.fmt.bufPrint(&prevbuf, "c{d}", .{i - 1}) catch unreachable;
            try g.submit(name, dupeText(alloc, "x"), &.{prev});
        }
    }
    try testing.expect(g.finish() == null);
    try testing.expect(!mock.violation);
    try testing.expectEqual(@as(usize, 100), mock.applied.items.len);
}
