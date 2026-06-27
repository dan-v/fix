//! Recursive descent parser using Pratt-style precedence climbing.
//!
//! Parses a stream of tokens into an AST. The AST lives in an arena allocator.
//! No intermediate representations — direct AST construction.

const std = @import("std");
const token = @import("token.zig");
const TokenType = token.TokenType;
const Token = token.Token;
const ast = @import("ast.zig");
const Node = ast.Node;
const NodeTag = ast.NodeTag;
const diagnostic = @import("diagnostic.zig");
const Diagnostic = diagnostic.Diagnostic;
const prefix = @import("parser/prefix.zig");
const infix = @import("parser/infix.zig");
const Scanner = @import("scanner.zig").Scanner;

pub const Precedence = enum(u8) {
    none,
    assignment, // = (in let)
    pipe, // |>
    impl, // ->
    or_, // ||
    and_, // &&
    eq, // == !=
    cmp, // < > <= >=
    update, // //
    not, // !
    sum, // + -
    prod, // * /
    concat, // ++
    unary, // unary -
    apply, // function application
    primary,
};

pub const ParseFn = *const fn (p: *Parser) anyerror!*Node;
pub const InfixFn = *const fn (p: *Parser, left: *Node) anyerror!*Node;

pub const AttrDeclaration = struct {
    path: []Node.Atom,
    dynamic_name: ?*Node = null,
    static_prefix_len: ?usize = null,
    dynamic_suffix: ?*AttrDeclaration = null,
};

