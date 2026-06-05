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

const Precedence = enum(u8) {
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

const ParseFn = *const fn (p: *Parser) anyerror!*Node;
const InfixFn = *const fn (p: *Parser, left: *Node) anyerror!*Node;

const AttrDeclaration = struct {
    path: []Node.Atom,
    dynamic_name: ?*Node = null,
    tail_dynamic_name: ?*Node = null,
    static_prefix_len: ?usize = null,
    dynamic_suffix: ?*AttrDeclaration = null,
};

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
    diagnostics: std.ArrayListUnmanaged(Diagnostic),

    pub fn init(allocator: std.mem.Allocator, arena: *ast.AstArena, source: []const u8) Parser {
        return .{
            .allocator = allocator,
            .arena = arena,
            .scanner = @import("scanner.zig").Scanner.init(source),
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

    fn span(self: *const Parser, tok: Token) []const u8 {
        return self.source[tok.offset .. tok.offset + tok.len];
    }

    // ---- precedence ----

    fn rule(tt: TokenType) Rule {
        switch (tt) {
            .left_paren => return .{ .prefix = grouping, .infix = null, .prec = .none },
            .left_brace => return .{ .prefix = braceExpr, .infix = null, .prec = .none },
            .left_bracket => return .{ .prefix = list, .infix = null, .prec = .none },
            .identifier => return .{ .prefix = variable, .infix = null, .prec = .none },
            .integer => return .{ .prefix = integer, .infix = null, .prec = .none },
            .float_val => return .{ .prefix = floatLit, .infix = null, .prec = .none },
            .string => return .{ .prefix = stringLit, .infix = null, .prec = .none },
            .path => return .{ .prefix = pathLit, .infix = null, .prec = .none },
            .search_path => return .{ .prefix = searchPathLit, .infix = null, .prec = .none },
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
            .kw_or => return .{ .prefix = null, .infix = attrOr, .prec = .primary },
            .double_slash => return .{ .prefix = null, .infix = binary, .prec = .update },
            .double_plus => return .{ .prefix = null, .infix = binary, .prec = .concat },
            .arrow => return .{ .prefix = null, .infix = binary, .prec = .impl },
            .dot => return .{ .prefix = null, .infix = dotAccess, .prec = .primary },
            .question_mark => return .{ .prefix = null, .infix = hasAttr, .prec = .cmp },
            else => return .{ .prefix = null, .infix = null, .prec = .none },
        }
    }

    fn expression(self: *Parser) anyerror!*Node {
        return self.parsePrecedence(.assignment);
    }

    fn selectionExpression(self: *Parser) anyerror!*Node {
        self.advance();
        var left = switch (self.previous.type) {
            .identifier => try self.arena.createNode(.identifier, .{ .atom = .{
                .offset = self.previous.offset,
                .len = self.previous.len,
            } }),
            .integer => try self.integer(),
            .float_val => try self.floatLit(),
            .string => try self.stringLit(),
            .path => try self.pathLit(),
            .search_path => try self.searchPathLit(),
            .kw_true, .kw_false, .kw_null => try self.literal(),
            .left_paren => try self.grouping(),
            .left_brace => try self.braceExpr(),
            .left_bracket => try self.list(),
            .kw_rec => try self.recAttrSet(),
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

    fn isDisallowedListItemStart(tt: TokenType) bool {
        return switch (tt) {
            .kw_if,
            .kw_assert,
            .kw_with,
            .kw_let,
            .bang,
            .minus,
            => true,
            else => false,
        };
    }

    fn isDisallowedListItemContinuation(tt: TokenType) bool {
        return switch (tt) {
            .colon,
            .plus,
            .minus,
            .slash,
            .star,
            .equal_equal,
            .bang_equal,
            .less,
            .less_equal,
            .greater,
            .greater_equal,
            .amp_amp,
            .pipe_pipe,
            .double_slash,
            .double_plus,
            .arrow,
            .question_mark,
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

    fn searchPathLit(self: *Parser) !*Node {
        return self.arena.createNode(.search_path, .{ .atom = .{
            .offset = self.previous.offset,
            .len = self.previous.len,
        } });
    }

    fn variable(self: *Parser) !*Node {
        const name_tok = self.previous;
        if (self.match(.at)) {
            _ = try self.expect(.left_brace, "Expected '{' after function argument binding.");
            return self.attrLambdaPattern(.{
                .offset = name_tok.offset,
                .len = name_tok.len,
            });
        }
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
        var operand = try self.parsePrecedence(.unary);
        if (is_not and self.match(.question_mark)) {
            operand = try self.hasAttr(operand);
        }
        return self.arena.createNode(.unary_op, .{ .unary = .{ .op = op, .expr = operand } });
    }

    fn braceExpr(self: *Parser) !*Node {
        if (self.looksLikeAttrLambdaPattern()) {
            return self.attrLambdaPattern(null);
        }
        return self.attrSetAfterLeftBrace(false);
    }

    fn recAttrSet(self: *Parser) !*Node {
        _ = try self.expect(.left_brace, "Expected '{' after rec.");
        return self.attrSetAfterLeftBrace(true);
    }

    fn looksLikeAttrLambdaPattern(self: *Parser) bool {
        var probe = self.*;
        probe.diagnostics = .empty;

        var depth: usize = 1;
        while (!probe.check(.eof)) {
            switch (probe.current.type) {
                .left_brace, .left_bracket, .left_paren, .dollar_curly => depth += 1,
                .right_brace, .right_bracket, .right_paren => {
                    depth -= 1;
                    if (depth == 0) {
                        probe.advance();
                        return probe.check(.colon) or probe.check(.at);
                    }
                },
                else => {},
            }
            probe.advance();
        }

        return false;
    }

    fn attrLambdaPattern(self: *Parser, bind_before: ?Node.Atom) !*Node {
        const arena_allocator = self.arena.allocator();
        var params: std.ArrayListUnmanaged(Node.LambdaAttrParam) = .empty;
        var allow_extra = false;

        if (!self.match(.right_brace)) {
            while (true) {
                if (self.match(.ellipsis)) {
                    allow_extra = true;
                    _ = try self.expect(.right_brace, "Expected '}' after '...'.");
                    break;
                }

                const name_tok = self.current;
                if (!self.matchAttrPatternName()) {
                    self.reportError("Expected function argument name.");
                    return error.ParseError;
                }
                const default = if (self.match(.question_mark))
                    try self.expression()
                else
                    null;
                try params.append(arena_allocator, .{
                    .name = .{
                        .offset = name_tok.offset,
                        .len = name_tok.len,
                    },
                    .default = default,
                });

                if (self.match(.right_brace)) break;
                _ = try self.expect(.comma, "Expected ',' or '}' in function argument set.");
                if (self.match(.right_brace)) break;
            }
        }

        const bind_name = bind_before orelse bind_after: {
            if (!self.match(.at)) break :bind_after null;
            const bind_tok = self.current;
            if (!self.matchAttrPatternName()) {
                self.reportError("Expected function argument binding name.");
                return error.ParseError;
            }
            break :bind_after Node.Atom{
                .offset = bind_tok.offset,
                .len = bind_tok.len,
            };
        };

        _ = try self.expect(.colon, "Expected ':' after function argument set.");
        const body = try self.expression();

        return self.arena.createNode(.lambda_attrs, .{
            .lambda_attrs = .{
                .bind_name = bind_name,
                .params = try params.toOwnedSlice(arena_allocator),
                .allow_extra = allow_extra,
                .body = body,
            },
        });
    }

    fn attrSetAfterLeftBrace(self: *Parser, recursive: bool) !*Node {
        const arena_allocator = self.arena.allocator();
        var entries: std.ArrayListUnmanaged(Node.AttrSetEntry) = .empty;

        while (!self.check(.right_brace) and !self.check(.eof)) {
            if (self.match(.kw_inherit)) {
                self.inheritAttrs(arena_allocator, &entries) catch {
                    self.synchronizeAttrSetEntry();
                    continue;
                };
                if (self.expect(.semicolon, "Expected ';' after inherit.")) |_| {} else |_| {
                    self.synchronizeAttrSetEntry();
                }
                continue;
            }

            const declaration = self.attrDeclaration(arena_allocator) catch {
                self.synchronizeAttrSetEntry();
                continue;
            };
            if (self.expect(.equal, "Expected '=' after attribute name.")) |_| {} else |_| {
                self.synchronizeAttrSetEntry();
                continue;
            }
            // allow missing semicolons by checking what comes next
            if (!self.check(.semicolon) and !self.check(.right_brace)) {
                _ = self.match(.semicolon); // optional
            }

            var expr = self.expression() catch {
                self.synchronizeAttrSetEntry();
                continue;
            };

            var path = declaration.path;
            var dynamic_name = declaration.dynamic_name;
            var tail_dynamic_name = declaration.tail_dynamic_name;
            if (declaration.dynamic_suffix) |suffix| {
                expr = try self.wrapAttrDeclarationExpr(arena_allocator, suffix.*, expr);
            }
            if (declaration.static_prefix_len) |prefix_len| {
                const nested_entries = try arena_allocator.alloc(Node.AttrSetEntry, 1);
                nested_entries[0] = .{
                    .path = declaration.path[prefix_len..],
                    .dynamic_name = dynamic_name,
                    .tail_dynamic_name = tail_dynamic_name,
                    .expr = expr,
                };
                expr = try self.arena.createNode(.attr_set, .{
                    .attr_set = .{
                        .entries = nested_entries,
                        .recursive = false,
                    },
                });
                path = declaration.path[0..prefix_len];
                dynamic_name = null;
                tail_dynamic_name = null;
            }

            try entries.append(arena_allocator, .{
                .path = path,
                .dynamic_name = dynamic_name,
                .tail_dynamic_name = tail_dynamic_name,
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

    fn wrapAttrDeclarationExpr(self: *Parser, allocator: std.mem.Allocator, declaration: AttrDeclaration, expr: *Node) !*Node {
        var wrapped_expr = expr;
        if (declaration.dynamic_suffix) |suffix| {
            wrapped_expr = try self.wrapAttrDeclarationExpr(allocator, suffix.*, wrapped_expr);
        }

        var path = declaration.path;
        var dynamic_name = declaration.dynamic_name;
        var tail_dynamic_name = declaration.tail_dynamic_name;
        if (declaration.static_prefix_len) |prefix_len| {
            const nested_entries = try allocator.alloc(Node.AttrSetEntry, 1);
            nested_entries[0] = .{
                .path = declaration.path[prefix_len..],
                .dynamic_name = dynamic_name,
                .tail_dynamic_name = tail_dynamic_name,
                .expr = wrapped_expr,
            };
            wrapped_expr = try self.arena.createNode(.attr_set, .{
                .attr_set = .{
                    .entries = nested_entries,
                    .recursive = false,
                },
            });
            path = declaration.path[0..prefix_len];
            dynamic_name = null;
            tail_dynamic_name = null;
        }

        const entries = try allocator.alloc(Node.AttrSetEntry, 1);
        entries[0] = .{
            .path = path,
            .dynamic_name = dynamic_name,
            .tail_dynamic_name = tail_dynamic_name,
            .expr = wrapped_expr,
        };
        return self.arena.createNode(.attr_set, .{
            .attr_set = .{
                .entries = entries,
                .recursive = false,
            },
        });
    }

    fn synchronizeAttrSetEntry(self: *Parser) void {
        while (!self.check(.semicolon) and !self.check(.right_brace) and !self.check(.eof)) {
            self.advance();
        }
        _ = self.match(.semicolon);
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
            const matched_name = if (source != null) self.matchAttrName() else self.matchLetBindingName();
            if (!matched_name) {
                self.reportError("Expected inherited variable name.");
                return error.ParseError;
            }

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
                .inherit_outer = source == null,
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
                .root = try ast.cloneNode(self.arena, source),
                .segments = segments,
            },
        });
    }

    fn attrDeclaration(self: *Parser, allocator: std.mem.Allocator) !AttrDeclaration {
        if (self.match(.dollar_curly)) {
            const name = try self.expression();
            _ = try self.expect(.right_brace, "Expected '}' after dynamic attribute name.");
            const path = try self.arena.allocSlice(Node.Atom, 0);
            if (self.match(.dot)) {
                const suffix = try allocator.create(AttrDeclaration);
                suffix.* = try self.attrDeclaration(allocator);
                return .{ .path = path, .dynamic_name = name, .dynamic_suffix = suffix };
            }
            return .{ .path = path, .dynamic_name = name };
        }

        return self.staticAttrDeclaration(allocator);
    }

    fn staticAttrDeclaration(self: *Parser, allocator: std.mem.Allocator) !AttrDeclaration {
        var segments: std.ArrayListUnmanaged(Node.Atom) = .empty;
        errdefer segments.deinit(allocator);

        while (true) {
            if (self.matchAttrName()) {
                try segments.append(allocator, .{
                    .offset = self.previous.offset,
                    .len = self.previous.len,
                });
            } else {
                self.reportError("Expected attribute name.");
                return error.ParseError;
            }

            if (!self.match(.dot)) break;
            if (!self.match(.dollar_curly)) continue;

            const dynamic_name = try self.expression();
            _ = try self.expect(.right_brace, "Expected '}' after dynamic attribute name.");
            const dynamic_path = try self.arena.allocSlice(Node.Atom, 0);
            const dynamic_declaration = try allocator.create(AttrDeclaration);
            dynamic_declaration.* = .{
                .path = dynamic_path,
                .dynamic_name = dynamic_name,
            };
            if (self.match(.dot)) {
                const suffix = try allocator.create(AttrDeclaration);
                suffix.* = try self.attrDeclaration(allocator);
                dynamic_declaration.dynamic_suffix = suffix;
            }

            return .{
                .path = try segments.toOwnedSlice(allocator),
                .dynamic_suffix = dynamic_declaration,
            };
        }

        return .{ .path = try segments.toOwnedSlice(allocator) };
    }

    fn attrDeclarationPath(self: *Parser, allocator: std.mem.Allocator) ![]Node.Atom {
        var segments: std.ArrayListUnmanaged(Node.Atom) = .empty;

        while (true) {
            if (self.matchAttrName()) {
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
            const item = try self.listItem();
            try items.append(arena_allocator, item);

            _ = self.match(.comma);
        }

        _ = try self.expect(.right_bracket, "Expected ']' after list.");

        return self.arena.createNode(.list, .{
            .list = .{ .items = try items.toOwnedSlice(arena_allocator) },
        });
    }

    fn listItem(self: *Parser) !*Node {
        if (isDisallowedListItemStart(self.current.type)) {
            self.reportError("Expected list item.");
            return error.ParseError;
        }

        var item = try self.parsePrecedenceWithApply(.primary, false);
        if (item.tag == .lambda) {
            self.reportError("Expected list separator or ']'.");
            return error.ParseError;
        }

        if (self.check(.kw_or)) {
            self.advance();
            item = try self.attrOr(item);
        }

        if (isDisallowedListItemContinuation(self.current.type)) {
            self.reportError("Expected list separator or ']'.");
            return error.ParseError;
        }

        return item;
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
            if (self.match(.kw_inherit)) {
                try self.inheritLetBindings(arena_allocator, &bindings);
                _ = try self.expect(.semicolon, "Expected ';' after inherit.");
                continue;
            }

            const path = try self.letBindingPath(arena_allocator);
            const first = path[0];
            _ = try self.expect(.equal, "Expected '=' after variable name.");
            const expr = try self.expression();
            _ = try self.expect(.semicolon, "Expected ';' after let binding.");

            try bindings.append(arena_allocator, .{
                .name_offset = first.offset,
                .name_len = first.len,
                .path = path,
                .expr = expr,
                .inherit_outer = false,
            });
        }

        _ = try self.expect(.kw_in, "Expected 'in' after let bindings.");
        const body = try self.expression();

        return self.arena.createNode(.let_in, .{
            .let_in = .{ .bindings = try bindings.toOwnedSlice(arena_allocator), .body = body },
        });
    }

    fn letBindingPath(self: *Parser, allocator: std.mem.Allocator) ![]Node.Atom {
        var path: std.ArrayListUnmanaged(Node.Atom) = .empty;
        errdefer path.deinit(allocator);

        const name_tok = self.current;
        if (!self.matchLetBindingName()) {
            self.reportError("Expected variable name in let binding.");
            return error.ParseError;
        }
        try path.append(allocator, .{
            .offset = name_tok.offset,
            .len = name_tok.len,
        });

        while (self.match(.dot)) {
            if (!self.matchAttrName()) {
                self.reportError("Expected attribute name.");
                return error.ParseError;
            }
            try path.append(allocator, .{
                .offset = self.previous.offset,
                .len = self.previous.len,
            });
        }

        return path.toOwnedSlice(allocator);
    }

    fn inheritLetBindings(
        self: *Parser,
        allocator: std.mem.Allocator,
        bindings: *std.ArrayListUnmanaged(Node.Binding),
    ) !void {
        const source: ?*Node = if (self.match(.left_paren)) source: {
            const expr = try self.expression();
            _ = try self.expect(.right_paren, "Expected ')' after inherit source.");
            break :source expr;
        } else null;

        var count: usize = 0;
        while (!self.check(.semicolon) and !self.check(.kw_in) and !self.check(.eof)) {
            const name_tok = self.current;
            if (!self.matchLetBindingName()) {
                self.reportError("Expected inherited variable name.");
                return error.ParseError;
            }

            const name = Node.Atom{
                .offset = name_tok.offset,
                .len = name_tok.len,
            };
            const expr = if (source) |src|
                try self.inheritSourceAttr(src, name)
            else
                try self.arena.createNode(.identifier, .{ .atom = name });

            try bindings.append(allocator, .{
                .name_offset = name.offset,
                .name_len = name.len,
                .path = try self.singleAtomPath(allocator, name),
                .expr = expr,
                .inherit_outer = source == null,
            });
            count += 1;
        }

        if (count == 0) {
            self.reportError("Expected inherited variable name.");
            return error.ParseError;
        }
    }

    fn singleAtomPath(self: *Parser, allocator: std.mem.Allocator, atom: Node.Atom) ![]Node.Atom {
        _ = self;
        const path = try allocator.alloc(Node.Atom, 1);
        path[0] = atom;
        return path;
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
        const right_prec: Precedence = if (self.previous.type == .arrow)
            r.prec
        else
            @enumFromInt(@intFromEnum(r.prec) + 1);
        const right = try self.parsePrecedence(right_prec);

        return self.makeBinary(op, left, right);
    }

    fn dotAccess(self: *Parser, left: *Node) !*Node {
        // `expr.attr` or `expr."string"` or `expr.${...}`
        const arena_allocator = self.arena.allocator();
        var current = left;
        var segments: std.ArrayListUnmanaged(Node.Atom) = .empty;

        while (true) {
            if (self.matchAttrName()) {
                try segments.append(arena_allocator, .{
                    .offset = self.previous.offset,
                    .len = self.previous.len,
                });
            } else if (self.match(.dollar_curly)) {
                if (segments.items.len > 0) {
                    current = try self.arena.createNode(.attr_path, .{
                        .attr_path = .{
                            .root = current,
                            .segments = try segments.toOwnedSlice(arena_allocator),
                        },
                    });
                    segments = .empty;
                }

                const name = try self.expression();
                _ = try self.expect(.right_brace, "Expected '}' after dynamic attribute name.");
                current = try self.arena.createNode(.attr_dynamic, .{
                    .attr_dynamic = .{
                        .root = current,
                        .name = name,
                    },
                });
            } else {
                break;
            }

            if (!self.match(.dot)) break;
        }

        if (segments.items.len == 0) return current;
        return self.arena.createNode(.attr_path, .{
            .attr_path = .{
                .root = current,
                .segments = try segments.toOwnedSlice(arena_allocator),
            },
        });
    }

    fn attrOr(self: *Parser, left: *Node) !*Node {
        if (left.tag == .apply and
            (left.data.apply.arg.tag == .attr_path or left.data.apply.arg.tag == .attr_dynamic))
        {
            const default = try self.selectionExpression();
            const defaulted_arg = try self.arena.createNode(.attr_or, .{
                .attr_or = .{ .attr_path = left.data.apply.arg, .default = default },
            });
            return self.arena.createNode(.apply, .{
                .apply = .{ .func = left.data.apply.func, .arg = defaulted_arg },
            });
        }

        if (left.tag != .attr_path and left.tag != .attr_dynamic) {
            self.reportError("'or' default requires an attribute path.");
            return error.ParseError;
        }
        const default = try self.selectionExpression();
        return self.arena.createNode(.attr_or, .{
            .attr_or = .{ .attr_path = left, .default = default },
        });
    }

    fn hasAttr(self: *Parser, left: *Node) !*Node {
        const arena_allocator = self.arena.allocator();
        var static_segments: std.ArrayListUnmanaged(Node.Atom) = .empty;
        var mixed_segments: std.ArrayListUnmanaged(Node.HasAttrMixedSegment) = .empty;
        var has_dynamic = false;

        while (true) {
            if (self.match(.dollar_curly)) {
                has_dynamic = true;
                const name = try self.expression();
                _ = try self.expect(.right_brace, "Expected '}' after dynamic attribute name.");
                try mixed_segments.append(arena_allocator, .{ .dynamic = name });
            } else if (self.matchAttrName()) {
                const atom = Node.Atom{
                    .offset = self.previous.offset,
                    .len = self.previous.len,
                };
                try static_segments.append(arena_allocator, atom);
                try mixed_segments.append(arena_allocator, .{ .static = atom });
            } else {
                self.reportError("Expected attribute name after '?'.");
                return error.ParseError;
            }

            if (!self.match(.dot)) break;
        }

        if (has_dynamic) {
            return self.arena.createNode(.has_attr_mixed, .{
                .has_attr_mixed = .{
                    .root = left,
                    .segments = try mixed_segments.toOwnedSlice(arena_allocator),
                },
            });
        }

        return self.arena.createNode(.has_attr, .{
            .has_attr = .{
                .root = left,
                .segments = try static_segments.toOwnedSlice(arena_allocator),
            },
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

    fn matchAttrName(self: *Parser) bool {
        return self.match(.identifier) or
            self.match(.string) or
            self.match(.kw_or) or
            self.match(.kw_true) or
            self.match(.kw_false) or
            self.match(.kw_null);
    }

    fn matchLetBindingName(self: *Parser) bool {
        return self.match(.identifier) or self.match(.kw_or);
    }

    fn matchAttrPatternName(self: *Parser) bool {
        return self.match(.identifier) or self.match(.kw_or);
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

test "parser treats implication as right associative" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "a -> b -> c");
    const node = try parser.parse();

    try std.testing.expectEqual(NodeTag.binary_op, node.tag);
    try std.testing.expectEqual(ast.BinaryOp.impl, node.data.binary.op);
    try std.testing.expectEqual(NodeTag.identifier, node.data.binary.left.tag);
    try std.testing.expectEqual(NodeTag.binary_op, node.data.binary.right.tag);
    try std.testing.expectEqual(ast.BinaryOp.impl, node.data.binary.right.data.binary.op);
}

test "parser gives implication lower precedence than boolean or" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "true || false -> false");
    const node = try parser.parse();

    try std.testing.expectEqual(NodeTag.binary_op, node.tag);
    try std.testing.expectEqual(ast.BinaryOp.impl, node.data.binary.op);
    try std.testing.expectEqual(NodeTag.binary_op, node.data.binary.left.tag);
    try std.testing.expectEqual(ast.BinaryOp.or_, node.data.binary.left.data.binary.op);
    try std.testing.expectEqual(NodeTag.bool_false, node.data.binary.right.tag);
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

test "parser recognizes attrset lambda" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "{ x, y }: x + y");
    const node = try parser.parse();

    try std.testing.expectEqual(NodeTag.lambda_attrs, node.tag);
    try std.testing.expectEqual(@as(usize, 2), node.data.lambda_attrs.params.len);
    try std.testing.expectEqual(NodeTag.binary_op, node.data.lambda_attrs.body.tag);
}

test "parser recognizes attrset lambda defaults ellipsis and binding" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "args@{ x ? 1, ... }: args.x");
    const node = try parser.parse();

    try std.testing.expectEqual(NodeTag.lambda_attrs, node.tag);
    try std.testing.expect(node.data.lambda_attrs.bind_name != null);
    try std.testing.expect(node.data.lambda_attrs.allow_extra);
    try std.testing.expectEqual(@as(usize, 1), node.data.lambda_attrs.params.len);
    try std.testing.expect(node.data.lambda_attrs.params[0].default != null);
}

test "parser recognizes attrset lambda defaults with dynamic attrs" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(
        std.testing.allocator,
        &arena,
        "{ x ? let table = { a = { b = 1; }; }; in table.${\"a\"}.b }: x",
    );
    const node = try parser.parse();

    try std.testing.expectEqual(NodeTag.lambda_attrs, node.tag);
    try std.testing.expect(node.data.lambda_attrs.params[0].default != null);
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

    var parser = Parser.init(std.testing.allocator, &arena, "{ inherit a or; }");
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
    try std.testing.expectEqualStrings("or", parser.span(.{
        .type = .kw_or,
        .offset = entries[1].path[0].offset,
        .len = entries[1].path[0].len,
        .line = 1,
    }));
    try std.testing.expectEqual(NodeTag.identifier, entries[1].expr.tag);
}

test "parser desugars inherit from source expression" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "{ inherit (src) a or; }");
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

test "parser recognizes contextual or attr names" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "{ or = 2; x.or = 3; }");
    const node = try parser.parse();

    try std.testing.expectEqual(NodeTag.attr_set, node.tag);
    const entries = node.data.attr_set.entries;
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("or", parser.span(.{
        .type = .kw_or,
        .offset = entries[0].path[0].offset,
        .len = entries[0].path[0].len,
        .line = 1,
    }));
    try std.testing.expectEqualStrings("or", parser.span(.{
        .type = .kw_or,
        .offset = entries[1].path[1].offset,
        .len = entries[1].path[1].len,
        .line = 1,
    }));
}

test "parser desugars inherit in let bindings" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "let inherit a; inherit (src) b; in a");
    defer parser.deinit();
    const node = try parser.parse();

    try std.testing.expectEqual(NodeTag.let_in, node.tag);
    const bindings = node.data.let_in.bindings;
    try std.testing.expectEqual(@as(usize, 2), bindings.len);
    try std.testing.expectEqualStrings("a", parser.span(.{
        .type = .identifier,
        .offset = bindings[0].name_offset,
        .len = bindings[0].name_len,
        .line = 1,
    }));
    try std.testing.expectEqual(NodeTag.identifier, bindings[0].expr.tag);
    try std.testing.expect(bindings[0].inherit_outer);
    try std.testing.expectEqualStrings("b", parser.span(.{
        .type = .identifier,
        .offset = bindings[1].name_offset,
        .len = bindings[1].name_len,
        .line = 1,
    }));
    try std.testing.expectEqual(NodeTag.attr_path, bindings[1].expr.tag);
    try std.testing.expectEqual(NodeTag.identifier, bindings[1].expr.data.attr_path.root.tag);
    try std.testing.expect(!bindings[1].inherit_outer);
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

