//! Bytecode chunk — a sequence of opcodes and a constant pool.
//!
//! Chunks are immutable after construction. They are identified by ChunkId
//! in a global table, enabling cheap interning and cross-thread referencing.

const std = @import("std");
const types = @import("runtime").types;
const encoding = @import("encoding.zig");
const OpCode = @import("opcode.zig").OpCode;
const Value = @import("runtime").value.Value;
const AttrEntry = @import("runtime").heap.AttrEntry;
const AttrPosEntry = @import("runtime").heap.AttrPosEntry;
const stable = @import("base").segments;
const sync = @import("base").sync;
const name_tree_mod = @import("name_tree.zig");
const ChunkId = types.ChunkId;
const ConstIdx = types.ConstIdx;

/// The formal-parameter pattern of a lambda chunk, carried so `--xml`
/// output can render `<varpat>`/`<attrspat>` the way Nix does. `none` for
/// non-lambda (thunk) bodies, builtins, and merged bodies with no param
/// info. Semantically distinguishing (two identity lambdas `x: x` and
/// `y: y` compile to identical bytecode but render different varpat names),
/// so it participates in chunk dedup (`contentHash`/`contentEql`).
pub const LambdaPattern = union(enum) {
    none,
    /// `x: …` (value lambda; for a merged `a: b: …` chain, the first param).
    var_pat: types.InternId,
    /// `{a, b, …}: …` / `args@{…}: …`. Formal names come from `function_args`.
    attrs_pat: AttrsPattern,

    pub const AttrsPattern = struct {
        /// The `@`-binding name (`args` in `args@{…}`); valid iff `has_bind`.
        bind_name: types.InternId = 0,
        has_bind: bool = false,
        /// The pattern ends in `...` (accepts extra attrs).
        ellipsis: bool = false,
    };
};

pub const Chunk = struct {
    pub const SourceSpan = struct {
        file: ?types.InternId,
        offset: u32,
        len: u32,
        line: u32,
        column: u32,
    };

    pub const SourceMapEntry = struct {
        start: u32,
        end: u32,
        span: SourceSpan,
    };

    /// Bytecode stream.
    code: []u8,
    /// Constant pool.
    constants: []Value,
    /// Number of stack slots reserved for locals in each frame.
    local_count: u16,
    /// Number of parameters the function consumes before its body runs.
    /// 1 for curried/attrset lambdas (the historical default) and for
    /// thunk bodies (which are never "called"). N>1 for an *uncurried*
    /// chunk produced by merging an adjacent `a: b: ...:` value-lambda
    /// chain (see `compiler/ops.zig compileLambda`): a call site
    /// supplying N args runs the body in one frame, under-application
    /// builds a partial-application (PAP) value. `arity <= local_count`.
    arity: u16 = 1,
    /// Bitmask (bit i = param i) of which params an *uncurried* (arity>1)
    /// chunk's body unconditionally forces — the multi-param analogue of
    /// `scheduling.strict_param`. The saturated `call_n` path eagerly
    /// forces these arg positions before running the body, recovering the
    /// eager-arg optimization the single-param path gets via `thunk_arg`
    /// (and avoiding lazy-thunk-chain buildup in accumulator recursion).
    /// 0 for arity-1 chunks (handled by `strict_param`) and thunk bodies.
    strict_params: u8 = 0,
    /// Compile-time scheduling hints — `body_is_substantial`
    /// (chunk-size driven, pays the scheduler hop) and `strictness`
    /// (which upvalues the body unconditionally forces). Both are
    /// stamped at `ChunkBuilder.finish()` time and consumed by the VM
    /// to decide whether to submit a thunk for parallel forcing at
    /// creation. See `compiler/strictness.zig` for the strictness
    /// analysis.
    scheduling: SchedulingHints = .{},
    /// Attrset function parameter metadata for builtins.functionArgs.
    function_args: []const AttrEntry = &.{},
    /// Source positions of the function parameters (parallel data for
    /// `builtins.functionArgs`), so `unsafeGetAttrPos` can report a formal's
    /// location. Empty when the chunk was compiled without a source path.
    function_arg_pos: []const AttrPosEntry = &.{},
    /// Attr-position records referenced by `attrs_new_named_pos_srt` ops.
    /// Kept OUT of the dispatched code stream (they were 16 bytes/entry
    /// inline — ~38% of all emitted bytecode on a NixOS eval, cold data read
    /// only by `unsafeGetAttrPos`/diagnostics). Ops carry a (start, count)
    /// reference.
    attr_pos: []const AttrPosEntry = &.{},
    /// Attr names referenced by `attrs_new_named*` ops (interned ids, sorted
    /// per site) — like `attr_pos`, kept out of the code stream; each op
    /// carries a (start, count) reference.
    attr_names: []const types.InternId = &.{},
    /// Capture-descriptor lists referenced by `thunk_defer` (and, later, the
    /// thunk family) — kept OUT of the code stream and DEDUPED, like `attr_pos`.
    /// An attrset's deferred values all snapshot the same enclosing scope, so
    /// the same `(kind:1, index:2)*` list was re-emitted inline per value (~12%
    /// of all code). Ops now carry a `(start, count)` reference; identical lists
    /// share one range here. Read via `captureList`.
    capture_bytes: []const u8 = &.{},
    /// Source span ranges for cold-path error traces.
    source_map: []const SourceMapEntry = &.{},
    /// The span of the whole body node this chunk was compiled from — a
    /// representative source location for the chunk even when `source_map` is
    /// empty (it's sparse: entries are added only for tail apply/if/let/…
    /// constructs). Used by the timeline to label a thunk quantum / demand
    /// wait. Set at `stampOnBuilder`; null for chunks that skip it.
    body_span: ?SourceSpan = null,
    /// Formal-parameter pattern for `--xml` function rendering. See the type.
    lambda_pattern: LambdaPattern = .none,

    /// The capture-descriptor bytes for a `(start, count)` reference: `count`
    /// `(kind:1, index:2)` triples starting at `start` in `capture_bytes`.
    pub fn captureList(self: *const Chunk, start: u32, count: u16) []const u8 {
        return self.capture_bytes[start .. start + @as(usize, count) * 3];
    }

    pub fn deinit(self: *Chunk, allocator: std.mem.Allocator) void {
        allocator.free(self.code);
        allocator.free(self.constants);
        allocator.free(self.function_args);
        allocator.free(self.function_arg_pos);
        allocator.free(self.attr_pos);
        allocator.free(self.attr_names);
        allocator.free(self.capture_bytes);
        allocator.free(self.source_map);
    }
};

/// Compile-time signal of which upvalues a chunk's body will force.
/// Two depths:
///   `forced_upvalues` — forced when the body is evaluated to WHNF
///       (always, since entering a chunk runs its body).
///   `deep_upvalues`   — additionally forced when the result is deep-
///       forced by the caller. Covers structure-building chunks
///       (attr-sets, lists) whose body itself forces nothing but whose
///       contained values get forced if the result is walked.
pub const ChunkStrictness = struct {
    /// Upvalue slot N (0..63) is unconditionally forced when the chunk
    /// runs. Slots ≥ 64 are dropped silently — coverage degrades for
    /// chunks with many captures, which are rare.
    forced_upvalues: u64 = 0,
    /// Upvalue slot N is additionally forced when the result is
    /// recursively deep-forced. Superset of `forced_upvalues`.
    deep_upvalues: u64 = 0,
};

/// Compile-time classification of trivial chunk shapes. When a
/// chunk's entire body is a single value-load followed by ret, we can
/// short-circuit `thunk` and skip creating a thunk altogether
/// — just push the inlined value at the caller. Cuts a heap alloc, a
/// future force, a frame push/pop, and 2 dispatches per occurrence.
pub const TrivialBody = union(enum) {
    /// Not a trivial shape — full thunk creation required.
    none,
    /// Body is `up_get_ret upvalue[N]` (or `up_get N; ret`).
    /// At thunk we know upvalue N's value from the descriptor,
    /// so we push that value directly instead of allocating a thunk.
    identity_upvalue: u16,
    /// Body is `closure CL, 0; ret; halt` (or `closure_w`). The
    /// chunk wraps a zero-upvalue closure. At thunk we
    /// allocate the closure directly, skipping the thunk wrapper.
    /// Each invocation still gets a fresh closure ObjectId — same as
    /// running the body — but the thunk alloc + future force vanish.
    closure_zero: ChunkId,
    /// Body is `closure_cap CL, K, descriptors; ret; halt` with
    /// K >= 1 and every inner descriptor of kind=upvalue (which is
    /// guaranteed since thunk bodies have local_count == 0). At
    /// `thunk`, the closure's upvalue values can be resolved
    /// directly: inner_upvalue[i] = outer_descriptors[inner_idx[i]]
    /// evaluated against the outer frame. We compose the two
    /// descriptor layers and build the closure in place, skipping
    /// thunk creation entirely.
    closure_captures: ClosureCaptures,
    /// Body is `push_builtins; ret; halt` — the binding aliases the
    /// evaluator's builtins attrset. At thunk we push
    /// `vm.builtins` directly. Common via `with builtins;` blocks and
    /// `let lib = import ...; in ...` patterns where lib transitively
    /// embeds `builtins`.
    builtins,
    /// Body returns a compile-time-known `Value` — `push_const_ret #idx`
    /// (the constant is copied out of the pool at classify time, so the
    /// short-circuit never touches the Chunk) or one of
    /// `push_null|push_true|push_false; ret; halt`. Saves one heap
    /// alloc + one thunk force per binding.
    literal: Value,
    /// Body is `up_get_attr U N; ret; halt` (7 bytes) — the
    /// pervasive `someUpvalue.attr` thunk (`config.foo`, `lib.bar`,
    /// attrset-pattern param lookups). At thunk creation we resolve
    /// upvalue `U` from the descriptor and build a frameless
    /// `attr_access` thunk over (base, name), so forcing skips the
    /// isolated frame + bytecode dispatch and goes straight to
    /// `getAttrValue`.
    attr_access: AttrAccessShape,
};

