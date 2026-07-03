const std = @import("std");
const ast = @import("../ast.zig");
const parser_mod = @import("../parser.zig");
const infix = @import("infix.zig");

const AttrDeclaration = parser_mod.AttrDeclaration;
const Node = ast.Node;
const NodeTag = ast.NodeTag;
const Parser = parser_mod.Parser;
const Precedence = parser_mod.Precedence;
const TokenType = @import("../token.zig").TokenType;

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
        .pipe_forward,
        .pipe_backward,
        .double_slash,
        .double_plus,
        .arrow,
        .question_mark,
        => true,
        else => false,
    };
}

pub fn grouping(self: *Parser) !*Node {
    const expr = try self.expression();
    _ = try self.expect(.right_paren, "Expected ')' after expression.");
    return self.arena.createNode(.parens, .{ .parens = expr });
}

pub fn integer(self: *Parser) !*Node {
    return self.arena.createNode(.integer, .{ .atom = .{
        .offset = self.previous.offset,
        .len = self.previous.len,
    } });
}

pub fn floatLit(self: *Parser) !*Node {
    return self.arena.createNode(.float_val, .{ .atom = .{
        .offset = self.previous.offset,
        .len = self.previous.len,
    } });
}

pub fn stringLit(self: *Parser) !*Node {
    return self.arena.createNode(.string, .{ .atom = .{
        .offset = self.previous.offset,
        .len = self.previous.len,
    } });
}

pub fn pathLit(self: *Parser) !*Node {
    return self.arena.createNode(.path, .{ .atom = .{
        .offset = self.previous.offset,
        .len = self.previous.len,
    } });
}

pub fn searchPathLit(self: *Parser) !*Node {
    return self.arena.createNode(.search_path, .{ .atom = .{
        .offset = self.previous.offset,
        .len = self.previous.len,
    } });
}

