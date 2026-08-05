//! NaN-boxed 8-byte Value.
//!
//! Layout (64 bits):
//!
//!   If bits[63:51] != 0x1FFF — i.e. sign != 1, OR exponent != 0x7FF,
//!   OR quiet-NaN bit != 1 — the Value is a regular IEEE 754 double.
//!
//!   Otherwise the Value is a tagged scalar/object reference:
//!     bits[50:48]  = 3-bit primary tag (8 variants)
//!     bits[47:0]   = 48-bit payload
//!
//!   For the `misc` primary tag (7), the variant is further refined by a
//!   4-bit sub-tag in bits[47:44] and a 44-bit sub-payload in bits[43:0].
//!
//! Float canonicalisation: arithmetic-produced NaNs may land anywhere in
//! the qNaN bit space, including patterns that look like a tagged value.
//! `float(v)` scrubs any input NaN to a fixed positive canonical NaN
//! (sign=0) that never collides with our tagged prefix (sign=1).
//!
//! Integers up to 2^47 fit inline in the int tag's 48-bit payload. The
//! rare i64 overflow case is held in a heap-boxed `Object.boxed_int`
//! slot and surfaced through the `boxed_int` ValueType — see
//! `runtime/int.zig` for the make/get helpers callers use to stay
//! agnostic of which encoding any given integer Value is in.

const std = @import("std");
const types = @import("types.zig");
const InternId = types.InternId;
const ObjectId = types.ObjectId;

pub const ValueType = enum(u8) {
    null = 0,
    bool_false = 1,
    bool_true = 2,
    int = 3,
    float = 4,
    string = 5, // payload is InternId
    path = 6, // payload is InternId
    list = 7, // payload is ObjectId
    attrs = 8, // payload is ObjectId
    closure = 9, // payload is ObjectId
    thunk = 10, // payload is ObjectId
    builtin = 11, // payload is builtin id
    builtin_closure = 12, // payload is ObjectId
    string_context = 13, // payload is ObjectId
    /// Heap-boxed i64 for values that don't fit the 48-bit inline
    /// payload. Created and unboxed through `runtime/int.zig`'s
    /// `make`/`get` helpers; the payload is an ObjectId into an
    /// `Object.boxed_int` slot.
    boxed_int = 14,
    /// Partial application of an uncurried (arity>1) closure: some but
    /// not all of its parameters have been supplied. Payload is an
    /// ObjectId into an `Object.partial_app` slot. Behaves as a function
    /// (`isFunction`, `typeOf "lambda"`) and is callable — applying the
    /// remaining args runs the underlying body. See `vm/closures.zig`.
    partial_app = 15,
    /// A GC-able string whose bytes live in the heap's byte store rather
    /// than the immortal intern table. Payload is an ObjectId into an
    /// `Object.heap_string` slot. Language-visible behavior is identical
    /// to `.string`; producers route long derived text here (threshold in
    /// `vm/strings.makeString`) so churn — unique intermediates a fold
    /// never looks at again — can be collected. Equality/ordering must go
    /// through byte comparison (`vm/strings.stringTextEqual`); attr NAMES
    /// are always interned, never this.
    heap_string = 16,
    // reserved 17..255 for future extensions
};

// ---- bit layout constants ----

/// Sign=1 quiet-NaN prefix in bits [63:51]. Any Value whose bits AND this
/// mask equals this constant is a tagged Value; anything else is a float.
const qnan_prefix: u64 = 0xFFF8_0000_0000_0000;
const qnan_prefix_mask: u64 = qnan_prefix;

/// High-16-bit mask for primary-tag isolation. Each primary tag's prefix
/// is `qnan_prefix | (tag << 48)`, and the top 16 bits uniquely identify
/// the primary tag — so `(bits & high_16_mask) == prefix(tag)` is a single
/// load + AND + CMP predicate.
const high_16_mask: u64 = 0xFFFF_0000_0000_0000;

const payload_mask: u64 = 0x0000_FFFF_FFFF_FFFF;
/// Within the closure primary tag, bit 47 distinguishes a capture-free
/// function (payload = ChunkId) from a heap closure (payload = ObjectId).
const function_marker: u64 = 1 << 47;

