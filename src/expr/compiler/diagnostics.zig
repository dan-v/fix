//! Compile-time diagnostic reporting: emit errors/notes, absorb child and
//! parser diagnostics, and resolve source offsets to line/column via a
//! memoized (root-owned, parent-chain-shared) line index.
//! Also the operand-size guards (`requireU16At`/`requireU8At`) and chunk
//! source-span construction.

const std = @import("std");
const compiler_mod = @import("context.zig");
const ast = @import("syntax").ast;
const chunk = @import("../bytecode.zig").chunk;
const diagnostic = @import("syntax").diagnostic;
const types = @import("runtime").types;

const Compiler = compiler_mod.Compiler;
const Node = compiler_mod.Node;
const Diagnostic = diagnostic.Diagnostic;
const InternId = types.InternId;

pub fn reportCompileError(self: *Compiler, offset: u32, len: u32, message: []const u8) !void {
    try reportDiagnostic(self, .err, offset, len, message);
}

pub fn reportCompileNote(self: *Compiler, offset: u32, len: u32, message: []const u8) !void {
    try reportDiagnostic(self, .note, offset, len, message);
}

pub fn reportDuplicateAttribute(self: *Compiler, duplicate: Node.Atom, original: Node.Atom) !void {
    try reportCompileError(self, duplicate.offset, duplicate.len, "duplicate attribute");
    try reportCompileNote(self, original.offset, original.len, "first attribute defined here");
}

pub fn reportDiagnostic(self: *Compiler, severity: Diagnostic.Severity, offset: u32, len: u32, message: []const u8) !void {
    const position = try sourcePositionForOffset(self, offset);
    try self.diagnostics.append(self.allocator, .{
        .severity = severity,
        .kind = .compile,
        .line = position.line,
        .column = position.column,
        .offset = offset,
        .len = len,
        .token_type = null,
        .message = message,
    });
}

pub fn absorbParserDiagnostics(self: *Compiler, diags: []const Diagnostic, source_offset: u32) !void {
    try self.diagnostics.ensureUnusedCapacity(self.allocator, diags.len);
    for (diags) |diag| {
        const offset = source_offset + diag.offset;
        const position = try sourcePositionForOffset(self, offset);
        var copy = diag;
        copy.offset = offset;
        copy.line = position.line;
        copy.column = position.column;
        copy.source = null;
        copy.source_path = null;
        self.diagnostics.appendAssumeCapacity(copy);
    }
}

pub fn requireU16At(self: *Compiler, count: usize, atom: Node.Atom, message: []const u8) !u16 {
    if (count > std.math.maxInt(u16)) {
        try reportCompileError(self, atom.offset, atom.len, message);
        return error.BytecodeOperandTooLarge;
    }
    return @intCast(count);
}

pub fn requireU8At(self: *Compiler, count: usize, atom: Node.Atom, message: []const u8) !u8 {
    if (count > std.math.maxInt(u8)) {
        try reportCompileError(self, atom.offset, atom.len, message);
        return error.BytecodeOperandTooLarge;
    }
    return @intCast(count);
}

pub fn absorbChildDiagnostics(self: *Compiler, child: *Compiler) !void {
    try self.diagnostics.appendSlice(self.allocator, child.diagnostics.items);
    child.diagnostics.clearRetainingCapacity();
    try self.owned_diagnostic_messages.appendSlice(self.allocator, child.owned_diagnostic_messages.items);
    child.owned_diagnostic_messages.clearRetainingCapacity();
}

pub fn sourcePositionForOffset(self: *Compiler, offset: u32) !diagnostic.SourcePosition {
    const index = try ensureLineIndex(self);
    return index.positionForOffset(offset);
}

pub fn ensureLineIndex(self: *Compiler) !*diagnostic.LineIndex {
    // Called per compiled node (source-map spans); memoize the resolved
    // index so deeply nested child compilers don't re-walk the parent
    // chain every time. Safe: the owning (root) compiler outlives every
    // child, and the root's `line_index` field address is stable once
    // built.
    if (self.resolved_line_index) |idx| return idx;
    const idx = blk: {
        if (self.parent) |parent| break :blk try ensureLineIndex(parent);
        if (self.external_line_index) |idx| break :blk idx;
        if (!self.line_index_ready) {
            self.line_index = try diagnostic.LineIndex.init(self.allocator, self.source);
            self.line_index_ready = true;
        }
        break :blk &self.line_index;
    };
    self.resolved_line_index = idx;
    return idx;
}

pub fn optionalSourceFileId(self: *Compiler) !?InternId {
    // Child compilers inherit `source_file_id` but NOT `source_path` (imports
    // set the path, nested chunk builders only copy the id) — so check the
    // cached/inherited id first, else fall back to deriving one from the path.
    // Without this, a nested chunk's spans carry a valid line but a null file,
    // which the timeline (and error traces) can't name.
    if (self.source_file_id) |id| return id;
    if (self.source_path == null) return null;
    return try sourceFileId(self);
}

/// Intern the source path once and share its id with every child compiler.
/// Source identity belongs to diagnostics/source maps, not attribute lowering.
pub fn sourceFileId(self: *Compiler) !InternId {
    if (self.source_file_id) |id| return id;
    const path = self.source_path orelse return error.MissingSourcePath;
    const id = try self.intern.intern(path);
    self.source_file_id = id;
    return id;
}

/// Like `sourceSpanForNode`, but from a bare source atom (offset/len) — used to
/// give attrset-body thunks (which compile a list of entries, not a single
/// node) a representative `Chunk.body_span` for timeline labelling.
pub fn sourceSpanForAtom(self: *Compiler, atom: Node.Atom) !?chunk.Chunk.SourceSpan {
    const position = try sourcePositionForOffset(self, atom.offset);
    return .{
        .file = try optionalSourceFileId(self),
        .offset = atom.offset,
        .len = atom.len,
        .line = position.line,
        .column = position.column,
    };
}

pub fn sourceSpanForNode(self: *Compiler, node: *const Node) !?chunk.Chunk.SourceSpan {
    const span = node.span orelse return null;
    const position = try sourcePositionForOffset(self, span.offset);
    return .{
        .file = try optionalSourceFileId(self),
        .offset = span.offset,
        .len = span.len,
        .line = position.line,
        .column = position.column,
    };
}
