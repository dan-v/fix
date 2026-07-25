//! Terminal display-width math for the repl's line editor.
//!
//! `cpWidth` is a pragmatic wcwidth: 0 for combining marks / zero-width
//! characters, 2 for East Asian wide/fullwidth and the common emoji planes,
//! 1 otherwise. Terminals themselves disagree at the margins (emoji ZWJ
//! sequences, ambiguous-width), so this aims to match what typical monospace
//! terminals render, not the full Unicode segmentation spec.

const std = @import("std");
const terminal_text = @import("base").terminal_text;

/// Display width of one codepoint: 0, 1, or 2 columns. Control characters
/// report 0 — the editor never lets them into the buffer (except '\n' and
/// '\t', which the renderer expands itself).
pub fn cpWidth(cp: u21) u2 {
    return terminal_text.cellWidth(cp);
}

/// Display width of a UTF-8 string. Invalid bytes count as width 1
/// (the renderer emits them verbatim; terminals show a replacement).
pub fn strWidth(text: []const u8) usize {
    var total: usize = 0;
    var it = Utf8Iterator{ .text = text };
    while (it.next()) |cp| total += cpWidth(cp.cp);
    return total;
}

/// Keep both ends of a long label visible, replacing its middle with one
/// ellipsis cell. The returned slice borrows `text` when it already fits and
/// otherwise belongs to `allocator`.
pub fn middleEllipsis(allocator: std.mem.Allocator, text: []const u8, max_cells: usize) ![]const u8 {
    if (strWidth(text) <= max_cells) return text;
    if (max_cells == 0) return "";
    if (max_cells == 1) return "…";

    const left_cells = (max_cells - 1) / 2;
    const right_cells = max_cells - 1 - left_cells;
    const left_end = prefixEnd(text, left_cells);
    const right_start = suffixStart(text, right_cells);
    return std.fmt.allocPrint(allocator, "{s}…{s}", .{ text[0..left_end], text[right_start..] });
}

/// Preserve the beginning of a value and replace the omitted tail with one
/// display-cell ellipsis. This is preferable to byte slicing for values such
/// as strings: it never splits UTF-8 and accounts for wide glyphs.
pub fn endEllipsis(allocator: std.mem.Allocator, text: []const u8, max_cells: usize) ![]const u8 {
    if (strWidth(text) <= max_cells) return text;
    if (max_cells == 0) return "";
    if (max_cells == 1) return "…";
    const end = prefixEnd(text, max_cells - 1);
    return std.fmt.allocPrint(allocator, "{s}…", .{text[0..end]});
}

fn prefixEnd(text: []const u8, cells: usize) usize {
    var used: usize = 0;
    var end: usize = 0;
    var it = Utf8Iterator{ .text = text };
    while (it.next()) |cp| {
        const width = cpWidth(cp.cp);
        if (used + width > cells) break;
        used += width;
        end = cp.offset + cp.len;
    }
    return end;
}

fn suffixStart(text: []const u8, cells: usize) usize {
    var used: usize = 0;
    var start = text.len;
    while (start > 0) {
        const previous = prevBoundary(text, start);
        const cp = std.unicode.utf8Decode(text[previous..start]) catch 0xFFFD;
        const width = cpWidth(cp);
        if (used + width > cells) break;
        used += width;
        start = previous;
    }
    return start;
}

pub const Cp = struct {
    cp: u21,
    /// Byte offset of this codepoint in the source text.
    offset: usize,
    /// Encoded byte length (1 for invalid bytes, consumed one at a time).
    len: usize,
};

