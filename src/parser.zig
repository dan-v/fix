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

const Precedence = enum(u8) {
    none,
    assignment, // = (in let)
    pipe, // |>
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

const ParseFn = *const fn (p: *Parser) anyerror!*Node;
const InfixFn = *const fn (p: *Parser, left: *Node) anyerror!*Node;

const Rule = struct {
    prefix: ?ParseFn,
    infix: ?InfixFn,
    prec: Precedence,
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    arena: *ast.AstArena,
    scanner: @import("scanner.zig").Scanner,
    source: []const u8,
    current: Token,
    previous: Token,
    had_error: bool,

    pub fn init(allocator: std.mem.Allocator, arena: *ast.AstArena, source: []const u8) Parser {
        return .{
            .allocator = allocator,
            .arena = arena,
            .scanner = @import("scanner.zig").Scanner.init(source),
            .source = source,
            .current = undefined,
            .previous = undefined,
            .had_error = false,
        };
    }

    pub fn parse(self: *Parser) !*Node {
        self.advance();
        const node = try self.expression();
        if (!self.check(.eof)) {
            self.reportError("Unexpected token after expression.");
        }
        return node;
    }

    pub fn parseFile(self: *Parser) !*Node {
        return self.parse();
    }

    // ---- token stream ----

    fn advance(self: *Parser) void {
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

    fn check(self: *const Parser, tt: TokenType) bool {
        return self.current.type == tt;
    }

    fn match(self: *Parser, tt: TokenType) bool {
        if (!self.check(tt)) return false;
        self.advance();
        return true;
    }

    fn expect(self: *Parser, tt: TokenType, msg: []const u8) !void {
        if (!self.match(tt)) {
            self.reportError(msg);
            // Recovery: skip until we find the expected token or safe token.
            return error.ParseError;
        }
    }

    fn reportError(self: *Parser, msg: []const u8) void {
        if (self.had_error) return;
        self.had_error = true;
        const tok = &self.current;
        std.debug.print("[line {d}] parse error", .{tok.line});
        if (tok.type != .eof) {
            const token_span = self.source[tok.offset .. tok.offset + tok.len];
            std.debug.print(" at '{s}'", .{token_span});
        }
        std.debug.print(": {s}\n", .{msg});
    }

    fn span(self: *const Parser, tok: Token) []const u8 {
        return self.source[tok.offset .. tok.offset + tok.len];
    }

    // ---- precedence ----

    fn rule(tt: TokenType) Rule {
        switch (tt) {
            .left_paren => return .{ .prefix = grouping, .infix = null, .prec = .none },
            .left_brace => return .{ .prefix = attrSet, .infix = null, .prec = .none },
            .left_bracket => return .{ .prefix = list, .infix = null, .prec = .none },
            .identifier => return .{ .prefix = variable, .infix = null, .prec = .none },
            .integer => return .{ .prefix = integer, .infix = null, .prec = .none },
            .float_val => return .{ .prefix = floatLit, .infix = null, .prec = .none },
            .string => return .{ .prefix = stringLit, .infix = null, .prec = .none },
            .path => return .{ .prefix = pathLit, .infix = null, .prec = .none },
            .kw_true => return .{ .prefix = literal, .infix = null, .prec = .none },
            .kw_false => return .{ .prefix = literal, .infix = null, .prec = .none },
            .kw_null => return .{ .prefix = literal, .infix = null, .prec = .none },
            .kw_if => return .{ .prefix = ifElse, .infix = null, .prec = .none },
            .kw_assert => return .{ .prefix = assert_, .infix = null, .prec = .none },
            .kw_with => return .{ .prefix = with_, .infix = null, .prec = .none },
            .kw_let => return .{ .prefix = letIn, .infix = null, .prec = .none },
            .kw_rec => return .{ .prefix = recAttrSet, .infix = null, .prec = .none },
            .bang => return .{ .prefix = unary, .infix = null, .prec = .none },
            .minus => return .{ .prefix = unary, .infix = binary, .prec = .sum },
            .plus => return .{ .prefix = null, .infix = binary, .prec = .sum },
            .slash => return .{ .prefix = null, .infix = binary, .prec = .prod },
            .star => return .{ .prefix = null, .infix = binary, .prec = .prod },
            .equal_equal => return .{ .prefix = null, .infix = binary, .prec = .eq },
            .bang_equal => return .{ .prefix = null, .infix = binary, .prec = .eq },
            .less => return .{ .prefix = null, .infix = binary, .prec = .cmp },
            .less_equal => return .{ .prefix = null, .infix = binary, .prec = .cmp },
            .greater => return .{ .prefix = null, .infix = binary, .prec = .cmp },
            .greater_equal => return .{ .prefix = null, .infix = binary, .prec = .cmp },
            .amp_amp => return .{ .prefix = null, .infix = binary, .prec = .and_ },
            .pipe_pipe => return .{ .prefix = null, .infix = binary, .prec = .or_ },
            .kw_or => return .{ .prefix = null, .infix = attrOr, .prec = .or_ },
            .double_slash => return .{ .prefix = null, .infix = binary, .prec = .update },
            .double_plus => return .{ .prefix = null, .infix = binary, .prec = .concat },
            .arrow => return .{ .prefix = null, .infix = binary, .prec = .or_ },
            .dot => return .{ .prefix = null, .infix = dotAccess, .prec = .primary },
            else => return .{ .prefix = null, .infix = null, .prec = .none },
        }
    }

    fn expression(self: *Parser) anyerror!*Node {
        return self.parsePrecedence(.assignment);
    }

    fn parsePrecedence(self: *Parser, min_prec: Precedence) anyerror!*Node {
        return self.parsePrecedenceWithApply(min_prec, true);
    }

    fn parsePrecedenceWithApply(self: *Parser, min_prec: Precedence, allow_apply: bool) anyerror!*Node {
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
            .minus,
            => true,
            else => false,
        };
    }

    // ---- prefix parsers ----

    fn grouping(self: *Parser) !*Node {
        const expr = try self.expression();
        _ = try self.expect(.right_paren, "Expected ')' after expression.");
        return self.arena.createNode(.parens, .{ .parens = expr });
    }

    fn integer(self: *Parser) !*Node {
        return self.arena.createNode(.integer, .{ .atom = .{
            .offset = self.previous.offset,
            .len = self.previous.len,
        } });
    }

    fn floatLit(self: *Parser) !*Node {
        return self.arena.createNode(.float_val, .{ .atom = .{
            .offset = self.previous.offset,
            .len = self.previous.len,
        } });
    }

    fn stringLit(self: *Parser) !*Node {
        return self.arena.createNode(.string, .{ .atom = .{
            .offset = self.previous.offset,
            .len = self.previous.len,
        } });
    }

    fn pathLit(self: *Parser) !*Node {
        return self.arena.createNode(.path, .{ .atom = .{
            .offset = self.previous.offset,
            .len = self.previous.len,
        } });
    }

    fn variable(self: *Parser) !*Node {
        const name_tok = self.previous;
        if (self.match(.colon)) {
            const body = try self.expression();
            return self.arena.createNode(.lambda, .{ .lambda = .{
                .param_offset = name_tok.offset,
                .param_len = name_tok.len,
                .body = body,
            } });
        }

        return self.arena.createNode(.identifier, .{ .atom = .{
            .offset = name_tok.offset,
            .len = name_tok.len,
        } });
    }

    fn literal(self: *Parser) !*Node {
        const tag: NodeTag = switch (self.previous.type) {
            .kw_true => .bool_true,
            .kw_false => .bool_false,
            .kw_null => .null,
            else => unreachable,
        };
        return self.arena.createNode(tag, .{ .atom = .{ .offset = 0, .len = 0 } });
    }

    fn unary(self: *Parser) !*Node {
        const is_not = self.previous.type == .bang;
        const op: ast.UnaryOp = if (is_not) .not else .negate;
        const operand = try self.parsePrecedence(.unary);
        return self.arena.createNode(.unary_op, .{ .unary = .{ .op = op, .expr = operand } });
    }

    fn attrSet(self: *Parser) !*Node {
        return self.attrSetAfterLeftBrace(false);
    }

    fn recAttrSet(self: *Parser) !*Node {
        _ = try self.expect(.left_brace, "Expected '{' after rec.");
        return self.attrSetAfterLeftBrace(true);
    }

    fn attrSetAfterLeftBrace(self: *Parser, recursive: bool) !*Node {
        const arena_allocator = self.arena.allocator();
        var entries: std.ArrayListUnmanaged(Node.AttrSetEntry) = .empty;

        while (!self.check(.right_brace) and !self.check(.eof)) {
            if (self.match(.kw_inherit)) {
                try self.inheritAttrs(arena_allocator, &entries);
                _ = try self.expect(.semicolon, "Expected ';' after inherit.");
                continue;
            }

            const path = try self.attrDeclarationPath(arena_allocator);
            _ = try self.expect(.equal, "Expected '=' after attribute name.");
            // allow missing semicolons by checking what comes next
            if (!self.check(.semicolon) and !self.check(.right_brace)) {
                _ = self.match(.semicolon); // optional
            }

            const expr = try self.expression();

            try entries.append(arena_allocator, .{
                .path = path,
                .expr = expr,
            });

            if (!self.match(.semicolon)) break;
        }

        _ = try self.expect(.right_brace, "Expected '}' after attribute set.");

        return self.arena.createNode(.attr_set, .{
            .attr_set = .{
                .entries = try entries.toOwnedSlice(arena_allocator),
                .recursive = recursive,
            },
        });
    }

    fn inheritAttrs(
        self: *Parser,
        allocator: std.mem.Allocator,
        entries: *std.ArrayListUnmanaged(Node.AttrSetEntry),
    ) !void {
        const source: ?*Node = if (self.match(.left_paren)) source: {
            const expr = try self.expression();
            _ = try self.expect(.right_paren, "Expected ')' after inherit source.");
            break :source expr;
        } else null;

        var count: usize = 0;
        while (!self.check(.semicolon) and !self.check(.right_brace) and !self.check(.eof)) {
            const name_tok = self.current;
            _ = try self.expect(.identifier, "Expected inherited variable name.");

            const path = try allocator.alloc(Node.Atom, 1);
            path[0] = .{
                .offset = name_tok.offset,
                .len = name_tok.len,
            };
            const expr = if (source) |src|
                try self.inheritSourceAttr(src, path[0])
            else
                try self.arena.createNode(.identifier, .{ .atom = path[0] });

            try entries.append(allocator, .{
                .path = path,
                .expr = expr,
            });
            count += 1;
        }

        if (count == 0) {
            self.reportError("Expected inherited variable name.");
            return error.ParseError;
        }
    }

    fn inheritSourceAttr(self: *Parser, source: *Node, name: Node.Atom) !*Node {
        const segments = try self.arena.allocSlice(Node.Atom, 1);
        segments[0] = name;
        return self.arena.createNode(.attr_path, .{
            .attr_path = .{
                .root = source,
                .segments = segments,
            },
        });
    }

    fn attrDeclarationPath(self: *Parser, allocator: std.mem.Allocator) ![]Node.Atom {
        var segments: std.ArrayListUnmanaged(Node.Atom) = .empty;

        while (true) {
            if (self.match(.identifier) or self.match(.string)) {
                try segments.append(allocator, .{
                    .offset = self.previous.offset,
                    .len = self.previous.len,
                });
            } else {
                self.reportError("Expected attribute name.");
                return error.ParseError;
            }

            if (!self.match(.dot)) break;
        }

        return segments.toOwnedSlice(allocator);
    }

    fn list(self: *Parser) !*Node {
        const arena_allocator = self.arena.allocator();
        var items: std.ArrayListUnmanaged(*Node) = .empty;

        while (!self.check(.right_bracket) and !self.check(.eof)) {
            const item = try self.parsePrecedenceWithApply(.assignment, false);
            try items.append(arena_allocator, item);

            _ = self.match(.comma);
        }

        _ = try self.expect(.right_bracket, "Expected ']' after list.");

        return self.arena.createNode(.list, .{
            .list = .{ .items = try items.toOwnedSlice(arena_allocator) },
        });
    }

    fn ifElse(self: *Parser) !*Node {
        const cond = try self.expression();
        _ = try self.expect(.kw_then, "Expected 'then' after if condition.");
        const then_branch = try self.expression();
        _ = try self.expect(.kw_else, "Expected 'else' after then branch.");
        const else_branch = try self.expression();

        return self.arena.createNode(.if_else, .{
            .if_else = .{
                .cond = cond,
                .then_branch = then_branch,
                .else_branch = else_branch,
            },
        });
    }

    fn assert_(self: *Parser) !*Node {
        const cond = try self.expression();
        _ = try self.expect(.semicolon, "Expected ';' after assert condition.");
        const body = try self.expression();

        return self.arena.createNode(.assert, .{
            .assert = .{ .cond = cond, .body = body },
        });
    }

    fn with_(self: *Parser) !*Node {
        const with_expr = try self.expression();
        _ = try self.expect(.semicolon, "Expected ';' after with expression.");
        const body = try self.expression();

        return self.arena.createNode(.with_expr, .{
            .with_expr = .{ .attr_set = with_expr, .body = body },
        });
    }

    fn letIn(self: *Parser) !*Node {
        const arena_allocator = self.arena.allocator();
        var bindings: std.ArrayListUnmanaged(Node.Binding) = .empty;

        while (!self.check(.kw_in) and !self.check(.eof)) {
            const name_tok = self.current;
            _ = try self.expect(.identifier, "Expected variable name in let binding.");
            _ = try self.expect(.equal, "Expected '=' after variable name.");
            const expr = try self.expression();
            _ = try self.expect(.semicolon, "Expected ';' after let binding.");

            try bindings.append(arena_allocator, .{
                .name_offset = name_tok.offset,
                .name_len = name_tok.len,
                .expr = expr,
            });
        }

        _ = try self.expect(.kw_in, "Expected 'in' after let bindings.");
        const body = try self.expression();

        return self.arena.createNode(.let_in, .{
            .let_in = .{ .bindings = try bindings.toOwnedSlice(arena_allocator), .body = body },
        });
    }

    // ---- infix parsers ----

    fn binary(self: *Parser, left: *Node) !*Node {
        const op: ast.BinaryOp = switch (self.previous.type) {
            .plus => .add,
            .minus => .sub,
            .star => .mul,
            .slash => .div,
            .equal_equal => .eq,
            .bang_equal => .neq,
            .less => .lt,
            .less_equal => .lte,
            .greater => .gt,
            .greater_equal => .gte,
            .amp_amp => .and_,
            .pipe_pipe => .or_,
            .double_slash => .update,
            .double_plus => .concat,
            .arrow => .impl,
            else => unreachable,
        };

        const r = rule(self.previous.type);
        const right = try self.parsePrecedence(@enumFromInt(@intFromEnum(r.prec) + 1));

        return self.makeBinary(op, left, right);
    }

    fn dotAccess(self: *Parser, left: *Node) !*Node {
        // `expr.attr` or `expr."string"` or `expr.${...}`
        const arena_allocator = self.arena.allocator();
        var segments: std.ArrayListUnmanaged(Node.Atom) = .empty;

        while (true) {
            if (self.match(.identifier)) {
                try segments.append(arena_allocator, .{
                    .offset = self.previous.offset,
                    .len = self.previous.len,
                });
            } else if (self.match(.string)) {
                // "string" inside dot access: a."foo"
                try segments.append(arena_allocator, .{
                    .offset = self.previous.offset,
                    .len = self.previous.len,
                });
            } else {
                break;
            }

            if (!self.match(.dot)) break;
        }

        return self.arena.createNode(.attr_path, .{
            .attr_path = .{
                .root = left,
                .segments = try segments.toOwnedSlice(arena_allocator),
            },
        });
    }

    fn attrOr(self: *Parser, left: *Node) !*Node {
        if (left.tag != .attr_path) {
            self.reportError("'or' default requires an attribute path.");
            return error.ParseError;
        }
        const default = try self.expression();
        return self.arena.createNode(.attr_or, .{
            .attr_or = .{ .attr_path = left, .default = default },
        });
    }

    // ---- helpers ----

    fn makeBinary(self: *Parser, op: ast.BinaryOp, left: *Node, right: *Node) !*Node {
        return self.arena.createNode(.binary_op, .{
            .binary = .{ .op = op, .left = left, .right = right },
        });
    }

    fn makeApply(self: *Parser, func: *Node, arg: *Node) !*Node {
        return self.arena.createNode(.apply, .{
            .apply = .{ .func = func, .arg = arg },
        });
    }
};

test "parser applies boolean operator precedence" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "true && false || true");
    const node = try parser.parse();

    try std.testing.expectEqual(NodeTag.binary_op, node.tag);
    try std.testing.expectEqual(ast.BinaryOp.or_, node.data.binary.op);
    try std.testing.expectEqual(NodeTag.binary_op, node.data.binary.left.tag);
    try std.testing.expectEqual(ast.BinaryOp.and_, node.data.binary.left.data.binary.op);
    try std.testing.expectEqual(NodeTag.bool_true, node.data.binary.right.tag);
}

