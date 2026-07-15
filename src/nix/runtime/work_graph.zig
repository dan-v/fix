//! WorkGraph: a concurrent dependency-DAG executor for daemon store work —
//! `.drv` writes AND builds, in one graph.
//!
//! Two node kinds:
//!  - **write** — one `addTextToStore` of a `.drv`. Edge X -> Y (X refs Y) means
//!    Y must be written before X; the daemon enforces referential integrity, so
//!    honoring the edges is what lets writes run in PARALLEL across a pool of
//!    connections (dispatch order no longer has to be topological). Correctness
//!    is in the edges, not in force order.
//!  - **build** — one `buildPaths([drv!*])`. A build depends on exactly one node:
//!    the write of its `.drv` (a build can't start until its `.drv` — and, via
//!    the write's own edges, its whole `.drv` closure — is in the store). So
//!    build-gating is not special-cased: it is the same decrement-on-dep-done
//!    rule as everything else.
//!
//! Writes and builds have very different cost (short vs minutes), so each kind
//! has its own connection pool + ready queue; scheduling is otherwise uniform.
//!
//! A build node may carry a `wait_future` (`runtime/thunk.zig` `Future`): the
//! fiber that demanded it (IFD, or the final CLI build) parks on that future and
//! the graph `publish()`es it on completion, writing the build result into the
//! caller's `result` slot first. Eager builds pass no future (fire-and-forget);
//! their first failure is surfaced by `finish`.
//!
//! `Backend` is a vtable so the scheduler is unit-testable with mock apply fns
//! (see tests); the real backends open a `DaemonStore` per worker.

const std = @import("std");
const stable = @import("base").sync;
const Future = @import("thunk.zig").Future;

/// Per-worker connection lifecycle + the apply op for one node kind. `open` runs
/// once per worker thread (its own connection); `apply` performs one node.
pub const Backend = struct {
    ctx: *anyopaque,
    open: *const fn (ctx: *anyopaque) anyerror!*anyopaque,
    close: *const fn (ctx: *anyopaque, conn: *anyopaque) void,
    /// For a write node: (store_path, text, refs). For a build node: store_path =
    /// the drv path, text/refs empty.
    apply: *const fn (ctx: *anyopaque, conn: *anyopaque, store_path: []const u8, text: []const u8, refs: []const []const u8) anyerror!void,
};

const NodeKind = enum { write, build };
const State = enum { blocked, ready, running, done, failed };

/// A parked fiber awaiting a node's completion: `future` wakes it, `result`
/// (if any) receives the node's error-or-ok. A node may have several — e.g. two
/// fibers importing the same derivation output, or importing a `.drv`'s text.
const Waiter = struct { future: *Future, result: ?*(anyerror!void) };

const Node = struct {
    kind: NodeKind,
    /// write: the store path; build: the drv path.
    store_path: []u8,
    text: []u8 = &.{},
    references: [][]u8 = &.{},
    /// Fibers parked on this node's completion (empty for fire-and-forget).
    waiters: std.ArrayListUnmanaged(Waiter) = .empty,
    pending: u32 = 0,
    dependents: std.ArrayListUnmanaged(u32) = .empty,
    state: State = .blocked,
    /// Under `keep_going`: a dependency failed, so this node can't run (its input
    /// isn't in the store) — it is skipped-as-failed instead of aborting the graph.
    dep_failed: bool = false,

    fn deinit(self: *Node, alloc: std.mem.Allocator) void {
        alloc.free(self.store_path);
        alloc.free(self.text);
        for (self.references) |r| alloc.free(r);
        alloc.free(self.references);
        self.waiters.deinit(alloc);
        self.dependents.deinit(alloc);
    }
};

