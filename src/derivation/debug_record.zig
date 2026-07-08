//! Builds a self-owned DebugRecord snapshot of a Drv for the derivation-debug
//! CLI: deep-clones every field and precomputes the ATerm, text hash,
//! references, and both (masked/unmasked) hash-modulo steps.

const std = @import("std");
const drv_mod = @import("drv.zig");
const codec = @import("hash_codec.zig");
const types = @import("types.zig");
const clone = @import("clone.zig");

const DebugHashModuloStep = types.DebugHashModuloStep;
const DebugRecord = types.DebugRecord;
const Drv = drv_mod.Drv;
const DrvInput = types.DrvInput;
const HashModuloResolver = types.HashModuloResolver;

pub fn debugRecordFromDrv(
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
    record.args = try clone.cloneStringListDeep(allocator, drv.args);
    errdefer clone.freeStringListDeep(allocator, record.args);
    record.outputs = try clone.cloneDrvOutputsDeep(allocator, drv.outputs);
    errdefer clone.freeDrvOutputsDeep(allocator, record.outputs);
    record.input_drvs = try clone.cloneDrvInputsDeep(allocator, drv.input_drvs);
    errdefer clone.freeDrvInputsDeep(allocator, record.input_drvs);
    record.input_srcs = try clone.cloneStringListDeep(allocator, drv.input_srcs);
    errdefer clone.freeStringListDeep(allocator, record.input_srcs);
    record.env = try clone.cloneEnvVarsDeep(allocator, drv.env);
    errdefer clone.freeEnvVarsDeep(allocator, record.env);

    record.drv_aterm = try drv.toATerm(allocator, false, null);
    errdefer allocator.free(record.drv_aterm);
    record.drv_text_hash = try codec.sha256Hex(allocator, record.drv_aterm);
    errdefer allocator.free(record.drv_text_hash);

    const references = try drv.textReferences(allocator);
    defer allocator.free(references);
    record.drv_text_references = try clone.cloneStringListDeep(allocator, references);
    errdefer clone.freeStringListDeep(allocator, record.drv_text_references);

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
    defer drv_mod.freeHashModuloInputs(allocator, borrowed_inputs);

    const inputs = try clone.cloneDrvInputsDeep(allocator, borrowed_inputs);
    errdefer clone.freeDrvInputsDeep(allocator, inputs);
    const aterm = try drv.toATerm(allocator, mask_outputs, borrowed_inputs);
    errdefer allocator.free(aterm);
    const hash = try codec.sha256Hex(allocator, aterm);
    errdefer allocator.free(hash);

    return .{
        .mask_outputs = mask_outputs,
        .inputs = inputs,
        .aterm = aterm,
        .hash_modulo = .{ .drv = hash },
    };
}
