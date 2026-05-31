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
    name: []const u8,
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
            .value = Value.path(spec.drv_path),
        },
        .{
            .name = try intern.intern("outputs"),
            .value = Value.list(try outputNamesList(allocator, heap, spec.outputs)),
        },
    });

    const default = outputByName(spec.outputs, spec.default_output) orelse return error.InvalidDerivationOutput;
    try entries.append(allocator, .{
        .name = try intern.intern("outPath"),
        .value = Value.path(default.out_path),
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
    const text = if (std.mem.eql(u8, output, "out"))
        try std.fmt.allocPrint(allocator, "/nix/store/fix-{s}", .{name})
    else
        try std.fmt.allocPrint(allocator, "/nix/store/fix-{s}-{s}", .{ name, output });
    defer allocator.free(text);
    return intern.intern(text);
}

pub fn drvPath(
    allocator: std.mem.Allocator,
    intern: *InternTable,
    name: []const u8,
) !InternId {
    const text = try std.fmt.allocPrint(allocator, "/nix/store/fix-{s}.drv", .{name});
    defer allocator.free(text);
    return intern.intern(text);
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
    _ = allocator;
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
            .value = Value.path(output.out_path),
        },
        .{
            .name = try intern.intern("drvPath"),
            .value = Value.path(spec.drv_path),
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

fn outputByName(outputs: []const Output, name: InternId) ?Output {
    for (outputs) |output| {
        if (output.name == name) return output;
    }
    return null;
}
