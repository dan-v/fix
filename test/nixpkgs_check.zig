//! Package-level nixpkgs parity checker.
//!
//! This intentionally stays smaller than the expression fuzzer: ask Nix for the
//! package attr paths, then compare each derivation path with fix until the
//! first disagreement.

const std = @import("std");
const harness = @import("harness");

const Config = struct {
    nixpkgs: ?[]const u8 = null,
    selector: ?[]const u8 = null,
    skip: usize = 0,
    limit: usize = 0,
    fix_bin: []const u8 = "zig-out/bin/fix",
    nix_bin: []const u8 = "nix-instantiate",
    nix_env_bin: []const u8 = "nix-env",
    timeout_seconds: u32 = 60,
};

const Candidate = struct {
    attr_path: []const u8,

    fn deinit(self: Candidate, allocator: std.mem.Allocator) void {
        allocator.free(self.attr_path);
    }
};

const CheckResult = enum {
    matched,
    skipped,
    failed,
};

const package_stdout_limit = 128 * 1024 * 1024;
const package_stderr_limit = 8 * 1024 * 1024;
const display_limit = 4096;
const nixpkgs_config_expr = "{ allowUnfree = true; allowBroken = true; allowUnsupportedSystem = true; }";
const pinned_nixpkgs_expr = "(import ./npins).nixpkgs.outPath";

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var config: Config = .{};
    try parseArgs(&config, init);

    if (config.timeout_seconds == 0) {
        std.debug.print("--timeout must be greater than zero\n", .{});
        std.process.exit(2);
    }

    const nixpkgs_path = try resolveNixpkgs(allocator, init.io, config);
    defer allocator.free(nixpkgs_path);

    const listed = try listPackages(allocator, init.io, config, nixpkgs_path);
    defer listed.deinit(allocator);
    if (!listed.ok) {
        reportCommandFailure("nix-env", listed);
        std.process.exit(1);
    }

    const candidates = parseCandidates(allocator, listed.stdout) catch |err| {
        std.debug.print("nixpkgs-check: failed to parse nix-env JSON: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer freeCandidates(allocator, candidates);
    if (candidates.len == 0) {
        std.debug.print("nixpkgs-check: no package candidates\n", .{});
        std.process.exit(1);
    }

    std.mem.sort(Candidate, candidates, {}, lessThanCandidate);

    const window = checkWindow(candidates.len, config.skip, config.limit);
    if (window.total == 0) {
        std.debug.print("nixpkgs-check: no package candidates after --skip/--limit\n", .{});
        std.process.exit(1);
    }
    std.debug.print("nixpkgs-check: candidates={} skip={} checking={}\n", .{ candidates.len, window.start, window.total });

    var checked: usize = 0;
    var matched: usize = 0;
    var skipped: usize = 0;
    while (checked < window.total) : (checked += 1) {
        const candidate = candidates[window.start + checked];
        switch (try checkCandidate(allocator, init.io, config, nixpkgs_path, candidate, checked + 1, window.total)) {
            .matched => matched += 1,
            .skipped => skipped += 1,
            .failed => std.process.exit(1),
        }
    }

    std.debug.print("nixpkgs-check: ok checked={} matched={} skipped={}\n", .{ checked, matched, skipped });
}

fn listPackages(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config,
    nixpkgs_path: []const u8,
) !harness.CommandResult {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);

    try argv.appendSlice(allocator, &.{
        config.nix_env_bin,
        "-qaP",
        "-f",
        nixpkgs_path,
        "--arg",
        "config",
        nixpkgs_config_expr,
        "--json",
    });
    if (config.selector) |selector| try argv.append(allocator, selector);

    return harness.runCommandWithLimits(
        allocator,
        io,
        config.timeout_seconds,
        argv.items,
        .{ .stdout = package_stdout_limit, .stderr = package_stderr_limit },
    );
}

fn resolveNixpkgs(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config,
) ![]u8 {
    const requested = config.nixpkgs orelse return resolveNixExprPath(allocator, io, config, pinned_nixpkgs_expr);
    if (!isAnglePath(requested)) return allocator.dupe(u8, requested);

    const expr = try std.mem.concat(allocator, u8, &.{ "toString ", requested });
    defer allocator.free(expr);
    return resolveNixExprPath(allocator, io, config, expr);
}

fn resolveNixExprPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config,
    expr: []const u8,
) ![]u8 {
    const resolved = try harness.runCommand(
        allocator,
        io,
        config.timeout_seconds,
        &.{ config.nix_bin, "--eval", "--raw", "--expr", expr },
    );
    defer resolved.deinit(allocator);

    if (!resolved.ok) {
        reportCommandFailure("nixpkgs path resolution", resolved);
        std.process.exit(1);
    }

    const path = trimOutput(resolved.stdout);
    if (path.len == 0) return error.InvalidNixpkgsPath;
    return allocator.dupe(u8, path);
}

