const std = @import("std");
const compiler_mod = @import("../compiler.zig");
const ast = @import("../ast.zig");
const bytecode = @import("../bytecode.zig");
const chunk = bytecode.chunk;
const heap_mod = @import("../runtime/heap.zig");
const types = @import("../runtime/types.zig");
const OpCode = bytecode.OpCode;
const operand = @import("operand.zig");
const attrs = @import("attrs.zig");
const diagnostics = @import("diagnostics.zig");

const Compiler = compiler_mod.Compiler;
const Node = compiler_mod.Node;
const Capture = compiler_mod.Capture;
const InternId = types.InternId;
const captureCount = operand.captureCount;
const u16Count = operand.u16Count;

pub fn emitOp(self: *Compiler, op: OpCode) !void {
    try self.builder.writeOp(self.allocator, op);
}

pub fn emitOpU16(self: *Compiler, op: OpCode, val: u16) !void {
    try emitOp(self, op);
    try self.builder.writeU16(self.allocator, val);
}

pub fn emitOpU32(self: *Compiler, op: OpCode, val: u32) !void {
    try emitOp(self, op);
    try self.builder.writeU32(self.allocator, val);
}

pub fn emitBuildAttrs(self: *Compiler, count: u16, positions: []const heap_mod.AttrPosEntry) !void {
    if (positions.len == 0) {
        try emitOpU16(self, .build_attrs, count);
        return;
    }

    try emitOpU16(self, .build_attrs_with_pos, count);
    try self.builder.writeU16(self.allocator, try u16Count(positions.len));
    for (positions) |position| {
        try self.builder.writeU32(self.allocator, position.name);
        try self.builder.writeU32(self.allocator, position.pos.file);
        try self.builder.writeU32(self.allocator, position.pos.line);
        try self.builder.writeU32(self.allocator, position.pos.column);
    }
}

pub fn emitOpByte(self: *Compiler, op: OpCode, val: u8) !void {
    try emitOp(self, op);
    try self.builder.writeByte(self.allocator, val);
}

pub fn emitLocalOp(self: *Compiler, short_op: OpCode, long_op: OpCode, slot: u16) !void {
    if (slot <= std.math.maxInt(u8)) {
        try emitOpByte(self, short_op, @intCast(slot));
    } else {
        try emitOpU16(self, long_op, slot);
    }
}

pub fn emitGetLocal(self: *Compiler, slot: u16) !void {
    try emitLocalOp(self, .get_local, .get_local_long, slot);
}

pub fn emitCaptureLocal(self: *Compiler, slot: u16) !void {
    try emitLocalOp(self, .capture_local, .capture_local_long, slot);
}

pub fn emitSetLocal(self: *Compiler, slot: u16) !void {
    try emitLocalOp(self, .set_local, .set_local_long, slot);
}

pub fn emitSetCellLocal(self: *Compiler, slot: u16) !void {
    try emitLocalOp(self, .set_cell_local, .set_cell_local_long, slot);
}

pub fn emitInitCellSlot(self: *Compiler, slot: u16) !void {
    try emitLocalOp(self, .init_cell_slot, .init_cell_slot_long, slot);
}

pub fn emitGetLocalRet(self: *Compiler, slot: u16) !void {
    try emitLocalOp(self, .get_local_ret, .get_local_ret_long, slot);
}

/// Emit a `ret`, fusing it into the immediately-preceding value-producing
/// op when the pattern matches a `<op>_ret` super-op. Safe because the
/// rewrite preserves the operand bytes — source-map entries pointing at
/// the original op's byte range still describe the same span.
pub fn emitRet(self: *Compiler) !void {
    if (self.builder.last_op_offset) |offset| {
        const code = self.builder.code.items;
        if (offset < code.len) {
            const last_op: OpCode = @enumFromInt(code[offset]);
            switch (last_op) {
                .constant => {
                    code[offset] = @intFromEnum(OpCode.constant_ret);
                    self.builder.last_op_offset = null;
                    return;
                },
                .get_upvalue => {
                    code[offset] = @intFromEnum(OpCode.get_upvalue_ret);
                    self.builder.last_op_offset = null;
                    return;
                },
                .get_local => {
                    code[offset] = @intFromEnum(OpCode.get_local_ret);
                    self.builder.last_op_offset = null;
                    return;
                },
                .get_local_long => {
                    code[offset] = @intFromEnum(OpCode.get_local_ret_long);
                    self.builder.last_op_offset = null;
                    return;
                },
                else => {},
            }
        }
    }
    try emitOp(self, .ret);
}

