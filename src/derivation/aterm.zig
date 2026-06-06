const std = @import("std");
const sort = @import("sort.zig");
const types = @import("types.zig");

const DrvInput = types.DrvInput;

pub fn toATerm(drv: anytype, allocator: std.mem.Allocator, mask_outputs: bool, actual_inputs: ?[]const DrvInput) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "Derive([");
    const sorted_outputs = try sort.sortedOutputs(allocator, drv.outputs);
    defer allocator.free(sorted_outputs);
    for (sorted_outputs, 0..) |output, index| {
        if (index != 0) try out.append(allocator, ',');
        try out.append(allocator, '(');
        try appendUnquotedString(allocator, &out, output.name);
        try out.append(allocator, ',');
        try appendUnquotedString(allocator, &out, if (mask_outputs) "" else output.path);
        try out.append(allocator, ',');
        try appendUnquotedString(allocator, &out, output.hash_algo);
        try out.append(allocator, ',');
        try appendUnquotedString(allocator, &out, output.hash);
        try out.append(allocator, ')');
    }
    try out.appendSlice(allocator, "],[");
    const inputs = actual_inputs orelse drv.input_drvs;
    const sorted_inputs = try sort.sortedInputs(allocator, inputs);
    defer allocator.free(sorted_inputs);
    for (sorted_inputs, 0..) |input, index| {
        if (index != 0) try out.append(allocator, ',');
        try out.append(allocator, '(');
        try appendUnquotedString(allocator, &out, input.path);
        try out.append(allocator, ',');
        const sorted_names = try sort.sortedStrings(allocator, input.outputs);
        defer allocator.free(sorted_names);
        try appendUnquotedStringList(allocator, &out, sorted_names);
        try out.append(allocator, ')');
    }
    try out.appendSlice(allocator, "],");
    const sorted_srcs = try sort.sortedStrings(allocator, drv.input_srcs);
    defer allocator.free(sorted_srcs);
    try appendUnquotedStringList(allocator, &out, sorted_srcs);
    try out.append(allocator, ',');
    try appendUnquotedString(allocator, &out, drv.system);
    try out.append(allocator, ',');
    try appendString(allocator, &out, drv.builder);
    try out.append(allocator, ',');
    try appendStringList(allocator, &out, drv.args);
    try out.appendSlice(allocator, ",[");
    const sorted_env = try sort.sortedEnv(allocator, drv.env);
    defer allocator.free(sorted_env);
    for (sorted_env, 0..) |env, index| {
        if (index != 0) try out.append(allocator, ',');
        try out.append(allocator, '(');
        try appendString(allocator, &out, env.name);
        try out.append(allocator, ',');
        const value = if (mask_outputs and hasOutput(drv.outputs, env.name)) "" else env.value;
        try appendString(allocator, &out, value);
        try out.append(allocator, ')');
    }
    try out.appendSlice(allocator, "])");
    return out.toOwnedSlice(allocator);
}

fn hasOutput(outputs: anytype, name: []const u8) bool {
    for (outputs) |output| {
        if (std.mem.eql(u8, output.name, name)) return true;
    }
    return false;
}

fn appendStringList(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), strings: []const []const u8) !void {
    try out.append(allocator, '[');
    for (strings, 0..) |string, index| {
        if (index != 0) try out.append(allocator, ',');
        try appendString(allocator, out, string);
    }
    try out.append(allocator, ']');
}

fn appendUnquotedStringList(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), strings: []const []const u8) !void {
    try out.append(allocator, '[');
    for (strings, 0..) |string, index| {
        if (index != 0) try out.append(allocator, ',');
        try appendUnquotedString(allocator, out, string);
    }
    try out.append(allocator, ']');
}

fn appendString(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), string: []const u8) !void {
    try out.append(allocator, '"');
    for (string) |char| {
        switch (char) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, char),
        }
    }
    try out.append(allocator, '"');
}

fn appendUnquotedString(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), string: []const u8) !void {
    try out.append(allocator, '"');
    try out.appendSlice(allocator, string);
    try out.append(allocator, '"');
}
