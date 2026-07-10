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
const stable = @import("base").segments;
const ChunkId = types.ChunkId;
const ConstIdx = types.ConstIdx;

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
    /// eager-arg optimization the single-param path gets via `apply_arg`
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
    /// Source span ranges for cold-path error traces.
    source_map: []const SourceMapEntry = &.{},
    /// The span of the whole body node this chunk was compiled from — a
    /// representative source location for the chunk even when `source_map` is
    /// empty (it's sparse: entries are added only for tail apply/if/let/…
    /// constructs). Used by the timeline to label a thunk quantum / demand
    /// wait. Set at `stampOnBuilder`; null for chunks that skip it.
    body_span: ?SourceSpan = null,

    pub fn deinit(self: *Chunk, allocator: std.mem.Allocator) void {
        allocator.free(self.code);
        allocator.free(self.constants);
        allocator.free(self.function_args);
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
/// short-circuit `thunk_captures` and skip creating a thunk altogether
/// — just push the inlined value at the caller. Cuts a heap alloc, a
/// future force, a frame push/pop, and 2 dispatches per occurrence.
pub const TrivialBody = union(enum) {
    /// Not a trivial shape — full thunk creation required.
    none,
    /// Body is `get_upvalue_ret upvalue[N]` (or `get_upvalue N; ret`).
    /// At thunk_captures we know upvalue N's value from the descriptor,
    /// so we push that value directly instead of allocating a thunk.
    identity_upvalue: u16,
    /// Body is `closure CL, 0; ret; halt` (or `closure_long`). The
    /// chunk wraps a zero-upvalue closure. At thunk_captures we
    /// allocate the closure directly, skipping the thunk wrapper.
    /// Each invocation still gets a fresh closure ObjectId — same as
    /// running the body — but the thunk alloc + future force vanish.
    closure_zero: ChunkId,
    /// Body is `closure_captures CL, K, descriptors; ret; halt` with
    /// K >= 1 and every inner descriptor of kind=upvalue (which is
    /// guaranteed since thunk bodies have local_count == 0). At
    /// `thunk_captures`, the closure's upvalue values can be resolved
    /// directly: inner_upvalue[i] = outer_descriptors[inner_idx[i]]
    /// evaluated against the outer frame. We compose the two
    /// descriptor layers and build the closure in place, skipping
    /// thunk creation entirely.
    closure_captures: ClosureCaptures,
    /// Body is `push_builtins; ret; halt` — the binding aliases the
    /// evaluator's builtins attrset. At thunk_captures we push
    /// `vm.builtins` directly. Common via `with builtins;` blocks and
    /// `let lib = import ...; in ...` patterns where lib transitively
    /// embeds `builtins`.
    builtins,
    /// Body returns a compile-time-known `Value` — `constant_ret #idx`
    /// (the constant is copied out of the pool at classify time, so the
    /// short-circuit never touches the Chunk) or one of
    /// `push_null|push_true|push_false; ret; halt`. Saves one heap
    /// alloc + one thunk force per binding.
    literal: Value,
    /// Body is `get_upvalue_attr U N; ret; halt` (7 bytes) — the
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
    code: std.ArrayListUnmanaged(u8),
    constants: std.ArrayListUnmanaged(Value),
    function_args: std.ArrayListUnmanaged(AttrEntry),
    source_map: std.ArrayListUnmanaged(Chunk.SourceMapEntry),
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
        self.source_map.deinit(allocator);
    }

    /// Restore the freshly-initialized state, keeping buffer capacity —
    /// for the compiler's child-builder pool (`Compiler.acquireBuilder`).
    pub fn reset(self: *ChunkBuilder) void {
        self.code.clearRetainingCapacity();
        self.constants.clearRetainingCapacity();
        self.function_args.clearRetainingCapacity();
        self.source_map.clearRetainingCapacity();
        self.body_span = null;
        self.last_op_offset = null;
        self.fusion_savings = 0;
        self.strictness = .{};
        self.strict_param = false;
        self.strict_via_upvalue = null;
        self.arity = 1;
        self.strict_params = 0;
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
        try self.writeOp(allocator, .constant);
        try self.writeU16(allocator, idx);
    }

    pub fn setFunctionArgs(self: *ChunkBuilder, allocator: std.mem.Allocator, args: []const AttrEntry) !void {
        self.function_args.clearRetainingCapacity();
        try self.function_args.appendSlice(allocator, args);
    }

    pub fn addSourceMapEntry(self: *ChunkBuilder, allocator: std.mem.Allocator, start: usize, end: usize, span: Chunk.SourceSpan) !void {
        if (start >= end) return;
        try self.source_map.append(allocator, .{
            .start = @intCast(start),
            .end = @intCast(end),
            .span = span,
        });
    }

    /// Finalize into an immutable Chunk.
    pub fn finish(self: *ChunkBuilder, allocator: std.mem.Allocator, local_count: u16) !Chunk {
        const code = try allocator.dupe(u8, self.code.items);
        errdefer allocator.free(code);
        const constants = try allocator.dupe(Value, self.constants.items);
        errdefer allocator.free(constants);
        const function_args = try allocator.dupe(AttrEntry, self.function_args.items);
        errdefer allocator.free(function_args);
        const source_map = try allocator.dupe(Chunk.SourceMapEntry, self.source_map.items);
        return Chunk{
            .code = code,
            .constants = constants,
            .local_count = local_count,
            .arity = self.arity,
            .strict_params = self.strict_params,
            .scheduling = .{
                .body_is_substantial = self.code.items.len + self.fusion_savings >= SPECULATION_MIN_CODE_BYTES,
                .strictness = self.strictness,
                .trivial = classifyTrivialBody(self.code.items, self.constants.items, local_count),
                .strict_param = self.strict_param and local_count == 1,
                .strict_via_upvalue = if (local_count == 1) self.strict_via_upvalue else null,
            },
            .function_args = function_args,
            .source_map = source_map,
            .body_span = self.body_span,
        };
    }
};

