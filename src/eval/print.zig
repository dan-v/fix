//! Nix value rendering for Evaluator.writeValue.

const std = @import("std");
const types = @import("../runtime/types.zig");
const Value = @import("../runtime/value.zig").Value;
const ThunkState = @import("../runtime/thunk.zig").ThunkState;

pub fn writeValue(ev: anytype, writer: *std.Io.Writer, value: Value) !void {
    var printer = ValuePrinter(@TypeOf(ev)){
        .ev = ev,
        .writer = writer,
        .seen = .empty,
    };
    defer printer.seen.deinit(ev.allocator);

    try printer.write(value);
}

fn writeQuotedString(writer: *std.Io.Writer, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}

fn ValuePrinter(comptime EvaluatorPtr: type) type {
    return struct {
        const Self = @This();

        ev: EvaluatorPtr,
        writer: *std.Io.Writer,
        seen: std.ArrayListUnmanaged(SeenObject),

        const SeenKind = enum { list, attrs, thunk };

        const SeenObject = struct {
            kind: SeenKind,
            id: types.ObjectId,
        };

        fn write(self: *Self, value: Value) anyerror!void {
            switch (value.kind()) {
                .null => try self.writer.writeAll("null"),
                .bool_false => try self.writer.writeAll("false"),
                .bool_true => try self.writer.writeAll("true"),
                .int => try self.writer.print("{}", .{value.asInt()}),
                .boxed_int => try self.writer.print("{}", .{try self.ev.heap.getBoxedInt(value.asObjectId())}),
                .float => try self.writer.print("{d}", .{value.asFloat()}),
                .string => try writeQuotedString(self.writer, self.ev.intern.get(value.asInternId())),
                .path => try self.writer.writeAll(self.ev.intern.get(value.asInternId())),
                .string_context => {
                    const string = try self.ev.heap.getContextString(value.asObjectId());
                    try writeQuotedString(self.writer, self.ev.intern.get(string.text));
                },
                .list => try self.writeList(value.asObjectId()),
                .attrs => try self.writeAttrs(value.asObjectId()),
                .closure => try self.writer.writeAll("<closure>"),
                .thunk => try self.writeThunk(value.asObjectId()),
                .builtin => try self.writer.writeAll("<builtin>"),
                .builtin_closure => try self.writer.writeAll("<builtin-closure>"),
            }
        }

        fn writeList(self: *Self, id: types.ObjectId) !void {
            if (!try self.enter(.list, id)) {
                try self.writer.writeAll("...");
                return;
            }
            defer self.leave();

            const items = try self.ev.heap.getList(id);
            if (items.len == 0) {
                try self.writer.writeAll("[ ]");
                return;
            }

            try self.writer.writeAll("[ ");
            for (items, 0..) |item, i| {
                if (i > 0) try self.writer.writeByte(' ');
                try self.write(item);
            }
            try self.writer.writeAll(" ]");
        }

        fn writeAttrs(self: *Self, id: types.ObjectId) !void {
            if (try self.derivationDrvPath(id)) |path| {
                try self.writer.writeAll(path);
                return;
            }

            if (!try self.enter(.attrs, id)) {
                try self.writer.writeAll("...");
                return;
            }
            defer self.leave();

            const entries = try self.ev.heap.getAttrs(id);
            if (entries.len == 0) {
                try self.writer.writeAll("{ }");
                return;
            }

            try self.writer.writeAll("{ ");
            for (entries) |entry| {
                try self.writeAttrName(self.ev.intern.get(entry.name));
                try self.writer.writeAll(" = ");
                try self.write(entry.value);
                try self.writer.writeAll("; ");
            }
            try self.writer.writeByte('}');
        }

        fn derivationDrvPath(self: *Self, id: types.ObjectId) !?[]const u8 {
            const type_id = try self.ev.intern.intern("type");
            const type_value = self.ev.heap.getAttrValue(id, type_id) catch |err| switch (err) {
                error.MissingAttribute => return null,
                else => return err,
            };
            const forced_type = try self.ev.forceValue(type_value);
            if (!forced_type.isString()) return null;
            if (!std.mem.eql(u8, self.ev.intern.get(forced_type.asInternId()), "derivation")) return null;

            const drv_path_id = try self.ev.intern.intern("drvPath");
            const drv_path = self.ev.heap.getAttrValue(id, drv_path_id) catch |err| switch (err) {
                error.MissingAttribute => return null,
                else => return err,
            };
            return try self.stringText(try self.ev.forceValue(drv_path));
        }

        fn stringText(self: *Self, value: Value) ![]const u8 {
            return switch (value.kind()) {
                .string, .path => self.ev.intern.get(value.asInternId()),
                .string_context => blk: {
                    const string = try self.ev.heap.getContextString(value.asObjectId());
                    break :blk self.ev.intern.get(string.text);
                },
                else => error.TypeError,
            };
        }

        fn writeThunk(self: *Self, id: types.ObjectId) !void {
            if (!try self.enter(.thunk, id)) {
                try self.writer.writeAll("...");
                return;
            }
            defer self.leave();

            const thunk = try self.ev.heap.getThunk(id);
            const state: ThunkState = @enumFromInt(thunk.state.load(.acquire));
            if (state == .resolved) {
                try self.write(thunk.result.result);
                return;
            }
            // Pass-through (cell-like) thunks hold a value that hasn't been
            // forced yet. Render the wrapped value rather than an opaque
            // `...`, matching how cells used to render their `initial`.
            switch (thunk.target) {
                .pass_through => |v| try self.write(v),
                else => try self.writer.writeAll("..."),
            }
        }

        fn writeAttrName(self: *Self, name: []const u8) !void {
            if (isBareAttrName(name)) {
                try self.writer.writeAll(name);
            } else {
                try writeQuotedString(self.writer, name);
            }
        }

        fn enter(self: *Self, kind: SeenKind, id: types.ObjectId) !bool {
            for (self.seen.items) |seen| {
                if (seen.kind == kind and seen.id == id) return false;
            }
            try self.seen.append(self.ev.allocator, .{ .kind = kind, .id = id });
            return true;
        }

        fn leave(self: *Self) void {
            _ = self.seen.pop();
        }

        fn isBareAttrName(name: []const u8) bool {
            if (name.len == 0) return false;
            if (!isAttrNameStart(name[0])) return false;
            for (name[1..]) |c| {
                if (!isAttrNameContinue(c)) return false;
            }
            return true;
        }

        fn isAttrNameStart(c: u8) bool {
            return std.ascii.isAlphabetic(c) or c == '_';
        }

        fn isAttrNameContinue(c: u8) bool {
            return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '\'';
        }
    };
}
