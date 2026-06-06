const std = @import("std");
const ast = @import("../ast.zig");
const parser_mod = @import("../parser.zig");

const Node = ast.Node;
const Parser = parser_mod.Parser;
const Precedence = parser_mod.Precedence;

pub fn binary(self: *Parser, left: *Node) !*Node {
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

    const r = Parser.rule(self.previous.type);
    const right_prec: Precedence = if (self.previous.type == .arrow)
        r.prec
    else
        @enumFromInt(@intFromEnum(r.prec) + 1);
    const right = try self.parsePrecedence(right_prec);

    return self.makeBinary(op, left, right);
}

pub fn dotAccess(self: *Parser, left: *Node) !*Node {
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

pub fn attrOr(self: *Parser, left: *Node) !*Node {
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

pub fn hasAttr(self: *Parser, left: *Node) !*Node {
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
