//! Compact tagged value representation.
//!
//! Two representations live behind the same public surface, selected at
//! build time:
//!
//!   - `Value16` (default): an extern struct of `{u8 tag, u64 payload}`
//!     padded to 16 bytes. The original layout — kept as the default
//!     while `Value8` is validated against real workloads.
//!   - `Value8` (`-Dvalue8=true`): an 8-byte NaN-boxed `u64`. See
//!     `value8.zig` for the bit layout and the rationale for migrating.
//!
//! Both Value implementations expose the same method API: `kind()`,
//! `rawPayload()`, all `isX()` / `asX()` accessors, all constructors,
//! `idEq`, `idHash`, and `format`. Callers go through methods rather
//! than the underlying fields so the layout swap is transparent.

const std = @import("std");
const build_options = @import("build_options");
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
    /// Heap-boxed i64. The inline `int` variant covers most of the Nix
    /// integer range (always under Value16, only i48 under Value8); this
    /// variant carries the rare i64 values that don't fit Value8's 48-bit
    /// payload. Payload is an ObjectId pointing at an `Object.boxed_int`
    /// heap slot. Created via `runtime/int.zig`'s `make`; unboxed via
    /// `runtime/int.zig`'s `get`.
    boxed_int = 14,
    // reserved 15..255 for future extensions
};

pub const Value = if (build_options.value8) @import("value8.zig").Value else Value16;

test {
    _ = if (build_options.value8) @import("value8.zig") else struct {};
}