pub const WorkGraph = struct {
    allocator: std.mem.Allocator,
    write_backend: Backend,
    build_backend: Backend,
    write_worker_count: usize,
    build_worker_count: usize,

    mu: stable.BlockingMutex = .{},
    seq: std.atomic.Value(u32) = .init(0),
    nodes: std.ArrayListUnmanaged(Node) = .empty,
    /// store path -> WRITE node id (build nodes are not indexed; they look their
    /// drv's write node up here for their single dependency).
    index: std.StringHashMapUnmanaged(u32) = .empty,
    /// drv path -> its build node id (dedup re-submits; a second waiter attaches
    /// to the existing node).
    build_submitted: std.StringHashMapUnmanaged(u32) = .empty,
    write_ready: std.ArrayListUnmanaged(u32) = .empty,
    build_ready: std.ArrayListUnmanaged(u32) = .empty,
    threads: std.ArrayListUnmanaged(std.Thread) = .empty,
    started: bool = false,
    done: bool = false,
    /// Submitted-but-not-yet-completed nodes. A worker whose ready queue is empty
    /// must keep waiting while this is >0 (a node in another queue / in flight may
    /// still enqueue work for it — e.g. a build becomes ready when its write
    /// completes). Only `done and outstanding == 0` means truly finished.
    outstanding: usize = 0,
    /// First failure, surfaced by `finish`. Without `keep_going` it also aborts
    /// the rest of the graph; with it, only this node's dependents are skipped.
    first_error: ?anyerror = null,
    /// `--keep-going`: on a failure, keep running nodes that don't depend on the
    /// failed one instead of aborting the whole graph.
    keep_going: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        write_backend: Backend,
        build_backend: Backend,
        write_worker_count: usize,
        build_worker_count: usize,
        keep_going: bool,
    ) WorkGraph {
        return .{
            .allocator = allocator,
            .write_backend = write_backend,
            .build_backend = build_backend,
            .write_worker_count = @max(write_worker_count, 1),
            .build_worker_count = @max(build_worker_count, 1),
            .keep_going = keep_going,
        };
    }

    /// Submit a `.drv` write. Takes ownership of `text` (moved); copies
    /// `store_path`/`references`. Dedupes by store path. Never blocks. Edges: the
    /// still-pending write node of each reference.
    pub fn submitWrite(self: *WorkGraph, store_path: []const u8, text: []u8, references: []const []const u8) !void {
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
        try self.nodes.append(self.allocator, .{ .kind = .write, .store_path = owned_path, .text = text, .references = owned_refs });
        errdefer _ = self.nodes.pop();
        try self.index.put(self.allocator, owned_path, id);

        var pending: u32 = 0;
        for (references) |r| {
            const dep_id = self.index.get(r) orelse continue;
            if (self.nodes.items[dep_id].state == .done) continue;
            try self.nodes.items[dep_id].dependents.append(self.allocator, id);
            pending += 1;
        }
        self.nodes.items[id].pending = pending;
        self.outstanding += 1;
        if (pending == 0) try self.enqueueReady(id);
    }

    /// Submit a build of `drv_path`. It depends on the write node of `drv_path`
    /// (if that write is still pending). INVARIANT: the drv's write is always
    /// submitted before its build (instantiation writes the `.drv`, then the same
    /// fiber submits the build), so the write node is already in `index` here.
    /// `wait_future`/`result` non-null =>
    /// a fiber is parked; the graph writes `result` then `publish()`es the future
    /// on completion. Both null => fire-and-forget (eager). Dedupes by drv path.
    pub fn submitBuild(self: *WorkGraph, drv_path: []const u8, wait_future: ?*Future, result: ?*(anyerror!void)) !void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.build_submitted.get(drv_path)) |existing| {
            // A build for this drv already exists: attach a second waiter to it
            // (concurrent IFD of the same output), or — if it already finished —
            // wake this fiber now.
            try self.attachWaiter(existing, wait_future, result);
            return;
        }
        const owned_drv = try self.allocator.dupe(u8, drv_path);
        errdefer self.allocator.free(owned_drv);
        const id: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, .{ .kind = .build, .store_path = owned_drv });
        errdefer _ = self.nodes.pop();
        if (wait_future) |f| try self.nodes.items[id].waiters.append(self.allocator, .{ .future = f, .result = result });
        try self.build_submitted.put(self.allocator, owned_drv, id);

        var pending: u32 = 0;
        if (self.index.get(drv_path)) |wid| {
            if (self.nodes.items[wid].state != .done) {
                try self.nodes.items[wid].dependents.append(self.allocator, id);
                pending = 1;
            }
        }
        self.nodes.items[id].pending = pending;
        self.outstanding += 1;
        if (pending == 0) try self.enqueueReady(id);
    }

    /// Park the caller on the write of `drv_path`: returns false if there is no
    /// write node for it (already valid / not written via the graph — caller
    /// proceeds without waiting), true if a waiter was attached or the write was
    /// already done (in which case the future is published immediately).
    pub fn awaitWrite(self: *WorkGraph, drv_path: []const u8, future: *Future, result: ?*(anyerror!void)) !bool {
        self.mu.lock();
        defer self.mu.unlock();
        const wid = self.index.get(drv_path) orelse return false;
        try self.attachWaiter(wid, future, result);
        return true;
    }

    /// Attach a waiter to node `id`, or publish immediately if it's already
    /// terminal. Caller holds `mu`. A null future is a no-op (fire-and-forget).
    fn attachWaiter(self: *WorkGraph, id: u32, future: ?*Future, result: ?*(anyerror!void)) !void {
        const f = future orelse return;
        const st = self.nodes.items[id].state;
        if (st == .done or st == .failed) {
            if (result) |r| r.* = if (st == .failed) error.StoreWriteFailed else {};
            f.publish();
            return;
        }
        try self.nodes.items[id].waiters.append(self.allocator, .{ .future = f, .result = result });
    }

    fn enqueueReady(self: *WorkGraph, id: u32) !void {
        self.nodes.items[id].state = .ready;
        switch (self.nodes.items[id].kind) {
            .write => try self.write_ready.append(self.allocator, id),
            .build => try self.build_ready.append(self.allocator, id),
        }
        self.wakeAll();
    }

    pub fn start(self: *WorkGraph) !void {
        self.started = true;
        errdefer self.stopThreads();
        var i: usize = 0;
        while (i < self.write_worker_count) : (i += 1) {
            try self.threads.append(self.allocator, try std.Thread.spawn(.{}, worker, .{ self, NodeKind.write }));
        }
        i = 0;
        while (i < self.build_worker_count) : (i += 1) {
            try self.threads.append(self.allocator, try std.Thread.spawn(.{}, worker, .{ self, NodeKind.build }));
        }
    }

    /// Drain all pending work, join the pool, return the first error. Idempotent.
    pub fn finish(self: *WorkGraph) ?anyerror {
        if (self.started) {
            self.mu.lock();
            self.done = true;
            self.mu.unlock();
            self.wakeAll();
            self.stopThreads();
        }
        const err = self.first_error;
        self.freeGraph();
        return err;
    }

    fn stopThreads(self: *WorkGraph) void {
        for (self.threads.items) |t| t.join();
        self.threads.clearRetainingCapacity();
        self.started = false;
    }

    fn wakeAll(self: *WorkGraph) void {
        _ = self.seq.fetchAdd(1, .release);
        stable.Futex.wake(&self.seq, std.math.maxInt(u32));
    }

    fn readyQueue(self: *WorkGraph, kind: NodeKind) *std.ArrayListUnmanaged(u32) {
        return switch (kind) {
            .write => &self.write_ready,
            .build => &self.build_ready,
        };
    }

    fn worker(self: *WorkGraph, kind: NodeKind) void {
        const backend = switch (kind) {
            .write => self.write_backend,
            .build => self.build_backend,
        };
        // Connect lazily on the first node so a small build (which never fills a
        // pool) only opens as many connections as it has concurrent work for —
        // each connection makes the daemon fork a worker, so we don't open the
        // whole pool for one drv. On a build with real eval, these connects
        // overlap eval anyway. `open_failed` sticks: once a worker can't connect,
        // it fails its remaining nodes.
        var conn: ?*anyopaque = null;
        var open_failed = false;
        defer if (conn) |c| backend.close(backend.ctx, c);

        const q = self.readyQueue(kind);
        while (true) {
            self.mu.lock();
            while (q.items.len == 0 and !(self.done and self.outstanding == 0)) {
                const s = self.seq.load(.acquire);
                self.mu.unlock();
                stable.Futex.wait(&self.seq, s);
                self.mu.lock();
            }
            if (q.items.len == 0) {
                self.mu.unlock();
                return; // done and outstanding == 0
            }
            const id = q.orderedRemove(0);
            self.nodes.items[id].state = .running;
            // Skip this node if (keep_going) a dependency of it failed, else if
            // ANY failure has occurred (abort the whole graph).
            const aborted = if (self.keep_going) self.nodes.items[id].dep_failed else self.first_error != null;
            const sp = self.nodes.items[id].store_path;
            const tx = self.nodes.items[id].text;
            const refs = self.nodes.items[id].references;
            self.mu.unlock();

            var apply_err: ?anyerror = null;
            if (aborted) {
                apply_err = error.Aborted;
            } else {
                if (conn == null and !open_failed) {
                    conn = backend.open(backend.ctx) catch |err| blk: {
                        open_failed = true;
                        self.recordErr(err);
                        break :blk null;
                    };
                }
                if (open_failed) {
                    apply_err = error.StoreUnavailable;
                } else {
                    const refs_const: []const []const u8 = refs;
                    backend.apply(backend.ctx, conn.?, sp, tx, refs_const) catch |err| {
                        apply_err = err;
                    };
                }
            }
            self.complete(id, apply_err);
        }
    }

    fn recordErr(self: *WorkGraph, err: anyerror) void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.first_error == null) self.first_error = err;
    }

    /// Mark node `id` finished, propagate to dependents, wake a parked fiber (for
    /// a build with a `wait_future`), record the first error.
    fn complete(self: *WorkGraph, id: u32, apply_err: ?anyerror) void {
        self.mu.lock();
        const node = &self.nodes.items[id];
        const failed = apply_err != null;
        if (apply_err) |err| {
            if (self.first_error == null and err != error.Aborted) self.first_error = err;
            node.state = .failed;
        } else {
            node.state = .done;
        }
        for (node.dependents.items) |dep| {
            // A dependent of a failed node can't run (its input isn't in the
            // store); under keep_going it's skipped-as-failed, cascading down the
            // dependency subtree while independent nodes keep going.
            if (failed and self.keep_going) self.nodes.items[dep].dep_failed = true;
            self.nodes.items[dep].pending -= 1;
            if (self.nodes.items[dep].pending == 0) self.enqueueReady(dep) catch {};
        }
        self.outstanding -= 1;
        // Wake all workers so an idle one re-checks the `done and outstanding==0`
        // exit condition even when this completion enqueued nothing.
        self.wakeAll();
        // Snapshot the waiter list before unlocking: publishing wakes a parked
        // fiber that may resume and (for a build) even free the future's frame,
        // but the futures live on stable WorkerFibers, and the list memory is the
        // node's (freed only in `finish`, after all workers join). Take the slice
        // out so we can publish after releasing the lock.
        const waiters = node.waiters.items;
        const outcome: anyerror!void = if (apply_err) |e| e else {};
        self.mu.unlock();

        for (waiters) |w| {
            if (w.result) |r| r.* = outcome;
            w.future.publish();
        }
    }

    fn freeGraph(self: *WorkGraph) void {
        for (self.nodes.items) |*n| n.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.index.deinit(self.allocator);
        self.build_submitted.deinit(self.allocator);
        self.write_ready.deinit(self.allocator);
        self.build_ready.deinit(self.allocator);
        self.threads.deinit(self.allocator);
    }
};

