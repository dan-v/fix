//! Compiler: AST → Bytecode
//!
//! Walks the AST tree and emits bytecode into a ChunkBuilder.
//! The compiler is stack-based: expressions push their result,
//! statements push/discard as needed.

const std = @import("std");
const literals = @import("compiler/literals.zig");
const ops = @import("compiler/ops.zig");
const control = @import("compiler/control.zig");
const attrs = @import("compiler/attrs.zig");
const access = @import("compiler/access.zig");
const compiler_helpers = @import("compiler/helpers.zig");
const compiler_types = @import("compiler/types.zig");
const ast = @import("ast.zig");
pub const Node = ast.Node;
pub const NodeTag = ast.NodeTag;
pub const BinaryOp = ast.BinaryOp;
const OpCode = @import("opcode.zig").OpCode;
const bytecode = @import("bytecode.zig");
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

pub const Local = compiler_types.Local;
pub const Capture = compiler_types.Capture;
pub const WithScope = compiler_types.WithScope;
pub const AttrEntryView = compiler_types.AttrEntryView;
pub const AttrEntryGroup = compiler_types.AttrEntryGroup;
pub const AttrEntryGroups = compiler_types.AttrEntryGroups;
pub const ContainerValueOptions = compiler_types.ContainerValueOptions;
pub const with_capture_name = compiler_types.with_capture_name;

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

    pub fn compileAmbientScope(self: *Compiler, node: *const Node, scope_value: Value) !void {
        self.beginScope();

        const scope_slot = try self.declareLocal("", try self.intern.intern(""));
        try self.builder.emitConstant(self.allocator, scope_value);
        try self.emitSetLocal(scope_slot);
        try self.with_scopes.append(self.allocator, .{ .kind = .local, .index = scope_slot });

        try self.compileNode(node);

        _ = self.with_scopes.pop();
        self.endScope();
    }

    pub fn compileNode(self: *Compiler, node: *const Node) anyerror!void {
        const start = self.builder.code.items.len;
        try self.compileNodeImpl(node);
        const end = self.builder.code.items.len;
        if (try self.sourceSpanForNode(node)) |span| {
            try self.builder.addSourceMapEntry(self.allocator, start, end, span);
        }
    }

    pub fn compileNodeImpl(self: *Compiler, node: *const Node) anyerror!void {
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

    pub fn sourceSpanForNode(self: *Compiler, node: *const Node) !?chunk.Chunk.SourceSpan {
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

    pub fn optionalSourceFileId(self: *Compiler) !?InternId {
        if (self.source_path == null) return null;
        return try self.sourceFileId();
    }

    pub fn emitOp(self: *Compiler, op: OpCode) !void {
        try self.builder.writeOp(self.allocator, op);
    }

    pub fn emitOpU16(self: *Compiler, op: OpCode, val: u16) !void {
        try self.emitOp(op);
        try self.builder.writeU16(self.allocator, val);
    }

    pub fn emitOpU32(self: *Compiler, op: OpCode, val: u32) !void {
        try self.emitOp(op);
        try self.builder.writeU32(self.allocator, val);
    }

    pub fn emitBuildAttrs(self: *Compiler, count: u16, positions: []const heap_mod.AttrPosEntry) !void {
        if (positions.len == 0) {
            try self.emitOpU16(.build_attrs, count);
            return;
        }

        try self.emitOpU16(.build_attrs_with_pos, count);
        try self.builder.writeU16(self.allocator, try u16Count(positions.len));
        for (positions) |position| {
            try self.builder.writeU32(self.allocator, position.name);
            try self.builder.writeU32(self.allocator, position.pos.file);
            try self.builder.writeU32(self.allocator, position.pos.line);
            try self.builder.writeU32(self.allocator, position.pos.column);
        }
    }

    pub fn emitOpByte(self: *Compiler, op: OpCode, val: u8) !void {
        try self.emitOp(op);
        try self.builder.writeByte(self.allocator, val);
    }

    pub fn emitLocalOp(self: *Compiler, short_op: OpCode, long_op: OpCode, slot: u16) !void {
        if (slot <= std.math.maxInt(u8)) {
            try self.emitOpByte(short_op, @intCast(slot));
        } else {
            try self.emitOpU16(long_op, slot);
        }
    }

    pub fn emitGetLocal(self: *Compiler, slot: u16) !void {
        try self.emitLocalOp(.get_local, .get_local_long, slot);
    }

    pub fn emitCaptureLocal(self: *Compiler, slot: u16) !void {
        try self.emitLocalOp(.capture_local, .capture_local_long, slot);
    }

    pub fn emitSetLocal(self: *Compiler, slot: u16) !void {
        try self.emitLocalOp(.set_local, .set_local_long, slot);
    }

    pub fn emitSetCellLocal(self: *Compiler, slot: u16) !void {
        try self.emitLocalOp(.set_cell_local, .set_cell_local_long, slot);
    }

    pub fn emitInternOp(self: *Compiler, short_op: OpCode, long_op: OpCode, id: InternId) !void {
        if (id <= std.math.maxInt(u16)) {
            try self.emitOpU16(short_op, @intCast(id));
        } else {
            try self.emitOp(long_op);
            try self.builder.writeU32(self.allocator, id);
        }
    }

    pub fn writeInternId(self: *Compiler, id: InternId, wide: bool) !void {
        try bytecode.writeInternId(&self.builder.code, self.allocator, id, wide);
    }

    pub fn emitClosure(self: *Compiler, chunk_id: types.ChunkId, upvalue_count: u16) !void {
        if (chunk_id <= std.math.maxInt(u16)) {
            try self.emitOpU16(.closure, @intCast(chunk_id));
        } else {
            try self.emitOp(.closure_long);
            try self.builder.writeU32(self.allocator, chunk_id);
        }
        try self.builder.writeU16(self.allocator, upvalue_count);
    }

    pub fn emitClosureWithCaptures(self: *Compiler, chunk_id: types.ChunkId, captures: []const Capture) !void {
        if (captures.len == 0) return self.emitClosure(chunk_id, 0);
        const upvalue_count = try captureCount(captures.len);

        if (chunk_id <= std.math.maxInt(u16)) {
            try self.emitOpU16(.closure_captures, @intCast(chunk_id));
        } else {
            try self.emitOp(.closure_captures_long);
            try self.builder.writeU32(self.allocator, chunk_id);
        }
        try self.builder.writeU16(self.allocator, upvalue_count);
        try self.emitCaptureDescriptors(captures);
    }

    pub fn emitThunkWithCaptures(self: *Compiler, chunk_id: types.ChunkId, captures: []const Capture) !void {
        const upvalue_count = try captureCount(captures.len);

        if (chunk_id <= std.math.maxInt(u16)) {
            try self.emitOpU16(.thunk_captures, @intCast(chunk_id));
        } else {
            try self.emitOp(.thunk_captures_long);
            try self.builder.writeU32(self.allocator, chunk_id);
        }
        try self.builder.writeU16(self.allocator, upvalue_count);
        try self.emitCaptureDescriptors(captures);
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
            if (try self.attrSegmentNameId(seg) > std.math.maxInt(u16)) wide = true;
        }
        return wide;
    }

    pub fn writeStaticAttrPathOperand(self: *Compiler, segments: []const Node.Atom, atom: Node.Atom, wide: bool) !void {
        try self.builder.writeByte(self.allocator, try self.requireU8At(segments.len, atom, "attribute path has too many segments"));
        for (segments) |seg| {
            const name_id = try self.attrSegmentNameId(seg);
            try self.writeInternId(name_id, wide);
        }
    }

    pub fn writeMixedAttrPathOperand(self: *Compiler, segments: []const Node.Atom, dynamic_count: usize, atom: Node.Atom) !void {
        try self.builder.writeByte(self.allocator, try self.requireU8At(segments.len, atom, "attribute path has too many segments"));
        try self.builder.writeByte(self.allocator, try self.requireU8At(dynamic_count, atom, "attribute path has too many dynamic segments"));
        for (segments) |seg| {
            if (self.attrSegmentHasInterpolation(seg)) {
                try self.builder.writeByte(self.allocator, @intFromEnum(bytecode.MixedAttrSegmentTag.dynamic));
            } else {
                try self.builder.writeByte(self.allocator, @intFromEnum(bytecode.MixedAttrSegmentTag.static));
                try self.builder.writeU32(self.allocator, try self.attrSegmentNameId(seg));
            }
        }
    }

    pub fn writeHasAttrMixedOperand(self: *Compiler, segments: []const Node.HasAttrMixedSegment, dynamic_count: usize, atom: Node.Atom) !void {
        try self.builder.writeByte(self.allocator, try self.requireU8At(segments.len, atom, "attribute path has too many segments"));
        try self.builder.writeByte(self.allocator, try self.requireU8At(dynamic_count, atom, "attribute path has too many dynamic segments"));
        for (segments) |segment| {
            switch (segment) {
                .static => |static_atom| {
                    if (self.attrSegmentHasInterpolation(static_atom)) {
                        try self.builder.writeByte(self.allocator, @intFromEnum(bytecode.MixedAttrSegmentTag.dynamic));
                    } else {
                        try self.builder.writeByte(self.allocator, @intFromEnum(bytecode.MixedAttrSegmentTag.static));
                        try self.builder.writeU32(self.allocator, try self.attrSegmentNameId(static_atom));
                    }
                },
                .dynamic => try self.builder.writeByte(self.allocator, @intFromEnum(bytecode.MixedAttrSegmentTag.dynamic)),
            }
        }
    }

    pub const compileInt = literals.compileInt;
    pub const compileFloat = literals.compileFloat;
    pub const compileString = literals.compileString;
    pub const compileStringAtom = literals.compileStringAtom;
    pub const emitStringPart = literals.emitStringPart;
    pub const compileInterpolatedExpr = literals.compileInterpolatedExpr;
    pub const compilePath = literals.compilePath;
    pub const compileInterpolatedPath = literals.compileInterpolatedPath;
    pub const emitPathPart = literals.emitPathPart;
    pub const compileSearchPath = literals.compileSearchPath;
    pub const resolvePathLiteral = literals.resolvePathLiteral;
    pub const resolvePathLiteralPreserveTrailingSlash = literals.resolvePathLiteralPreserveTrailingSlash;
    pub const compileIdent = literals.compileIdent;
    pub const compileCurPos = literals.compileCurPos;
    pub const emitAmbientBuiltin = literals.emitAmbientBuiltin;

    pub const compileBinary = ops.compileBinary;
    pub const compileAnd = ops.compileAnd;
    pub const compileOr = ops.compileOr;
    pub const compileImpl = ops.compileImpl;
    pub const compileUnary = ops.compileUnary;
    pub const compileApply = ops.compileApply;
    pub const compileTailExpression = ops.compileTailExpression;
    pub const compileTailNodeImpl = ops.compileTailNodeImpl;
    pub const compileApplyWithOp = ops.compileApplyWithOp;
    pub const compileLambda = ops.compileLambda;
    pub const compileLambdaAttrs = ops.compileLambdaAttrs;
    pub const compileAttrParamThunk = ops.compileAttrParamThunk;
    pub const compileLetIn = ops.compileLetIn;
    pub const compileLetInWithTailBody = ops.compileLetInWithTailBody;
    pub const compileLetInBody = ops.compileLetInBody;
    pub const compileLetRootBinding = ops.compileLetRootBinding;
    pub const bindingRootSeen = ops.bindingRootSeen;

    pub const compileIfElse = control.compileIfElse;
    pub const compileIfElseTail = control.compileIfElseTail;
    pub const compileIfElseBody = control.compileIfElseBody;
    pub const compileAssert = control.compileAssert;
    pub const compileAssertTail = control.compileAssertTail;
    pub const compileAssertBody = control.compileAssertBody;
    pub const compileWith = control.compileWith;
    pub const compileWithTail = control.compileWithTail;
    pub const compileWithBody = control.compileWithBody;

    pub const compileAttrSet = attrs.compileAttrSet;
    pub const compileMixedAttrSet = attrs.compileMixedAttrSet;
    pub const compileMixedRecursiveAttrSet = attrs.compileMixedRecursiveAttrSet;
    pub const hasDynamicAttrEntries = attrs.hasDynamicAttrEntries;
    pub const staticAttrEntryCount = attrs.staticAttrEntryCount;
    pub const isDynamicAttrEntry = attrs.isDynamicAttrEntry;
    pub const compileDynamicAttrName = attrs.compileDynamicAttrName;
    pub const compileDynamicAttrValueThunk = attrs.compileDynamicAttrValueThunk;
    pub const compileNodeAttrEntriesThunk = attrs.compileNodeAttrEntriesThunk;
    pub const compileAttrEntries = attrs.compileAttrEntries;
    pub const compileMixedAttrEntryViews = attrs.compileMixedAttrEntryViews;
    pub const compileMixedRecursiveAttrEntryViews = attrs.compileMixedRecursiveAttrEntryViews;
    pub const hasDynamicAttrEntryViews = attrs.hasDynamicAttrEntryViews;
    pub const staticAttrEntryViewCount = attrs.staticAttrEntryViewCount;
    pub const isDynamicAttrEntryView = attrs.isDynamicAttrEntryView;
    pub const compileDynamicAttrViewName = attrs.compileDynamicAttrViewName;
    pub const compileDynamicAttrViewValueThunk = attrs.compileDynamicAttrViewValueThunk;
    pub const compilePlainAttrEntries = attrs.compilePlainAttrEntries;
    pub const compileRecursiveAttrEntries = attrs.compileRecursiveAttrEntries;
    pub const compilePlainAttrGroup = attrs.compilePlainAttrGroup;
    pub const declareRecursiveAttrLocals = attrs.declareRecursiveAttrLocals;
    pub const compileRecursiveAttrCells = attrs.compileRecursiveAttrCells;
    pub const emitRecursiveAttrObject = attrs.emitRecursiveAttrObject;
    pub const compileExtendedAttrSetLiteralThunk = attrs.compileExtendedAttrSetLiteralThunk;
    pub const nonAttrSetDuplicateLeaf = attrs.nonAttrSetDuplicateLeaf;
    pub const compileAttrEntriesThunk = attrs.compileAttrEntriesThunk;
    pub const attrEntryViews = attrs.attrEntryViews;
    pub const attrEntryGroups = attrs.attrEntryGroups;
    pub const reportDuplicateAttribute = attrs.reportDuplicateAttribute;
    pub const attrSegmentsEqual = attrs.attrSegmentsEqual;
    pub const emitAttrNameId = attrs.emitAttrNameId;
    pub const appendAttrPosition = attrs.appendAttrPosition;
    pub const sourceFileId = attrs.sourceFileId;

    pub const compileAttrPath = access.compileAttrPath;
    pub const compileAttrDynamic = access.compileAttrDynamic;
    pub const compileAttrOr = access.compileAttrOr;
    pub const attrPathHasInterpolation = access.attrPathHasInterpolation;
    pub const compileHasAttr = access.compileHasAttr;
    pub const compileHasAttrDynamic = access.compileHasAttrDynamic;
    pub const compileHasAttrMixed = access.compileHasAttrMixed;
    pub const hasAttrSegmentsHaveInterpolation = access.hasAttrSegmentsHaveInterpolation;
    pub const compileList = access.compileList;
    pub const compileContainerValue = access.compileContainerValue;
    pub const compileImmediateContainerValue = access.compileImmediateContainerValue;
    pub const compileRawIdent = access.compileRawIdent;
    pub const stringHasInterpolation = access.stringHasInterpolation;
    pub const pathHasInterpolation = access.pathHasInterpolation;

    pub fn reportCompileError(self: *Compiler, offset: u32, len: u32, message: []const u8) !void {
        try self.reportDiagnostic(.err, offset, len, message);
    }

    pub fn reportCompileNote(self: *Compiler, offset: u32, len: u32, message: []const u8) !void {
        try self.reportDiagnostic(.note, offset, len, message);
    }

    pub fn reportDiagnostic(self: *Compiler, severity: Diagnostic.Severity, offset: u32, len: u32, message: []const u8) !void {
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

    pub fn absorbParserDiagnostics(self: *Compiler, diagnostics: []const Diagnostic, source_offset: u32) !void {
        try self.diagnostics.ensureUnusedCapacity(self.allocator, diagnostics.len);
        for (diagnostics) |diag| {
            const offset = source_offset + diag.offset;
            const position = try self.sourcePositionForOffset(offset);
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
            try self.reportCompileError(atom.offset, atom.len, message);
            return error.BytecodeOperandTooLarge;
        }
        return @intCast(count);
    }

    pub fn requireU8At(self: *Compiler, count: usize, atom: Node.Atom, message: []const u8) !u8 {
        if (count > std.math.maxInt(u8)) {
            try self.reportCompileError(atom.offset, atom.len, message);
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

    pub fn compileThunk(self: *Compiler, expr: *const Node) !void {
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
        try self.emitThunkWithCaptures(child_id, child.captures.items);
    }

    pub fn compileStringAtomThunk(self: *Compiler, atom: Node.Atom) !void {
        var node = Node{
            .tag = .string,
            .data = .{ .atom = atom },
            .span = atom,
        };
        try self.compileThunk(&node);
    }

    pub fn emitWithLookup(self: *Compiler, name: []const u8) !bool {
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

    pub fn collectWithScopes(self: *Compiler, scopes: *std.ArrayListUnmanaged(WithScope)) !void {
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

    pub fn patchJump(self: *Compiler, instruction_offset: usize, target_offset: usize) void {
        const operand_offset = instruction_offset + 1;
        const next_instruction = instruction_offset + 5;
        const relative: u32 = @intCast(target_offset - next_instruction);
        self.builder.code.items[operand_offset] = @truncate(relative);
        self.builder.code.items[operand_offset + 1] = @truncate(relative >> 8);
        self.builder.code.items[operand_offset + 2] = @truncate(relative >> 16);
        self.builder.code.items[operand_offset + 3] = @truncate(relative >> 24);
    }

    pub fn attrSegmentSpan(self: *const Compiler, atom: Node.Atom) []const u8 {
        const span = self.source[atom.offset .. atom.offset + atom.len];
        if (span.len >= 2 and span[0] == '"' and span[span.len - 1] == '"') {
            return span[1 .. span.len - 1];
        }
        return span;
    }

    pub fn attrSegmentNameId(self: *Compiler, atom: Node.Atom) !InternId {
        const name = try self.attrSegmentNameAlloc(atom);
        defer self.allocator.free(name);
        return self.intern.intern(name);
    }

    pub fn attrSegmentNameAlloc(self: *Compiler, atom: Node.Atom) ![]u8 {
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

    pub fn attrSegmentHasInterpolation(self: *const Compiler, atom: Node.Atom) bool {
        const span = self.source[atom.offset .. atom.offset + atom.len];
        return string_syntax.kindAt(self.source, atom.offset) != null and std.mem.indexOf(u8, span, "${") != null;
    }

    // ---- scope management ----

    pub fn beginScope(self: *Compiler) void {
        self.scope_depth += 1;
    }

    pub fn endScope(self: *Compiler) void {
        self.scope_depth -= 1;
        // Pop locals defined in this scope.
        while (self.locals.items.len > 0) {
            const local = self.locals.items[self.locals.items.len - 1];
            if (local.depth <= self.scope_depth) break;
            _ = self.locals.pop();
        }
    }

    pub fn declareLocal(self: *Compiler, name: []const u8, name_id: InternId) !u16 {
        if (self.slot_count == std.math.maxInt(u16)) return error.TooManyLocals;
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

    pub fn resolveLocal(self: *const Compiler, name: []const u8) ?u16 {
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

    pub fn resolveLocalId(self: *const Compiler, name_id: InternId) ?u16 {
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

    pub fn resolveCapture(self: *Compiler, name: []const u8) !?u16 {
        const parent = self.parent orelse return null;
        if (parent.resolveLocal(name)) |parent_slot| {
            return try self.addCapture(name, .local, parent_slot);
        }
        if (try parent.resolveCapture(name)) |parent_upvalue| {
            return try self.addCapture(name, .upvalue, parent_upvalue);
        }
        return null;
    }

    pub fn addCapture(self: *Compiler, name: []const u8, kind: Capture.Kind, capture_index: u16) !u16 {
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

    pub fn sourcePositionForOffset(self: *Compiler, offset: u32) !diagnostic.SourcePosition {
        const index = try self.ensureLineIndex();
        return index.positionForOffset(offset);
    }

    pub fn ensureLineIndex(self: *Compiler) !*const diagnostic.LineIndex {
        if (self.parent) |parent| return parent.ensureLineIndex();
        if (!self.line_index_ready) {
            self.line_index = try diagnostic.LineIndex.init(self.allocator, self.source);
            self.line_index_ready = true;
        }
        return &self.line_index;
    }
};

pub const captureCount = compiler_helpers.captureCount;
pub const u16Count = compiler_helpers.u16Count;
pub const diagnosticAtom = compiler_helpers.diagnosticAtom;
pub const attrEntriesDiagnosticAtom = compiler_helpers.attrEntriesDiagnosticAtom;
pub const attrGroupsDiagnosticAtom = compiler_helpers.attrGroupsDiagnosticAtom;
pub const attrPathDiagnosticAtom = compiler_helpers.attrPathDiagnosticAtom;
pub const hasAttrDiagnosticAtom = compiler_helpers.hasAttrDiagnosticAtom;
pub const hasAttrMixedDiagnosticAtom = compiler_helpers.hasAttrMixedDiagnosticAtom;
pub const nodeMayEvaluateToFloat = compiler_helpers.nodeMayEvaluateToFloat;
pub const nodeSourceSpan = compiler_helpers.nodeSourceSpan;
pub const unwrapParens = compiler_helpers.unwrapParens;
pub const offsetNode = compiler_helpers.offsetNode;