// Primary tags (3 bits, shifted into bits 50:48).
const tag_int: u64 = 0;
const tag_string: u64 = 1;
const tag_path: u64 = 2;
const tag_list: u64 = 3;
const tag_attrs: u64 = 4;
const tag_thunk: u64 = 5;
const tag_closure: u64 = 6;
const tag_misc: u64 = 7;

// Misc sub-tags (4 bits, shifted into bits 47:44).
const misc_subtag_shift: u6 = 44;
const misc_subtag_mask: u64 = 0xF;
const misc_builtin_closure: u64 = 0;
const misc_string_context: u64 = 1;
const misc_builtin: u64 = 2;
const misc_null: u64 = 3;
const misc_bool_false: u64 = 4;
const misc_bool_true: u64 = 5;
const misc_boxed_int: u64 = 6;
const misc_partial_app: u64 = 7;
const misc_heap_string: u64 = 8;

// Mask matching the high 16 bits + the 4-bit misc sub-tag (bits 47:44).
const misc_full_tag_mask: u64 = high_16_mask | (misc_subtag_mask << misc_subtag_shift);

/// 48-bit sign-extended integer encode (the int payload occupies the
/// full 48 bits including its own sign bit).
const i48_sign_bit: u64 = 1 << 47;
const i48_sign_extension: u64 = 0xFFFF_0000_0000_0000;
const i48_min: i64 = -(@as(i64, 1) << 47);
const i48_max: i64 = (@as(i64, 1) << 47) - 1;

/// Positive canonical NaN. Any NaN value passed to `float()` is rewritten
/// to this bit pattern so it can't be misread as a tagged Value (which
/// always has sign=1).
const canonical_nan: u64 = 0x7FF8_0000_0000_0001;

inline fn tagPrefix(tag: u64) u64 {
    return qnan_prefix | (tag << 48);
}

inline fn miscPrefix(sub: u64) u64 {
    return tagPrefix(tag_misc) | (sub << misc_subtag_shift);
}

