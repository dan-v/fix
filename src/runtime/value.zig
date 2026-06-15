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
    // reserved 16..255 for future extensions
};

// ---- bit layout constants ----

/// Sign=1 quiet-NaN prefix in bits [63:51]. Any Value whose bits AND this
/// mask equals this constant is a tagged Value; anything else is a float.
const QNAN_PREFIX: u64 = 0xFFF8_0000_0000_0000;
const QNAN_PREFIX_MASK: u64 = QNAN_PREFIX;

/// High-16-bit mask for primary-tag isolation. Each primary tag's prefix
/// is `QNAN_PREFIX | (tag << 48)`, and the top 16 bits uniquely identify
/// the primary tag — so `(bits & HIGH16_MASK) == prefix(tag)` is a single
/// load + AND + CMP predicate.
const HIGH16_MASK: u64 = 0xFFFF_0000_0000_0000;

const PAYLOAD_MASK: u64 = 0x0000_FFFF_FFFF_FFFF;

// Primary tags (3 bits, shifted into bits 50:48).
const TAG_INT: u64 = 0;
const TAG_STRING: u64 = 1;
const TAG_PATH: u64 = 2;
const TAG_LIST: u64 = 3;
const TAG_ATTRS: u64 = 4;
const TAG_THUNK: u64 = 5;
const TAG_CLOSURE: u64 = 6;
const TAG_MISC: u64 = 7;

// Misc sub-tags (4 bits, shifted into bits 47:44).
const MISC_SUB_SHIFT: u6 = 44;
const MISC_SUB_MASK: u64 = 0xF;
const MISC_SUB_BUILTIN_CLOSURE: u64 = 0;
const MISC_SUB_STRING_CONTEXT: u64 = 1;
const MISC_SUB_BUILTIN: u64 = 2;
const MISC_SUB_NULL: u64 = 3;
const MISC_SUB_BOOL_FALSE: u64 = 4;
const MISC_SUB_BOOL_TRUE: u64 = 5;
const MISC_SUB_BOXED_INT: u64 = 6;
const MISC_SUB_PARTIAL_APP: u64 = 7;

// Mask matching the high 16 bits + the 4-bit misc sub-tag (bits 47:44).
const MISC_FULL_TAG_MASK: u64 = HIGH16_MASK | (MISC_SUB_MASK << MISC_SUB_SHIFT);

/// 48-bit sign-extended integer encode (the int payload occupies the
/// full 48 bits including its own sign bit).
const I48_SIGN_BIT: u64 = 1 << 47;
const I48_SIGN_EXT: u64 = 0xFFFF_0000_0000_0000;
const I48_MIN: i64 = -(@as(i64, 1) << 47);
const I48_MAX: i64 = (@as(i64, 1) << 47) - 1;

/// Positive canonical NaN. Any NaN value passed to `float()` is rewritten
/// to this bit pattern so it can't be misread as a tagged Value (which
/// always has sign=1).
const CANONICAL_NAN: u64 = 0x7FF8_0000_0000_0001;

inline fn tagPrefix(tag: u64) u64 {
    return QNAN_PREFIX | (tag << 48);
}

inline fn miscPrefix(sub: u64) u64 {
    return tagPrefix(TAG_MISC) | (sub << MISC_SUB_SHIFT);
}