// ---------------------------------------------------------------------------
// Tests — mock backends recording apply order + asserting the deps-first
// invariant (references applied before a write; write applied before its build).
// ---------------------------------------------------------------------------

const testing = std.testing;

const Mock = struct {
    mu: stable.BlockingMutex = .{},
    seen: std.StringHashMapUnmanaged(void) = .empty, // applied write paths
    built: std.ArrayListUnmanaged([]const u8) = .empty,
    applied_writes: usize = 0,
    violation: bool = false,
    /// If set, a write of this path fails (to test keep-going).
    fail_write: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    fn writeBackend(self: *Mock) Backend {
        return .{ .ctx = self, .open = openMock, .close = closeMock, .apply = applyWrite };
    }
    fn buildBackend(self: *Mock) Backend {
        return .{ .ctx = self, .open = openMock, .close = closeMock, .apply = applyBuild };
    }
    fn openMock(ctx: *anyopaque) anyerror!*anyopaque {
        return ctx;
    }
    fn closeMock(_: *anyopaque, _: *anyopaque) void {}
    fn applyWrite(ctx: *anyopaque, _: *anyopaque, store_path: []const u8, _: []const u8, refs: []const []const u8) anyerror!void {
        const self: *Mock = @ptrCast(@alignCast(ctx));
        stable.sleepNs(50_000);
        if (self.fail_write) |fp| {
            if (std.mem.eql(u8, fp, store_path)) return error.WriteFailed;
        }
        self.mu.lock();
        defer self.mu.unlock();
        for (refs) |r| {
            if (!self.seen.contains(r)) self.violation = true;
        }
        self.seen.put(self.allocator, store_path, {}) catch {};
        self.applied_writes += 1;
    }
    fn applyBuild(ctx: *anyopaque, _: *anyopaque, drv_path: []const u8, _: []const u8, _: []const []const u8) anyerror!void {
        const self: *Mock = @ptrCast(@alignCast(ctx));
        stable.sleepNs(50_000);
        self.mu.lock();
        defer self.mu.unlock();
        // Invariant: a build's drv must have been written first.
        if (!self.seen.contains(drv_path)) self.violation = true;
        // Dupe: `drv_path` borrows graph-node memory that `finish` frees, but
        // tests read `built` afterwards.
        self.built.append(self.allocator, self.allocator.dupe(u8, drv_path) catch return) catch {};
    }
    fn deinit(self: *Mock) void {
        self.seen.deinit(self.allocator);
        for (self.built.items) |b| self.allocator.free(b);
        self.built.deinit(self.allocator);
    }
};