pub const AttrAccessShape = struct {
    upvalue_index: u16,
    name: u16,
};

pub const ClosureCaptures = struct {
    closure_chunk_id: ChunkId,
    /// Slice into the *enclosing* chunk's `code` buffer where the
    /// inner descriptors live. Stored as (offset, len) since the
    /// classifier runs before the buffer is duped into the final
    /// Chunk — we resolve to a real slice at use time via
    /// `ch.code[offset..offset+len]`.
    inner_descriptors_offset: u16,
    inner_descriptors_len: u16,
};

/// All compile-time hints the scheduler uses when deciding whether to
/// submit a thunk for parallel forcing. Stamped at chunk-builder
/// finish, never mutated at runtime.
pub const SchedulingHints = struct {
    /// True when the chunk's bytecode body is large enough that a
    /// helper finishing it ahead of demand saves more than the
    /// scheduler submit/wake overhead costs. Cached here so the
    /// thunk-creation hot path doesn't have to re-read `code.len`.
    body_is_substantial: bool = false,
    /// True when the chunk's effective body size is below
    /// `SPECULATION_TRUSTED_CODE_BYTES`: its unattended speculative
    /// execution is NOT trusted (the sub-256 combinator family — small
    /// bodies whose one execution can recursively force multi-million-
    /// thunk never-demanded subgraphs). Speculative `force_thunk` tasks
    /// whose ROOT chunk carries this bit run under a hard creation
    /// budget (`Scheduler.spec_band_budget`); trusted (≥256) roots run
    /// unbudgeted as always. With the admission gate at its default
    /// (== trusted threshold) no such chunk is ever submitted, so the
    /// bit is dormant; it exists so lowering the admission gate — or a
    /// future aged-pool drain of the sub-256 family — is contained by
    /// construction instead of cascading (measured 2026-07: gate at 192
    /// unbudgeted = +15-52% w=8 wall; same gate under a 512 creation
    /// budget = baseline).
    spec_band_small: bool = false,
    /// See ChunkStrictness.
    strictness: ChunkStrictness = .{},
    /// Trivial-shape classification — see `TrivialBody`.
    trivial: TrivialBody = .none,
    /// True for a single-parameter lambda whose body unconditionally
    /// forces its parameter (sound must-force). Lets a caller that holds
    /// this closure at a `call` site evaluate the argument eagerly
    /// instead of thunking it — the runtime-known-callee analogue of the
    /// compiler's directly-applied-lambda eager arg. Only meaningful when
    /// `local_count == 1` (one param, no extra locals).
    strict_param: bool = false,
    /// Forwarding strictness: the body is exactly `f param` for a
    /// captured function `f` at this upvalue index, so the lambda forces
    /// its parameter *iff* `f` does. The caller resolves it at the call
    /// site (it holds the closure's upvalues). `null` when not a simple
    /// forwarder.
    strict_via_upvalue: ?u16 = null,
};

