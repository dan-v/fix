//! CLI stderr sink for evaluator effects and unadorned daemon build logs.
//!
//! Engines and protocol clients emit semantic records; this module owns the
//! process-facing decision to write them, synchronize terminal repaint, and
//! restore terminal state after fatal signals. Interactive build commands use
//! `build_progress.zig` instead; this raw sink serves commands whose stdout is
//! machine-consumable.

const std = @import("std");
const expr = @import("expr");
const daemon = @import("store").daemon;

pub const StderrSink = struct {
    io: std.Io,
    sync_updates: bool,

    pub fn create(allocator: std.mem.Allocator, io: std.Io, sync_updates: bool) !*StderrSink {
        const self = try allocator.create(StderrSink);
        self.* = .{ .io = io, .sync_updates = sync_updates };
        if (sync_updates) installSyncCleanup();
        return self;
    }

    pub fn destroy(self: *StderrSink, allocator: std.mem.Allocator) void {
        allocator.destroy(self);
    }

    pub fn effectSink(self: *StderrSink) expr.EffectSink {
        return .{ .context = self, .emit_fn = emit };
    }

    pub fn buildSink(self: *StderrSink) daemon.BuildSink {
        return .{ .context = self, .emit_fn = emitBuild };
    }

    fn emit(raw: ?*anyopaque, kind: expr.EffectKind, message: []const u8) void {
        const self: *StderrSink = @ptrCast(@alignCast(raw.?));
        var buffer: [4096]u8 = undefined;
        var locked = self.io.lockStderr(&buffer, null) catch return;
        defer self.io.unlockStderr();
        const writer = &locked.file_writer.interface;
        const label: []const u8 = switch (kind) {
            .trace => "trace",
            .warning => "warning",
        };
        if (self.sync_updates) {
            var parts = [_][]const u8{ sync_begin, label, ": ", message, "\n", sync_end };
            writer.writeSplatAll(&parts, 1) catch return;
        } else {
            var parts = [_][]const u8{ label, ": ", message, "\n" };
            writer.writeSplatAll(&parts, 1) catch return;
        }
        writer.flush() catch {};
    }

    fn emitBuild(raw: *anyopaque, event: daemon.BuildEvent) void {
        const log = switch (event) {
            .log => |value| value,
            else => return,
        };
        const self: *StderrSink = @ptrCast(@alignCast(raw));
        var buffer: [4096]u8 = undefined;
        var locked = self.io.lockStderr(&buffer, null) catch return;
        defer self.io.unlockStderr();
        const writer = &locked.file_writer.interface;
        if (self.sync_updates) writer.writeAll(sync_begin) catch return;
        defer if (self.sync_updates) writer.writeAll(sync_end) catch {};
        writer.writeAll(log.text) catch return;
        if (!std.mem.endsWith(u8, log.text, "\n")) writer.writeByte('\n') catch return;
        writer.flush() catch {};
    }
};

const sync_begin = "\x1b[?2026h";
const sync_end = "\x1b[?2026l";

/// A fatal signal between the synchronization markers would otherwise leave
/// the terminal apparently frozen. Installation is process-global/idempotent.
const sync_cleanup = struct {
    const hooked = [_]std.posix.SIG{ .INT, .TERM, .HUP, .QUIT };
    var installed = false;
    var prev: [hooked.len]std.posix.Sigaction = undefined;

    fn handler(sig: std.posix.SIG) callconv(.c) void {
        _ = std.posix.system.write(std.posix.STDERR_FILENO, sync_end.ptr, sync_end.len);
        for (hooked, 0..) |candidate, i| {
            if (candidate == sig) {
                std.posix.sigaction(sig, &prev[i], null);
                break;
            }
        }
        _ = std.posix.raise(sig) catch {};
    }
};

fn installSyncCleanup() void {
    if (sync_cleanup.installed) return;
    sync_cleanup.installed = true;
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = sync_cleanup.handler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    for (sync_cleanup.hooked, 0..) |sig, i|
        std.posix.sigaction(sig, &action, &sync_cleanup.prev[i]);
}
