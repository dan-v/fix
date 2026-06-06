const std = @import("std");
const ast = @import("../ast.zig");
const parser_mod = @import("../parser.zig");

const NodeTag = ast.NodeTag;
const Parser = parser_mod.Parser;

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
