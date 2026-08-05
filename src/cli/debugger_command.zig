//! Shared debugger command parsing and execution helpers.
//!
//! The line console and terminal UI own their interaction and layout, but use
//! these helpers for value forcing and breakpoint semantics so the two surfaces
//! do not drift.

const std = @import("std");
const engine = @import("expr");
const runtime = @import("runtime");
const render = @import("render.zig");

const DebugSession = engine.DebugSession;

pub const Step = enum { over, into, out };

pub const Command = union(enum) {
    none,
    proceed,
    abort,
    step: Step,
    backtrace,
    locals,
    frame: []const u8,
    value,
    explore: []const u8,
    breakpoint: []const u8,
    breakpoints,
    delete: []const u8,
    gc,
    help,
    eval: []const u8,
};

/// A bare line is an expression unless it is exactly a no-argument command.
/// A leading `:` forces command interpretation (`n + 1` evaluates; `n` steps).
pub fn parse(line_raw: []const u8) Command {
    const line = std.mem.trim(u8, line_raw, " \t\r\n");
    if (line.len == 0) return .none;
    const explicit = line[0] == ':';
    const command_text = if (explicit) std.mem.trim(u8, line[1..], " \t") else line;
    if (command_text.len == 0) return .none;
    const word = firstWord(command_text);
    const rest = std.mem.trim(u8, command_text[word.len..], " \t");
    const bare = rest.len == 0;

    if (bare or explicit) {
        if (isWord(word, &.{ "c", "cont", "continue" })) return .proceed;
        if (isWord(word, &.{ "q", "quit", "abort" })) return .abort;
        if (isWord(word, &.{ "n", "next" })) return .{ .step = .over };
        if (isWord(word, &.{ "s", "step" })) return .{ .step = .into };
        if (isWord(word, &.{ "finish", "fin", "out" })) return .{ .step = .out };
        if (isWord(word, &.{ "bt", "backtrace", "where", "w" })) return .backtrace;
        if (isWord(word, &.{ "l", "locals" })) return .locals;
        if (isWord(word, &.{ "v", "value" })) return .value;
        if (isWord(word, &.{ "breakpoints", "info" })) return .breakpoints;
        if (isWord(word, &.{"gc"})) return .gc;
        if (isWord(word, &.{ "help", "h", "?" })) return .help;
    }
    if (explicit and isWord(word, &.{"frame"})) return .{ .frame = rest };
    if (explicit and isWord(word, &.{"vm"})) return .{ .explore = rest };
    if (isWord(word, &.{"break"})) return .{ .breakpoint = rest };
    if (isWord(word, &.{"delete"})) return .{ .delete = rest };
    return .{ .eval = line };
}

const BreakpointTarget = struct {
    file: []const u8,
    line: u32,
};

const BreakpointTargetError = error{
    MissingBreakpointFile,
    InvalidBreakpointLine,
};

fn parseBreakpointTarget(arg: []const u8) BreakpointTargetError!BreakpointTarget {
    const colon = std.mem.lastIndexOfScalar(u8, arg, ':') orelse return error.MissingBreakpointFile;
    const file = std.mem.trim(u8, arg[0..colon], " \t");
    if (file.len == 0) return error.MissingBreakpointFile;
    const line = std.fmt.parseInt(u32, std.mem.trim(u8, arg[colon + 1 ..], " \t"), 10) catch
        return error.InvalidBreakpointLine;
    return .{ .file = file, .line = line };
}

/// Render a debugger value consistently across the console and full-screen UI.
/// Only the immediate thunk is forced; nested lazy values remain inspectable.
pub fn writeValue(session: *DebugSession, writer: *std.Io.Writer, value: runtime.Value) !void {
    const shown = session.force(value) catch value;
    try session.writeValue(writer, shown);
}

pub fn addBreakpoint(session: *DebugSession, writer: *std.Io.Writer, arg: []const u8) !void {
    const target = parseBreakpointTarget(arg) catch |err| {
        return writer.writeAll(switch (err) {
            error.MissingBreakpointFile => "usage: break FILE:LINE",
            error.InvalidBreakpointLine => "usage: break FILE:LINE (LINE must be a number)",
        });
    };
    const result = session.setBreakpoint(target.file, target.line) catch |err| {
        return writer.print("error: {f}", .{render.friendly(err)});
    };
    try writer.print("breakpoint {d} {s}at {s}:{d}", .{
        result.id,
        if (result.pending) "pending " else "",
        target.file,
        result.line,
    });
    if (result.line != target.line)
        try writer.print(" (nearest code to line {d})", .{target.line});
    try writer.print(" — {d} site(s)", .{result.sites});
}

