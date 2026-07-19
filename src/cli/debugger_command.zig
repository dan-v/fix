//! Presentation-neutral debugger command parsing shared by the line console
//! and the interactive terminal UI.

const std = @import("std");

pub const Step = enum { over, into, out };

pub const Command = union(enum) {
    none,
    proceed,
    abort,
    step: Step,
    backtrace,
    locals,
    value,
    breakpoint: []const u8,
    breakpoints,
    delete: []const u8,
    help,
    eval: []const u8,
};

/// A bare line is an expression unless it is exactly a no-argument command.
/// A leading `:` forces command interpretation, matching the console's
/// historical ambiguity rules (`n + 1` evaluates; `n` steps).
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
        if (isWord(word, &.{ "help", "h", "?" })) return .help;
    }
    if (isWord(word, &.{"break"})) return .{ .breakpoint = rest };
    if (isWord(word, &.{"delete"})) return .{ .delete = rest };
    return .{ .eval = line };
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
    try std.testing.expect(parse("break file.nix:12") == .breakpoint);
}
