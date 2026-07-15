//! DaemonRuntime: the single owner of every background thread + daemon
//! connection `fix` uses to talk to the nix-daemon during a run. It folds the
//! two previously-separate mechanisms into one object:
//!
//!  - the **fast lane** — a single serial executor thread (the `IoRuntime`) that
//!    runs short offloaded daemon ops (store writes, `isValidPath` queries, IFD
//!    realizes) while the calling fiber parks (see `vm/io_offload.zig`). One op
//!    at a time, matching the blocking serial daemon socket.
//!
//!  - the **build lane** — a dedicated thread with its OWN daemon connection that
//!    realizes derivations fire-and-forget as they are instantiated (eval/build
//!    pipelining). A build holds its connection for the whole build, so it must
//!    NOT share the fast lane's connection (it would starve eval's own writes);
//!    the daemon is the cross-connection serialization point (commits added
//!    paths on write; per-output build locks prevent double-building).
//!
//! Phase 1 (this file) is a behavior-preserving consolidation: the fast lane is
//! the unchanged `IoRuntime`; the build lane is the former `BuildPump`, decoupled
//! from `*DerivationStore` (it takes allocator/io/socket/options as primitives so
//! it can live in the runtime layer). Phase 2 replaces both lanes' ad-hoc
//! ordering with an explicit dependency graph.

const std = @import("std");
const stable = @import("base").sync;
const io_runtime = @import("io_runtime.zig");
const rstore = @import("store.zig");

pub const Job = io_runtime.Job;

pub const DaemonRuntime = struct {
    /// Serial executor for offloaded short daemon ops; `io_offload.run` submits
    /// `Job`s here and parks the fiber. Started at construction, torn down last.
    fast: io_runtime.IoRuntime = .{},
    /// Fire-and-forget eager-build lane (own connection). Started on demand by
    /// the realizing commands (`startBuilds`).
    build: BuildLane = .{},

    pub fn init() DaemonRuntime {
        return .{};
    }

    /// Start the always-on fast lane. Must be called once the runtime is at its
    /// final address (heap-allocate it — the fast thread captures `&self.fast`).
    pub fn start(self: *DaemonRuntime) !void {
        try self.fast.start();
    }

    /// The fast-lane executor, handed to `DerivationStore.setOffload` as the
    /// offload context (`io_offload.run` submits Jobs to it).
    pub fn fastRuntime(self: *DaemonRuntime) *io_runtime.IoRuntime {
        return &self.fast;
    }

    /// Spawn the eager-build lane (its own daemon connection). `sink` drives live
    /// build progress (may be null for silent).
    pub fn startBuilds(
        self: *DaemonRuntime,
        allocator: std.mem.Allocator,
        io: std.Io,
        socket: []const u8,
        options: ?rstore.BuildSettings,
        sink: ?rstore.BuildSink,
        mode: rstore.BuildMode,
    ) !void {
        try self.build.start(allocator, io, socket, options, sink, mode);
    }

    /// Fire a freshly instantiated `.drv` at the build lane. Never blocks.
    pub fn submitBuild(self: *DaemonRuntime, drv_path: []const u8) !void {
        try self.build.submit(drv_path);
    }

    /// Drain + join the build lane; returns the first build error (its message is
    /// available via `takeBuildErrorMsg`). Idempotent.
    pub fn finishBuilds(self: *DaemonRuntime) ?anyerror {
        return self.build.stopAndJoin();
    }

    /// Transfer ownership of the first build failure's daemon message (or null).
    pub fn takeBuildErrorMsg(self: *DaemonRuntime) ?[]u8 {
        const msg = self.build.error_msg;
        self.build.error_msg = null;
        return msg;
    }

    /// Join the build lane (safety net) then stop the fast lane. Callers must
    /// ensure the compute pool is quiesced (no fiber parked on a fast-lane op).
    pub fn deinit(self: *DaemonRuntime) void {
        _ = self.build.stopAndJoin();
        if (self.build.error_msg) |msg| {
            self.build.allocator.?.free(msg);
            self.build.error_msg = null;
        }
        self.fast.deinit();
    }
};

