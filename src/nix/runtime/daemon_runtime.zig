//! DaemonRuntime: owns the background IO thread `fix` uses to run blocking
//! nix-daemon store ops off the compute-fiber workers.
//!
//! The **fast lane** is a single serial executor thread (`IoRuntime`) that runs
//! short offloaded daemon ops while the calling fiber parks (`vm/io_offload`):
//! source/flat/`.drv` writes, `isValidPath` queries, and IFD realization. The
//! nix-daemon connection is blocking and strictly serial (one socket, objects
//! added in reverse-topological / force order), so a single draining thread
//! matches it exactly while keeping every socket syscall off the worker threads.
//!
//! The whole eval routes its store I/O through this one thread onto the store's
//! single daemon connection, so that connection stays warm + options-applied for
//! the terminal authoritative build — no separate build-connection pool needed.

const io_runtime = @import("io_runtime.zig");

pub const DaemonRuntime = struct {
    fast: io_runtime.IoRuntime = .{},

    pub fn init() DaemonRuntime {
        return .{};
    }

    pub fn start(self: *DaemonRuntime) !void {
        try self.fast.start();
    }

    pub fn fastRuntime(self: *DaemonRuntime) *io_runtime.IoRuntime {
        return &self.fast;
    }

    pub fn deinit(self: *DaemonRuntime) void {
        self.fast.deinit();
    }
};
