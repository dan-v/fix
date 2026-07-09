//! Lowers leaf and near-leaf expressions: integer/float/string/path
//! literals (with `${…}` interpolation and `concat_strings` assembly),
//! search paths, identifier resolution (locals/upvalues/`with`/ambient
//! builtins/`__curPos`), and materialization of parser-elided bodies.

const std = @import("std");
const compiler_mod = @import("../compiler.zig");
const ast = @import("syntax").ast;
const bytecode = @import("../bytecode.zig");
const builtins = @import("runtime").builtins;
const chunk = bytecode.chunk;
const diagnostic = @import("syntax").diagnostic;
const heap_mod = @import("runtime").heap;
const string_syntax = @import("syntax").string_syntax;
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const OpCode = bytecode.OpCode;
const emit = @import("emit.zig");
const scope = @import("scope.zig");
const diagnostics = @import("diagnostics.zig");
const attrs = @import("attrs.zig");
const int_ops = @import("runtime").int;
const parser_mod = @import("syntax").parser;

const Compiler = compiler_mod.Compiler;
const Node = compiler_mod.Node;
const NodeTag = compiler_mod.NodeTag;
const BinaryOp = compiler_mod.BinaryOp;
const Capture = compiler_mod.Capture;
const AttrEntryView = compiler_mod.AttrEntryView;
const AttrEntryGroup = compiler_mod.AttrEntryGroup;
const AttrEntryGroups = compiler_mod.AttrEntryGroups;
const ContainerValueOptions = compiler_mod.ContainerValueOptions;
const WithScope = compiler_mod.WithScope;
const InternId = types.InternId;
const offsetNode = ast.offsetNode;

pub const ResolvedPath = struct {
    text: []const u8,
    owned: bool,
};

pub fn compileInt(self: *Compiler, node: *const Node) !void {
    const span = self.source[node.data.atom.offset .. node.data.atom.offset + node.data.atom.len];
    const val = std.fmt.parseInt(i64, span, 10) catch {
        try diagnostics.reportCompileError(self, node.data.atom.offset, node.data.atom.len, "invalid integer literal");
        return error.InvalidNumber;
    };
    try self.builder.emitConstant(self.allocator, try int_ops.make(self.heap, val));
}

pub fn compileFloat(self: *Compiler, node: *const Node) !void {
    const span = self.source[node.data.atom.offset .. node.data.atom.offset + node.data.atom.len];
    const val = std.fmt.parseFloat(f64, span) catch {
        try diagnostics.reportCompileError(self, node.data.atom.offset, node.data.atom.len, "invalid float literal");
        return error.InvalidNumber;
    };
    const v = Value.float(val);
    try self.builder.emitConstant(self.allocator, v);
}

pub fn compileString(self: *Compiler, node: *const Node) !void {
    try compileStringAtom(self, node.data.atom);
}

/// Cap on operands accumulated for one `concat_strings`. Keeps the
/// operand count in the opcode's u16 and bounds transient VM stack
/// growth for pathological many-part literals; when the cap is hit the
/// accumulated parts are folded into one operand and assembly continues.
const max_concat_parts: u16 = 4096;

pub fn compileStringAtom(self: *Compiler, atom: Node.Atom) !void {
    const literal = string_syntax.Span{
        .start = atom.offset,
        .end = atom.offset + atom.len,
    };
    const parsed = try string_syntax.parseLiteral(self.allocator, self.source, literal);
    defer parsed.deinit();

    // Push every part, then assemble with ONE `concat_strings` — the
    // old `add_int` fold interned every intermediate prefix (hash +
    // copy + permanent intern-table bytes per `${}` boundary).
    var parts: u16 = 0;
    var total_parts: u32 = 0;
    var ops_emitted: u32 = 0;
    var first_is_interp = false;
    var single_is_text = false;
    for (parsed.parts) |part| {
        switch (part) {
            .text => |text| {
                if (text.bytes.len == 0) continue;
                const id = try self.intern.intern(text.bytes);
                try self.builder.emitConstant(self.allocator, Value.string(id));
                parts += 1;
                total_parts += 1;
                single_is_text = total_parts == 1;
            },
            .interpolation => |span| {
                if (total_parts == 0) first_is_interp = true;
                try compileInterpolatedExpr(self, self.source[span.start..span.end], span.start);
                parts += 1;
                total_parts += 1;
                single_is_text = false;
            },
        }
        if (parts == max_concat_parts) {
            try emit.emitOpU16(self, .concat_strings, parts);
            ops_emitted += 1;
            parts = 1;
        }
    }

    switch (parts) {
        0 => try self.builder.emitConstant(self.allocator, Value.string(try self.intern.intern(""))),
        // A lone text part is already a string constant. A lone
        // interpolation still needs the string coercion (`"${x}"`);
        // `concat_strings 1` coerces without re-interning the text.
        1 => if (!single_is_text) {
            try emit.emitOpU16(self, .concat_strings, 1);
            ops_emitted += 1;
        },
        else => {
            try emit.emitOpU16(self, .concat_strings, parts);
            ops_emitted += 1;
        },
    }

    // Perceived-weight compensation: speculation admission
    // (`body_is_substantial`) is keyed on encoded size, and its tuning
    // "lives at a sharp cliff" (see `ChunkBuilder.fusion_savings`). The
    // old encoding spent `total_parts - 1` add_int bytes (plus a 3-byte
    // empty-string constant and one more add when the literal starts
    // with an interpolation); the new one spends 3 bytes per concat op.
    // Add the (saturating) difference back so many-part literals keep
    // the scheduling weight they had under the add_int fold — dropping
    // hot generated-config chunks below the cliff measurably starves
    // the speculation avalanche at w>=8.
    if (ops_emitted != 0) {
        const old_extra: u32 = (total_parts - 1) + @as(u32, if (first_is_interp) 4 else 0);
        const new_extra: u32 = 3 * ops_emitted;
        self.builder.fusion_savings += old_extra -| new_extra;
    }
}