pub const Value16 = extern struct {
    discriminant: ValueType align(8),
    payload: u64 align(8),

    comptime {
        std.debug.assert(@sizeOf(Value16) == 16);
    }

    // ---- constructors ----

    pub const null_val: @This() = .{ .discriminant = .null, .payload = 0 };

    pub fn boolVal(v: bool) @This() {
        return .{
            .discriminant = if (v) .bool_true else .bool_false,
            .payload = 0,
        };
    }

    pub fn int(v: i64) @This() {
        return .{
            .discriminant = .int,
            .payload = @bitCast(v),
        };
    }

    pub fn float(v: f64) @This() {
        return .{
            .discriminant = .float,
            .payload = @bitCast(v),
        };
    }

    pub fn string(id: InternId) @This() {
        return .{
            .discriminant = .string,
            .payload = id,
        };
    }

    pub fn path(id: InternId) @This() {
        return .{
            .discriminant = .path,
            .payload = id,
        };
    }

    pub fn list(id: ObjectId) @This() {
        return .{
            .discriminant = .list,
            .payload = id,
        };
    }

    pub fn attrs(id: ObjectId) @This() {
        return .{
            .discriminant = .attrs,
            .payload = id,
        };
    }

    pub fn closure(id: ObjectId) @This() {
        return .{
            .discriminant = .closure,
            .payload = id,
        };
    }

    pub fn thunk(id: ObjectId) @This() {
        return .{
            .discriminant = .thunk,
            .payload = id,
        };
    }

    pub fn builtin(id: u16) @This() {
        return .{
            .discriminant = .builtin,
            .payload = id,
        };
    }

    pub fn builtinClosure(id: ObjectId) @This() {
        return .{
            .discriminant = .builtin_closure,
            .payload = id,
        };
    }

    pub fn contextString(id: ObjectId) @This() {
        return .{
            .discriminant = .string_context,
            .payload = id,
        };
    }

    pub fn boxedInt(id: ObjectId) @This() {
        return .{
            .discriminant = .boxed_int,
            .payload = id,
        };
    }

    // ---- accessors ----

    pub fn asInt(self: @This()) i64 {
        std.debug.assert(self.discriminant == .int);
        return @bitCast(self.payload);
    }

    pub fn asFloat(self: @This()) f64 {
        std.debug.assert(self.discriminant == .float);
        return @bitCast(self.payload);
    }

    pub fn asInternId(self: @This()) InternId {
        return @intCast(self.payload);
    }

    pub fn asObjectId(self: @This()) ObjectId {
        return @intCast(self.payload);
    }

    pub fn asBuiltinId(self: @This()) u16 {
        return @intCast(self.payload);
    }

    /// Return the value's discriminant. Prefer this over reading
    /// `.discriminant` directly so callers stay layout-agnostic — a
    /// future NaN-boxed encoding (`-Dvalue8`) keeps the method but
    /// removes the field.
    pub fn kind(self: @This()) ValueType {
        return self.discriminant;
    }

    /// Raw 64-bit payload bits. Used by identity equality/hash where
    /// the payload semantics are tag-implied and a bitwise compare is
    /// sufficient. Layout-agnostic accessor for the same reason as
    /// `kind`.
    pub fn rawPayload(self: @This()) u64 {
        return self.payload;
    }

    pub fn isThunk(self: @This()) bool {
        return self.discriminant == .thunk;
    }

    pub fn isNull(self: @This()) bool {
        return self.discriminant == .null;
    }

    pub fn isBool(self: @This()) bool {
        return self.discriminant == .bool_true or self.discriminant == .bool_false;
    }

    pub fn asBool(self: @This()) bool {
        return self.discriminant == .bool_true;
    }

    pub fn isInt(self: @This()) bool {
        return self.discriminant == .int;
    }

    pub fn isFloat(self: @This()) bool {
        return self.discriminant == .float;
    }

    pub fn isString(self: @This()) bool {
        return self.discriminant == .string;
    }

    pub fn isPath(self: @This()) bool {
        return self.discriminant == .path;
    }

    pub fn isList(self: @This()) bool {
        return self.discriminant == .list;
    }

    pub fn isAttrs(self: @This()) bool {
        return self.discriminant == .attrs;
    }

    pub fn isClosure(self: @This()) bool {
        return self.discriminant == .closure;
    }

    pub fn isBuiltin(self: @This()) bool {
        return self.discriminant == .builtin;
    }

    pub fn isBuiltinClosure(self: @This()) bool {
        return self.discriminant == .builtin_closure;
    }

    pub fn isContextString(self: @This()) bool {
        return self.discriminant == .string_context;
    }

    pub fn isBoxedInt(self: @This()) bool {
        return self.discriminant == .boxed_int;
    }

    // ---- identity equality ----
    //
    // These compare by tag + payload bits. For scalar tags this matches
    // semantic equality; for object tags (list, attrs, closure, thunk, …)
    // it is *identity* equality on the heap ObjectId. Structural equality
    // requires heap access; see `vm/equality.zig`.

    /// Identity equality. `boxed_int` is compared by ObjectId only — two
    /// boxed slots holding the same numeric value but distinct ids are
    /// NOT idEq. Semantic numeric equality across inline/boxed
    /// encodings is handled by `runtime/int.zig` + `vm/equality.zig`.
    pub fn idEq(self: @This(), other: @This()) bool {
        if (self.kind() != other.kind()) return false;
        return switch (self.kind()) {
            .null, .bool_false, .bool_true => true,
            .int => self.asInt() == other.asInt(),
            .float => self.asFloat() == other.asFloat(),
            .string, .path => self.asInternId() == other.asInternId(),
            .list, .attrs, .closure, .thunk, .builtin, .builtin_closure, .string_context, .boxed_int => self.rawPayload() == other.rawPayload(),
        };
    }

    pub fn idHash(self: @This()) u64 {
        return switch (self.kind()) {
            .null => 0,
            .bool_false => 1,
            .bool_true => 2,
            .int => @bitCast(self.asInt()),
            .float => @bitCast(self.asFloat()),
            .string, .path => @as(u64, self.asInternId()) *% 31,
            .list, .attrs => self.rawPayload() *% 31,
            .closure, .thunk, .builtin, .builtin_closure, .string_context, .boxed_int => self.rawPayload(),
        };
    }

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) !void {
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
        }
    }
};
