//! Derivation value construction.
//!
//! This module owns the evaluator-facing attr shape for derivations. It does
//! not force Nix values; callers normalize inputs and pass interned names.

const std = @import("std");
const InternTable = @import("intern.zig").InternTable;
const heap_mod = @import("heap.zig");
const ObjectHeap = heap_mod.ObjectHeap;
const AttrEntry = heap_mod.AttrEntry;
const Value = @import("value.zig").Value;
const InternId = @import("types.zig").InternId;

pub const Output = struct {
    name: InternId,
    out_path: InternId,
};

pub const Spec = struct {
    drv_path: InternId,
    default_output: InternId,
    outputs: []const Output,
    original_attrs: []const AttrEntry,
};

pub fn buildValue(
    allocator: std.mem.Allocator,
    intern: *InternTable,
    heap: *ObjectHeap,
    spec: Spec,
) !Value {
    var entries: std.ArrayListUnmanaged(AttrEntry) = .empty;
    defer entries.deinit(allocator);

    for (spec.original_attrs) |entry| {
        if (isSyntheticName(intern, intern.get(entry.name), spec.outputs)) continue;
        try entries.append(allocator, entry);
    }

    try entries.appendSlice(allocator, &.{
        .{
            .name = try intern.intern("type"),
            .value = Value.string(try intern.intern("derivation")),
        },
        .{
            .name = try intern.intern("outputName"),
            .value = Value.string(spec.default_output),
        },
        .{
            .name = try intern.intern("drvPath"),
            .value = try drvPathString(allocator, intern, heap, spec.drv_path),
        },
        .{
            .name = try intern.intern("outputs"),
            .value = Value.list(try outputNamesList(allocator, heap, spec.outputs)),
        },
    });

    const default = outputByName(spec.outputs, spec.default_output) orelse return error.InvalidDerivationOutput;
    try entries.append(allocator, .{
        .name = try intern.intern("outPath"),
        .value = try outputPathString(allocator, intern, heap, spec.drv_path, default),
    });

    const output_values = try allocator.alloc(Value, spec.outputs.len);
    defer allocator.free(output_values);
    for (spec.outputs, output_values) |output, *output_value| {
        output_value.* = try buildOutputValue(allocator, intern, heap, spec, output);
        try entries.append(allocator, .{
            .name = output.name,
            .value = output_value.*,
        });
    }
    try entries.append(allocator, .{
        .name = try intern.intern("all"),
        .value = Value.list(try heap.addList(output_values)),
    });

    return Value.attrs(try heap.addAttrs(entries.items));
}

pub fn storePath(
    allocator: std.mem.Allocator,
    intern: *InternTable,
    name: []const u8,
    output: []const u8,
) !InternId {
    const hash = stablePlaceholderHash(name, output);
    const text = if (std.mem.eql(u8, output, "out"))
        try std.fmt.allocPrint(allocator, "/nix/store/{s}-{s}", .{ hash, name })
    else
        try std.fmt.allocPrint(allocator, "/nix/store/{s}-{s}-{s}", .{ hash, name, output });
    defer allocator.free(text);
    return intern.intern(text);
}

pub fn drvPath(
    allocator: std.mem.Allocator,
    intern: *InternTable,
    name: []const u8,
) !InternId {
    const hash = stablePlaceholderHash(name, "drv");
    const text = try std.fmt.allocPrint(allocator, "/nix/store/{s}-{s}.drv", .{ hash, name });
    defer allocator.free(text);
    return intern.intern(text);
}

pub fn stablePlaceholderHash(name: []const u8, output: []const u8) [16]u8 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(name);
    hasher.update(&.{0});
    hasher.update(output);
    const digest = hasher.final();

    var encoded: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&encoded, "{x:0>16}", .{digest}) catch unreachable;
    return encoded;
}

pub fn isSyntheticName(intern: *InternTable, name: []const u8, outputs: []const Output) bool {
    const synthetic = [_][]const u8{ "type", "outputName", "outPath", "drvPath", "outputs", "all" };
    for (synthetic) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    for (outputs) |output| {
        if (std.mem.eql(u8, name, intern.get(output.name))) return true;
    }
    return false;
}

fn buildOutputValue(
    allocator: std.mem.Allocator,
    intern: *InternTable,
    heap: *ObjectHeap,
    spec: Spec,
    output: Output,
) !Value {
    const entries = [_]AttrEntry{
        .{
            .name = try intern.intern("type"),
            .value = Value.string(try intern.intern("derivation")),
        },
        .{
            .name = try intern.intern("outputName"),
            .value = Value.string(output.name),
        },
        .{
            .name = try intern.intern("outPath"),
            .value = try outputPathString(allocator, intern, heap, spec.drv_path, output),
        },
        .{
            .name = try intern.intern("drvPath"),
            .value = try drvPathString(allocator, intern, heap, spec.drv_path),
        },
    };
    return Value.attrs(try heap.addAttrs(&entries));
}

fn outputNamesList(
    allocator: std.mem.Allocator,
    heap: *ObjectHeap,
    outputs: []const Output,
) !@import("types.zig").ObjectId {
    const values = try allocator.alloc(Value, outputs.len);
    defer allocator.free(values);
    for (outputs, values) |output, *value| value.* = Value.string(output.name);
    return heap.addList(values);
}

fn drvPathString(
    allocator: std.mem.Allocator,
    intern: *InternTable,
    heap: *ObjectHeap,
    drv_path: InternId,
) !Value {
    const all_outputs = [_]AttrEntry{
        .{ .name = try intern.intern("allOutputs"), .value = Value.boolVal(true) },
    };
    const context_value = Value.attrs(try heap.addAttrs(&all_outputs));
    const context = [_]AttrEntry{
        .{ .name = drv_path, .value = context_value },
    };
    _ = allocator;
    return Value.contextString(try heap.addContextString(drv_path, &context));
}

fn outputPathString(
    allocator: std.mem.Allocator,
    intern: *InternTable,
    heap: *ObjectHeap,
    drv_path: InternId,
    output: Output,
) !Value {
    const output_values = [_]Value{Value.string(output.name)};
    const outputs = [_]AttrEntry{
        .{ .name = try intern.intern("outputs"), .value = Value.list(try heap.addList(&output_values)) },
    };
    const context_value = Value.attrs(try heap.addAttrs(&outputs));
    const context = [_]AttrEntry{
        .{ .name = drv_path, .value = context_value },
    };
    _ = allocator;
    return Value.contextString(try heap.addContextString(output.out_path, &context));
}

fn outputByName(outputs: []const Output, name: InternId) ?Output {
    for (outputs) |output| {
        if (output.name == name) return output;
    }
    return null;
}

test "stable placeholder hash depends on name and output" {
    const out_hash = stablePlaceholderHash("pkg", "out");
    const dev_hash = stablePlaceholderHash("pkg", "dev");
    const repeat = stablePlaceholderHash("pkg", "out");

    try std.testing.expectEqualStrings(&out_hash, &repeat);
    try std.testing.expect(!std.mem.eql(u8, &out_hash, &dev_hash));
}
