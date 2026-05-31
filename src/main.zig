//! fix — blazing fast Nix evaluator CLI entry point.

const std = @import("std");
const builtin = @import("builtin");
const eval = @import("eval.zig");
const diagnostic = @import("diagnostic.zig");
const Evaluator = eval.Evaluator;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args_iter = try init.minimal.args.iterateAllocator(allocator);
    defer args_iter.deinit();

    const usage =
        \\usage: fix <expression> | -e <expression> | --file <path>
        \\
    ;

    const prog_name = args_iter.next() orelse {
        std.debug.print("{s}", .{usage});
        std.process.exit(1);
    };
    _ = prog_name;

    const arg1 = args_iter.next() orelse {
        std.debug.print("{s}", .{usage});
        std.process.exit(1);
    };

    const worker_count: u8 = if (builtin.single_threaded)
        1
    else
        @intCast(@min(@as(u32, 8), @as(u32, @intCast(try std.Thread.getCpuCount()))));

    var ev = try Evaluator.init(allocator, worker_count);
    defer ev.deinit();
    try ev.setBasePathFromCurrentPath(init.io);

    const source = getSource(init.io, allocator, arg1, &args_iter) catch |err| {
        std.debug.print("Error reading source: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer if (source.owned) allocator.free(source.text);

    const result = ev.evaluate(source.text) catch |err| {
        if (ev.getDiagnostics().len > 0) {
            var stderr_buffer: [1024]u8 = undefined;
            var stderr = std.Io.File.stderr().writerStreaming(init.io, &stderr_buffer);
            try diagnostic.writeAll(&stderr.interface, source.text, ev.getDiagnostics());
            try stderr.interface.flush();
        } else {
            std.debug.print("Evaluation error: {s}\n", .{@errorName(err)});
        }
        std.process.exit(1);
    };

    var stdout_buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    try ev.writeValue(&stdout.interface, result);
    try stdout.interface.writeByte('\n');
    try stdout.interface.flush();
}

const Source = struct {
    text: []const u8,
    owned: bool,
};

fn getSource(
    io: std.Io,
    allocator: std.mem.Allocator,
    first_arg: []const u8,
    args_iter: *std.process.Args.Iterator,
) !Source {
    if (std.mem.eql(u8, first_arg, "-e")) {
        return .{ .text = args_iter.next() orelse return error.MissingExpression, .owned = false };
    }
    if (std.mem.eql(u8, first_arg, "--file")) {
        const path = args_iter.next() orelse return error.MissingPath;
        return .{
            .text = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)),
            .owned = true,
        };
    }
    return .{ .text = first_arg, .owned = false };
}
