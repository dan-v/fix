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

pub const DrvOutput = struct {
    name: []const u8,
    path: []const u8 = "",
    hash_algo: []const u8 = "",
    hash: []const u8 = "",
};

pub const DrvInput = struct {
    path: []const u8,
    outputs: []const []const u8,
};

pub const OutputHash = struct {
    output: []const u8,
    hash: []const u8,
};

pub const HashModulo = union(enum) {
    drv: []u8,
    outputs: []OutputHash,

    pub fn deinit(self: HashModulo, allocator: std.mem.Allocator) void {
        switch (self) {
            .drv => |hash| allocator.free(hash),
            .outputs => |outputs| {
                for (outputs) |output| {
                    allocator.free(output.output);
                    allocator.free(output.hash);
                }
                allocator.free(outputs);
            },
        }
    }

    pub fn view(self: *const HashModulo) HashModuloView {
        return switch (self.*) {
            .drv => |hash| .{ .drv = hash },
            .outputs => |outputs| .{ .outputs = outputs },
        };
    }
};

pub const HashModuloView = union(enum) {
    drv: []const u8,
    outputs: []const OutputHash,
};

pub const DebugHashModuloStep = struct {
    mask_outputs: bool,
    inputs: []DrvInput,
    aterm: ?[]u8,
    hash_modulo: HashModulo,

    pub fn deinit(self: DebugHashModuloStep, allocator: std.mem.Allocator) void {
        freeDrvInputsDeep(allocator, self.inputs);
        if (self.aterm) |aterm| allocator.free(aterm);
        self.hash_modulo.deinit(allocator);
    }
};

pub const DebugRecord = struct {
    name: []u8,
    drv_path: []u8,
    system: []u8,
    builder: []u8,
    args: []const []const u8,
    outputs: []DrvOutput,
    input_drvs: []DrvInput,
    input_srcs: []const []const u8,
    env: []EnvVar,
    drv_aterm: []u8,
    drv_text_hash: []u8,
    drv_text_references: []const []const u8,
    output_hash: DebugHashModuloStep,
    dependency_hash: DebugHashModuloStep,

    pub fn deinit(self: DebugRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.drv_path);
        allocator.free(self.system);
        allocator.free(self.builder);
        freeStringListDeep(allocator, self.args);
        freeDrvOutputsDeep(allocator, self.outputs);
        freeDrvInputsDeep(allocator, self.input_drvs);
        freeStringListDeep(allocator, self.input_srcs);
        freeEnvVarsDeep(allocator, self.env);
        allocator.free(self.drv_aterm);
        allocator.free(self.drv_text_hash);
        freeStringListDeep(allocator, self.drv_text_references);
        self.output_hash.deinit(allocator);
        self.dependency_hash.deinit(allocator);
    }
};

pub const HashModuloResolver = struct {
    store_dir: []const u8,
    context: *anyopaque,
    resolve: *const fn (*anyopaque, []const u8) anyerror!?HashModuloView,

    pub fn resolvePath(self: HashModuloResolver, drv_path: []const u8) !?HashModuloView {
        return self.resolve(self.context, drv_path);
    }
};