pub const Rule = struct {
    prefix: ?ParseFn,
    infix: ?InfixFn,
    prec: Precedence,
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    arena: *ast.AstArena,
    scanner: Scanner,
    source: []const u8,
    current: Token,
    previous: Token,
    had_error: bool,
    diagnostics: std.ArrayListUnmanaged(Diagnostic),

    pub fn init(allocator: std.mem.Allocator, arena: *ast.AstArena, source: []const u8) Parser {
        return .{
            .allocator = allocator,
            .arena = arena,
            .scanner = Scanner.init(source),
            .source = source,
            .current = undefined,
            .previous = undefined,
            .had_error = false,
            .diagnostics = .empty,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.diagnostics.deinit(self.allocator);
    }

    pub fn parse(self: *Parser) !*Node {
        self.advance();
        const node = try self.expression();
        if (!self.check(.eof)) {
            self.reportError("Unexpected token after expression.");
        }
        if (self.had_error) return error.ParseError;
        return node;
    }

    // ---- token stream ----

    pub fn advance(self: *Parser) void {
        self.previous = self.current;
        while (true) {
            self.current = self.scanner.next();
            if (self.current.type == .error_token) {
                self.reportError("Invalid token.");
                continue;
            }
            break;
        }
    }

    pub fn check(self: *const Parser, tt: TokenType) bool {
        return self.current.type == tt;
    }

    pub fn match(self: *Parser, tt: TokenType) bool {
        if (!self.check(tt)) return false;
        self.advance();
        return true;
    }

    pub fn expect(self: *Parser, tt: TokenType, msg: []const u8) !void {
        if (!self.match(tt)) {
            self.reportError(msg);
            // Recovery: skip until we find the expected token or safe token.
            return error.ParseError;
        }
    }

    pub fn reportError(self: *Parser, msg: []const u8) void {
        self.had_error = true;
        const tok = self.current;
        self.diagnostics.append(self.allocator, .{
            .line = tok.line,
            .column = diagnostic.columnForOffset(self.source, tok.offset),
            .offset = tok.offset,
            .len = tok.len,
            .token_type = tok.type,
            .message = msg,
        }) catch {};
    }

    pub fn span(self: *const Parser, tok: Token) []const u8 {
        return self.source[tok.offset .. tok.offset + tok.len];
    }

    // ---- precedence ----

    pub fn rule(tt: TokenType) Rule {
        switch (tt) {
            .left_paren => return .{ .prefix = prefix.grouping, .infix = null, .prec = .none },
            .left_brace => return .{ .prefix = prefix.braceExpr, .infix = null, .prec = .none },
            .left_bracket => return .{ .prefix = prefix.list, .infix = null, .prec = .none },
            .identifier => return .{ .prefix = prefix.variable, .infix = null, .prec = .none },
            .integer => return .{ .prefix = prefix.integer, .infix = null, .prec = .none },
            .float_val => return .{ .prefix = prefix.floatLit, .infix = null, .prec = .none },
            .string => return .{ .prefix = prefix.stringLit, .infix = null, .prec = .none },
            .path => return .{ .prefix = prefix.pathLit, .infix = null, .prec = .none },
            .search_path => return .{ .prefix = prefix.searchPathLit, .infix = null, .prec = .none },
            .kw_true => return .{ .prefix = prefix.literal, .infix = null, .prec = .none },
            .kw_false => return .{ .prefix = prefix.literal, .infix = null, .prec = .none },
            .kw_null => return .{ .prefix = prefix.literal, .infix = null, .prec = .none },
            .kw_if => return .{ .prefix = prefix.ifElse, .infix = null, .prec = .none },
            .kw_assert => return .{ .prefix = prefix.assert_, .infix = null, .prec = .none },
            .kw_with => return .{ .prefix = prefix.with_, .infix = null, .prec = .none },
            .kw_let => return .{ .prefix = prefix.letIn, .infix = null, .prec = .none },
            .kw_rec => return .{ .prefix = prefix.recAttrSet, .infix = null, .prec = .none },
            .bang => return .{ .prefix = prefix.unary, .infix = null, .prec = .none },
            .minus => return .{ .prefix = prefix.unary, .infix = infix.binary, .prec = .sum },
            .plus => return .{ .prefix = null, .infix = infix.binary, .prec = .sum },
            .slash => return .{ .prefix = null, .infix = infix.binary, .prec = .prod },
            .star => return .{ .prefix = null, .infix = infix.binary, .prec = .prod },
            .equal_equal => return .{ .prefix = null, .infix = infix.binary, .prec = .eq },
            .bang_equal => return .{ .prefix = null, .infix = infix.binary, .prec = .eq },
            .less => return .{ .prefix = null, .infix = infix.binary, .prec = .cmp },
            .less_equal => return .{ .prefix = null, .infix = infix.binary, .prec = .cmp },
            .greater => return .{ .prefix = null, .infix = infix.binary, .prec = .cmp },
            .greater_equal => return .{ .prefix = null, .infix = infix.binary, .prec = .cmp },
            .amp_amp => return .{ .prefix = null, .infix = infix.binary, .prec = .and_ },
            .pipe_pipe => return .{ .prefix = null, .infix = infix.binary, .prec = .or_ },
            .kw_or => return .{ .prefix = null, .infix = infix.attrOr, .prec = .primary },
            .double_slash => return .{ .prefix = null, .infix = infix.binary, .prec = .update },
            .double_plus => return .{ .prefix = null, .infix = infix.binary, .prec = .concat },
            .arrow => return .{ .prefix = null, .infix = infix.binary, .prec = .impl },
            .dot => return .{ .prefix = null, .infix = infix.dotAccess, .prec = .primary },
            .question_mark => return .{ .prefix = null, .infix = infix.hasAttr, .prec = .cmp },
            else => return .{ .prefix = null, .infix = null, .prec = .none },
        }
    }

    pub fn expression(self: *Parser) anyerror!*Node {
        return self.parsePrecedence(.assignment);
    }

    pub fn selectionExpression(self: *Parser) anyerror!*Node {
        self.advance();
        var left = switch (self.previous.type) {
            .identifier => try self.arena.createNode(.identifier, .{ .atom = .{
                .offset = self.previous.offset,
                .len = self.previous.len,
            } }),
            .integer => try prefix.integer(self),
            .float_val => try prefix.floatLit(self),
            .string => try prefix.stringLit(self),
            .path => try prefix.pathLit(self),
            .search_path => try prefix.searchPathLit(self),
            .kw_true, .kw_false, .kw_null => try prefix.literal(self),
            .left_paren => try prefix.grouping(self),
            .left_brace => try prefix.braceExpr(self),
            .left_bracket => try prefix.list(self),
            .kw_rec => try prefix.recAttrSet(self),
            else => {
                self.reportError("Expected selection expression after 'or'.");
                return error.ParseError;
            },
        };

        while (self.current.type == .dot or self.current.type == .kw_or) {
            self.advance();
            left = try rule(self.previous.type).infix.?(self, left);
        }

        return left;
    }

    pub fn parsePrecedence(self: *Parser, min_prec: Precedence) anyerror!*Node {
        return self.parsePrecedenceWithApply(min_prec, true);
    }

    pub fn parsePrecedenceWithApply(self: *Parser, min_prec: Precedence, allow_apply: bool) anyerror!*Node {
        self.advance();
        const prefix_fn = rule(self.previous.type).prefix orelse {
            self.reportError("Expected expression.");
            return error.ParseError;
        };
        var left = try prefix_fn(self);

        while (true) {
            // Check for function application (juxtaposition)
            if (allow_apply and canStartExpr(self.current.type) and @intFromEnum(min_prec) <= @intFromEnum(Precedence.apply)) {
                const prev = self.previous;
                _ = prev;
                // Don't advance — parse the argument
                const arg = try self.parsePrecedence(@enumFromInt(@intFromEnum(Precedence.apply) + 1));
                left = try self.makeApply(left, arg);
                continue;
            }

            const r = rule(self.current.type);
            if (r.infix == null) break;
            if (@intFromEnum(min_prec) > @intFromEnum(r.prec)) break;

            self.advance();
            left = try r.infix.?(self, left);
        }

        return left;
    }

    fn canStartExpr(tt: TokenType) bool {
        return switch (tt) {
            .identifier,
            .integer,
            .float_val,
            .string,
            .path,
            .search_path,
            .left_paren,
            .left_brace,
            .left_bracket,
            .kw_true,
            .kw_false,
            .kw_null,
            .kw_if,
            .kw_assert,
            .kw_with,
            .kw_let,
            .kw_rec,
            .bang,
            => true,
            else => false,
        };
    }

    // ---- helpers ----

    pub fn makeBinary(self: *Parser, op: ast.BinaryOp, left: *Node, right: *Node) !*Node {
        return self.arena.createNode(.binary_op, .{
            .binary = .{ .op = op, .left = left, .right = right },
        });
    }

    pub fn makeApply(self: *Parser, func: *Node, arg: *Node) !*Node {
        return self.arena.createNode(.apply, .{
            .apply = .{ .func = func, .arg = arg },
        });
    }

    pub fn matchAttrName(self: *Parser) bool {
        return self.match(.identifier) or
            self.match(.string) or
            self.match(.kw_or) or
            self.match(.kw_true) or
            self.match(.kw_false) or
            self.match(.kw_null);
    }

    pub fn matchLetBindingName(self: *Parser) bool {
        return self.match(.identifier) or self.match(.kw_or);
    }

    pub fn matchAttrPatternName(self: *Parser) bool {
        return self.match(.identifier) or self.match(.kw_or);
    }
};

test {
    _ = @import("parser/tests.zig");
}
