const std = @import("std");
const sort = @import("sort.zig");
const types = @import("types.zig");

const DrvInput = types.DrvInput;

pub fn toATerm(drv: anytype, allocator: std.mem.Allocator, mask_outputs: bool, actual_inputs: ?[]const DrvInput) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    // Pre-size from the dominant content (env values + input paths) so the
    // build doesn't repeatedly realloc-and-copy a growing buffer.
    var estimate: usize = 256;
    for (drv.env) |e| estimate += e.name.len + e.value.len + 8;
    const est_inputs = actual_inputs orelse drv.input_drvs;
    for (est_inputs) |i| estimate += i.path.len + 16;
    try out.ensureTotalCapacity(allocator, estimate);

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
    // Bulk-copy maximal runs with no escape-needing char, then emit the
    // one escape, instead of appending byte-by-byte (each with its own
    // capacity check). Derivation env values (build scripts, dependency
    // lists) are large and almost entirely escape-free, so this is one
    // `appendSlice` per value in the common case rather than N appends —
    // and this runs on the w=32 critical path (drv ATerm hashing).
    var start: usize = 0;
    for (string, 0..) |char, i| {
        const esc: ?[]const u8 = switch (char) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            else => null,
        };
        if (esc) |e| {
            if (i > start) try out.appendSlice(allocator, string[start..i]);
            try out.appendSlice(allocator, e);
            start = i + 1;
        }
    }
    if (start < string.len) try out.appendSlice(allocator, string[start..]);
    try out.append(allocator, '"');
}

fn appendUnquotedString(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), string: []const u8) !void {
    try out.append(allocator, '"');
    try out.appendSlice(allocator, string);
    try out.append(allocator, '"');
}
