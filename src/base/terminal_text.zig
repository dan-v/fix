//! Helpers for treating external text as terminal-safe plain text.

const std = @import("std");

const CellRange = struct { lo: u21, hi: u21 };

const zero_width = [_]CellRange{
    .{ .lo = 0x0300, .hi = 0x036F }, .{ .lo = 0x0483, .hi = 0x0489 },
    .{ .lo = 0x0591, .hi = 0x05BD }, .{ .lo = 0x05BF, .hi = 0x05BF },
    .{ .lo = 0x0610, .hi = 0x061A }, .{ .lo = 0x064B, .hi = 0x065F },
    .{ .lo = 0x0670, .hi = 0x0670 }, .{ .lo = 0x06D6, .hi = 0x06DC },
    .{ .lo = 0x0711, .hi = 0x0711 }, .{ .lo = 0x0730, .hi = 0x074A },
    .{ .lo = 0x0E31, .hi = 0x0E31 }, .{ .lo = 0x0E34, .hi = 0x0E3A },
    .{ .lo = 0x0E47, .hi = 0x0E4E }, .{ .lo = 0x135D, .hi = 0x135F },
    .{ .lo = 0x1AB0, .hi = 0x1AFF }, .{ .lo = 0x1DC0, .hi = 0x1DFF },
    .{ .lo = 0x200B, .hi = 0x200F }, .{ .lo = 0x202A, .hi = 0x202E },
    .{ .lo = 0x20D0, .hi = 0x20FF }, .{ .lo = 0xFE00, .hi = 0xFE0F },
    .{ .lo = 0xFE20, .hi = 0xFE2F }, .{ .lo = 0xFEFF, .hi = 0xFEFF },
};

const double_width = [_]CellRange{
    .{ .lo = 0x1100, .hi = 0x115F },   .{ .lo = 0x2329, .hi = 0x232A },
    .{ .lo = 0x2E80, .hi = 0x303E },   .{ .lo = 0x3041, .hi = 0x33FF },
    .{ .lo = 0x3400, .hi = 0x4DBF },   .{ .lo = 0x4E00, .hi = 0x9FFF },
    .{ .lo = 0xA000, .hi = 0xA4CF },   .{ .lo = 0xAC00, .hi = 0xD7A3 },
    .{ .lo = 0xF900, .hi = 0xFAFF },   .{ .lo = 0xFE30, .hi = 0xFE4F },
    .{ .lo = 0xFF00, .hi = 0xFF60 },   .{ .lo = 0xFFE0, .hi = 0xFFE6 },
    .{ .lo = 0x1F300, .hi = 0x1F64F }, .{ .lo = 0x1F680, .hi = 0x1F6FF },
    .{ .lo = 0x1F900, .hi = 0x1F9FF }, .{ .lo = 0x1FA70, .hi = 0x1FAFF },
    .{ .lo = 0x20000, .hi = 0x2FFFD }, .{ .lo = 0x30000, .hi = 0x3FFFD },
};

fn inCellRanges(cp: u21, ranges: []const CellRange) bool {
    for (ranges) |range| if (cp >= range.lo and cp <= range.hi) return true;
    return false;
}

/// Shared pragmatic wcwidth used by every terminal surface.
pub fn cellWidth(cp: u21) u2 {
    if (cp < 0x20 or cp == 0x7F) return 0;
    if (cp < 0x0300) return 1;
    if (inCellRanges(cp, &zero_width)) return 0;
    if (inCellRanges(cp, &double_width)) return 2;
    return 1;
}

/// Remove ANSI escape sequences in place and return the compacted prefix.
/// Handles CSI (including SGR), OSC hyperlinks/titles, DCS/SOS/PM/APC strings,
/// and ordinary two-byte/intermediate escape sequences. An incomplete sequence
/// at the end is discarded rather than allowed to affect later terminal output.
pub fn stripAnsiInPlace(text: []u8) []u8 {
    var read: usize = 0;
    var write: usize = 0;
    while (read < text.len) {
        if (text[read] == 0x1b) {
            read = skipEscape(text, read);
            continue;
        }
        // Preserve the two controls useful in plain log records. Other C0
        // controls can rewrite terminal state or previously rendered text.
        // Bytes >= 0x80 are left alone because they may be UTF-8 continuation
        // bytes rather than legacy single-byte C1 controls.
        if ((text[read] < 0x20 and text[read] != '\n' and text[read] != '\t') or
            text[read] == 0x7f)
        {
            read += 1;
            continue;
        }
        text[write] = text[read];
        write += 1;
        read += 1;
    }
    return text[0..write];
}

pub fn stripAnsiAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const copy = try allocator.dupe(u8, text);
    errdefer allocator.free(copy);
    const clean_len = stripAnsiInPlace(copy).len;
    return allocator.realloc(copy, clean_len);
}

fn skipEscape(text: []const u8, esc: usize) usize {
    var i = esc + 1;
    if (i >= text.len) return text.len;
    return switch (text[i]) {
        '[' => skipCsi(text, i + 1),
        ']', 'P', 'X', '^', '_' => skipString(text, i + 1),
        else => blk: {
            // ISO/IEC 2022: zero or more intermediate bytes, then one final.
            while (i < text.len and text[i] >= 0x20 and text[i] <= 0x2f) : (i += 1) {}
            break :blk @min(i + 1, text.len);
        },
    };
}

fn skipCsi(text: []const u8, start: usize) usize {
    var i = start;
    while (i < text.len) : (i += 1) {
        if (text[i] >= 0x40 and text[i] <= 0x7e) return i + 1;
    }
    return text.len;
}

fn skipString(text: []const u8, start: usize) usize {
    var i = start;
    while (i < text.len) : (i += 1) {
        if (text[i] == 0x07) return i + 1; // BEL terminator (OSC)
        if (text[i] == 0x1b and i + 1 < text.len and text[i + 1] == '\\') return i + 2; // ST
    }
    return text.len;
}

test "strip ANSI terminal sequences" {
    var sgr = [_]u8{ 'a', 0x1b, '[', '3', '1', 'm', 'b', 0x1b, '[', '0', 'm', 'c' };
    try std.testing.expectEqualStrings("abc", stripAnsiInPlace(&sgr));

    var osc = [_]u8{ 0x1b, ']', '8', ';', ';', 'u', 'r', 'l', 0x1b, '\\', 'x', 0x1b, ']', '8', ';', ';', 0x07 };
    try std.testing.expectEqualStrings("x", stripAnsiInPlace(&osc));

    var charset = [_]u8{ 'a', 0x1b, '(', 'B', 'b' };
    try std.testing.expectEqualStrings("ab", stripAnsiInPlace(&charset));

    var incomplete = [_]u8{ 'a', 0x1b, '[', '3', '1' };
    try std.testing.expectEqualStrings("a", stripAnsiInPlace(&incomplete));

    var lines = [_]u8{ 'a', '\n', '\t', 'b' };
    try std.testing.expectEqualStrings("a\n\tb", stripAnsiInPlace(&lines));

    var controls = [_]u8{ 'a', '\r', 'b', 0x7f, 'c' };
    try std.testing.expectEqualStrings("abc", stripAnsiInPlace(&controls));

    var utf8 = [_]u8{ 0xc3, 0x9c };
    try std.testing.expectEqualStrings("Ü", stripAnsiInPlace(&utf8));
}

test "shared terminal cell width handles wide and combining codepoints" {
    try std.testing.expectEqual(@as(u2, 2), cellWidth(0x4E2D));
    try std.testing.expectEqual(@as(u2, 0), cellWidth(0x0301));
}
