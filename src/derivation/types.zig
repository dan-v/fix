const std = @import("std");
const heap_mod = @import("../runtime/heap.zig");
const InternId = @import("../runtime/types.zig").InternId;

const AttrEntry = heap_mod.AttrEntry;

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

pub const EnvVar = struct {
    name: []const u8,
    value: []const u8,
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

pub fn cloneStringListDeep(allocator: std.mem.Allocator, strings: []const []const u8) ![]const []const u8 {
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

pub fn freeStringListDeep(allocator: std.mem.Allocator, strings: []const []const u8) void {
    for (strings) |string| allocator.free(string);
    allocator.free(strings);
}

pub fn cloneDrvOutputsDeep(allocator: std.mem.Allocator, outputs: []const DrvOutput) ![]DrvOutput {
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

pub fn freeDrvOutputsDeep(allocator: std.mem.Allocator, outputs: []const DrvOutput) void {
    for (outputs) |output| {
        allocator.free(output.name);
        allocator.free(output.path);
        allocator.free(output.hash_algo);
        allocator.free(output.hash);
    }
    allocator.free(outputs);
}

pub fn cloneDrvInputsDeep(allocator: std.mem.Allocator, inputs: []const DrvInput) ![]DrvInput {
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

pub fn freeDrvInputsDeep(allocator: std.mem.Allocator, inputs: []const DrvInput) void {
    for (inputs) |input| {
        allocator.free(input.path);
        freeStringListDeep(allocator, input.outputs);
    }
    allocator.free(inputs);
}

pub fn cloneEnvVarsDeep(allocator: std.mem.Allocator, env: []const EnvVar) ![]EnvVar {
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

pub fn freeEnvVarsDeep(allocator: std.mem.Allocator, env: []const EnvVar) void {
    for (env) |entry| {
        allocator.free(entry.name);
        allocator.free(entry.value);
    }
    allocator.free(env);
}

pub fn cloneHashModulo(allocator: std.mem.Allocator, hash_modulo: HashModuloView) !HashModulo {
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

pub fn cloneOutputNames(allocator: std.mem.Allocator, outputs: []const DrvOutput) ![]const []const u8 {
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

pub fn freeOutputNames(allocator: std.mem.Allocator, outputs: []const []const u8) void {
    for (outputs) |output| allocator.free(output);
    allocator.free(outputs);
}