fn td(alloc: std.mem.Allocator, s: []const u8) []u8 {
    return alloc.dupe(u8, s) catch unreachable;
}

test "work graph: diamond writes bottom-up, builds gated on their write" {
    const alloc = testing.allocator;
    var mock: Mock = .{ .allocator = alloc };
    defer mock.deinit();
    var g = WorkGraph.init(alloc, mock.writeBackend(), mock.buildBackend(), 4, 4, false);
    try g.start();
    // Diamond A -> {B,C} -> D, submitted in force order.
    try g.submitWrite("D", td(alloc, "d"), &.{});
    try g.submitWrite("B", td(alloc, "b"), &.{"D"});
    try g.submitWrite("C", td(alloc, "c"), &.{"D"});
    try g.submitWrite("A", td(alloc, "a"), &.{ "B", "C" });
    // Eager-build A immediately (its write may not be done yet).
    try g.submitBuild("A", null, null);
    try testing.expect(g.finish() == null);
    try testing.expect(!mock.violation);
    try testing.expectEqual(@as(usize, 4), mock.applied_writes);
    try testing.expectEqual(@as(usize, 1), mock.built.items.len);
}

test "work graph: build waits for its (slow) write" {
    const alloc = testing.allocator;
    var mock: Mock = .{ .allocator = alloc };
    defer mock.deinit();
    var g = WorkGraph.init(alloc, mock.writeBackend(), mock.buildBackend(), 2, 2, false);
    try g.start();
    // Real ordering: write submitted, then the build of the same drv. The build
    // must not run until the (sleeping) write completes.
    try g.submitWrite("X", td(alloc, "x"), &.{});
    try g.submitBuild("X", null, null);
    try testing.expect(g.finish() == null);
    try testing.expect(!mock.violation);
    try testing.expectEqual(@as(usize, 1), mock.built.items.len);
}

