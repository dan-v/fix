const std = @import("std");
const compiler_mod = @import("../compiler.zig");
const ast = @import("../ast.zig");
const bytecode = @import("../bytecode.zig");
const builtins = @import("../builtins.zig");
const chunk = bytecode.chunk;
const diagnostic = @import("../diagnostic.zig");
const heap_mod = @import("../runtime/heap.zig");
const string_syntax = @import("../string_syntax.zig");
const types = @import("../runtime/types.zig");
const Value = @import("../runtime/value.zig").Value;
const OpCode = bytecode.OpCode;
const emit = @import("emit.zig");
const scope = @import("scope.zig");
const diagnostics = @import("diagnostics.zig");
const attrs = @import("attrs.zig");

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
    try self.builder.emitConstant(self.allocator, try @import("../runtime/int.zig").make(self.heap, val));
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

pub fn compileStringAtom(self: *Compiler, atom: Node.Atom) !void {
    const literal = string_syntax.Span{
        .start = atom.offset,
        .end = atom.offset + atom.len,
    };
    const parsed = try string_syntax.parseLiteral(self.allocator, self.source, literal);
    defer parsed.deinit();

    var have_value = false;
    for (parsed.parts) |part| {
        switch (part) {
            .text => |text| try emitStringPart(self, text.bytes, &have_value),
            .interpolation => |span| {
                if (!have_value) {
                    const empty_id = try self.intern.intern("");
                    try self.builder.emitConstant(self.allocator, Value.string(empty_id));
                    have_value = true;
                }
                try compileInterpolatedExpr(self, self.source[span.start..span.end], span.start);
                try emit.emitOp(self, .add_int);
                have_value = true;
            },
        }
    }

    if (!have_value) {
        const id = try self.intern.intern("");
        try self.builder.emitConstant(self.allocator, Value.string(id));
    }
}

pub fn emitStringPart(self: *Compiler, part: []const u8, have_value: *bool) !void {
    if (part.len == 0) return;

    const id = try self.intern.intern(part);
    try self.builder.emitConstant(self.allocator, Value.string(id));
    if (have_value.*) try emit.emitOp(self, .add_int);
    have_value.* = true;
}

pub fn compileInterpolatedExpr(self: *Compiler, expr_source: []const u8, source_offset: u32) !void {
    var arena = ast.AstArena.init(self.allocator);
    defer arena.deinit();

    var parser = @import("../parser.zig").Parser.init(self.allocator, &arena, expr_source);
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
