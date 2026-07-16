//! Deep clone / free ownership helpers for the derivation IR types.
//!
//! The `types.zig` structs are plain data; this is the allocation-owning
//! toolkit that duplicates and frees their heap-backed string fields (used by
//! the derivation store and the debug-record builder to take independent
//! copies of borrowed data). Kept separate so `types.zig` stays a pure type
//! catalog.

const std = @import("std");
const owned_strings = @import("base").owned_strings;
const types = @import("types.zig");

const DrvOutput = types.DrvOutput;
const DrvInput = types.DrvInput;
const EnvVar = types.EnvVar;
const OutputHash = types.OutputHash;
const HashModulo = types.HashModulo;
const HashModuloView = types.HashModuloView;

pub fn cloneStringListDeep(allocator: std.mem.Allocator, strings: []const []const u8) ![]const []const u8 {
    return owned_strings.clone(allocator, strings);
}

pub fn freeStringListDeep(allocator: std.mem.Allocator, strings: []const []const u8) void {
    owned_strings.free(allocator, strings);
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
