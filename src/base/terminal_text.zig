//! Helpers for treating external text as terminal-safe plain text.

const std = @import("std");

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