/// The eager-build lane: a dedicated thread with its own daemon connection,
/// draining a queue of drv paths in waves (`buildPaths(batch)` per wave). Ported
/// from the former `derivation/build_pump.zig`, decoupled from `*DerivationStore`
/// (takes allocator/io/socket/options directly). Wait/wake mirrors `IoRuntime`
/// (BlockingMutex + a `seq` futex as a condvar-by-sequence).
pub const BuildLane = struct {
    allocator: ?std.mem.Allocator = null,
    io: ?std.Io = null,
    socket: []const u8 = "",
    options: ?rstore.BuildSettings = null,
    /// This lane's OWN daemon connection, opened lazily on the lane thread.
    daemon: ?*rstore.DaemonStore = null,

    mu: stable.BlockingMutex = .{},
    seq: std.atomic.Value(u32) = .init(0),
    queue: std.ArrayListUnmanaged([]u8) = .empty,
    submitted: std.StringHashMapUnmanaged(void) = .empty,
    done: bool = false,

    thread: ?std.Thread = null,
    sink: ?rstore.BuildSink = null,
    mode: rstore.BuildMode = .normal,

    /// First build failure (surfaced by `stopAndJoin`) + an owned copy of the
    /// daemon's message. Once set, later waves are dropped but still drained.
    first_error: ?anyerror = null,
    error_msg: ?[]u8 = null,

    pub fn start(
        self: *BuildLane,
        allocator: std.mem.Allocator,
        io: std.Io,
        socket: []const u8,
        options: ?rstore.BuildSettings,
        sink: ?rstore.BuildSink,
        mode: rstore.BuildMode,
    ) !void {
        self.allocator = allocator;
        self.io = io;
        self.socket = socket;
        self.options = options;
        self.sink = sink;
        self.mode = mode;
        self.thread = try std.Thread.spawn(.{}, loop, .{self});
    }

    /// Enqueue a bare `.drv` path for building. Dedupes + dupes into lane memory.
    /// No-op after `done`; never blocks on a build.
    pub fn submit(self: *BuildLane, drv_path: []const u8) !void {
        const alloc = self.allocator orelse return;
        self.mu.lock();
        defer self.mu.unlock();
        if (self.done) return;
        if (self.submitted.contains(drv_path)) return;
        const key = try alloc.dupe(u8, drv_path);
        errdefer alloc.free(key);
        try self.submitted.put(alloc, key, {});
        // A separate queue dupe so `stopAndJoin` frees queue + dedup entries
        // independently (a drained entry leaves `submitted` intact).
        const qcopy = try alloc.dupe(u8, drv_path);
        errdefer alloc.free(qcopy);
        try self.queue.append(alloc, qcopy);
        self.wake();
    }

    /// Signal drain-and-exit, join the thread, close the connection, free the
    /// queue/dedup storage. Returns the first build error. Idempotent (gated on a
    /// live thread — once joined, a second call is a no-op).
    pub fn stopAndJoin(self: *BuildLane) ?anyerror {
        const t = self.thread orelse return self.first_error;
        self.mu.lock();
        self.done = true;
        self.mu.unlock();
        self.wake();
        t.join();
        self.thread = null;

        if (self.daemon) |d| {
            d.deinit();
            self.daemon = null;
        }
        const alloc = self.allocator.?;
        for (self.queue.items) |q| alloc.free(q);
        self.queue.deinit(alloc);
        var it = self.submitted.keyIterator();
        while (it.next()) |k| alloc.free(k.*);
        self.submitted.deinit(alloc);
        return self.first_error;
    }

    fn wake(self: *BuildLane) void {
        _ = self.seq.fetchAdd(1, .release);
        stable.Futex.wake(&self.seq, 1);
    }

    fn loop(self: *BuildLane) void {
        const alloc = self.allocator.?;
        while (true) {
            self.mu.lock();
            while (self.queue.items.len == 0 and !self.done) {
                const s = self.seq.load(.acquire);
                self.mu.unlock();
                stable.Futex.wait(&self.seq, s);
                self.mu.lock();
            }
            if (self.queue.items.len == 0 and self.done) {
                self.mu.unlock();
                return;
            }
            const batch = self.queue.toOwnedSlice(alloc) catch {
                self.mu.unlock();
                stable.sleepNs(1_000_000);
                continue;
            };
            const already_failed = self.first_error != null;
            self.mu.unlock();

            defer {
                for (batch) |b| alloc.free(b);
                alloc.free(batch);
            }
            if (already_failed) continue; // stop building, just drain

            self.buildBatch(alloc, batch) catch |err| self.recordError(err);
        }
    }

    fn buildBatch(self: *BuildLane, alloc: std.mem.Allocator, batch: []const []u8) !void {
        const daemon = try self.ensureDaemon();
        const derived = try alloc.alloc([]const u8, batch.len);
        var n: usize = 0;
        defer {
            for (derived[0..n]) |d| alloc.free(d);
            alloc.free(derived);
        }
        for (batch) |drv| {
            derived[n] = try std.fmt.allocPrint(alloc, "{s}!*", .{drv});
            n += 1;
        }
        try daemon.buildPaths(derived, self.sink, self.mode);
    }

    fn ensureDaemon(self: *BuildLane) !*rstore.DaemonStore {
        if (self.daemon) |d| return d;
        const io = self.io orelse return error.StoreUnavailable;
        const d = try rstore.DaemonStore.connect(self.allocator.?, io, self.socket);
        errdefer d.deinit();
        // The lane only runs for store-writing commands, so pushing fix's
        // resolved daemon options (max-jobs/cores/…) is correct here.
        if (self.options) |opts| try d.setOptions(opts);
        self.daemon = d;
        return d;
    }

    fn recordError(self: *BuildLane, err: anyerror) void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.first_error != null) return;
        self.first_error = err;
        if (self.daemon) |d| {
            if (d.last_error) |msg| self.error_msg = self.allocator.?.dupe(u8, msg) catch null;
        }
    }
};
