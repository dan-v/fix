//! Compiler: AST → Bytecode
//!
//! Walks the AST tree and emits bytecode into a ChunkBuilder.
//! The compiler is stack-based: expressions push their result,
//! statements push/discard as needed.

const std = @import("std");
const ast = @import("ast.zig");
const Node = ast.Node;
const NodeTag = ast.NodeTag;
const BinaryOp = ast.BinaryOp;
const OpCode = @import("opcode.zig").OpCode;
const chunk = @import("chunk.zig");
const ChunkBuilder = chunk.ChunkBuilder;
const ChunkRegistry = chunk.ChunkRegistry;
const types = @import("types.zig");
const diagnostic = @import("diagnostic.zig");
const builtins = @import("builtins.zig");
const string_syntax = @import("string_syntax.zig");
const heap_mod = @import("heap.zig");
const Diagnostic = diagnostic.Diagnostic;
const Value = @import("value.zig").Value;

const InternId = types.InternId;

/// A local variable tracked during compilation.
const Local = struct {
    name: []const u8,
    name_id: InternId,
    depth: u8,
    /// Index from frame base on the stack.
    slot: u16,
};

const Capture = struct {
    const Kind = enum { local, upvalue };

    name: []const u8,
    kind: Kind,
    index: u16,
};

const WithScope = struct {
    kind: Capture.Kind,
    index: u16,
};

const AttrEntryView = struct {
    path: []const Node.Atom,
    expr: *const Node,
    inherit_outer: bool = false,
};

const AttrEntryGroup = struct {
    first: Node.Atom,
    name: []const u8,
    name_id: InternId,
    leaf: ?AttrEntryView = null,
    duplicate_leaf: ?AttrEntryView = null,
    leaves: []AttrEntryView = &.{},
    leaf_count: usize = 0,
    first_nested: ?AttrEntryView = null,
    tails: []AttrEntryView = &.{},
    tail_count: usize = 0,
};

const AttrEntryGroups = struct {
    groups: []AttrEntryGroup = &.{},
    leaves: []AttrEntryView = &.{},
    tails: []AttrEntryView = &.{},

    fn deinit(self: *AttrEntryGroups, allocator: std.mem.Allocator) void {
        allocator.free(self.leaves);
        allocator.free(self.tails);
        for (self.groups) |group| allocator.free(group.name);
        allocator.free(self.groups);
        self.* = .{};
    }
};

const ContainerValueOptions = struct {
    raw_identifier: bool = false,
};

const with_capture_name = "\x00with";

