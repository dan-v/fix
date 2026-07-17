//! Terminal build-session lifecycle after evaluator language state is released.

const std = @import("std");
const store_domain = @import("store");
const StoreState = @import("eval/store_state.zig").StoreState;

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

    pub fn buildPaths(self: *BuildSession, paths: []const []const u8, sink: ?store_domain.daemon.BuildSink, mode: store_domain.daemon.BuildMode) !void {
        return self.store.buildPaths(paths, sink, mode);
    }

    pub fn lastStoreError(self: *BuildSession) ?[]const u8 {
        return self.store.lastError();
    }
};
