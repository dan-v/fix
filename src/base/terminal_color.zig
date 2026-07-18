//! Small terminal-color primitives shared by diagnostic presentations.

const std = @import("std");

pub const Rgb = [3]u8;

pub const Depth = enum {
    none,
    ansi16,
    ansi256,
    truecolor,

    pub fn enabled(self: Depth) bool {
        return self != .none;
    }
};

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

pub fn foreground(writer: *std.Io.Writer, depth: Depth, rgb: Rgb, bold: bool) !void {
    if (!depth.enabled()) return;
    if (bold) try writer.writeAll("\x1b[1m");
    switch (depth) {
        .none => unreachable,
        .ansi16 => try writer.print("\x1b[{d}m", .{ansi16Code(rgb, false)}),
        .ansi256 => try writer.print("\x1b[38;5;{d}m", .{ansi256Index(rgb)}),
        .truecolor => try writer.print("\x1b[38;2;{d};{d};{d}m", .{ rgb[0], rgb[1], rgb[2] }),
    }
}

pub fn background(writer: *std.Io.Writer, depth: Depth, rgb: Rgb) !void {
    if (!depth.enabled()) return;
    switch (depth) {
        .none => unreachable,
        .ansi16 => try writer.print("\x1b[{d}m", .{ansi16Code(rgb, true)}),
        .ansi256 => try writer.print("\x1b[48;5;{d}m", .{ansi256Index(rgb)}),
        .truecolor => try writer.print("\x1b[48;2;{d};{d};{d}m", .{ rgb[0], rgb[1], rgb[2] }),
    }
}

pub fn ansi256Index(rgb: Rgb) u8 {
    const levels = [_]u8{ 0, 95, 135, 175, 215, 255 };
    var cube_index: [3]u8 = undefined;
    var cube_rgb: Rgb = undefined;
    for (rgb, 0..) |component, i| {
        cube_index[i] = nearestComponent(component, &levels);
        cube_rgb[i] = levels[cube_index[i]];
    }
    const cube_distance = distanceSquared(rgb, cube_rgb);

    var gray_index: u8 = 0;
    var gray_distance: u32 = std.math.maxInt(u32);
    for (0..24) |i| {
        const value: u8 = @intCast(8 + i * 10);
        const distance = distanceSquared(rgb, .{ value, value, value });
        if (distance < gray_distance) {
            gray_distance = distance;
            gray_index = @intCast(i);
        }
    }
    if (gray_distance < cube_distance) return 232 + gray_index;
    return 16 + 36 * cube_index[0] + 6 * cube_index[1] + cube_index[2];
}

pub fn ansi16Code(rgb: Rgb, background_color: bool) u8 {
    const palette = [_]Rgb{
        .{ 0, 0, 0 },       .{ 205, 0, 0 },   .{ 0, 205, 0 },   .{ 205, 205, 0 },
        .{ 0, 0, 238 },     .{ 205, 0, 205 }, .{ 0, 205, 205 }, .{ 229, 229, 229 },
        .{ 127, 127, 127 }, .{ 255, 0, 0 },   .{ 0, 255, 0 },   .{ 255, 255, 0 },
        .{ 92, 92, 255 },   .{ 255, 0, 255 }, .{ 0, 255, 255 }, .{ 255, 255, 255 },
    };
    var nearest: u8 = 0;
    var nearest_distance: u32 = std.math.maxInt(u32);
    for (palette, 0..) |candidate, i| {
        const distance = distanceSquared(rgb, candidate);
        if (distance < nearest_distance) {
            nearest_distance = distance;
            nearest = @intCast(i);
        }
    }
    const base: u8 = if (background_color) 40 else 30;
    return if (nearest < 8) base + nearest else base + 60 + (nearest - 8);
}

fn nearestComponent(value: u8, levels: []const u8) u8 {
    var nearest: u8 = 0;
    var nearest_distance: u16 = std.math.maxInt(u16);
    for (levels, 0..) |candidate, i| {
        const distance: u16 = if (value > candidate) value - candidate else candidate - value;
        if (distance < nearest_distance) {
            nearest_distance = distance;
            nearest = @intCast(i);
        }
    }
    return nearest;
}

fn distanceSquared(a: Rgb, b: Rgb) u32 {
    var total: u32 = 0;
    for (a, b) |lhs, rhs| {
        const delta: i32 = @as(i32, lhs) - @as(i32, rhs);
        total += @intCast(delta * delta);
    }
    return total;
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

test "RGB colors quantize to terminal palettes" {
    try std.testing.expectEqual(@as(u8, 196), ansi256Index(.{ 255, 0, 0 }));
    try std.testing.expectEqual(@as(u8, 46), ansi256Index(.{ 0, 255, 0 }));
    try std.testing.expectEqual(@as(u8, 244), ansi256Index(.{ 128, 128, 128 }));
    try std.testing.expectEqual(@as(u8, 91), ansi16Code(.{ 255, 0, 0 }, false));
    try std.testing.expectEqual(@as(u8, 101), ansi16Code(.{ 255, 0, 0 }, true));
}

test "foreground encoding follows color depth" {
    var buffer: [64]u8 = undefined;

    var ansi16 = std.Io.Writer.fixed(&buffer);
    try foreground(&ansi16, .ansi16, .{ 255, 0, 0 }, true);
    try std.testing.expectEqualStrings("\x1b[1m\x1b[91m", ansi16.buffered());

    var ansi256 = std.Io.Writer.fixed(&buffer);
    try foreground(&ansi256, .ansi256, .{ 255, 0, 0 }, false);
    try std.testing.expectEqualStrings("\x1b[38;5;196m", ansi256.buffered());

    var truecolor = std.Io.Writer.fixed(&buffer);
    try foreground(&truecolor, .truecolor, .{ 255, 0, 0 }, false);
    try std.testing.expectEqualStrings("\x1b[38;2;255;0;0m", truecolor.buffered());
}