test "parser gives attr defaults selection precedence" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "m.require or [ ] ++ m.imports or [ ]");
    const node = try parser.parse();

    try std.testing.expectEqual(NodeTag.binary_op, node.tag);
    try std.testing.expectEqual(ast.BinaryOp.concat, node.data.binary.op);
    try std.testing.expectEqual(NodeTag.attr_or, node.data.binary.left.tag);
    try std.testing.expectEqual(NodeTag.attr_or, node.data.binary.right.tag);
}

test "parser recognizes has-attr operator" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "{ a.b = 1; } ? a.b");
    const node = try parser.parse();

    try std.testing.expectEqual(NodeTag.has_attr, node.tag);
    try std.testing.expectEqual(@as(usize, 2), node.data.has_attr.segments.len);
}

test "parser recognizes mixed dynamic has-attr operator" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "{ a.b = 1; } ? a.${key}.c");
    const node = try parser.parse();

    try std.testing.expectEqual(NodeTag.has_attr_mixed, node.tag);
    try std.testing.expectEqual(@as(usize, 3), node.data.has_attr_mixed.segments.len);
}

test "parser rejects unparenthesized expression forms in lists" {
    const cases = [_][]const u8{
        "[ with { x = 1; }; x ]",
        "[ let x = 1; in x ]",
        "[ if true then 1 else 2 ]",
        "[ assert true; 1 ]",
        "[ ! true ]",
        "[ -1 ]",
        "[ x: x ]",
        "[ 1 + 2 ]",
    };

    for (cases) |source| {
        var arena = ast.AstArena.init(std.testing.allocator);
        defer arena.deinit();

        var parser = Parser.init(std.testing.allocator, &arena, source);
        defer parser.deinit();

        try std.testing.expectError(error.ParseError, parser.parse());
    }
}

