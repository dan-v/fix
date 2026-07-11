//! Bytecode emission helpers: low-level op/operand writers plus the
//! short/long and capture-carrying encodings for closures, thunks, and
//! attr-set/attr-path ops. Also the peephole super-op fusion (`*_ret`,
//! `get_*_attr`, store-to-slot) and jump patching.

const std = @import("std");
const compiler_mod = @import("../compiler.zig");
const ast = @import("syntax").ast;
const bytecode = @import("bytecode");
const chunk = bytecode.chunk;
const heap_mod = @import("runtime").heap;
const types = @import("runtime").types;
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

/// Build-attrs emission for STATIC sorted+unique literals: the attr names go
/// to the chunk's side table (`attrs_new_named*`) and the stack carries only
/// the N values — no per-entry `push_const` of the name, no pool slot.
/// Positions (when present) ride the side table too.
pub fn emitBuildAttrsSorted(self: *Compiler, count: u16, names: []const types.InternId, positions: []const heap_mod.AttrPosEntry) !void {
    std.debug.assert(names.len == count);
    if (count == 0) return emitOpU16(self, .attrs_new_srt, 0);
    const names_start: u32 = @intCast(self.builder.attr_names.items.len);
    try self.builder.attr_names.appendSlice(self.allocator, names);
    if (positions.len == 0) {
        try emitOpU16(self, .attrs_new_named_srt, count);
        try self.builder.writeU32(self.allocator, names_start);
        return;
    }
    // Positions bake pre-sorted by name (presorted call sites append them in
    // emit order, which IS name order); `findAttrPos` binary-searches.
    std.debug.assert(std.sort.isSorted(heap_mod.AttrPosEntry, positions, {}, posNameLessThan));
    const pos_start: u32 = @intCast(self.builder.attr_pos.items.len);
    try self.builder.attr_pos.appendSlice(self.allocator, positions);
    try emitOpU16(self, .attrs_new_named_pos_srt, count);
    try self.builder.writeU32(self.allocator, names_start);
    try self.builder.writeU16(self.allocator, try u16Count(positions.len));
    try self.builder.writeU32(self.allocator, pos_start);
}

fn posNameLessThan(_: void, a: heap_mod.AttrPosEntry, b: heap_mod.AttrPosEntry) bool {
    return a.name < b.name;
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
    try emitLocalOp(self, .loc_get, .loc_get_w, slot);
}

pub fn emitCaptureLocal(self: *Compiler, slot: u16) !void {
    try emitLocalOp(self, .loc_grab, .loc_grab_w, slot);
}

pub fn emitSetLocal(self: *Compiler, slot: u16) !void {
    if (try fuseStoreToSlot(self, slot, .narrow_local)) return;
    try emitLocalOp(self, .loc_set, .loc_set_w, slot);
}

pub fn emitSetCellLocal(self: *Compiler, slot: u16) !void {
    if (try fuseStoreToSlot(self, slot, .narrow_cell)) return;
    try emitLocalOp(self, .cell_set, .cell_set_w, slot);
}

const StoreTarget = enum { narrow_local, narrow_cell };

/// Rewrite a just-emitted `thunk`-family op into the fused `*_st`/`*_st_cell`
/// variant by appending the destination slot byte. Saves the push/pop of the
/// new thunk reference plus one dispatch.
///
/// Only fuses for 1-byte slots (`loc_set`/`cell_set`, not the `_w` forms);
/// ~all let-bindings fit. Both chunk-id widths fuse: past 65,536 registered
/// chunks (any real NixOS eval) the wide encoding is the DOMINANT form, not
/// the rare one.
fn fuseStoreToSlot(self: *Compiler, slot: u16, target: StoreTarget) !bool {
    if (slot > std.math.maxInt(u8)) return false;
    const offset = self.builder.last_op_offset orelse return false;
    const code = self.builder.code.items;
    if (offset >= code.len) return false;
    const last_op: OpCode = @enumFromInt(code[offset]);
    const fused: OpCode = switch (last_op) {
        .thunk => switch (target) {
            .narrow_local => .thunk_st,
            .narrow_cell => .thunk_st_cell,
        },
        .thunk_eag => switch (target) {
            .narrow_local => .thunk_eag_st,
            .narrow_cell => .thunk_eag_st_cell,
        },
        .thunk_w => switch (target) {
            .narrow_local => .thunk_w_st,
            .narrow_cell => .thunk_w_st_cell,
        },
        .thunk_eag_w => switch (target) {
            .narrow_local => .thunk_eag_w_st,
            .narrow_cell => .thunk_eag_w_st_cell,
        },
        else => return false,
    };
    code[offset] = @intFromEnum(fused);
    try self.builder.writeByte(self.allocator, @intCast(slot));
    self.builder.last_op_offset = null;
    // Unfused: extra `loc_set` op (1 byte) + slot byte. Fused: just
    // the slot byte appended. Net 1 byte saved.
    self.builder.fusion_savings += 1;
    return true;
}