pub const DerivationStore = struct {
    allocator: std.mem.Allocator,
    store_dir: []const u8 = "/nix/store",
    records: std.StringHashMapUnmanaged(Record) = .empty,
    debug_enabled: bool = false,
    debug_records: std.ArrayListUnmanaged(DebugRecord) = .empty,

    const Record = struct {
        hash_modulo: HashModulo,
        outputs: []const []const u8,

        fn deinit(self: Record, allocator: std.mem.Allocator) void {
            self.hash_modulo.deinit(allocator);
            for (self.outputs) |output| allocator.free(output);
            allocator.free(self.outputs);
        }
    };

    pub fn init(allocator: std.mem.Allocator) DerivationStore {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *DerivationStore) void {
        self.clearDebugRecords();
        self.debug_records.deinit(self.allocator);
        var it = self.records.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.records.deinit(self.allocator);
    }

    pub fn setDebugEnabled(self: *DerivationStore, enabled: bool) void {
        self.debug_enabled = enabled;
        if (!enabled) self.clearDebugRecords();
    }

    pub fn clearDebugRecords(self: *DerivationStore) void {
        for (self.debug_records.items) |debug_record| debug_record.deinit(self.allocator);
        self.debug_records.clearRetainingCapacity();
    }

    pub fn debugRecords(self: *const DerivationStore) []const DebugRecord {
        return self.debug_records.items;
    }

    pub fn resolver(self: *DerivationStore) HashModuloResolver {
        return .{ .store_dir = self.store_dir, .context = self, .resolve = resolveHashModulo };
    }

    pub fn record(self: *DerivationStore, drv_path: []const u8, hash_modulo: HashModuloView, outputs: []const DrvOutput) !void {
        const value: Record = blk: {
            const cloned_hash_modulo = try cloneHashModulo(self.allocator, hash_modulo);
            errdefer cloned_hash_modulo.deinit(self.allocator);
            const cloned_outputs = try cloneOutputNames(self.allocator, outputs);
            errdefer freeOutputNames(self.allocator, cloned_outputs);
            break :blk .{
                .hash_modulo = cloned_hash_modulo,
                .outputs = cloned_outputs,
            };
        };
        errdefer value.deinit(self.allocator);
        if (self.records.getPtr(drv_path)) |old| {
            old.deinit(self.allocator);
            old.* = value;
            return;
        }
        const key = try self.allocator.dupe(u8, drv_path);
        errdefer self.allocator.free(key);
        try self.records.put(self.allocator, key, value);
    }

    pub fn recordDebug(self: *DerivationStore, drv: *const Drv, computed: ComputedPaths) !void {
        if (!self.debug_enabled) return;
        var debug_record = try debugRecordFromDrv(self.allocator, drv, computed.drv_path, self.resolver());
        errdefer debug_record.deinit(self.allocator);
        try self.debug_records.append(self.allocator, debug_record);
    }

    pub fn outputNames(self: *DerivationStore, drv_path: []const u8) ?[]const []const u8 {
        const value = self.records.getPtr(drv_path) orelse return null;
        return value.outputs;
    }

    fn resolveHashModulo(context: *anyopaque, drv_path: []const u8) anyerror!?HashModuloView {
        const self: *DerivationStore = @ptrCast(@alignCast(context));
        const value = self.records.getPtr(drv_path) orelse return null;
        return value.hash_modulo.view();
    }
};

pub const EnvVar = struct {
    name: []const u8,
    value: []const u8,
};

