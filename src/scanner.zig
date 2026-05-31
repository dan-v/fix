//! Lexer / scanner. Produces a token stream from source text.
//! Lock-free single-pass design. No allocation during scanning.
//! Returns byte offsets rather than string slices — the source lives longer.

const std = @import("std");
const token = @import("token.zig");
const string_syntax = @import("string_syntax.zig");
const TokenType = token.TokenType;
const Token = token.Token;

pub const Scanner = struct {
    source: []const u8,
    pos: u32,
    line: u32,

    pub fn init(source: []const u8) Scanner {
        return .{
            .source = source,
            .pos = 0,
            .line = 1,
        };
    }

    pub fn next(self: *Scanner) Token {
        self.skipLayout();

        if (self.pos >= self.source.len) {
            return self.makeToken(.eof, self.pos, 0);
        }

        const start = self.pos;
        const c = self.advance();

        // Fast path: ASCII alpha starts an identifier/keyword.
        if (isAlpha(c)) return self.lexIdentOrKeyword(start);
        if (isDigit(c)) return self.lexNumber(start);
        if (c == '"') return self.lexString(start, .double_quoted);
        if (c == '\'' and self.peek() == '\'') return self.lexString(start, .indented);
        if (c == '.' and (self.peek() == '/' or (self.peek() == '.' and self.peekAhead(1) == '/'))) return self.lexPath(start);

        // Single-character tokens.
        switch (c) {
            '(' => return self.makeToken(.left_paren, start, 1),
            ')' => return self.makeToken(.right_paren, start, 1),
            '{' => return self.makeToken(.left_brace, start, 1),
            '}' => return self.makeToken(.right_brace, start, 1),
            '[' => return self.makeToken(.left_bracket, start, 1),
            ']' => return self.makeToken(.right_bracket, start, 1),
            ',' => return self.makeToken(.comma, start, 1),
            ':' => return self.makeToken(.colon, start, 1),
            '.' => {
                if (self.match('.') and self.match('.')) return self.makeToken(.ellipsis, start, 3);
                return self.makeToken(.dot, start, 1);
            },
            '@' => return self.makeToken(.at, start, 1),
            ';' => return self.makeToken(.semicolon, start, 1),
            '?' => return self.makeToken(.question_mark, start, 1),
            '$' => {
                if (self.match('{')) return self.makeToken(.dollar_curly, start, 2);
                return self.makeToken(.error_token, start, 1);
            },
            '+' => {
                if (self.match('+')) return self.makeToken(.double_plus, start, 2);
                return self.makeToken(.plus, start, 1);
            },
            '*' => return self.makeToken(.star, start, 1),
            '-' => {
                if (self.match('>')) return self.makeToken(.arrow, start, 2);
                return self.makeToken(.minus, start, 1);
            },
            '!' => {
                if (self.match('=')) return self.makeToken(.bang_equal, start, 2);
                return self.makeToken(.bang, start, 1);
            },
            '=' => {
                if (self.match('=')) return self.makeToken(.equal_equal, start, 2);
                return self.makeToken(.equal, start, 1);
            },
            '<' => {
                if (self.match('=')) return self.makeToken(.less_equal, start, 2);
                if (isSearchPathStart(self.peek())) return self.lexSearchPath(start);
                return self.makeToken(.less, start, 1);
            },
            '>' => {
                if (self.match('=')) return self.makeToken(.greater_equal, start, 2);
                return self.makeToken(.greater, start, 1);
            },
            '/' => {
                if (self.match('/')) return self.makeToken(.double_slash, start, 2);
                if (isPathContinue(self.peek()) and !isDigit(self.peek())) return self.lexPath(start);
                return self.makeToken(.slash, start, 1);
            },
            '&' => {
                if (self.match('&')) return self.makeToken(.amp_amp, start, 2);
                return self.makeToken(.error_token, start, 1);
            },
            '|' => {
                if (self.match('|')) return self.makeToken(.pipe_pipe, start, 2);
                return self.makeToken(.error_token, start, 1);
            },
            else => return self.makeToken(.error_token, start, 1),
        }
    }

    fn advance(self: *Scanner) u8 {
        const b = self.source[self.pos];
        self.pos += 1;
        return b;
    }

    fn match(self: *Scanner, expected: u8) bool {
        if (self.pos >= self.source.len) return false;
        if (self.source[self.pos] != expected) return false;
        self.pos += 1;
        return true;
    }

    fn peek(self: *Scanner) u8 {
        if (self.pos >= self.source.len) return 0;
        return self.source[self.pos];
    }

    fn peekAhead(self: *Scanner, offset: u32) u8 {
        const i = self.pos + offset;
        if (i >= self.source.len) return 0;
        return self.source[i];
    }

    fn makeToken(self: *Scanner, tt: TokenType, start: u32, len: u32) Token {
        return Token{ .type = tt, .offset = start, .len = len, .line = self.line };
    }

    fn skipLayout(self: *Scanner) void {
        while (self.pos < self.source.len) {
            switch (self.source[self.pos]) {
                ' ', '\r', '\t' => self.pos += 1,
                '\n' => {
                    self.line += 1;
                    self.pos += 1;
                },
                '#' => {
                    // Line comment
                    while (self.pos < self.source.len and self.source[self.pos] != '\n') {
                        self.pos += 1;
                    }
                },
                '/' => {
                    if (self.pos + 1 < self.source.len and self.source[self.pos + 1] == '*') {
                        // Block comment
                        self.pos += 2;
                        while (self.pos + 1 < self.source.len) {
                            if (self.source[self.pos] == '*' and self.source[self.pos + 1] == '/') {
                                self.pos += 2;
                                break;
                            }
                            if (self.source[self.pos] == '\n') self.line += 1;
                            self.pos += 1;
                        }
                    } else {
                        return; // single '/' is a token
                    }
                },
                else => return,
            }
        }
    }

    fn lexIdentOrKeyword(self: *Scanner, start: u32) Token {
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (!isAlpha(c) and !isDigit(c) and c != '-' and c != '\'' and c != '_') break;
            self.pos += 1;
        }
        const len = self.pos - start;
        const tt = keywordType(self.source[start..][0..len]);
        return self.makeToken(tt, start, len);
    }

    fn lexNumber(self: *Scanner, start: u32) Token {
        while (self.pos < self.source.len and isDigit(self.source[self.pos])) {
            self.pos += 1;
        }
        // Float if dot followed by digit.
        if (self.pos < self.source.len and self.source[self.pos] == '.' and
            self.pos + 1 < self.source.len and isDigit(self.source[self.pos + 1]))
        {
            self.pos += 1; // consume '.'
            while (self.pos < self.source.len and isDigit(self.source[self.pos])) {
                self.pos += 1;
            }
            return self.makeToken(.float_val, start, self.pos - start);
        }
        return self.makeToken(.integer, start, self.pos - start);
    }

    fn lexString(self: *Scanner, start: u32, kind: string_syntax.LiteralKind) Token {
        const end = string_syntax.scanLiteral(self.source, start, kind) orelse {
            self.pos = @intCast(self.source.len);
            return self.makeToken(.error_token, start, self.pos - start);
        };
        self.countNewlines(self.source[start..end]);
        self.pos = @intCast(end);
        return self.makeToken(.string, start, self.pos - start);
    }

    fn countNewlines(self: *Scanner, bytes: []const u8) void {
        for (bytes) |byte| {
            if (byte == '\n') self.line += 1;
        }
    }

    fn lexPath(self: *Scanner, start: u32) Token {
        while (self.pos < self.source.len and isPathContinue(self.source[self.pos])) {
            self.pos += 1;
        }
        return self.makeToken(.path, start, self.pos - start);
    }

    fn lexSearchPath(self: *Scanner, start: u32) Token {
        while (self.pos < self.source.len and self.source[self.pos] != '>') {
            if (!isSearchPathContinue(self.source[self.pos])) break;
            self.pos += 1;
        }
        if (self.pos < self.source.len and self.source[self.pos] == '>') {
            self.pos += 1;
            return self.makeToken(.search_path, start, self.pos - start);
        }
        return self.makeToken(.less, start, 1);
    }

    fn isAlpha(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
    }

    fn isDigit(c: u8) bool {
        return c >= '0' and c <= '9';
    }

    fn isPathContinue(c: u8) bool {
        return isAlpha(c) or isDigit(c) or c == '/' or c == '.' or c == '-' or c == '_' or c == '+';
    }

    fn isSearchPathStart(c: u8) bool {
        return isAlpha(c) or c == '.' or c == '_' or c == '-';
    }

    fn isSearchPathContinue(c: u8) bool {
        return isPathContinue(c);
    }

    fn keywordType(s: []const u8) TokenType {
        // Static lookup using a comptime map.
        const mapping = std.StaticStringMap(TokenType).initComptime(.{
            .{ "if", .kw_if },
            .{ "then", .kw_then },
            .{ "else", .kw_else },
            .{ "assert", .kw_assert },
            .{ "with", .kw_with },
            .{ "let", .kw_let },
            .{ "in", .kw_in },
            .{ "rec", .kw_rec },
            .{ "inherit", .kw_inherit },
            .{ "or", .kw_or },
            .{ "true", .kw_true },
            .{ "false", .kw_false },
            .{ "null", .kw_null },
        });
        return mapping.get(s) orelse .identifier;
    }
};

