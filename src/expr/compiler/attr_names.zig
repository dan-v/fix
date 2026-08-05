//! Attribute-name decoding and source-position metadata.
//!
//! These operations are shared by access lowering, set construction, constant
//! folding, lambda formals, and let bindings. Keeping them in a leaf module
//! prevents those compiler stages from depending on the whole attrs compiler.

const std = @import("std");
const compiler_mod = @import("context.zig");
const diagnostics = @import("diagnostics.zig");
const string_syntax = @import("syntax").string_syntax;
const heap_mod = @import("runtime").heap;
const InternId = @import("runtime").types.InternId;

const Compiler = compiler_mod.Compiler;
const Node = compiler_mod.Node;

pub fn equal(self: *const Compiler, a: Node.Atom, b: Node.Atom) bool {
    return std.mem.eql(u8, span(self, a), span(self, b));
}

pub fn span(self: *const Compiler, atom: Node.Atom) []const u8 {
    const source = self.source[atom.offset .. atom.offset + atom.len];
    if (source.len >= 2 and source[0] == '"' and source[source.len - 1] == '"') {
        return source[1 .. source.len - 1];
    }
    return source;
}

/// A double-quoted name whose body has no escapes or interpolation decodes to
/// exactly its inner bytes.
fn simpleQuotedInner(self: *const Compiler, atom: Node.Atom) ?[]const u8 {
    const source = self.source[atom.offset .. atom.offset + atom.len];
    if (source.len < 2 or source[0] != '"' or source[source.len - 1] != '"') return null;
    const inner = source[1 .. source.len - 1];
    if (std.mem.indexOfAny(u8, inner, "\\$\"") != null) return null;
    return inner;
}

pub fn intern(self: *Compiler, atom: Node.Atom) !InternId {
    // Identifiers and simple quoted names are already decoded in the source;
    // intern their slices directly and avoid a temporary allocation.
    if (string_syntax.kindAt(self.source, atom.offset) == null) {
        return self.intern.intern(self.source[atom.offset .. atom.offset + atom.len]);
    }
    if (simpleQuotedInner(self, atom)) |inner| return self.intern.intern(inner);

    const name = try alloc(self, atom);
    defer self.allocator.free(name);
    return self.intern.intern(name);
}

pub fn alloc(self: *Compiler, atom: Node.Atom) ![]u8 {
    const source = self.source[atom.offset .. atom.offset + atom.len];
    if (string_syntax.kindAt(self.source, atom.offset) == null) {
        return self.allocator.dupe(u8, source);
    }
    if (simpleQuotedInner(self, atom)) |inner| return self.allocator.dupe(u8, inner);

    const parsed = try string_syntax.parseLiteral(self.allocator, self.source, .{
        .start = atom.offset,
        .end = atom.offset + atom.len,
    });
    defer parsed.deinit();

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(self.allocator);
    for (parsed.parts) |part| switch (part) {
        .text => |text| try out.appendSlice(self.allocator, text.slice()),
        .interpolation => return error.InvalidAttributePath,
    };
    return out.toOwnedSlice(self.allocator);
}

pub fn hasInterpolation(self: *const Compiler, atom: Node.Atom) bool {
    const source = self.source[atom.offset .. atom.offset + atom.len];
    return string_syntax.kindAt(self.source, atom.offset) != null and
        std.mem.indexOf(u8, source, "${") != null;
}

pub fn appendPosition(
    self: *Compiler,
    positions: *std.ArrayListUnmanaged(heap_mod.AttrPosEntry),
    atom: Node.Atom,
    name_id: InternId,
) !void {
    _ = self.source_path orelse return;
    const position = try diagnostics.sourcePositionForOffset(self, atom.offset);
    try positions.append(self.allocator, .{
        .name = name_id,
        .pos = .{
            .file = try diagnostics.sourceFileId(self),
            .line = position.line,
            .column = position.column,
        },
    });
}
