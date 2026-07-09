//! Builds the runtime attrset Value that `derivation` returns: the derivation
//! attrs (type, drvPath, outputName, outPath, per-output sub-attrs, `all`) with
//! string context wiring drvPath/outPath back to the .drv and its outputs.

const std = @import("std");
const heap_mod = @import("runtime").heap;
const InternTable = @import("runtime").intern.InternTable;
const Value = @import("runtime").value.Value;
const types = @import("types.zig");

const AttrEntry = heap_mod.AttrEntry;
const ObjectHeap = heap_mod.ObjectHeap;
const InternId = @import("runtime").types.InternId;
const Output = types.Output;
const Spec = types.Spec;

pub fn buildValue(
    allocator: std.mem.Allocator,
    intern: *InternTable,
    heap: *ObjectHeap,
    spec: Spec,
) !Value {
    const output_values = try allocator.alloc(Value, spec.outputs.len);
    defer allocator.free(output_values);
    for (spec.outputs, output_values) |output, *output_value| {
        output_value.* = try buildSelectedValue(allocator, intern, heap, spec, output, null);
    }

    const default = outputByName(spec.outputs, spec.default_output) orelse return error.InvalidDerivationOutput;
    return buildSelectedValue(allocator, intern, heap, spec, default, output_values);
}

pub fn buildStrictValue(
    allocator: std.mem.Allocator,
    intern: *InternTable,
    heap: *ObjectHeap,
    spec: Spec,
) !Value {
    var entries: std.ArrayListUnmanaged(AttrEntry) = .empty;
    defer entries.deinit(allocator);

    try entries.append(allocator, .{
        .name = try intern.intern("drvPath"),
        .value = try drvPathString(intern, heap, spec.drv_path),
    });
    for (spec.outputs) |output| {
        try entries.append(allocator, .{
            .name = output.name,
            .value = try outputPathString(intern, heap, spec.drv_path, output),
        });
    }

    return Value.attrs(try heap.addAttrs(entries.items));
}

fn buildSelectedValue(
    allocator: std.mem.Allocator,
    intern: *InternTable,
    heap: *ObjectHeap,
    spec: Spec,
    selected: Output,
    output_values: ?[]const Value,
) !Value {
    var entries: std.ArrayListUnmanaged(AttrEntry) = .empty;
    defer entries.deinit(allocator);

    for (spec.original_attrs) |entry| {
        if (isSyntheticName(intern, intern.get(entry.name), spec.outputs)) continue;
        try entries.append(allocator, entry);
    }

    try entries.append(allocator, .{
        .name = try intern.intern("type"),
        .value = Value.string(try intern.intern("derivation")),
    });
    try entries.append(allocator, .{
        .name = try intern.intern("outputName"),
        .value = Value.string(selected.name),
    });
    try entries.append(allocator, .{
        .name = try intern.intern("drvPath"),
        .value = try drvPathString(intern, heap, spec.drv_path),
    });
    if (spec.explicit_outputs) {
        try entries.append(allocator, .{
            .name = try intern.intern("outputs"),
            .value = Value.list(try outputNamesList(allocator, heap, spec.outputs)),
        });
    }
    try entries.append(allocator, .{
        .name = try intern.intern("drvAttrs"),
        .value = Value.attrs(try heap.addAttrs(spec.original_attrs)),
    });

    try entries.append(allocator, .{
        .name = try intern.intern("outPath"),
        .value = try outputPathString(intern, heap, spec.drv_path, selected),
    });

    const nested_output_values = if (output_values) |values|
        values
    else
        try outputReferenceValues(allocator, intern, heap, spec);
    defer if (output_values == null) allocator.free(nested_output_values);

    for (spec.outputs, nested_output_values) |output, output_value| {
        try entries.append(allocator, .{
            .name = output.name,
            .value = output_value,
        });
    }
    try entries.append(allocator, .{
        .name = try intern.intern("all"),
        .value = Value.list(try heap.addList(nested_output_values)),
    });

    return Value.attrs(try heap.addAttrs(entries.items));
}

fn outputReferenceValues(
    allocator: std.mem.Allocator,
    intern: *InternTable,
    heap: *ObjectHeap,
    spec: Spec,
) ![]Value {
    const values = try allocator.alloc(Value, spec.outputs.len);
    errdefer allocator.free(values);
    for (spec.outputs, values) |output, *value| {
        value.* = try buildOutputReferenceValue(intern, heap, spec, output);
    }
    return values;
}

fn buildOutputReferenceValue(
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
            .name = try intern.intern("drvPath"),
            .value = try drvPathString(intern, heap, spec.drv_path),
        },
        .{
            .name = try intern.intern("outPath"),
            .value = try outputPathString(intern, heap, spec.drv_path, output),
        },
    };
    return Value.attrs(try heap.addAttrs(&entries));
}

pub fn isSyntheticName(intern: *InternTable, name: []const u8, outputs: []const Output) bool {
    const synthetic = [_][]const u8{ "type", "outputName", "outPath", "drvPath", "drvAttrs", "outputs", "all" };
    for (synthetic) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    for (outputs) |output| {
        if (std.mem.eql(u8, name, intern.get(output.name))) return true;
    }
    return false;
}

fn outputNamesList(
    allocator: std.mem.Allocator,
    heap: *ObjectHeap,
    outputs: []const Output,
) !heap_mod.ObjectId {
    const values = try allocator.alloc(Value, outputs.len);
    defer allocator.free(values);
    for (outputs, values) |output, *value| value.* = Value.string(output.name);
    return heap.addList(values);
}

fn drvPathString(
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
    return Value.contextString(try heap.addContextString(drv_path, &context));
}

fn outputPathString(
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
    return Value.contextString(try heap.addContextString(output.out_path, &context));
}

fn outputByName(outputs: []const Output, name: InternId) ?Output {
    for (outputs) |output| {
        if (output.name == name) return output;
    }
    return null;
}
