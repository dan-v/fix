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
    explicit_outputs: bool,
    original_attrs: []const AttrEntry,
};

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
        .value = try drvPathString(allocator, intern, heap, spec.drv_path),
    });
    for (spec.outputs) |output| {
        try entries.append(allocator, .{
            .name = output.name,
            .value = try outputPathString(allocator, intern, heap, spec.drv_path, output),
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
        .value = try drvPathString(allocator, intern, heap, spec.drv_path),
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
        .value = try outputPathString(allocator, intern, heap, spec.drv_path, selected),
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
        value.* = try buildOutputReferenceValue(allocator, intern, heap, spec, output);
    }
    return values;
}

fn buildOutputReferenceValue(
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
            .name = try intern.intern("drvPath"),
            .value = try drvPathString(allocator, intern, heap, spec.drv_path),
        },
        .{
            .name = try intern.intern("outPath"),
            .value = try outputPathString(allocator, intern, heap, spec.drv_path, output),
        },
    };
    return Value.attrs(try heap.addAttrs(&entries));
}

pub fn storePath(
    allocator: std.mem.Allocator,
    intern: *InternTable,
    name: []const u8,
    output: []const u8,
    fingerprint: []const u8,
) !InternId {
    const hash = stableStoreHash(name, output, fingerprint);
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
    fingerprint: []const u8,
) !InternId {
    const hash = stableStoreHash(name, "drv", fingerprint);
    const text = try std.fmt.allocPrint(allocator, "/nix/store/{s}-{s}.drv", .{ hash, name });
    defer allocator.free(text);
    return intern.intern(text);
}

pub fn stableStoreHash(name: []const u8, output: []const u8, fingerprint: []const u8) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    updateHashPart(&hasher, "name", name);
    updateHashPart(&hasher, "output", output);
    updateHashPart(&hasher, "fingerprint", fingerprint);

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return nixBase32(compressDigest(&digest));
}

fn updateHashPart(hasher: anytype, tag: []const u8, bytes: []const u8) void {
    var len: [8]u8 = undefined;
    std.mem.writeInt(u64, &len, bytes.len, .little);
    hasher.update(tag);
    hasher.update(&.{0});
    hasher.update(&len);
    hasher.update(bytes);
    hasher.update(&.{0});
}

fn compressDigest(digest: []const u8) [20]u8 {
    var compressed = [_]u8{0} ** 20;
    for (digest, 0..) |byte, index| compressed[index % compressed.len] ^= byte;
    return compressed;
}

fn nixBase32(bytes: [20]u8) [32]u8 {
    const alphabet = "0123456789abcdfghijklmnpqrsvwxyz";
    var encoded: [32]u8 = undefined;
    for (0..encoded.len) |n| {
        const bit = n * 5;
        const byte_index = bit / 8;
        const bit_index: u3 = @intCast(bit % 8);
        var value: u16 = bytes[byte_index] >> bit_index;
        if (byte_index + 1 < bytes.len) {
            const next_shift: u4 = 8 - @as(u4, bit_index);
            value |= @as(u16, bytes[byte_index + 1]) << next_shift;
        }
        encoded[encoded.len - n - 1] = alphabet[@as(usize, value & 0x1f)];
    }
    return encoded;
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

test "stable store hash is nix-shaped and depends on name output and fingerprint" {
    const out_hash = stableStoreHash("pkg", "out", "a");
    const dev_hash = stableStoreHash("pkg", "dev", "a");
    const changed_hash = stableStoreHash("pkg", "out", "b");
    const repeat = stableStoreHash("pkg", "out", "a");

    try std.testing.expectEqualStrings(&out_hash, &repeat);
    try std.testing.expect(!std.mem.eql(u8, &out_hash, &dev_hash));
    try std.testing.expect(!std.mem.eql(u8, &out_hash, &changed_hash));
    for (out_hash) |char| {
        try std.testing.expect(std.mem.indexOfScalar(u8, "0123456789abcdfghijklmnpqrsvwxyz", char) != null);
    }
}
