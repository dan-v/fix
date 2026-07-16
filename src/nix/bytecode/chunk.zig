//! Bytecode chunk facade.
//!
//! The immutable model, mutable construction machinery, and concurrent
//! registry have separate implementations but retain this stable namespace for
//! compiler, VM, debugger, and inspection callers.

pub const model = @import("chunk/model.zig");
pub const builder = @import("chunk/builder.zig");
pub const registry = @import("chunk/registry.zig");

pub const LambdaPattern = model.LambdaPattern;
pub const Chunk = model.Chunk;
pub const ChunkStrictness = model.ChunkStrictness;
pub const TrivialBody = model.TrivialBody;
pub const AttrAccessShape = model.AttrAccessShape;
pub const ClosureCaptures = model.ClosureCaptures;
pub const SchedulingHints = model.SchedulingHints;

pub const ChunkBuilder = builder.ChunkBuilder;
pub const SPECULATION_MIN_CODE_BYTES = builder.SPECULATION_MIN_CODE_BYTES;
pub const SPECULATION_TRUSTED_CODE_BYTES = builder.SPECULATION_TRUSTED_CODE_BYTES;

pub const WellKnownChunks = registry.WellKnownChunks;
pub const ChunkRegistry = registry.ChunkRegistry;

test {
    _ = model;
    _ = builder;
    _ = registry;
}