fn parseCandidates(allocator: std.mem.Allocator, json_text: []const u8) ![]Candidate {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
    defer parsed.deinit();

    var candidates: std.ArrayListUnmanaged(Candidate) = .empty;
    errdefer {
        for (candidates.items) |candidate| candidate.deinit(allocator);
        candidates.deinit(allocator);
    }

    switch (parsed.value) {
        .object => |object| {
            var it = object.iterator();
            while (it.next()) |entry| {
                if (entry.key_ptr.*.len == 0) return error.InvalidPackageAttrPath;
                try candidates.append(allocator, .{
                    .attr_path = try allocator.dupe(u8, entry.key_ptr.*),
                });
            }
        },
        else => return error.InvalidPackageJson,
    }

    return candidates.toOwnedSlice(allocator);
}

fn freeCandidates(allocator: std.mem.Allocator, candidates: []Candidate) void {
    for (candidates) |candidate| candidate.deinit(allocator);
    allocator.free(candidates);
}

fn lessThanCandidate(_: void, lhs: Candidate, rhs: Candidate) bool {
    return std.mem.lessThan(u8, lhs.attr_path, rhs.attr_path);
}

const CheckWindow = struct {
    start: usize,
    total: usize,
};

fn checkWindow(candidate_count: usize, skip: usize, limit: usize) CheckWindow {
    const start = @min(skip, candidate_count);
    const available = candidate_count - start;
    const total = if (limit == 0) available else @min(limit, available);
    return .{ .start = start, .total = total };
}

fn checkCandidate(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config,
    nixpkgs_path: []const u8,
    candidate: Candidate,
    index: usize,
    total: usize,
) !CheckResult {
    const expr = try drvPathExpr(allocator, nixpkgs_path, candidate.attr_path);
    defer allocator.free(expr);

    const nix = try harness.runCommand(allocator, io, config.timeout_seconds, &.{ config.nix_bin, "--eval", "--expr", expr });
    defer nix.deinit(allocator);

    if (!nix.ok) {
        reportProgress(index, total, candidate.attr_path);
        return .skipped;
    }

    const fix = try harness.runCommand(allocator, io, config.timeout_seconds, &.{ config.fix_bin, "--expr", expr });
    defer fix.deinit(allocator);

    if (fix.ok) {
        const nix_out = trimOutput(nix.stdout);
        const fix_out = trimOutput(fix.stdout);
        if (std.mem.eql(u8, nix_out, fix_out)) {
            reportProgress(index, total, candidate.attr_path);
            return .matched;
        }
        reportMismatch(candidate.attr_path, expr, "drvPath mismatch", nix, fix);
        return .failed;
    }

    if (fix.timed_out) {
        reportMismatch(candidate.attr_path, expr, "command timed out", nix, fix);
    } else {
        reportMismatch(candidate.attr_path, expr, "fix rejected Nix package", nix, fix);
    }
    return .failed;
}

fn reportProgress(index: usize, total: usize, attr_path: []const u8) void {
    if (index == total or index == 1 or index % 100 == 0) {
        std.debug.print("nixpkgs-check: checked {}/{} {s}\n", .{ index, total, attr_path });
    }
}

fn reportMismatch(
    attr_path: []const u8,
    expr: []const u8,
    reason: []const u8,
    nix: harness.CommandResult,
    fix: harness.CommandResult,
) void {
    std.debug.print("nixpkgs-check: {s}: {s}\n", .{ reason, attr_path });
    std.debug.print("expression:\n{s}\n", .{expr});
    printCommandResult("nix", nix);
    printCommandResult("fix", fix);
}

fn reportCommandFailure(label: []const u8, result: harness.CommandResult) void {
    std.debug.print("nixpkgs-check: {s} failed\n", .{label});
    printCommandResult(label, result);
}

fn printCommandResult(label: []const u8, result: harness.CommandResult) void {
    std.debug.print("{s}: ok={} timed_out={}\n", .{ label, result.ok, result.timed_out });
    printBlock(label, "stdout", result.stdout);
    printBlock(label, "stderr", result.stderr);
}

fn printBlock(label: []const u8, stream: []const u8, text: []const u8) void {
    const trimmed = trimOutput(text);
    if (trimmed.len == 0) return;

    const shown = trimmed[0..@min(trimmed.len, display_limit)];
    std.debug.print("{s} {s}:\n{s}", .{ label, stream, shown });
    if (shown.len != trimmed.len) std.debug.print("\n... truncated {} bytes", .{trimmed.len - shown.len});
    std.debug.print("\n", .{});
}