pub const Value = extern struct {
    bits: u64 align(8),

    comptime {
        std.debug.assert(@sizeOf(Value) == 8);
        std.debug.assert(@alignOf(Value) == 8);
    }

    // ---- low-level encode helpers ----

    inline fn tagged(tag: u64, payload: u64) Value {
        std.debug.assert(payload & ~PAYLOAD_MASK == 0);
        return .{ .bits = tagPrefix(tag) | payload };
    }

    inline fn miscTagged(sub: u64, payload: u64) Value {
        const sub_payload_mask: u64 = PAYLOAD_MASK >> 4;
        std.debug.assert(payload & ~sub_payload_mask == 0);
        return .{ .bits = miscPrefix(sub) | payload };
    }

    // ---- constructors ----

    pub const null_val: Value = .{ .bits = miscPrefix(MISC_SUB_NULL) };

    pub fn boolVal(v: bool) Value {
        return .{ .bits = miscPrefix(if (v) MISC_SUB_BOOL_TRUE else MISC_SUB_BOOL_FALSE) };
    }

    /// Construct an inline integer. Callers that may have an out-of-range
    /// i64 should go through `runtime/int.zig`'s `make` instead, which
    /// boxes the rare overflow case into a heap-allocated `boxed_int`.
    /// The debug assert here catches accidental direct calls on
    /// unbounded i64s.
    pub fn int(v: i64) Value {
        std.debug.assert(v >= I48_MIN and v <= I48_MAX);
        const masked: u64 = @as(u64, @bitCast(v)) & PAYLOAD_MASK;
        return .{ .bits = tagPrefix(TAG_INT) | masked };
    }

    pub fn float(v: f64) Value {
        const raw: u64 = @bitCast(v);
        // Scrub any NaN to canonical; otherwise a NaN whose bit pattern
        // happened to overlap our tagged-Value space would be misread.
        if ((raw & 0x7FF0_0000_0000_0000) == 0x7FF0_0000_0000_0000 and
            (raw & 0x000F_FFFF_FFFF_FFFF) != 0)
        {
            return .{ .bits = CANONICAL_NAN };
        }
        return .{ .bits = raw };
    }

    pub fn string(id: InternId) Value {
        return tagged(TAG_STRING, id);
    }

    pub fn path(id: InternId) Value {
        return tagged(TAG_PATH, id);
    }

    pub fn list(id: ObjectId) Value {
        return tagged(TAG_LIST, id);
    }

    pub fn attrs(id: ObjectId) Value {
        return tagged(TAG_ATTRS, id);
    }

    pub fn closure(id: ObjectId) Value {
        return tagged(TAG_CLOSURE, id);
    }

    pub fn thunk(id: ObjectId) Value {
        return tagged(TAG_THUNK, id);
    }

    pub fn builtin(id: u16) Value {
        return miscTagged(MISC_SUB_BUILTIN, id);
    }

    pub fn builtinClosure(id: ObjectId) Value {
        return miscTagged(MISC_SUB_BUILTIN_CLOSURE, id);
    }

    pub fn contextString(id: ObjectId) Value {
        return miscTagged(MISC_SUB_STRING_CONTEXT, id);
    }

    pub fn boxedInt(id: ObjectId) Value {
        return miscTagged(MISC_SUB_BOXED_INT, id);
    }

    pub fn partialApp(id: ObjectId) Value {
        return miscTagged(MISC_SUB_PARTIAL_APP, id);
    }

    // ---- discrimination ----

    inline fn isTagged(self: Value) bool {
        return (self.bits & QNAN_PREFIX_MASK) == QNAN_PREFIX;
    }

    pub fn kind(self: Value) ValueType {
        if (!self.isTagged()) return .float;
        const primary: u64 = (self.bits >> 48) & 0x7;
        return switch (primary) {
            TAG_INT => .int,
            TAG_STRING => .string,
            TAG_PATH => .path,
            TAG_LIST => .list,
            TAG_ATTRS => .attrs,
            TAG_THUNK => .thunk,
            TAG_CLOSURE => .closure,
            TAG_MISC => switch ((self.bits >> MISC_SUB_SHIFT) & MISC_SUB_MASK) {
                MISC_SUB_BUILTIN_CLOSURE => .builtin_closure,
                MISC_SUB_STRING_CONTEXT => .string_context,
                MISC_SUB_BUILTIN => .builtin,
                MISC_SUB_NULL => .null,
                MISC_SUB_BOOL_FALSE => .bool_false,
                MISC_SUB_BOOL_TRUE => .bool_true,
                MISC_SUB_BOXED_INT => .boxed_int,
                MISC_SUB_PARTIAL_APP => .partial_app,
                else => unreachable,
            },
            else => unreachable,
        };
    }

    pub fn rawPayload(self: Value) u64 {
        return self.bits & PAYLOAD_MASK;
    }

    // ---- predicates ----

    pub fn isFloat(self: Value) bool {
        return !self.isTagged();
    }

    pub fn isInt(self: Value) bool {
        return (self.bits & HIGH16_MASK) == tagPrefix(TAG_INT);
    }

    pub fn isString(self: Value) bool {
        return (self.bits & HIGH16_MASK) == tagPrefix(TAG_STRING);
    }

    pub fn isPath(self: Value) bool {
        return (self.bits & HIGH16_MASK) == tagPrefix(TAG_PATH);
    }

    pub fn isList(self: Value) bool {
        return (self.bits & HIGH16_MASK) == tagPrefix(TAG_LIST);
    }

    pub fn isAttrs(self: Value) bool {
        return (self.bits & HIGH16_MASK) == tagPrefix(TAG_ATTRS);
    }

    pub fn isThunk(self: Value) bool {
        return (self.bits & HIGH16_MASK) == tagPrefix(TAG_THUNK);
    }

    pub fn isClosure(self: Value) bool {
        return (self.bits & HIGH16_MASK) == tagPrefix(TAG_CLOSURE);
    }

    inline fn isMiscSub(self: Value, sub: u64) bool {
        return (self.bits & MISC_FULL_TAG_MASK) == miscPrefix(sub);
    }

    pub fn isBuiltinClosure(self: Value) bool {
        return self.isMiscSub(MISC_SUB_BUILTIN_CLOSURE);
    }

    pub fn isContextString(self: Value) bool {
        return self.isMiscSub(MISC_SUB_STRING_CONTEXT);
    }

    pub fn isBoxedInt(self: Value) bool {
        return self.isMiscSub(MISC_SUB_BOXED_INT);
    }

    pub fn isBuiltin(self: Value) bool {
        return self.isMiscSub(MISC_SUB_BUILTIN);
    }

    pub fn isPartialApp(self: Value) bool {
        return self.isMiscSub(MISC_SUB_PARTIAL_APP);
    }

    pub fn isNull(self: Value) bool {
        return self.isMiscSub(MISC_SUB_NULL);
    }

    pub fn isBool(self: Value) bool {
        // bool_true and bool_false share the misc tag and live in two
        // adjacent sub-tag slots — check both.
        const masked = self.bits & MISC_FULL_TAG_MASK;
        return masked == miscPrefix(MISC_SUB_BOOL_FALSE) or
            masked == miscPrefix(MISC_SUB_BOOL_TRUE);
    }

    pub fn asBool(self: Value) bool {
        return self.isMiscSub(MISC_SUB_BOOL_TRUE);
    }

    // ---- accessors ----

    pub fn asInt(self: Value) i64 {
        std.debug.assert(self.isInt());
        const masked: u64 = self.bits & PAYLOAD_MASK;
        // Sign-extend bit 47 into the high 16 bits.
        if ((masked & I48_SIGN_BIT) != 0) {
            return @bitCast(masked | I48_SIGN_EXT);
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
        }
    }
};

test "value: tagged int round-trip" {
    const cases = [_]i64{ 0, 1, -1, 42, -42, I48_MIN, I48_MAX, 1 << 30, -(1 << 30) };
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
    try std.testing.expectEqual(CANONICAL_NAN, x.bits);
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

test "value: idEq compares scalars and objects by bits, floats by IEEE" {
    try std.testing.expect(Value.int(5).idEq(Value.int(5)));
    try std.testing.expect(!Value.int(5).idEq(Value.int(6)));
    try std.testing.expect(Value.list(@as(ObjectId, 1)).idEq(Value.list(@as(ObjectId, 1))));
    try std.testing.expect(!Value.list(@as(ObjectId, 1)).idEq(Value.list(@as(ObjectId, 2))));
    try std.testing.expect(Value.null_val.idEq(Value.null_val));
    const nan = Value.float(std.math.nan(f64));
    try std.testing.expect(!nan.idEq(nan));
}
