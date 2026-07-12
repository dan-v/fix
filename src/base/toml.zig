//! Minimal arena-backed TOML parser backing `builtins.fromTOML`: parses tables,
//! array-of-tables, inline tables/arrays, and scalar values into a tree owned
//! by the returned `Parsed` arena.

const std = @import("std");

pub const Entry = struct {
    key: []const u8,
    value: Value,
};

pub const Table = struct {
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    fn find(self: *Table, key: []const u8) ?*Entry {
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.key, key)) return entry;
        }
        return null;
    }
};

pub const Value = union(enum) {
    boolean: bool,
    integer: i64,
    float: f64,
    string: []const u8,
    array: []const Value,
    table: *Table,
};

pub const Parsed = struct {
    arena: @import("arena.zig").ArenaAllocator,
    root: *Table,

    pub fn deinit(self: *Parsed) void {
        self.arena.deinit();
    }
};

pub fn parse(allocator: std.mem.Allocator, text: []const u8) !Parsed {
    var arena = @import("arena.zig").ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    var parser = Parser{
        .allocator = arena.allocator(),
        .text = text,
        .root = try newTable(arena.allocator()),
    };
    try parser.parseDocument();

    return .{ .arena = arena, .root = parser.root };
}

const Parser = struct {
    allocator: std.mem.Allocator,
    text: []const u8,
    pos: usize = 0,
    root: *Table,
    current: ?*Table = null,

    fn parseDocument(self: *Parser) !void {
        self.current = self.root;
        while (true) {
            self.skipTrivia();
            if (self.eof()) return;
            if (self.peek() == '[') {
                _ = self.advance();
                if (self.consume('[')) {
                    const path = try self.parseKeyPath(']');
                    self.expectChar(']') catch return error.InvalidToml;
                    self.expectChar(']') catch return error.InvalidToml;
                    self.current = try self.appendArrayTablePath(self.root, path);
                } else {
                    const path = try self.parseKeyPath(']');
                    self.expectChar(']') catch return error.InvalidToml;
                    self.current = try self.ensureTablePath(self.root, path);
                }
            } else {
                const path = try self.parseKeyPath('=');
                self.expectChar('=') catch return error.InvalidToml;
                const value = try self.parseValue();
                try self.putPath(self.current.?, path, value);
            }
            try self.finishStatement();
        }
    }

    fn parseValue(self: *Parser) anyerror!Value {
        self.skipInlineSpace();
        if (self.eof()) return error.InvalidToml;
        return switch (self.peek()) {
            '"' => .{ .string = try self.parseBasicString() },
            '\'' => .{ .string = try self.parseLiteralString() },
            '[' => try self.parseArray(),
            '{' => try self.parseInlineTable(),
            else => try self.parseBareValue(),
        };
    }

    fn parseArray(self: *Parser) !Value {
        self.expectChar('[') catch unreachable;
        var items: std.ArrayListUnmanaged(Value) = .empty;
        while (true) {
            self.skipTrivia();
            if (self.consume(']')) break;
            try items.append(self.allocator, try self.parseValue());
            self.skipTrivia();
            if (self.consume(']')) break;
            self.expectChar(',') catch return error.InvalidToml;
        }
        return .{ .array = try items.toOwnedSlice(self.allocator) };
    }

    fn parseInlineTable(self: *Parser) !Value {
        self.expectChar('{') catch unreachable;
        const table = try newTable(self.allocator);
        while (true) {
            self.skipInlineSpace();
            if (self.consume('}')) break;
            const path = try self.parseKeyPath('=');
            self.expectChar('=') catch return error.InvalidToml;
            const value = try self.parseValue();
            try self.putPath(table, path, value);
            self.skipInlineSpace();
            if (self.consume('}')) break;
            self.expectChar(',') catch return error.InvalidToml;
        }
        return .{ .table = table };
    }

    fn parseBareValue(self: *Parser) !Value {
        const start = self.pos;
        while (!self.eof()) {
            const c = self.peek();
            if (c == '#' or c == ',' or c == ']' or c == '}' or c == '\n' or c == '\r') break;
            _ = self.advance();
        }
        const raw = std.mem.trim(u8, self.text[start..self.pos], " \t");
        if (std.mem.eql(u8, raw, "true")) return .{ .boolean = true };
        if (std.mem.eql(u8, raw, "false")) return .{ .boolean = false };
        if (parseInteger(self.allocator, raw)) |integer| return .{ .integer = integer } else |err| {
            // An integer-shaped literal (no '.'/'e'/'E') that fails to parse is
            // out of range — propagate rather than degrading to a float, so a
            // 64-bit overflow errors instead of silently becoming ~9.2e18.
            if (raw.len != 0 and std.mem.indexOfAny(u8, raw, ".eE") == null and
                (std.ascii.isDigit(raw[0]) or raw[0] == '+' or raw[0] == '-')) return err;
        }
        if (parseFloat(self.allocator, raw)) |float| return .{ .float = float } else |_| {}
        if (raw.len != 0) return .{ .string = try self.allocator.dupe(u8, raw) };
        return error.InvalidToml;
    }

    fn parseKeyPath(self: *Parser, terminator: u8) ![]const []const u8 {
        var keys: std.ArrayListUnmanaged([]const u8) = .empty;
        while (true) {
            self.skipInlineSpace();
            try keys.append(self.allocator, try self.parseKey());
            self.skipInlineSpace();
            if (self.peekOrZero() == terminator) break;
            self.expectChar('.') catch return error.InvalidToml;
        }
        return keys.toOwnedSlice(self.allocator);
    }

    fn parseKey(self: *Parser) ![]const u8 {
        if (self.peekOrZero() == '"') return self.parseBasicString();
        if (self.peekOrZero() == '\'') return self.parseLiteralString();
        const start = self.pos;
        while (!self.eof()) {
            const c = self.peek();
            if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-') {
                _ = self.advance();
            } else break;
        }
        if (self.pos == start) return error.InvalidToml;
        return self.text[start..self.pos];
    }

    fn parseBasicString(self: *Parser) ![]const u8 {
        if (self.startsWith("\"\"\"")) return self.parseDelimitedString("\"\"\"", true);
        return self.parseDelimitedString("\"", true);
    }

    fn parseLiteralString(self: *Parser) ![]const u8 {
        if (self.startsWith("'''")) return self.parseDelimitedString("'''", false);
        return self.parseDelimitedString("'", false);
    }

    fn parseDelimitedString(self: *Parser, delimiter: []const u8, escapes: bool) ![]const u8 {
        self.pos += delimiter.len;
        var out: std.ArrayListUnmanaged(u8) = .empty;
        while (!self.eof()) {
            if (self.startsWith(delimiter)) {
                self.pos += delimiter.len;
                return out.toOwnedSlice(self.allocator);
            }
            const c = self.advance();
            if (!escapes or c != '\\') {
                try out.append(self.allocator, c);
                continue;
            }
            if (self.eof()) return error.InvalidToml;
            switch (self.advance()) {
                'b' => try out.append(self.allocator, 0x08),
                't' => try out.append(self.allocator, '\t'),
                'n' => try out.append(self.allocator, '\n'),
                'f' => try out.append(self.allocator, 0x0c),
                'r' => try out.append(self.allocator, '\r'),
                '"' => try out.append(self.allocator, '"'),
                '\\' => try out.append(self.allocator, '\\'),
                'u' => try self.appendCodepoint(&out, 4),
                'U' => try self.appendCodepoint(&out, 8),
                else => return error.InvalidToml,
            }
        }
        return error.InvalidToml;
    }

    fn appendCodepoint(self: *Parser, out: *std.ArrayListUnmanaged(u8), digits: usize) !void {
        if (self.pos + digits > self.text.len) return error.InvalidToml;
        const codepoint = std.fmt.parseInt(u21, self.text[self.pos .. self.pos + digits], 16) catch return error.InvalidToml;
        self.pos += digits;
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(codepoint, &buf) catch return error.InvalidToml;
        try out.appendSlice(self.allocator, buf[0..len]);
    }

    fn ensureTablePath(self: *Parser, base: *Table, path: []const []const u8) !*Table {
        // Array-aware: a `[fruit.physical]` header after `[[fruit]]` navigates
        // into the LAST element of the `fruit` array-of-tables before creating
        // `physical`, so intermediate array-table segments must be followed.
        var table = base;
        for (path) |key| {
            table = try self.descendArrayAwareTable(table, key);
        }
        return table;
    }

    fn appendArrayTablePath(self: *Parser, base: *Table, path: []const []const u8) !*Table {
        if (path.len == 0) return error.InvalidToml;
        var table = base;
        for (path[0 .. path.len - 1]) |key| {
            table = try self.descendArrayAwareTable(table, key);
        }

        const child = try newTable(self.allocator);
        const key = path[path.len - 1];
        if (table.find(key)) |entry| {
            if (entry.value != .array) return error.DuplicateAttribute;
            entry.value.array = try self.appendValue(entry.value.array, .{ .table = child });
        } else {
            const values = try self.allocator.alloc(Value, 1);
            values[0] = .{ .table = child };
            try table.entries.append(self.allocator, .{ .key = key, .value = .{ .array = values } });
        }
        return child;
    }

    fn descendArrayAwareTable(self: *Parser, table: *Table, key: []const u8) !*Table {
        if (table.find(key)) |entry| {
            switch (entry.value) {
                .table => |child| return child,
                .array => |items| {
                    if (items.len == 0 or items[items.len - 1] != .table) return error.InvalidToml;
                    return items[items.len - 1].table;
                },
                else => return error.DuplicateAttribute,
            }
        }

        const child = try newTable(self.allocator);
        try table.entries.append(self.allocator, .{ .key = key, .value = .{ .table = child } });
        return child;
    }

    fn appendValue(self: *Parser, values: []const Value, value: Value) ![]const Value {
        const out = try self.allocator.alloc(Value, values.len + 1);
        @memcpy(out[0..values.len], values);
        out[values.len] = value;
        return out;
    }

    fn putPath(self: *Parser, base: *Table, path: []const []const u8, value: Value) !void {
        if (path.len == 0) return error.InvalidToml;
        var table = base;
        for (path[0 .. path.len - 1]) |key| {
            if (table.find(key)) |entry| {
                if (entry.value != .table) return error.DuplicateAttribute;
                table = entry.value.table;
            } else {
                const child = try newTable(self.allocator);
                try table.entries.append(self.allocator, .{ .key = key, .value = .{ .table = child } });
                table = child;
            }
        }
        const final_key = path[path.len - 1];
        if (table.find(final_key) != null) return error.DuplicateAttribute;
        try table.entries.append(self.allocator, .{ .key = final_key, .value = value });
    }

    fn finishStatement(self: *Parser) !void {
        self.skipInlineSpace();
        if (self.consume('#')) {
            while (!self.eof() and self.peek() != '\n') _ = self.advance();
        }
        if (self.eof()) return;
        if (self.consume('\n')) return;
        if (self.consume('\r')) {
            _ = self.consume('\n');
            return;
        }
        return error.InvalidToml;
    }

    fn skipTrivia(self: *Parser) void {
        while (!self.eof()) {
            self.skipInlineSpace();
            if (self.consume('#')) {
                while (!self.eof() and self.peek() != '\n') _ = self.advance();
                continue;
            }
            if (self.consume('\n')) continue;
            if (self.consume('\r')) {
                _ = self.consume('\n');
                continue;
            }
            break;
        }
    }

    fn skipInlineSpace(self: *Parser) void {
        while (!self.eof() and (self.peek() == ' ' or self.peek() == '\t')) _ = self.advance();
    }

    fn expectChar(self: *Parser, c: u8) !void {
        self.skipInlineSpace();
        if (!self.consume(c)) return error.InvalidToml;
    }

    fn consume(self: *Parser, c: u8) bool {
        if (!self.eof() and self.text[self.pos] == c) {
            self.pos += 1;
            return true;
        }
        return false;
    }

    fn startsWith(self: *const Parser, needle: []const u8) bool {
        return std.mem.startsWith(u8, self.text[self.pos..], needle);
    }

    fn eof(self: *const Parser) bool {
        return self.pos >= self.text.len;
    }

    fn peek(self: *const Parser) u8 {
        return self.text[self.pos];
    }

    fn peekOrZero(self: *const Parser) u8 {
        return if (self.eof()) 0 else self.peek();
    }

    fn advance(self: *Parser) u8 {
        const c = self.text[self.pos];
        self.pos += 1;
        return c;
    }
};