/// A mutable builder for constructing chunks.
pub const ChunkBuilder = struct {
    /// A distinct capture list's range in `capture_bytes` (for dedup scanning).
    pub const CaptureRange = struct { start: u32, len: u32 };

    code: std.ArrayListUnmanaged(u8),
    constants: std.ArrayListUnmanaged(Value),
    function_args: std.ArrayListUnmanaged(AttrEntry),
    function_arg_pos: std.ArrayListUnmanaged(AttrPosEntry) = .empty,
    source_map: std.ArrayListUnmanaged(Chunk.SourceMapEntry),
    /// Attr-position records collected by `emitBuildAttrsSorted` — carried
    /// onto `Chunk.attr_pos` at finish (see that field's doc).
    attr_pos: std.ArrayListUnmanaged(AttrPosEntry) = .empty,
    /// Attr names for `attrs_new_named*` — carried onto `Chunk.attr_names`.
    attr_names: std.ArrayListUnmanaged(types.InternId) = .empty,
    /// Deduped capture-descriptor bytes for `thunk_defer` — carried onto
    /// `Chunk.capture_bytes`. `capture_index` records each distinct list's
    /// range so `internCaptureList` can coalesce identical lists (an attrset's
    /// shared scope snapshot) by a linear scan — a chunk has only a handful of
    /// distinct lists even when it emits thousands of ops, so no map is needed.
    capture_bytes: std.ArrayListUnmanaged(u8) = .empty,
    capture_index: std.ArrayListUnmanaged(CaptureRange) = .empty,
    /// Total descriptor bytes that USED to be inline in code (summed per op,
    /// before dedup) — added to `sideTableWeight` so extracting them doesn't
    /// shrink the chunk's perceived size past the speculation cliff.
    capture_inline_weight: usize = 0,
    /// The body node's span (see `Chunk.body_span`). Set by `stampOnBuilder`.
    body_span: ?Chunk.SourceSpan = null,
    /// Byte offset of the start of the most recently written opcode.
    /// `null` when no op has been written or when the tail is no
    /// longer a single rewritable opcode (e.g. after a branch fixup
    /// patches an offset in place). Used by `emit.emitRet` to fuse
    /// the previous value-producing op into a `<op>_ret` super-op.
    last_op_offset: ?usize = null,
    /// Bytes saved by emit-time fusion (super-op rewrites). Added back
    /// to `code.items.len` when computing `body_is_substantial` so a
    /// chunk's perceived "weight" reflects the work it does, not the
    /// fusion-compressed encoding. Speculation tuning lives at a sharp
    /// cliff (see project-tier1-perf-session); shifting chunks across
    /// the threshold by 1 byte per fusion was a real regression.
    fusion_savings: u32 = 0,
    /// Strictness signature computed by `compiler/strictness.zig`
    /// after the body is compiled. Carried through `finish` onto the
    /// resulting Chunk via `SchedulingHints`.
    strictness: ChunkStrictness = .{},
    /// Single-param lambda whose body must-forces its parameter. Set by
    /// `compileLambda`; carried onto `SchedulingHints.strict_param`.
    strict_param: bool = false,
    /// See `SchedulingHints.strict_via_upvalue`. Set by `compileLambda`.
    strict_via_upvalue: ?u16 = null,
    /// Number of params the chunk consumes before the body runs — carried
    /// onto `Chunk.arity`. Set by `compileLambda` when it merges an
    /// adjacent value-lambda chain into one uncurried chunk; otherwise 1.
    arity: u16 = 1,
    /// Per-param must-force bitmask for an uncurried chunk — carried onto
    /// `Chunk.strict_params`. Set by `compileLambda`.
    strict_params: u8 = 0,
    /// Formal-parameter pattern for `--xml` rendering — carried onto
    /// `Chunk.lambda_pattern`. Set by `compileLambda`/`compileLambdaAttrs`.
    lambda_pattern: LambdaPattern = .none,

    pub fn init(allocator: std.mem.Allocator) !ChunkBuilder {
        var code = try std.ArrayListUnmanaged(u8).initCapacity(allocator, types.CHUNK_CODE_CAP);
        errdefer code.deinit(allocator);

        var constants = try std.ArrayListUnmanaged(Value).initCapacity(allocator, types.CHUNK_CONSTANTS_CAP);
        errdefer constants.deinit(allocator);

        return .{
            .code = code,
            .constants = constants,
            .function_args = .empty,
            .source_map = .empty,
        };
    }

    pub fn deinit(self: *ChunkBuilder, allocator: std.mem.Allocator) void {
        self.code.deinit(allocator);
        self.constants.deinit(allocator);
        self.function_args.deinit(allocator);
        self.function_arg_pos.deinit(allocator);
        self.source_map.deinit(allocator);
        self.attr_pos.deinit(allocator);
        self.attr_names.deinit(allocator);
        self.capture_bytes.deinit(allocator);
        self.capture_index.deinit(allocator);
    }

    /// Restore the freshly-initialized state, keeping buffer capacity —
    /// for the compiler's child-builder pool (`Compiler.acquireBuilder`).
    pub fn reset(self: *ChunkBuilder) void {
        self.code.clearRetainingCapacity();
        self.constants.clearRetainingCapacity();
        self.function_args.clearRetainingCapacity();
        self.function_arg_pos.clearRetainingCapacity();
        self.attr_pos.clearRetainingCapacity();
        self.attr_names.clearRetainingCapacity();
        self.capture_bytes.clearRetainingCapacity();
        self.capture_index.clearRetainingCapacity();
        self.capture_inline_weight = 0;
        self.source_map.clearRetainingCapacity();
        self.body_span = null;
        self.last_op_offset = null;
        self.fusion_savings = 0;
        self.strictness = .{};
        self.strict_param = false;
        self.strict_via_upvalue = null;
        self.arity = 1;
        self.strict_params = 0;
        self.lambda_pattern = .none;
    }

    /// Intern a capture-descriptor list (`descriptors` = `(kind:1, index:2)*`),
    /// returning its start offset in `capture_bytes`. Identical lists coalesce
    /// (an attrset's deferred values share one scope snapshot). A rare hash
    /// collision with different content just appends a non-shared copy.
    pub fn internCaptureList(self: *ChunkBuilder, allocator: std.mem.Allocator, descriptors: []const u8) !u32 {
        for (self.capture_index.items) |r| {
            if (r.len == descriptors.len and
                std.mem.eql(u8, self.capture_bytes.items[r.start .. r.start + r.len], descriptors))
                return r.start;
        }
        const start: u32 = @intCast(self.capture_bytes.items.len);
        try self.capture_bytes.appendSlice(allocator, descriptors);
        try self.capture_index.append(allocator, .{ .start = start, .len = @intCast(descriptors.len) });
        return start;
    }

    /// Write a single opcode byte.
    pub fn writeOp(self: *ChunkBuilder, allocator: std.mem.Allocator, op: OpCode) !void {
        self.last_op_offset = self.code.items.len;
        try self.code.append(allocator, @intFromEnum(op));
    }

    /// Write a single byte operand.
    pub fn writeByte(self: *ChunkBuilder, allocator: std.mem.Allocator, byte: u8) !void {
        try self.code.append(allocator, byte);
    }

    /// Write a two-byte operand (little-endian).
    pub fn writeU16(self: *ChunkBuilder, allocator: std.mem.Allocator, val: u16) !void {
        try encoding.writeU16(&self.code, allocator, val);
    }

    /// Write a four-byte operand (little-endian).
    pub fn writeU32(self: *ChunkBuilder, allocator: std.mem.Allocator, val: u32) !void {
        try encoding.writeU32(&self.code, allocator, val);
    }

    /// Add a constant to the pool and return its index.
    pub fn addConstant(self: *ChunkBuilder, allocator: std.mem.Allocator, val: Value) !ConstIdx {
        if (self.constants.items.len > std.math.maxInt(ConstIdx)) return error.TooManyConstants;
        try self.constants.append(allocator, val);
        return @intCast(self.constants.items.len - 1);
    }

    /// Emit a constant-loading instruction (op + 2-byte index).
    pub fn emitConstant(self: *ChunkBuilder, allocator: std.mem.Allocator, val: Value) !void {
        const idx = try self.addConstant(allocator, val);
        try self.writeOp(allocator, .push_const);
        try self.writeU16(allocator, idx);
    }

    pub fn setFunctionArgs(self: *ChunkBuilder, allocator: std.mem.Allocator, args: []const AttrEntry) !void {
        self.function_args.clearRetainingCapacity();
        try self.function_args.appendSlice(allocator, args);
    }

    pub fn setFunctionArgPositions(self: *ChunkBuilder, allocator: std.mem.Allocator, positions: []const AttrPosEntry) !void {
        self.function_arg_pos.clearRetainingCapacity();
        try self.function_arg_pos.appendSlice(allocator, positions);
    }

    pub fn addSourceMapEntry(self: *ChunkBuilder, allocator: std.mem.Allocator, start: usize, end: usize, span: Chunk.SourceSpan) !void {
        if (start >= end) return;
        try self.source_map.append(allocator, .{
            .start = @intCast(start),
            .end = @intCast(end),
            .span = span,
        });
    }

    /// Side-table compensation for `body_is_substantial`: attr positions and
    /// attr names used to live inline in the code stream (16 bytes per
    /// position record; 3 bytes per name — a `push_const` op + u16 index).
    /// Extracting them to side tables shrank `code.len`, but the speculation
    /// threshold (`SPECULATION_MIN_CODE_BYTES`) is tuned against the OLD
    /// effective sizes and sits on a sharp cliff — measured 2026-07: dropping
    /// effective chunk size by even 64 bytes cost +52% w=8 wall. These
    /// constants mirror the removed inline encodings so a chunk's perceived
    /// weight reflects the work it does, not the encoding; ANY future
    /// extraction of code bytes into a side table MUST add its own
    /// compensation here (same rule as `fusion_savings`).
    fn sideTableWeight(self: *const ChunkBuilder) usize {
        return self.attr_pos.items.len * 16 + self.attr_names.items.len * 3 + self.capture_inline_weight;
    }

    /// Finalize into an immutable Chunk.
    pub fn finish(self: *ChunkBuilder, allocator: std.mem.Allocator, local_count: u16) !Chunk {
        const code = try allocator.dupe(u8, self.code.items);
        errdefer allocator.free(code);
        const constants = try allocator.dupe(Value, self.constants.items);
        errdefer allocator.free(constants);
        const function_args = try allocator.dupe(AttrEntry, self.function_args.items);
        errdefer allocator.free(function_args);
        const function_arg_pos = try allocator.dupe(AttrPosEntry, self.function_arg_pos.items);
        errdefer allocator.free(function_arg_pos);
        const attr_pos = try allocator.dupe(AttrPosEntry, self.attr_pos.items);
        errdefer allocator.free(attr_pos);
        const attr_names = try allocator.dupe(types.InternId, self.attr_names.items);
        errdefer allocator.free(attr_names);
        const capture_bytes = try allocator.dupe(u8, self.capture_bytes.items);
        errdefer allocator.free(capture_bytes);
        const source_map = try allocator.dupe(Chunk.SourceMapEntry, self.source_map.items);
        return Chunk{
            .code = code,
            .constants = constants,
            .capture_bytes = capture_bytes,
            .local_count = local_count,
            .arity = self.arity,
            .strict_params = self.strict_params,
            .scheduling = .{
                .body_is_substantial = self.code.items.len + self.fusion_savings + self.sideTableWeight() >= SPECULATION_MIN_CODE_BYTES,
                .spec_band_small = self.code.items.len + self.fusion_savings + self.sideTableWeight() < SPECULATION_TRUSTED_CODE_BYTES,
                .strictness = self.strictness,
                .trivial = classifyTrivialBody(self.code.items, self.constants.items, local_count),
                .strict_param = self.strict_param and local_count == 1,
                .strict_via_upvalue = if (local_count == 1) self.strict_via_upvalue else null,
            },
            .function_args = function_args,
            .function_arg_pos = function_arg_pos,
            .attr_pos = attr_pos,
            .attr_names = attr_names,
            .source_map = source_map,
            .body_span = self.body_span,
            .lambda_pattern = self.lambda_pattern,
        };
    }
};

/// Classify the body of a freshly-built chunk as one of the trivial
/// shapes that let `thunk` skip thunk allocation entirely.
/// Run once at chunk-finish; result lives on the immutable Chunk so
/// the hot path reads it without re-parsing the bytecode.
fn classifyTrivialBody(code: []const u8, constants: []const Value, local_count: u16) TrivialBody {
    // Trivial-body short-circuit is only safe for chunks used as
    // *thunk bodies*. Thunk bodies have local_count == 0 (no args,
    // no temporaries). Closure bodies (lambdas) have local_count >= 1
    // for the param and may have additional locals. We must not
    // short-circuit those because `thunk` against a chunk
    // assumes the chunk is a thunk body, not a lambda body.
    if (local_count != 0) return .none;
    if (code.len < 2) return .none;
    const first: OpCode = @enumFromInt(code[0]);
    switch (first) {
        // `up_get_ret upvalue[N]; halt`
        // Layout: 1 byte op, 2 bytes upvalue idx, 1 byte halt.
        .up_get_ret => {
            if (code.len != 4) return .none;
            if (@as(OpCode, @enumFromInt(code[3])) != .halt) return .none;
            const idx = readU16Inline(code, 1);
            return .{ .identity_upvalue = idx };
        },
        // `push_const_ret #idx; halt` — 1 byte op, 2 bytes idx, 1 byte halt.
        .push_const_ret => {
            if (code.len != 4) return .none;
            if (@as(OpCode, @enumFromInt(code[3])) != .halt) return .none;
            const idx = readU16Inline(code, 1);
            if (idx >= constants.len) return .none;
            return .{ .literal = constants[idx] };
        },
        // `up_get_attr U N; ret; halt` — 1 + 2 + 2 + 1 + 1 = 7 bytes.
        .up_get_attr => {
            if (code.len != 7) return .none;
            if (@as(OpCode, @enumFromInt(code[5])) != .ret) return .none;
            if (@as(OpCode, @enumFromInt(code[6])) != .halt) return .none;
            return .{ .attr_access = .{
                .upvalue_index = readU16Inline(code, 1),
                .name = readU16Inline(code, 3),
            } };
        },
        // `push_builtins; ret; halt` — 1 + 1 + 1 = 3 bytes.
        .push_builtins => {
            if (code.len != 3) return .none;
            if (@as(OpCode, @enumFromInt(code[1])) != .ret) return .none;
            if (@as(OpCode, @enumFromInt(code[2])) != .halt) return .none;
            return .builtins;
        },
        // `push_null|push_true|push_false; ret; halt` — 3 bytes.
        // The compiler doesn't fuse these into a `_ret` super-op
        // (only `push_const`/`up_get`/`loc_get`/`loc_get_w`
        // are fused), so without the short-circuit each binding to
        // `null`/`true`/`false` allocates a thunk whose body trivially
        // returns the literal.
        .push_null, .push_true, .push_false => {
            if (code.len != 3) return .none;
            if (@as(OpCode, @enumFromInt(code[1])) != .ret) return .none;
            if (@as(OpCode, @enumFromInt(code[2])) != .halt) return .none;
            const literal: Value = switch (first) {
                .push_null => Value.null_val,
                .push_true => Value.boolVal(true),
                .push_false => Value.boolVal(false),
                else => unreachable,
            };
            return .{ .literal = literal };
        },
        // `closure CL, 0; ret; halt` — 1 op + 2 chunk_id + 2 upvalue_count + 1 ret + 1 halt = 7 bytes.
        .closure => {
            if (code.len != 7) return .none;
            if (@as(OpCode, @enumFromInt(code[5])) != .ret) return .none;
            if (@as(OpCode, @enumFromInt(code[6])) != .halt) return .none;
            const upvalue_count = readU16Inline(code, 3);
            if (upvalue_count != 0) return .none; // non-zero closure needs stack values
            return .{ .closure_zero = readU16Inline(code, 1) };
        },
        // `closure_w CL(4), 0; ret; halt` — 1 + 4 + 2 + 1 + 1 = 9 bytes.
        .closure_w => {
            if (code.len != 9) return .none;
            if (@as(OpCode, @enumFromInt(code[7])) != .ret) return .none;
            if (@as(OpCode, @enumFromInt(code[8])) != .halt) return .none;
            const upvalue_count = readU16Inline(code, 5);
            if (upvalue_count != 0) return .none;
            return .{ .closure_zero = readU32Inline(code, 1) };
        },
        // `closure_cap CL, K, descriptors(3K); ret; halt`
        // 1 op + 2 chunk_id + 2 K + 3K descriptors + 1 ret + 1 halt = 7 + 3K.
        .closure_cap => {
            if (code.len < 7) return .none;
            const k = readU16Inline(code, 3);
            if (k == 0) return .none; // shouldn't happen — emit drops to .closure when K==0
            const desc_len: usize = @as(usize, k) * 3;
            if (code.len != 7 + desc_len) return .none;
            if (@as(OpCode, @enumFromInt(code[5 + desc_len])) != .ret) return .none;
            if (@as(OpCode, @enumFromInt(code[6 + desc_len])) != .halt) return .none;
            // Inner descriptors must all be kind=upvalue (1) since the
            // thunk body has no locals. If the compiler ever emits
            // kind=local here it would read garbage, so refusing the
            // short-circuit is the safe fallback.
            var i: usize = 0;
            while (i < desc_len) : (i += 3) {
                if (code[5 + i] != 1) return .none;
            }
            return .{ .closure_captures = .{
                .closure_chunk_id = readU16Inline(code, 1),
                .inner_descriptors_offset = 5,
                .inner_descriptors_len = @intCast(desc_len),
            } };
        },
        // `closure_cap_w CL(4), K, descriptors(3K); ret; halt`
        // 1 + 4 + 2 + 3K + 1 + 1 = 9 + 3K.
        .closure_cap_w => {
            if (code.len < 9) return .none;
            const k = readU16Inline(code, 5);
            if (k == 0) return .none;
            const desc_len: usize = @as(usize, k) * 3;
            if (code.len != 9 + desc_len) return .none;
            if (@as(OpCode, @enumFromInt(code[7 + desc_len])) != .ret) return .none;
            if (@as(OpCode, @enumFromInt(code[8 + desc_len])) != .halt) return .none;
            var i: usize = 0;
            while (i < desc_len) : (i += 3) {
                if (code[7 + i] != 1) return .none;
            }
            return .{ .closure_captures = .{
                .closure_chunk_id = readU32Inline(code, 1),
                .inner_descriptors_offset = 7,
                .inner_descriptors_len = @intCast(desc_len),
            } };
        },
        else => return .none,
    }
}

