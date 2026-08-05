//! Nix-daemon configuration, connection-pool access, and presence cache.

const std = @import("std");
const builtin = @import("builtin");
const sync = @import("base").sync;
const rstore = @import("../daemon.zig");
const DaemonRuntime = @import("../daemon/runtime.zig").DaemonRuntime;
const Future = @import("runtime").future.Future;
const daemon_execution = @import("daemon_execution.zig");

pub const Client = struct {
    allocator: std.mem.Allocator,
    mu: sync.BlockingMutex = .{},
    last_error_msg: ?[]u8 = null,
    instantiated: std.StringHashMapUnmanaged(void) = .empty,
    io: ?std.Io = null,
    socket: []const u8 = rstore.default_socket_path,
    socket_owned: ?[]u8 = null,
    options: ?rstore.BuildSettings = null,
    overrides: std.ArrayListUnmanaged(rstore.Setting) = .empty,
    writes_enabled: bool = false,
    pool_executor: ?daemon_execution.Executor = null,
    runtime: ?*DaemonRuntime = null,
    pool: ?*rstore.DaemonPool = null,
    pool_mu: sync.BlockingMutex = .{},
    test_owned_runtime: if (builtin.is_test) ?*DaemonRuntime else void = if (builtin.is_test) null else {},

    pub fn init(allocator: std.mem.Allocator) Client {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Client) void {
        if (comptime builtin.is_test) {
            if (self.test_owned_runtime) |runtime| {
                runtime.deinit();
                self.allocator.destroy(runtime);
                self.test_owned_runtime = null;
            }
        }
        var instantiated = self.instantiated.keyIterator();
        while (instantiated.next()) |key| self.allocator.free(key.*);
        self.instantiated.deinit(self.allocator);
        deinitOverrides(self.allocator, &self.overrides);
        if (self.socket_owned) |owned| self.allocator.free(owned);
        if (self.last_error_msg) |message| self.allocator.free(message);
    }

    pub fn setBuildSettings(self: *Client, settings: rstore.BuildSettings) !void {
        var replacement: std.ArrayListUnmanaged(rstore.Setting) = .empty;
        errdefer deinitOverrides(self.allocator, &replacement);
        try replacement.ensureTotalCapacity(self.allocator, settings.overrides.len);
        for (settings.overrides) |override| {
            const name = try self.allocator.dupe(u8, override.name);
            errdefer self.allocator.free(name);
            const value = try self.allocator.dupe(u8, override.value);
            errdefer self.allocator.free(value);
            replacement.appendAssumeCapacity(.{
                .name = name,
                .value = value,
            });
        }

        deinitOverrides(self.allocator, &self.overrides);
        self.overrides = replacement;
        var owned = settings;
        owned.overrides = self.overrides.items;
        self.options = owned;
    }

    pub fn setSocket(self: *Client, path: []const u8) !void {
        if (path.len == 0) return;
        const owned = try self.allocator.dupe(u8, path);
        if (self.socket_owned) |old| self.allocator.free(old);
        self.socket_owned = owned;
        self.socket = owned;
    }

    pub fn setBorrowedSocket(self: *Client, path: []const u8) void {
        if (comptime !builtin.is_test) unreachable;
        if (self.socket_owned) |owned| self.allocator.free(owned);
        self.socket_owned = null;
        self.socket = path;
    }

    pub fn socketPath(self: *const Client) []const u8 {
        return self.socket;
    }

    pub fn writesEnabled(self: *const Client) bool {
        return self.writes_enabled;
    }

    pub fn setIo(self: *Client, io: std.Io) void {
        self.io = io;
    }

    pub fn enableWrites(self: *Client) void {
        self.writes_enabled = true;
        _ = self.ensurePool() catch {};
    }

    pub fn setExecution(self: *Client, runtime: *DaemonRuntime, executor: daemon_execution.Executor) void {
        self.runtime = runtime;
        self.pool_executor = executor;
    }

    pub fn clearExecution(self: *Client) void {
        self.pool_executor = null;
        self.runtime = null;
        self.pool = null;
    }

    pub fn takeRuntime(self: *Client, runtime: *DaemonRuntime) void {
        if (comptime !builtin.is_test) unreachable;
        self.runtime = runtime;
        self.test_owned_runtime = runtime;
    }

    pub fn ensurePool(self: *Client) !*rstore.DaemonPool {
        self.pool_mu.lock();
        defer self.pool_mu.unlock();
        if (self.pool) |pool| return pool;
        const runtime = self.runtime orelse return error.StoreUnavailable;
        const io = self.io orelse return error.StoreUnavailable;
        const pool = try runtime.ensurePool(self.allocator, io, self.socket, self.options, self.writes_enabled);
        self.pool = pool;
        return pool;
    }

    pub fn run(self: *Client, work: *const fn (conn: ?*anyopaque, work_ctx: *anyopaque) void, work_ctx: *anyopaque) !void {
        const pool = try self.ensurePool();
        if (self.pool_executor) |executor| {
            executor.runPool(pool, work, work_ctx);
        } else {
            pool.submitBlocking(work, work_ctx);
        }
    }

    /// Enqueue daemon work without parking the submitter. The caller owns the
    /// job and its context until the job signals completion.
    pub fn submit(self: *Client, job: *rstore.DaemonPool.Job) !void {
        const pool = try self.ensurePool();
        pool.submit(job);
    }

    pub fn captureError(self: *Client, conn: *rstore.DaemonStore) void {
        const message = conn.last_error orelse return;
        self.mu.lock();
        defer self.mu.unlock();
        if (self.last_error_msg != null) return;
        self.last_error_msg = self.allocator.dupe(u8, message) catch null;
    }

    pub fn lastError(self: *Client) ?[]const u8 {
        self.mu.lock();
        defer self.mu.unlock();
        return self.last_error_msg;
    }

    pub fn cacheContains(self: *Client, store_path: []const u8) bool {
        self.mu.lock();
        defer self.mu.unlock();
        return self.instantiated.contains(store_path);
    }

    pub fn cacheMark(self: *Client, store_path: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.instantiated.contains(store_path)) return;
        const key = self.allocator.dupe(u8, store_path) catch return;
        self.instantiated.put(self.allocator, key, {}) catch self.allocator.free(key);
    }

    pub fn parkClaim(self: *Client, future: *Future) bool {
        return if (self.pool_executor) |executor| executor.parkFuture(future) else false;
    }
};

fn deinitOverrides(
    allocator: std.mem.Allocator,
    overrides: *std.ArrayListUnmanaged(rstore.Setting),
) void {
    for (overrides.items) |override| {
        allocator.free(override.name);
        allocator.free(override.value);
    }
    overrides.deinit(allocator);
    overrides.* = .empty;
}

fn checkBuildSettingsAllocationFailures(allocator: std.mem.Allocator) !void {
    var client = Client.init(allocator);
    defer client.deinit();
    try client.setBuildSettings(.{ .overrides = &.{
        .{ .name = "max-jobs", .value = "4" },
        .{ .name = "cores", .value = "8" },
    } });
    try std.testing.expectEqual(@as(usize, 2), client.overrides.items.len);
}

test "build settings own complete overrides across every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkBuildSettingsAllocationFailures,
        .{},
    );
}
