//! Bytecode chunk — a sequence of opcodes and a constant pool.
//!
//! Chunks are immutable after construction. They are identified by ChunkId
//! in a global table, enabling cheap interning and cross-thread referencing.

const std = @import("std");
const types = @import("../runtime/types.zig");
const encoding = @import("encoding.zig");
const OpCode = @import("opcode.zig").OpCode;
const Value = @import("../runtime/value.zig").Value;
const AttrEntry = @import("../runtime/heap.zig").AttrEntry;
const stable = @import("../runtime/stable_segments.zig");
const ChunkId = types.ChunkId;
const ConstIdx = types.ConstIdx;

pub const Chunk = struct {
    pub const SourceSpan = struct {
        file: ?@import("../runtime/types.zig").InternId,
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
    /// Body is `constant_ret #idx` (or `constant #idx; ret`).
    /// The value is in `chunk.constants[idx]`. We push it directly.
    constant: ConstIdx,
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
};

/// A mutable builder for constructing chunks.
pub const ChunkBuilder = struct {
    code: std.ArrayListUnmanaged(u8),
    constants: std.ArrayListUnmanaged(Value),
    function_args: std.ArrayListUnmanaged(AttrEntry),
    source_map: std.ArrayListUnmanaged(Chunk.SourceMapEntry),
    /// Byte offset of the start of the most recently written opcode.
    /// `null` when no op has been written or when the tail is no
    /// longer a single rewritable opcode (e.g. after a branch fixup
    /// patches an offset in place). Used by `emit.emitRet` to fuse
    /// the previous value-producing op into a `<op>_ret` super-op.
    last_op_offset: ?usize = null,
    /// Strictness signature computed by `compiler/strictness.zig`
    /// after the body is compiled. Carried through `finish` onto the
    /// resulting Chunk via `SchedulingHints`.
    strictness: ChunkStrictness = .{},

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
            .scheduling = .{
                .body_is_substantial = self.code.items.len >= SPECULATION_MIN_CODE_BYTES,
                .strictness = self.strictness,
                .trivial = classifyTrivialBody(self.code.items, self.constants.items, local_count),
            },
            .function_args = function_args,
            .source_map = source_map,
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
            return .{ .constant = idx };
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
    const Store = stable.StableSegments(*Chunk, .{ .first_segment_size = 64 });

    allocator: std.mem.Allocator,
    chunks: Store,
    well_known: WellKnownChunks,

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

        // get_upvalue 0  — push func
        try builder.writeOp(self.allocator, .get_upvalue);
        try builder.writeU16(self.allocator, 0);
        // get_upvalue 1  — push index
        try builder.writeOp(self.allocator, .get_upvalue);
        try builder.writeU16(self.allocator, 1);
        // tail_call      — call func with index
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

        // get_upvalue 0  — push func
        try builder.writeOp(self.allocator, .get_upvalue);
        try builder.writeU16(self.allocator, 0);
        // get_upvalue 1  — push name
        try builder.writeOp(self.allocator, .get_upvalue);
        try builder.writeU16(self.allocator, 1);
        // call           — partial = func name (result on stack)
        try builder.writeOp(self.allocator, .call);
        // get_upvalue 2  — push value
        try builder.writeOp(self.allocator, .get_upvalue);
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
            const chunk = self.chunks.get(id).*;
            chunk.deinit(self.allocator);
            self.allocator.destroy(chunk);
        }
        self.chunks.deinit(self.allocator);
    }

    pub fn register(self: *ChunkRegistry, chunk: Chunk) !ChunkId {
        const stored = try self.allocator.create(Chunk);
        errdefer {
            stored.deinit(self.allocator);
            self.allocator.destroy(stored);
        }
        stored.* = chunk;
        return try self.chunks.append(self.allocator, stored);
    }

    pub fn get(self: *const ChunkRegistry, id: ChunkId) ?*const Chunk {
        if (id >= self.chunks.count()) return null;
        return self.chunks.get(id).*;
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
            const ch = self.chunks.get(id).*;
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
