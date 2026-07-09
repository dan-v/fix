//! Shared type definitions used throughout the evaluator.
//! No logic here — just types, constants, and small building blocks.

const std = @import("std");

/// How many worker threads to spawn for the evaluation pool.
pub const DEFAULT_WORKER_COUNT: u8 = 4;

/// Maximum value stack slots for a VM.
pub const VM_STACK_CAP: usize = 65_536;

/// Maximum call frame depth.
pub const MAX_FRAMES: usize = 512;

/// Hard cap on how many adjacent value-lambda params the compiler merges
/// into one uncurried chunk (`compiler/ops.zig compileLambda`), and thus
/// the largest `Chunk.arity` / partial-application arg count. Bounds the
/// on-stack arg buffers in the VM's PAP machinery. Chains longer than
/// this stay curried beyond the cap.
pub const MAX_UNCURRY_ARITY: u16 = 4;

/// Initial capacity for a bytecode chunk constant pool.
pub const CHUNK_CONSTANTS_CAP: usize = 128;

/// Initial capacity for bytecode in a chunk.
pub const CHUNK_CODE_CAP: usize = 256;

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

/// An index into the evaluator object heap.
pub const ObjectId = u32;
pub const OBJECT_ID_NONE: ObjectId = std.math.maxInt(ObjectId);