pub fn emitInitCellSlot(self: *Compiler, slot: u16) !void {
    try emitLocalOp(self, .cell_init, .cell_init_w, slot);
}

pub fn emitGetLocalRet(self: *Compiler, slot: u16) !void {
    try emitLocalOp(self, .loc_get_ret, .loc_get_ret_w, slot);
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
                .push_const => {
                    code[offset] = @intFromEnum(OpCode.push_const_ret);
                    self.builder.last_op_offset = null;
                    return;
                },
                .up_get => {
                    code[offset] = @intFromEnum(OpCode.up_get_ret);
                    self.builder.last_op_offset = null;
                    return;
                },
                .loc_get => {
                    code[offset] = @intFromEnum(OpCode.loc_get_ret);
                    self.builder.last_op_offset = null;
                    return;
                },
                .loc_get_w => {
                    code[offset] = @intFromEnum(OpCode.loc_get_ret_w);
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

/// Emit `attr_get name`, fusing with an immediately-preceding source
/// op into a compound super-op (`up_get_attr`, `loc_get_attr`,
/// `loc_get_attr_w`). Only fuses when the attr name InternId
/// fits in u16; there's no long-name form yet.
pub fn emitGetAttr(self: *Compiler, id: InternId) !void {
    if (id <= std.math.maxInt(u16)) {
        if (self.builder.last_op_offset) |offset| {
            const code = self.builder.code.items;
            if (offset < code.len) {
                const last_op: OpCode = @enumFromInt(code[offset]);
                const fused: ?OpCode = switch (last_op) {
                    .up_get => .up_get_attr,
                    .loc_get => .loc_get_attr,
                    .loc_get_w => .loc_get_attr_w,
                    else => null,
                };
                if (fused) |op| {
                    code[offset] = @intFromEnum(op);
                    try self.builder.writeU16(self.allocator, @intCast(id));
                    self.builder.last_op_offset = null;
                    // The unfused encoding would have been 3 bytes
                    // (attr_get op + 2-byte name); we wrote 2 bytes.
                    self.builder.fusion_savings += 1;
                    return;
                }
            }
        }
    }
    try emitInternOp(self, .attr_get, .attr_get_w, id);
}

pub fn writeInternId(self: *Compiler, id: InternId, wide: bool) !void {
    try bytecode.writeInternId(&self.builder.code, self.allocator, id, wide);
}

pub fn emitClosure(self: *Compiler, chunk_id: types.ChunkId, upvalue_count: u16) !void {
    if (chunk_id <= std.math.maxInt(u16)) {
        try emitOpU16(self, .closure, @intCast(chunk_id));
    } else {
        try emitOp(self, .closure_w);
        try self.builder.writeU32(self.allocator, chunk_id);
    }
    try self.builder.writeU16(self.allocator, upvalue_count);
}

pub fn emitClosureWithCaptures(self: *Compiler, chunk_id: types.ChunkId, captures: []const Capture) !void {
    if (captures.len == 0) return emitClosure(self, chunk_id, 0);
    const upvalue_count = try captureCount(captures.len);

    if (chunk_id <= std.math.maxInt(u16)) {
        try emitOpU16(self, .closure_cap, @intCast(chunk_id));
    } else {
        try emitOp(self, .closure_cap_w);
        try self.builder.writeU32(self.allocator, chunk_id);
    }
    try self.builder.writeU16(self.allocator, upvalue_count);
    try emitCaptureDescriptors(self, captures);
}

pub fn emitThunkWithCaptures(self: *Compiler, chunk_id: types.ChunkId, captures: []const Capture) !void {
    return emitThunkWithCapturesImpl(self, chunk_id, captures, false);
}

/// Same as `emitThunkWithCaptures` but emits the `thunk_eag`
/// variant — runtime will submit the thunk to the urgent scheduler
/// queue at creation. Called by `compileThunk` when the surrounding
/// chunk's strictness signature says this binding will be forced.
pub fn emitEagerThunkWithCaptures(self: *Compiler, chunk_id: types.ChunkId, captures: []const Capture) !void {
    return emitThunkWithCapturesImpl(self, chunk_id, captures, true);
}

fn emitThunkWithCapturesImpl(self: *Compiler, chunk_id: types.ChunkId, captures: []const Capture, eager: bool) !void {
    const upvalue_count = try captureCount(captures.len);

    if (chunk_id <= std.math.maxInt(u16)) {
        const op: bytecode.OpCode = if (eager) .thunk_eag else .thunk;
        try emitOpU16(self, op, @intCast(chunk_id));
    } else {
        const op: bytecode.OpCode = if (eager) .thunk_eag_w else .thunk_w;
        try emitOp(self, op);
        try self.builder.writeU32(self.allocator, chunk_id);
    }
    try self.builder.writeU16(self.allocator, upvalue_count);
    try emitCaptureDescriptors(self, captures);
}

/// Emit `thunk_arg` — a function argument whose laziness is decided at
/// runtime from the callee's strictness. Always wide chunk-id (the 2
/// extra operand bytes are negligible vs. avoiding a second opcode).
pub fn emitApplyArg(self: *Compiler, chunk_id: types.ChunkId, captures: []const Capture) !void {
    const upvalue_count = try captureCount(captures.len);
    try emitOp(self, .thunk_arg);
    try self.builder.writeU32(self.allocator, chunk_id);
    try self.builder.writeU16(self.allocator, upvalue_count);
    try emitCaptureDescriptors(self, captures);
}

/// Emit `thunk_defer` (lazy per-attr compilation): a deferred-table id plus a
/// `(start, count)` reference into the chunk's deduped capture-list side table.
/// An attrset's deferred values all snapshot the same enclosing scope, so the
/// descriptor list — previously re-emitted inline per value — is interned once.
pub fn emitDeferAttrValue(self: *Compiler, deferred_id: u32, scope: []const Capture) !void {
    const env_count = try captureCount(scope.len);
    const cap_start = try internCaptureList(self, scope);
    try emitOp(self, .thunk_defer);
    try self.builder.writeU32(self.allocator, deferred_id);
    try self.builder.writeU32(self.allocator, cap_start);
    try self.builder.writeU16(self.allocator, env_count);
    // The descriptors left the code stream for the side table — compensate the
    // speculation-size threshold (see ChunkBuilder.sideTableWeight).
    self.builder.capture_inline_weight += @as(usize, scope.len) * 3;
}

/// Encode `captures` as `(kind:1, index:2-LE)*` and intern the list into the
/// builder's capture side table, returning its start offset.
fn internCaptureList(self: *Compiler, captures: []const Capture) !u32 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(self.allocator);
    for (captures) |capture| {
        try buf.append(self.allocator, switch (capture.kind) {
            .local => 0,
            .upvalue => 1,
        });
        try buf.append(self.allocator, @intCast(capture.index & 0xff));
        try buf.append(self.allocator, @intCast(capture.index >> 8));
    }
    return self.builder.internCaptureList(self.allocator, buf.items);
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

/// Emit `thunk_attr`: a frameless attr-access thunk over the value of one
/// capture descriptor — the elided form of an `up_get_attr; ret; halt`
/// wrapper chunk.
pub fn emitThunkAttr(self: *Compiler, base: Capture, name: u16) !void {
    try emitOp(self, .thunk_attr);
    try emitCaptureDescriptors(self, &.{base});
    try self.builder.writeU16(self.allocator, name);
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