test "work graph: parked build future is published with result" {
    const alloc = testing.allocator;
    var mock: Mock = .{ .allocator = alloc };
    defer mock.deinit();
    var g = WorkGraph.init(alloc, mock.writeBackend(), mock.buildBackend(), 2, 2, false);
    try g.start();
    try g.submitWrite("W", td(alloc, "w"), &.{});
    var fut = Future.initClaimed(1);
    var result: anyerror!void = error.Unset;
    try g.submitBuild("W", &fut, &result);
    // The graph publishes the future on completion; drain to make it deterministic.
    try testing.expect(g.finish() == null);
    result catch |e| try testing.expect(e != error.Unset);
    try testing.expect(!mock.violation);
}

test "work graph: keep-going builds independent nodes past a failed write" {
    const alloc = testing.allocator;
    var mock: Mock = .{ .allocator = alloc, .fail_write = "Xd" };
    defer mock.deinit();
    // keep_going = true.
    var g = WorkGraph.init(alloc, mock.writeBackend(), mock.buildBackend(), 4, 4, true);
    try g.start();
    // Subtree X: write Xd (FAILS) -> build X (depends on Xd, must be skipped).
    try g.submitWrite("Xd", td(alloc, "xd"), &.{});
    try g.submitBuild("Xd", null, null);
    // Independent subtree Y: write Yd (ok) -> build Y (must still run).
    try g.submitWrite("Yd", td(alloc, "yd"), &.{});
    try g.submitBuild("Yd", null, null);
    // A failure occurred, so finish returns an error...
    try testing.expect(g.finish() != null);
    // ...but the independent Y was built and X was NOT (its write failed).
    try testing.expectEqual(@as(usize, 1), mock.built.items.len);
    try testing.expectEqualStrings("Yd", mock.built.items[0]);
    try testing.expect(!mock.violation);
}

test "work graph: without keep-going, a failed write aborts the rest" {
    const alloc = testing.allocator;
    var mock: Mock = .{ .allocator = alloc, .fail_write = "Ad" };
    defer mock.deinit();
    var g = WorkGraph.init(alloc, mock.writeBackend(), mock.buildBackend(), 1, 1, false);
    try g.start();
    // One write worker: Ad fails first, so Bd's write + both builds are aborted.
    try g.submitWrite("Ad", td(alloc, "ad"), &.{});
    try g.submitBuild("Ad", null, null);
    try g.submitWrite("Bd", td(alloc, "bd"), &.{});
    try g.submitBuild("Bd", null, null);
    try testing.expect(g.finish() != null);
    try testing.expectEqual(@as(usize, 0), mock.built.items.len);
}
