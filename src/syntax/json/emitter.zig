//! Deterministic nlohmann-style JSON rendering.

const std = @import("std");
const Value = @import("value.zig").Value;

pub fn write(writer: *std.Io.Writer, scratch: std.mem.Allocator, value: Value) !void {
    try emit(writer, scratch, value, 0);
}

fn emit(writer: *std.Io.Writer, scratch: std.mem.Allocator, value: Value, indent: usize) !void {
    switch (value) {
        .int => |v| try writer.print("{d}", .{v}),
        .float => |v| try emitFloat(writer, v),
        .str => |s| try emitString(writer, s),
        .boolean => |b| try writer.writeAll(if (b) "true" else "false"),
        .nul => try writer.writeAll("null"),
        .array => |items| {
            if (items.len == 0) return writer.writeAll("[]");
            try writer.writeAll("[\n");
            for (items, 0..) |item, i| {
                try indentBy(writer, indent + 2);
                try emit(writer, scratch, item, indent + 2);
                if (i + 1 != items.len) try writer.writeByte(',');
                try writer.writeByte('\n');
            }
            try indentBy(writer, indent);
            try writer.writeByte(']');
        },
        .object => |fields| {
            if (fields.len == 0) return writer.writeAll("{}");
            const sorted = try scratch.dupe(Value.Field, fields);
            std.mem.sort(Value.Field, sorted, {}, fieldLess);
            try writer.writeAll("{\n");
            for (sorted, 0..) |field, i| {
                try indentBy(writer, indent + 2);
                try emitString(writer, field.key);
                try writer.writeAll(": ");
                try emit(writer, scratch, field.val, indent + 2);
                if (i + 1 != sorted.len) try writer.writeByte(',');
                try writer.writeByte('\n');
            }
            try indentBy(writer, indent);
            try writer.writeByte('}');
        },
    }
}

fn fieldLess(_: void, a: Value.Field, b: Value.Field) bool {
    const a_type = std.mem.eql(u8, a.key, "_type");
    const b_type = std.mem.eql(u8, b.key, "_type");
    if (a_type != b_type) return a_type;
    return std.mem.lessThan(u8, a.key, b.key);
}

fn indentBy(writer: *std.Io.Writer, n: usize) !void {
    try writer.splatByteAll(' ', n);
}

fn emitFloat(writer: *std.Io.Writer, value: f64) !void {
    var buf: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{value}) catch {
        try writer.print("{d}", .{value});
        return;
    };
    try writer.writeAll(text);
    if (std.mem.indexOfAny(u8, text, ".eEnN") == null) try writer.writeAll(".0");
}

fn emitString(writer: *std.Io.Writer, string: []const u8) !void {
    try writer.writeByte('"');
    for (string) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x08 => try writer.writeAll("\\b"),
            0x0c => try writer.writeAll("\\f"),
            else => if (c < 0x20)
                try writer.print("\\u{x:0>4}", .{c})
            else
                try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}

test "objects of every width are sorted" {
    var key_storage: [26][1]u8 = undefined;
    var fields: [26]Value.Field = undefined;
    for (0..fields.len) |i| {
        key_storage[i][0] = 'z' - @as(u8, @intCast(i));
        fields[i] = .{ .key = key_storage[i][0..], .val = .nul };
    }

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try write(&writer, arena_state.allocator(), .{ .object = &fields });

    const output = writer.buffered();
    const a = std.mem.indexOf(u8, output, "\"a\"").?;
    const m = std.mem.indexOf(u8, output, "\"m\"").?;
    const z = std.mem.indexOf(u8, output, "\"z\"").?;
    try std.testing.expect(a < m);
    try std.testing.expect(m < z);
}
