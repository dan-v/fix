//! Nix-daemon configuration, connection-pool access, and presence cache.

const std = @import("std");
const builtin = @import("builtin");
const sync = @import("base").sync;
const host = @import("../host.zig");
const rstore = host.store;
const DaemonRuntime = host.DaemonRuntime;
const Future = @import("runtime").future.Future;
const execution_port = @import("../execution/port.zig");

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
    fiber_executor: ?execution_port.FiberExecutor = null,
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
        for (self.overrides.items) |override| {
            self.allocator.free(override.name);
            self.allocator.free(override.value);
        }
        self.overrides.deinit(self.allocator);
        if (self.socket_owned) |owned| self.allocator.free(owned);
        if (self.last_error_msg) |message| self.allocator.free(message);
    }

    pub fn setBuildSettings(self: *Client, settings: rstore.BuildSettings) !void {
        for (self.overrides.items) |override| {
            self.allocator.free(override.name);
            self.allocator.free(override.value);
        }
        self.overrides.clearRetainingCapacity();
        for (settings.overrides) |override| {
            try self.overrides.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, override.name),
                .value = try self.allocator.dupe(u8, override.value),
            });
        }
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

    pub fn setBorrowedSocketForTest(self: *Client, path: []const u8) void {
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

    pub fn setExecution(self: *Client, runtime: *DaemonRuntime, executor: execution_port.FiberExecutor) void {
        self.runtime = runtime;
        self.fiber_executor = executor;
    }

    pub fn clearExecution(self: *Client) void {
        self.fiber_executor = null;
        self.runtime = null;
        self.pool = null;
    }

    pub fn setTestRuntime(self: *Client, runtime: *DaemonRuntime) void {
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
        if (self.fiber_executor) |executor| {
            executor.runPool(pool, work, work_ctx);
        } else {
            pool.submitBlocking(work, work_ctx);
        }
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
        return if (self.fiber_executor) |executor| executor.parkFuture(future) else false;
    }
};
