//! Compact tagged value representation.
//!
//! Values are 16 bytes (two 8-byte words). The first word determines the
//! discriminant. This keeps the stack cache-line-friendly and copies cheap.

const std = @import("std");
const types = @import("types.zig");
const InternId = types.InternId;
const ChunkId = types.ChunkId;

pub const ValueType = enum(u8) {
    null = 0,
    bool_false = 1,
    bool_true = 2,
    int = 3,
    float = 4,
    string = 5, // payload is InternId
    path = 6, // payload is InternId
    list = 7, // payload is *ListHeader
    attrs = 8, // payload is *AttrsHeader
    closure = 9, // payload is *Closure (closure.zig)
    builtin = 10, // payload is *Builtin (builtins.zig)
    thunk = 11, // payload is *Thunk (thunk.zig)
    cell = 12, // payload is *Cell (thunk.zig)
    // reserved 13..255 for future extensions
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

    pub fn list(ptr: *anyopaque) Value {
        return .{
            .discriminant = .list,
            .payload = @intFromPtr(ptr),
        };
    }

    pub fn attrs(ptr: *anyopaque) Value {
        return .{
            .discriminant = .attrs,
            .payload = @intFromPtr(ptr),
        };
    }

    pub fn closure(ptr: *anyopaque) Value {
        return .{
            .discriminant = .closure,
            .payload = @intFromPtr(ptr),
        };
    }

    pub fn builtin(ptr: *anyopaque) Value {
        return .{
            .discriminant = .builtin,
            .payload = @intFromPtr(ptr),
        };
    }

    pub fn thunkPtr(ptr: *anyopaque) Value {
        return .{
            .discriminant = .thunk,
            .payload = @intFromPtr(ptr),
        };
    }

    pub fn cell(ptr: *anyopaque) Value {
        return .{
            .discriminant = .cell,
            .payload = @intFromPtr(ptr),
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

    pub fn asPtr(self: Value, comptime T: type) *T {
        return @ptrFromInt(@as(usize, @intCast(self.payload)));
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

    // ---- equality (structural, for memoization) ----

    pub fn memoEq(self: Value, other: Value, intern_table: anytype) bool {
        _ = intern_table;
        if (self.discriminant != other.discriminant) return false;
        return switch (self.discriminant) {
            .null, .bool_false, .bool_true => true,
            .int => self.asInt() == other.asInt(),
            .float => self.asFloat() == other.asFloat(),
            .string, .path => self.asInternId() == other.asInternId(),
            .list => self.asPtr(u8) == other.asPtr(u8),
            .attrs => self.asPtr(u8) == other.asPtr(u8),
            .closure => false,
            .builtin => self.asPtr(u8) == other.asPtr(u8),
            .thunk => {
                const t1: *const @import("thunk.zig").Thunk = @ptrCast(@alignCast(self.asPtr(u8)));
                const t2: *const @import("thunk.zig").Thunk = @ptrCast(@alignCast(other.asPtr(u8)));
                return t1.eq(t2);
            },
            .cell => self.asPtr(u8) == other.asPtr(u8),
        };
    }

    pub fn hash(self: Value) u64 {
        return switch (self.discriminant) {
            .null => 0,
            .bool_false => 1,
            .bool_true => 2,
            .int => @bitCast(self.asInt()),
            .float => @bitCast(self.asFloat()),
            .string, .path => @as(u64, self.asInternId()) *% 31,
            .list => @intFromPtr(self.asPtr(u8)) *% 31,
            .attrs => @intFromPtr(self.asPtr(u8)) *% 31,
            .closure => @intFromPtr(self.asPtr(u8)),
            .builtin => @intFromPtr(self.asPtr(u8)),
            .thunk => @intFromPtr(self.asPtr(u8)),
            .cell => @intFromPtr(self.asPtr(u8)),
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
            .builtin => try writer.writeAll("<builtin>"),
            .thunk => try writer.writeAll("<thunk>"),
            .cell => try writer.writeAll("<cell>"),
        }
    }
};
