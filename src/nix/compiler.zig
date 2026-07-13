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
pub const deferred_table = @import("compiler/deferred_table.zig");
pub const deferred = @import("compiler/deferred.zig");
const compiler_types = @import("compiler/types.zig");
const ast = @import("syntax").ast;
pub const Node = ast.Node;
pub const NodeTag = ast.NodeTag;
pub const BinaryOp = ast.BinaryOp;
const bytecode = @import("bytecode");
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
    /// $HOME, for expanding `~/…` home-relative path literals at compile time
    /// (Nix resolves the tilde at parse time). Null when unset in the env.
    home_dir: ?[]const u8,
    /// `nul-bytes` deprecated feature: when true a NUL in a string literal
    /// truncates at the NUL; when false (default) it is a compile error.
    allow_nul_bytes: bool = false,
    /// `rec-set-overrides` deprecated feature: a top-level `__overrides` in a
    /// `rec` set is a compile error unless enabled.
    allow_rec_set_overrides: bool = false,
    /// `rec-set-merges` deprecated feature: a rec/non-rec attr-path merge
    /// conflict is a compile error unless enabled.
    allow_rec_set_merges: bool = false,
    source_file_id: ?InternId,
    locals: std.ArrayListUnmanaged(Local),
    captures: std.ArrayListUnmanaged(Capture),
    /// Debug-only slot→name record (parallel to slot allocation). Populated in
    /// `declareLocal` when `registry.capture_names` is on; handed to the
    /// registry's `local_names` sidecar at finalize. Empty otherwise.
    local_names: std.ArrayListUnmanaged(InternId),
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
    /// Arena that `.elided` bodies are sub-parsed into (body-span elision;
    /// see `literals.materializeElided`). Set on the ROOT compiler:
    /// `parseAndCompile` points it at the file's (possibly retained) AST
    /// arena; `deferred.compile` at a per-compile throwaway arena. Null in
    /// roots that can never see elided nodes (elision is only enabled for
    /// file parses).
    ast_arena: ?*ast.AstArena = null,
    /// Whether `materializeElided` may overwrite the shared `.elided` node
    /// in place with its parsed body. True only for the single-threaded
    /// original file compile (where in-place replacement makes every later
    /// consumer — merge checks, strictness stamps — see exactly the tree an
    /// eager parse would have built). Force-time deferred compiles run
    /// concurrently over the shared retained AST and must never write to it.
    elide_mutable: bool = false,
    /// Best-effort chunk naming (`fix disasm`, gated on `registry.capture_names`).
    /// `name_hint` is set by let/attr-set compilation just before a bound value
    /// is compiled; the first child compiler spun up for that value consumes it
    /// into its own `chunk_name`, which is recorded against the chunk id at
    /// registration. `name_prefix` is the joined path of enclosing named chunks:
    /// real attr/let segments join with `.` (`a.b.c`), synthetic segments (λ…,
    /// node-tag tags) join with `·` so the name never reads as a false attr
    /// path. All null (and free) when off.
    name_hint: ?InternId = null,
    /// Whether `name_hint` is synthetic (λ/tag) rather than a real binding name
    /// — selects the `·` joiner and lets real names take precedence.
    name_hint_synthetic: bool = false,
    /// Always-on qualified-name node for the chunk this compiler emits (see
    /// `bytecode/name_tree.zig`). Threaded down the compiler chain: a named
    /// child extends it, an anonymous child inherits it. Unlike the `·`/`.`
    /// string naming above (gated on `capture_names`), this is always built —
    /// cheaply, one small node per bound chunk.
    name_id: bytecode.NameId = bytecode.NAME_ROOT,
    /// This compile's ambient scope REPLACES the base (builtins) scope rather
    /// than overlaying it — the `builtins.scopedImport` semantic, where the
    /// supplied attrset becomes the entire free-identifier environment. When
    /// set, free identifiers resolve against the ambient scope BEFORE (and
    /// instead of) the static builtins, so even names that are builtins
    /// (`import`, `map`, …) bind to the attrset's entries. Set on the root by
    /// `parseAndCompile` (scope present AND a source_path — i.e. a scoped
    /// import, not a repl/debug overlay), inherited by children. The repl's
    /// ambient scope keeps this false, so builtins stay visible there.
    scoped_base: bool = false,

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
            .home_dir = null,
            .source_file_id = null,
            .locals = .empty,
            .captures = .empty,
            .local_names = .empty,
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
        child.scoped_base = self.scoped_base;
        child.base_path = self.base_path;
        child.source_path = self.source_path;
        child.home_dir = self.home_dir;
        child.allow_nul_bytes = self.allow_nul_bytes;
        child.allow_rec_set_overrides = self.allow_rec_set_overrides;
        child.allow_rec_set_merges = self.allow_rec_set_merges;
        child.source_file_id = self.source_file_id;
        // Qualified-name tree: the first child spun up for a named bound value
        // claims the pending name as a child node of this compiler's name and
        // becomes the parent for its own nested bodies. Real binding segments
        // are always recorded (traces/errors); synthetic λ/tag segments are
        // armed only under `capture_names` (disasm detail), so an ordinary run
        // keeps clean `pkgs.hello` paths. Unnamed children inherit the parent.
        child.name_id = self.name_id;
        if (self.name_hint) |seg| {
            child.name_id = self.registry.childName(self.name_id, seg, self.name_hint_synthetic) catch self.name_id;
            self.name_hint = null;
            self.name_hint_synthetic = false;
        }
        return child;
    }

    /// Arm the pending chunk name for the next child compiler: the first body
    /// spun up (see `childCompiler`) claims `name_id` as its best-effort name.
    /// A no-op unless `fix disasm` turned name capture on, so callers can arm
    /// unconditionally without gating on the hot path.
    pub fn armName(self: *Compiler, name_id: InternId) void {
        // Always on now: the qualified-name tree needs real binding segments in
        // every run (traces/errors), and setting a pending `InternId` is cheap.
        // `armSyntheticName`/`armNodeTagName` stay gated — synthetic detail is
        // disasm-only. See `initChild`.
        self.name_hint = name_id;
        self.name_hint_synthetic = false;
    }

    /// Arm a *synthetic* name (e.g. `λpkgs` for an unbound lambda, `(apply)`
    /// for an argument thunk) — only when no real binding name is already
    /// pending, since a binding name is always the better attribution.
    pub fn armSyntheticName(self: *Compiler, text: []const u8) void {
        if (!self.registry.capture_names or self.name_hint != null) return;
        self.name_hint = self.intern.intern(text) catch return;
        self.name_hint_synthetic = true;
    }

    /// Arm a synthetic tag derived from the node kind — `(apply)`, `(if_expr)`,
    /// `(string)`, … — for child chunks with no binding name (argument thunks,
    /// operands, interpolations).
    pub fn armNodeTagName(self: *Compiler, node: *const Node) void {
        if (!self.registry.capture_names or self.name_hint != null) return;
        var buf: [64]u8 = undefined;
        const t = std.fmt.bufPrint(&buf, "({s})", .{@tagName(node.tag)}) catch return;
        self.armSyntheticName(t);
    }

    /// Register `ch`, tagging it with this compiler's qualified-name node.
    pub fn registerChunk(self: *Compiler, ch: chunk.Chunk) !types.ChunkId {
        // Content-addressed dedup over FULL structural equality (code, constant
        // bits, side tables, source map, spans): field-equal chunks carry
        // identical semantics AND identical diagnostics, so sharing one
        // registration is observation-free. Folded-constant chunks self-exclude
        // (their pool Values hold per-fold ObjectIds that never bit-match).
        const r = try self.registry.registerDeduped(ch, self.name_id);
        if (r.reused) {
            var copy = ch;
            copy.deinit(self.persistent);
            return r.id; // first registration keeps its name/upvalue sidecar
        }
        try self.recordChunkSidecar(r.id, &ch);
        return r.id;
    }

    /// The disasm-only per-slot sidecar recording (upvalue/local names + file)
    /// split out of `registerChunk`. The chunk's *name* is no longer here — it
    /// lives in the always-on `name_tree` (see `initChild`/`registerDeduped`).
    fn recordChunkSidecar(self: *Compiler, id: types.ChunkId, ch: *const chunk.Chunk) !void {
        _ = ch;
        if (self.source_file_id) |file| try self.registry.recordFile(id, file);
        // This compiler's capture list IS the chunk's upvalue vector (slot
        // order), and every capture carries its binding name — record them for
        // the disassembler's upvalue table.
        if (self.registry.capture_names and self.captures.items.len > 0) {
            const names = try self.allocator.alloc(types.InternId, self.captures.items.len);
            defer self.allocator.free(names);
            for (self.captures.items, names) |cap, *n| n.* = cap.name_id;
            try self.registry.recordUpvalueNames(id, names);
        }
        // Local binding names (slot order) — the debugger resolves
        // breakpoint-scope identifiers through this.
        if (self.registry.capture_names and self.local_names.items.len > 0) {
            try self.registry.recordLocalNames(id, self.local_names.items);
        }
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
        self.local_names.deinit(self.allocator);
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
            .uri => try literals.compileUri(self, node),
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
            // A body whose parse was elided: sub-parse the span now and
            // compile the result. Recurses through `compileNodeImpl` (not
            // `compileNode`) so exactly ONE source-map entry is added — by
            // the enclosing `compileNode`, which reads the materialized
            // span in the in-place (mutable) case — matching the eager
            // compile byte for byte.
            .elided => {
                const body = try literals.materializeElided(self, node);
                try self.compileNodeImpl(body);
            },
        }
    }
};
