//! A reader for the block-style YAML that pyyaml emits, producing a
//! `std.json.Value`. The Lix parse-okay goldens are the reference parser's AST
//! run through `yaml.dump` (sorted keys, fixed indentation). Because pyyaml is a
//! deterministic function of the data and fix's `parse --json` is the same data
//! as JSON, comparing the two parsed *values* structurally is equivalent to the
//! run.py string compare — without re-implementing pyyaml's emitter.
//!
//! Only the shapes pyyaml actually produces here are handled: block mappings and
//! sequences, plain scalars (int/float/bool/null/string), and single- and
//! double-quoted scalars including pyyaml's line folding.

const std = @import("std");
const Value = std.json.Value;

pub fn parse(arena: std.mem.Allocator, text: []const u8) !Value {
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| try lines.append(arena, line);
    var p: Parser = .{ .arena = arena, .lines = lines.items, .i = 0 };
    p.skipBlank();
    if (p.i >= p.lines.len) return .null;
    return p.parseNode(indentOf(p.lines[p.i]));
}

fn indentOf(line: []const u8) usize {
    var n: usize = 0;
    while (n < line.len and line[n] == ' ') n += 1;
    return n;
}

fn isBlank(line: []const u8) bool {
    return std.mem.trim(u8, line, " \t\r").len == 0;
}

const Parser = struct {
    arena: std.mem.Allocator,
    lines: [][]const u8,
    i: usize,

    fn skipBlank(self: *Parser) void {
        while (self.i < self.lines.len and isBlank(self.lines[self.i])) self.i += 1;
    }

    fn parseNode(self: *Parser, indent: usize) anyerror!Value {
        self.skipBlank();
        const content = self.lines[self.i][indent..];
        if (std.mem.eql(u8, content, "-") or std.mem.startsWith(u8, content, "- "))
            return self.parseSeq(indent);
        if (isMappingLine(content))
            return self.parseMap(indent);
        // A bare scalar node.
        self.i += 1;
        return self.parseScalar(content);
    }

    fn parseMap(self: *Parser, indent: usize) !Value {
        var obj: std.json.ObjectMap = .empty;
        while (true) {
            self.skipBlank();
            if (self.i >= self.lines.len) break;
            const line = self.lines[self.i];
            const ind = indentOf(line);
            if (ind < indent) break;
            const content = line[indent..];
            if (std.mem.startsWith(u8, content, "- ")) break;
            const colon = colonIndex(content) orelse break;
            const key = content[0..colon];
            var rest = content[colon + 1 ..];
            self.i += 1;
            var val: Value = undefined;
            if (std.mem.trim(u8, rest, " ").len == 0) {
                // Nested block on the following, more-indented lines.
                self.skipBlank();
                val = try self.parseNode(indentOf(self.lines[self.i]));
            } else {
                if (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
                if (std.mem.eql(u8, rest, "[]")) {
                    val = .{ .array = std.json.Array.init(self.arena) };
                } else if (std.mem.eql(u8, rest, "{}")) {
                    val = .{ .object = std.json.ObjectMap.empty };
                } else {
                    val = try self.parseScalar(rest);
                }
            }
            try obj.put(self.arena, key, val);
        }
        return .{ .object = obj };
    }

    fn parseSeq(self: *Parser, indent: usize) !Value {
        var arr = std.json.Array.init(self.arena);
        while (true) {
            self.skipBlank();
            if (self.i >= self.lines.len) break;
            const line = self.lines[self.i];
            if (indentOf(line) != indent) break;
            const content = line[indent..];
            if (!std.mem.startsWith(u8, content, "- ") and !std.mem.eql(u8, content, "-")) break;
            // Rewrite "- " into two spaces so the item parses as a node at
            // indent+2 (its inline first line plus any deeper following lines).
            if (std.mem.eql(u8, content, "-")) {
                self.i += 1;
                self.skipBlank();
                try arr.append(try self.parseNode(indentOf(self.lines[self.i])));
            } else {
                const rewritten = try self.arena.dupe(u8, line);
                rewritten[indent] = ' '; // '-' -> ' '
                self.lines[self.i] = rewritten;
                try arr.append(try self.parseNode(indent + 2));
            }
        }
        return .{ .array = arr };
    }

    /// Parse an inline scalar beginning with `first` (the text after `key: `),
    /// consuming continuation lines for a folded quoted scalar.
    fn parseScalar(self: *Parser, first: []const u8) !Value {
        if (first.len > 0 and first[0] == '\'') return .{ .string = try self.parseSingle(first) };
        if (first.len > 0 and first[0] == '"') return .{ .string = try self.parseDouble(first) };
        return classifyPlain(std.mem.trim(u8, first, " \t\r"));
    }

    fn parseSingle(self: *Parser, first: []const u8) ![]const u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        var seg = first[1..];
        var breaks: usize = 0;
        while (true) {
            var j: usize = 0;
            while (j < seg.len) {
                if (seg[j] == '\'') {
                    if (j + 1 < seg.len and seg[j + 1] == '\'') {
                        try self.flushFold(&buf, &breaks);
                        try buf.append(self.arena, '\'');
                        j += 2;
                        continue;
                    }
                    try self.flushFold(&buf, &breaks);
                    return buf.items; // closing quote
                }
                try self.flushFold(&buf, &breaks);
                try buf.append(self.arena, seg[j]);
                j += 1;
            }
            breaks += 1;
            if (self.i >= self.lines.len) return error.UnterminatedScalar;
            seg = std.mem.trimStart(u8, self.lines[self.i], " ");
            self.i += 1;
        }
    }

    fn parseDouble(self: *Parser, first: []const u8) ![]const u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        var seg = first[1..];
        var breaks: usize = 0;
        while (true) {
            var j: usize = 0;
            var escaped_break = false;
            while (j < seg.len) {
                const c = seg[j];
                if (c == '"') {
                    try self.flushFold(&buf, &breaks);
                    return buf.items; // closing quote
                }
                if (c == '\\') {
                    if (j + 1 >= seg.len) {
                        escaped_break = true; // trailing '\' = line continuation
                        break;
                    }
                    try self.flushFold(&buf, &breaks);
                    const e = seg[j + 1];
                    switch (e) {
                        'n' => try buf.append(self.arena, '\n'),
                        't' => try buf.append(self.arena, '\t'),
                        'r' => try buf.append(self.arena, '\r'),
                        '0' => try buf.append(self.arena, 0),
                        'x', 'u', 'U' => {
                            // \xHH \uHHHH \UHHHHHHHH -> the code point, UTF-8 encoded.
                            const ndig: usize = switch (e) {
                                'x' => 2,
                                'u' => 4,
                                else => 8,
                            };
                            if (j + 2 + ndig <= seg.len) {
                                if (std.fmt.parseInt(u21, seg[j + 2 .. j + 2 + ndig], 16)) |cp| {
                                    var ub: [4]u8 = undefined;
                                    const n = std.unicode.utf8Encode(cp, &ub) catch 0;
                                    try buf.appendSlice(self.arena, ub[0..n]);
                                    j += 2 + ndig;
                                    continue;
                                } else |_| {}
                            }
                            try buf.append(self.arena, e); // malformed -> literal
                        },
                        else => try buf.append(self.arena, e), // \\ \" \/ \<space> -> literal
                    }
                    j += 2;
                    continue;
                }
                try self.flushFold(&buf, &breaks);
                try buf.append(self.arena, c);
                j += 1;
            }
            if (self.i >= self.lines.len) return error.UnterminatedScalar;
            // An escaped break contributes nothing; an unescaped one folds to a
            // space. Either way leading indentation on the next line is stripped.
            if (!escaped_break) breaks += 1;
            seg = std.mem.trimStart(u8, self.lines[self.i], " ");
            self.i += 1;
        }
    }

    fn flushFold(self: *Parser, buf: *std.ArrayListUnmanaged(u8), breaks: *usize) !void {
        if (breaks.* == 0) return;
        if (breaks.* == 1) {
            try buf.append(self.arena, ' ');
        } else {
            for (0..breaks.* - 1) |_| try buf.append(self.arena, '\n');
        }
        breaks.* = 0;
    }
};