pub fn emitInternOp(self: *Compiler, short_op: OpCode, long_op: OpCode, id: InternId) !void {
    if (id <= std.math.maxInt(u16)) {
        try emitOpU16(self, short_op, @intCast(id));
    } else {
        try emitOp(self, long_op);
        try self.builder.writeU32(self.allocator, id);
    }
}

pub fn writeInternId(self: *Compiler, id: InternId, wide: bool) !void {
    try bytecode.writeInternId(&self.builder.code, self.allocator, id, wide);
}

pub fn emitClosure(self: *Compiler, chunk_id: types.ChunkId, upvalue_count: u16) !void {
    if (chunk_id <= std.math.maxInt(u16)) {
        try emitOpU16(self, .closure, @intCast(chunk_id));
    } else {
        try emitOp(self, .closure_long);
        try self.builder.writeU32(self.allocator, chunk_id);
    }
    try self.builder.writeU16(self.allocator, upvalue_count);
}

pub fn emitClosureWithCaptures(self: *Compiler, chunk_id: types.ChunkId, captures: []const Capture) !void {
    if (captures.len == 0) return emitClosure(self, chunk_id, 0);
    const upvalue_count = try captureCount(captures.len);

    if (chunk_id <= std.math.maxInt(u16)) {
        try emitOpU16(self, .closure_captures, @intCast(chunk_id));
    } else {
        try emitOp(self, .closure_captures_long);
        try self.builder.writeU32(self.allocator, chunk_id);
    }
    try self.builder.writeU16(self.allocator, upvalue_count);
    try emitCaptureDescriptors(self, captures);
}

pub fn emitThunkWithCaptures(self: *Compiler, chunk_id: types.ChunkId, captures: []const Capture) !void {
    return emitThunkWithCapturesImpl(self, chunk_id, captures, false);
}

/// Same as `emitThunkWithCaptures` but emits the `thunk_captures_eager`
/// variant — runtime will submit the thunk to the urgent scheduler
/// queue at creation. Called by `compileThunk` when the surrounding
/// chunk's strictness signature says this binding will be forced.
pub fn emitEagerThunkWithCaptures(self: *Compiler, chunk_id: types.ChunkId, captures: []const Capture) !void {
    return emitThunkWithCapturesImpl(self, chunk_id, captures, true);
}

fn emitThunkWithCapturesImpl(self: *Compiler, chunk_id: types.ChunkId, captures: []const Capture, eager: bool) !void {
    const upvalue_count = try captureCount(captures.len);

    if (chunk_id <= std.math.maxInt(u16)) {
        const op: bytecode.OpCode = if (eager) .thunk_captures_eager else .thunk_captures;
        try emitOpU16(self, op, @intCast(chunk_id));
    } else {
        const op: bytecode.OpCode = if (eager) .thunk_captures_eager_long else .thunk_captures_long;
        try emitOp(self, op);
        try self.builder.writeU32(self.allocator, chunk_id);
    }
    try self.builder.writeU16(self.allocator, upvalue_count);
    try emitCaptureDescriptors(self, captures);
}

pub fn emitCaptureDescriptors(self: *Compiler, captures: []const Capture) !void {
    for (captures) |capture| {
        try self.builder.writeByte(self.allocator, switch (capture.kind) {
            .local => 0,
            .upvalue => 1,
        });
        try self.builder.writeU16(self.allocator, capture.index);
    }
}