test "parser recognizes identifier lambda" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "x: x + 1");
    const node = try parser.parse();

    try std.testing.expectEqual(NodeTag.lambda, node.tag);
    try std.testing.expectEqualStrings("x", parser.span(.{
        .type = .identifier,
        .offset = node.data.lambda.param_offset,
        .len = node.data.lambda.param_len,
        .line = 1,
    }));
    try std.testing.expectEqual(NodeTag.binary_op, node.data.lambda.body.tag);
}

test "parser recognizes nested attr declarations" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "{ a.b = 1; a.\"c\" = 2; }");
    const node = try parser.parse();

    try std.testing.expectEqual(NodeTag.attr_set, node.tag);
    const entries = node.data.attr_set.entries;
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqual(@as(usize, 2), entries[0].path.len);
    try std.testing.expectEqualStrings("a", parser.span(.{
        .type = .identifier,
        .offset = entries[0].path[0].offset,
        .len = entries[0].path[0].len,
        .line = 1,
    }));
    try std.testing.expectEqualStrings("b", parser.span(.{
        .type = .identifier,
        .offset = entries[0].path[1].offset,
        .len = entries[0].path[1].len,
        .line = 1,
    }));
    try std.testing.expectEqualStrings("\"c\"", parser.span(.{
        .type = .string,
        .offset = entries[1].path[1].offset,
        .len = entries[1].path[1].len,
        .line = 1,
    }));
}