pub fn emitStringPart(self: *Compiler, part: []const u8, have_value: *bool) !void {
    if (part.len == 0) return;

    const id = try self.intern.intern(part);
    try self.builder.emitConstant(self.allocator, Value.string(id));
    if (have_value.*) try emit.emitOp(self, .add_int);
    have_value.* = true;
}

/// Materialize an `.elided` body (body-span elision, see
/// `syntax/parser.zig scanElidableBody`): sub-parse its recorded source
/// span into the root compiler's AST arena and return the parsed body,
/// offset-corrected so every node span matches what an eager parse of the
/// whole file would have produced. Parse diagnostics are absorbed with the
/// same offset correction (the `compileInterpolatedExpr` precedent).
///
/// During the original file compile (`elide_mutable`), the shared elided
/// node is overwritten in place, so all later consumers — duplicate-merge
/// checks, the parent chunk's strictness stamp — see the real shape.
/// Force-time deferred compiles run CONCURRENTLY over the shared retained
/// AST: they parse into their per-compile throwaway arena and leave the
/// shared node untouched (racers each materialize their own copy).
pub fn materializeElided(self: *Compiler, node: *const Node) anyerror!*Node {
    std.debug.assert(node.tag == .elided);
    var root: *Compiler = self;
    while (root.parent) |p| root = p;
    const arena = root.ast_arena orelse return error.ElidedBodyWithoutArena;

    const atom = node.data.atom;
    const body_source = self.source[atom.offset .. atom.offset + atom.len];
    var parser = parser_mod.Parser.init(self.allocator, arena, body_source);
    defer parser.deinit();
    const expr = parser.parse() catch |err| {
        try diagnostics.absorbParserDiagnostics(self, parser.diagnostics.items, atom.offset);
        return err;
    };
    offsetNode(expr, atom.offset);

    if (root.elide_mutable) {
        const shared = @constCast(node);
        shared.* = expr.*;
        return shared;
    }
    return expr;
}

pub fn compileInterpolatedExpr(self: *Compiler, expr_source: []const u8, source_offset: u32) !void {
    var arena = ast.AstArena.init(self.allocator);
    defer arena.deinit();

    var parser = parser_mod.Parser.init(self.allocator, &arena, expr_source);
    defer parser.deinit();
    const expr = parser.parse() catch |err| {
        try diagnostics.absorbParserDiagnostics(self, parser.diagnostics.items, source_offset);
        return err;
    };
    offsetNode(expr, source_offset);
    try self.compileNode(expr);
}

pub fn compilePath(self: *Compiler, node: *const Node) !void {
    const span = self.source[node.data.atom.offset .. node.data.atom.offset + node.data.atom.len];
    if (std.mem.indexOf(u8, span, "${") != null) return compileInterpolatedPath(self, span, node.data.atom.offset);

    const path = try resolvePathLiteral(self, span);
    defer if (path.owned) self.allocator.free(path.text);
    const id = try self.intern.intern(path.text);
    const v = Value.path(id);
    try self.builder.emitConstant(self.allocator, v);
}

pub fn compileInterpolatedPath(self: *Compiler, span: []const u8, source_offset: u32) !void {
    var cursor: usize = 0;
    var have_value = false;

    while (std.mem.indexOf(u8, span[cursor..], "${")) |relative_start| {
        const interp_start = cursor + relative_start;
        try emitPathPart(self, span[cursor..interp_start], &have_value);

        const expr_start = interp_start + 2;
        const expr_end = string_syntax.findInterpolationEnd(span, expr_start) orelse return error.InvalidPathLiteral;
        try compileInterpolatedExpr(self, span[expr_start..expr_end], source_offset + @as(u32, @intCast(expr_start)));
        if (have_value) try emit.emitOp(self, .add_int);
        have_value = true;
        cursor = expr_end + 1;
    }

    try emitPathPart(self, span[cursor..], &have_value);
    if (!have_value) return error.InvalidPathLiteral;
}

