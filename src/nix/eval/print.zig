//! Nix value rendering for Evaluator.writeValue.

const std = @import("std");
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const FutureState = @import("runtime").thunk.FutureState;

// Value-coloring palette (SGR), applied when `ev.value_color` is set. Chosen to
// match the CLI's own styles (green paths, yellow hashes/numbers, magenta
// keywords, cyan labels) — see `src/cli/cli.zig`.
const col_string = "\x1b[32m"; // strings, paths — green
const col_number = "\x1b[33m"; // ints, floats — yellow
const col_keyword = "\x1b[35m"; // true/false/null — magenta
const col_name = "\x1b[36m"; // attribute names — cyan
const col_reset = "\x1b[0m";

pub fn writeValue(ev: anytype, writer: *std.Io.Writer, value: Value) !void {
    var printer = ValuePrinter(@TypeOf(ev)){
        .ev = ev,
        .writer = writer,
        .seen = .empty,
        .use_color = ev.value_color,
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
        use_color: bool,
        seen: std.ArrayListUnmanaged(SeenObject),
        /// Recursion depth, so top-level (`depth == 0`) list/attrs walks can
        /// report `[i/N]` item progress on the render node without every nested
        /// container fighting over the same counter.
        depth: u32 = 0,

        const SeenKind = enum { list, attrs, thunk };

        const SeenObject = struct {
            kind: SeenKind,
            id: types.ObjectId,
        };

        /// Emit an SGR code (or nothing when color is off).
        fn on(self: *Self, code: []const u8) !void {
            if (self.use_color) try self.writer.writeAll(code);
        }
        fn off(self: *Self) !void {
            if (self.use_color) try self.writer.writeAll(col_reset);
        }
        /// Write `text` wrapped in `code`…reset.
        fn leaf(self: *Self, code: []const u8, text: []const u8) !void {
            try self.on(code);
            try self.writer.writeAll(text);
            try self.off();
        }
        fn quotedString(self: *Self, s: []const u8) !void {
            try self.on(col_string);
            try writeQuotedString(self.writer, s);
            try self.off();
        }

        fn write(self: *Self, value: Value) anyerror!void {
            switch (value.kind()) {
                .null => try self.leaf(col_keyword, "null"),
                .bool_false => try self.leaf(col_keyword, "false"),
                .bool_true => try self.leaf(col_keyword, "true"),
                .int => {
                    try self.on(col_number);
                    try self.writer.print("{}", .{value.asInt()});
                    try self.off();
                },
                .boxed_int => {
                    try self.on(col_number);
                    try self.writer.print("{}", .{try self.ev.heap.getBoxedInt(value.asObjectId())});
                    try self.off();
                },
                .float => {
                    try self.on(col_number);
                    try self.writer.print("{d}", .{value.asFloat()});
                    try self.off();
                },
                .string => try self.quotedString(self.ev.intern.get(value.asInternId())),
                .path => try self.leaf(col_string, self.ev.intern.get(value.asInternId())),
                .string_context => {
                    const string = try self.ev.heap.getContextString(value.asObjectId());
                    try self.quotedString(self.ev.intern.get(string.text));
                },
                .list => try self.writeList(value.asObjectId()),
                .attrs => try self.writeAttrs(value.asObjectId()),
                .closure => try self.writer.writeAll("<closure>"),
                .thunk => try self.writeThunk(value.asObjectId()),
                .builtin => try self.writer.writeAll("<builtin>"),
                .builtin_closure => try self.writer.writeAll("<builtin-closure>"),
                .partial_app => try self.writer.writeAll("<partial-app>"),
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

            const count_on = self.depth == 0 and self.ev.progressCountBegin(items.len);
            self.depth += 1;
            defer self.depth -= 1;

            try self.writer.writeAll("[ ");
            for (items, 0..) |item, i| {
                if (i > 0) try self.writer.writeByte(' ');
                try self.write(item);
                if (count_on) self.ev.progressStep(i + 1, items.len);
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

            const count_on = self.depth == 0 and self.ev.progressCountBegin(entries.len);
            self.depth += 1;
            defer self.depth -= 1;

            try self.writer.writeAll("{ ");
            for (entries, 0..) |entry, i| {
                try self.writeAttrName(self.ev.intern.get(entry.name));
                try self.writer.writeAll(" = ");
                try self.write(entry.value);
                try self.writer.writeAll("; ");
                if (count_on) self.ev.progressStep(i + 1, entries.len);
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
            const state: FutureState = @enumFromInt(thunk.future.state.load(.acquire));
            if (state == .resolved) {
                try self.write(thunk.payload.result);
                return;
            }
            // Pass-through (cell-like) thunks hold a value that hasn't been
            // forced yet. Render the wrapped value rather than an opaque
            // `...`, matching how cells used to render their `initial`.
            if (thunk.targetKind() == .pass_through) {
                try self.write(thunk.payload.target.pass_through);
            } else {
                try self.writer.writeAll("...");
            }
        }

        fn writeAttrName(self: *Self, name: []const u8) !void {
            try self.on(col_name);
            if (isBareAttrName(name)) {
                try self.writer.writeAll(name);
            } else {
                try writeQuotedString(self.writer, name);
            }
            try self.off();
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