test "parser desugars simple inherit in attrsets" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "{ inherit a b; }");
    const node = try parser.parse();

    try std.testing.expectEqual(NodeTag.attr_set, node.tag);
    const entries = node.data.attr_set.entries;
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqual(@as(usize, 1), entries[0].path.len);
    try std.testing.expectEqualStrings("a", parser.span(.{
        .type = .identifier,
        .offset = entries[0].path[0].offset,
        .len = entries[0].path[0].len,
        .line = 1,
    }));
    try std.testing.expectEqual(NodeTag.identifier, entries[0].expr.tag);
    try std.testing.expectEqualStrings("b", parser.span(.{
        .type = .identifier,
        .offset = entries[1].path[0].offset,
        .len = entries[1].path[0].len,
        .line = 1,
    }));
    try std.testing.expectEqual(NodeTag.identifier, entries[1].expr.tag);
}

test "parser desugars inherit from source expression" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "{ inherit (src) a b; }");
    const node = try parser.parse();

    try std.testing.expectEqual(NodeTag.attr_set, node.tag);
    const entries = node.data.attr_set.entries;
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqual(NodeTag.attr_path, entries[0].expr.tag);
    try std.testing.expectEqual(NodeTag.identifier, entries[0].expr.data.attr_path.root.tag);
    try std.testing.expectEqual(@as(usize, 1), entries[0].expr.data.attr_path.segments.len);
    try std.testing.expectEqualStrings("a", parser.span(.{
        .type = .identifier,
        .offset = entries[0].expr.data.attr_path.segments[0].offset,
        .len = entries[0].expr.data.attr_path.segments[0].len,
        .line = 1,
    }));
    try std.testing.expectEqual(NodeTag.attr_path, entries[1].expr.tag);
    try std.testing.expectEqual(NodeTag.identifier, entries[1].expr.data.attr_path.root.tag);
}

test "parser recognizes attr path or default" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "a.b or 2");
    const node = try parser.parse();

    try std.testing.expectEqual(NodeTag.attr_or, node.tag);
    try std.testing.expectEqual(NodeTag.attr_path, node.data.attr_or.attr_path.tag);
    try std.testing.expectEqual(NodeTag.integer, node.data.attr_or.default.tag);
}
