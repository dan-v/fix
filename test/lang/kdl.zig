//! Minimal KDL reader for the snix nix-language-test-suite `.kdl` case files —
//! a faithful port of run.py's `parse_kdl`. Covers the subset the suite uses:
//! nodes with string/bareword args, key="val" properties, `{...}` children,
//! `//` and `/* */` comments, and `\`-newline continuations. Everything is
//! allocated from the caller's arena.

const std = @import("std");

pub const Prop = struct { key: []const u8, value: []const u8 };

pub const Node = struct {
    name: []const u8,
    args: []const []const u8 = &.{},
    props: []const Prop = &.{},
    children: []const Node = &.{},

    pub fn prop(self: Node, key: []const u8) ?[]const u8 {
        for (self.props) |p| if (std.mem.eql(u8, p.key, key)) return p.value;
        return null;
    }
    pub fn child(self: Node, name: []const u8) ?Node {
        for (self.children) |c| if (std.mem.eql(u8, c.name, name)) return c;
        return null;
    }
};

/// Parse KDL text into a list of top-level nodes.
pub fn parse(arena: std.mem.Allocator, text: []const u8) ![]const Node {
    const pre = try preprocess(arena, text);
    const toks = try tokenize(arena, pre);
    var p: Parser = .{ .toks = toks, .pos = 0 };
    return p.parseNodes(arena, 0);
}

// --- preprocessing: strip comments, join line continuations -----------------

fn preprocess(arena: std.mem.Allocator, text: []const u8) ![]u8 {
    // 1. Strip /* ... */ (non-greedy, spans newlines) -> single space.
    var noblock: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (i + 1 < text.len and text[i] == '/' and text[i + 1] == '*') {
            i += 2;
            while (i + 1 < text.len and !(text[i] == '*' and text[i + 1] == '/')) i += 1;
            i = @min(i + 2, text.len);
            try noblock.append(arena, ' ');
        } else {
            try noblock.append(arena, text[i]);
            i += 1;
        }
    }
    // 2. Strip `// ...` to end of line (naive, as run.py does).
    var noline: std.ArrayListUnmanaged(u8) = .empty;
    var lines = std.mem.splitScalar(u8, noblock.items, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try noline.append(arena, '\n');
        first = false;
        const cut = std.mem.indexOf(u8, line, "//") orelse line.len;
        try noline.appendSlice(arena, line[0..cut]);
    }
    // 3. Join `\`<optional ws>\n continuations -> space.
    var out: std.ArrayListUnmanaged(u8) = .empty;
    i = 0;
    const s = noline.items;
    while (i < s.len) {
        if (s[i] == '\\') {
            var j = i + 1;
            while (j < s.len and (s[j] == ' ' or s[j] == '\t' or s[j] == '\r')) j += 1;
            if (j < s.len and s[j] == '\n') {
                try out.append(arena, ' ');
                i = j + 1;
                continue;
            }
        }
        try out.append(arena, s[i]);
        i += 1;
    }
    return out.items;
}

// --- tokenizer --------------------------------------------------------------

fn tokenize(arena: std.mem.Allocator, s: []const u8) ![]const []const u8 {
    var toks: std.ArrayListUnmanaged([]const u8) = .empty;
    var i: usize = 0;
    const n = s.len;
    while (i < n) {
        const c = s[i];
        if (c == ' ' or c == '\t' or c == '\r') {
            i += 1;
        } else if (c == '\n') {
            try toks.append(arena, "\n");
            i += 1;
        } else if (c == '{' or c == '}' or c == ';') {
            try toks.append(arena, s[i .. i + 1]);
            i += 1;
        } else if (c == '"') {
            var j = i + 1;
            while (j < n and s[j] != '"') {
                if (s[j] == '\\') {
                    j += 2;
                    continue;
                }
                j += 1;
            }
            j = @min(j + 1, n); // include closing quote
            try toks.append(arena, s[i..j]);
            i = j;
        } else {
            var j = i;
            while (j < n and s[j] != ' ' and s[j] != '\t' and s[j] != '\r' and
                s[j] != '\n' and s[j] != '{' and s[j] != '}' and s[j] != ';')
            {
                if (s[j] == '"') {
                    j += 1;
                    while (j < n and s[j] != '"') j += 1;
                }
                j += 1;
            }
            try toks.append(arena, s[i..j]);
            i = j;
        }
    }
    return toks.items;
}

fn isBreak(tok: []const u8) bool {
    return tok.len == 1 and (tok[0] == '{' or tok[0] == '}' or tok[0] == '\n' or tok[0] == ';');
}

// --- recursive-descent parser ----------------------------------------------

const Parser = struct {
    toks: []const []const u8,
    pos: usize,

    fn parseNodes(self: *Parser, arena: std.mem.Allocator, depth: usize) ![]const Node {
        var nodes: std.ArrayListUnmanaged(Node) = .empty;
        while (self.pos < self.toks.len) {
            const t = self.toks[self.pos];
            if (std.mem.eql(u8, t, "}")) {
                self.pos += 1;
                if (depth == 0) continue;
                return nodes.items;
            }
            if (std.mem.eql(u8, t, ";") or std.mem.eql(u8, t, "\n") or std.mem.eql(u8, t, "{")) {
                self.pos += 1;
                continue;
            }
            const name = try unquote(arena, t);
            self.pos += 1;
            var args: std.ArrayListUnmanaged([]const u8) = .empty;
            var props: std.ArrayListUnmanaged(Prop) = .empty;
            while (self.pos < self.toks.len and !isBreak(self.toks[self.pos])) {
                const tk = self.toks[self.pos];
                const eq = std.mem.indexOfScalar(u8, tk, '=');
                if (eq != null and !(tk.len > 0 and tk[0] == '"')) {
                    try props.append(arena, .{
                        .key = tk[0..eq.?],
                        .value = try unquote(arena, tk[eq.? + 1 ..]),
                    });
                } else {
                    try args.append(arena, try unquote(arena, tk));
                }
                self.pos += 1;
            }
            var children: []const Node = &.{};
            if (self.pos < self.toks.len and std.mem.eql(u8, self.toks[self.pos], "{")) {
                self.pos += 1;
                children = try self.parseNodes(arena, depth + 1);
            }
            try nodes.append(arena, .{
                .name = name,
                .args = args.items,
                .props = props.items,
                .children = children,
            });
        }
        return nodes.items;
    }
};

/// A quoted token becomes its unescaped body; a bareword is returned verbatim.
fn unquote(arena: std.mem.Allocator, t: []const u8) ![]const u8 {
    if (t.len >= 2 and t[0] == '"' and t[t.len - 1] == '"') {
        const body = t[1 .. t.len - 1];
        var out: std.ArrayListUnmanaged(u8) = .empty;
        var i: usize = 0;
        while (i < body.len) {
            if (body[i] == '\\' and i + 1 < body.len) {
                const e = body[i + 1];
                try out.append(arena, switch (e) {
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    '0' => 0,
                    else => e, // \\  \"  and anything else -> literal
                });
                i += 2;
            } else {
                try out.append(arena, body[i]);
                i += 1;
            }
        }
        return out.items;
    }
    return t;
}
