const std = @import("std");
const derivation = @import("derivation.zig");

pub const Mode = enum {
    off,
    summary,
    full,
};

pub const Options = struct {
    mode: Mode = .off,
    filter: ?[]const u8 = null,
    name: ?[]const u8 = null,
    drv_path: ?[]const u8 = null,

    pub fn enabled(self: Options) bool {
        return self.mode != .off;
    }
};

pub fn parseMode(text: []const u8) ?Mode {
    if (std.mem.eql(u8, text, "summary")) return .summary;
    if (std.mem.eql(u8, text, "full")) return .full;
    return null;
}

pub fn write(
    io: std.Io,
    use_color: bool,
    allocator: std.mem.Allocator,
    options: Options,
    records: []const derivation.DebugRecord,
) !void {
    if (!options.enabled()) return;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr = std.Io.File.stderr().writerStreaming(io, &stderr_buffer);
    const writer = &stderr.interface;

    var shown: usize = 0;
    for (records) |record| {
        if (matches(record, options)) shown += 1;
    }

    try style(writer, use_color, .heading);
    try writer.writeAll("derivation debug");
    try reset(writer, use_color);
    try writer.print(": {d} shown / {d} captured", .{ shown, records.len });
    try writeSelectors(writer, use_color, options);
    try writer.writeByte('\n');

    if (shown == 0) {
        try writer.flush();
        return;
    }

    var display_index: usize = 0;
    for (records) |record| {
        if (!matches(record, options)) continue;
        display_index += 1;
        try writeRecord(writer, use_color, allocator, options.mode, display_index, record);
    }
    try writer.flush();
}

fn writeSelectors(writer: *std.Io.Writer, use_color: bool, options: Options) !void {
    if (options.filter == null and options.name == null and options.drv_path == null) return;

    try style(writer, use_color, .dim);
    if (options.filter) |filter| try writer.print("  filter={s}", .{filter});
    if (options.name) |name| try writer.print("  name={s}", .{name});
    if (options.drv_path) |drv_path| try writer.print("  drv={s}", .{drv_path});
    try reset(writer, use_color);
}

fn matches(record: derivation.DebugRecord, options: Options) bool {
    if (options.name) |name| {
        if (!std.mem.eql(u8, record.name, name)) return false;
    }
    if (options.drv_path) |drv_path| {
        if (!std.mem.eql(u8, record.drv_path, drv_path)) return false;
    }
    return broadMatch(record, options.filter);
}

fn broadMatch(record: derivation.DebugRecord, filter: ?[]const u8) bool {
    const needle = filter orelse return true;
    if (std.mem.indexOf(u8, record.name, needle) != null) return true;
    if (std.mem.indexOf(u8, record.drv_path, needle) != null) return true;
    if (std.mem.indexOf(u8, record.builder, needle) != null) return true;
    for (record.outputs) |output| {
        if (std.mem.indexOf(u8, output.name, needle) != null) return true;
        if (std.mem.indexOf(u8, output.path, needle) != null) return true;
    }
    for (record.input_drvs) |input| {
        if (std.mem.indexOf(u8, input.path, needle) != null) return true;
    }
    for (record.input_srcs) |src| {
        if (std.mem.indexOf(u8, src, needle) != null) return true;
    }
    return false;
}

fn writeRecord(
    writer: *std.Io.Writer,
    use_color: bool,
    allocator: std.mem.Allocator,
    mode: Mode,
    index: usize,
    record: derivation.DebugRecord,
) !void {
    try writer.writeByte('\n');
    try style(writer, use_color, .dim);
    try writer.print("[{d}] ", .{index});
    try reset(writer, use_color);
    try style(writer, use_color, .name);
    try writer.writeAll(record.name);
    try reset(writer, use_color);
    try writer.writeByte('\n');

    try writeField(writer, use_color, "drvPath", record.drv_path, .path);
    try writeField(writer, use_color, "system", record.system, .plain);
    try writeField(writer, use_color, "builder", record.builder, .path);
    try writeHashField(writer, use_color, "outputHash", record.output_hash.hash_modulo);
    try writeHashField(writer, use_color, "dependencyHash", record.dependency_hash.hash_modulo);
    try writer.print("  inputs: {d} drv, {d} src    outputs: {d}    env: {d}\n", .{
        record.input_drvs.len,
        record.input_srcs.len,
        record.outputs.len,
        record.env.len,
    });

    if (mode == .summary) return;

    try writeOutputs(writer, use_color, allocator, record.outputs);
    try writeStringListSection(writer, use_color, allocator, "args", record.args);
    try writeInputDrvSection(writer, use_color, allocator, "input drvs", record.input_drvs);
    try writeStringListSection(writer, use_color, allocator, "input srcs", record.input_srcs);
    try writeEnvSection(writer, use_color, allocator, record.env);
    try writeHashModuloStep(writer, use_color, allocator, "output hash modulo", record.output_hash);
    try writeHashModuloStep(writer, use_color, allocator, "dependency hash modulo", record.dependency_hash);
    try writeStringListSection(writer, use_color, allocator, "drv text references", record.drv_text_references);
    try writeField(writer, use_color, "drvTextHash", record.drv_text_hash, .hash);
    try writeBlock(writer, use_color, "drv ATerm", record.drv_aterm);
}