pub const Compiler = struct {
    allocator: std.mem.Allocator,
    builder: *ChunkBuilder,
    registry: *ChunkRegistry,
    source: []const u8,
    intern: *@import("intern.zig").InternTable,
    base_path: ?[]const u8,
    source_path: ?[]const u8,
    source_file_id: ?InternId,
    locals: std.ArrayListUnmanaged(Local),
    captures: std.ArrayListUnmanaged(Capture),
    with_scopes: std.ArrayListUnmanaged(WithScope),
    diagnostics: std.ArrayListUnmanaged(Diagnostic),
    owned_diagnostic_messages: std.ArrayListUnmanaged([]u8),
    line_index: diagnostic.LineIndex,
    line_index_ready: bool,
    parent: ?*Compiler,
    skip_local_slot: ?u16,
    scope_depth: u8,
    slot_count: u16,

    pub fn init(
        allocator: std.mem.Allocator,
        builder: *ChunkBuilder,
        registry: *ChunkRegistry,
        source: []const u8,
        intern: *@import("intern.zig").InternTable,
    ) Compiler {
        return .{
            .allocator = allocator,
            .builder = builder,
            .registry = registry,
            .source = source,
            .intern = intern,
            .base_path = null,
            .source_path = null,
            .source_file_id = null,
            .locals = .empty,
            .captures = .empty,
            .with_scopes = .empty,
            .diagnostics = .empty,
            .owned_diagnostic_messages = .empty,
            .line_index = .empty,
            .line_index_ready = false,
            .parent = null,
            .skip_local_slot = null,
            .scope_depth = 0,
            .slot_count = 0,
        };
    }

    pub fn deinit(self: *Compiler) void {
        for (self.owned_diagnostic_messages.items) |message| {
            self.allocator.free(message);
        }
        self.owned_diagnostic_messages.deinit(self.allocator);
        self.with_scopes.deinit(self.allocator);
        self.captures.deinit(self.allocator);
        self.locals.deinit(self.allocator);
        self.diagnostics.deinit(self.allocator);
        if (self.parent == null and self.line_index_ready) {
            self.line_index.deinit(self.allocator);
        }
    }

    pub fn compile(self: *Compiler, node: *const Node) !void {
        try self.compileNode(node);
    }

    pub fn compileWithScope(self: *Compiler, node: *const Node, scope: ?Value) !void {
        if (scope) |scope_value| {
            try self.compileAmbientScope(node, scope_value);
        } else {
            try self.compileNode(node);
        }
    }

    fn compileAmbientScope(self: *Compiler, node: *const Node, scope_value: Value) !void {
        self.beginScope();

        const scope_slot = try self.declareLocal("", try self.intern.intern(""));
        try self.builder.emitConstant(self.allocator, scope_value);
        try self.emitSetLocal(scope_slot);
        try self.with_scopes.append(self.allocator, .{ .kind = .local, .index = scope_slot });

        try self.compileNode(node);

        _ = self.with_scopes.pop();
        self.endScope();
    }

    fn compileNode(self: *Compiler, node: *const Node) anyerror!void {
        const start = self.builder.code.items.len;
        try self.compileNodeImpl(node);
        const end = self.builder.code.items.len;
        if (try self.sourceSpanForNode(node)) |span| {
            try self.builder.addSourceMapEntry(self.allocator, start, end, span);
        }
    }

    fn compileNodeImpl(self: *Compiler, node: *const Node) anyerror!void {
        switch (node.tag) {
            .integer => try self.compileInt(node),
            .float_val => try self.compileFloat(node),
            .string => try self.compileString(node),
            .path => try self.compilePath(node),
            .search_path => try self.compileSearchPath(node),
            .identifier => try self.compileIdent(node),
            .bool_true => try self.emitOp(.push_true),
            .bool_false => try self.emitOp(.push_false),
            .null => try self.emitOp(.push_null),
            .binary_op => try self.compileBinary(node),
            .unary_op => try self.compileUnary(node),
            .apply => try self.compileApply(node),
            .lambda => try self.compileLambda(node),
            .lambda_attrs => try self.compileLambdaAttrs(node),
            .let_in => try self.compileLetIn(node),
            .if_else => try self.compileIfElse(node),
            .assert => try self.compileAssert(node),
            .with_expr => try self.compileWith(node),
            .attr_set => try self.compileAttrSet(node),
            .attr_path => try self.compileAttrPath(node),
            .attr_dynamic => try self.compileAttrDynamic(node),
            .attr_or => try self.compileAttrOr(node),
            .has_attr => try self.compileHasAttr(node),
            .has_attr_dynamic => try self.compileHasAttrDynamic(node),
            .has_attr_mixed => try self.compileHasAttrMixed(node),
            .list => try self.compileList(node),
            .parens => try self.compileNode(node.data.parens),
        }
    }

    fn sourceSpanForNode(self: *Compiler, node: *const Node) !?chunk.Chunk.SourceSpan {
        const span = nodeSourceSpan(node) orelse return null;
        const position = try self.sourcePositionForOffset(span.offset);
        return .{
            .file = try self.optionalSourceFileId(),
            .offset = span.offset,
            .len = span.len,
            .line = position.line,
            .column = position.column,
        };
    }

    fn optionalSourceFileId(self: *Compiler) !?InternId {
        if (self.source_path == null) return null;
        return try self.sourceFileId();
    }

    fn emitOp(self: *Compiler, op: OpCode) !void {
        try self.builder.writeOp(self.allocator, op);
    }

    fn emitOpU16(self: *Compiler, op: OpCode, val: u16) !void {
        try self.emitOp(op);
        try self.builder.writeU16(self.allocator, val);
    }

    fn emitOpU32(self: *Compiler, op: OpCode, val: u32) !void {
        try self.emitOp(op);
        try self.builder.writeU32(self.allocator, val);
    }

    fn emitBuildAttrs(self: *Compiler, count: u16, positions: []const heap_mod.AttrPosEntry) !void {
        if (positions.len == 0) {
            try self.emitOpU16(.build_attrs, count);
            return;
        }

        try self.emitOpU16(.build_attrs_with_pos, count);
        try self.builder.writeU16(self.allocator, @intCast(positions.len));
        for (positions) |position| {
            try self.builder.writeU32(self.allocator, position.name);
            try self.builder.writeU32(self.allocator, position.pos.file);
            try self.builder.writeU32(self.allocator, position.pos.line);
            try self.builder.writeU32(self.allocator, position.pos.column);
        }
    }

    fn emitOpByte(self: *Compiler, op: OpCode, val: u8) !void {
        try self.emitOp(op);
        try self.builder.writeByte(self.allocator, val);
    }

    fn emitLocalOp(self: *Compiler, short_op: OpCode, long_op: OpCode, slot: u16) !void {
        if (slot <= std.math.maxInt(u8)) {
            try self.emitOpByte(short_op, @intCast(slot));
        } else {
            try self.emitOpU16(long_op, slot);
        }
    }

    fn emitGetLocal(self: *Compiler, slot: u16) !void {
        try self.emitLocalOp(.get_local, .get_local_long, slot);
    }

    fn emitCaptureLocal(self: *Compiler, slot: u16) !void {
        try self.emitLocalOp(.capture_local, .capture_local_long, slot);
    }

    fn emitSetLocal(self: *Compiler, slot: u16) !void {
        try self.emitLocalOp(.set_local, .set_local_long, slot);
    }

    fn emitSetCellLocal(self: *Compiler, slot: u16) !void {
        try self.emitLocalOp(.set_cell_local, .set_cell_local_long, slot);
    }

    fn emitInternOp(self: *Compiler, short_op: OpCode, long_op: OpCode, id: InternId) !void {
        if (id <= std.math.maxInt(u16)) {
            try self.emitOpU16(short_op, @intCast(id));
        } else {
            try self.emitOp(long_op);
            try self.builder.writeU32(self.allocator, id);
        }
    }

    fn writeInternId(self: *Compiler, id: InternId, wide: bool) !void {
        if (wide) {
            try self.builder.writeU32(self.allocator, id);
        } else {
            try self.builder.writeU16(self.allocator, @intCast(id));
        }
    }

    fn emitClosure(self: *Compiler, chunk_id: types.ChunkId, upvalue_count: u16) !void {
        if (chunk_id <= std.math.maxInt(u16)) {
            try self.emitOpU16(.closure, @intCast(chunk_id));
        } else {
            try self.emitOp(.closure_long);
            try self.builder.writeU32(self.allocator, chunk_id);
        }
        try self.builder.writeU16(self.allocator, upvalue_count);
    }

    // ---- atom compilers ----

    fn compileInt(self: *Compiler, node: *const Node) !void {
        const span = self.source[node.data.atom.offset .. node.data.atom.offset + node.data.atom.len];
        const val = std.fmt.parseInt(i64, span, 10) catch 0;
        const v = @import("value.zig").Value.int(val);
        try self.builder.emitConstant(self.allocator, v);
    }

    fn compileFloat(self: *Compiler, node: *const Node) !void {
        const span = self.source[node.data.atom.offset .. node.data.atom.offset + node.data.atom.len];
        const val = std.fmt.parseFloat(f64, span) catch 0.0;
        const v = @import("value.zig").Value.float(val);
        try self.builder.emitConstant(self.allocator, v);
    }

    fn compileString(self: *Compiler, node: *const Node) !void {
        try self.compileStringAtom(node.data.atom);
    }

    fn compileStringAtom(self: *Compiler, atom: Node.Atom) !void {
        const literal = string_syntax.Span{
            .start = atom.offset,
            .end = atom.offset + atom.len,
        };
        const parsed = try string_syntax.parseLiteral(self.allocator, self.source, literal);
        defer parsed.deinit();

        var have_value = false;
        for (parsed.parts) |part| {
            switch (part) {
                .text => |text| try self.emitStringPart(text.bytes, &have_value),
                .interpolation => |span| {
                    if (!have_value) {
                        const empty_id = try self.intern.intern("");
                        try self.builder.emitConstant(self.allocator, Value.string(empty_id));
                        have_value = true;
                    }
                    try self.compileInterpolatedExpr(self.source[span.start..span.end], span.start);
                    try self.emitOp(.add_int);
                    have_value = true;
                },
            }
        }

        if (!have_value) {
            const id = try self.intern.intern("");
            try self.builder.emitConstant(self.allocator, @import("value.zig").Value.string(id));
        }
    }

    fn emitStringPart(self: *Compiler, part: []const u8, have_value: *bool) !void {
        if (part.len == 0) return;

        const id = try self.intern.intern(part);
        try self.builder.emitConstant(self.allocator, @import("value.zig").Value.string(id));
        if (have_value.*) try self.emitOp(.add_int);
        have_value.* = true;
    }

    fn compileInterpolatedExpr(self: *Compiler, expr_source: []const u8, source_offset: u32) !void {
        var arena = ast.AstArena.init(self.allocator);
        defer arena.deinit();

        var parser = @import("parser.zig").Parser.init(self.allocator, &arena, expr_source);
        defer parser.deinit();
        const expr = try parser.parse();
        offsetNode(expr, source_offset);
        try self.compileNode(expr);
    }

    fn compilePath(self: *Compiler, node: *const Node) !void {
        const span = self.source[node.data.atom.offset .. node.data.atom.offset + node.data.atom.len];
        if (std.mem.indexOf(u8, span, "${") != null) return self.compileInterpolatedPath(span, node.data.atom.offset);

        const path = try self.resolvePathLiteral(span);
        defer if (path.owned) self.allocator.free(path.text);
        const id = try self.intern.intern(path.text);
        const v = @import("value.zig").Value.path(id);
        try self.builder.emitConstant(self.allocator, v);
    }

    fn compileInterpolatedPath(self: *Compiler, span: []const u8, source_offset: u32) !void {
        var cursor: usize = 0;
        var have_value = false;

        while (std.mem.indexOf(u8, span[cursor..], "${")) |relative_start| {
            const interp_start = cursor + relative_start;
            try self.emitPathPart(span[cursor..interp_start], &have_value);

            const expr_start = interp_start + 2;
            const expr_end = string_syntax.findInterpolationEnd(span, expr_start) orelse return error.InvalidPathLiteral;
            try self.compileInterpolatedExpr(span[expr_start..expr_end], source_offset + @as(u32, @intCast(expr_start)));
            if (have_value) try self.emitOp(.add_int);
            have_value = true;
            cursor = expr_end + 1;
        }

        try self.emitPathPart(span[cursor..], &have_value);
        if (!have_value) return error.InvalidPathLiteral;
    }

    fn emitPathPart(self: *Compiler, part: []const u8, have_value: *bool) !void {
        if (part.len == 0) return;
        if (!have_value.*) {
            const path = try self.resolvePathLiteralPreserveTrailingSlash(part);
            defer if (path.owned) self.allocator.free(path.text);
            const id = try self.intern.intern(path.text);
            try self.builder.emitConstant(self.allocator, @import("value.zig").Value.path(id));
            have_value.* = true;
            return;
        }

        try self.emitStringPart(part, have_value);
    }

    fn compileSearchPath(self: *Compiler, node: *const Node) !void {
        const span = self.source[node.data.atom.offset .. node.data.atom.offset + node.data.atom.len];
        if (span.len < 2) return error.InvalidSearchPath;
        const id = try self.intern.intern(span[1 .. span.len - 1]);
        try self.emitInternOp(.find_file, .find_file_long, id);
    }

    const ResolvedPath = struct {
        text: []const u8,
        owned: bool,
    };

    fn resolvePathLiteral(self: *Compiler, span: []const u8) !ResolvedPath {
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

    fn resolvePathLiteralPreserveTrailingSlash(self: *Compiler, span: []const u8) !ResolvedPath {
        const resolved = try self.resolvePathLiteral(span);
        if (!std.mem.endsWith(u8, span, "/") or std.mem.endsWith(u8, resolved.text, "/")) return resolved;

        const text = try std.fmt.allocPrint(self.allocator, "{s}/", .{resolved.text});
        if (resolved.owned) self.allocator.free(resolved.text);
        return .{ .text = text, .owned = true };
    }

    fn compileIdent(self: *Compiler, node: *const Node) !void {
        const span = self.source[node.data.atom.offset .. node.data.atom.offset + node.data.atom.len];
        if (std.mem.eql(u8, span, "__curPos")) {
            try self.compileCurPos(node.data.atom);
        } else if (self.resolveLocal(span)) |slot| {
            try self.emitGetLocal(slot);
        } else if (try self.resolveCapture(span)) |slot| {
            try self.emitOpU16(.get_upvalue, slot);
        } else if (std.mem.eql(u8, span, "builtins")) {
            try self.emitOp(.push_builtins);
        } else if (try self.emitAmbientBuiltin(span)) {
            return;
        } else if (try self.emitWithLookup(span)) {
            return;
        } else {
            const message = try std.fmt.allocPrint(self.allocator, "undefined variable '{s}'", .{span});
            try self.owned_diagnostic_messages.append(self.allocator, message);
            try self.reportCompileError(node.data.atom.offset, node.data.atom.len, message);
            return error.UndefinedVariable;
        }
    }

    fn compileCurPos(self: *Compiler, atom: Node.Atom) !void {
        if (self.source_path == null) {
            try self.emitOp(.push_null);
            return;
        }

        const file_id = try self.intern.intern("file");
        const line_id = try self.intern.intern("line");
        const column_id = try self.intern.intern("column");
        const source_path_id = try self.sourceFileId();
        const position = try self.sourcePositionForOffset(atom.offset);

        try self.emitAttrNameId(file_id);
        try self.builder.emitConstant(self.allocator, Value.string(source_path_id));
        try self.emitAttrNameId(line_id);
        try self.builder.emitConstant(self.allocator, Value.int(position.line));
        try self.emitAttrNameId(column_id);
        try self.builder.emitConstant(self.allocator, Value.int(position.column));
        try self.emitOpU16(.build_attrs, 3);
    }

    fn emitAmbientBuiltin(self: *Compiler, name: []const u8) !bool {
        if (builtins.ambientIdForName(name)) |id| {
            try self.builder.emitConstant(self.allocator, @import("value.zig").Value.builtin(@intFromEnum(id)));
            return true;
        }

        if (builtins.hasConstant(name)) {
            try self.emitOp(.push_builtins);
            try self.emitInternOp(.get_attr, .get_attr_long, try self.intern.intern(name));
            return true;
        }

        return false;
    }

    // ---- compound compilers ----

    fn compileBinary(self: *Compiler, node: *const Node) !void {
        const bin = node.data.binary;
        switch (bin.op) {
            .and_ => return self.compileAnd(bin.left, bin.right),
            .or_ => return self.compileOr(bin.left, bin.right),
            .impl => return self.compileImpl(bin.left, bin.right),
            else => {},
        }

        try self.compileNode(bin.left);
        try self.compileNode(bin.right);

        switch (bin.op) {
            .add => try self.emitOp(if (nodeMayEvaluateToFloat(bin.left) or nodeMayEvaluateToFloat(bin.right)) .add_float else .add_int),
            .sub => try self.emitOp(if (nodeMayEvaluateToFloat(bin.left) or nodeMayEvaluateToFloat(bin.right)) .sub_float else .sub_int),
            .mul => try self.emitOp(if (nodeMayEvaluateToFloat(bin.left) or nodeMayEvaluateToFloat(bin.right)) .mul_float else .mul_int),
            .div => try self.emitOp(if (nodeMayEvaluateToFloat(bin.left) or nodeMayEvaluateToFloat(bin.right)) .div_float else .div_int),
            .eq => try self.emitOp(.eq),
            .neq => try self.emitOp(.neq),
            .lt => try self.emitOp(.lt),
            .lte => try self.emitOp(.lte),
            .gt => try self.emitOp(.gt),
            .gte => try self.emitOp(.gte),
            .and_, .or_ => unreachable,
            .update => try self.emitOp(.merge_attrs),
            .impl => unreachable,
            .concat => try self.emitOp(.concat_lists),
        }
    }

    fn compileAnd(self: *Compiler, left: *const Node, right: *const Node) !void {
        try self.compileNode(left);

        const end_jump = self.builder.code.items.len;
        try self.emitOpU32(.jump_if_false, 0);
        try self.emitOp(.pop);

        try self.compileNode(right);
        self.patchJump(end_jump, self.builder.code.items.len);
    }

    fn compileOr(self: *Compiler, left: *const Node, right: *const Node) !void {
        try self.compileNode(left);

        const false_jump = self.builder.code.items.len;
        try self.emitOpU32(.jump_if_false, 0);

        const end_jump = self.builder.code.items.len;
        try self.emitOpU32(.jump, 0);

        self.patchJump(false_jump, self.builder.code.items.len);
        try self.emitOp(.pop);

        try self.compileNode(right);
        self.patchJump(end_jump, self.builder.code.items.len);
    }

    fn compileImpl(self: *Compiler, left: *const Node, right: *const Node) !void {
        try self.compileNode(left);

        const false_jump = self.builder.code.items.len;
        try self.emitOpU32(.jump_if_false, 0);
        try self.emitOp(.pop);

        try self.compileNode(right);
        const end_jump = self.builder.code.items.len;
        try self.emitOpU32(.jump, 0);

        self.patchJump(false_jump, self.builder.code.items.len);
        try self.emitOp(.pop);
        try self.emitOp(.push_true);

        self.patchJump(end_jump, self.builder.code.items.len);
    }

    fn compileUnary(self: *Compiler, node: *const Node) !void {
        const un = node.data.unary;
        try self.compileNode(un.expr);
        switch (un.op) {
            .negate => try self.emitOp(.negate_int),
            .not => try self.emitOp(.not),
        }
    }

    fn compileApply(self: *Compiler, node: *const Node) !void {
        try self.compileApplyWithOp(node, .call);
    }

    fn compileTailExpression(self: *Compiler, node: *const Node) anyerror!void {
        const unwrapped = unwrapParens(node);
        switch (unwrapped.tag) {
            .apply, .if_else, .let_in, .assert, .with_expr => {},
            else => return self.compileNode(node),
        }

        {
            const start = self.builder.code.items.len;
            try self.compileTailNodeImpl(unwrapped);
            const end = self.builder.code.items.len;
            if (try self.sourceSpanForNode(node)) |span| {
                try self.builder.addSourceMapEntry(self.allocator, start, end, span);
            }
            return;
        }
    }

    fn compileTailNodeImpl(self: *Compiler, node: *const Node) anyerror!void {
        switch (node.tag) {
            .apply => try self.compileApplyWithOp(node, .tail_call),
            .if_else => try self.compileIfElseTail(node),
            .let_in => try self.compileLetInWithTailBody(node),
            .assert => try self.compileAssertTail(node),
            .with_expr => try self.compileWithTail(node),
            else => unreachable,
        }
    }

    fn compileApplyWithOp(self: *Compiler, node: *const Node, op: OpCode) !void {
        const ap = node.data.apply;
        try self.compileNode(ap.func);
        try self.compileContainerValue(ap.arg, .{});
        try self.emitOp(op);
    }

    fn compileLambda(self: *Compiler, node: *const Node) !void {
        const lambda = node.data.lambda;
        const param_name = self.source[lambda.param_offset .. lambda.param_offset + lambda.param_len];

        var child_builder = try ChunkBuilder.init(self.allocator);
        defer child_builder.deinit(self.allocator);

        var child = Compiler.init(
            self.allocator,
            &child_builder,
            self.registry,
            self.source,
            self.intern,
        );
        child.parent = self;
        child.base_path = self.base_path;
        child.source_path = self.source_path;
        child.source_file_id = self.source_file_id;
        defer child.deinit();

        const param_id = try self.intern.intern(param_name);
        _ = try child.declareLocal(param_name, param_id);
        child.compileTailExpression(lambda.body) catch |err| {
            try self.absorbChildDiagnostics(&child);
            return err;
        };
        try child.emitOp(.ret);
        try child.emitOp(.halt);

        const child_chunk = try child_builder.finish(self.allocator, child.slot_count);
        const child_id = try self.registry.register(child_chunk);
        try self.emitCaptures(child.captures.items);
        try self.emitClosure(child_id, try captureCount(child.captures.items.len));
    }

    fn compileLambdaAttrs(self: *Compiler, node: *const Node) !void {
        const lambda = node.data.lambda_attrs;

        var child_builder = try ChunkBuilder.init(self.allocator);
        defer child_builder.deinit(self.allocator);

        var child = Compiler.init(
            self.allocator,
            &child_builder,
            self.registry,
            self.source,
            self.intern,
        );
        child.parent = self;
        child.base_path = self.base_path;
        child.source_path = self.source_path;
        child.source_file_id = self.source_file_id;
        defer child.deinit();

        const arg_slot = try child.declareLocal("\x00args", try self.intern.intern("\x00args"));
        if (lambda.bind_name) |bind_name| {
            const name = self.source[bind_name.offset .. bind_name.offset + bind_name.len];
            const name_id = try self.intern.intern(name);
            const slot = try child.declareLocal(name, name_id);
            try child.emitCaptureLocal(arg_slot);
            try child.emitSetLocal(slot);
        }

        var wide_params = false;
        for (lambda.params) |param| {
            const name = self.source[param.name.offset .. param.name.offset + param.name.len];
            if (try self.intern.intern(name) > std.math.maxInt(u16)) wide_params = true;
        }

        try child.emitGetLocal(arg_slot);
        try child.emitOp(if (wide_params) .validate_attrs_long else .validate_attrs);
        try child.builder.writeByte(child.allocator, if (lambda.allow_extra) 1 else 0);
        try child.builder.writeU16(child.allocator, @intCast(lambda.params.len));
        var function_args: std.ArrayListUnmanaged(@import("heap.zig").AttrEntry) = .empty;
        defer function_args.deinit(self.allocator);
        try function_args.ensureTotalCapacity(self.allocator, lambda.params.len);
        for (lambda.params) |param| {
            const name = self.source[param.name.offset .. param.name.offset + param.name.len];
            const name_id = try self.intern.intern(name);
            try child.writeInternId(name_id, wide_params);
            function_args.appendAssumeCapacity(.{
                .name = name_id,
                .value = @import("value.zig").Value.boolVal(param.default != null),
            });
        }
        try child_builder.setFunctionArgs(self.allocator, function_args.items);

        for (lambda.params) |param| {
            const name = self.source[param.name.offset .. param.name.offset + param.name.len];
            const name_id = try self.intern.intern(name);
            try child.emitOp(.push_null);
            try child.emitOp(.make_cell);
            const slot = try child.declareLocal(name, name_id);
            try child.emitSetLocal(slot);
        }

        for (lambda.params) |param| {
            const name = self.source[param.name.offset .. param.name.offset + param.name.len];
            const name_id = try self.intern.intern(name);
            const slot = child.resolveLocal(name) orelse return error.UndefinedVariable;
            try child.compileAttrParamThunk(arg_slot, name_id, param.default);
            try child.emitSetCellLocal(slot);
        }

        child.compileTailExpression(lambda.body) catch |err| {
            try self.absorbChildDiagnostics(&child);
            return err;
        };
        try child.emitOp(.ret);
        try child.emitOp(.halt);

        const child_chunk = try child_builder.finish(self.allocator, child.slot_count);
        const child_id = try self.registry.register(child_chunk);
        try self.emitCaptures(child.captures.items);
        try self.emitClosure(child_id, try captureCount(child.captures.items.len));
    }

    fn compileAttrParamThunk(self: *Compiler, arg_slot: u16, name_id: InternId, default: ?*const Node) !void {
        var child_builder = try ChunkBuilder.init(self.allocator);
        defer child_builder.deinit(self.allocator);

        var child = Compiler.init(
            self.allocator,
            &child_builder,
            self.registry,
            self.source,
            self.intern,
        );
        child.parent = self;
        child.base_path = self.base_path;
        child.source_path = self.source_path;
        child.source_file_id = self.source_file_id;
        defer child.deinit();

        _ = try child.addCapture("\x00args", .local, arg_slot);
        try child.emitOpU16(.get_upvalue, 0);
        if (default) |default_expr| {
            try child.compileThunk(default_expr);
            try child.emitOp(if (name_id > std.math.maxInt(u16)) .get_attr_path_or_long else .get_attr_path_or);
            try child.builder.writeByte(child.allocator, 1);
            try child.writeInternId(name_id, name_id > std.math.maxInt(u16));
        } else {
            try child.emitInternOp(.get_attr, .get_attr_long, name_id);
        }
        try child.emitOp(.ret);
        try child.emitOp(.halt);

        const child_chunk = try child_builder.finish(self.allocator, child.slot_count);
        const child_id = try self.registry.register(child_chunk);
        try self.emitCaptures(child.captures.items);
        try self.emitClosure(child_id, try captureCount(child.captures.items.len));
        try self.emitOp(.make_thunk);
    }

    fn compileLetIn(self: *Compiler, node: *const Node) !void {
        try self.compileLetInBody(node, false);
    }

    fn compileLetInWithTailBody(self: *Compiler, node: *const Node) anyerror!void {
        try self.compileLetInBody(node, true);
    }

    fn compileLetInBody(self: *Compiler, node: *const Node, tail_body: bool) anyerror!void {
        const let_in = node.data.let_in;

        self.beginScope();

        for (let_in.bindings, 0..) |binding, index| {
            if (self.bindingRootSeen(let_in.bindings[0..index], binding.path[0])) continue;
            const name = self.attrSegmentSpan(binding.path[0]);
            const name_id = try self.intern.intern(name);
            try self.emitOp(.push_null);
            try self.emitOp(.make_cell);
            const slot = try self.declareLocal(name, name_id);
            try self.emitSetLocal(slot);
        }

        for (let_in.bindings, 0..) |binding, index| {
            if (self.bindingRootSeen(let_in.bindings[0..index], binding.path[0])) continue;
            const name = self.attrSegmentSpan(binding.path[0]);
            const slot = self.resolveLocal(name) orelse return error.UndefinedVariable;
            try self.compileLetRootBinding(let_in.bindings, binding.path[0], slot);
            try self.emitSetCellLocal(slot);
        }

        if (tail_body) {
            try self.compileTailExpression(let_in.body);
        } else {
            try self.compileNode(let_in.body);
        }

        self.endScope();
    }

    fn compileLetRootBinding(self: *Compiler, bindings: []const Node.Binding, root: Node.Atom, slot: u16) !void {
        var leaf: ?Node.Binding = null;
        var tail_count: usize = 0;

        for (bindings) |binding| {
            if (!self.attrSegmentsEqual(binding.path[0], root)) continue;
            if (binding.path.len == 1) {
                if (leaf) |previous| {
                    try self.reportCompileError(binding.name_offset, binding.name_len, "duplicate let binding");
                    try self.reportCompileNote(previous.name_offset, previous.name_len, "first binding defined here");
                    return error.DuplicateBinding;
                }
                leaf = binding;
            } else {
                tail_count += 1;
            }
        }

        if (tail_count == 0) {
            const binding = leaf orelse return error.UndefinedVariable;
            const previous_skip = self.skip_local_slot;
            if (binding.inherit_outer) self.skip_local_slot = slot;
            const compile_result = self.compileContainerValue(binding.expr, .{});
            self.skip_local_slot = previous_skip;
            return compile_result;
        }

        const tails = try self.allocator.alloc(AttrEntryView, tail_count);
        defer self.allocator.free(tails);
        var i: usize = 0;
        for (bindings) |binding| {
            if (!self.attrSegmentsEqual(binding.path[0], root) or binding.path.len == 1) continue;
            tails[i] = .{
                .path = binding.path[1..],
                .expr = binding.expr,
                .inherit_outer = binding.inherit_outer,
            };
            i += 1;
        }

        if (leaf) |root_leaf| {
            if (root_leaf.expr.tag != .attr_set) {
                try self.reportDuplicateAttribute(tails[0].path[0], root_leaf.path[0]);
                return error.DuplicateAttribute;
            }
            const leaves = [_]AttrEntryView{.{
                .path = root_leaf.path,
                .expr = root_leaf.expr,
                .inherit_outer = root_leaf.inherit_outer,
            }};
            return self.compileExtendedAttrSetLiteralThunk(&leaves, tails);
        }

        return self.compileAttrEntriesThunk(tails, true);
    }

    fn bindingRootSeen(self: *const Compiler, bindings: []const Node.Binding, root: Node.Atom) bool {
        for (bindings) |binding| {
            if (binding.path.len > 0 and self.attrSegmentsEqual(binding.path[0], root)) return true;
        }
        return false;
    }

    fn reportCompileError(self: *Compiler, offset: u32, len: u32, message: []const u8) !void {
        try self.reportDiagnostic(.err, offset, len, message);
    }

    fn reportCompileNote(self: *Compiler, offset: u32, len: u32, message: []const u8) !void {
        try self.reportDiagnostic(.note, offset, len, message);
    }

    fn reportDiagnostic(self: *Compiler, severity: Diagnostic.Severity, offset: u32, len: u32, message: []const u8) !void {
        const position = try self.sourcePositionForOffset(offset);
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

    fn absorbChildDiagnostics(self: *Compiler, child: *Compiler) !void {
        try self.diagnostics.appendSlice(self.allocator, child.diagnostics.items);
        child.diagnostics.clearRetainingCapacity();
        try self.owned_diagnostic_messages.appendSlice(self.allocator, child.owned_diagnostic_messages.items);
        child.owned_diagnostic_messages.clearRetainingCapacity();
    }

    fn compileThunk(self: *Compiler, expr: *const Node) !void {
        var child_builder = try ChunkBuilder.init(self.allocator);
        defer child_builder.deinit(self.allocator);

        var child = Compiler.init(
            self.allocator,
            &child_builder,
            self.registry,
            self.source,
            self.intern,
        );
        child.parent = self;
        child.base_path = self.base_path;
        child.source_path = self.source_path;
        child.source_file_id = self.source_file_id;
        defer child.deinit();

        child.compileNode(expr) catch |err| {
            try self.absorbChildDiagnostics(&child);
            return err;
        };
        try child.emitOp(.ret);
        try child.emitOp(.halt);

        const child_chunk = try child_builder.finish(self.allocator, child.slot_count);
        const child_id = try self.registry.register(child_chunk);
        try self.emitCaptures(child.captures.items);
        try self.emitClosure(child_id, try captureCount(child.captures.items.len));
        try self.emitOp(.make_thunk);
    }

    fn compileStringAtomThunk(self: *Compiler, atom: Node.Atom) !void {
        var node = Node{
            .tag = .string,
            .data = .{ .atom = atom },
            .span = atom,
        };
        try self.compileThunk(&node);
    }

    fn emitCaptures(self: *Compiler, captures: []const Capture) !void {
        for (captures) |capture| {
            switch (capture.kind) {
                .local => try self.emitCaptureLocal(capture.index),
                .upvalue => try self.emitOpU16(.capture_upvalue, capture.index),
            }
        }
    }

    fn compileIfElse(self: *Compiler, node: *const Node) !void {
        try self.compileIfElseBody(node, false);
    }

    fn compileIfElseTail(self: *Compiler, node: *const Node) anyerror!void {
        try self.compileIfElseBody(node, true);
    }

    fn compileIfElseBody(self: *Compiler, node: *const Node, tail_branches: bool) anyerror!void {
        const ife = node.data.if_else;

        try self.compileNode(ife.cond);

        // Emit placeholder for jump_if_false
        const jump_pos = self.builder.code.items.len;
        try self.emitOpU32(.jump_if_false, 0);
        try self.emitOp(.pop);

        if (tail_branches) {
            try self.compileTailExpression(ife.then_branch);
        } else {
            try self.compileNode(ife.then_branch);
        }
        const jump_over_pos = self.builder.code.items.len;
        try self.emitOpU32(.jump, 0);

        // Patch jump_if_false target
        self.patchJump(jump_pos, self.builder.code.items.len);

        try self.emitOp(.pop);
        if (tail_branches) {
            try self.compileTailExpression(ife.else_branch);
        } else {
            try self.compileNode(ife.else_branch);
        }

        // Patch jump (skip else)
        self.patchJump(jump_over_pos, self.builder.code.items.len);
    }

    fn compileAssert(self: *Compiler, node: *const Node) !void {
        try self.compileAssertBody(node, false);
    }

    fn compileAssertTail(self: *Compiler, node: *const Node) anyerror!void {
        try self.compileAssertBody(node, true);
    }

    fn compileAssertBody(self: *Compiler, node: *const Node, tail_body: bool) anyerror!void {
        const assert_node = node.data.assert;

        try self.compileNode(assert_node.cond);

        const fail_jump = self.builder.code.items.len;
        try self.emitOpU32(.jump_if_false, 0);
        try self.emitOp(.pop);

        if (tail_body) {
            try self.compileTailExpression(assert_node.body);
        } else {
            try self.compileNode(assert_node.body);
        }
        const end_jump = self.builder.code.items.len;
        try self.emitOpU32(.jump, 0);

        self.patchJump(fail_jump, self.builder.code.items.len);
        try self.emitOp(.pop);
        try self.emitOp(.fail_assertion);

        self.patchJump(end_jump, self.builder.code.items.len);
    }

    fn compileWith(self: *Compiler, node: *const Node) !void {
        try self.compileWithBody(node, false);
    }

    fn compileWithTail(self: *Compiler, node: *const Node) anyerror!void {
        try self.compileWithBody(node, true);
    }

    fn compileWithBody(self: *Compiler, node: *const Node, tail_body: bool) anyerror!void {
        const with_node = node.data.with_expr;

        self.beginScope();

        const scope_slot = try self.declareLocal("", try self.intern.intern(""));
        try self.compileThunk(with_node.attr_set);
        try self.emitSetLocal(scope_slot);
        try self.with_scopes.append(self.allocator, .{ .kind = .local, .index = scope_slot });

        if (tail_body) {
            try self.compileTailExpression(with_node.body);
        } else {
            try self.compileNode(with_node.body);
        }

        _ = self.with_scopes.pop();
        self.endScope();
    }

    fn compileAttrSet(self: *Compiler, node: *const Node) !void {
        const aset = node.data.attr_set;
        if (self.hasDynamicAttrEntries(aset.entries)) {
            return self.compileMixedAttrSet(aset.entries, aset.recursive);
        }

        const entries = try self.attrEntryViews(aset.entries);
        defer self.allocator.free(entries);

        try self.compileAttrEntries(entries, aset.recursive);
    }

    fn compileMixedAttrSet(self: *Compiler, entries: []const Node.AttrSetEntry, recursive: bool) !void {
        if (recursive) return self.compileMixedRecursiveAttrSet(entries);

        const static_count = self.staticAttrEntryCount(entries);
        if (static_count > 0) {
            const static_entries = try self.allocator.alloc(Node.AttrSetEntry, static_count);
            defer self.allocator.free(static_entries);

            var i: usize = 0;
            for (entries) |entry| {
                if (!self.isDynamicAttrEntry(entry)) {
                    static_entries[i] = entry;
                    i += 1;
                }
            }

            const views = try self.attrEntryViews(static_entries);
            defer self.allocator.free(views);
            try self.compileAttrEntries(views, false);
        } else {
            try self.emitOpU16(.build_attrs, 0);
        }

        for (entries) |entry| {
            if (!self.isDynamicAttrEntry(entry)) continue;
            try self.compileDynamicAttrName(entry);
            try self.compileDynamicAttrValueThunk(entry);
            try self.emitOpU16(.build_attrs, 1);
            try self.emitOp(.merge_attrs_strict);
        }
    }

    fn compileMixedRecursiveAttrSet(self: *Compiler, entries: []const Node.AttrSetEntry) !void {
        const static_count = self.staticAttrEntryCount(entries);
        const static_entries = try self.allocator.alloc(Node.AttrSetEntry, static_count);
        defer self.allocator.free(static_entries);

        var static_i: usize = 0;
        for (entries) |entry| {
            if (!self.isDynamicAttrEntry(entry)) {
                static_entries[static_i] = entry;
                static_i += 1;
            }
        }

        const views = try self.attrEntryViews(static_entries);
        defer self.allocator.free(views);

        var grouped = try self.attrEntryGroups(views);
        defer grouped.deinit(self.allocator);

        self.beginScope();
        errdefer self.endScope();

        try self.declareRecursiveAttrLocals(grouped.groups);
        try self.compileRecursiveAttrCells(grouped.groups);
        try self.emitRecursiveAttrObject(grouped.groups);

        for (entries) |entry| {
            if (!self.isDynamicAttrEntry(entry)) continue;
            try self.compileDynamicAttrName(entry);
            try self.compileDynamicAttrValueThunk(entry);
            try self.emitOpU16(.build_attrs, 1);
            try self.emitOp(.merge_attrs_strict);
        }

        self.endScope();
    }

    fn hasDynamicAttrEntries(self: *const Compiler, entries: []const Node.AttrSetEntry) bool {
        for (entries) |entry| {
            if (self.isDynamicAttrEntry(entry)) return true;
        }
        return false;
    }

    fn staticAttrEntryCount(self: *const Compiler, entries: []const Node.AttrSetEntry) usize {
        var count: usize = 0;
        for (entries) |entry| {
            if (!self.isDynamicAttrEntry(entry)) count += 1;
        }
        return count;
    }

    fn isDynamicAttrEntry(self: *const Compiler, entry: Node.AttrSetEntry) bool {
        return entry.dynamic_name != null or (entry.path.len > 0 and self.attrSegmentHasInterpolation(entry.path[0]));
    }

    fn compileDynamicAttrName(self: *Compiler, entry: Node.AttrSetEntry) !void {
        if (entry.dynamic_name) |name| return self.compileNode(name);
        if (entry.path.len > 0 and self.attrSegmentHasInterpolation(entry.path[0])) {
            return self.compileStringAtom(entry.path[0]);
        }
        return error.InvalidAttributePath;
    }

    fn compileDynamicAttrValueThunk(self: *Compiler, entry: Node.AttrSetEntry) !void {
        if (entry.tail_dynamic_name) |tail_dynamic_name| {
            const nested = [_]Node.AttrSetEntry{
                .{
                    .path = entry.path,
                    .dynamic_name = tail_dynamic_name,
                    .expr = entry.expr,
                    .inherit_outer = entry.inherit_outer,
                },
            };
            return self.compileNodeAttrEntriesThunk(&nested, false);
        }

        if (entry.dynamic_name) |_| {
            if (entry.path.len == 0) return self.compileThunk(entry.expr);

            const views = [_]AttrEntryView{
                .{ .path = entry.path, .expr = entry.expr, .inherit_outer = entry.inherit_outer },
            };
            try self.compileAttrEntriesThunk(&views, false);
            return;
        }

        if (entry.path.len > 0 and self.attrSegmentHasInterpolation(entry.path[0])) {
            if (entry.path.len == 1) return self.compileThunk(entry.expr);

            const views = [_]AttrEntryView{
                .{ .path = entry.path[1..], .expr = entry.expr, .inherit_outer = entry.inherit_outer },
            };
            try self.compileAttrEntriesThunk(&views, false);
            return;
        }

        return error.InvalidAttributePath;
    }

    fn compileNodeAttrEntriesThunk(self: *Compiler, entries: []const Node.AttrSetEntry, recursive: bool) !void {
        var child_builder = try ChunkBuilder.init(self.allocator);
        defer child_builder.deinit(self.allocator);

        var child = Compiler.init(
            self.allocator,
            &child_builder,
            self.registry,
            self.source,
            self.intern,
        );
        child.parent = self;
        child.base_path = self.base_path;
        child.source_path = self.source_path;
        child.source_file_id = self.source_file_id;
        defer child.deinit();

        child.compileMixedAttrSet(entries, recursive) catch |err| {
            try self.absorbChildDiagnostics(&child);
            return err;
        };
        try child.emitOp(.ret);
        try child.emitOp(.halt);

        const child_chunk = try child_builder.finish(self.allocator, child.slot_count);
        const child_id = try self.registry.register(child_chunk);
        try self.emitCaptures(child.captures.items);
        try self.emitClosure(child_id, try captureCount(child.captures.items.len));
        try self.emitOp(.make_thunk);
    }

    fn compileAttrEntries(self: *Compiler, entries: []const AttrEntryView, recursive: bool) anyerror!void {
        if (self.hasDynamicAttrEntryViews(entries)) {
            return self.compileMixedAttrEntryViews(entries, recursive);
        }

        if (recursive) {
            try self.compileRecursiveAttrEntries(entries);
        } else {
            try self.compilePlainAttrEntries(entries);
        }
    }

    fn compileMixedAttrEntryViews(self: *Compiler, entries: []const AttrEntryView, recursive: bool) !void {
        if (recursive) return self.compileMixedRecursiveAttrEntryViews(entries);

        const static_count = self.staticAttrEntryViewCount(entries);
        if (static_count > 0) {
            const static_entries = try self.allocator.alloc(AttrEntryView, static_count);
            defer self.allocator.free(static_entries);

            var i: usize = 0;
            for (entries) |entry| {
                if (!self.isDynamicAttrEntryView(entry)) {
                    static_entries[i] = entry;
                    i += 1;
                }
            }

            try self.compileAttrEntries(static_entries, false);
        } else {
            try self.emitOpU16(.build_attrs, 0);
        }

        for (entries) |entry| {
            if (!self.isDynamicAttrEntryView(entry)) continue;
            try self.compileDynamicAttrViewName(entry);
            try self.compileDynamicAttrViewValueThunk(entry);
            try self.emitOpU16(.build_attrs, 1);
            try self.emitOp(.merge_attrs_strict);
        }
    }

    fn compileMixedRecursiveAttrEntryViews(self: *Compiler, entries: []const AttrEntryView) !void {
        const static_count = self.staticAttrEntryViewCount(entries);
        const static_entries = try self.allocator.alloc(AttrEntryView, static_count);
        defer self.allocator.free(static_entries);

        var static_i: usize = 0;
        for (entries) |entry| {
            if (!self.isDynamicAttrEntryView(entry)) {
                static_entries[static_i] = entry;
                static_i += 1;
            }
        }

        var grouped = try self.attrEntryGroups(static_entries);
        defer grouped.deinit(self.allocator);

        self.beginScope();
        errdefer self.endScope();

        try self.declareRecursiveAttrLocals(grouped.groups);
        try self.compileRecursiveAttrCells(grouped.groups);
        try self.emitRecursiveAttrObject(grouped.groups);

        for (entries) |entry| {
            if (!self.isDynamicAttrEntryView(entry)) continue;
            try self.compileDynamicAttrViewName(entry);
            try self.compileDynamicAttrViewValueThunk(entry);
            try self.emitOpU16(.build_attrs, 1);
            try self.emitOp(.merge_attrs_strict);
        }

        self.endScope();
    }

    fn hasDynamicAttrEntryViews(self: *const Compiler, entries: []const AttrEntryView) bool {
        for (entries) |entry| {
            if (self.isDynamicAttrEntryView(entry)) return true;
        }
        return false;
    }

    fn staticAttrEntryViewCount(self: *const Compiler, entries: []const AttrEntryView) usize {
        var count: usize = 0;
        for (entries) |entry| {
            if (!self.isDynamicAttrEntryView(entry)) count += 1;
        }
        return count;
    }

    fn isDynamicAttrEntryView(self: *const Compiler, entry: AttrEntryView) bool {
        return entry.path.len > 0 and self.attrSegmentHasInterpolation(entry.path[0]);
    }

    fn compileDynamicAttrViewName(self: *Compiler, entry: AttrEntryView) !void {
        if (entry.path.len > 0 and self.attrSegmentHasInterpolation(entry.path[0])) {
            return self.compileStringAtom(entry.path[0]);
        }
        return error.InvalidAttributePath;
    }

    fn compileDynamicAttrViewValueThunk(self: *Compiler, entry: AttrEntryView) !void {
        if (entry.path.len == 1) return self.compileThunk(entry.expr);

        const views = [_]AttrEntryView{
            .{
                .path = entry.path[1..],
                .expr = entry.expr,
                .inherit_outer = entry.inherit_outer,
            },
        };
        try self.compileAttrEntriesThunk(&views, false);
    }

    fn compilePlainAttrEntries(self: *Compiler, entries: []const AttrEntryView) anyerror!void {
        var grouped = try self.attrEntryGroups(entries);
        defer grouped.deinit(self.allocator);

        var positions: std.ArrayListUnmanaged(heap_mod.AttrPosEntry) = .empty;
        defer positions.deinit(self.allocator);

        for (grouped.groups) |group| {
            try self.compilePlainAttrGroup(&positions, group);
        }

        try self.emitBuildAttrs(@intCast(grouped.groups.len), positions.items);
    }

    fn compileRecursiveAttrEntries(self: *Compiler, entries: []const AttrEntryView) anyerror!void {
        var grouped = try self.attrEntryGroups(entries);
        defer grouped.deinit(self.allocator);

        self.beginScope();
        errdefer self.endScope();

        try self.declareRecursiveAttrLocals(grouped.groups);
        try self.compileRecursiveAttrCells(grouped.groups);
        try self.emitRecursiveAttrObject(grouped.groups);
        self.endScope();
    }

    fn compilePlainAttrGroup(
        self: *Compiler,
        positions: *std.ArrayListUnmanaged(heap_mod.AttrPosEntry),
        group: AttrEntryGroup,
    ) anyerror!void {
        const leaf = group.leaf;
        if (leaf == null) {
            try self.emitAttrNameId(group.name_id);
            try self.compileAttrEntriesThunk(group.tails, false);
            try self.appendAttrPosition(positions, group.first, group.name_id);
            return;
        }

        if (group.leaf_count > 1 or group.tails.len > 0) {
            const duplicate = if (leaf.?.expr.tag != .attr_set)
                group.duplicate_leaf orelse group.first_nested
            else
                self.nonAttrSetDuplicateLeaf(group);
            if (duplicate) |entry| {
                try self.reportDuplicateAttribute(entry.path[0], leaf.?.path[0]);
                return error.DuplicateAttribute;
            }
            try self.emitAttrNameId(group.name_id);
            try self.compileExtendedAttrSetLiteralThunk(group.leaves, group.tails);
            try self.appendAttrPosition(positions, group.first, group.name_id);
            return;
        }

        try self.emitAttrNameId(group.name_id);
        try self.compileContainerValue(leaf.?.expr, .{ .raw_identifier = true });
        try self.appendAttrPosition(positions, group.first, group.name_id);
    }

    fn declareRecursiveAttrLocals(self: *Compiler, groups: []const AttrEntryGroup) anyerror!void {
        for (groups) |group| {
            try self.emitOp(.push_null);
            try self.emitOp(.make_cell);
            const slot = try self.declareLocal(group.name, group.name_id);
            try self.emitSetLocal(slot);
        }
    }

    fn compileRecursiveAttrCells(self: *Compiler, groups: []const AttrEntryGroup) anyerror!void {
        for (groups) |group| {
            const slot = self.resolveLocalId(group.name_id) orelse return error.UndefinedVariable;
            const leaf = group.leaf;
            if (leaf == null) {
                try self.compileAttrEntriesThunk(group.tails, false);
                try self.emitSetCellLocal(slot);
                continue;
            }

            if (group.leaf_count > 1 or group.tails.len > 0) {
                const duplicate = if (leaf.?.expr.tag != .attr_set)
                    group.duplicate_leaf orelse group.first_nested
                else
                    self.nonAttrSetDuplicateLeaf(group);
                if (duplicate) |entry| {
                    try self.reportDuplicateAttribute(entry.path[0], leaf.?.path[0]);
                    return error.DuplicateAttribute;
                }
                try self.compileExtendedAttrSetLiteralThunk(group.leaves, group.tails);
                try self.emitSetCellLocal(slot);
                continue;
            }
            const previous_skip = self.skip_local_slot;
            if (leaf.?.inherit_outer) self.skip_local_slot = slot;
            const compile_result = self.compileContainerValue(leaf.?.expr, .{});
            self.skip_local_slot = previous_skip;
            try compile_result;
            try self.emitSetCellLocal(slot);
        }
    }

    fn emitRecursiveAttrObject(self: *Compiler, groups: []const AttrEntryGroup) anyerror!void {
        var positions: std.ArrayListUnmanaged(heap_mod.AttrPosEntry) = .empty;
        defer positions.deinit(self.allocator);

        for (groups) |group| {
            try self.emitAttrNameId(group.name_id);

            const slot = self.resolveLocalId(group.name_id) orelse return error.UndefinedVariable;
            try self.emitCaptureLocal(slot);
            try self.appendAttrPosition(&positions, group.first, group.name_id);
        }

        try self.emitBuildAttrs(@intCast(groups.len), positions.items);
    }

    fn compileExtendedAttrSetLiteralThunk(self: *Compiler, leaves: []const AttrEntryView, tails: []const AttrEntryView) !void {
        std.debug.assert(leaves.len > 0);
        std.debug.assert(leaves[0].expr.tag == .attr_set);
        const first_attr_set = leaves[0].expr.data.attr_set;

        var merged_count: usize = tails.len;
        for (leaves) |leaf| {
            std.debug.assert(leaf.expr.tag == .attr_set);
            merged_count += leaf.expr.data.attr_set.entries.len;
        }

        const merged = try self.allocator.alloc(Node.AttrSetEntry, merged_count);
        defer self.allocator.free(merged);

        var index: usize = 0;
        for (leaves) |leaf| {
            const attr_set = leaf.expr.data.attr_set;
            @memcpy(merged[index .. index + attr_set.entries.len], attr_set.entries);
            index += attr_set.entries.len;
        }
        for (tails, merged[index..]) |tail, *entry| {
            entry.* = .{
                .path = @constCast(tail.path),
                .expr = @constCast(tail.expr),
                .inherit_outer = tail.inherit_outer,
            };
        }

        try self.compileNodeAttrEntriesThunk(merged, first_attr_set.recursive);
    }

    fn nonAttrSetDuplicateLeaf(self: *Compiler, group: AttrEntryGroup) ?AttrEntryView {
        _ = self;
        if (group.leaves.len <= 1) return null;
        for (group.leaves[1..]) |leaf| {
            if (leaf.expr.tag != .attr_set) return leaf;
        }
        return null;
    }

    fn compileAttrEntriesThunk(self: *Compiler, entries: []const AttrEntryView, recursive: bool) anyerror!void {
        var child_builder = try ChunkBuilder.init(self.allocator);
        defer child_builder.deinit(self.allocator);

        var child = Compiler.init(
            self.allocator,
            &child_builder,
            self.registry,
            self.source,
            self.intern,
        );
        child.parent = self;
        child.base_path = self.base_path;
        child.source_path = self.source_path;
        child.source_file_id = self.source_file_id;
        defer child.deinit();

        child.compileAttrEntries(entries, recursive) catch |err| {
            try self.absorbChildDiagnostics(&child);
            return err;
        };
        try child.emitOp(.ret);
        try child.emitOp(.halt);

        const child_chunk = try child_builder.finish(self.allocator, child.slot_count);
        const child_id = try self.registry.register(child_chunk);
        try self.emitCaptures(child.captures.items);
        try self.emitClosure(child_id, try captureCount(child.captures.items.len));
        try self.emitOp(.make_thunk);
    }

    fn attrEntryViews(self: *Compiler, entries: []const Node.AttrSetEntry) ![]AttrEntryView {
        const views = try self.allocator.alloc(AttrEntryView, entries.len);
        for (entries, views) |entry, *view| {
            std.debug.assert(entry.dynamic_name == null);
            view.* = .{ .path = entry.path, .expr = entry.expr, .inherit_outer = entry.inherit_outer };
        }
        return views;
    }

    fn attrEntryGroups(self: *Compiler, entries: []const AttrEntryView) !AttrEntryGroups {
        var group_index: std.AutoHashMapUnmanaged(InternId, usize) = .empty;
        defer group_index.deinit(self.allocator);

        var groups_list: std.ArrayListUnmanaged(AttrEntryGroup) = .empty;
        var groups_list_owned = true;
        errdefer if (groups_list_owned) {
            for (groups_list.items) |group| self.allocator.free(group.name);
            groups_list.deinit(self.allocator);
        };

        var total_leaves: usize = 0;
        var total_tails: usize = 0;
        for (entries) |entry| {
            if (entry.path.len == 0) return error.InvalidAttributePath;

            var name: ?[]u8 = try self.attrSegmentNameAlloc(entry.path[0]);
            errdefer if (name) |owned| self.allocator.free(owned);
            const name_id = try self.intern.intern(name.?);
            const index = group_index.get(name_id) orelse blk: {
                const new_index = groups_list.items.len;
                try group_index.put(self.allocator, name_id, new_index);
                try groups_list.append(self.allocator, .{
                    .first = entry.path[0],
                    .name = name.?,
                    .name_id = name_id,
                });
                name = null;
                break :blk new_index;
            };
            if (name) |owned| {
                self.allocator.free(owned);
                name = null;
            }

            const group = &groups_list.items[index];
            if (entry.path.len == 1) {
                group.leaf_count += 1;
                total_leaves += 1;
                if (group.leaf == null) {
                    group.leaf = entry;
                } else if (group.duplicate_leaf == null) {
                    group.duplicate_leaf = entry;
                }
            } else {
                if (group.first_nested == null) group.first_nested = entry;
                group.tail_count += 1;
                total_tails += 1;
            }
        }

        var groups = try groups_list.toOwnedSlice(self.allocator);
        groups_list_owned = false;
        errdefer {
            for (groups) |group| self.allocator.free(group.name);
            self.allocator.free(groups);
        }

        const leaves = try self.allocator.alloc(AttrEntryView, total_leaves);
        errdefer self.allocator.free(leaves);
        const tails = try self.allocator.alloc(AttrEntryView, total_tails);
        errdefer self.allocator.free(tails);

        var leaf_start: usize = 0;
        for (groups) |*group| {
            const leaf_end = leaf_start + group.leaf_count;
            group.leaves = leaves[leaf_start..leaf_end];
            group.leaf_count = 0;
            leaf_start = leaf_end;
        }

        var tail_start: usize = 0;
        for (groups) |*group| {
            const tail_end = tail_start + group.tail_count;
            group.tails = tails[tail_start..tail_end];
            group.tail_count = 0;
            tail_start = tail_end;
        }

        for (entries) |entry| {
            const name_id = try self.attrSegmentNameId(entry.path[0]);
            const index = group_index.get(name_id).?;
            const group = &groups[index];
            if (entry.path.len == 1) {
                group.leaves[group.leaf_count] = entry;
                group.leaf_count += 1;
                continue;
            }
            group.tails[group.tail_count] = .{
                .path = entry.path[1..],
                .expr = entry.expr,
                .inherit_outer = entry.inherit_outer,
            };
            group.tail_count += 1;
        }

        return .{ .groups = groups, .leaves = leaves, .tails = tails };
    }

    fn reportDuplicateAttribute(self: *Compiler, duplicate: Node.Atom, original: Node.Atom) !void {
        try self.reportCompileError(duplicate.offset, duplicate.len, "duplicate attribute");
        try self.reportCompileNote(original.offset, original.len, "first attribute defined here");
    }

    fn attrSegmentsEqual(self: *const Compiler, a: Node.Atom, b: Node.Atom) bool {
        return std.mem.eql(u8, self.attrSegmentSpan(a), self.attrSegmentSpan(b));
    }

    fn emitAttrNameId(self: *Compiler, name_id: InternId) !void {
        const name_val = @import("value.zig").Value.string(name_id);
        try self.builder.emitConstant(self.allocator, name_val);
    }

    fn appendAttrPosition(
        self: *Compiler,
        positions: *std.ArrayListUnmanaged(heap_mod.AttrPosEntry),
        atom: Node.Atom,
        name_id: InternId,
    ) !void {
        _ = self.source_path orelse return;
        const position = try self.sourcePositionForOffset(atom.offset);
        try positions.append(self.allocator, .{
            .name = name_id,
            .pos = .{
                .file = try self.sourceFileId(),
                .line = position.line,
                .column = position.column,
            },
        });
    }

    fn sourceFileId(self: *Compiler) !InternId {
        if (self.source_file_id) |id| return id;
        const path = self.source_path orelse return error.MissingSourcePath;
        const id = try self.intern.intern(path);
        self.source_file_id = id;
        return id;
    }

    fn compileAttrPath(self: *Compiler, node: *const Node) !void {
        const apath = node.data.attr_path;
        try self.compileNode(apath.root);

        for (apath.segments) |seg| {
            if (self.attrSegmentHasInterpolation(seg)) {
                try self.compileStringAtom(seg);
                try self.emitOp(.get_attr_dynamic);
            } else {
                const name_id = try self.attrSegmentNameId(seg);
                try self.emitInternOp(.get_attr, .get_attr_long, name_id);
            }
        }
    }

    fn compileAttrDynamic(self: *Compiler, node: *const Node) !void {
        const dynamic = node.data.attr_dynamic;
        try self.compileNode(dynamic.root);
        try self.compileNode(dynamic.name);
        try self.emitOp(.get_attr_dynamic);
    }

    fn compileAttrOr(self: *Compiler, node: *const Node) !void {
        const attr_or = node.data.attr_or;
        if (attr_or.attr_path.tag == .attr_dynamic) {
            const dynamic = attr_or.attr_path.data.attr_dynamic;
            if (dynamic.root.tag == .attr_path) {
                const root_path = dynamic.root.data.attr_path;
                try self.compileNode(root_path.root);
                try self.compileThunk(dynamic.name);
                try self.compileThunk(attr_or.default);
                var wide = false;
                for (root_path.segments) |seg| {
                    if (try self.attrSegmentNameId(seg) > std.math.maxInt(u16)) wide = true;
                }
                try self.emitOp(if (wide) .get_attr_path_dynamic_or_long else .get_attr_path_dynamic_or);
                try self.builder.writeByte(self.allocator, @intCast(root_path.segments.len));
                for (root_path.segments) |seg| {
                    const name_id = try self.attrSegmentNameId(seg);
                    try self.writeInternId(name_id, wide);
                }
                return;
            }
            try self.compileNode(dynamic.root);
            try self.compileThunk(dynamic.name);
            try self.compileThunk(attr_or.default);
            try self.emitOp(.get_attr_dynamic_or);
            return;
        }

        const apath = attr_or.attr_path.data.attr_path;
        if (self.attrPathHasInterpolation(apath)) {
            try self.compileNode(apath.root);
            var dynamic_count: usize = 0;
            for (apath.segments) |seg| {
                if (self.attrSegmentHasInterpolation(seg)) {
                    try self.compileStringAtomThunk(seg);
                    dynamic_count += 1;
                }
            }
            try self.compileThunk(attr_or.default);
            try self.emitOp(.get_attr_path_mixed_or);
            try self.builder.writeByte(self.allocator, @intCast(apath.segments.len));
            try self.builder.writeByte(self.allocator, @intCast(dynamic_count));
            for (apath.segments) |seg| {
                if (self.attrSegmentHasInterpolation(seg)) {
                    try self.builder.writeByte(self.allocator, 1);
                } else {
                    try self.builder.writeByte(self.allocator, 0);
                    try self.builder.writeU32(self.allocator, try self.attrSegmentNameId(seg));
                }
            }
            return;
        }

        try self.compileNode(apath.root);
        try self.compileThunk(attr_or.default);
        var wide = false;
        for (apath.segments) |seg| {
            if (try self.attrSegmentNameId(seg) > std.math.maxInt(u16)) wide = true;
        }
        try self.emitOp(if (wide) .get_attr_path_or_long else .get_attr_path_or);
        try self.builder.writeByte(self.allocator, @intCast(apath.segments.len));
        for (apath.segments) |seg| {
            const name_id = try self.attrSegmentNameId(seg);
            try self.writeInternId(name_id, wide);
        }
    }

    fn attrPathHasInterpolation(self: *Compiler, path: Node.AttrPath) bool {
        for (path.segments) |seg| {
            if (self.attrSegmentHasInterpolation(seg)) return true;
        }
        return false;
    }

    fn compileHasAttr(self: *Compiler, node: *const Node) !void {
        const has_attr = node.data.has_attr;
        try self.compileNode(has_attr.root);
        if (self.hasAttrSegmentsHaveInterpolation(has_attr.segments)) {
            var dynamic_count: usize = 0;
            for (has_attr.segments) |seg| {
                if (self.attrSegmentHasInterpolation(seg)) {
                    try self.compileStringAtomThunk(seg);
                    dynamic_count += 1;
                }
            }
            try self.emitOp(.has_attr_path_mixed);
            try self.builder.writeByte(self.allocator, @intCast(has_attr.segments.len));
            try self.builder.writeByte(self.allocator, @intCast(dynamic_count));
            for (has_attr.segments) |seg| {
                if (self.attrSegmentHasInterpolation(seg)) {
                    try self.builder.writeByte(self.allocator, 1);
                } else {
                    try self.builder.writeByte(self.allocator, 0);
                    try self.builder.writeU32(self.allocator, try self.attrSegmentNameId(seg));
                }
            }
            return;
        }

        var wide = false;
        for (has_attr.segments) |seg| {
            if (try self.attrSegmentNameId(seg) > std.math.maxInt(u16)) wide = true;
        }
        try self.emitOp(if (wide) .has_attr_path_long else .has_attr_path);
        try self.builder.writeByte(self.allocator, @intCast(has_attr.segments.len));
        for (has_attr.segments) |seg| {
            const name_id = try self.attrSegmentNameId(seg);
            try self.writeInternId(name_id, wide);
        }
    }

    fn compileHasAttrDynamic(self: *Compiler, node: *const Node) !void {
        const dynamic = node.data.has_attr_dynamic;
        try self.compileNode(dynamic.root);
        try self.compileNode(dynamic.name);
        try self.emitOp(.has_attr_dynamic);
    }

    fn compileHasAttrMixed(self: *Compiler, node: *const Node) !void {
        const has_attr = node.data.has_attr_mixed;
        try self.compileNode(has_attr.root);
        var dynamic_count: usize = 0;
        for (has_attr.segments) |segment| {
            switch (segment) {
                .static => |atom| {
                    if (self.attrSegmentHasInterpolation(atom)) {
                        try self.compileStringAtomThunk(atom);
                        dynamic_count += 1;
                    }
                },
                .dynamic => |name| {
                    try self.compileThunk(name);
                    dynamic_count += 1;
                },
            }
        }

        try self.emitOp(.has_attr_path_mixed);
        try self.builder.writeByte(self.allocator, @intCast(has_attr.segments.len));
        try self.builder.writeByte(self.allocator, @intCast(dynamic_count));
        for (has_attr.segments) |segment| {
            switch (segment) {
                .static => |atom| {
                    if (self.attrSegmentHasInterpolation(atom)) {
                        try self.builder.writeByte(self.allocator, 1);
                    } else {
                        try self.builder.writeByte(self.allocator, 0);
                        try self.builder.writeU32(self.allocator, try self.attrSegmentNameId(atom));
                    }
                },
                .dynamic => try self.builder.writeByte(self.allocator, 1),
            }
        }
    }

    fn hasAttrSegmentsHaveInterpolation(self: *Compiler, segments: []const Node.Atom) bool {
        for (segments) |segment| {
            if (self.attrSegmentHasInterpolation(segment)) return true;
        }
        return false;
    }

    fn compileList(self: *Compiler, node: *const Node) !void {
        const list = node.data.list;
        for (list.items) |item| {
            try self.compileContainerValue(item, .{ .raw_identifier = true });
        }
        try self.emitOpU16(.build_list, @intCast(list.items.len));
    }

    fn compileContainerValue(self: *Compiler, node: *const Node, options: ContainerValueOptions) !void {
        if (try self.compileImmediateContainerValue(node, options)) return;
        try self.compileThunk(node);
    }

    fn compileImmediateContainerValue(self: *Compiler, node: *const Node, options: ContainerValueOptions) !bool {
        const unwrapped = unwrapParens(node);
        switch (unwrapped.tag) {
            .integer => try self.compileInt(unwrapped),
            .float_val => try self.compileFloat(unwrapped),
            .string => {
                if (self.stringHasInterpolation(unwrapped)) return false;
                try self.compileString(unwrapped);
            },
            .path => {
                if (self.pathHasInterpolation(unwrapped)) return false;
                try self.compilePath(unwrapped);
            },
            .bool_true => try self.emitOp(.push_true),
            .bool_false => try self.emitOp(.push_false),
            .null => try self.emitOp(.push_null),
            .list => {
                if (unwrapped.data.list.items.len != 0) return false;
                try self.emitOpU16(.build_list, 0);
            },
            .identifier => {
                if (!options.raw_identifier) return false;
                if (!try self.compileRawIdent(unwrapped)) return false;
            },
            else => return false,
        }
        return true;
    }

    fn compileRawIdent(self: *Compiler, node: *const Node) !bool {
        const span = self.source[node.data.atom.offset .. node.data.atom.offset + node.data.atom.len];
        if (self.resolveLocal(span)) |slot| {
            try self.emitCaptureLocal(slot);
            return true;
        }
        if (try self.resolveCapture(span)) |slot| {
            try self.emitOpU16(.capture_upvalue, slot);
            return true;
        }
        return false;
    }

    fn stringHasInterpolation(self: *Compiler, node: *const Node) bool {
        const atom = node.data.atom;
        const span = self.source[atom.offset .. atom.offset + atom.len];
        return std.mem.indexOf(u8, span, "${") != null;
    }

    fn pathHasInterpolation(self: *Compiler, node: *const Node) bool {
        const atom = node.data.atom;
        const span = self.source[atom.offset .. atom.offset + atom.len];
        return std.mem.indexOf(u8, span, "${") != null;
    }

    fn emitWithLookup(self: *Compiler, name: []const u8) !bool {
        var scopes: std.ArrayListUnmanaged(WithScope) = .empty;
        defer scopes.deinit(self.allocator);

        try self.collectWithScopes(&scopes);
        if (scopes.items.len == 0) return false;
        if (scopes.items.len > std.math.maxInt(u8)) return error.TooManyWithScopes;

        for (scopes.items) |scope| {
            switch (scope.kind) {
                .local => try self.emitCaptureLocal(scope.index),
                .upvalue => try self.emitOpU16(.capture_upvalue, scope.index),
            }
        }

        const name_id = try self.intern.intern(name);
        try self.emitInternOp(.lookup_with, .lookup_with_long, name_id);
        try self.builder.writeByte(self.allocator, @intCast(scopes.items.len));
        return true;
    }

    fn collectWithScopes(self: *Compiler, scopes: *std.ArrayListUnmanaged(WithScope)) !void {
        var i: usize = self.with_scopes.items.len;
        while (i > 0) {
            i -= 1;
            try scopes.append(self.allocator, self.with_scopes.items[i]);
        }

        const parent = self.parent orelse return;
        var parent_scopes: std.ArrayListUnmanaged(WithScope) = .empty;
        defer parent_scopes.deinit(self.allocator);

        try parent.collectWithScopes(&parent_scopes);
        for (parent_scopes.items) |scope| {
            const capture_slot = try self.addCapture(with_capture_name, scope.kind, scope.index);
            try scopes.append(self.allocator, .{ .kind = .upvalue, .index = capture_slot });
        }
    }

    // ---- patch helpers ----

    fn patchJump(self: *Compiler, instruction_offset: usize, target_offset: usize) void {
        const operand_offset = instruction_offset + 1;
        const next_instruction = instruction_offset + 5;
        const relative: u32 = @intCast(target_offset - next_instruction);
        self.builder.code.items[operand_offset] = @truncate(relative);
        self.builder.code.items[operand_offset + 1] = @truncate(relative >> 8);
        self.builder.code.items[operand_offset + 2] = @truncate(relative >> 16);
        self.builder.code.items[operand_offset + 3] = @truncate(relative >> 24);
    }

    fn attrSegmentSpan(self: *const Compiler, atom: Node.Atom) []const u8 {
        const span = self.source[atom.offset .. atom.offset + atom.len];
        if (span.len >= 2 and span[0] == '"' and span[span.len - 1] == '"') {
            return span[1 .. span.len - 1];
        }
        return span;
    }

    fn attrSegmentNameId(self: *Compiler, atom: Node.Atom) !InternId {
        const name = try self.attrSegmentNameAlloc(atom);
        defer self.allocator.free(name);
        return self.intern.intern(name);
    }

    fn attrSegmentNameAlloc(self: *Compiler, atom: Node.Atom) ![]u8 {
        const span = self.source[atom.offset .. atom.offset + atom.len];
        if (string_syntax.kindAt(self.source, atom.offset) == null) {
            return self.allocator.dupe(u8, span);
        }

        const parsed = try string_syntax.parseLiteral(self.allocator, self.source, .{
            .start = atom.offset,
            .end = atom.offset + atom.len,
        });
        defer parsed.deinit();

        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(self.allocator);

        for (parsed.parts) |part| {
            switch (part) {
                .text => |text| try out.appendSlice(self.allocator, text.bytes),
                .interpolation => return error.InvalidAttributePath,
            }
        }

        return out.toOwnedSlice(self.allocator);
    }

    fn attrSegmentHasInterpolation(self: *const Compiler, atom: Node.Atom) bool {
        const span = self.source[atom.offset .. atom.offset + atom.len];
        return string_syntax.kindAt(self.source, atom.offset) != null and std.mem.indexOf(u8, span, "${") != null;
    }

    // ---- scope management ----

    fn beginScope(self: *Compiler) void {
        self.scope_depth += 1;
    }

    fn endScope(self: *Compiler) void {
        self.scope_depth -= 1;
        // Pop locals defined in this scope.
        while (self.locals.items.len > 0) {
            const local = self.locals.items[self.locals.items.len - 1];
            if (local.depth <= self.scope_depth) break;
            _ = self.locals.pop();
        }
    }

    fn declareLocal(self: *Compiler, name: []const u8, name_id: InternId) !u16 {
        const slot = self.slot_count;
        self.slot_count += 1;
        errdefer self.slot_count -= 1;
        try self.locals.append(self.allocator, .{
            .name = name,
            .name_id = name_id,
            .depth = self.scope_depth,
            .slot = slot,
        });
        return slot;
    }

    fn resolveLocal(self: *const Compiler, name: []const u8) ?u16 {
        var i: usize = self.locals.items.len;
        while (i > 0) {
            i -= 1;
            const local = self.locals.items[i];
            if (self.skip_local_slot) |skip| {
                if (local.slot == skip) continue;
            }
            if (std.mem.eql(u8, local.name, name)) {
                return local.slot;
            }
        }
        return null;
    }

    fn resolveLocalId(self: *const Compiler, name_id: InternId) ?u16 {
        var i: usize = self.locals.items.len;
        while (i > 0) {
            i -= 1;
            const local = self.locals.items[i];
            if (self.skip_local_slot) |skip| {
                if (local.slot == skip) continue;
            }
            if (local.name_id == name_id) return local.slot;
        }
        return null;
    }

    fn resolveCapture(self: *Compiler, name: []const u8) !?u16 {
        const parent = self.parent orelse return null;
        if (parent.resolveLocal(name)) |parent_slot| {
            return try self.addCapture(name, .local, parent_slot);
        }
        if (try parent.resolveCapture(name)) |parent_upvalue| {
            return try self.addCapture(name, .upvalue, parent_upvalue);
        }
        return null;
    }

    fn addCapture(self: *Compiler, name: []const u8, kind: Capture.Kind, capture_index: u16) !u16 {
        for (self.captures.items, 0..) |capture, existing_index| {
            if (capture.kind == kind and capture.index == capture_index and std.mem.eql(u8, capture.name, name)) {
                return @intCast(existing_index);
            }
        }

        if (self.captures.items.len > std.math.maxInt(u16)) return error.TooManyCaptures;
        try self.captures.append(self.allocator, .{
            .name = name,
            .kind = kind,
            .index = capture_index,
        });
        return @intCast(self.captures.items.len - 1);
    }

    fn sourcePositionForOffset(self: *Compiler, offset: u32) !diagnostic.SourcePosition {
        const index = try self.ensureLineIndex();
        return index.positionForOffset(offset);
    }

    fn ensureLineIndex(self: *Compiler) !*const diagnostic.LineIndex {
        if (self.parent) |parent| return parent.ensureLineIndex();
        if (!self.line_index_ready) {
            self.line_index = try diagnostic.LineIndex.init(self.allocator, self.source);
            self.line_index_ready = true;
        }
        return &self.line_index;
    }
};

fn captureCount(count: usize) !u16 {
    if (count > std.math.maxInt(u16)) return error.TooManyCaptures;
    return @intCast(count);
}

fn nodeMayEvaluateToFloat(node: *const Node) bool {
    return switch (node.tag) {
        .float_val => true,
        .parens => nodeMayEvaluateToFloat(node.data.parens),
        .unary_op => nodeMayEvaluateToFloat(node.data.unary.expr),
        .binary_op => switch (node.data.binary.op) {
            .add, .sub, .mul, .div => nodeMayEvaluateToFloat(node.data.binary.left) or
                nodeMayEvaluateToFloat(node.data.binary.right),
            else => false,
        },
        else => false,
    };
}

fn nodeSourceSpan(node: *const Node) ?Node.Atom {
    return node.span;
}

fn unwrapParens(node: *const Node) *const Node {
    var current = node;
    while (current.tag == .parens) current = current.data.parens;
    return current;
}

fn offsetNode(node: *Node, offset: u32) void {
    if (node.span) |*span| span.offset += offset;
    switch (node.tag) {
        .integer, .float_val, .string, .path, .search_path, .identifier, .bool_true, .bool_false, .null => {
            node.data.atom.offset += offset;
        },
        .unary_op => offsetNode(node.data.unary.expr, offset),
        .binary_op => {
            offsetNode(node.data.binary.left, offset);
            offsetNode(node.data.binary.right, offset);
        },
        .apply => {
            offsetNode(node.data.apply.func, offset);
            offsetNode(node.data.apply.arg, offset);
        },
        .lambda => {
            node.data.lambda.param_offset += offset;
            offsetNode(node.data.lambda.body, offset);
        },
        .lambda_attrs => {
            if (node.data.lambda_attrs.bind_name) |*bind_name| {
                bind_name.offset += offset;
            }
            for (node.data.lambda_attrs.params) |*param| {
                param.name.offset += offset;
                if (param.default) |default| offsetNode(default, offset);
            }
            offsetNode(node.data.lambda_attrs.body, offset);
        },
        .let_in => {
            for (node.data.let_in.bindings) |*binding| {
                binding.name_offset += offset;
                for (binding.path) |*segment| {
                    segment.offset += offset;
                }
                offsetNode(binding.expr, offset);
            }
            offsetNode(node.data.let_in.body, offset);
        },
        .if_else => {
            offsetNode(node.data.if_else.cond, offset);
            offsetNode(node.data.if_else.then_branch, offset);
            offsetNode(node.data.if_else.else_branch, offset);
        },
        .assert => {
            offsetNode(node.data.assert.cond, offset);
            offsetNode(node.data.assert.body, offset);
        },
        .with_expr => {
            offsetNode(node.data.with_expr.attr_set, offset);
            offsetNode(node.data.with_expr.body, offset);
        },
        .attr_set => {
            for (node.data.attr_set.entries) |*entry| {
                for (entry.path) |*segment| {
                    segment.offset += offset;
                }
                if (entry.dynamic_name) |dynamic_name| offsetNode(dynamic_name, offset);
                if (entry.tail_dynamic_name) |dynamic_name| offsetNode(dynamic_name, offset);
                offsetNode(entry.expr, offset);
            }
        },
        .attr_path => {
            offsetNode(node.data.attr_path.root, offset);
            for (node.data.attr_path.segments) |*segment| {
                segment.offset += offset;
            }
        },
        .attr_dynamic => {
            offsetNode(node.data.attr_dynamic.root, offset);
            offsetNode(node.data.attr_dynamic.name, offset);
        },
        .attr_or => {
            offsetNode(node.data.attr_or.attr_path, offset);
            offsetNode(node.data.attr_or.default, offset);
        },
        .has_attr => {
            offsetNode(node.data.has_attr.root, offset);
            for (node.data.has_attr.segments) |*segment| {
                segment.offset += offset;
            }
        },
        .has_attr_dynamic => {
            offsetNode(node.data.has_attr_dynamic.root, offset);
            offsetNode(node.data.has_attr_dynamic.name, offset);
        },
        .has_attr_mixed => {
            offsetNode(node.data.has_attr_mixed.root, offset);
            for (node.data.has_attr_mixed.segments) |*segment| {
                switch (segment.*) {
                    .static => |*atom| atom.offset += offset,
                    .dynamic => |dynamic| offsetNode(dynamic, offset),
                }
            }
        },
        .list => {
            for (node.data.list.items) |item| {
                offsetNode(item, offset);
            }
        },
        .parens => offsetNode(node.data.parens, offset),
    }
}