pub fn emitPathPart(self: *Compiler, part: []const u8, have_value: *bool) !void {
    if (part.len == 0) return;
    if (!have_value.*) {
        const path = try resolvePathLiteralPreserveTrailingSlash(self, part);
        defer if (path.owned) self.allocator.free(path.text);
        const id = try self.intern.intern(path.text);
        try self.builder.emitConstant(self.allocator, Value.path(id));
        have_value.* = true;
        return;
    }

    try emitStringPart(self, part, have_value);
}

pub fn compileSearchPath(self: *Compiler, node: *const Node) !void {
    const span = self.source[node.data.atom.offset .. node.data.atom.offset + node.data.atom.len];
    if (span.len < 2) return error.InvalidSearchPath;
    const id = try self.intern.intern(span[1 .. span.len - 1]);
    try emit.emitInternOp(self, .find_file, .find_file_long, id);
}

pub fn resolvePathLiteral(self: *Compiler, span: []const u8) !ResolvedPath {
    if (std.fs.path.isAbsolute(span)) {
        return .{
            .text = try std.fs.path.resolve(self.allocator, &.{span}),
            .owned = true,
        };
    }
    const cwd = self.base_path orelse return .{ .text = span, .owned = false };

    return .{
        .text = try std.fs.path.resolve(self.allocator, &.{ cwd, span }),
        .owned = true,
    };
}

pub fn resolvePathLiteralPreserveTrailingSlash(self: *Compiler, span: []const u8) !ResolvedPath {
    const resolved = try resolvePathLiteral(self, span);
    if (!std.mem.endsWith(u8, span, "/") or std.mem.endsWith(u8, resolved.text, "/")) return resolved;

    const text = try std.fmt.allocPrint(self.allocator, "{s}/", .{resolved.text});
    if (resolved.owned) self.allocator.free(resolved.text);
    return .{ .text = text, .owned = true };
}

pub fn compileIdent(self: *Compiler, node: *const Node) !void {
    const span = self.source[node.data.atom.offset .. node.data.atom.offset + node.data.atom.len];
    if (std.mem.eql(u8, span, "__curPos")) {
        try compileCurPos(self, node.data.atom);
        return;
    }
    // Intern once, then resolve by id (u32 compares) up the scope chain
    // instead of re-comparing the source bytes against every local at
    // every parent level. Identifier resolution is the bulk of compile
    // time (~13% of w=1), and most references are deep upvalues
    // (`lib`/`config`/`pkgs`) that walk the whole parent chain.
    const name_id = try self.intern.intern(span);
    if (scope.resolveLocalId(self, name_id)) |slot| {
        try emit.emitGetLocal(self, slot);
    } else if (try scope.resolveCaptureId(self, span, name_id)) |slot| {
        try emit.emitOpU16(self, .get_upvalue, slot);
    } else if (std.mem.eql(u8, span, "builtins")) {
        try emit.emitOp(self, .push_builtins);
    } else if (try emitAmbientBuiltin(self, span)) {
        return;
    } else if (try scope.emitWithLookup(self, span)) {
        return;
    } else {
        const message = try std.fmt.allocPrint(self.allocator, "undefined variable '{s}'", .{span});
        try self.owned_diagnostic_messages.append(self.allocator, message);
        try diagnostics.reportCompileError(self, node.data.atom.offset, node.data.atom.len, message);
        return error.UndefinedVariable;
    }
}

pub fn compileCurPos(self: *Compiler, atom: Node.Atom) !void {
    if (self.source_path == null) {
        try emit.emitOp(self, .push_null);
        return;
    }

    const file_id = try self.intern.intern("file");
    const line_id = try self.intern.intern("line");
    const column_id = try self.intern.intern("column");
    const source_path_id = try attrs.sourceFileId(self);
    const position = try diagnostics.sourcePositionForOffset(self, atom.offset);

    try attrs.emitAttrNameId(self, file_id);
    try self.builder.emitConstant(self.allocator, Value.string(source_path_id));
    try attrs.emitAttrNameId(self, line_id);
    try self.builder.emitConstant(self.allocator, Value.int(position.line));
    try attrs.emitAttrNameId(self, column_id);
    try self.builder.emitConstant(self.allocator, Value.int(position.column));
    try emit.emitOpU16(self, .build_attrs, 3);
}

pub fn emitAmbientBuiltin(self: *Compiler, name: []const u8) !bool {
    if (builtins.ambientIdForName(name)) |id| {
        try self.builder.emitConstant(self.allocator, Value.builtin(@intFromEnum(id)));
        return true;
    }

    if (builtins.hasConstant(name)) {
        try emit.emitOp(self, .push_builtins);
        try emit.emitGetAttr(self, try self.intern.intern(name));
        return true;
    }

    return false;
}
