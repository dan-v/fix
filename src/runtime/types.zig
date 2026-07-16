//! Shared type definitions used throughout the evaluator.
//! No logic here — just types, constants, and small building blocks.

const std = @import("std");

/// How many worker threads to spawn for the evaluation pool.
pub const default_worker_count: u8 = 4;

/// Maximum value stack slots for a VM.
pub const vm_stack_capacity: usize = 65_536;

/// Maximum physical call frame depth. Bounds non-tail recursion (tail
/// calls reuse a frame). Kept comfortably above `default_max_call_depth`
/// so the logical call-depth cap (which matches Nix's `max-call-depth`)
/// fires with a proper "stack overflow" error before the physical frame
/// array is exhausted on legitimate deep non-tail recursion.
pub const max_frames: usize = 20_000;

/// Default logical call-depth limit, matching Nix/Lix's `max-call-depth`
/// setting (10000). Incremented on every function application including
/// tail calls; when it is exceeded the evaluator raises a
/// "stack overflow; max-call-depth exceeded" error. Overridable via
/// `--option max-call-depth N`.
pub const default_max_call_depth: u32 = 10_000;

/// Hard cap on how many adjacent value-lambda params the compiler merges
/// into one uncurried chunk (`compiler/lambda.zig compileLambda`), and thus
/// the largest `Chunk.arity` / partial-application arg count. Bounds the
/// on-stack arg buffers in the VM's PAP machinery. Chains longer than
/// this stay curried beyond the cap.
pub const max_uncurry_arity: u16 = 4;

/// Initial capacity for a bytecode chunk constant pool.
pub const chunk_constants_capacity: usize = 128;

/// Initial capacity for bytecode in a chunk.
pub const chunk_code_capacity: usize = 256;

/// A small identifier for interned strings.
pub const InternId = u32;
pub const no_intern_id: InternId = std.math.maxInt(InternId);

/// The ID of a bytecode chunk in a global table.
pub const ChunkId = u32;
pub const no_chunk_id: ChunkId = std.math.maxInt(ChunkId);

/// An index into a worker's stack.
pub const StackIdx = u32;

/// An index into a chunk's constant pool. Bytecode encodes this as a u16.
pub const ConstIdx = u16;

/// An index into the evaluator object heap.
pub const ObjectId = u32;
pub const no_object_id: ObjectId = std.math.maxInt(ObjectId);