test "scanner recognizes boolean operator tokens" {
    var scanner = Scanner.init("true && false || true ++ []");

    try std.testing.expectEqual(TokenType.kw_true, scanner.next().type);
    try std.testing.expectEqual(TokenType.amp_amp, scanner.next().type);
    try std.testing.expectEqual(TokenType.kw_false, scanner.next().type);
    try std.testing.expectEqual(TokenType.pipe_pipe, scanner.next().type);
    try std.testing.expectEqual(TokenType.kw_true, scanner.next().type);
    try std.testing.expectEqual(TokenType.double_plus, scanner.next().type);
    try std.testing.expectEqual(TokenType.left_bracket, scanner.next().type);
    try std.testing.expectEqual(TokenType.right_bracket, scanner.next().type);
    try std.testing.expectEqual(TokenType.eof, scanner.next().type);
}

test "scanner recognizes lambda colon" {
    var scanner = Scanner.init("x: x");

    try std.testing.expectEqual(TokenType.identifier, scanner.next().type);
    try std.testing.expectEqual(TokenType.colon, scanner.next().type);
    try std.testing.expectEqual(TokenType.identifier, scanner.next().type);
    try std.testing.expectEqual(TokenType.eof, scanner.next().type);
}

test "scanner recognizes simple path literals" {
    var scanner = Scanner.init("./foo ../bar ../../lib /nix/store/abc");

    try std.testing.expectEqual(TokenType.path, scanner.next().type);
    try std.testing.expectEqual(TokenType.path, scanner.next().type);
    try std.testing.expectEqual(TokenType.path, scanner.next().type);
    try std.testing.expectEqual(TokenType.path, scanner.next().type);
    try std.testing.expectEqual(TokenType.eof, scanner.next().type);
}

