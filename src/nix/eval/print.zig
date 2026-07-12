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
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        switch (c) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            // Nix escapes a `$` that begins an interpolation (`${`) as `\${` so
            // the printed form re-parses to the same string.
            '$' => {
                if (i + 1 < s.len and s[i + 1] == '{') try writer.writeByte('\\');
                try writer.writeByte('$');
            },
            else => try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}

/// Render a float the way Nix/Lix does: C++ `ostream` default formatting,
/// i.e. printf `%g` with the default precision of 6 significant digits.
/// `18446744073709551616.0` → `1.84467e+19`, `3.1415` → `3.1415`, `1.0` → `1`.
fn writeNixFloat(writer: *std.Io.Writer, v: f64) !void {
    if (std.math.isNan(v)) return writer.writeAll("nan");
    if (std.math.isInf(v)) return writer.writeAll(if (v < 0) "-inf" else "inf");
    var buf: [64]u8 = undefined;
    try writer.writeAll(try formatG(&buf, v, 6));
}

/// Minimal printf `%g` for f64 with `prec` significant digits, matching glibc:
/// choose `%e` when the decimal exponent is < -4 or >= prec, else `%f`, then
/// strip trailing zeros (and a bare trailing `.`).
fn formatG(buf: []u8, v: f64, prec: usize) ![]const u8 {
    const p: usize = if (prec == 0) 1 else prec;
    if (v == 0) return "0";

    // Determine the decimal exponent from a full-precision scientific render.
    var ebuf: [64]u8 = undefined;
    const e_str = try std.fmt.bufPrint(&ebuf, "{e}", .{v});
    const e_idx = std.mem.indexOfScalar(u8, e_str, 'e').?;
    const exp = try std.fmt.parseInt(i32, e_str[e_idx + 1 ..], 10);

    if (exp < -4 or exp >= @as(i32, @intCast(p))) {
        // Scientific with p-1 fractional digits (= p significant digits).
        var sbuf: [64]u8 = undefined;
        const raw = try std.fmt.bufPrint(&sbuf, "{e:.[1]}", .{ v, p - 1 });
        return normalizeSci(buf, raw);
    } else {
        // Fixed with p-1-exp fractional digits.
        const frac: usize = @intCast(@as(i32, @intCast(p)) - 1 - exp);
        var fbuf: [80]u8 = undefined;
        const raw = try std.fmt.bufPrint(&fbuf, "{d:.[1]}", .{ v, frac });
        return stripTrailingZeros(buf, raw);
    }
}

/// Convert Zig's `{e:.N}` output (`1.84467e19`, `5.00000e-3`) into C's `%g`
/// form (`1.84467e+19`): strip trailing zeros in the mantissa, force a signed
/// two-digit-minimum exponent.
fn normalizeSci(out: []u8, raw: []const u8) ![]const u8 {
    const e_idx = std.mem.indexOfScalar(u8, raw, 'e').?;
    var mant = raw[0..e_idx];
    if (std.mem.indexOfScalar(u8, mant, '.') != null) {
        while (mant.len > 0 and mant[mant.len - 1] == '0') mant = mant[0 .. mant.len - 1];
        if (mant.len > 0 and mant[mant.len - 1] == '.') mant = mant[0 .. mant.len - 1];
    }
    const exp = try std.fmt.parseInt(i32, raw[e_idx + 1 ..], 10);
    const sign: u8 = if (exp < 0) '-' else '+';
    const mag: u32 = @intCast(if (exp < 0) -exp else exp);
    return std.fmt.bufPrint(out, "{s}e{c}{d:0>2}", .{ mant, sign, mag });
}

fn stripTrailingZeros(out: []u8, raw: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '.') == null) {
        @memcpy(out[0..raw.len], raw);
        return out[0..raw.len];
    }
    var end = raw.len;
    while (end > 0 and raw[end - 1] == '0') end -= 1;
    if (end > 0 and raw[end - 1] == '.') end -= 1;
    @memcpy(out[0..end], raw[0..end]);
    return out[0..end];
}

fn ValuePrinter(comptime EvaluatorPtr: type) type {
    return struct {
        const Self = @This();

        ev: EvaluatorPtr,
        writer: *std.Io.Writer,
        use_color: bool,
        /// Objects already visited in THIS print. A shared or recursive
        /// reference reached a second time (by any path, not just an
        /// ancestor) renders as «repeated», matching Nix's identity-based
        /// printer — it is never pruned mid-print. Keyed by (id, kind); the
        /// id is a heap slot, so this is identity, not structural, equality.
        seen: std.AutoHashMapUnmanaged(u64, void),
        /// Recursion depth, so top-level (`depth == 0`) list/attrs walks can
        /// report `[i/N]` item progress on the render node without every nested
        /// container fighting over the same counter.
        depth: u32 = 0,

        const SeenKind = enum(u2) { list, attrs, thunk };

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
                    try writeNixFloat(self.writer, value.asFloat());
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
                // Marker strings match Nix's value printer: a user lambda is
                // <LAMBDA>, a builtin is <PRIMOP>, a partially-applied builtin
                // is <PRIMOP-APP>.
                .closure => try self.writer.writeAll("<LAMBDA>"),
                .thunk => try self.writeThunk(value.asObjectId()),
                .builtin => try self.writer.writeAll("<PRIMOP>"),
                .builtin_closure => try self.writer.writeAll("<PRIMOP-APP>"),
                .partial_app => try self.writer.writeAll("<PRIMOP-APP>"),
            }
        }

        fn writeList(self: *Self, id: types.ObjectId) !void {
            const items = try self.ev.heap.getList(id);
            // Nix only records NON-empty containers for identity («repeated»)
            // tracking — an empty list/attrs is always rendered in full. Check
            // emptiness before `enter` so a shared empty `[ ]` (e.g. an
            // `inherit`ed leaf) doesn't spuriously print as «repeated».
            if (items.len == 0) {
                try self.writer.writeAll("[ ]");
                return;
            }
            if (!try self.enter(.list, id)) {
                try self.writer.writeAll("«repeated»");
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

            const stored = try self.ev.heap.getAttrs(id);
            // Empty attrs are never «repeated» (see writeList) — render `{ }`
            // before recording identity.
            if (stored.len == 0) {
                try self.writer.writeAll("{ }");
                return;
            }
            if (!try self.enter(.attrs, id)) {
                try self.writer.writeAll("«repeated»");
                return;
            }

            // Nix prints attribute sets with their keys in lexicographic order,
            // regardless of definition order (fix's JSON/XML writers already do
            // this via attrsets.sortedAttrEntries). Sort a private copy here so
            // the plain value form matches — attr storage is symbol-id order,
            // which is first-seen order, not alphabetical.
            const Entry = std.meta.Elem(@TypeOf(stored));
            const entries = try self.ev.allocator.dupe(Entry, stored);
            defer self.ev.allocator.free(entries);
            const Cmp = struct {
                intern: @TypeOf(self.ev.intern),
                fn lessThan(ctx: @This(), a: Entry, b: Entry) bool {
                    return std.mem.lessThan(u8, ctx.intern.get(a.name), ctx.intern.get(b.name));
                }
            };
            std.mem.sort(Entry, entries, Cmp{ .intern = self.ev.intern }, Cmp.lessThan);

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
                try self.writer.writeAll("«repeated»");
                return;
            }

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
                // An unforced thunk renders as <CODE>, matching Nix's printer.
                try self.writer.writeAll("<CODE>");
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
            const key = (@as(u64, id) << 2) | @intFromEnum(kind);
            const gop = try self.seen.getOrPut(self.ev.allocator, key);
            return !gop.found_existing;
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
