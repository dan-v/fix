//! Small terminal-color primitives shared by diagnostic presentations.

const std = @import("std");

pub const Rgb = [3]u8;

/// A legible color for sequence position `seq`. Consecutive values land a
/// golden angle apart, keeping nearby identities visually distinct.
pub fn hueColor(seq: usize) Rgb {
    const hue: f32 = @floatCast(@mod(@as(f64, @floatFromInt(seq)) * 137.508, 360.0));
    return hsvToRgb(hue, 0.62, 0.99);
}

/// Give arbitrary text a deterministic color. The namespace separates color
/// identities belonging to different presentation roles.
pub fn stableColor(namespace: u64, text: []const u8) Rgb {
    const hash = std.hash.Wyhash.hash(namespace, text);
    return hueColor(@intCast(hash % 4096));
}

pub fn foreground(writer: *std.Io.Writer, use_color: bool, rgb: Rgb, bold: bool) !void {
    if (!use_color) return;
    if (bold) try writer.writeAll("\x1b[1m");
    try writer.print("\x1b[38;2;{d};{d};{d}m", .{ rgb[0], rgb[1], rgb[2] });
}

fn hsvToRgb(h: f32, s: f32, v: f32) Rgb {
    const c = v * s;
    const hp = h / 60.0;
    const x = c * (1.0 - @abs(@mod(hp, 2.0) - 1.0));
    var r: f32 = 0;
    var g: f32 = 0;
    var b: f32 = 0;
    if (hp < 1.0) {
        r = c;
        g = x;
    } else if (hp < 2.0) {
        r = x;
        g = c;
    } else if (hp < 3.0) {
        g = c;
        b = x;
    } else if (hp < 4.0) {
        g = x;
        b = c;
    } else if (hp < 5.0) {
        r = x;
        b = c;
    } else {
        r = c;
        b = x;
    }
    const m = v - c;
    return .{
        @intFromFloat(@round((r + m) * 255.0)),
        @intFromFloat(@round((g + m) * 255.0)),
        @intFromFloat(@round((b + m) * 255.0)),
    };
}

test "stable colors preserve identity and namespaces" {
    try std.testing.expectEqual(stableColor(1, "thing"), stableColor(1, "thing"));
    try std.testing.expect(!std.meta.eql(stableColor(1, "thing"), stableColor(2, "thing")));
}