pub fn attrSegmentsWide(self: *Compiler, segments: []const Node.Atom) !bool {
    var wide = false;
    for (segments) |seg| {
        if (try attrs.attrSegmentNameId(self, seg) > std.math.maxInt(u16)) wide = true;
    }
    return wide;
}

pub fn writeStaticAttrPathOperand(self: *Compiler, segments: []const Node.Atom, atom: Node.Atom, wide: bool) !void {
    try self.builder.writeByte(self.allocator, try diagnostics.requireU8At(self, segments.len, atom, "attribute path has too many segments"));
    for (segments) |seg| {
        const name_id = try attrs.attrSegmentNameId(self, seg);
        try writeInternId(self, name_id, wide);
    }
}

pub fn writeMixedAttrPathOperand(self: *Compiler, segments: []const Node.Atom, dynamic_count: usize, atom: Node.Atom) !void {
    try self.builder.writeByte(self.allocator, try diagnostics.requireU8At(self, segments.len, atom, "attribute path has too many segments"));
    try self.builder.writeByte(self.allocator, try diagnostics.requireU8At(self, dynamic_count, atom, "attribute path has too many dynamic segments"));
    for (segments) |seg| {
        if (attrs.attrSegmentHasInterpolation(self, seg)) {
            try self.builder.writeByte(self.allocator, @intFromEnum(bytecode.MixedAttrSegmentTag.dynamic));
        } else {
            try self.builder.writeByte(self.allocator, @intFromEnum(bytecode.MixedAttrSegmentTag.static));
            try self.builder.writeU32(self.allocator, try attrs.attrSegmentNameId(self, seg));
        }
    }
}

pub fn writeHasAttrMixedOperand(self: *Compiler, segments: []const Node.HasAttrMixedSegment, dynamic_count: usize, atom: Node.Atom) !void {
    try self.builder.writeByte(self.allocator, try diagnostics.requireU8At(self, segments.len, atom, "attribute path has too many segments"));
    try self.builder.writeByte(self.allocator, try diagnostics.requireU8At(self, dynamic_count, atom, "attribute path has too many dynamic segments"));
    for (segments) |segment| {
        switch (segment) {
            .static => |static_atom| {
                if (attrs.attrSegmentHasInterpolation(self, static_atom)) {
                    try self.builder.writeByte(self.allocator, @intFromEnum(bytecode.MixedAttrSegmentTag.dynamic));
                } else {
                    try self.builder.writeByte(self.allocator, @intFromEnum(bytecode.MixedAttrSegmentTag.static));
                    try self.builder.writeU32(self.allocator, try attrs.attrSegmentNameId(self, static_atom));
                }
            },
            .dynamic => try self.builder.writeByte(self.allocator, @intFromEnum(bytecode.MixedAttrSegmentTag.dynamic)),
        }
    }
}

pub fn patchJump(self: *Compiler, instruction_offset: usize, target_offset: usize) void {
    const operand_offset = instruction_offset + 1;
    const next_instruction = instruction_offset + 5;
    const relative: u32 = @intCast(target_offset - next_instruction);
    self.builder.code.items[operand_offset] = @truncate(relative);
    self.builder.code.items[operand_offset + 1] = @truncate(relative >> 8);
    self.builder.code.items[operand_offset + 2] = @truncate(relative >> 16);
    self.builder.code.items[operand_offset + 3] = @truncate(relative >> 24);
    // Patching a jump means some branch now lands at `target_offset`.
    // If that target equals the current write position (`code.len`),
    // the next opcode we emit becomes a multi-predecessor join — we
    // can no longer assume the op at `last_op_offset` is the only
    // path producing the value flowing into `emit.emitRet`'s fuse
    // candidate. Conservative: drop the hint whenever the target
    // is the tail. (Patches that land BEFORE the tail can't affect
    // straight-line fusion of subsequent ops.)
    if (target_offset == self.builder.code.items.len) {
        self.builder.last_op_offset = null;
    }
}