const FieldKind = enum {
    plain,
    path,
    hash,
};

fn writeField(writer: *std.Io.Writer, use_color: bool, label: []const u8, value: []const u8, kind: FieldKind) !void {
    try writer.writeAll("  ");
    try style(writer, use_color, .label);
    try writer.print("{s}", .{label});
    try reset(writer, use_color);
    try writer.writeAll(": ");
    switch (kind) {
        .plain => {},
        .path => try style(writer, use_color, .path),
        .hash => try style(writer, use_color, .hash),
    }
    try writer.writeAll(value);
    if (kind != .plain) try reset(writer, use_color);
    try writer.writeByte('\n');
}

fn writeHashField(writer: *std.Io.Writer, use_color: bool, label: []const u8, hash_modulo: derivation.HashModulo) !void {
    try writer.writeAll("  ");
    try style(writer, use_color, .label);
    try writer.print("{s}", .{label});
    try reset(writer, use_color);
    try writer.writeAll(": ");
    try writeHashModulo(writer, use_color, hash_modulo);
    try writer.writeByte('\n');
}

fn writeHashModulo(writer: *std.Io.Writer, use_color: bool, hash_modulo: derivation.HashModulo) !void {
    switch (hash_modulo) {
        .drv => |hash| {
            try style(writer, use_color, .hash);
            try writer.writeAll(hash);
            try reset(writer, use_color);
        },
        .outputs => |outputs| {
            try writer.writeAll("outputs");
            for (outputs) |output| {
                try writer.writeAll(" ");
                try style(writer, use_color, .label);
                try writer.writeAll(output.output);
                try reset(writer, use_color);
                try writer.writeAll("=");
                try style(writer, use_color, .hash);
                try writer.writeAll(output.hash);
                try reset(writer, use_color);
            }
        },
    }
}

fn writeOutputs(
    writer: *std.Io.Writer,
    use_color: bool,
    allocator: std.mem.Allocator,
    outputs: []const derivation.DrvOutput,
) !void {
    try writeSection(writer, use_color, "outputs");
    if (outputs.len == 0) {
        try writeEmpty(writer, use_color);
        return;
    }

    const sorted = try allocator.dupe(derivation.DrvOutput, outputs);
    defer allocator.free(sorted);
    std.mem.sort(derivation.DrvOutput, sorted, {}, struct {
        fn lessThan(_: void, left: derivation.DrvOutput, right: derivation.DrvOutput) bool {
            return std.mem.lessThan(u8, left.name, right.name);
        }
    }.lessThan);

    for (sorted) |output| {
        try writer.writeAll("    ");
        try style(writer, use_color, .label);
        try writer.writeAll(output.name);
        try reset(writer, use_color);
        try writer.writeAll(" -> ");
        try style(writer, use_color, .path);
        try writer.writeAll(output.path);
        try reset(writer, use_color);
        if (output.hash_algo.len != 0 or output.hash.len != 0) {
            try writer.print("  hash {s}:{s}", .{ output.hash_algo, output.hash });
        }
        try writer.writeByte('\n');
    }
}

fn writeStringListSection(
    writer: *std.Io.Writer,
    use_color: bool,
    allocator: std.mem.Allocator,
    title: []const u8,
    values: []const []const u8,
) !void {
    try writeSection(writer, use_color, title);
    if (values.len == 0) {
        try writeEmpty(writer, use_color);
        return;
    }

    const sorted = try allocator.dupe([]const u8, values);
    defer allocator.free(sorted);
    std.mem.sort([]const u8, sorted, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.lessThan);

    for (sorted) |value| {
        try writer.writeAll("    ");
        try writeMaybePath(writer, use_color, value);
        try writer.writeByte('\n');
    }
}

