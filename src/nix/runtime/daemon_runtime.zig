//! DaemonRuntime: the single owner of every background thread + daemon
//! connection `fix` uses. Two mechanisms:
//!
//!  - the **fast lane** — a single serial executor thread (`IoRuntime`) that runs
//!    short offloaded daemon ops while the calling fiber parks (`vm/io_offload`):
//!    source/flat writes, `isValidPath` queries, and `.drv` writes when the work
//!    graph is not active (plain `instantiate`).
//!
//!  - the **work graph** — a dependency-DAG executor (`work_graph.zig`) that runs
//!    `.drv` writes AND builds across pools of their own connections, ordered by
//!    explicit reference edges instead of force order (so writes parallelize and
//!    a build waits for its `.drv`'s write). Started on demand by the realizing
//!    commands (`startGraph`); `.drv` writes then go here (async, fiber doesn't
//!    park), eager builds are fire-and-forget nodes, and IFD parks on a node.

const std = @import("std");
const io_runtime = @import("io_runtime.zig");
const wg = @import("work_graph.zig");
const rstore = @import("store.zig");
const Future = @import("thunk.zig").Future;

pub const WorkGraph = wg.WorkGraph;

/// The name portion of a store path (`/nix/store/<hash>-<name>` -> `<name>`),
/// the `name` arg `addTextToStore` recomputes the path from.
fn storePathName(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    if (base.len > 33 and base[32] == '-') return base[33..];
    return base;
}

