const std = @import("std");
const compiler_mod = @import("../compiler.zig");
const ast = @import("../ast.zig");
const chunk = @import("../bytecode.zig").chunk;
const diagnostic = @import("../diagnostic.zig");
const types = @import("../types.zig");
const attrs = @import("attrs.zig");

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

pub fn ensureLineIndex(self: *Compiler) !*const diagnostic.LineIndex {
    if (self.parent) |parent| return ensureLineIndex(parent);
    if (!self.line_index_ready) {
        self.line_index = try diagnostic.LineIndex.init(self.allocator, self.source);
        self.line_index_ready = true;
    }
    return &self.line_index;
}

pub fn optionalSourceFileId(self: *Compiler) !?InternId {
    if (self.source_path == null) return null;
    return try attrs.sourceFileId(self);
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