inline fn readU16Inline(buf: []const u8, off: usize) u16 {
    return @as(u16, buf[off]) | (@as(u16, buf[off + 1]) << 8);
}

inline fn readU32Inline(buf: []const u8, off: usize) u32 {
    return @as(u32, buf[off]) |
        (@as(u32, buf[off + 1]) << 8) |
        (@as(u32, buf[off + 2]) << 16) |
        (@as(u32, buf[off + 3]) << 24);
}

/// Code length at or above which a chunk is considered substantial
/// enough that submitting its body to a helper at thunk-creation time
/// pays the scheduler hop. Used by `SchedulingHints.body_is_substantial`.
pub const SPECULATION_MIN_CODE_BYTES: usize = 256;

/// Effective size at or above which a chunk's speculative execution is
/// trusted to run WITHOUT a creation budget. Deliberately a separate
/// constant from the admission gate above: the admission gate says "worth
/// a scheduler hop", this one says "safe to run unattended" — see
/// `SchedulingHints.spec_band_small`. Keep at the 2026-07 sweep's
/// validated junk cliff (256) even if the admission gate moves.
pub const SPECULATION_TRUSTED_CODE_BYTES: usize = 256;

/// Well-known chunk ids registered eagerly at `ChunkRegistry.init`. These
/// are tiny stub chunks that builtins use to materialise lazy values
/// without allocating a per-element `builtin_closure` object — see
/// `genlist_apply` for the canonical example.
pub const WellKnownChunks = struct {
    /// Stub chunk for `builtins.genList` element thunks. Body:
    ///   `up_get 0; up_get 1; call_tail; ret; halt`
    /// Upvalues are `[func, index]`. Forcing the thunk calls
    /// `func index` and returns the result. Replaces the
    /// `builtin_closure(.mapValue, [func, index])` per element that
    /// would otherwise allocate one extra Object per genList slot.
    /// Reused by `builtins.map` since the body is the same single-arg
    /// application regardless of whether arg 1 is an index or a list
    /// item.
    genlist_apply: ChunkId,
    /// Stub chunk for `builtins.mapAttrs` element thunks. Body:
    ///   `up_get 0; up_get 1; call; up_get 2; call_tail;
    ///    ret; halt`
    /// Upvalues are `[func, name, value]`. Forcing the thunk calls
    /// `(func name) value` (partial application then tail call).
    /// Replaces the `builtin_closure(.mapAttrValue, ...)` + Thunk pair
    /// the old path allocated per attr.
    mapattrs_apply: ChunkId,
};

