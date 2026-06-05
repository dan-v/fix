const std = @import("std");

pub const default_stdout_limit = 8 * 1024 * 1024;
pub const default_stderr_limit = 1024 * 1024;

pub const CommandLimits = struct {
    stdout: usize = default_stdout_limit,
    stderr: usize = default_stderr_limit,
};

pub const CommandResult = struct {
    ok: bool,
    comparable: bool = true,
    timed_out: bool = false,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: CommandResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

pub fn runCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    timeout_seconds: u32,
    argv: []const []const u8,
) !CommandResult {
    return runCommandWithLimits(allocator, io, timeout_seconds, argv, .{});
}

pub fn runCommandWithLimits(
    allocator: std.mem.Allocator,
    io: std.Io,
    timeout_seconds: u32,
    argv: []const []const u8,
    limits: CommandLimits,
) !CommandResult {
    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(limits.stdout),
        .stderr_limit = .limited(limits.stderr),
        .timeout = .{ .duration = commandTimeout(timeout_seconds) },
    }) catch |err| switch (err) {
        error.Timeout => return .{
            .ok = false,
            .comparable = false,
            .timed_out = true,
            .stdout = try allocator.dupe(u8, ""),
            .stderr = try std.fmt.allocPrint(allocator, "command timed out after {}s", .{timeout_seconds}),
        },
        error.StreamTooLong => return .{
            .ok = false,
            .comparable = false,
            .stdout = try allocator.dupe(u8, ""),
            .stderr = try allocator.dupe(u8, "output exceeded integration harness limit"),
        },
        else => return err,
    };

    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };

    return .{
        .ok = ok,
        .comparable = true,
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

pub fn optionValue(args: anytype, arg: []const u8, comptime name: []const u8) !?[]const u8 {
    if (std.mem.eql(u8, arg, name)) return args.next() orelse error.MissingArgument;
    if (std.mem.startsWith(u8, arg, name) and arg.len > name.len and arg[name.len] == '=') {
        return arg[name.len + 1 ..];
    }
    return null;
}

fn commandTimeout(seconds: u32) std.Io.Clock.Duration {
    return .{
        .raw = std.Io.Duration.fromSeconds(@intCast(seconds)),
        .clock = .awake,
    };
}