pub const Drv = struct {
    name: []const u8,
    outputs: []DrvOutput,
    input_drvs: []const DrvInput,
    input_srcs: []const []const u8,
    system: []const u8,
    builder: []const u8,
    args: []const []const u8,
    env: []EnvVar,

    pub fn computePaths(self: *Drv, allocator: std.mem.Allocator, resolver: HashModuloResolver) !ComputedPaths {
        for (self.outputs) |*output| {
            if (output.hash_algo.len != 0) {
                output.path = try fixedOutputPath(allocator, resolver.store_dir, self.name, output.name, output.hash_algo, output.hash);
            }
        }

        const output_hash_modulo = try self.hashModulo(allocator, resolver, true);
        defer output_hash_modulo.deinit(allocator);

        for (self.outputs) |*output| {
            if (output.path.len == 0) {
                output.path = try inputAddressedOutputPath(allocator, resolver.store_dir, self.name, output.name, output_hash_modulo.drv);
            }
        }
        for (self.outputs) |output| {
            for (self.env) |*env| {
                if (std.mem.eql(u8, env.name, output.name)) {
                    env.value = output.path;
                    break;
                }
            }
        }

        const text = try self.toATerm(allocator, false, null);
        defer allocator.free(text);
        const refs = try self.textReferences(allocator);
        defer allocator.free(refs);
        const drv_name = try drvPathName(allocator, self.name);
        defer allocator.free(drv_name);
        const drv_path = try textStorePath(allocator, resolver.store_dir, drv_name, text, refs);
        const dependency_hash_modulo = try self.hashModulo(allocator, resolver, false);
        errdefer dependency_hash_modulo.deinit(allocator);
        return .{
            .drv_path = drv_path,
            .hash_modulo = dependency_hash_modulo,
        };
    }

    pub fn hashModulo(self: *const Drv, allocator: std.mem.Allocator, resolver: HashModuloResolver, mask_outputs: bool) !HashModulo {
        if (self.isFixedOutput()) {
            const output = self.outputs[0];
            const inner = try std.fmt.allocPrint(allocator, "fixed:out:{s}:{s}:{s}", .{ output.hash_algo, output.hash, output.path });
            defer allocator.free(inner);
            const outputs = try allocator.alloc(OutputHash, 1);
            errdefer allocator.free(outputs);
            const name = try allocator.dupe(u8, output.name);
            errdefer allocator.free(name);
            const hash = try sha256Hex(allocator, inner);
            errdefer allocator.free(hash);
            outputs[0] = .{
                .output = name,
                .hash = hash,
            };
            return .{ .outputs = outputs };
        }

        const actual_inputs = try self.hashModuloInputs(allocator, resolver);
        defer freeHashModuloInputs(allocator, actual_inputs);
        const text = try self.toATerm(allocator, mask_outputs, actual_inputs);
        defer allocator.free(text);
        return .{ .drv = try sha256Hex(allocator, text) };
    }

    pub fn toATerm(self: *const Drv, allocator: std.mem.Allocator, mask_outputs: bool, actual_inputs: ?[]const DrvInput) ![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);

        try out.appendSlice(allocator, "Derive([");
        const sorted_outputs = try sortedOutputs(allocator, self.outputs);
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
        const inputs = actual_inputs orelse self.input_drvs;
        const sorted_inputs = try sortedInputs(allocator, inputs);
        defer allocator.free(sorted_inputs);
        for (sorted_inputs, 0..) |input, index| {
            if (index != 0) try out.append(allocator, ',');
            try out.append(allocator, '(');
            try appendUnquotedString(allocator, &out, input.path);
            try out.append(allocator, ',');
            const sorted_names = try sortedStrings(allocator, input.outputs);
            defer allocator.free(sorted_names);
            try appendUnquotedStringList(allocator, &out, sorted_names);
            try out.append(allocator, ')');
        }
        try out.appendSlice(allocator, "],");
        const sorted_srcs = try sortedStrings(allocator, self.input_srcs);
        defer allocator.free(sorted_srcs);
        try appendUnquotedStringList(allocator, &out, sorted_srcs);
        try out.append(allocator, ',');
        try appendUnquotedString(allocator, &out, self.system);
        try out.append(allocator, ',');
        try appendString(allocator, &out, self.builder);
        try out.append(allocator, ',');
        try appendStringList(allocator, &out, self.args);
        try out.appendSlice(allocator, ",[");
        const sorted_env = try sortedEnv(allocator, self.env);
        defer allocator.free(sorted_env);
        for (sorted_env, 0..) |env, index| {
            if (index != 0) try out.append(allocator, ',');
            try out.append(allocator, '(');
            try appendString(allocator, &out, env.name);
            try out.append(allocator, ',');
            const value = if (mask_outputs and self.hasOutput(env.name)) "" else env.value;
            try appendString(allocator, &out, value);
            try out.append(allocator, ')');
        }
        try out.appendSlice(allocator, "])");
        return out.toOwnedSlice(allocator);
    }

    fn isFixedOutput(self: *const Drv) bool {
        return self.outputs.len == 1 and self.outputs[0].hash_algo.len != 0;
    }

    fn hasOutput(self: *const Drv, name: []const u8) bool {
        for (self.outputs) |output| {
            if (std.mem.eql(u8, output.name, name)) return true;
        }
        return false;
    }

    fn textReferences(self: *const Drv, allocator: std.mem.Allocator) ![]const []const u8 {
        var refs: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer refs.deinit(allocator);
        for (self.input_drvs) |input| try appendUniqueString(allocator, &refs, input.path);
        for (self.input_srcs) |src| try appendUniqueString(allocator, &refs, src);
        return refs.toOwnedSlice(allocator);
    }

    fn hashModuloInputs(self: *const Drv, allocator: std.mem.Allocator, resolver: HashModuloResolver) ![]DrvInput {
        var inputs: std.ArrayListUnmanaged(DrvInput) = .empty;
        errdefer freeHashModuloInputs(allocator, inputs.items);

        for (self.input_drvs) |input| {
            const hash_modulo = try resolver.resolvePath(input.path) orelse return error.UnknownInputDerivation;
            switch (hash_modulo) {
                .drv => |hash| {
                    const outputs = try allocator.dupe([]const u8, input.outputs);
                    errdefer allocator.free(outputs);
                    try inputs.append(allocator, .{ .path = hash, .outputs = outputs });
                },
                .outputs => |output_hashes| {
                    for (input.outputs) |output_name| {
                        const hash = outputHashByName(output_hashes, output_name) orelse return error.UnknownDerivationOutput;
                        const outputs = try allocator.alloc([]const u8, 1);
                        errdefer allocator.free(outputs);
                        outputs[0] = "out";
                        try inputs.append(allocator, .{ .path = hash, .outputs = outputs });
                    }
                },
            }
        }

        return inputs.toOwnedSlice(allocator);
    }
};