/// Global chunk registry. Chunks are stored here and referenced by ChunkId.
/// This is the "program" that the VM executes.
///
/// Thread safety:
///   - `get(id)` is lock-free.
///   - `register(chunk)` serializes on the underlying segments' writer mutex.
pub const ChunkRegistry = struct {
    /// Dense per-chunk slot: the Chunk pointer plus a copy of the hot
    /// scheduling metadata. The thunk-creation path (`thunk`,
    /// ~6M executions per NixOS toplevel) and the speculation gates only
    /// need `trivial`/`body_is_substantial`; reading them through `ptr`
    /// is a cache-missing deref into a heap-scattered Chunk, while the
    /// slot array is dense and hot chunk ids repeat. `ptr` is only
    /// dereferenced by paths that need the code/constants themselves.
    pub const ChunkSlot = struct {
        ptr: *Chunk,
        /// Qualified-name node in `name_tree` (0 = anonymous). Always populated
        /// (not gated), cheap, thread-safe — this is what traces/errors/disasm
        /// read for a chunk's `pkgs.hello`-style name.
        name: name_tree_mod.NameId = name_tree_mod.NAME_ROOT,
        trivial: TrivialBody,
        body_is_substantial: bool,
        /// Untrusted-band bit (see `SchedulingHints.spec_band_small`):
        /// speculative tasks rooted at this chunk run under the hard
        /// creation budget.
        spec_band_small: bool = false,
        strict_param: bool,
        strict_via_upvalue: ?u16,
        /// Novelty gate (`FIX_SPEC_NOVEL`): set by the FIRST creation-time
        /// speculative submission of any thunk of this chunk (see
        /// `markSpecSubmitted`). A never-before-submitted chunk is a new
        /// code region — a potential subsystem/chain root worth running
        /// ahead of the repeat-instance churn; later instances of the same
        /// chunk are the bulk speculation stream.
        spec_submitted: std.atomic.Value(u8) = .init(0),
    };

    const Store = stable.StableSegments(ChunkSlot, .{ .first_segment_size = 64 }, @import("runtime").mem_tag.vma);

    const dedup_shard_count = 64;
    /// One shard of the content-addressed dedup map. `align(cache_line)` on
    /// the shard lock keeps neighboring shards out of each other's cache
    /// lines (each shard is padded to a full line).
    const DedupShard = struct {
        mu: sync.SpinMutex align(std.atomic.cache_line) = .{},
        map: std.AutoHashMapUnmanaged(u64, ChunkId) = .empty,
    };

    allocator: std.mem.Allocator,
    chunks: Store,
    well_known: WellKnownChunks,
    /// Always-on qualified-name tree (see `name_tree.zig`). The compiler
    /// populates it; each `ChunkSlot.name` indexes into it. Unlike the
    /// `capture_names` sidecar below, this is cheap and thread-safe, so names
    /// are available in every run for traces/errors — not just under disasm.
    name_tree: name_tree_mod.NameTree = .{},
    /// Best-effort chunk-name sidecar for `fix disasm`: maps a chunk id to the
    /// attr/let binding name a lambda or thunk was compiled for. Populated only
    /// while `capture_names` is set — off by default so ordinary compiles pay
    /// nothing and the hot `Chunk` layout is untouched. Not concurrency-safe;
    /// only enabled for the single-threaded disasm compile.
    capture_names: bool = false,
    /// Debugger source-line-breakpoint patcher (see `BreakpointSink`). Null
    /// unless a debugger is attached.
    breakpoint_sink: ?BreakpointSink = null,
    /// Import-prefetch discovery hook for this registry. Keeping the hook on
    /// the registry prevents concurrently-live Evaluators from redirecting
    /// each other's newly compiled path constants.
    path_const_sink: ?PathConstSink = null,
    /// The thread that first recorded into the sidecar, captured lazily. The
    /// maps are not synchronized, so every `recordName`/`recordFile` must come
    /// from one thread; a debug assertion enforces it (see `checkSingleThread`).
    sidecar_owner: ?std.Thread.Id = null,
    /// The source file each chunk was compiled from (interned path id), so even
    /// chunks with no per-op source map get a file. Populated under name capture.
    files: std.AutoHashMapUnmanaged(ChunkId, types.InternId) = .empty,
    /// Per-chunk upvalue binding names (slot order), from the compiler's capture
    /// list. Slices owned by `allocator`. Chunk *names* live in `name_tree`.
    upvalue_names: std.AutoHashMapUnmanaged(ChunkId, []types.InternId) = .empty,
    /// Per-chunk LOCAL binding names indexed by stack slot (let bindings + lambda
    /// params). Slots are monotonic per chunk, so this is a flat slot→name array.
    /// Used by the debugger to resolve breakpoint-scope identifiers.
    local_names: std.AutoHashMapUnmanaged(ChunkId, []types.InternId) = .empty,
    /// Content-addressed dedup of chunk registrations: structurally identical
    /// chunks are semantically interchangeable, so re-registrations reuse the
    /// first id (the generalization of the hand-picked WellKnownChunks).
    /// Sharded by hash bits (see `DedupShard`): registrations come from every
    /// compiling worker (deferred bodies + speculative compiles, ~264K at
    /// w=8), and one global lock held across the full structural memcmp
    /// burned ~3-4% of all w=8 cycles in spin. Each shard carries its own
    /// lock, and the memcmp runs OUTSIDE it (see `registerDeduped`).
    dedup_shards: [dedup_shard_count]DedupShard = [_]DedupShard{.{}} ** dedup_shard_count,
    /// Single-threaded mode: when the owner guarantees exactly one thread
    /// ever registers chunks (a `--workers=1` evaluator; set before anything
    /// runs), `registerDeduped` skips the dedup shard mutexes and `register`
    /// takes the serial (CAS-free) slot append. ~2 lock RMWs + 1 CAS per
    /// registration elided (~213K registrations per NixOS-toplevel eval).
    /// Reads (`get`) were always lock-free. Default off.
    solo: bool = false,

    pub fn init(allocator: std.mem.Allocator) !ChunkRegistry {
        var self: ChunkRegistry = .{
            .allocator = allocator,
            .chunks = .empty,
            .well_known = .{ .genlist_apply = 0, .mapattrs_apply = 0 },
        };
        errdefer self.deinit();
        self.well_known.genlist_apply = try self.registerGenListApplyChunk();
        self.well_known.mapattrs_apply = try self.registerMapAttrsApplyChunk();
        return self;
    }

    fn registerGenListApplyChunk(self: *ChunkRegistry) !ChunkId {
        var builder = try ChunkBuilder.init(self.allocator);
        defer builder.deinit(self.allocator);

        // up_grab 0 — push func, unforced. builtinMap/builtinGenList
        // force fn_arg before storing it as upvalue 0, so it's already
        // callable.
        try builder.writeOp(self.allocator, .up_grab);
        try builder.writeU16(self.allocator, 0);
        // up_grab 1 — push index or item, *unforced*. Passing
        // unforced lets the user fn decide laziness — same reasoning as
        // the mapattrs_apply value upvalue (see registerMapAttrsApplyChunk).
        try builder.writeOp(self.allocator, .up_grab);
        try builder.writeU16(self.allocator, 1);
        // call_tail      — call func with index/item
        try builder.writeOp(self.allocator, .call_tail);
        // ret            — return result (call_tail to a closure transfers
        //                  control; ret only runs when callee was a builtin)
        try builder.writeOp(self.allocator, .ret);
        // halt           — sentinel
        try builder.writeOp(self.allocator, .halt);

        const chunk = try builder.finish(self.allocator, 0);
        return self.register(chunk);
    }

    fn registerMapAttrsApplyChunk(self: *ChunkRegistry) !ChunkId {
        var builder = try ChunkBuilder.init(self.allocator);
        defer builder.deinit(self.allocator);

        // up_grab 0 — push func, unforced. mapAttrs only takes
        // this path when fn_arg is already callable; no force needed.
        try builder.writeOp(self.allocator, .up_grab);
        try builder.writeU16(self.allocator, 0);
        // up_grab 1 — push name. mapAttrs stores `Value.string`
        // here, so force would be a no-op anyway.
        try builder.writeOp(self.allocator, .up_grab);
        try builder.writeU16(self.allocator, 1);
        // call           — partial = func name (result on stack)
        try builder.writeOp(self.allocator, .call);
        // up_grab 2 — push value *unforced*. `value` is whatever
        // the source attrset stored, typically a thunk. Forcing it here
        // (the old `up_get`) eagerly evaluated entries that the
        // user lambda would otherwise treat lazily — when the lambda
        // captures the parent recursive attrset (typical NixOS module
        // pattern), the eager force routes through that parent and
        // blackholes. Passing unforced lets the user lambda decide.
        try builder.writeOp(self.allocator, .up_grab);
        try builder.writeU16(self.allocator, 2);
        // call_tail      — partial value
        try builder.writeOp(self.allocator, .call_tail);
        try builder.writeOp(self.allocator, .ret);
        try builder.writeOp(self.allocator, .halt);

        const chunk = try builder.finish(self.allocator, 0);
        return self.register(chunk);
    }

    pub fn deinit(self: *ChunkRegistry) void {
        var id: u32 = 0;
        const total = self.chunks.count();
        while (id < total) : (id += 1) {
            const chunk = self.chunks.get(id).ptr;
            chunk.deinit(self.allocator);
            self.allocator.destroy(chunk);
        }
        self.chunks.deinit(self.allocator);
        self.files.deinit(self.allocator);
        var it = self.upvalue_names.valueIterator();
        while (it.next()) |v| self.allocator.free(v.*);
        self.upvalue_names.deinit(self.allocator);
        var lit = self.local_names.valueIterator();
        while (lit.next()) |v| self.allocator.free(v.*);
        self.local_names.deinit(self.allocator);
        self.name_tree.deinit(self.allocator);
        for (&self.dedup_shards) |*shard| shard.map.deinit(self.allocator);
    }

    /// Assert the unsynchronized sidecar maps are only ever touched from a
    /// single thread (the invariant that makes them safe without a lock). The
    /// first caller claims ownership; later callers must match. Debug-only.
    fn checkSingleThread(self: *ChunkRegistry) void {
        const tid = std.Thread.getCurrentId();
        if (self.sidecar_owner) |owner| {
            std.debug.assert(owner == tid);
        } else {
            self.sidecar_owner = tid;
        }
    }

    /// Record the source file a chunk was compiled from. No-op unless
    /// `capture_names` is on.
    pub fn recordFile(self: *ChunkRegistry, id: ChunkId, file: types.InternId) !void {
        if (!self.capture_names) return;
        self.checkSingleThread();
        try self.files.put(self.allocator, id, file);
    }

    /// Record the chunk's upvalue binding names (slot order). No-op unless
    /// `capture_names` is on; the slice is duped into the registry.
    pub fn recordUpvalueNames(self: *ChunkRegistry, id: ChunkId, names_in: []const types.InternId) !void {
        if (!self.capture_names or names_in.len == 0) return;
        self.checkSingleThread();
        const copy = try self.allocator.dupe(types.InternId, names_in);
        errdefer self.allocator.free(copy);
        const gop = try self.upvalue_names.getOrPut(self.allocator, id);
        if (gop.found_existing) self.allocator.free(gop.value_ptr.*);
        gop.value_ptr.* = copy;
    }

    /// The chunk's recorded upvalue names (slot order), if any.
    pub fn upvalueNamesOf(self: *const ChunkRegistry, id: ChunkId) ?[]const types.InternId {
        return self.upvalue_names.get(id);
    }

    /// Record the chunk's local binding names indexed by stack slot. No-op
    /// unless `capture_names` is on; the slice is duped into the registry.
    pub fn recordLocalNames(self: *ChunkRegistry, id: ChunkId, names_in: []const types.InternId) !void {
        if (!self.capture_names or names_in.len == 0) return;
        self.checkSingleThread();
        const copy = try self.allocator.dupe(types.InternId, names_in);
        errdefer self.allocator.free(copy);
        const gop = try self.local_names.getOrPut(self.allocator, id);
        if (gop.found_existing) self.allocator.free(gop.value_ptr.*);
        gop.value_ptr.* = copy;
    }

    /// The chunk's recorded local names (slot order), if any.
    pub fn localNamesOf(self: *const ChunkRegistry, id: ChunkId) ?[]const types.InternId {
        return self.local_names.get(id);
    }

    /// Write `id`'s always-on qualified name (`pkgs.hello`) into `w`, or nothing
    /// if the chunk is anonymous. Reads the `name_tree`; no allocation, no flag.
    pub fn writeQualifiedName(self: *const ChunkRegistry, w: *std.Io.Writer, id: ChunkId, intern: *const @import("runtime").intern.InternTable) !void {
        const s = self.slot(id) orelse return;
        try self.name_tree.writeQualified(w, s.name, intern);
    }

    /// Whether `id` has an always-on qualified name.
    pub fn hasQualifiedName(self: *const ChunkRegistry, id: ChunkId) bool {
        const s = self.slot(id) orelse return false;
        return self.name_tree.named(s.name);
    }

    /// Intern a child name under `parent` for `segment` (compiler use, during
    /// its top-down descent). `synthetic` selects the `·` joiner.
    pub fn childName(self: *ChunkRegistry, parent: name_tree_mod.NameId, segment: types.InternId, synthetic: bool) !name_tree_mod.NameId {
        return self.name_tree.child(self.allocator, parent, segment, synthetic);
    }

    /// The source file recorded for `id`, if any.
    pub fn fileOf(self: *const ChunkRegistry, id: ChunkId) ?types.InternId {
        return self.files.get(id);
    }

    /// Optional import-prefetch discovery sink (`FIX_IMPORT_PREFETCH`): when
    /// set (by the Evaluator, before workers start), `register` reports each
    /// freshly compiled chunk's `.path` constants so `.nix` file references
    /// can be speculatively parsed+compiled+evaluated on idle helpers ahead
    /// of the demand fiber. Deferred force-time compiles already register
    /// through this registry, so they feed the same per-Evaluator hook without
    /// additional compiler plumbing. Read-only after start; called concurrently
    /// from every compiling worker (the callee synchronizes and deduplicates).
    pub const PathConstSink = struct {
        ctx: *anyopaque,
        call: *const fn (ctx: *anyopaque, path_id: types.InternId) void,
    };
    /// Debugger hook: called for every chunk as it registers, so pending
    /// source-line breakpoints get patched into freshly (often lazily) compiled
    /// bodies — imports and deferred attrs register mid-evaluation. Null in
    /// every normal run. Per-registry (not a global) so it can't leak across
    /// evaluators. See `bytecode/breakpoints.zig`.
    pub const BreakpointSink = struct {
        ctx: *anyopaque,
        place: *const fn (ctx: *anyopaque, chunk_id: types.ChunkId, chunk: *Chunk) void,
    };

    // Every field of `Chunk` must either be covered by `contentHash` AND
    // `contentEql` or be derived from covered fields (`scheduling` is the
    // one derived field today): a semantic field missing from both silently
    // merges chunks that differ in it. If you add a field, teach BOTH
    // functions about it, then bump this count. Diagnostic-only metadata
    // (names, files, upvalue names, ...) belongs in the registry sidecar
    // maps instead — those are keyed by id after registration and never
    // perturb dedup.
    comptime {
        const chunk_field_count = 14;
        if (std.meta.fields(Chunk).len != chunk_field_count)
            @compileError("Chunk changed shape: update contentHash + contentEql (or route diagnostic-only metadata through the registry sidecar), then adjust chunk_field_count.");
    }

    /// Deterministic content hash over everything that makes a chunk what it
    /// is. Optionals/structs are fed field-by-field (never as raw bytes) so
    /// undefined padding can't perturb the hash.
    fn contentHash(chunk: *const Chunk) u64 {
        // The hash is only a bucket key — collisions fall through to
        // `contentEql`, which stays FULL. Instead of per-entry
        // attr_pos/source_map walks (the +512M instr/eval cost measured at
        // 77befca), mix in a cheap positional fingerprint: lens + first/last
        // source-map span line. Position-divergent clones collide into one
        // bucket and the loser registers normally via `contentEql`, so the
        // dedup rate is unchanged.
        var h = std.hash.Wyhash.init(0);
        h.update(chunk.code);
        h.update(std.mem.sliceAsBytes(chunk.constants));
        h.update(std.mem.sliceAsBytes(chunk.attr_names));
        h.update(chunk.capture_bytes);
        h.update(std.mem.sliceAsBytes(chunk.function_args));
        h.update(std.mem.sliceAsBytes(chunk.function_arg_pos));
        var fp: [4]u32 = .{ @intCast(chunk.attr_pos.len), @intCast(chunk.source_map.len), 0, 0 };
        if (chunk.source_map.len > 0) {
            fp[2] = chunk.source_map[0].span.line;
            fp[3] = chunk.source_map[chunk.source_map.len - 1].span.line;
        }
        h.update(std.mem.sliceAsBytes(&fp));
        if (chunk.body_span) |bs| hashSpan(&h, bs);
        h.update(std.mem.asBytes(&chunk.local_count));
        h.update(std.mem.asBytes(&chunk.arity));
        h.update(std.mem.asBytes(&chunk.strict_params));
        switch (chunk.lambda_pattern) {
            .none => h.update(&.{0}),
            .var_pat => |id| {
                h.update(&.{1});
                h.update(std.mem.asBytes(&id));
            },
            .attrs_pat => |ap| {
                h.update(&.{2});
                h.update(std.mem.asBytes(&ap.bind_name));
                h.update(std.mem.asBytes(&ap.has_bind));
                h.update(std.mem.asBytes(&ap.ellipsis));
            },
        }
        return h.final();
    }

    fn hashSpan(h: *std.hash.Wyhash, span: Chunk.SourceSpan) void {
        const file: types.InternId = span.file orelse 0xFFFF_FFFF;
        h.update(std.mem.asBytes(&file));
        h.update(std.mem.asBytes(&span.offset));
        h.update(std.mem.asBytes(&span.len));
        h.update(std.mem.asBytes(&span.line));
        h.update(std.mem.asBytes(&span.column));
    }

    fn spanEql(a: Chunk.SourceSpan, b: Chunk.SourceSpan) bool {
        return std.meta.eql(a.file, b.file) and a.offset == b.offset and a.len == b.len and a.line == b.line and a.column == b.column;
    }

    /// Full structural equality — byte/field-equal chunks are indistinguishable
    /// (identical semantics AND identical diagnostics/positions), so sharing
    /// one registration is observation-free.
    fn contentEql(a: *const Chunk, b: *const Chunk) bool {
        if (a.local_count != b.local_count or a.arity != b.arity or a.strict_params != b.strict_params) return false;
        if (!std.mem.eql(u8, a.code, b.code)) return false;
        if (!std.mem.eql(u8, std.mem.sliceAsBytes(a.constants), std.mem.sliceAsBytes(b.constants))) return false;
        if (!std.mem.eql(types.InternId, a.attr_names, b.attr_names)) return false;
        if (a.attr_pos.len != b.attr_pos.len) return false;
        for (a.attr_pos, b.attr_pos) |x, y| {
            if (x.name != y.name or x.pos.file != y.pos.file or x.pos.line != y.pos.line or x.pos.column != y.pos.column) return false;
        }
        if (!std.mem.eql(u8, std.mem.sliceAsBytes(a.function_args), std.mem.sliceAsBytes(b.function_args))) return false;
        if (a.function_arg_pos.len != b.function_arg_pos.len) return false;
        for (a.function_arg_pos, b.function_arg_pos) |x, y| {
            if (x.name != y.name or x.pos.file != y.pos.file or x.pos.line != y.pos.line or x.pos.column != y.pos.column) return false;
        }
        if (!std.mem.eql(u8, a.capture_bytes, b.capture_bytes)) return false;
        if (a.source_map.len != b.source_map.len) return false;
        for (a.source_map, b.source_map) |x, y| {
            if (x.start != y.start or x.end != y.end or !spanEql(x.span, y.span)) return false;
        }
        if ((a.body_span == null) != (b.body_span == null)) return false;
        if (a.body_span) |ba| if (!spanEql(ba, b.body_span.?)) return false;
        if (!lambdaPatternEql(a.lambda_pattern, b.lambda_pattern)) return false;
        return true;
    }

    fn lambdaPatternEql(a: LambdaPattern, b: LambdaPattern) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .none => true,
            .var_pat => |id| id == b.var_pat,
            .attrs_pat => |ap| ap.bind_name == b.attrs_pat.bind_name and
                ap.has_bind == b.attrs_pat.has_bind and ap.ellipsis == b.attrs_pat.ellipsis,
        };
    }

    /// Register `chunk`, reusing an existing structurally identical
    /// registration when possible (see `dedup_shards`). Returns the id and
    /// whether it was reused — reused=true means the caller still owns (and
    /// must deinit) its own copy of `chunk`.
    pub fn registerDeduped(self: *ChunkRegistry, chunk: Chunk, name: name_tree_mod.NameId) !struct { id: ChunkId, reused: bool } {
        const h = contentHash(&chunk);
        const shard = &self.dedup_shards[@as(usize, @intCast(h >> 58))];

        // Snapshot the candidate id under the shard lock; run the full
        // structural memcmp OUTSIDE it. Registered chunks are immutable and
        // ids are never removed, so a snapshot can't go stale — the lock only
        // has to protect the map itself.
        if (!self.solo) shard.mu.lock();
        const candidate = shard.map.get(h);
        if (!self.solo) shard.mu.unlock();

        if (candidate) |existing| {
            if (contentEql(self.get(existing).?, &chunk)) {
                return .{ .id = existing, .reused = true };
            }
            // Hash collision with different content. `h`'s map entry is
            // permanent (first writer wins, entries are never replaced), so
            // there is nothing to insert: register plain, as before.
            return .{ .id = try self.registerNamed(chunk, name), .reused = false };
        }

        const id = try self.registerNamed(chunk, name);
        if (!self.solo) shard.mu.lock();
        const inserted = blk: {
            const gop = shard.map.getOrPut(self.allocator, h) catch |err| {
                if (!self.solo) shard.mu.unlock();
                return err;
            };
            if (gop.found_existing) break :blk gop.value_ptr.*;
            gop.value_ptr.* = id;
            break :blk null;
        };
        if (!self.solo) shard.mu.unlock();
        const winner = inserted orelse return .{ .id = id, .reused = false };

        // A concurrent registration won the insert race for this hash while
        // we were registering. When it is content-equal (the common case: the
        // same body compiled speculatively on two workers), converge on the
        // winner id so equal registrations always resolve to one id. Our copy
        // is already owned by the registry — report reused=false so the
        // caller doesn't deinit it; it stays registered but unreferenced
        // (benign). A mere hash collision keeps our own id.
        if (contentEql(self.get(winner).?, self.get(id).?)) {
            return .{ .id = winner, .reused = false };
        }
        return .{ .id = id, .reused = false };
    }

    pub fn register(self: *ChunkRegistry, chunk: Chunk) !ChunkId {
        return self.registerNamed(chunk, name_tree_mod.NAME_ROOT);
    }

    /// `register`, tagging the chunk with its qualified-name node (see
    /// `name_tree`). The compiler passes the name it built while descending.
    pub fn registerNamed(self: *ChunkRegistry, chunk: Chunk, name: name_tree_mod.NameId) !ChunkId {
        const stored = try self.allocator.create(Chunk);
        errdefer {
            stored.deinit(self.allocator);
            self.allocator.destroy(stored);
        }
        stored.* = chunk;
        if (self.path_const_sink) |sink| {
            for (stored.constants) |c| {
                if (c.isPath()) sink.call(sink.ctx, c.asInternId());
            }
        }
        // Lock-free registration: many workers compile (deferred bodies +
        // speculative imports) concurrently; the writer-mutex append serialized
        // them per-chunk. `appendAtomic` CAS-bumps the cursor instead. In
        // solo mode (single-worker evaluator) the serial append drops the CAS.
        const new_slot: ChunkSlot = .{
            .ptr = stored,
            .name = name,
            .trivial = stored.scheduling.trivial,
            .body_is_substantial = stored.scheduling.body_is_substantial,
            .spec_band_small = stored.scheduling.spec_band_small,
            .strict_param = stored.scheduling.strict_param,
            .strict_via_upvalue = stored.scheduling.strict_via_upvalue,
        };
        const id = if (self.solo)
            try self.chunks.appendSerial(self.allocator, new_slot)
        else
            try self.chunks.appendAtomic(self.allocator, new_slot);
        // Debugger: patch any pending source-line breakpoints into this newly
        // registered body. Solo-only in practice (the debugger forces w=1), so
        // patching the just-published chunk races nothing.
        if (self.breakpoint_sink) |s| s.place(s.ctx, id, stored);
        return id;
    }

    pub fn get(self: *const ChunkRegistry, id: ChunkId) ?*const Chunk {
        if (id >= self.chunks.count()) return null;
        return self.chunks.get(id).ptr;
    }

    /// Dense-slot accessor for the hot metadata paths (see `ChunkSlot`).
    pub fn slot(self: *const ChunkRegistry, id: ChunkId) ?*const ChunkSlot {
        if (id >= self.chunks.count()) return null;
        return self.chunks.get(id);
    }

    /// Novelty test-and-set (`FIX_SPEC_NOVEL`): returns true exactly once
    /// per chunk — for the first caller ever to submit a creation-time
    /// speculation of this chunk. Atomic swap: concurrent first-instance
    /// creations on different workers race benignly (one wins the novel
    /// slot, the rest take the bulk lane).
    pub fn markSpecSubmitted(self: *ChunkRegistry, id: ChunkId) bool {
        if (id >= self.chunks.count()) return false;
        return self.chunks.getMut(id).spec_submitted.swap(1, .monotonic) == 0;
    }

    pub fn count(self: *const ChunkRegistry) u32 {
        return self.chunks.count();
    }

    pub const Stats = struct {
        chunks: u32,
        code_bytes: u64,
        const_count: u64,
        source_map_entries: u64,
        size_buckets: [6]u32, // <16, <64, <256, <1024, <4096, >=4096
        max_code_bytes: u32,
        /// Chunks with a non-empty strictness signature.
        with_strictness: u32,
        /// Chunks marked `speculatable` by the size heuristic.
        speculatable: u32,
        /// Chunks that are both speculatable AND have a non-empty
        /// strictness signature — the intersection that Phase B/C will
        /// be able to schedule deterministically instead of speculating.
        speculatable_with_strictness: u32,

        pub fn bucketLabel(index: usize) []const u8 {
            return switch (index) {
                0 => "<16",
                1 => "16-63",
                2 => "64-255",
                3 => "256-1023",
                4 => "1024-4095",
                5 => ">=4096",
                else => "?",
            };
        }
    };

    pub fn stats(self: *const ChunkRegistry) Stats {
        var result: Stats = .{
            .chunks = self.chunks.count(),
            .code_bytes = 0,
            .const_count = 0,
            .source_map_entries = 0,
            .size_buckets = [_]u32{0} ** 6,
            .max_code_bytes = 0,
            .with_strictness = 0,
            .speculatable = 0,
            .speculatable_with_strictness = 0,
        };
        var id: u32 = 0;
        while (id < result.chunks) : (id += 1) {
            const ch = self.chunks.get(id).ptr;
            const len: u32 = @intCast(ch.code.len);
            result.code_bytes += len;
            result.const_count += ch.constants.len;
            result.source_map_entries += ch.source_map.len;
            if (len > result.max_code_bytes) result.max_code_bytes = len;
            const bucket: usize = if (len < 16) 0
                else if (len < 64) 1
                else if (len < 256) 2
                else if (len < 1024) 3
                else if (len < 4096) 4
                else 5;
            result.size_buckets[bucket] += 1;
            const strict = ch.scheduling.strictness;
            const has_strict = (strict.forced_upvalues | strict.deep_upvalues) != 0;
            if (has_strict) result.with_strictness += 1;
            if (ch.scheduling.body_is_substantial) result.speculatable += 1;
            if (ch.scheduling.body_is_substantial and has_strict) result.speculatable_with_strictness += 1;
        }
        return result;
    }
};

