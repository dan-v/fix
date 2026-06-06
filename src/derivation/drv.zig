const std = @import("std");
const aterm = @import("aterm.zig");
const paths = @import("paths.zig");
const types = @import("types.zig");

const ComputedPaths = types.ComputedPaths;
const DrvInput = types.DrvInput;
const DrvOutput = types.DrvOutput;
const EnvVar = types.EnvVar;
const HashModulo = types.HashModulo;
const HashModuloResolver = types.HashModuloResolver;
const OutputHash = types.OutputHash;

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
                output.path = try paths.fixedOutputPath(allocator, resolver.store_dir, self.name, output.name, output.hash_algo, output.hash);
            }
        }

        const output_hash_modulo = try self.hashModulo(allocator, resolver, true);
        defer output_hash_modulo.deinit(allocator);

        for (self.outputs) |*output| {
            if (output.path.len == 0) {
                output.path = try paths.inputAddressedOutputPath(allocator, resolver.store_dir, self.name, output.name, output_hash_modulo.drv);
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
        const drv_name = try paths.drvPathName(allocator, self.name);
        defer allocator.free(drv_name);
        const drv_path = try paths.textPath(allocator, resolver.store_dir, drv_name, text, refs);
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
            const hash = try paths.sha256Hex(allocator, inner);
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
        return .{ .drv = try paths.sha256Hex(allocator, text) };
    }

    pub fn toATerm(self: *const Drv, allocator: std.mem.Allocator, mask_outputs: bool, actual_inputs: ?[]const DrvInput) ![]u8 {
        return aterm.toATerm(self, allocator, mask_outputs, actual_inputs);
    }

    pub fn isFixedOutput(self: *const Drv) bool {
        return self.outputs.len == 1 and self.outputs[0].hash_algo.len != 0;
    }

    pub fn textReferences(self: *const Drv, allocator: std.mem.Allocator) ![]const []const u8 {
        var refs: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer refs.deinit(allocator);
        for (self.input_drvs) |input| try appendUniqueString(allocator, &refs, input.path);
        for (self.input_srcs) |src| try appendUniqueString(allocator, &refs, src);
        return refs.toOwnedSlice(allocator);
    }

    pub fn hashModuloInputs(self: *const Drv, allocator: std.mem.Allocator, resolver: HashModuloResolver) ![]DrvInput {
        var inputs: std.ArrayListUnmanaged(DrvInput) = .empty;
        errdefer freeHashModuloInputs(allocator, inputs.items);

        for (self.input_drvs) |input| {
            const hash_modulo = try resolver.resolvePath(input.path) orelse return error.UnknownInputDerivation;
            switch (hash_modulo) {
                .drv => |hash| {
                    const outputs = try allocator.dupe([]const u8, input.outputs);
                    errdefer allocator.free(outputs);
                    try appendMergedInput(allocator, &inputs, hash, outputs);
                },
                .outputs => |output_hashes| {
                    for (input.outputs) |output_name| {
                        const hash = outputHashByName(output_hashes, output_name) orelse return error.UnknownDerivationOutput;
                        const outputs = try allocator.alloc([]const u8, 1);
                        errdefer allocator.free(outputs);
                        outputs[0] = "out";
                        try appendMergedInput(allocator, &inputs, hash, outputs);
                    }
                },
            }
        }

        return inputs.toOwnedSlice(allocator);
    }
};

fn outputHashByName(outputs: []const OutputHash, name: []const u8) ?[]const u8 {
    for (outputs) |output| {
        if (std.mem.eql(u8, output.output, name)) return output.hash;
    }
    return null;
}

pub fn freeHashModuloInputs(allocator: std.mem.Allocator, inputs: []const DrvInput) void {
    for (inputs) |input| allocator.free(input.outputs);
    allocator.free(inputs);
}

fn appendMergedInput(
    allocator: std.mem.Allocator,
    inputs: *std.ArrayListUnmanaged(DrvInput),
    path: []const u8,
    outputs: []const []const u8,
) !void {
    errdefer allocator.free(outputs);

    for (inputs.items) |*existing| {
        if (!std.mem.eql(u8, existing.path, path)) continue;

        var merged = existing.outputs;
        for (outputs) |output| {
            if (containsString(merged, output)) continue;

            const expanded = try allocator.alloc([]const u8, merged.len + 1);
            @memcpy(expanded[0..merged.len], merged);
            expanded[merged.len] = output;
            allocator.free(merged);
            existing.outputs = expanded;
            merged = expanded;
        }
        allocator.free(outputs);
        return;
    }

    try inputs.append(allocator, .{ .path = path, .outputs = outputs });
}

fn containsString(strings: []const []const u8, needle: []const u8) bool {
    for (strings) |string| {
        if (std.mem.eql(u8, string, needle)) return true;
    }
    return false;
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