pub const ComputedPaths = struct {
    drv_path: []u8,
    hash_modulo: HashModulo,
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

fn inputAddressedOutputPath(
    allocator: std.mem.Allocator,
    store_dir: []const u8,
    name: []const u8,
    output: []const u8,
    hash_modulo: []const u8,
) ![]u8 {
    const output_name = try outputPathName(allocator, name, output);
    defer allocator.free(output_name);
    const ty = try std.fmt.allocPrint(allocator, "output:{s}", .{output});
    defer allocator.free(ty);
    return storePathFromInnerDigest(allocator, store_dir, ty, hash_modulo, output_name);
}

fn fixedOutputPath(
    allocator: std.mem.Allocator,
    store_dir: []const u8,
    drv_name: []const u8,
    output: []const u8,
    hash_algo: []const u8,
    hash: []const u8,
) ![]u8 {
    const output_name = try outputPathName(allocator, drv_name, output);
    defer allocator.free(output_name);
    if (std.mem.startsWith(u8, hash_algo, "r:")) {
        return storePathFromInnerDigest(allocator, store_dir, "source", hash, output_name);
    }
    const inner = try std.fmt.allocPrint(allocator, "fixed:out:{s}:{s}:", .{ hash_algo, hash });
    defer allocator.free(inner);
    const digest = try sha256Hex(allocator, inner);
    defer allocator.free(digest);
    return storePathFromInnerDigest(allocator, store_dir, "output:out", digest, output_name);
}

pub fn sourcePath(allocator: std.mem.Allocator, store_dir: []const u8, name: []const u8, nar_hash_hex: []const u8) ![]u8 {
    return storePathFromInnerDigest(allocator, store_dir, "source", nar_hash_hex, name);
}

fn textStorePath(
    allocator: std.mem.Allocator,
    store_dir: []const u8,
    name: []const u8,
    text: []const u8,
    refs: anytype,
) ![]u8 {
    const digest = try sha256Hex(allocator, text);
    defer allocator.free(digest);
    var ty: std.ArrayListUnmanaged(u8) = .empty;
    defer ty.deinit(allocator);
    try ty.appendSlice(allocator, "text");
    const sorted_refs = try sortedStrings(allocator, refs);
    defer allocator.free(sorted_refs);
    for (sorted_refs) |ref| {
        try ty.append(allocator, ':');
        try ty.appendSlice(allocator, ref);
    }
    return storePathFromInnerDigest(allocator, store_dir, ty.items, digest, name);
}

pub fn textPath(
    allocator: std.mem.Allocator,
    store_dir: []const u8,
    name: []const u8,
    text: []const u8,
    refs: []const []const u8,
) ![]u8 {
    return textStorePath(allocator, store_dir, name, text, refs);
}

fn storePathFromInnerDigest(
    allocator: std.mem.Allocator,
    store_dir: []const u8,
    ty: []const u8,
    inner_digest: []const u8,
    name: []const u8,
) ![]u8 {
    const fingerprint = try std.fmt.allocPrint(allocator, "{s}:sha256:{s}:{s}:{s}", .{ ty, inner_digest, store_dir, name });
    defer allocator.free(fingerprint);
    const hash = storeDigest(fingerprint);
    return std.fmt.allocPrint(allocator, "{s}/{s}-{s}", .{ store_dir, hash, name });
}

pub fn outputPathName(allocator: std.mem.Allocator, drv_name: []const u8, output: []const u8) ![]u8 {
    if (std.mem.eql(u8, output, "out")) return allocator.dupe(u8, drv_name);
    return std.fmt.allocPrint(allocator, "{s}-{s}", .{ drv_name, output });
}

pub fn drvPathName(allocator: std.mem.Allocator, drv_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.drv", .{drv_name});
}

pub fn hashToBase16(allocator: std.mem.Allocator, expected_algo: []const u8, text: []const u8) ![]u8 {
    var prefixed_sri = false;
    const body = if (hashAlgorithmSeparator(text)) |separator| blk: {
        const algo = text[0..separator];
        if (!std.mem.eql(u8, algo, expected_algo)) return error.InvalidHashAlgorithm;
        prefixed_sri = text[separator] == '-';
        break :blk text[separator + 1 ..];
    } else text;

    if (prefixed_sri) {
        const bytes = try base64LooseDecode(allocator, body);
        defer allocator.free(bytes);
        return bytesToHexAlloc(allocator, bytes);
    }

    if (isHex(body)) {
        return allocator.dupe(u8, body);
    }

    if (std.mem.indexOfScalar(u8, body, '=') != null or std.mem.indexOfScalar(u8, body, '+') != null or std.mem.indexOfScalar(u8, body, '/') != null) {
        const bytes = try base64LooseDecode(allocator, body);
        defer allocator.free(bytes);
        return bytesToHexAlloc(allocator, bytes);
    }

    const bytes = try nixBase32Decode(allocator, body);
    defer allocator.free(bytes);
    return bytesToHexAlloc(allocator, bytes);
}

fn bytesToHexAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |byte, index| {
        const encoded = std.fmt.bytesToHex([_]u8{byte}, .lower);
        out[index * 2] = encoded[0];
        out[index * 2 + 1] = encoded[1];
    }
    return out;
}

