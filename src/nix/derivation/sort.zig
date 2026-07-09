//! Canonical-ordering helpers (outputs/inputs/env/strings) that return sorted
//! copies, so ATerm serialization is deterministic and its hash is stable.

const std = @import("std");
const types = @import("types.zig");

const DrvInput = types.DrvInput;
const DrvOutput = types.DrvOutput;
const EnvVar = types.EnvVar;

pub fn sortedOutputs(allocator: std.mem.Allocator, outputs: []const DrvOutput) ![]DrvOutput {
    const sorted = try allocator.dupe(DrvOutput, outputs);
    std.mem.sort(DrvOutput, sorted, {}, struct {
        fn lessThan(_: void, a: DrvOutput, b: DrvOutput) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
    return sorted;
}

pub fn sortedInputs(allocator: std.mem.Allocator, inputs: []const DrvInput) ![]DrvInput {
    const sorted = try allocator.dupe(DrvInput, inputs);
    std.mem.sort(DrvInput, sorted, {}, struct {
        fn lessThan(_: void, a: DrvInput, b: DrvInput) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lessThan);
    return sorted;
}

pub fn sortedEnv(allocator: std.mem.Allocator, env: []const EnvVar) ![]EnvVar {
    const sorted = try allocator.dupe(EnvVar, env);
    std.mem.sort(EnvVar, sorted, {}, struct {
        fn lessThan(_: void, a: EnvVar, b: EnvVar) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
    return sorted;
}

pub fn sortedStrings(allocator: std.mem.Allocator, strings: []const []const u8) ![][]const u8 {
    const sorted = try allocator.dupe([]const u8, strings);
    std.mem.sort([]const u8, sorted, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    return sorted;
}