pub const Value = extern struct {
    bits: u64 align(8),

    comptime {
        std.debug.assert(@sizeOf(Value) == 8);
        std.debug.assert(@alignOf(Value) == 8);
    }

    // ---- low-level encode helpers ----

    inline fn tagged(tag: u64, payload: u64) Value {
        std.debug.assert(payload & ~payload_mask == 0);
        return .{ .bits = tagPrefix(tag) | payload };
    }

    inline fn miscTagged(sub: u64, payload: u64) Value {
        const sub_payload_mask: u64 = payload_mask >> 4;
        std.debug.assert(payload & ~sub_payload_mask == 0);
        return .{ .bits = miscPrefix(sub) | payload };
    }

    // ---- constructors ----

    pub const null_val: Value = .{ .bits = miscPrefix(misc_null) };

    pub fn boolVal(v: bool) Value {
        return .{ .bits = miscPrefix(if (v) misc_bool_true else misc_bool_false) };
    }

    /// Construct an inline integer. Callers that may have an out-of-range
    /// i64 should go through `runtime/int.zig`'s `make` instead, which
    /// boxes the rare overflow case into a heap-allocated `boxed_int`.
    /// The debug assert here catches accidental direct calls on
    /// unbounded i64s.
    pub fn int(v: i64) Value {
        std.debug.assert(v >= i48_min and v <= i48_max);
        const masked: u64 = @as(u64, @bitCast(v)) & payload_mask;
        return .{ .bits = tagPrefix(tag_int) | masked };
    }

    pub fn float(v: f64) Value {
        const raw: u64 = @bitCast(v);
        // Scrub any NaN to canonical; otherwise a NaN whose bit pattern
        // happened to overlap our tagged-Value space would be misread.
        if ((raw & 0x7FF0_0000_0000_0000) == 0x7FF0_0000_0000_0000 and
            (raw & 0x000F_FFFF_FFFF_FFFF) != 0)
        {
            return .{ .bits = canonical_nan };
        }
        return .{ .bits = raw };
    }

    pub fn string(id: InternId) Value {
        return tagged(tag_string, id);
    }

    pub fn path(id: InternId) Value {
        return tagged(tag_path, id);
    }

    pub fn list(id: ObjectId) Value {
        return tagged(tag_list, id);
    }

    pub fn attrs(id: ObjectId) Value {
        return tagged(tag_attrs, id);
    }

    pub fn closure(id: ObjectId) Value {
        return tagged(tag_closure, id);
    }

    pub fn function(chunk_id: types.ChunkId) Value {
        return tagged(tag_closure, function_marker | chunk_id);
    }

    pub fn thunk(id: ObjectId) Value {
        return tagged(tag_thunk, id);
    }

    pub fn builtin(id: u16) Value {
        return miscTagged(misc_builtin, id);
    }

    pub fn builtinClosure(id: ObjectId) Value {
        return miscTagged(misc_builtin_closure, id);
    }

    pub fn contextString(id: ObjectId) Value {
        return miscTagged(misc_string_context, id);
    }

    pub fn boxedInt(id: ObjectId) Value {
        return miscTagged(misc_boxed_int, id);
    }

    pub fn partialApp(id: ObjectId) Value {
        return miscTagged(misc_partial_app, id);
    }

    pub fn heapString(id: ObjectId) Value {
        return miscTagged(misc_heap_string, id);
    }

    // ---- discrimination ----

    inline fn isTagged(self: Value) bool {
        return (self.bits & qnan_prefix_mask) == qnan_prefix;
    }

    pub fn kind(self: Value) ValueType {
        if (!self.isTagged()) return .float;
        const primary: u64 = (self.bits >> 48) & 0x7;
        return switch (primary) {
            tag_int => .int,
            tag_string => .string,
            tag_path => .path,
            tag_list => .list,
            tag_attrs => .attrs,
            tag_thunk => .thunk,
            tag_closure => .closure,
            tag_misc => switch ((self.bits >> misc_subtag_shift) & misc_subtag_mask) {
                misc_builtin_closure => .builtin_closure,
                misc_string_context => .string_context,
                misc_builtin => .builtin,
                misc_null => .null,
                misc_bool_false => .bool_false,
                misc_bool_true => .bool_true,
                misc_boxed_int => .boxed_int,
                misc_partial_app => .partial_app,
                misc_heap_string => .heap_string,
                else => unreachable,
            },
            else => unreachable,
        };
    }

    pub fn rawPayload(self: Value) u64 {
        return self.bits & payload_mask;
    }

    // ---- predicates ----

    pub fn isFloat(self: Value) bool {
        return !self.isTagged();
    }

    pub fn isInt(self: Value) bool {
        return (self.bits & high_16_mask) == tagPrefix(tag_int);
    }

    pub fn isString(self: Value) bool {
        return (self.bits & high_16_mask) == tagPrefix(tag_string);
    }

    pub fn isPath(self: Value) bool {
        return (self.bits & high_16_mask) == tagPrefix(tag_path);
    }

    pub fn isList(self: Value) bool {
        return (self.bits & high_16_mask) == tagPrefix(tag_list);
    }

    pub fn isAttrs(self: Value) bool {
        return (self.bits & high_16_mask) == tagPrefix(tag_attrs);
    }

    pub fn isThunk(self: Value) bool {
        return (self.bits & high_16_mask) == tagPrefix(tag_thunk);
    }

    pub fn isClosure(self: Value) bool {
        return (self.bits & high_16_mask) == tagPrefix(tag_closure) and (self.rawPayload() & function_marker) == 0;
    }

    pub fn isFunction(self: Value) bool {
        return (self.bits & high_16_mask) == tagPrefix(tag_closure) and (self.rawPayload() & function_marker) != 0;
    }

    pub fn isNixClosure(self: Value) bool {
        return self.isClosure() or self.isFunction();
    }

    inline fn isMiscSub(self: Value, sub: u64) bool {
        return (self.bits & misc_full_tag_mask) == miscPrefix(sub);
    }

    pub fn isBuiltinClosure(self: Value) bool {
        return self.isMiscSub(misc_builtin_closure);
    }

    pub fn isContextString(self: Value) bool {
        return self.isMiscSub(misc_string_context);
    }

    pub fn isHeapString(self: Value) bool {
        return self.isMiscSub(misc_heap_string);
    }

    pub fn isBoxedInt(self: Value) bool {
        return self.isMiscSub(misc_boxed_int);
    }

    pub fn isBuiltin(self: Value) bool {
        return self.isMiscSub(misc_builtin);
    }

    pub fn isPartialApp(self: Value) bool {
        return self.isMiscSub(misc_partial_app);
    }

    pub fn isNull(self: Value) bool {
        return self.isMiscSub(misc_null);
    }

    pub fn isBool(self: Value) bool {
        // bool_true and bool_false share the misc tag and live in two
        // adjacent sub-tag slots — check both.
        const masked = self.bits & misc_full_tag_mask;
        return masked == miscPrefix(misc_bool_false) or
            masked == miscPrefix(misc_bool_true);
    }

    pub fn asBool(self: Value) bool {
        return self.isMiscSub(misc_bool_true);
    }

    // ---- accessors ----

    pub fn asInt(self: Value) i64 {
        std.debug.assert(self.isInt());
        const masked: u64 = self.bits & payload_mask;
        // Sign-extend bit 47 into the high 16 bits.
        if ((masked & i48_sign_bit) != 0) {
            return @bitCast(masked | i48_sign_extension);
        }
        return @bitCast(masked);
    }

    pub fn asFloat(self: Value) f64 {
        std.debug.assert(self.isFloat());
        return @bitCast(self.bits);
    }

    pub fn asInternId(self: Value) InternId {
        return @intCast(self.bits & 0xFFFF_FFFF);
    }

    pub fn asObjectId(self: Value) ObjectId {
        std.debug.assert(!self.isFunction());
        return @intCast(self.bits & 0xFFFF_FFFF);
    }

    pub fn asFunctionChunkId(self: Value) types.ChunkId {
        std.debug.assert(self.isFunction());
        return @intCast(self.bits & 0xFFFF_FFFF);
    }

    pub fn asBuiltinId(self: Value) u16 {
        return @intCast(self.bits & 0xFFFF);
    }

    // ---- identity equality / hash ----
    //
    // Scalars and object references compare by raw bits, since the tag
    // is part of the bit pattern. Floats use IEEE equality (so NaN !=
    // NaN even when both are the canonical NaN pattern) to match the
    // semantics callers of `idEq` rely on.

    pub fn idEq(self: Value, other: Value) bool {
        if (self.isFloat() and other.isFloat()) {
            return self.asFloat() == other.asFloat();
        }
        return self.bits == other.bits;
    }

    pub fn idHash(self: Value) u64 {
        return self.bits;
    }

    pub fn format(self: Value, writer: *std.Io.Writer) !void {
        switch (self.kind()) {
            .null => try writer.writeAll("null"),
            .bool_false => try writer.writeAll("false"),
            .bool_true => try writer.writeAll("true"),
            .int => try writer.print("{}", .{self.asInt()}),
            .float => try writer.print("{d}", .{self.asFloat()}),
            .string => try writer.print("\"{d}\"", .{self.asInternId()}),
            .path => try writer.print("<path:{d}>", .{self.asInternId()}),
            .list => try writer.writeAll("[...]"),
            .attrs => try writer.writeAll("{...}"),
            .closure => try writer.writeAll("<closure>"),
            .thunk => try writer.writeAll("<thunk>"),
            .builtin => try writer.writeAll("<builtin>"),
            .builtin_closure => try writer.writeAll("<builtin-closure>"),
            .string_context => try writer.writeAll("<string-context>"),
            .boxed_int => try writer.print("<boxed-int:{d}>", .{self.asObjectId()}),
            .partial_app => try writer.writeAll("<partial-app>"),
            .heap_string => try writer.print("<heap-string:{d}>", .{self.asObjectId()}),
        }
    }
};