pub fn variable(self: *Parser) !*Node {
    const name_tok = self.previous;
    if (self.match(.at)) {
        _ = try self.expect(.left_brace, "Expected '{' after function argument binding.");
        return attrLambdaPattern(self, .{
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

pub fn literal(self: *Parser) !*Node {
    const tag: NodeTag = switch (self.previous.type) {
        .kw_true => .bool_true,
        .kw_false => .bool_false,
        .kw_null => .null,
        else => unreachable,
    };
    return self.arena.createNode(tag, .{ .atom = .{ .offset = 0, .len = 0 } });
}

pub fn unary(self: *Parser) !*Node {
    const is_not = self.previous.type == .bang;
    const op: ast.UnaryOp = if (is_not) .not else .negate;
    var operand = try self.parsePrecedence(.unary);
    if (is_not and self.match(.question_mark)) {
        operand = try infix.hasAttr(self, operand);
    }
    return self.arena.createNode(.unary_op, .{ .unary = .{ .op = op, .expr = operand } });
}

pub fn braceExpr(self: *Parser) !*Node {
    if (looksLikeAttrLambdaPattern(self)) {
        return attrLambdaPattern(self, null);
    }
    return attrSetAfterLeftBrace(self, false);
}

pub fn recAttrSet(self: *Parser) !*Node {
    _ = try self.expect(.left_brace, "Expected '{' after rec.");
    return attrSetAfterLeftBrace(self, true);
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
            inheritAttrs(self, arena_allocator, &entries) catch {
                synchronizeAttrSetEntry(self);
                continue;
            };
            if (self.expect(.semicolon, "Expected ';' after inherit.")) |_| {} else |_| {
                synchronizeAttrSetEntry(self);
            }
            continue;
        }

        const declaration = attrDeclaration(self, arena_allocator) catch {
            synchronizeAttrSetEntry(self);
            continue;
        };
        if (self.expect(.equal, "Expected '=' after attribute name.")) |_| {} else |_| {
            synchronizeAttrSetEntry(self);
            continue;
        }
        // allow missing semicolons by checking what comes next
        if (!self.check(.semicolon) and !self.check(.right_brace)) {
            _ = self.match(.semicolon); // optional
        }

        var expr = self.expression() catch {
            synchronizeAttrSetEntry(self);
            continue;
        };

        var path = declaration.path;
        var dynamic_name = declaration.dynamic_name;
        if (declaration.dynamic_suffix) |suffix| {
            expr = try wrapAttrDeclarationExpr(self, arena_allocator, suffix.*, expr);
        }
        if (declaration.static_prefix_len) |prefix_len| {
            const nested_entries = try arena_allocator.alloc(Node.AttrSetEntry, 1);
            nested_entries[0] = .{
                .path = declaration.path[prefix_len..],
                .dynamic_name = dynamic_name,
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
        }

        try entries.append(arena_allocator, .{
            .path = path,
            .dynamic_name = dynamic_name,
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
        wrapped_expr = try wrapAttrDeclarationExpr(self, allocator, suffix.*, wrapped_expr);
    }

    var path = declaration.path;
    var dynamic_name = declaration.dynamic_name;
    if (declaration.static_prefix_len) |prefix_len| {
        const nested_entries = try allocator.alloc(Node.AttrSetEntry, 1);
        nested_entries[0] = .{
            .path = declaration.path[prefix_len..],
            .dynamic_name = dynamic_name,
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
    }

    const entries = try allocator.alloc(Node.AttrSetEntry, 1);
    entries[0] = .{
        .path = path,
        .dynamic_name = dynamic_name,
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
            try inheritSourceAttr(self, src, path[0])
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
            suffix.* = try attrDeclaration(self, allocator);
            return .{ .path = path, .dynamic_name = name, .dynamic_suffix = suffix };
        }
        return .{ .path = path, .dynamic_name = name };
    }

    return staticAttrDeclaration(self, allocator);
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
            suffix.* = try attrDeclaration(self, allocator);
            dynamic_declaration.dynamic_suffix = suffix;
        }

        return .{
            .path = try segments.toOwnedSlice(allocator),
            .dynamic_suffix = dynamic_declaration,
        };
    }

    return .{ .path = try segments.toOwnedSlice(allocator) };
}

pub fn list(self: *Parser) !*Node {
    const arena_allocator = self.arena.allocator();
    var items: std.ArrayListUnmanaged(*Node) = .empty;

    while (!self.check(.right_bracket) and !self.check(.eof)) {
        const item = try listItem(self);
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
        item = try infix.attrOr(self, item);
    }

    if (isDisallowedListItemContinuation(self.current.type)) {
        self.reportError("Expected list separator or ']'.");
        return error.ParseError;
    }

    return item;
}

pub fn ifElse(self: *Parser) !*Node {
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

pub fn assert_(self: *Parser) !*Node {
    const cond = try self.expression();
    _ = try self.expect(.semicolon, "Expected ';' after assert condition.");
    const body = try self.expression();

    return self.arena.createNode(.assert, .{
        .assert = .{ .cond = cond, .body = body },
    });
}

pub fn with_(self: *Parser) !*Node {
    const with_expr = try self.expression();
    _ = try self.expect(.semicolon, "Expected ';' after with expression.");
    const body = try self.expression();

    return self.arena.createNode(.with_expr, .{
        .with_expr = .{ .attr_set = with_expr, .body = body },
    });
}

pub fn letIn(self: *Parser) !*Node {
    const arena_allocator = self.arena.allocator();
    var bindings: std.ArrayListUnmanaged(Node.Binding) = .empty;

    while (!self.check(.kw_in) and !self.check(.eof)) {
        if (self.match(.kw_inherit)) {
            try inheritLetBindings(self, arena_allocator, &bindings);
            _ = try self.expect(.semicolon, "Expected ';' after inherit.");
            continue;
        }

        const path = try letBindingPath(self, arena_allocator);
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
            try inheritSourceAttr(self, src, name)
        else
            try self.arena.createNode(.identifier, .{ .atom = name });

        try bindings.append(allocator, .{
            .name_offset = name.offset,
            .name_len = name.len,
            .path = try singleAtomPath(self, allocator, name),
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
