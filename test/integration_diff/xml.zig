const std = @import("std");

pub fn equivalentXml(allocator: std.mem.Allocator, left: []const u8, right: []const u8) !bool {
    var left_doc = parseXml(allocator, left) catch return false;
    defer left_doc.deinit();

    var right_doc = parseXml(allocator, right) catch return false;
    defer right_doc.deinit();

    return xmlNodesEqual(left_doc.root, right_doc.root);
}

const XmlDocument = struct {
    arena: std.heap.ArenaAllocator,
    root: XmlNode,

    fn deinit(self: *XmlDocument) void {
        self.arena.deinit();
    }
};

const XmlNode = struct {
    name: []const u8,
    attrs: []const XmlAttr,
    children: []const XmlNode,
};

const XmlAttr = struct {
    name: []const u8,
    value: []const u8,
};

const XmlParser = struct {
    allocator: std.mem.Allocator,
    input: []const u8,
    pos: usize = 0,

    fn document(self: *XmlParser) !XmlNode {
        self.skipWhitespace();
        if (self.startsWith("<?xml")) {
            self.pos += "<?xml".len;
            while (!self.eof() and !self.startsWith("?>")) self.pos += 1;
            if (self.eof()) return error.InvalidXml;
            self.pos += "?>".len;
        }
        self.skipWhitespace();
        const root = try self.element();
        self.skipWhitespace();
        if (!self.eof()) return error.InvalidXml;
        return root;
    }

    fn element(self: *XmlParser) !XmlNode {
        try self.expect('<');
        if (self.peek() == '/') return error.InvalidXml;

        const element_name = try self.name();
        var attrs: std.ArrayListUnmanaged(XmlAttr) = .empty;
        defer attrs.deinit(self.allocator);
        var children: std.ArrayListUnmanaged(XmlNode) = .empty;
        defer children.deinit(self.allocator);

        while (true) {
            self.skipWhitespace();
            if (self.consume("/>")) {
                return .{
                    .name = element_name,
                    .attrs = try attrs.toOwnedSlice(self.allocator),
                    .children = &.{},
                };
            }
            if (self.consume(">")) break;

            const attr = try self.attribute();
            if (!ignoredXmlAttr(attr.name)) try attrs.append(self.allocator, attr);
        }

        while (true) {
            self.skipWhitespace();
            if (self.consume("</")) {
                const close_name = try self.name();
                if (!std.mem.eql(u8, element_name, close_name)) return error.InvalidXml;
                self.skipWhitespace();
                try self.expect('>');
                return .{
                    .name = element_name,
                    .attrs = try attrs.toOwnedSlice(self.allocator),
                    .children = try children.toOwnedSlice(self.allocator),
                };
            }
            if (self.eof()) return error.InvalidXml;
            if (self.peek() != '<') return error.InvalidXml;
            try children.append(self.allocator, try self.element());
        }
    }

    fn attribute(self: *XmlParser) !XmlAttr {
        const attr_name = try self.name();
        self.skipWhitespace();
        try self.expect('=');
        self.skipWhitespace();

        const quote = self.peek() orelse return error.InvalidXml;
        if (quote != '"' and quote != '\'') return error.InvalidXml;
        self.pos += 1;

        var value: std.ArrayListUnmanaged(u8) = .empty;
        defer value.deinit(self.allocator);
        while (true) {
            const c = self.peek() orelse return error.InvalidXml;
            self.pos += 1;
            if (c == quote) break;
            if (c == '&') {
                try value.appendSlice(self.allocator, try self.entity());
            } else {
                try value.append(self.allocator, c);
            }
        }

        return .{ .name = attr_name, .value = try value.toOwnedSlice(self.allocator) };
    }

    fn entity(self: *XmlParser) ![]const u8 {
        if (self.consume("amp;")) return "&";
        if (self.consume("lt;")) return "<";
        if (self.consume("gt;")) return ">";
        if (self.consume("quot;")) return "\"";
        if (self.consume("apos;")) return "'";
        return error.InvalidXml;
    }

    fn name(self: *XmlParser) ![]const u8 {
        const start = self.pos;
        while (!self.eof() and isXmlNameChar(self.input[self.pos])) self.pos += 1;
        if (self.pos == start) return error.InvalidXml;
        return try self.allocator.dupe(u8, self.input[start..self.pos]);
    }

    fn skipWhitespace(self: *XmlParser) void {
        while (!self.eof() and std.ascii.isWhitespace(self.input[self.pos])) self.pos += 1;
    }

    fn expect(self: *XmlParser, c: u8) !void {
        if (self.peek() != c) return error.InvalidXml;
        self.pos += 1;
    }

    fn consume(self: *XmlParser, text: []const u8) bool {
        if (!self.startsWith(text)) return false;
        self.pos += text.len;
        return true;
    }

    fn startsWith(self: *const XmlParser, text: []const u8) bool {
        return std.mem.startsWith(u8, self.input[self.pos..], text);
    }

    fn peek(self: *const XmlParser) ?u8 {
        if (self.eof()) return null;
        return self.input[self.pos];
    }

    fn eof(self: *const XmlParser) bool {
        return self.pos >= self.input.len;
    }
};

fn parseXml(allocator: std.mem.Allocator, input: []const u8) !XmlDocument {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    var parser: XmlParser = .{
        .allocator = arena.allocator(),
        .input = input,
    };
    const root = try parser.document();
    return .{
        .arena = arena,
        .root = root,
    };
}

fn xmlNodesEqual(left: XmlNode, right: XmlNode) bool {
    if (!std.mem.eql(u8, left.name, right.name)) return false;
    if (left.attrs.len != right.attrs.len) return false;
    if (left.children.len != right.children.len) return false;

    for (left.attrs) |attr| {
        const other = xmlAttrValue(right.attrs, attr.name) orelse return false;
        if (!std.mem.eql(u8, attr.value, other)) return false;
    }
    for (left.children, right.children) |left_child, right_child| {
        if (!xmlNodesEqual(left_child, right_child)) return false;
    }
    return true;
}

fn xmlAttrValue(attrs: []const XmlAttr, name: []const u8) ?[]const u8 {
    for (attrs) |attr| {
        if (std.mem.eql(u8, attr.name, name)) return attr.value;
    }
    return null;
}

fn ignoredXmlAttr(name: []const u8) bool {
    return std.mem.eql(u8, name, "line") or std.mem.eql(u8, name, "column");
}

fn isXmlNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == ':' or c == '.';
}

test "XML comparison ignores source positions" {
    try std.testing.expect(try equivalentXml(
        std.testing.allocator,
        "<?xml version='1.0' encoding='utf-8'?><expr><attrs><attr line=\"1\" column=\"2\" name=\"a\"><int value=\"1\" /></attr></attrs></expr>",
        "<?xml version='1.0' encoding='utf-8'?><expr><attrs><attr name=\"a\"><int value=\"1\" /></attr></attrs></expr>",
    ));
}

test "XML comparison decodes entities structurally" {
    try std.testing.expect(try equivalentXml(
        std.testing.allocator,
        "<expr><string value=\"a&lt;&amp;&quot;&apos;&gt;\" /></expr>",
        "<expr><string value=\"a&lt;&amp;&quot;&apos;&gt;\" /></expr>",
    ));
    try std.testing.expect(!try equivalentXml(
        std.testing.allocator,
        "<expr><string value=\"a\" /></expr>",
        "<expr><string value=\"b\" /></expr>",
    ));
}
