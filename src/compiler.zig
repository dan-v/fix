//! Compiler: AST → Bytecode
//!
//! Walks the AST tree and emits bytecode into a ChunkBuilder.
//! The compiler is stack-based: expressions push their result,
//! statements push/discard as needed.

const std = @import("std");
pub const literals = @import("compiler/literals.zig");
pub const ops = @import("compiler/ops.zig");
pub const control = @import("compiler/control.zig");
pub const attrs = @import("compiler/attrs.zig");
pub const access = @import("compiler/access.zig");
pub const emit = @import("compiler/emit.zig");
pub const scope = @import("compiler/scope.zig");
pub const thunks = @import("compiler/thunks.zig");
pub const diagnostics = @import("compiler/diagnostics.zig");
pub const strictness = @import("compiler/strictness.zig");
const operand = @import("compiler/operand.zig");
const compiler_types = @import("compiler/types.zig");
const captureCount = operand.captureCount;
const u16Count = operand.u16Count;
const ast = @import("ast.zig");
pub const Node = ast.Node;
pub const NodeTag = ast.NodeTag;
pub const BinaryOp = ast.BinaryOp;
const bytecode = @import("bytecode.zig");
const OpCode = bytecode.OpCode;
const chunk = bytecode.chunk;
const ChunkBuilder = chunk.ChunkBuilder;
const ChunkRegistry = chunk.ChunkRegistry;
const types = @import("runtime/types.zig");
const diagnostic = @import("diagnostic.zig");
const Diagnostic = diagnostic.Diagnostic;
const Value = @import("runtime/value.zig").Value;

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
    /// Used by integer-literal compilation to box i64 values that
    /// exceed the inline Value range (see `runtime/int.zig`). The
    /// resulting boxed object lives in the heap for the same span as
    /// the chunk constants that reference it — i.e. the evaluator
    /// lifetime, which always outlives any chunk execution.
    heap: *@import("runtime/heap.zig").ObjectHeap,
    source: []const u8,
    intern: *@import("runtime/intern.zig").InternTable,
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
    /// Count of attr value bodies deferred during this compile (lazy
    /// per-attr compilation). Tracked on the ROOT compiler (children
    /// bump the root); `parseAndCompile` reads it to decide whether to
    /// retain the file's AST arena. See `compiler/attrs.zig`.
    deferred_count: u32,
    /// Deferred-attr table to register bodies into, set on the ROOT
    /// compiler by `parseAndCompile`. Null disables deferral (e.g. the
    /// synthetic parent used by force-time deferred compilation, so
    /// nested attrsets there compile eagerly). See `deferred.zig`.
    deferred_table: ?*@import("compiler/deferred_table.zig").Table = null,
    /// A pre-built line index to use instead of building one over
    /// `source`. Set on the synthetic root of a force-time deferred
    /// compile so it doesn't rebuild the index over the whole (possibly
    /// huge) file per body. Not owned — never freed by `deinit`.
    external_line_index: ?*diagnostic.LineIndex = null,

    pub fn init(
        allocator: std.mem.Allocator,
        builder: *ChunkBuilder,
        registry: *ChunkRegistry,
        source: []const u8,
        intern: *@import("runtime/intern.zig").InternTable,
        heap: *@import("runtime/heap.zig").ObjectHeap,
    ) Compiler {
        return .{
            .allocator = allocator,
            .builder = builder,
            .registry = registry,
            .heap = heap,
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
            .deferred_count = 0,
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

    pub fn compileWithScope(self: *Compiler, node: *const Node, scope_value: ?Value) !void {
        if (scope_value) |value| {
            try self.compileAmbientScope(node, value);
        } else {
            try self.compileNode(node);
        }
    }

    /// Compile `node` (optionally in an ambient scope) and emit the
    /// terminating `ret`/`halt` instructions. After this returns, the
    /// builder holds a complete chunk ready for `ChunkBuilder.finish`.
    pub fn compileAndFinish(self: *Compiler, node: *const Node, scope_value: ?Value) !void {
        try self.compileWithScope(node, scope_value);
        try strictness.stampOnBuilder(self, node);
        try emit.emitRet(self);
        try self.builder.writeOp(self.allocator, .halt);
    }

    pub fn compileAmbientScope(self: *Compiler, node: *const Node, scope_value: Value) !void {
        scope.beginScope(self);

        const scope_slot = try scope.declareLocal(self, "", try self.intern.intern(""));
        try self.builder.emitConstant(self.allocator, scope_value);
        try emit.emitSetLocal(self, scope_slot);
        try self.with_scopes.append(self.allocator, .{ .kind = .local, .index = scope_slot });

        try self.compileNode(node);

        _ = self.with_scopes.pop();
        scope.endScope(self);
    }

    pub fn compileNode(self: *Compiler, node: *const Node) anyerror!void {
        const start = self.builder.code.items.len;
        try self.compileNodeImpl(node);
        const end = self.builder.code.items.len;
        if (try diagnostics.sourceSpanForNode(self, node)) |span| {
            try self.builder.addSourceMapEntry(self.allocator, start, end, span);
        }
    }

    pub fn compileNodeImpl(self: *Compiler, node: *const Node) anyerror!void {
        switch (node.tag) {
            .integer => try literals.compileInt(self, node),
            .float_val => try literals.compileFloat(self, node),
            .string => try literals.compileString(self, node),
            .path => try literals.compilePath(self, node),
            .search_path => try literals.compileSearchPath(self, node),
            .identifier => try literals.compileIdent(self, node),
            .bool_true => try emit.emitOp(self, .push_true),
            .bool_false => try emit.emitOp(self, .push_false),
            .null => try emit.emitOp(self, .push_null),
            .binary_op => try ops.compileBinary(self, node),
            .unary_op => try ops.compileUnary(self, node),
            .apply => try ops.compileApply(self, node),
            .lambda => try ops.compileLambda(self, node),
            .lambda_attrs => try ops.compileLambdaAttrs(self, node),
            .let_in => try ops.compileLetIn(self, node),
            .if_else => try control.compileIfElse(self, node),
            .assert => try control.compileAssert(self, node),
            .with_expr => try control.compileWith(self, node),
            .attr_set => try attrs.compileAttrSet(self, node),
            .attr_path => try access.compileAttrPath(self, node),
            .attr_dynamic => try access.compileAttrDynamic(self, node),
            .attr_or => try access.compileAttrOr(self, node),
            .has_attr => try access.compileHasAttr(self, node),
            .has_attr_dynamic => try access.compileHasAttrDynamic(self, node),
            .has_attr_mixed => try access.compileHasAttrMixed(self, node),
            .list => try access.compileList(self, node),
            .parens => try self.compileNode(node.data.parens),
        }
    }
};