test "chunk builder emits opcodes and operands into the code stream" {
    const allocator = std.testing.allocator;
    var builder = try ChunkBuilder.init(allocator);
    defer builder.deinit(allocator);

    try builder.writeOp(allocator, .loc_get);
    try builder.writeByte(allocator, 3);
    try builder.writeOp(allocator, .jump);
    try builder.writeU32(allocator, 10);

    var chunk = try builder.finish(allocator, 1);
    defer chunk.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 7), chunk.code.len);
    try std.testing.expectEqual(@intFromEnum(OpCode.loc_get), chunk.code[0]);
    try std.testing.expectEqual(@as(u8, 3), chunk.code[1]);
    try std.testing.expectEqual(@intFromEnum(OpCode.jump), chunk.code[2]);
    try std.testing.expectEqual(@as(u32, 10), readU32Inline(chunk.code, 3));
}

test "chunk path hooks are isolated per registry" {
    const allocator = std.testing.allocator;
    var left = try ChunkRegistry.init(allocator);
    defer left.deinit();
    var right = try ChunkRegistry.init(allocator);
    defer right.deinit();

    const Counter = struct {
        value: u32 = 0,

        fn note(ctx: *anyopaque, _: types.InternId) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.value += 1;
        }
    };
    var left_count: Counter = .{};
    var right_count: Counter = .{};
    left.path_const_sink = .{ .ctx = &left_count, .call = Counter.note };
    right.path_const_sink = .{ .ctx = &right_count, .call = Counter.note };

    var builder = try ChunkBuilder.init(allocator);
    defer builder.deinit(allocator);
    _ = try builder.addConstant(allocator, Value.path(17));
    const chunk = try builder.finish(allocator, 0);
    _ = try left.register(chunk);

    try std.testing.expectEqual(@as(u32, 1), left_count.value);
    try std.testing.expectEqual(@as(u32, 0), right_count.value);
}