fn base64LooseDecode(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var acc: u32 = 0;
    var bits: u5 = 0;
    for (text) |char| {
        if (char == '=') break;
        const value = base64Value(char) orelse return error.InvalidHash;
        acc = (acc << 6) | value;
        bits += 6;
        while (bits >= 8) {
            bits -= 8;
            try out.append(allocator, @intCast((acc >> bits) & 0xff));
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn hashAlgorithmSeparator(text: []const u8) ?usize {
    const dash = std.mem.indexOfScalar(u8, text, '-');
    const colon = std.mem.indexOfScalar(u8, text, ':');
    if (dash == null) return colon;
    if (colon == null) return dash;
    return @min(dash.?, colon.?);
}

fn base64Value(char: u8) ?u32 {
    if (char >= 'A' and char <= 'Z') return char - 'A';
    if (char >= 'a' and char <= 'z') return 26 + char - 'a';
    if (char >= '0' and char <= '9') return 52 + char - '0';
    if (char == '+') return 62;
    if (char == '/') return 63;
    return null;
}

fn debugRecordFromDrv(
    allocator: std.mem.Allocator,
    drv: *const Drv,
    drv_path: []const u8,
    resolver: HashModuloResolver,
) !DebugRecord {
    var record: DebugRecord = undefined;

    record.name = try allocator.dupe(u8, drv.name);
    errdefer allocator.free(record.name);
    record.drv_path = try allocator.dupe(u8, drv_path);
    errdefer allocator.free(record.drv_path);
    record.system = try allocator.dupe(u8, drv.system);
    errdefer allocator.free(record.system);
    record.builder = try allocator.dupe(u8, drv.builder);
    errdefer allocator.free(record.builder);
    record.args = try cloneStringListDeep(allocator, drv.args);
    errdefer freeStringListDeep(allocator, record.args);
    record.outputs = try cloneDrvOutputsDeep(allocator, drv.outputs);
    errdefer freeDrvOutputsDeep(allocator, record.outputs);
    record.input_drvs = try cloneDrvInputsDeep(allocator, drv.input_drvs);
    errdefer freeDrvInputsDeep(allocator, record.input_drvs);
    record.input_srcs = try cloneStringListDeep(allocator, drv.input_srcs);
    errdefer freeStringListDeep(allocator, record.input_srcs);
    record.env = try cloneEnvVarsDeep(allocator, drv.env);
    errdefer freeEnvVarsDeep(allocator, record.env);

    record.drv_aterm = try drv.toATerm(allocator, false, null);
    errdefer allocator.free(record.drv_aterm);
    record.drv_text_hash = try sha256Hex(allocator, record.drv_aterm);
    errdefer allocator.free(record.drv_text_hash);

    const references = try drv.textReferences(allocator);
    defer allocator.free(references);
    record.drv_text_references = try cloneStringListDeep(allocator, references);
    errdefer freeStringListDeep(allocator, record.drv_text_references);

    record.output_hash = try debugHashModuloStep(allocator, drv, resolver, true);
    errdefer record.output_hash.deinit(allocator);
    record.dependency_hash = try debugHashModuloStep(allocator, drv, resolver, false);
    errdefer record.dependency_hash.deinit(allocator);

    return record;
}

fn debugHashModuloStep(
    allocator: std.mem.Allocator,
    drv: *const Drv,
    resolver: HashModuloResolver,
    mask_outputs: bool,
) !DebugHashModuloStep {
    if (drv.isFixedOutput()) {
        const inputs = try allocator.alloc(DrvInput, 0);
        errdefer allocator.free(inputs);
        const hash_modulo = try drv.hashModulo(allocator, resolver, mask_outputs);
        errdefer hash_modulo.deinit(allocator);
        return .{
            .mask_outputs = mask_outputs,
            .inputs = inputs,
            .aterm = null,
            .hash_modulo = hash_modulo,
        };
    }

    const borrowed_inputs = try drv.hashModuloInputs(allocator, resolver);
    defer freeHashModuloInputs(allocator, borrowed_inputs);

    const inputs = try cloneDrvInputsDeep(allocator, borrowed_inputs);
    errdefer freeDrvInputsDeep(allocator, inputs);
    const aterm = try drv.toATerm(allocator, mask_outputs, borrowed_inputs);
    errdefer allocator.free(aterm);
    const hash = try sha256Hex(allocator, aterm);
    errdefer allocator.free(hash);

    return .{
        .mask_outputs = mask_outputs,
        .inputs = inputs,
        .aterm = aterm,
        .hash_modulo = .{ .drv = hash },
    };
}

fn cloneStringListDeep(allocator: std.mem.Allocator, strings: []const []const u8) ![]const []const u8 {
    const cloned = try allocator.alloc([]const u8, strings.len);
    var initialized: usize = 0;
    errdefer {
        for (cloned[0..initialized]) |string| allocator.free(string);
        allocator.free(cloned);
    }
    for (strings, cloned) |string, *dest| {
        dest.* = try allocator.dupe(u8, string);
        initialized += 1;
    }
    return cloned;
}

fn freeStringListDeep(allocator: std.mem.Allocator, strings: []const []const u8) void {
    for (strings) |string| allocator.free(string);
    allocator.free(strings);
}

fn cloneDrvOutputsDeep(allocator: std.mem.Allocator, outputs: []const DrvOutput) ![]DrvOutput {
    const cloned = try allocator.alloc(DrvOutput, outputs.len);
    var initialized: usize = 0;
    errdefer {
        for (cloned[0..initialized]) |output| {
            allocator.free(output.name);
            allocator.free(output.path);
            allocator.free(output.hash_algo);
            allocator.free(output.hash);
        }
        allocator.free(cloned);
    }
    for (outputs, cloned) |output, *dest| {
        dest.* = .{
            .name = try allocator.dupe(u8, output.name),
            .path = undefined,
            .hash_algo = undefined,
            .hash = undefined,
        };
        errdefer allocator.free(dest.name);
        dest.path = try allocator.dupe(u8, output.path);
        errdefer allocator.free(dest.path);
        dest.hash_algo = try allocator.dupe(u8, output.hash_algo);
        errdefer allocator.free(dest.hash_algo);
        dest.hash = try allocator.dupe(u8, output.hash);
        initialized += 1;
    }
    return cloned;
}

fn freeDrvOutputsDeep(allocator: std.mem.Allocator, outputs: []const DrvOutput) void {
    for (outputs) |output| {
        allocator.free(output.name);
        allocator.free(output.path);
        allocator.free(output.hash_algo);
        allocator.free(output.hash);
    }
    allocator.free(outputs);
}

fn cloneDrvInputsDeep(allocator: std.mem.Allocator, inputs: []const DrvInput) ![]DrvInput {
    const cloned = try allocator.alloc(DrvInput, inputs.len);
    var initialized: usize = 0;
    errdefer {
        for (cloned[0..initialized]) |input| {
            allocator.free(input.path);
            freeStringListDeep(allocator, input.outputs);
        }
        allocator.free(cloned);
    }
    for (inputs, cloned) |input, *dest| {
        dest.* = .{
            .path = try allocator.dupe(u8, input.path),
            .outputs = undefined,
        };
        errdefer allocator.free(dest.path);
        dest.outputs = try cloneStringListDeep(allocator, input.outputs);
        initialized += 1;
    }
    return cloned;
}

fn freeDrvInputsDeep(allocator: std.mem.Allocator, inputs: []const DrvInput) void {
    for (inputs) |input| {
        allocator.free(input.path);
        freeStringListDeep(allocator, input.outputs);
    }
    allocator.free(inputs);
}

fn cloneEnvVarsDeep(allocator: std.mem.Allocator, env: []const EnvVar) ![]EnvVar {
    const cloned = try allocator.alloc(EnvVar, env.len);
    var initialized: usize = 0;
    errdefer {
        for (cloned[0..initialized]) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.value);
        }
        allocator.free(cloned);
    }
    for (env, cloned) |entry, *dest| {
        dest.* = .{
            .name = try allocator.dupe(u8, entry.name),
            .value = undefined,
        };
        errdefer allocator.free(dest.name);
        dest.value = try allocator.dupe(u8, entry.value);
        initialized += 1;
    }
    return cloned;
}

fn freeEnvVarsDeep(allocator: std.mem.Allocator, env: []const EnvVar) void {
    for (env) |entry| {
        allocator.free(entry.name);
        allocator.free(entry.value);
    }
    allocator.free(env);
}

fn cloneHashModulo(allocator: std.mem.Allocator, hash_modulo: HashModuloView) !HashModulo {
    return switch (hash_modulo) {
        .drv => |hash| .{ .drv = try allocator.dupe(u8, hash) },
        .outputs => |outputs| blk: {
            const cloned = try allocator.alloc(OutputHash, outputs.len);
            var initialized: usize = 0;
            errdefer {
                for (cloned[0..initialized]) |output| {
                    allocator.free(output.output);
                    allocator.free(output.hash);
                }
                allocator.free(cloned);
            }
            for (outputs, cloned) |output, *dest| {
                dest.* = try cloneOutputHash(allocator, output);
                initialized += 1;
            }
            break :blk .{ .outputs = cloned };
        },
    };
}

fn cloneOutputHash(allocator: std.mem.Allocator, output: OutputHash) !OutputHash {
    const name = try allocator.dupe(u8, output.output);
    errdefer allocator.free(name);
    return .{
        .output = name,
        .hash = try allocator.dupe(u8, output.hash),
    };
}

fn cloneOutputNames(allocator: std.mem.Allocator, outputs: []const DrvOutput) ![]const []const u8 {
    const cloned = try allocator.alloc([]const u8, outputs.len);
    var initialized: usize = 0;
    errdefer {
        for (cloned[0..initialized]) |output| allocator.free(output);
        allocator.free(cloned);
    }
    for (outputs, cloned) |output, *dest| {
        dest.* = try allocator.dupe(u8, output.name);
        initialized += 1;
    }
    return cloned;
}

fn freeOutputNames(allocator: std.mem.Allocator, outputs: []const []const u8) void {
    for (outputs) |output| allocator.free(output);
    allocator.free(outputs);
}

fn outputHashByName(outputs: []const OutputHash, name: []const u8) ?[]const u8 {
    for (outputs) |output| {
        if (std.mem.eql(u8, output.output, name)) return output.hash;
    }
    return null;
}

fn freeHashModuloInputs(allocator: std.mem.Allocator, inputs: []const DrvInput) void {
    for (inputs) |input| allocator.free(input.outputs);
    allocator.free(inputs);
}

fn isHex(text: []const u8) bool {
    if (text.len == 0 or text.len % 2 != 0) return false;
    for (text) |char| {
        if (!std.ascii.isHex(char)) return false;
    }
    return true;
}

pub fn storeDigest(fingerprint: []const u8) [32]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(fingerprint, &digest, .{});
    return nixBase32(compressDigest(&digest));
}