fn isMappingLine(content: []const u8) bool {
    return colonIndex(content) != null;
}

/// The colon that separates a block-mapping key from its value: a `:` followed
/// by a space or end-of-line. (Keys in these goldens are bare identifiers.)
fn colonIndex(content: []const u8) ?usize {
    var i: usize = 0;
    while (i < content.len) : (i += 1) {
        if (content[i] == ':' and (i + 1 == content.len or content[i + 1] == ' ')) return i;
    }
    return null;
}

fn classifyPlain(s: []const u8) Value {
    if (std.mem.eql(u8, s, "true")) return .{ .bool = true };
    if (std.mem.eql(u8, s, "false")) return .{ .bool = false };
    if (std.mem.eql(u8, s, "null") or std.mem.eql(u8, s, "~")) return .null;
    if (std.fmt.parseInt(i64, s, 10)) |n| {
        return .{ .integer = n };
    } else |_| {}
    if (looksFloat(s)) {
        if (std.fmt.parseFloat(f64, s)) |f| return .{ .float = f } else |_| {}
    }
    return .{ .string = s };
}

fn looksFloat(s: []const u8) bool {
    // Avoid treating an arbitrary token (e.g. a hex-looking string) as a float:
    // require it to be made only of float-legal characters.
    if (s.len == 0) return false;
    var has_digit = false;
    for (s) |c| switch (c) {
        '0'...'9' => has_digit = true,
        '.', '-', '+', 'e', 'E' => {},
        else => return false,
    };
    return has_digit and (std.mem.indexOfScalar(u8, s, '.') != null or
        std.mem.indexOfScalar(u8, s, 'e') != null or std.mem.indexOfScalar(u8, s, 'E') != null);
}

/// Order-independent structural equality of two JSON values (object key order
/// differs between pyyaml's sorted goldens and fix's emission order).
pub fn equals(a: Value, b: Value) bool {
    return switch (a) {
        .null => b == .null,
        .bool => |x| b == .bool and b.bool == x,
        .integer => |x| switch (b) {
            .integer => |y| x == y,
            .float => |y| @as(f64, @floatFromInt(x)) == y,
            else => false,
        },
        .float => |x| switch (b) {
            .float => |y| x == y,
            .integer => |y| x == @as(f64, @floatFromInt(y)),
            else => false,
        },
        .number_string => |x| b == .number_string and std.mem.eql(u8, x, b.number_string),
        .string => |x| b == .string and std.mem.eql(u8, x, b.string),
        .array => |x| {
            if (b != .array or x.items.len != b.array.items.len) return false;
            for (x.items, b.array.items) |ea, eb| if (!equals(ea, eb)) return false;
            return true;
        },
        .object => |x| {
            if (b != .object or x.count() != b.object.count()) return false;
            var it = x.iterator();
            while (it.next()) |entry| {
                const other = b.object.get(entry.key_ptr.*) orelse return false;
                if (!equals(entry.value_ptr.*, other)) return false;
            }
            return true;
        },
    };
}
