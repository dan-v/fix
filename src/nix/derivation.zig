//! Derivation value construction.
//!
//! Public API surface for derivation IR, hashing, path construction, and
//! evaluator-facing value construction.

const heap_mod = @import("runtime").heap;
const InternTable = @import("runtime").intern.InternTable;
const Value = @import("runtime").value.Value;
const dtypes = @import("derivation/types.zig");
const drv_mod = @import("derivation/drv.zig");
const path_mod = @import("derivation/paths.zig");
const hash_codec = @import("derivation/hash_codec.zig");
const store_mod = @import("derivation/store.zig");
const value_builder = @import("derivation/value.zig");
const std = @import("std");

/// Store-path realization for `path`/`filterSource`-style source imports.
pub const source_path = @import("derivation/source_path.zig");

pub const Output = dtypes.Output;
pub const DrvOutput = dtypes.DrvOutput;
pub const DrvInput = dtypes.DrvInput;
pub const OutputHash = dtypes.OutputHash;
pub const HashModulo = dtypes.HashModulo;
pub const HashModuloView = dtypes.HashModuloView;
pub const DebugHashModuloStep = dtypes.DebugHashModuloStep;
pub const DebugRecord = dtypes.DebugRecord;
pub const HashModuloResolver = dtypes.HashModuloResolver;
pub const EnvVar = dtypes.EnvVar;
pub const ComputedPaths = dtypes.ComputedPaths;
pub const Spec = dtypes.Spec;

pub const Drv = drv_mod.Drv;
pub const DerivationStore = store_mod.DerivationStore;

pub const sourcePath = path_mod.sourcePath;
pub const textPath = path_mod.textPath;
pub const outputPathName = path_mod.outputPathName;
pub const drvPathName = path_mod.drvPathName;
pub const hashToBase16 = hash_codec.hashToBase16;
pub const hashAlgorithmSeparator = hash_codec.hashAlgorithmSeparator;
pub const storeDigest = hash_codec.storeDigest;

pub fn buildValue(
    allocator: std.mem.Allocator,
    intern: *InternTable,
    heap: *heap_mod.ObjectHeap,
    spec: Spec,
) !Value {
    return value_builder.buildValue(allocator, intern, heap, spec);
}

pub fn buildStrictValue(
    allocator: std.mem.Allocator,
    intern: *InternTable,
    heap: *heap_mod.ObjectHeap,
    spec: Spec,
) !Value {
    return value_builder.buildStrictValue(allocator, intern, heap, spec);
}

pub const isSyntheticName = value_builder.isSyntheticName;

test {
    _ = @import("derivation/tests.zig");
    _ = hash_codec;
}
