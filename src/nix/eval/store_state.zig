//! Store-side evaluator state that survives language-state teardown.
//!
//! This is the composition point for realization, the daemon runtime, and the
//! realization-owned adapter that parks daemon work off compute fibers.

const std = @import("std");
const host = @import("../host.zig");
const realization = @import("../realization.zig");

pub const StoreState = struct {
    allocator: std.mem.Allocator,
    realization: realization.RealizationStore,
    daemon_runtime: *host.DaemonRuntime,

    pub fn init(allocator: std.mem.Allocator) !StoreState {
        const runtime_ptr = try allocator.create(host.DaemonRuntime);
        errdefer allocator.destroy(runtime_ptr);
        runtime_ptr.* = host.DaemonRuntime.init();
        errdefer runtime_ptr.deinit();

        var realization_store = realization.RealizationStore.init(allocator);
        realization_store.setExecution(runtime_ptr, realization.daemon_execution.fiber_executor);
        return .{ .allocator = allocator, .realization = realization_store, .daemon_runtime = runtime_ptr };
    }

    pub fn deinit(self: *StoreState) void {
        self.realization.clearExecution();
        self.daemon_runtime.deinit();
        self.allocator.destroy(self.daemon_runtime);
        self.realization.deinit();
    }

    pub fn buildPaths(self: *StoreState, paths: []const []const u8, sink: ?host.store.BuildSink, mode: host.store.BuildMode) !void {
        return self.realization.buildPaths(paths, sink, mode);
    }

    pub fn lastError(self: *StoreState) ?[]const u8 {
        return self.realization.lastStoreError();
    }

    pub fn addIndirectRoot(self: *StoreState, link_path: []const u8) !void {
        return self.realization.addIndirectRoot(link_path);
    }
};