fn trimOutput(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t\r\n");
}

fn drvPathExpr(allocator: std.mem.Allocator, nixpkgs: []const u8, attr_path: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try out.writer.writeAll(
        \\let
        \\  pkgs = import 
    );
    try writeNixImportPath(&out.writer, nixpkgs);
    try out.writer.writeAll(" {\n    config = ");
    try out.writer.writeAll(nixpkgs_config_expr);
    try out.writer.writeAll(";\n  };\nin pkgs");
    try writeAttrSelector(&out.writer, attr_path);
    try out.writer.writeAll(".drvPath");

    return out.toOwnedSlice();
}

fn writeNixImportPath(writer: *std.Io.Writer, nixpkgs: []const u8) !void {
    if (nixpkgs.len == 0) return error.InvalidNixpkgsPath;
    if (isAnglePath(nixpkgs) or nixpkgs[0] == '/' or nixpkgs[0] == '.') {
        try writer.writeAll(nixpkgs);
        return;
    }
    return error.InvalidNixpkgsPath;
}

fn isAnglePath(path: []const u8) bool {
    return path.len >= 3 and path[0] == '<' and path[path.len - 1] == '>';
}

fn writeAttrSelector(writer: *std.Io.Writer, attr_path: []const u8) !void {
    var parts = std.mem.splitScalar(u8, attr_path, '.');
    while (parts.next()) |part| {
        if (part.len == 0) return error.InvalidPackageAttrPath;
        try writer.writeByte('.');
        try writeNixString(writer, part);
    }
}

fn writeNixString(writer: *std.Io.Writer, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |c| {
        switch (c) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}

fn parseArgs(config: *Config, init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();

    _ = args.next();
    while (args.next()) |arg| {
        if (try harness.optionValue(&args, arg, "--nixpkgs")) |value| {
            config.nixpkgs = value;
        } else if (try harness.optionValue(&args, arg, "--selector")) |value| {
            config.selector = value;
        } else if (try harness.optionValue(&args, arg, "--skip")) |value| {
            config.skip = try std.fmt.parseInt(usize, value, 10);
        } else if (try harness.optionValue(&args, arg, "--limit")) |value| {
            config.limit = try std.fmt.parseInt(usize, value, 10);
        } else if (try harness.optionValue(&args, arg, "--fix-bin")) |value| {
            config.fix_bin = value;
        } else if (try harness.optionValue(&args, arg, "--nix-bin")) |value| {
            config.nix_bin = value;
        } else if (try harness.optionValue(&args, arg, "--nix-env-bin")) |value| {
            config.nix_env_bin = value;
        } else if (try harness.optionValue(&args, arg, "--timeout")) |value| {
            config.timeout_seconds = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            usage();
            std.process.exit(0);
        } else {
            std.debug.print("unknown argument: {s}\n", .{arg});
            usage();
            return error.UnknownArgument;
        }
    }
}

fn usage() void {
    std.debug.print(
        \\usage: zig build nixpkgs-check -- [options]
        \\
        \\options:
        \\  --nixpkgs PATH      nixpkgs path for nix-env/import (default: pinned ./npins)
        \\  --selector TEXT     optional nix-env selector, such as hello
        \\  --skip N            skip the first N sorted candidates
        \\  --limit N           stop after N candidates; 0 means all
        \\  --fix-bin PATH      fix executable (default: zig-out/bin/fix)
        \\  --nix-bin PATH      nix-instantiate executable
        \\  --nix-env-bin PATH  nix-env executable
        \\  --timeout N         seconds per command (default: 60)
        \\
    , .{});
}

test "drvPath expression quotes attr path components" {
    const expr = try drvPathExpr(std.testing.allocator, "<nixpkgs>", "haskellPackages.hello");
    defer std.testing.allocator.free(expr);
    try std.testing.expect(std.mem.indexOf(u8, expr, "pkgs.\"haskellPackages\".\"hello\".drvPath") != null);
}

test "check window applies skip before limit" {
    try std.testing.expectEqual(CheckWindow{ .start = 0, .total = 10 }, checkWindow(10, 0, 0));
    try std.testing.expectEqual(CheckWindow{ .start = 3, .total = 7 }, checkWindow(10, 3, 0));
    try std.testing.expectEqual(CheckWindow{ .start = 3, .total = 4 }, checkWindow(10, 3, 4));
    try std.testing.expectEqual(CheckWindow{ .start = 10, .total = 0 }, checkWindow(10, 12, 4));
}