fn writeInputDrvSection(
    writer: *std.Io.Writer,
    use_color: bool,
    allocator: std.mem.Allocator,
    title: []const u8,
    inputs: []const derivation.DrvInput,
) !void {
    try writeSection(writer, use_color, title);
    if (inputs.len == 0) {
        try writeEmpty(writer, use_color);
        return;
    }

    const sorted = try allocator.dupe(derivation.DrvInput, inputs);
    defer allocator.free(sorted);
    std.mem.sort(derivation.DrvInput, sorted, {}, struct {
        fn lessThan(_: void, left: derivation.DrvInput, right: derivation.DrvInput) bool {
            return std.mem.lessThan(u8, left.path, right.path);
        }
    }.lessThan);

    for (sorted) |input| {
        try writer.writeAll("    ");
        try writeMaybePath(writer, use_color, input.path);
        try writer.writeAll(" [");
        for (input.outputs, 0..) |output, output_index| {
            if (output_index != 0) try writer.writeAll(" ");
            try writer.writeAll(output);
        }
        try writer.writeAll("]\n");
    }
}

fn writeEnvSection(
    writer: *std.Io.Writer,
    use_color: bool,
    allocator: std.mem.Allocator,
    env: []const derivation.EnvVar,
) !void {
    try writeSection(writer, use_color, "env");
    if (env.len == 0) {
        try writeEmpty(writer, use_color);
        return;
    }

    const sorted = try allocator.dupe(derivation.EnvVar, env);
    defer allocator.free(sorted);
    std.mem.sort(derivation.EnvVar, sorted, {}, struct {
        fn lessThan(_: void, left: derivation.EnvVar, right: derivation.EnvVar) bool {
            return std.mem.lessThan(u8, left.name, right.name);
        }
    }.lessThan);

    for (sorted) |entry| {
        try writer.writeAll("    ");
        try style(writer, use_color, .label);
        try writer.writeAll(entry.name);
        try reset(writer, use_color);
        try writer.writeAll(" = ");
        try writeStringValue(writer, use_color, entry.value);
    }
}

fn writeHashModuloStep(
    writer: *std.Io.Writer,
    use_color: bool,
    allocator: std.mem.Allocator,
    title: []const u8,
    step: derivation.DebugHashModuloStep,
) !void {
    try writeSection(writer, use_color, title);
    try writer.writeAll("    hash: ");
    try writeHashModulo(writer, use_color, step.hash_modulo);
    try writer.writeByte('\n');

    try writeInputDrvSection(writer, use_color, allocator, "hash-modulo inputs", step.inputs);
    if (step.aterm) |aterm| {
        try writeBlock(writer, use_color, "hash-modulo ATerm", aterm);
    } else {
        try writer.writeAll("    ");
        try style(writer, use_color, .dim);
        try writer.writeAll("fixed-output derivation: no ATerm hash-modulo text\n");
        try reset(writer, use_color);
    }
}

fn writeBlock(writer: *std.Io.Writer, use_color: bool, title: []const u8, text: []const u8) !void {
    try writeSection(writer, use_color, title);
    if (text.len == 0) {
        try writeEmpty(writer, use_color);
        return;
    }
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        try writer.writeAll("    ");
        try writer.writeAll(line);
        try writer.writeByte('\n');
    }
}

fn writeStringValue(writer: *std.Io.Writer, use_color: bool, value: []const u8) !void {
    if (std.mem.indexOfScalar(u8, value, '\n') == null) {
        try writeMaybePath(writer, use_color, value);
        try writer.writeByte('\n');
        return;
    }

    try writer.writeAll("|\n");
    var lines = std.mem.splitScalar(u8, value, '\n');
    while (lines.next()) |line| {
        try writer.writeAll("      ");
        try writer.writeAll(line);
        try writer.writeByte('\n');
    }
}

fn writeMaybePath(writer: *std.Io.Writer, use_color: bool, value: []const u8) !void {
    const is_path = std.mem.startsWith(u8, value, "/nix/store/") or std.mem.endsWith(u8, value, ".drv");
    if (is_path) try style(writer, use_color, .path);
    try writer.writeAll(value);
    if (is_path) try reset(writer, use_color);
}

fn writeSection(writer: *std.Io.Writer, use_color: bool, title: []const u8) !void {
    try style(writer, use_color, .section);
    try writer.print("  {s}\n", .{title});
    try reset(writer, use_color);
}

fn writeEmpty(writer: *std.Io.Writer, use_color: bool) !void {
    try writer.writeAll("    ");
    try style(writer, use_color, .dim);
    try writer.writeAll("(none)\n");
    try reset(writer, use_color);
}

const Style = enum {
    heading,
    section,
    label,
    name,
    path,
    hash,
    dim,
};

fn style(writer: *std.Io.Writer, use_color: bool, value: Style) !void {
    if (!use_color) return;
    try writer.writeAll(switch (value) {
        .heading => "\x1b[1;35m",
        .section => "\x1b[1;36m",
        .label => "\x1b[36m",
        .name => "\x1b[1m",
        .path => "\x1b[32m",
        .hash => "\x1b[33m",
        .dim => "\x1b[2m",
    });
}

fn reset(writer: *std.Io.Writer, use_color: bool) !void {
    if (use_color) try writer.writeAll("\x1b[0m");
}
