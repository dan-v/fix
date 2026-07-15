//! DaemonRuntime: owns the background daemon-facing infrastructure `fix` uses to
//! keep blocking nix-daemon store ops off the compute-fiber workers.
//!
//! The **pool** (`store/pool.zig`) is a set of hot daemon connections, each on
//! its own background IO thread, draining a shared job queue. Every store op —
//! `.drv`/source writes, `isValidPath` queries, builds, GC roots — is submitted
//! to the pool while the calling fiber parks (`vm/io_offload`); a worker runs it
//! on a warm connection and wakes the fiber. Connections stay hot and reused
//! across the whole run (eval, on-demand closure writes, the terminal build).
//! These threads are IO-bound (parked on the socket), separate from and not
//! counted against the `--workers` compute pool.
//!
//! The pool starts lazily (`ensurePool`) on the first store op — a pure `eval`
//! that never touches the daemon never forks a connection. Ordering is not the
//! pool's concern: it belongs to `DerivationStore`'s demand-driven closure walk
//! (see `store/pool.zig`).
//!
//! The **fast lane** (a single serial `IoRuntime`) remains for the legacy offload
//! seam during the pool cutover; it is retired once every op routes to the pool.

const std = @import("std");
const io_runtime = @import("io_runtime.zig");
const rstore = @import("store.zig");
const sync = @import("base").sync;

const DaemonPool = rstore.DaemonPool;

/// Hot-connection count. Its own knob: these are IO-bound threads parked on the
/// daemon socket, so this is not tied to `--workers`. Bounds concurrent client-
/// driven builds (each build holds its connection for the whole build); writes
/// and queries are short and interleave freely.
const default_pool_workers: usize = 8;

pub const DaemonRuntime = struct {
    fast: io_runtime.IoRuntime = .{},

    pool: DaemonPool = undefined,
    pool_started: bool = false,
    pool_mu: sync.BlockingMutex = .{},
    cfg: ConnConfig = .{},
    /// Hot-connection count (see `default_pool_workers`). Overridable — tests set
    /// a small value against the fake daemon.
    pool_workers: usize = default_pool_workers,

    /// How the pool opens a connection. `apply_options` is on only for store-
    /// writing commands (build/instantiate/run/shell): plain `eval` that realizes
    /// on demand (IFD) must NOT push fix's resolved settings, which would replace
    /// the daemon's richer defaults (e.g. strip `/bin/sh` from the build sandbox);
    /// the daemon reads the same nix.conf, so its own config is authoritative.
    const ConnConfig = struct {
        allocator: std.mem.Allocator = undefined,
        io: std.Io = undefined,
        socket: []const u8 = "",
        options: ?rstore.BuildSettings = null,
        apply_options: bool = false,
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

    /// Lazily create + start the connection pool with the given connection config.
    /// Idempotent: the first caller sets the config and spawns the warm workers;
    /// later callers get the running pool. Config is fixed per run (socket +
    /// options + write-mode don't change once a command is under way).
    pub fn ensurePool(
        self: *DaemonRuntime,
        allocator: std.mem.Allocator,
        io: std.Io,
        socket: []const u8,
        options: ?rstore.BuildSettings,
        apply_options: bool,
    ) !*DaemonPool {
        self.pool_mu.lock();
        defer self.pool_mu.unlock();
        if (self.pool_started) return &self.pool;
        self.cfg = .{ .allocator = allocator, .io = io, .socket = socket, .options = options, .apply_options = apply_options };
        self.pool = DaemonPool.init(allocator, .{ .ctx = self, .open = openConn, .close = closeConn }, self.pool_workers);
        try self.pool.start();
        self.pool_started = true;
        return &self.pool;
    }

    fn openConn(ctx: *anyopaque) anyerror!*anyopaque {
        const self: *DaemonRuntime = @ptrCast(@alignCast(ctx));
        const d = try rstore.DaemonStore.connect(self.cfg.allocator, self.cfg.io, self.cfg.socket);
        errdefer d.deinit();
        if (self.cfg.apply_options) {
            if (self.cfg.options) |opts| try d.setOptions(opts);
        }
        return d;
    }

    fn closeConn(_: *anyopaque, conn: *anyopaque) void {
        const d: *rstore.DaemonStore = @ptrCast(@alignCast(conn));
        d.deinit();
    }

    pub fn deinit(self: *DaemonRuntime) void {
        if (self.pool_started) self.pool.deinit();
        self.fast.deinit();
    }
};
