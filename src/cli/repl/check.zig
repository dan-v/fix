//! Smart-enter: is this input a complete Nix expression, or the prefix of
//! one? Runs the real parser; a parse failure whose (first error) diagnostic
//! points at the end of input means "more is coming" (unbalanced brackets,
//! `let` without `in`, a trailing operator) — everything else is complete
//! enough to submit, so genuinely broken input surfaces its error instead of
//! trapping the user in continuation lines.

const std = @import("std");
const engine = @import("nix");

/// True when `source` should be submitted on Enter; false to continue on a
/// new line. Empty input is complete (the repl skips it).
pub fn isComplete(allocator: std.mem.Allocator, source: []const u8) bool {
    const trimmed = std.mem.trim(u8, source, " \t\r\n");
    if (trimmed.len == 0) return true;

    var arena = engine.ast.AstArena.init(allocator);
    defer arena.deinit();
    var parser = engine.parser.Parser.init(allocator, &arena, source);
    defer parser.deinit();

    _ = parser.parse() catch {
        for (parser.diagnostics.items) |diag| {
            if (diag.severity != .err) continue;
            // An error at (or spanning to) the end of input, or one whose
            // offending token is EOF, is an incomplete expression.
            if (diag.token_type) |tt| {
                if (tt == .eof) return false;
            }
            if (diag.offset >= source.len) return false;
            // Unterminated string/indented-string: the scanner reports the
            // error at the opening quote, but the input clearly continues.
            if (std.mem.indexOf(u8, diag.message, "unterminated") != null) return false;
            return true;
        }
        return true;
    };
    return true;
}

const testing = std.testing;

test "complete expressions submit" {
    try testing.expect(isComplete(testing.allocator, "1 + 2"));
    try testing.expect(isComplete(testing.allocator, "{ a = 1; }"));
    try testing.expect(isComplete(testing.allocator, "let x = 1; in x"));
    try testing.expect(isComplete(testing.allocator, "[ 1 2 3 ]"));
    try testing.expect(isComplete(testing.allocator, "\"done\""));
    try testing.expect(isComplete(testing.allocator, "x: x + 1"));
    try testing.expect(isComplete(testing.allocator, ""));
}

test "incomplete expressions continue" {
    try testing.expect(!isComplete(testing.allocator, "{ a = 1;"));
    try testing.expect(!isComplete(testing.allocator, "[ 1 2"));
    try testing.expect(!isComplete(testing.allocator, "(1 + "));
    try testing.expect(!isComplete(testing.allocator, "let x = 1;"));
    try testing.expect(!isComplete(testing.allocator, "1 +"));
    try testing.expect(!isComplete(testing.allocator, "if true then 1"));
    try testing.expect(!isComplete(testing.allocator, "with pkgs;"));
}

test "unterminated strings continue" {
    try testing.expect(!isComplete(testing.allocator, "\"abc"));
    try testing.expect(!isComplete(testing.allocator, "''\n  line one"));
}

test "broken-but-finished input submits (shows its error)" {
    // A stray closer isn't fixable by typing more.
    try testing.expect(isComplete(testing.allocator, "1 + 2 }"));
}