test "chunk builder patches a forward jump offset after emission" {
    const allocator = std.testing.allocator;
    var builder = try ChunkBuilder.init(allocator);
    defer builder.deinit(allocator);

    try builder.writeOp(allocator, .jump_false);
    const patch_at = builder.code.items.len;
    try builder.writeU32(allocator, 0); // placeholder, patched below
    try builder.writeOp(allocator, .push_null);
    try builder.writeOp(allocator, .ret);

    // Patch the placeholder now that we know how far to jump.
    const target = builder.code.items.len;
    const offset: u32 = @intCast(target - (patch_at + 4));
    std.mem.writeInt(u32, builder.code.items[patch_at..][0..4], offset, .little);

    var chunk = try builder.finish(allocator, 0);
    defer chunk.deinit(allocator);

    const decoded = readU32Inline(chunk.code, patch_at);
    try std.testing.expectEqual(offset, decoded);
    // The patched jump should land exactly at the end of the code.
    try std.testing.expectEqual(chunk.code.len, patch_at + 4 + decoded);
}

test "addConstant appends without deduping identical values" {
    const allocator = std.testing.allocator;
    var builder = try ChunkBuilder.init(allocator);
    defer builder.deinit(allocator);

    const first = try builder.addConstant(allocator, Value.int(7));
    const second = try builder.addConstant(allocator, Value.int(7));

    try std.testing.expectEqual(@as(ConstIdx, 0), first);
    try std.testing.expectEqual(@as(ConstIdx, 1), second);
    try std.testing.expectEqual(@as(usize, 2), builder.constants.items.len);
}