fn newTable(allocator: std.mem.Allocator) !*Table {
    const table = try allocator.create(Table);
    table.* = .{};
    return table;
}

fn parseInteger(allocator: std.mem.Allocator, raw: []const u8) !i64 {
    if (raw.len == 0) return error.InvalidToml;
    const cleaned = try cleanNumber(allocator, raw);
    defer allocator.free(cleaned);

    var sign: i64 = 1;
    var number = cleaned;
    if (number.len > 0 and (number[0] == '+' or number[0] == '-')) {
        if (number[0] == '-') sign = -1;
        number = number[1..];
    }
    if (number.len >= 2 and number[0] == '0') {
        const base: u8 = switch (number[1]) {
            'x' => 16,
            'o' => 8,
            'b' => 2,
            else => 10,
        };
        // Hex/oct/bin literals can contain digits like 'e'/'E' (0xDEADBEEF), so
        // check the radix prefix BEFORE rejecting float indicators.
        if (base != 10) return sign * @as(i64, @intCast(std.fmt.parseInt(u64, number[2..], base) catch return error.InvalidToml));
    }
    // A base-10 literal with a decimal point or exponent is a float, not an int.
    if (std.mem.indexOfAny(u8, number, ".eE") != null) return error.InvalidToml;
    return std.fmt.parseInt(i64, cleaned, 10) catch return error.InvalidToml;
}

fn parseFloat(allocator: std.mem.Allocator, raw: []const u8) !f64 {
    if (raw.len == 0) return error.InvalidToml;
    const cleaned = try cleanNumber(allocator, raw);
    defer allocator.free(cleaned);
    return std.fmt.parseFloat(f64, cleaned) catch return error.InvalidToml;
}

fn cleanNumber(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (raw) |c| {
        if (c != '_') try out.append(allocator, c);
    }
    return out.toOwnedSlice(allocator);
}
