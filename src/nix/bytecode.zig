//! Bytecode IR facade.
//!
//! Re-exports the bytecode submodules so consumers can do either
//! `bytecode.OpCode` (flat) or `bytecode.opcode.OpCode` (nested).

pub const opcode = @import("bytecode/opcode.zig");
pub const encoding = @import("bytecode/encoding.zig");
pub const chunk = @import("bytecode/chunk.zig");
pub const disasm = @import("bytecode/disasm.zig");
pub const breakpoints = @import("bytecode/breakpoints.zig");
pub const BreakpointTable = breakpoints.BreakpointTable;
pub const name_tree = @import("bytecode/name_tree.zig");
pub const NameTree = name_tree.NameTree;
pub const NameId = name_tree.NameId;
pub const NAME_ROOT = name_tree.NAME_ROOT;

// Flat re-exports of the public surface.
pub const OpCode = opcode.OpCode;
pub const count = opcode.count;

pub const MixedAttrSegmentTag = encoding.MixedAttrSegmentTag;
pub const readU16 = encoding.readU16;
pub const readU32 = encoding.readU32;
pub const readInternId = encoding.readInternId;
pub const writeU16 = encoding.writeU16;
pub const writeU32 = encoding.writeU32;
pub const writeInternId = encoding.writeInternId;

pub const Chunk = chunk.Chunk;
pub const ChunkBuilder = chunk.ChunkBuilder;
pub const ChunkRegistry = chunk.ChunkRegistry;