test "emitConstant writes a constant op referencing the new pool index" {
    const allocator = std.testing.allocator;
    var builder = try ChunkBuilder.init(allocator);
    defer builder.deinit(allocator);

    try builder.emitConstant(allocator, Value.int(99));
    var chunk = try builder.finish(allocator, 0);
    defer chunk.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), chunk.constants.len);
    try std.testing.expectEqual(@as(i64, 99), chunk.constants[0].asInt());
    try std.testing.expectEqual(@intFromEnum(OpCode.push_const), chunk.code[0]);
    try std.testing.expectEqual(@as(u16, 0), readU16Inline(chunk.code, 1));
}

test "classifyTrivialBody recognizes a up_get_ret-only thunk body" {
    const allocator = std.testing.allocator;
    var builder = try ChunkBuilder.init(allocator);
    defer builder.deinit(allocator);

    try builder.writeOp(allocator, .up_get_ret);
    try builder.writeU16(allocator, 4);
    try builder.writeOp(allocator, .halt);

    // Thunk bodies have local_count == 0.
    var chunk = try builder.finish(allocator, 0);
    defer chunk.deinit(allocator);

    switch (chunk.scheduling.trivial) {
        .identity_upvalue => |idx| try std.testing.expectEqual(@as(u16, 4), idx),
        else => return error.TestUnexpectedResult,
    }
}

test "classifyTrivialBody recognizes a push_const_ret-only thunk body" {
    const allocator = std.testing.allocator;
    var builder = try ChunkBuilder.init(allocator);
    defer builder.deinit(allocator);

    try builder.emitConstant(allocator, Value.int(5));
    // emitConstant writes a plain `push_const` op; fuse it into
    // `push_const_ret` by hand the way the compiler's emit.zig would,
    // then append halt so the shape matches the classifier's expectation.
    builder.code.items[0] = @intFromEnum(OpCode.push_const_ret);
    try builder.writeOp(allocator, .halt);

    var chunk = try builder.finish(allocator, 0);
    defer chunk.deinit(allocator);

    switch (chunk.scheduling.trivial) {
        .literal => |v| try std.testing.expectEqual(@as(i64, 5), v.asInt()),
        else => return error.TestUnexpectedResult,
    }
}

test "classifyTrivialBody classifies a multi-instruction body as non-trivial" {
    const allocator = std.testing.allocator;
    var builder = try ChunkBuilder.init(allocator);
    defer builder.deinit(allocator);

    try builder.writeOp(allocator, .up_get);
    try builder.writeU16(allocator, 0);
    try builder.writeOp(allocator, .up_get);
    try builder.writeU16(allocator, 1);
    try builder.writeOp(allocator, .int_add);
    try builder.writeOp(allocator, .ret);
    try builder.writeOp(allocator, .halt);

    var chunk = try builder.finish(allocator, 0);
    defer chunk.deinit(allocator);

    try std.testing.expectEqual(TrivialBody.none, chunk.scheduling.trivial);
}

test "classifyTrivialBody never fires for chunks with locals (lambda bodies)" {
    const allocator = std.testing.allocator;
    var builder = try ChunkBuilder.init(allocator);
    defer builder.deinit(allocator);

    try builder.writeOp(allocator, .up_get_ret);
    try builder.writeU16(allocator, 0);
    try builder.writeOp(allocator, .halt);

    // local_count == 1 means this is a lambda body, not a thunk body,
    // so the short-circuit must not apply even though the bytes match
    // the up_get_ret shape exactly.
    var chunk = try builder.finish(allocator, 1);
    defer chunk.deinit(allocator);

    try std.testing.expectEqual(TrivialBody.none, chunk.scheduling.trivial);
}

test "chunk registry registers well-known chunks retrievable by id" {
    const allocator = std.testing.allocator;
    var registry = try ChunkRegistry.init(allocator);
    defer registry.deinit();

    const genlist_chunk = registry.get(registry.well_known.genlist_apply);
    try std.testing.expect(genlist_chunk != null);
    const mapattrs_chunk = registry.get(registry.well_known.mapattrs_apply);
    try std.testing.expect(mapattrs_chunk != null);

    // Two distinct well-known chunks must have distinct ids.
    try std.testing.expect(registry.well_known.genlist_apply != registry.well_known.mapattrs_apply);
}

test "chunk registry register/get round-trips a custom chunk" {
    const allocator = std.testing.allocator;
    var registry = try ChunkRegistry.init(allocator);
    defer registry.deinit();

    var builder = try ChunkBuilder.init(allocator);
    defer builder.deinit(allocator);
    try builder.emitConstant(allocator, Value.int(123));
    try builder.writeOp(allocator, .ret);
    try builder.writeOp(allocator, .halt);
    const built = try builder.finish(allocator, 0);

    const id = try registry.register(built);
    const fetched = registry.get(id) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(@as(usize, 1), fetched.constants.len);
    try std.testing.expectEqual(@as(i64, 123), fetched.constants[0].asInt());
}

test "chunk registry get returns null for an out-of-range id" {
    const allocator = std.testing.allocator;
    var registry = try ChunkRegistry.init(allocator);
    defer registry.deinit();

    try std.testing.expect(registry.get(std.math.maxInt(ChunkId)) == null);
}

/// Small chunk for the dedup tests: `push_const <const_val>; ret; halt` with
/// a body span on `line`, so a test can vary exactly one semantic ingredient
/// (constant bits / span) at a time.
fn buildDedupTestChunk(allocator: std.mem.Allocator, const_val: i64, line: u32) !Chunk {
    var builder = try ChunkBuilder.init(allocator);
    defer builder.deinit(allocator);
    try builder.emitConstant(allocator, Value.int(const_val));
    try builder.writeOp(allocator, .ret);
    try builder.writeOp(allocator, .halt);
    builder.body_span = .{ .file = null, .offset = 0, .len = 5, .line = line, .column = 1 };
    return builder.finish(allocator, 0);
}

test "chunk dedup: structurally identical registrations share one id" {
    const allocator = std.testing.allocator;
    var registry = try ChunkRegistry.init(allocator);
    defer registry.deinit();

    const first = try registry.registerDeduped(try buildDedupTestChunk(allocator, 7, 1), name_tree_mod.NAME_ROOT);
    try std.testing.expect(!first.reused);

    var copy = try buildDedupTestChunk(allocator, 7, 1);
    const second = try registry.registerDeduped(copy, name_tree_mod.NAME_ROOT);
    try std.testing.expect(second.reused);
    try std.testing.expectEqual(first.id, second.id);
    // reused=true ⇒ the registry kept the first registration; the caller
    // still owns (and must free) its own copy.
    copy.deinit(allocator);
}

test "chunk dedup: a differing constant or span is a distinct registration" {
    const allocator = std.testing.allocator;
    var registry = try ChunkRegistry.init(allocator);
    defer registry.deinit();

    const base = try registry.registerDeduped(try buildDedupTestChunk(allocator, 7, 1), name_tree_mod.NAME_ROOT);
    const other_const = try registry.registerDeduped(try buildDedupTestChunk(allocator, 8, 1), name_tree_mod.NAME_ROOT);
    const other_span = try registry.registerDeduped(try buildDedupTestChunk(allocator, 7, 2), name_tree_mod.NAME_ROOT);

    try std.testing.expect(!other_const.reused);
    try std.testing.expect(!other_span.reused);
    try std.testing.expect(base.id != other_const.id);
    try std.testing.expect(base.id != other_span.id);
    try std.testing.expect(other_const.id != other_span.id);
}

test "chunk dedup: concurrent registrations converge (equal) and stay distinct (unique)" {
    const allocator = std.testing.allocator;
    var registry = try ChunkRegistry.init(allocator);
    defer registry.deinit();

    const thread_count = 8;
    const iterations = 64;

    var equal_ids: [thread_count][iterations]ChunkId = undefined;
    var distinct_ids: [thread_count][iterations]ChunkId = undefined;

    const Worker = struct {
        fn run(reg: *ChunkRegistry, alloc: std.mem.Allocator, t_idx: usize, equal_out: []ChunkId, distinct_out: []ChunkId) void {
            for (equal_out, distinct_out, 0..) |*e, *d, i| {
                // Same content on every thread and iteration: every
                // registration must resolve to ONE converged id, whichever
                // thread's shard-map insert won the race (`registerDeduped`
                // returns the winner even for the losing racer).
                var equal = buildDedupTestChunk(alloc, 4242, 1) catch @panic("chunk build failed");
                const re = reg.registerDeduped(equal, name_tree_mod.NAME_ROOT) catch @panic("registerDeduped failed");
                if (re.reused) equal.deinit(alloc);
                e.* = re.id;

                // Per-(thread, iteration) unique constant: never merged.
                var distinct = buildDedupTestChunk(alloc, @intCast(t_idx * 100_000 + i), 1) catch @panic("chunk build failed");
                const rd = reg.registerDeduped(distinct, name_tree_mod.NAME_ROOT) catch @panic("registerDeduped failed");
                if (rd.reused) distinct.deinit(alloc);
                d.* = rd.id;
            }
        }
    };

    var threads: [thread_count]std.Thread = undefined;
    for (&threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{ &registry, allocator, i, &equal_ids[i], &distinct_ids[i] });
    }
    for (&threads) |t| t.join();

    const converged = equal_ids[0][0];
    for (equal_ids) |row| {
        for (row) |id| try std.testing.expectEqual(converged, id);
    }

    var seen: std.AutoHashMapUnmanaged(ChunkId, void) = .empty;
    defer seen.deinit(allocator);
    for (distinct_ids) |row| {
        for (row) |id| {
            try std.testing.expect(id != converged);
            const gop = try seen.getOrPut(allocator, id);
            try std.testing.expect(!gop.found_existing);
        }
    }
}