fn sha256Hex(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const encoded = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &encoded);
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

fn nixBase32Decode(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const byte_len = text.len * 5 / 8;
    const bytes = try allocator.alloc(u8, byte_len);
    @memset(bytes, 0);
    errdefer allocator.free(bytes);

    for (text, 0..) |char, n| {
        const value = nixBase32Value(char) orelse return error.InvalidHash;
        const bit = (text.len - n - 1) * 5;
        const byte_index = bit / 8;
        const bit_index: u3 = @intCast(bit % 8);
        bytes[byte_index] |= value << bit_index;
        if (byte_index + 1 < bytes.len and bit_index > 3) {
            const shift: u3 = @intCast(8 - @as(u4, bit_index));
            bytes[byte_index + 1] |= value >> shift;
        }
    }
    return bytes;
}

fn nixBase32Value(char: u8) ?u8 {
    const alphabet = "0123456789abcdfghijklmnpqrsvwxyz";
    return @intCast(std.mem.indexOfScalar(u8, alphabet, char) orelse return null);
}

fn sortedOutputs(allocator: std.mem.Allocator, outputs: []const DrvOutput) ![]DrvOutput {
    const sorted = try allocator.dupe(DrvOutput, outputs);
    std.mem.sort(DrvOutput, sorted, {}, struct {
        fn lessThan(_: void, a: DrvOutput, b: DrvOutput) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
    return sorted;
}

fn sortedInputs(allocator: std.mem.Allocator, inputs: []const DrvInput) ![]DrvInput {
    const sorted = try allocator.dupe(DrvInput, inputs);
    std.mem.sort(DrvInput, sorted, {}, struct {
        fn lessThan(_: void, a: DrvInput, b: DrvInput) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lessThan);
    return sorted;
}

fn sortedEnv(allocator: std.mem.Allocator, env: []const EnvVar) ![]EnvVar {
    const sorted = try allocator.dupe(EnvVar, env);
    std.mem.sort(EnvVar, sorted, {}, struct {
        fn lessThan(_: void, a: EnvVar, b: EnvVar) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
    return sorted;
}

fn sortedStrings(allocator: std.mem.Allocator, strings: []const []const u8) ![][]const u8 {
    const sorted = try allocator.dupe([]const u8, strings);
    std.mem.sort([]const u8, sorted, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    return sorted;
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

fn appendUniqueString(
    allocator: std.mem.Allocator,
    strings: *std.ArrayListUnmanaged([]const u8),
    string: []const u8,
) !void {
    for (strings.items) |existing| {
        if (std.mem.eql(u8, existing, string)) return;
    }
    try strings.append(allocator, string);
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

test "store digest uses Nix base32 alphabet" {
    const hash = storeDigest("text:sha256:fe9b6355b349291bfdd1c43e9972a3f2c8da199edcf10ee1504797e4da267032:/nix/store:pkg.drv");
    try std.testing.expectEqualStrings("s8l8ca4j8fb6d94205514xd6wf9b57ng", &hash);
    for (hash) |char| {
        try std.testing.expect(std.mem.indexOfScalar(u8, "0123456789abcdfghijklmnpqrsvwxyz", char) != null);
    }
}

test "derivation IR computes minimal Nix paths" {
    var store = DerivationStore.init(std.testing.allocator);
    defer store.deinit();

    var outputs = [_]DrvOutput{.{ .name = "out" }};
    defer if (outputs[0].path.len != 0) std.testing.allocator.free(outputs[0].path);
    var env = [_]EnvVar{
        .{ .name = "builder", .value = "/bin/sh" },
        .{ .name = "name", .value = "pkg" },
        .{ .name = "out", .value = "" },
        .{ .name = "system", .value = "x86_64-linux" },
    };
    var drv: Drv = .{
        .name = "pkg",
        .outputs = &outputs,
        .input_drvs = &.{},
        .input_srcs = &.{},
        .system = "x86_64-linux",
        .builder = "/bin/sh",
        .args = &.{},
        .env = &env,
    };

    const paths = try drv.computePaths(std.testing.allocator, store.resolver());
    defer std.testing.allocator.free(paths.drv_path);
    defer paths.hash_modulo.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("/nix/store/s8l8ca4j8fb6d94205514xd6wf9b57ng-pkg.drv", paths.drv_path);
    try std.testing.expectEqualStrings("/nix/store/8w6a3g1mvf8qkz788dysw8k4hmq91cc8-pkg", outputs[0].path);
}

test "output hash parser accepts SRI base64 and Nix base32" {
    const sri = try hashToBase16(std.testing.allocator, "sha256", "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=");
    defer std.testing.allocator.free(sri);
    try std.testing.expectEqualStrings("0000000000000000000000000000000000000000000000000000000000000000", sri);

    const unpadded_sri = try hashToBase16(std.testing.allocator, "sha256", "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
    defer std.testing.allocator.free(unpadded_sri);
    try std.testing.expectEqualStrings("0000000000000000000000000000000000000000000000000000000000000000", unpadded_sri);

    const nix32 = try hashToBase16(std.testing.allocator, "sha1", "s8l8ca4j8fb6d94205514xd6wf9b57ng");
    defer std.testing.allocator.free(nix32);
    try std.testing.expectEqualStrings("cf9eb292e3a675124a0182a466964392288628d2", nix32);

    const colon_prefixed_nix32 = try hashToBase16(std.testing.allocator, "sha1", "sha1:s8l8ca4j8fb6d94205514xd6wf9b57ng");
    defer std.testing.allocator.free(colon_prefixed_nix32);
    try std.testing.expectEqualStrings("cf9eb292e3a675124a0182a466964392288628d2", colon_prefixed_nix32);
}