test "value: tagged int round-trip" {
    const cases = [_]i64{ 0, 1, -1, 42, -42, i48_min, i48_max, 1 << 30, -(1 << 30) };
    for (cases) |v| {
        const x = Value.int(v);
        try std.testing.expect(x.isInt());
        try std.testing.expect(x.kind() == .int);
        try std.testing.expectEqual(v, x.asInt());
    }
}

test "value: float round-trip and NaN scrub" {
    const finite = [_]f64{ 0.0, -0.0, 1.5, -3.14, std.math.inf(f64), -std.math.inf(f64) };
    for (finite) |v| {
        const x = Value.float(v);
        try std.testing.expect(x.isFloat());
        try std.testing.expect(x.kind() == .float);
        try std.testing.expectEqual(@as(u64, @bitCast(v)), @as(u64, @bitCast(x.asFloat())));
    }
    // Any NaN, regardless of source bit pattern, scrubs to canonical NaN
    // so the tagged-space check stays unambiguous.
    const nan_input: f64 = std.math.nan(f64);
    const x = Value.float(nan_input);
    try std.testing.expect(x.isFloat());
    try std.testing.expect(std.math.isNan(x.asFloat()));
    try std.testing.expectEqual(canonical_nan, x.bits);
}

test "value: object id and intern id round-trip" {
    const x = Value.list(@as(ObjectId, 12345));
    try std.testing.expect(x.isList());
    try std.testing.expect(x.kind() == .list);
    try std.testing.expectEqual(@as(ObjectId, 12345), x.asObjectId());

    const s = Value.string(@as(InternId, 67890));
    try std.testing.expect(s.isString());
    try std.testing.expect(s.kind() == .string);
    try std.testing.expectEqual(@as(InternId, 67890), s.asInternId());
}

