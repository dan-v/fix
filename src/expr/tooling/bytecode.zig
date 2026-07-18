//! Bytecode inspection and presentation surface for diagnostics and CLI tools.

const core = @import("../bytecode.zig");

pub const opcode = core.opcode;
pub const encoding = core.encoding;
pub const chunk = core.chunk;
pub const inspect = core.inspect;
pub const breakpoints = core.breakpoints;
pub const name_tree = core.name_tree;

pub const OpCode = core.OpCode;
pub const Chunk = core.Chunk;
pub const ChunkBuilder = core.ChunkBuilder;
pub const ChunkRegistry = core.ChunkRegistry;
pub const BreakpointTable = core.BreakpointTable;
pub const NameId = core.NameId;
pub const root_name_id = core.root_name_id;

pub const disasm = @import("bytecode/disasm.zig");
pub const stats = @import("bytecode/stats.zig");

test {
    _ = disasm;
    _ = stats;
}