/// Forgiving UTF-8 iterator: invalid sequences yield one `.cp = replacement`
/// per byte instead of failing, so cursor math never desyncs from the bytes.
pub const Utf8Iterator = struct {
    text: []const u8,
    i: usize = 0,

    pub fn next(self: *Utf8Iterator) ?Cp {
        if (self.i >= self.text.len) return null;
        const start = self.i;
        const b = self.text[start];
        const len = std.unicode.utf8ByteSequenceLength(b) catch {
            self.i += 1;
            return .{ .cp = 0xFFFD, .offset = start, .len = 1 };
        };
        if (start + len > self.text.len) {
            self.i += 1;
            return .{ .cp = 0xFFFD, .offset = start, .len = 1 };
        }
        const cp = std.unicode.utf8Decode(self.text[start .. start + len]) catch {
            self.i += 1;
            return .{ .cp = 0xFFFD, .offset = start, .len = 1 };
        };
        self.i = start + len;
        return .{ .cp = cp, .offset = start, .len = len };
    }
};

/// Byte offset of the previous codepoint boundary before `i` (0 at start).
pub fn prevBoundary(text: []const u8, i: usize) usize {
    if (i == 0) return 0;
    var j = i - 1;
    while (j > 0 and (text[j] & 0b1100_0000) == 0b1000_0000) j -= 1;
    return j;
}

/// Byte offset of the next codepoint boundary after `i` (`text.len` at end).
pub fn nextBoundary(text: []const u8, i: usize) usize {
    if (i >= text.len) return text.len;
    var j = i + 1;
    while (j < text.len and (text[j] & 0b1100_0000) == 0b1000_0000) j += 1;
    return j;
}

test "cpWidth: ascii, wide, combining" {
    try std.testing.expectEqual(@as(u2, 1), cpWidth('a'));
    try std.testing.expectEqual(@as(u2, 1), cpWidth('~'));
    try std.testing.expectEqual(@as(u2, 2), cpWidth(0x4E2D)); // 中
    try std.testing.expectEqual(@as(u2, 2), cpWidth(0x1F600)); // 😀
    try std.testing.expectEqual(@as(u2, 0), cpWidth(0x0301)); // combining acute
    try std.testing.expectEqual(@as(u2, 0), cpWidth(0x200B)); // zero-width space
}

test "strWidth mixes widths" {
    try std.testing.expectEqual(@as(usize, 3), strWidth("abc"));
    try std.testing.expectEqual(@as(usize, 4), strWidth("a中b")); // 1+2+1
    try std.testing.expectEqual(@as(usize, 2), strWidth("e\u{0301}x")); // e + combining + x
}

test "middle ellipsis preserves both ends at display width" {
    const shortened = try middleEllipsis(std.testing.allocator, "abcdefghij", 7);
    defer std.testing.allocator.free(shortened);
    try std.testing.expectEqualStrings("abc…hij", shortened);
    try std.testing.expectEqual(@as(usize, 7), strWidth(shortened));
}

test "end ellipsis is display-width aware and preserves utf8" {
    const shortened = try endEllipsis(std.testing.allocator, "ab中def", 5);
    defer std.testing.allocator.free(shortened);
    try std.testing.expectEqualStrings("ab中…", shortened);
    try std.testing.expectEqual(@as(usize, 5), strWidth(shortened));
}

test "boundaries walk codepoints, not bytes" {
    const s = "a中b"; // 1 + 3 + 1 bytes
    try std.testing.expectEqual(@as(usize, 1), nextBoundary(s, 0));
    try std.testing.expectEqual(@as(usize, 4), nextBoundary(s, 1));
    try std.testing.expectEqual(@as(usize, 5), nextBoundary(s, 4));
    try std.testing.expectEqual(@as(usize, 4), prevBoundary(s, 5));
    try std.testing.expectEqual(@as(usize, 1), prevBoundary(s, 4));
    try std.testing.expectEqual(@as(usize, 0), prevBoundary(s, 1));
}

test "utf8 iterator is forgiving on invalid bytes" {
    var it = Utf8Iterator{ .text = "a\xffb" };
    try std.testing.expectEqual(@as(u21, 'a'), it.next().?.cp);
    try std.testing.expectEqual(@as(u21, 0xFFFD), it.next().?.cp);
    try std.testing.expectEqual(@as(u21, 'b'), it.next().?.cp);
    try std.testing.expect(it.next() == null);
}
