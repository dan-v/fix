const std = @import("std");
const main = @import("../integration_diff.zig");
const shrink = @import("shrink.zig");
const reporter_mod = @import("reporter.zig");

const Config = main.Config;
const Classification = main.Classification;
const Reporter = reporter_mod.Reporter;

pub fn reportInteresting(
    allocator: std.mem.Allocator,
    io: std.Io,
    classify: shrink.ClassifyFn,
    config: *const Config,
    seed: u64,
    iteration: usize,
    expr: []const u8,
    classification: *const Classification,
    reporter: *Reporter,
) !void {
    if (!config.shrink) {
        try saveAndPrintFailure(allocator, io, config, seed, iteration, expr, classification.*, reporter);
        return;
    }

    const saved_expr = try shrink.shrinkInteresting(allocator, io, classify, config, expr, classification.outcome);
    defer allocator.free(saved_expr);

    var saved_classification = try classify(allocator, io, config, saved_expr);
    defer saved_classification.deinit(allocator);

    try saveAndPrintFailure(allocator, io, config, seed, iteration, saved_expr, saved_classification, reporter);
}

fn saveAndPrintFailure(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: *const Config,
    seed: u64,
    iteration: usize,
    expr: []const u8,
    classification: Classification,
    reporter: *Reporter,
) !void {
    try saveFailure(allocator, io, config, seed, iteration, expr, classification);
    reporter.mismatch(classification.outcome, seed, iteration, config.failure_dir, expr);
}

fn saveFailure(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: *const Config,
    seed: u64,
    iteration: usize,
    expr: []const u8,
    classification: Classification,
) !void {
    try std.Io.Dir.cwd().createDirPath(io, config.failure_dir);

    const prefix = try std.fmt.allocPrint(allocator, "{s}/case-{d}-{d}-{s}", .{
        config.failure_dir,
        seed,
        iteration,
        @tagName(classification.outcome),
    });
    defer allocator.free(prefix);

    const expr_path = try std.fmt.allocPrint(allocator, "{s}.nix", .{prefix});
    defer allocator.free(expr_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = expr_path, .data = expr });

    const report = try std.fmt.allocPrint(allocator,
        \\outcome: {s}
        \\seed: {d}
        \\iteration: {d}
        \\
        \\expression:
        \\{s}
        \\
        \\nix ok: {}
        \\nix stdout:
        \\{s}
        \\nix stderr:
        \\{s}
        \\
        \\fix ok: {}
        \\fix stdout:
        \\{s}
        \\fix stderr:
        \\{s}
        \\
    , .{
        @tagName(classification.outcome),
        seed,
        iteration,
        expr,
        classification.nix.ok,
        classification.nix.stdout,
        classification.nix.stderr,
        classification.fix.ok,
        classification.fix.stdout,
        classification.fix.stderr,
    });
    defer allocator.free(report);

    const report_path = try std.fmt.allocPrint(allocator, "{s}.txt", .{prefix});
    defer allocator.free(report_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = report_path, .data = report });
}
