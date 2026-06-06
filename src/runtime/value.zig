//! Compact tagged value representation.
//!
//! Values are 16 bytes (two 8-byte words). The first word determines the
//! discriminant. This keeps the stack cache-line-friendly and copies cheap.

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
    cell = 11, // payload is ObjectId
    builtin = 12, // payload is builtin id
    builtin_closure = 13, // payload is ObjectId
    string_context = 14, // payload is ObjectId
    // reserved 15..255 for future extensions
};

pub const Value = extern struct {
    discriminant: ValueType align(8),
    payload: u64 align(8),

    comptime {
        std.debug.assert(@sizeOf(Value) == 16);
    }

    // ---- constructors ----

    pub const null_val = Value{ .discriminant = .null, .payload = 0 };

    pub fn boolVal(v: bool) Value {
        return .{
            .discriminant = if (v) .bool_true else .bool_false,
            .payload = 0,
        };
    }

    pub fn int(v: i64) Value {
        return .{
            .discriminant = .int,
            .payload = @bitCast(v),
        };
    }

    pub fn float(v: f64) Value {
        return .{
            .discriminant = .float,
            .payload = @bitCast(v),
        };
    }

    pub fn string(id: InternId) Value {
        return .{
            .discriminant = .string,
            .payload = id,
        };
    }

    pub fn path(id: InternId) Value {
        return .{
            .discriminant = .path,
            .payload = id,
        };
    }

    pub fn list(id: ObjectId) Value {
        return .{
            .discriminant = .list,
            .payload = id,
        };
    }

    pub fn attrs(id: ObjectId) Value {
        return .{
            .discriminant = .attrs,
            .payload = id,
        };
    }

    pub fn closure(id: ObjectId) Value {
        return .{
            .discriminant = .closure,
            .payload = id,
        };
    }

    pub fn thunk(id: ObjectId) Value {
        return .{
            .discriminant = .thunk,
            .payload = id,
        };
    }

    pub fn cell(id: ObjectId) Value {
        return .{
            .discriminant = .cell,
            .payload = id,
        };
    }

    pub fn builtin(id: u16) Value {
        return .{
            .discriminant = .builtin,
            .payload = id,
        };
    }

    pub fn builtinClosure(id: ObjectId) Value {
        return .{
            .discriminant = .builtin_closure,
            .payload = id,
        };
    }

    pub fn contextString(id: ObjectId) Value {
        return .{
            .discriminant = .string_context,
            .payload = id,
        };
    }

    // ---- accessors ----

    pub fn asInt(self: Value) i64 {
        std.debug.assert(self.discriminant == .int);
        return @bitCast(self.payload);
    }

    pub fn asFloat(self: Value) f64 {
        std.debug.assert(self.discriminant == .float);
        return @bitCast(self.payload);
    }

    pub fn asInternId(self: Value) InternId {
        return @intCast(self.payload);
    }

    pub fn asObjectId(self: Value) ObjectId {
        return @intCast(self.payload);
    }

    pub fn asBuiltinId(self: Value) u16 {
        return @intCast(self.payload);
    }

    pub fn isThunk(self: Value) bool {
        return self.discriminant == .thunk;
    }

    pub fn isNull(self: Value) bool {
        return self.discriminant == .null;
    }

    pub fn isBool(self: Value) bool {
        return self.discriminant == .bool_true or self.discriminant == .bool_false;
    }

    pub fn asBool(self: Value) bool {
        return self.discriminant == .bool_true;
    }

    pub fn isInt(self: Value) bool {
        return self.discriminant == .int;
    }

    // ---- identity equality ----
    //
    // These compare by tag + payload bits. For scalar tags this matches
    // semantic equality; for object tags (list, attrs, closure, thunk, …)
    // it is *identity* equality on the heap ObjectId. Structural equality
    // requires heap access; see `vm/equality.zig`.

    pub fn idEq(self: Value, other: Value) bool {
        if (self.discriminant != other.discriminant) return false;
        return switch (self.discriminant) {
            .null, .bool_false, .bool_true => true,
            .int => self.asInt() == other.asInt(),
            .float => self.asFloat() == other.asFloat(),
            .string, .path => self.asInternId() == other.asInternId(),
            .list, .attrs, .closure, .thunk, .cell, .builtin, .builtin_closure, .string_context => self.payload == other.payload,
        };
    }

    pub fn idHash(self: Value) u64 {
        return switch (self.discriminant) {
            .null => 0,
            .bool_false => 1,
            .bool_true => 2,
            .int => @bitCast(self.asInt()),
            .float => @bitCast(self.asFloat()),
            .string, .path => @as(u64, self.asInternId()) *% 31,
            .list, .attrs => self.payload *% 31,
            .closure, .thunk, .cell, .builtin, .builtin_closure, .string_context => self.payload,
        };
    }

    pub fn format(
        self: Value,
        writer: *std.Io.Writer,
    ) !void {
        switch (self.discriminant) {
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
            .cell => try writer.writeAll("<cell>"),
            .builtin => try writer.writeAll("<builtin>"),
            .builtin_closure => try writer.writeAll("<builtin-closure>"),
            .string_context => try writer.writeAll("<string-context>"),
        }
    }
};
