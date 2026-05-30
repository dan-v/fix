//! Shared type definitions used throughout the evaluator.
//! No logic here — just types, constants, and small building blocks.

const std = @import("std");

/// How many worker threads to spawn for the evaluation pool.
pub const DEFAULT_WORKER_COUNT: u8 = 4;

/// Initial stack capacity for a VM.
pub const VM_STACK_CAP: usize = 4096;

/// Maximum call frame depth.
pub const MAX_FRAMES: usize = 512;

/// Initial capacity for a bytecode chunk constant pool.
pub const CHUNK_CONSTANTS_CAP: usize = 128;

/// Initial capacity for bytecode in a chunk.
pub const CHUNK_CODE_CAP: usize = 256;

/// How many entries a newborn memo table can hold before growing.
pub const CACHE_INITIAL_CAP: usize = 4096;

/// A small identifier for interned strings.
pub const InternId = u32;
pub const INTERN_ID_NONE: InternId = std.math.maxInt(InternId);

/// The ID of a bytecode chunk in a global table.
pub const ChunkId = u32;
pub const CHUNK_ID_NONE: ChunkId = std.math.maxInt(ChunkId);

/// An index into a worker's stack.
pub const StackIdx = u32;

/// An index into a chunk's constant pool. Bytecode encodes this as a u16.
pub const ConstIdx = u16;

/// A fingerprint for memoization (hash of expression + environment).
pub const MemoHash = u64;

/// The result of attempting to force a thunk.
pub const ForceResult = enum(u8) {
    /// The thunk was already resolved, value is ready.
    already_resolved,
    /// This thread claimed the thunk and must now compute it.
    claimed,
    /// Another thread is computing it; spin or yield.
    busy,
};