pub const DaemonRuntime = struct {
    fast: io_runtime.IoRuntime = .{},
    /// Config for the graph's per-worker connections + build progress. Populated
    /// by `startGraph`; the backend `open`/`apply` fns read it.
    cfg: GraphConfig = .{},
    graph: ?WorkGraph = null,
    graph_active: bool = false,
    /// Warm build connections, decoupled from the graph's lifetime. A build
    /// worker returns its connection here at graph shutdown instead of closing
    /// it (it already forked a daemon worker + applied build settings); the
    /// terminal authoritative build then borrows one instead of forking a fresh
    /// connection on its critical path. `buildOnPool` acquires/releases; drained
    /// at `deinit`. Guarded by `build_pool_mu`.
    build_pool: std.ArrayListUnmanaged(*rstore.DaemonStore) = .empty,
    build_pool_mu: @import("base").sync.BlockingMutex = .{},

    /// Thread-safe per-build progress span, provided by the CLI. `begin` opens a
    /// span for a build and returns an opaque token; `end` closes it. Backed by
    /// the concurrent-span channel (lock-free node ops + a span mutex), so it is
    /// safe to call from every build-worker thread concurrently — unlike a
    /// shared per-activity `BuildSink`, whose hashmap raced and whose per-
    /// connection activity ids collided across the pool.
    pub const BuildSpans = struct {
        ctx: *anyopaque,
        begin: *const fn (ctx: *anyopaque, name: []const u8) u64,
        end: *const fn (ctx: *anyopaque, token: u64) void,
    };

    /// Shared "already in the store" cache, provided by `DerivationStore` (its
    /// `instantiated` set). The graph consults + populates it so a `.drv` written
    /// on the pool is visible to every other daemon path (queries, IFD closure
    /// walks) as a cache hit instead of a redundant `isValidPath` round-trip. Both
    /// callbacks are thread-safe (guarded on the store side).
    pub const Dedup = struct {
        ctx: *anyopaque,
        known: *const fn (ctx: *anyopaque, path: []const u8) bool,
        mark: *const fn (ctx: *anyopaque, path: []const u8) void,
    };

    pub const GraphConfig = struct {
        allocator: std.mem.Allocator = undefined,
        io: std.Io = undefined,
        socket: []const u8 = "",
        options: ?rstore.BuildSettings = null,
        spans: ?BuildSpans = null,
        dedup: ?Dedup = null,
        mode: rstore.BuildMode = .normal,
        /// First daemon error message (write or build), guarded, surfaced on finish.
        err_mu: @import("base").sync.BlockingMutex = .{},
        err_msg: ?[]u8 = null,
        err_set: bool = false,
    };

    pub fn init() DaemonRuntime {
        return .{};
    }

    pub fn start(self: *DaemonRuntime) !void {
        try self.fast.start();
    }

    pub fn fastRuntime(self: *DaemonRuntime) *io_runtime.IoRuntime {
        return &self.fast;
    }

    /// Start the work graph (per-worker daemon connections). `.drv` writes and
    /// builds route here until `finishGraph`.
    pub fn startGraph(
        self: *DaemonRuntime,
        allocator: std.mem.Allocator,
        io: std.Io,
        socket: []const u8,
        options: ?rstore.BuildSettings,
        spans: ?BuildSpans,
        dedup: ?Dedup,
        mode: rstore.BuildMode,
    ) !void {
        self.cfg = .{ .allocator = allocator, .io = io, .socket = socket, .options = options, .spans = spans, .dedup = dedup, .mode = mode };
        const keep_going = if (options) |o| o.keep_going else false;
        self.graph = WorkGraph.init(
            allocator,
            .{ .ctx = self, .open = openWriteConn, .close = closeWriteConn, .apply = applyWrite },
            .{ .ctx = self, .open = openBuildConn, .close = releaseBuildConn, .apply = applyBuild },
            write_workers,
            build_workers,
            keep_going,
        );
        try self.graph.?.start();
        self.graph_active = true;
    }

    pub fn graphActive(self: *DaemonRuntime) bool {
        return self.graph_active;
    }

    /// Submit a `.drv` write (async; takes ownership of `text`). Graph must be active.
    pub fn submitWrite(self: *DaemonRuntime, store_path: []const u8, text: []u8, references: []const []const u8) !void {
        try self.graph.?.submitWrite(store_path, text, references);
    }

    /// Submit a graph build of `drv_path` (a build node gated on its `.drv` write)
    /// with `future`/`result` registered as a waiter, so the caller can park until
    /// it finishes. The single entry point for IFD realization; graph must be
    /// active. Dedupes by drv path (concurrent IFD of the same output shares one
    /// build node).
    pub fn buildAwait(self: *DaemonRuntime, drv_path: []const u8, future: *Future, result: *(anyerror!void)) !void {
        try self.graph.?.submitBuild(drv_path, future, result);
    }

    /// Park `future` on the write of `drv_path` (IFD): true if attached/already
    /// done, false if there is no such write node (caller proceeds).
    pub fn awaitWrite(self: *DaemonRuntime, drv_path: []const u8, future: *Future, result: ?*(anyerror!void)) !bool {
        if (self.graph) |*g| return g.awaitWrite(drv_path, future, result);
        return false;
    }

    /// Are there warm build connections to borrow? True once the graph has run
    /// and its build workers returned their connections here — the signal for
    /// `DerivationStore.buildPaths` to route the terminal build onto the pool
    /// instead of forking its own `self.daemon`.
    pub fn hasBuildPool(self: *DaemonRuntime) bool {
        self.build_pool_mu.lock();
        defer self.build_pool_mu.unlock();
        return self.build_pool.items.len > 0;
    }

    /// Run an authoritative build on a warm pooled build connection, borrowing
    /// one from the pool (or opening one if the pool is empty) and returning it
    /// after. The connection already had build settings applied when it was
    /// opened, so this matches the `ensureDaemon` build path exactly — just on a
    /// warm connection. On error the daemon's message is captured for
    /// `takeErrorMsg`.
    pub fn buildOnPool(self: *DaemonRuntime, derived_paths: []const []const u8, sink: ?rstore.BuildSink, mode: rstore.BuildMode) !void {
        const d = try self.acquireBuildConn();
        defer self.stashBuildConn(d);
        d.buildPaths(derived_paths, sink, mode) catch |err| {
            self.captureErrForce(d);
            return err;
        };
    }

    fn acquireBuildConn(self: *DaemonRuntime) !*rstore.DaemonStore {
        self.build_pool_mu.lock();
        if (self.build_pool.pop()) |d| {
            self.build_pool_mu.unlock();
            return d;
        }
        self.build_pool_mu.unlock();
        // Pool empty (e.g. every warm conn is in flight): fork a fresh one with
        // build settings, same as a build worker would.
        const conn = try openBuildConn(self);
        return @ptrCast(@alignCast(conn));
    }

    fn stashBuildConn(self: *DaemonRuntime, d: *rstore.DaemonStore) void {
        self.build_pool_mu.lock();
        defer self.build_pool_mu.unlock();
        self.build_pool.append(self.cfg.allocator, d) catch d.deinit();
    }

    /// Drain + join the work graph. Returns the first error. Idempotent.
    pub fn finishGraph(self: *DaemonRuntime) ?anyerror {
        if (!self.graph_active) return null;
        self.graph_active = false;
        const err = if (self.graph) |*g| g.finish() else null;
        self.graph = null;
        return err;
    }

    /// Transfer ownership of the first daemon error message (write or build).
    pub fn takeErrorMsg(self: *DaemonRuntime) ?[]u8 {
        self.cfg.err_mu.lock();
        defer self.cfg.err_mu.unlock();
        const msg = self.cfg.err_msg;
        self.cfg.err_msg = null;
        return msg;
    }

    pub fn deinit(self: *DaemonRuntime) void {
        _ = self.finishGraph();
        // Drain the warm build pool. A non-zero capacity implies `startGraph`
        // ran (so `cfg.allocator` is valid); an untouched runtime never allocated.
        if (self.build_pool.capacity > 0) {
            for (self.build_pool.items) |d| d.deinit();
            self.build_pool.deinit(self.cfg.allocator);
        }
        if (self.cfg.err_msg) |msg| self.cfg.allocator.free(msg);
        self.fast.deinit();
    }

    // -- work-graph backend (per-worker connections) --

    /// Write connections do only `addTextToStore` / `isValidPath`, which don't
    /// use build settings — so skip the `setOptions` round-trip (one fewer daemon
    /// round-trip per write connection).
    fn openWriteConn(ctx: *anyopaque) anyerror!*anyopaque {
        const self: *DaemonRuntime = @ptrCast(@alignCast(ctx));
        const d = try rstore.DaemonStore.connect(self.cfg.allocator, self.cfg.io, self.cfg.socket);
        return d;
    }

    /// Build connections need the build settings (max-jobs/cores/keep-going/…).
    fn openBuildConn(ctx: *anyopaque) anyerror!*anyopaque {
        const self: *DaemonRuntime = @ptrCast(@alignCast(ctx));
        const d = try rstore.DaemonStore.connect(self.cfg.allocator, self.cfg.io, self.cfg.socket);
        errdefer d.deinit();
        if (self.cfg.options) |opts| try d.setOptions(opts);
        return d;
    }

    /// Write workers own their connection for the run and close it at shutdown —
    /// write conns never serve the terminal build, so there's nothing to retain.
    fn closeWriteConn(_: *anyopaque, conn: *anyopaque) void {
        const d: *rstore.DaemonStore = @ptrCast(@alignCast(conn));
        d.deinit();
    }

    /// Build workers hand their (warm, options-applied) connection back to the
    /// pool at shutdown instead of closing it, so the terminal authoritative
    /// build can reuse it. Same signature as the vtable `close` slot.
    fn releaseBuildConn(ctx: *anyopaque, conn: *anyopaque) void {
        const self: *DaemonRuntime = @ptrCast(@alignCast(ctx));
        const d: *rstore.DaemonStore = @ptrCast(@alignCast(conn));
        self.stashBuildConn(d);
    }

    fn applyWrite(ctx: *anyopaque, conn: *anyopaque, store_path: []const u8, text: []const u8, refs: []const []const u8) anyerror!void {
        const self: *DaemonRuntime = @ptrCast(@alignCast(ctx));
        const d: *rstore.DaemonStore = @ptrCast(@alignCast(conn));
        // Cache hit (some path already confirmed it in the store): skip the round
        // trip + the write entirely.
        if (self.cfg.dedup) |dd| if (dd.known(dd.ctx, store_path)) return;
        if (!(try d.isValidPath(store_path))) {
            const written = d.addTextToStore(self.cfg.allocator, storePathName(store_path), text, refs) catch |err| {
                self.captureErr(d);
                return err;
            };
            self.cfg.allocator.free(written);
        }
        // Record it as present so later queries / closure walks hit the cache.
        if (self.cfg.dedup) |dd| dd.mark(dd.ctx, store_path);
    }

    fn applyBuild(ctx: *anyopaque, conn: *anyopaque, store_path: []const u8, _: []const u8, _: []const []const u8) anyerror!void {
        const self: *DaemonRuntime = @ptrCast(@alignCast(ctx));
        const d: *rstore.DaemonStore = @ptrCast(@alignCast(conn));
        const derived = try std.fmt.allocPrint(self.cfg.allocator, "{s}!*", .{store_path});
        defer self.cfg.allocator.free(derived);
        // One thread-safe span per build (see BuildSpans); the daemon's per-
        // activity stream goes to a silent sink so build logs don't spam stderr.
        const tok: ?u64 = if (self.cfg.spans) |s| s.begin(s.ctx, storePathName(store_path)) else null;
        defer if (self.cfg.spans) |s| {
            if (tok) |t| s.end(s.ctx, t);
        };
        d.buildPaths(&.{derived}, silent_sink, self.cfg.mode) catch |err| {
            self.captureErr(d);
            return err;
        };
    }

    fn captureErr(self: *DaemonRuntime, d: *rstore.DaemonStore) void {
        self.cfg.err_mu.lock();
        defer self.cfg.err_mu.unlock();
        if (self.cfg.err_set) return;
        if (d.last_error) |msg| {
            self.cfg.err_msg = self.cfg.allocator.dupe(u8, msg) catch null;
            self.cfg.err_set = true;
        }
    }

    /// Like `captureErr` but overwrites — the terminal build runs after the graph
    /// (its error, if any, is the authoritative one to surface, not a stale
    /// eager-build message).
    fn captureErrForce(self: *DaemonRuntime, d: *rstore.DaemonStore) void {
        self.cfg.err_mu.lock();
        defer self.cfg.err_mu.unlock();
        if (d.last_error) |msg| {
            if (self.cfg.err_msg) |old| self.cfg.allocator.free(old);
            self.cfg.err_msg = self.cfg.allocator.dupe(u8, msg) catch null;
            self.cfg.err_set = true;
        }
    }
};

/// A `BuildSink` that discards everything — passed to pooled builds so their
/// per-activity log/progress stream is consumed (keeping the wire in sync)
/// without printing to stderr; the per-build span carries the progress instead.
const silent_sink: rstore.BuildSink = .{
    .context = undefined,
    .on_start = struct {
        fn f(_: *anyopaque, _: u64, _: u64, _: []const u8) void {}
    }.f,
    .on_stop = struct {
        fn f(_: *anyopaque, _: u64) void {}
    }.f,
    .on_progress = struct {
        fn f(_: *anyopaque, _: u64, _: u64, _: u64) void {}
    }.f,
    .on_log = struct {
        fn f(_: *anyopaque, _: []const u8) void {}
    }.f,
};

/// Write-connection pool size: writes are short (a few-KB `addTextToStore`), so a
/// small pool overlaps their round-trips. (Connections are opened lazily, so a
/// small build only ever opens as many as it has concurrent work for.)
const write_workers: usize = 4;
/// Build-connection pool size: each build holds its connection for the whole
/// build, so this bounds concurrent client-driven builds (the daemon also
/// parallelizes each build's closure internally per max-jobs).
const build_workers: usize = 8;
