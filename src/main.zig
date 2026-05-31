//! fix — blazing fast Nix evaluator CLI entry point.

const std = @import("std");
const builtin = @import("builtin");
const eval = @import("eval.zig");
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

    const source = getSource(init.io, allocator, arg1, &args_iter) catch |err| {
        std.debug.print("Error reading source: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer if (source.owned) allocator.free(source.text);

    const result = ev.evaluate(source.text) catch |err| {
        if (ev.getDiagnostics().len > 0) {
            printDiagnostics(source.text, ev.getDiagnostics());
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

fn printDiagnostics(source: []const u8, diagnostics: []const eval.Diagnostic) void {
    for (diagnostics) |diagnostic| {
        switch (diagnostic.severity) {
            .err => switch (diagnostic.kind) {
                .parse => std.debug.print("error: parse error at {d}:{d}: {s}\n", .{
                    diagnostic.line,
                    diagnostic.column,
                    diagnostic.message,
                }),
                .compile => std.debug.print("error: {s} at {d}:{d}\n", .{
                    diagnostic.message,
                    diagnostic.line,
                    diagnostic.column,
                }),
            },
            .note => std.debug.print("note: {s} at {d}:{d}\n", .{
                diagnostic.message,
                diagnostic.line,
                diagnostic.column,
            }),
        }

        const line = lineSpan(source, diagnostic.offset);
        std.debug.print("{d: >4} | {s}\n", .{ diagnostic.line, source[line.start..line.end] });
        std.debug.print("     | ", .{});
        writeSpaces(diagnostic.column - 1);
        const caret_count = @max(@as(u32, 1), diagnostic.len);
        var i: u32 = 0;
        while (i < caret_count) : (i += 1) {
            std.debug.print("^", .{});
        }

        if (diagnostic.token_type == null or diagnostic.token_type.? != .eof) {
            const start: usize = @intCast(diagnostic.offset);
            const len: usize = @intCast(diagnostic.len);
            if (start <= source.len and len <= source.len - start) {
                std.debug.print(" near `{s}`", .{source[start .. start + len]});
            }
        }
        std.debug.print("\n", .{});
    }
}

const LineSpan = struct {
    start: usize,
    end: usize,
};

fn lineSpan(source: []const u8, offset: u32) LineSpan {
    const target: usize = @min(@as(usize, @intCast(offset)), source.len);
    var start = target;
    while (start > 0 and source[start - 1] != '\n') {
        start -= 1;
    }

    var end = target;
    while (end < source.len and source[end] != '\n') {
        end += 1;
    }

    return .{ .start = start, .end = end };
}

fn writeSpaces(count: u32) void {
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        std.debug.print(" ", .{});
    }
}
