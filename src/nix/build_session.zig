//! Store-side state and terminal build-session lifecycle.
//!
//! These objects deliberately outlive evaluator language state, but are
//! composed by the evaluator from realization, host, and execution services.

const std = @import("std");
const host = @import("host.zig");
const build_protocol = @import("build_protocol.zig");
const RealizationStore = @import("realization.zig").RealizationStore;
const execution = @import("execution.zig");

/// Explicit process-owned work to run after evaluator language state has been
/// released. Passed to a release operation rather than stored on Evaluator.
pub const ReleaseAction = struct {
    context: *anyopaque,
    run: *const fn (context: *anyopaque) void,
};

pub const StoreState = struct {
    allocator: std.mem.Allocator,
    realization: RealizationStore,
    daemon_runtime: *host.DaemonRuntime,

    pub fn init(allocator: std.mem.Allocator) !StoreState {
        const runtime_ptr = try allocator.create(host.DaemonRuntime);
        errdefer allocator.destroy(runtime_ptr);
        runtime_ptr.* = host.DaemonRuntime.init();
        errdefer runtime_ptr.deinit();

        var realization_store = RealizationStore.init(allocator);
        realization_store.setExecution(runtime_ptr, execution.fiber_executor);
        return .{ .allocator = allocator, .realization = realization_store, .daemon_runtime = runtime_ptr };
    }

    pub fn deinit(self: *StoreState) void {
        self.realization.clearExecution();
        self.daemon_runtime.deinit();
        self.allocator.destroy(self.daemon_runtime);
        self.realization.deinit();
    }

    pub fn buildPaths(self: *StoreState, paths: []const []const u8, sink: ?build_protocol.Sink, mode: build_protocol.Mode) !void {
        return self.realization.buildPaths(paths, sink, mode);
    }

    pub fn lastError(self: *StoreState) ?[]const u8 {
        return self.realization.lastStoreError();
    }

    pub fn addIndirectRoot(self: *StoreState, link_path: []const u8) !void {
        return self.realization.addIndirectRoot(link_path);
    }
};

pub const BuildSession = struct {
    store: *StoreState,
    release_thread: ?std.Thread,

    pub fn init(store: *StoreState, release_thread: ?std.Thread) BuildSession {
        return .{ .store = store, .release_thread = release_thread };
    }

    pub fn deinit(self: *BuildSession) void {
        if (self.release_thread) |thread| thread.join();
        self.release_thread = null;
    }

    pub fn buildPaths(self: *BuildSession, paths: []const []const u8, sink: ?build_protocol.Sink, mode: build_protocol.Mode) !void {
        return self.store.buildPaths(paths, sink, mode);
    }

    pub fn lastStoreError(self: *BuildSession) ?[]const u8 {
        return self.store.lastError();
    }
};
