//! Subprocess helper for the conformance runner: spawn `fix` (or a resolver
//! command like `nix-instantiate`), capture stdout+stderr, and enforce a hard
//! per-case timeout. Mirrors run.py's `run_fix`: a wedged child cannot hang the
//! run (std.process.run kills it on the timeout error), and a launch failure is
//! surfaced as rc -1 rather than crashing the runner.

const std = @import("std");

/// A finished (or timed-out) subprocess. `rc` is the exit code, or -1 for a
/// timeout / launch failure / termination by signal (all "not a clean exit",
/// matching how run.py treats a non-1 code on an expected-failure case).
pub const Output = struct {
    rc: i32,
    stdout: []u8,
    stderr: []u8,
    timed_out: bool = false,

    pub fn deinit(self: *Output, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }
};

/// Same 10s ceiling as run.py's CASE_TIMEOUT_S.
pub const case_timeout_ns: i96 = 10 * std.time.ns_per_s;

/// A child environment = a copy of the parent's, with NO_COLOR defaulted on.
/// Callers add per-case overrides (HOME, NIX_PATH, ...) with `env.put(...)`.
pub fn cloneEnv(gpa: std.mem.Allocator, parent: *const std.process.Environ.Map) !std.process.Environ.Map {
    var map = try parent.clone(gpa);
    if (map.get("NO_COLOR") == null) try map.put("NO_COLOR", "1");
    return map;
}

/// Run `argv`, capturing both streams, killed after `timeout_ns`. `cwd` null
/// inherits the parent's; `env` null inherits the parent's environment.
pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    cwd: ?[]const u8,
    env: ?*const std.process.Environ.Map,
    timeout_ns: i96,
) !Output {
    const res = std.process.run(gpa, io, .{
        .argv = argv,
        .cwd = if (cwd) |c| .{ .path = c } else .inherit,
        .environ_map = env,
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromNanoseconds(timeout_ns) } },
    }) catch |err| switch (err) {
        error.Timeout => return .{
            .rc = -1,
            .stdout = try gpa.dupe(u8, ""),
            .stderr = try gpa.dupe(u8, "timed out"),
            .timed_out = true,
        },
        else => return .{
            .rc = -1,
            .stdout = try gpa.dupe(u8, ""),
            .stderr = try std.fmt.allocPrint(gpa, "failed to launch: {s}", .{@errorName(err)}),
        },
    };
    return .{
        .rc = switch (res.term) {
            .exited => |c| @intCast(c),
            else => -1,
        },
        .stdout = res.stdout,
        .stderr = res.stderr,
    };
}

/// Resolve an npins pin to its /nix/store path (run.py's `pin_path`): force the
/// corpus into the store, then print its path. Caller owns the returned slice.
pub fn resolvePin(gpa: std.mem.Allocator, io: std.Io, repo: []const u8, name: []const u8) ![]u8 {
    const expr = try std.fmt.allocPrint(gpa,
        \\let source = (import {s}/npins).{s};
        \\in builtins.seq (builtins.readDir source) (builtins.toString source)
    , .{ repo, name });
    defer gpa.free(expr);
    const argv = [_][]const u8{ "nix-instantiate", "--eval", "--strict", "--raw", "--expr", expr };
    var out = try run(gpa, io, &argv, null, null, 120 * std.time.ns_per_s);
    defer out.deinit(gpa);
    if (out.rc != 0) {
        std.debug.print("failed to resolve pin '{s}':\n{s}\n", .{ name, out.stderr });
        return error.PinResolutionFailed;
    }
    return gpa.dupe(u8, std.mem.trim(u8, out.stdout, " \n\r\t"));
}