test "value: misc-tag variants" {
    try std.testing.expect(Value.null_val.isNull());
    try std.testing.expect(Value.null_val.kind() == .null);

    try std.testing.expect(Value.boolVal(true).isBool());
    try std.testing.expect(Value.boolVal(true).asBool());
    try std.testing.expect(Value.boolVal(true).kind() == .bool_true);

    try std.testing.expect(Value.boolVal(false).isBool());
    try std.testing.expect(!Value.boolVal(false).asBool());
    try std.testing.expect(Value.boolVal(false).kind() == .bool_false);

    const bi = Value.builtin(@as(u16, 257));
    try std.testing.expect(bi.isBuiltin());
    try std.testing.expectEqual(@as(u16, 257), bi.asBuiltinId());

    const bc = Value.builtinClosure(@as(ObjectId, 99));
    try std.testing.expect(bc.isBuiltinClosure());
    try std.testing.expectEqual(@as(ObjectId, 99), bc.asObjectId());

    const cs = Value.contextString(@as(ObjectId, 7));
    try std.testing.expect(cs.isContextString());
    try std.testing.expectEqual(@as(ObjectId, 7), cs.asObjectId());
}

test "value: capture-free function uses the closure tag without an object id" {
    const f = Value.function(1234);
    try std.testing.expect(f.isFunction());
    try std.testing.expect(f.isNixClosure());
    try std.testing.expect(!f.isClosure());
    try std.testing.expectEqual(ValueType.closure, f.kind());
    try std.testing.expectEqual(@as(types.ChunkId, 1234), f.asFunctionChunkId());
}

test "value: idEq compares scalars and objects by bits, floats by IEEE" {
    try std.testing.expect(Value.int(5).idEq(Value.int(5)));
    try std.testing.expect(!Value.int(5).idEq(Value.int(6)));
    try std.testing.expect(Value.list(@as(ObjectId, 1)).idEq(Value.list(@as(ObjectId, 1))));
    try std.testing.expect(!Value.list(@as(ObjectId, 1)).idEq(Value.list(@as(ObjectId, 2))));
    try std.testing.expect(Value.null_val.idEq(Value.null_val));
    const nan = Value.float(std.math.nan(f64));
    try std.testing.expect(!nan.idEq(nan));
}