test "scanner recognizes indented string literals" {
    var scanner = Scanner.init("''\n  ${\"x\"}\n''");

    try std.testing.expectEqual(TokenType.string, scanner.next().type);
    try std.testing.expectEqual(TokenType.eof, scanner.next().type);
}

test "scanner recognizes nested strings in interpolation" {
    var scanner = Scanner.init("\"a${{ x = \"}\"; }.x}b\"");

    try std.testing.expectEqual(TokenType.string, scanner.next().type);
    try std.testing.expectEqual(TokenType.eof, scanner.next().type);
}

test "scanner recognizes dynamic attribute syntax" {
    var scanner = Scanner.init("attrs.${name}");

    try std.testing.expectEqual(TokenType.identifier, scanner.next().type);
    try std.testing.expectEqual(TokenType.dot, scanner.next().type);
    try std.testing.expectEqual(TokenType.dollar_curly, scanner.next().type);
    try std.testing.expectEqual(TokenType.identifier, scanner.next().type);
    try std.testing.expectEqual(TokenType.right_brace, scanner.next().type);
    try std.testing.expectEqual(TokenType.eof, scanner.next().type);
}

test "scanner recognizes search path literals" {
    var scanner = Scanner.init("<nixpkgs/lib>");

    try std.testing.expectEqual(TokenType.search_path, scanner.next().type);
    try std.testing.expectEqual(TokenType.eof, scanner.next().type);
}
