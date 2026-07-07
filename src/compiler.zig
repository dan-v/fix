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
const compiler_types = @import("compiler/types.zig");
const ast = @import("syntax").ast;
pub const Node = ast.Node;
pub const NodeTag = ast.NodeTag;
pub const BinaryOp = ast.BinaryOp;
const bytecode = @import("bytecode.zig");
const chunk = bytecode.chunk;
const ChunkBuilder = chunk.ChunkBuilder;
const ChunkRegistry = chunk.ChunkRegistry;
const types = @import("runtime").types;
const diagnostic = @import("syntax").diagnostic;
const Diagnostic = diagnostic.Diagnostic;
const Value = @import("runtime").value.Value;
const ObjectHeap = @import("runtime").heap.ObjectHeap;
const InternTable = @import("runtime").intern.InternTable;
const DeferredTable = @import("compiler/deferred_table.zig").Table;

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
    /// Per-compilation-unit SCRATCH allocator. Everything the compiler
    /// builds while emitting a chunk — locals/captures/with-scope tracking,
    /// strictness analysis maps, name-resolution sets, the ChunkBuilder's
    /// growth buffers, diagnostics — lives here. It is an arena owned by the
    /// unit root (`parseAndCompile` / `deferred.compile`) and freed wholesale
    /// when the unit finishes, so individual structures never need per-node
    /// frees. Child compilers share the root's arena.
    ///
    /// INVARIANT: anything that must outlive the compile (the emitted Chunk's
    /// `code`/`constants`/etc.) is duped onto `persistent` instead — that
    /// handoff happens only at `ChunkBuilder.finish`. Registry/deferred-table
    /// entries and copied-out diagnostics carry their own persistent copies.
    allocator: std.mem.Allocator,
    /// Long-lived allocator (evaluator lifetime) for compile OUTPUT only:
    /// the bytecode the registered chunk owns. Never used for scratch.
    persistent: std.mem.Allocator,
    builder: *ChunkBuilder,
    registry: *ChunkRegistry,
    /// Used by integer-literal compilation to box i64 values that
    /// exceed the inline Value range (see `runtime/int.zig`). The
    /// resulting boxed object lives in the heap for the same span as
    /// the chunk constants that reference it — i.e. the evaluator
    /// lifetime, which always outlives any chunk execution.
    heap: *ObjectHeap,
    source: []const u8,
    intern: *InternTable,
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
    /// nested attrsets there compile eagerly). See `deferred_table.zig`.
    deferred_table: ?*DeferredTable = null,
    /// A pre-built line index to use instead of building one over
    /// `source`. Set on the synthetic root of a force-time deferred
    /// compile so it doesn't rebuild the index over the whole (possibly
    /// huge) file per body. Not owned — never freed by `deinit`.
    external_line_index: ?*diagnostic.LineIndex = null,
    /// Memoized result of `diagnostics.ensureLineIndex` — avoids walking
    /// the parent chain per compiled node. Points at the root's
    /// `line_index` (or `external_line_index`); never owned.
    resolved_line_index: ?*diagnostic.LineIndex = null,
    /// Spare child ChunkBuilders, populated on the ROOT compiler only
    /// (children route through it). One builder is created per emitted
    /// chunk; recycling the buffers avoids paying the builder's initial
    /// code/constants capacity allocation ~once per chunk.
    builder_pool: std.ArrayListUnmanaged(ChunkBuilder) = .empty,

    pub fn init(
        allocator: std.mem.Allocator,
        persistent: std.mem.Allocator,
        builder: *ChunkBuilder,
        registry: *ChunkRegistry,
        source: []const u8,
        intern: *InternTable,
        heap: *ObjectHeap,
    ) Compiler {
        return .{
            .allocator = allocator,
            .persistent = persistent,
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

    /// Bootstrap a child compiler for a nested body (thunk, apply-arg,
    /// attr-entry, or lambda body): share the parent's allocators, registry,
    /// source, intern table, and heap via `init`, then inherit the source-
    /// location context (`parent`, `base_path`, `source_path`,
    /// `source_file_id`). Every nested-body compile goes through here so the
    /// inherited-field set lives in exactly one place.
    pub fn initChild(self: *Compiler, builder: *ChunkBuilder) Compiler {
        var child = Compiler.init(
            self.allocator,
            self.persistent,
            builder,
            self.registry,
            self.source,
            self.intern,
            self.heap,
        );
        child.parent = self;
        child.base_path = self.base_path;
        child.source_path = self.source_path;
        child.source_file_id = self.source_file_id;
        return child;
    }

    pub fn deinit(self: *Compiler) void {
        for (self.builder_pool.items) |*builder| builder.deinit(self.allocator);
        self.builder_pool.deinit(self.allocator);
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

    /// Take a ChunkBuilder for a nested chunk compile — recycled from the
    /// root's pool when available. Pair with `releaseBuilder`.
    pub fn acquireBuilder(self: *Compiler) !ChunkBuilder {
        const root = self.rootCompiler();
        if (root.builder_pool.pop()) |pooled| {
            var builder = pooled;
            builder.reset();
            return builder;
        }
        return ChunkBuilder.init(self.allocator);
    }

    /// Return a finished child builder's buffers to the root's pool. The
    /// builder must not be used again by the caller.
    pub fn releaseBuilder(self: *Compiler, builder: *ChunkBuilder) void {
        const root = self.rootCompiler();
        root.builder_pool.append(root.allocator, builder.*) catch {
            builder.deinit(self.allocator);
        };
    }

    fn rootCompiler(self: *Compiler) *Compiler {
        var compiler = self;
        while (compiler.parent) |parent| compiler = parent;
        return compiler;
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
            .has_attr_mixed => try access.compileHasAttrMixed(self, node),
            .list => try access.compileList(self, node),
            .parens => try self.compileNode(node.data.parens),
        }
    }
};