pub fn listBreakpoints(session: *const DebugSession, writer: *std.Io.Writer, prefix: []const u8) !void {
    const items = session.listBreakpoints();
    if (items.len == 0) return writer.writeAll("(no breakpoints)");
    for (items, 0..) |bp, i| {
        if (i != 0) try writer.writeByte('\n');
        try writer.writeAll(prefix);
        if (bp.span) |span| {
            try writer.print("{d}  chunk[0x{x}] L{d}:{d} (source span)", .{
                bp.id,
                bp.span_chunk.?,
                span.line,
                span.column,
            });
        } else if (bp.site_only) {
            try writer.print("{d}  (per-instruction site)", .{bp.id});
        } else {
            try writer.print("{d}  {s}:{d}{s}", .{
                bp.id,
                bp.file,
                bp.line,
                if (bp.pending) " (pending)" else "",
            });
        }
    }
}

pub fn deleteBreakpoint(session: *DebugSession, writer: *std.Io.Writer, arg: []const u8) !void {
    const id = std.fmt.parseInt(u32, std.mem.trim(u8, arg, " \t"), 10) catch
        return writer.writeAll("usage: delete N");
    if (session.deleteBreakpoint(id))
        try writer.print("deleted breakpoint {d}", .{id})
    else
        try writer.print("no breakpoint {d}", .{id});
}

pub fn collectGarbage(session: *DebugSession, writer: *std.Io.Writer) !void {
    const result = session.collectGarbage();
    if (!result.ran) {
        try writer.writeAll("gc: collector inactive");
    } else if (result.collections == 0) {
        try writer.print("gc: collector armed; heap capacity {d:.1} MiB retained for reuse", .{
            @as(f64, @floatFromInt(result.capacity_bytes)) / (1 << 20),
        });
    } else {
        try writer.print("gc: freed {d} object{s}; live {d:.1} MiB; heap capacity {d:.1} MiB retained for reuse", .{
            result.objects_freed,
            if (result.objects_freed == 1) "" else "s",
            @as(f64, @floatFromInt(result.live_bytes)) / (1 << 20),
            @as(f64, @floatFromInt(result.capacity_bytes)) / (1 << 20),
        });
    }
}

fn firstWord(s: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, s, " \t") orelse s.len;
    return s[0..end];
}

fn isWord(word: []const u8, aliases: []const []const u8) bool {
    for (aliases) |alias| if (std.mem.eql(u8, word, alias)) return true;
    return false;
}

test "debugger command ambiguity keeps expressions intact" {
    try std.testing.expect(parse("s") == .step);
    try std.testing.expectEqual(Step.into, parse("s").step);
    try std.testing.expect(parse("n + 1") == .eval);
    try std.testing.expectEqualStrings("n + 1", parse("n + 1").eval);
    try std.testing.expect(parse(":next") == .step);
    try std.testing.expectEqualStrings("2", parse(":frame 2").frame);
    try std.testing.expectEqualStrings("", parse(":frame").frame);
    try std.testing.expectEqualStrings("object 3", parse(":vm object 3").explore);
    try std.testing.expect(parse(":gc") == .gc);
    try std.testing.expectEqualStrings("frame", parse("frame").eval);
    try std.testing.expectEqualStrings("frame 2", parse("frame 2").eval);
    try std.testing.expect(parse("break file.nix:12") == .breakpoint);
}

test "breakpoint targets split at the final colon" {
    const target = try parseBreakpointTarget("path:with:colon.nix:42");
    try std.testing.expectEqualStrings("path:with:colon.nix", target.file);
    try std.testing.expectEqual(@as(u32, 42), target.line);
    try std.testing.expectError(error.MissingBreakpointFile, parseBreakpointTarget(":12"));
    try std.testing.expectError(error.InvalidBreakpointLine, parseBreakpointTarget("file.nix:nope"));
}