test "parser accepts parenthesized expression forms in lists" {
    const cases = [_][]const u8{
        "[ (with { x = 1; }; x) ]",
        "[ (let x = 1; in x) ]",
        "[ (if true then 1 else 2) ]",
        "[ (assert true; 1) ]",
        "[ (! true) ]",
        "[ (-1) ]",
        "[ (x: x) ]",
        "[ (1 + 2) ]",
    };

    for (cases) |source| {
        var arena = ast.AstArena.init(std.testing.allocator);
        defer arena.deinit();

        var parser = Parser.init(std.testing.allocator, &arena, source);
        defer parser.deinit();

        _ = try parser.parse();
    }
}

test "parser records diagnostics without printing" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "$ $ 1");
    defer parser.deinit();

    try std.testing.expectError(error.ParseError, parser.parse());
    try std.testing.expectEqual(@as(usize, 2), parser.diagnostics.items.len);
    try std.testing.expectEqualStrings("Invalid token.", parser.diagnostics.items[0].message);
    try std.testing.expectEqual(@as(u32, 0), parser.diagnostics.items[0].offset);
    try std.testing.expectEqual(@as(u32, 1), parser.diagnostics.items[0].column);
    try std.testing.expectEqualStrings("Invalid token.", parser.diagnostics.items[1].message);
    try std.testing.expectEqual(@as(u32, 2), parser.diagnostics.items[1].offset);
    try std.testing.expectEqual(@as(u32, 3), parser.diagnostics.items[1].column);
}

test "parser recovers across attrset entries" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "{ if = 1; good = 2; inherit = 3; alsoGood = 4; }");
    defer parser.deinit();

    try std.testing.expectError(error.ParseError, parser.parse());
    try std.testing.expectEqual(@as(usize, 2), parser.diagnostics.items.len);
    try std.testing.expectEqualStrings("Expected attribute name.", parser.diagnostics.items[0].message);
    try std.testing.expectEqualStrings("Expected inherited variable name.", parser.diagnostics.items[1].message);
}