/// Classify the body of a freshly-built chunk as one of the trivial
/// shapes that let `thunk_captures` skip thunk allocation entirely.
/// Run once at chunk-finish; result lives on the immutable Chunk so
/// the hot path reads it without re-parsing the bytecode.
fn classifyTrivialBody(code: []const u8, constants: []const Value, local_count: u16) TrivialBody {
    // Trivial-body short-circuit is only safe for chunks used as
    // *thunk bodies*. Thunk bodies have local_count == 0 (no args,
    // no temporaries). Closure bodies (lambdas) have local_count >= 1
    // for the param and may have additional locals. We must not
    // short-circuit those because `thunk_captures` against a chunk
    // assumes the chunk is a thunk body, not a lambda body.
    if (local_count != 0) return .none;
    if (code.len < 2) return .none;
    const first: OpCode = @enumFromInt(code[0]);
    switch (first) {
        // `get_upvalue_ret upvalue[N]; halt`
        // Layout: 1 byte op, 2 bytes upvalue idx, 1 byte halt.
        .get_upvalue_ret => {
            if (code.len != 4) return .none;
            if (@as(OpCode, @enumFromInt(code[3])) != .halt) return .none;
            const idx = readU16Inline(code, 1);
            return .{ .identity_upvalue = idx };
        },
        // `constant_ret #idx; halt` — 1 byte op, 2 bytes idx, 1 byte halt.
        .constant_ret => {
            if (code.len != 4) return .none;
            if (@as(OpCode, @enumFromInt(code[3])) != .halt) return .none;
            const idx = readU16Inline(code, 1);
            if (idx >= constants.len) return .none;
            return .{ .literal = constants[idx] };
        },
        // `get_upvalue_attr U N; ret; halt` — 1 + 2 + 2 + 1 + 1 = 7 bytes.
        .get_upvalue_attr => {
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
        // (only `constant`/`get_upvalue`/`get_local`/`get_local_long`
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
        // `closure_long CL(4), 0; ret; halt` — 1 + 4 + 2 + 1 + 1 = 9 bytes.
        .closure_long => {
            if (code.len != 9) return .none;
            if (@as(OpCode, @enumFromInt(code[7])) != .ret) return .none;
            if (@as(OpCode, @enumFromInt(code[8])) != .halt) return .none;
            const upvalue_count = readU16Inline(code, 5);
            if (upvalue_count != 0) return .none;
            return .{ .closure_zero = readU32Inline(code, 1) };
        },
        // `closure_captures CL, K, descriptors(3K); ret; halt`
        // 1 op + 2 chunk_id + 2 K + 3K descriptors + 1 ret + 1 halt = 7 + 3K.
        .closure_captures => {
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
        // `closure_captures_long CL(4), K, descriptors(3K); ret; halt`
        // 1 + 4 + 2 + 3K + 1 + 1 = 9 + 3K.
        .closure_captures_long => {
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

/// Well-known chunk ids registered eagerly at `ChunkRegistry.init`. These
/// are tiny stub chunks that builtins use to materialise lazy values
/// without allocating a per-element `builtin_closure` object — see
/// `genlist_apply` for the canonical example.
pub const WellKnownChunks = struct {
    /// Stub chunk for `builtins.genList` element thunks. Body:
    ///   `get_upvalue 0; get_upvalue 1; tail_call; ret; halt`
    /// Upvalues are `[func, index]`. Forcing the thunk calls
    /// `func index` and returns the result. Replaces the
    /// `builtin_closure(.mapValue, [func, index])` per element that
    /// would otherwise allocate one extra Object per genList slot.
    /// Reused by `builtins.map` since the body is the same single-arg
    /// application regardless of whether arg 1 is an index or a list
    /// item.
    genlist_apply: ChunkId,
    /// Stub chunk for `builtins.mapAttrs` element thunks. Body:
    ///   `get_upvalue 0; get_upvalue 1; call; get_upvalue 2; tail_call;
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
    /// scheduling metadata. The thunk-creation path (`thunk_captures`,
    /// ~6M executions per NixOS toplevel) and the speculation gates only
    /// need `trivial`/`body_is_substantial`; reading them through `ptr`
    /// is a cache-missing deref into a heap-scattered Chunk, while the
    /// slot array is dense and hot chunk ids repeat. `ptr` is only
    /// dereferenced by paths that need the code/constants themselves.
    pub const ChunkSlot = struct {
        ptr: *Chunk,
        trivial: TrivialBody,
        body_is_substantial: bool,
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

    allocator: std.mem.Allocator,
    chunks: Store,
    well_known: WellKnownChunks,
    /// Best-effort chunk-name sidecar for `fix disasm`: maps a chunk id to the
    /// attr/let binding name a lambda or thunk was compiled for. Populated only
    /// while `capture_names` is set — off by default so ordinary compiles pay
    /// nothing and the hot `Chunk` layout is untouched. Not concurrency-safe;
    /// only enabled for the single-threaded disasm compile.
    capture_names: bool = false,
    names: std.AutoHashMapUnmanaged(ChunkId, types.InternId) = .empty,
    /// Companion to `names`: the source file each chunk was compiled from
    /// (interned path id), so even chunks with no per-op source map get a file.
    files: std.AutoHashMapUnmanaged(ChunkId, types.InternId) = .empty,

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

        // capture_upvalue 0 — push func, unforced. builtinMap/builtinGenList
        // force fn_arg before storing it as upvalue 0, so it's already
        // callable.
        try builder.writeOp(self.allocator, .capture_upvalue);
        try builder.writeU16(self.allocator, 0);
        // capture_upvalue 1 — push index or item, *unforced*. Passing
        // unforced lets the user fn decide laziness — same reasoning as
        // the mapattrs_apply value upvalue (see registerMapAttrsApplyChunk).
        try builder.writeOp(self.allocator, .capture_upvalue);
        try builder.writeU16(self.allocator, 1);
        // tail_call      — call func with index/item
        try builder.writeOp(self.allocator, .tail_call);
        // ret            — return result (tail_call to a closure transfers
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

        // capture_upvalue 0 — push func, unforced. mapAttrs only takes
        // this path when fn_arg is already callable; no force needed.
        try builder.writeOp(self.allocator, .capture_upvalue);
        try builder.writeU16(self.allocator, 0);
        // capture_upvalue 1 — push name. mapAttrs stores `Value.string`
        // here, so force would be a no-op anyway.
        try builder.writeOp(self.allocator, .capture_upvalue);
        try builder.writeU16(self.allocator, 1);
        // call           — partial = func name (result on stack)
        try builder.writeOp(self.allocator, .call);
        // capture_upvalue 2 — push value *unforced*. `value` is whatever
        // the source attrset stored, typically a thunk. Forcing it here
        // (the old `get_upvalue`) eagerly evaluated entries that the
        // user lambda would otherwise treat lazily — when the lambda
        // captures the parent recursive attrset (typical NixOS module
        // pattern), the eager force routes through that parent and
        // blackholes. Passing unforced lets the user lambda decide.
        try builder.writeOp(self.allocator, .capture_upvalue);
        try builder.writeU16(self.allocator, 2);
        // tail_call      — partial value
        try builder.writeOp(self.allocator, .tail_call);
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
        self.names.deinit(self.allocator);
        self.files.deinit(self.allocator);
    }

    /// Record a best-effort name for a chunk. No-op unless `capture_names` is
    /// on, so callers can hand names unconditionally.
    pub fn recordName(self: *ChunkRegistry, id: ChunkId, name: types.InternId) !void {
        if (!self.capture_names) return;
        try self.names.put(self.allocator, id, name);
    }

    /// Record the source file a chunk was compiled from. No-op unless
    /// `capture_names` is on.
    pub fn recordFile(self: *ChunkRegistry, id: ChunkId, file: types.InternId) !void {
        if (!self.capture_names) return;
        try self.files.put(self.allocator, id, file);
    }

    /// The best-effort name attributed to `id`, if any.
    pub fn nameOf(self: *const ChunkRegistry, id: ChunkId) ?types.InternId {
        return self.names.get(id);
    }

    /// The source file recorded for `id`, if any.
    pub fn fileOf(self: *const ChunkRegistry, id: ChunkId) ?types.InternId {
        return self.files.get(id);
    }

    /// Optional import-prefetch discovery sink (`FIX_IMPORT_PREFETCH`): when
    /// set (by the Evaluator, before workers start), `register` reports each
    /// freshly compiled chunk's `.path` constants so `.nix` file references
    /// can be speculatively parsed+compiled+evaluated on idle helpers ahead
    /// of the demand fiber. A module-level hook (not a registry field) so
    /// the deferred force-time compiles — which build Compilers from bare
    /// registry/intern/heap refs — feed it without extra plumbing. Read-only
    /// after start; called concurrently from every compiling worker (the
    /// callee handles its own synchronization/dedup).
    pub const PathConstSink = struct {
        ctx: *anyopaque,
        call: *const fn (ctx: *anyopaque, path_id: types.InternId) void,
    };
    pub var path_const_sink: ?PathConstSink = null;

    pub fn register(self: *ChunkRegistry, chunk: Chunk) !ChunkId {
        const stored = try self.allocator.create(Chunk);
        errdefer {
            stored.deinit(self.allocator);
            self.allocator.destroy(stored);
        }
        stored.* = chunk;
        if (path_const_sink) |sink| {
            for (stored.constants) |c| {
                if (c.isPath()) sink.call(sink.ctx, c.asInternId());
            }
        }
        // Lock-free registration: many workers compile (deferred bodies +
        // speculative imports) concurrently; the writer-mutex append serialized
        // them per-chunk. `appendAtomic` CAS-bumps the cursor instead.
        return try self.chunks.appendAtomic(self.allocator, .{
            .ptr = stored,
            .trivial = stored.scheduling.trivial,
            .body_is_substantial = stored.scheduling.body_is_substantial,
            .strict_param = stored.scheduling.strict_param,
            .strict_via_upvalue = stored.scheduling.strict_via_upvalue,
        });
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

    try builder.writeOp(allocator, .get_local);
    try builder.writeByte(allocator, 3);
    try builder.writeOp(allocator, .jump);
    try builder.writeU32(allocator, 10);

    var chunk = try builder.finish(allocator, 1);
    defer chunk.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 7), chunk.code.len);
    try std.testing.expectEqual(@intFromEnum(OpCode.get_local), chunk.code[0]);
    try std.testing.expectEqual(@as(u8, 3), chunk.code[1]);
    try std.testing.expectEqual(@intFromEnum(OpCode.jump), chunk.code[2]);
    try std.testing.expectEqual(@as(u32, 10), readU32Inline(chunk.code, 3));
}

test "chunk builder patches a forward jump offset after emission" {
    const allocator = std.testing.allocator;
    var builder = try ChunkBuilder.init(allocator);
    defer builder.deinit(allocator);

    try builder.writeOp(allocator, .jump_if_false);
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
    try std.testing.expectEqual(@intFromEnum(OpCode.constant), chunk.code[0]);
    try std.testing.expectEqual(@as(u16, 0), readU16Inline(chunk.code, 1));
}

test "classifyTrivialBody recognizes a get_upvalue_ret-only thunk body" {
    const allocator = std.testing.allocator;
    var builder = try ChunkBuilder.init(allocator);
    defer builder.deinit(allocator);

    try builder.writeOp(allocator, .get_upvalue_ret);
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

test "classifyTrivialBody recognizes a constant_ret-only thunk body" {
    const allocator = std.testing.allocator;
    var builder = try ChunkBuilder.init(allocator);
    defer builder.deinit(allocator);

    try builder.emitConstant(allocator, Value.int(5));
    // emitConstant writes a plain `constant` op; fuse it into
    // `constant_ret` by hand the way the compiler's emit.zig would,
    // then append halt so the shape matches the classifier's expectation.
    builder.code.items[0] = @intFromEnum(OpCode.constant_ret);
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

    try builder.writeOp(allocator, .get_upvalue);
    try builder.writeU16(allocator, 0);
    try builder.writeOp(allocator, .get_upvalue);
    try builder.writeU16(allocator, 1);
    try builder.writeOp(allocator, .add_int);
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

    try builder.writeOp(allocator, .get_upvalue_ret);
    try builder.writeU16(allocator, 0);
    try builder.writeOp(allocator, .halt);

    // local_count == 1 means this is a lambda body, not a thunk body,
    // so the short-circuit must not apply even though the bytes match
    // the get_upvalue_ret shape exactly.
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
