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

test "parser desugars |> to a forward-tagged application" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "x |> f");
    const node = try parser.parse();

    // `x |> f` == `f x`: func is the right operand, arg the left.
    try std.testing.expectEqual(NodeTag.apply, node.tag);
    try std.testing.expectEqual(ast.PipeSugar.forward, node.data.apply.pipe);
    try std.testing.expectEqual(NodeTag.identifier, node.data.apply.func.tag);
    try std.testing.expectEqualStrings("f", parser.source[node.data.apply.func.data.atom.offset..][0..node.data.apply.func.data.atom.len]);
    try std.testing.expectEqualStrings("x", parser.source[node.data.apply.arg.data.atom.offset..][0..node.data.apply.arg.data.atom.len]);
    try std.testing.expect(parser.used_pipe_operators);
    try std.testing.expect(parser.first_pipe_token != null);
}

test "parser desugars <| to a backward-tagged application" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "f <| x");
    const node = try parser.parse();

    // `f <| x` == `f x`: func is the left operand, arg the right.
    try std.testing.expectEqual(NodeTag.apply, node.tag);
    try std.testing.expectEqual(ast.PipeSugar.backward, node.data.apply.pipe);
    try std.testing.expectEqualStrings("f", parser.source[node.data.apply.func.data.atom.offset..][0..node.data.apply.func.data.atom.len]);
    try std.testing.expectEqualStrings("x", parser.source[node.data.apply.arg.data.atom.offset..][0..node.data.apply.arg.data.atom.len]);
    try std.testing.expect(parser.used_pipe_operators);
}

test "parser treats |> as left associative" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    // a |> b |> c  ==  c (b a)  ==  apply(func=c, arg=apply(func=b, arg=a))
    var parser = Parser.init(std.testing.allocator, &arena, "a |> b |> c");
    const node = try parser.parse();

    try std.testing.expectEqual(NodeTag.apply, node.tag);
    try std.testing.expectEqual(ast.PipeSugar.forward, node.data.apply.pipe);
    try std.testing.expectEqualStrings("c", parser.source[node.data.apply.func.data.atom.offset..][0..node.data.apply.func.data.atom.len]);
    // The outer application's argument is the inner `a |> b`.
    const inner = node.data.apply.arg;
    try std.testing.expectEqual(NodeTag.apply, inner.tag);
    try std.testing.expectEqual(ast.PipeSugar.forward, inner.data.apply.pipe);
    try std.testing.expectEqualStrings("b", parser.source[inner.data.apply.func.data.atom.offset..][0..inner.data.apply.func.data.atom.len]);
    try std.testing.expectEqualStrings("a", parser.source[inner.data.apply.arg.data.atom.offset..][0..inner.data.apply.arg.data.atom.len]);
}

test "parser treats <| as right associative" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    // a <| b <| c  ==  a (b c)  ==  apply(func=a, arg=apply(func=b, arg=c))
    var parser = Parser.init(std.testing.allocator, &arena, "a <| b <| c");
    const node = try parser.parse();

    try std.testing.expectEqual(NodeTag.apply, node.tag);
    try std.testing.expectEqual(ast.PipeSugar.backward, node.data.apply.pipe);
    try std.testing.expectEqualStrings("a", parser.source[node.data.apply.func.data.atom.offset..][0..node.data.apply.func.data.atom.len]);
    const inner = node.data.apply.arg;
    try std.testing.expectEqual(NodeTag.apply, inner.tag);
    try std.testing.expectEqual(ast.PipeSugar.backward, inner.data.apply.pipe);
    try std.testing.expectEqualStrings("b", parser.source[inner.data.apply.func.data.atom.offset..][0..inner.data.apply.func.data.atom.len]);
    try std.testing.expectEqualStrings("c", parser.source[inner.data.apply.arg.data.atom.offset..][0..inner.data.apply.arg.data.atom.len]);
}

test "parser gives |> lower precedence than ->" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    // a -> b |> c  ==  (a -> b) |> c : the arg is the whole implication.
    var parser = Parser.init(std.testing.allocator, &arena, "a -> b |> c");
    const node = try parser.parse();

    try std.testing.expectEqual(NodeTag.apply, node.tag);
    try std.testing.expectEqual(ast.PipeSugar.forward, node.data.apply.pipe);
    try std.testing.expectEqual(NodeTag.binary_op, node.data.apply.arg.tag);
    try std.testing.expectEqual(ast.BinaryOp.impl, node.data.apply.arg.data.binary.op);
}

test "parser gives function application higher precedence than |>" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    // f x |> g  ==  g (f x) : the arg is the plain application `f x`.
    var parser = Parser.init(std.testing.allocator, &arena, "f x |> g");
    const node = try parser.parse();

    try std.testing.expectEqual(NodeTag.apply, node.tag);
    try std.testing.expectEqual(ast.PipeSugar.forward, node.data.apply.pipe);
    const arg = node.data.apply.arg;
    try std.testing.expectEqual(NodeTag.apply, arg.tag);
    try std.testing.expectEqual(ast.PipeSugar.none, arg.data.apply.pipe);
}

test "parser keeps a parenthesized pipe as a single list item" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "[ (1 |> f) ]");
    const node = try parser.parse();

    try std.testing.expectEqual(NodeTag.list, node.tag);
    try std.testing.expectEqual(@as(usize, 1), node.data.list.items.len);
}

test "parser rejects a bare pipe operator inside a list" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "[ 1 |> f ]");
    defer parser.deinit(); // error path records a diagnostic; free it
    try std.testing.expectError(error.ParseError, parser.parse());
}

test "cloneNode preserves pipe provenance" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "x |> f");
    const node = try parser.parse();
    const copy = try ast.cloneNode(&arena, node);

    try std.testing.expectEqual(NodeTag.apply, copy.tag);
    try std.testing.expectEqual(ast.PipeSugar.forward, copy.data.apply.pipe);
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

// ---- prefix.zig / infix.zig targeted coverage ----
//
// Note on string interpolation: the scanner (see scanner.zig "recognizes nested
// strings in interpolation") flattens an entire interpolated string, including
// nested `${...}` and nested string literals, into a single `.string` token
// before the parser ever sees it. `prefix.stringLit` has exactly one code path
// (capture the token span as an atom) regardless of whether the source text
// contains interpolation. There is no separate prefix handler or branch for
// the interpolated case, so a parser-level "interpolation as prefix position"
// test would just re-exercise `stringLit` identically to a plain string test
// already implied above — skipped as redundant per the task guardrail.

test "parser disambiguates unary minus from binary minus" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "-1 - -2");
    const node = try parser.parse();

    try std.testing.expectEqual(NodeTag.binary_op, node.tag);
    try std.testing.expectEqual(ast.BinaryOp.sub, node.data.binary.op);

    try std.testing.expectEqual(NodeTag.unary_op, node.data.binary.left.tag);
    try std.testing.expectEqual(ast.UnaryOp.negate, node.data.binary.left.data.unary.op);
    try std.testing.expectEqual(NodeTag.integer, node.data.binary.left.data.unary.expr.tag);

    try std.testing.expectEqual(NodeTag.unary_op, node.data.binary.right.tag);
    try std.testing.expectEqual(ast.UnaryOp.negate, node.data.binary.right.data.unary.op);
    try std.testing.expectEqual(NodeTag.integer, node.data.binary.right.data.unary.expr.tag);
}

test "parser gives unary minus higher precedence than multiplication" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "-2 * 3");
    const node = try parser.parse();

    try std.testing.expectEqual(NodeTag.binary_op, node.tag);
    try std.testing.expectEqual(ast.BinaryOp.mul, node.data.binary.op);
    try std.testing.expectEqual(NodeTag.unary_op, node.data.binary.left.tag);
    try std.testing.expectEqual(ast.UnaryOp.negate, node.data.binary.left.data.unary.op);
    try std.testing.expectEqual(NodeTag.integer, node.data.binary.right.tag);
}

test "parser gives boolean not higher precedence than and/or" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "!true && false || !false");
    const node = try parser.parse();

    // (!true && false) || (!false)
    try std.testing.expectEqual(NodeTag.binary_op, node.tag);
    try std.testing.expectEqual(ast.BinaryOp.or_, node.data.binary.op);

    const lhs = node.data.binary.left;
    try std.testing.expectEqual(NodeTag.binary_op, lhs.tag);
    try std.testing.expectEqual(ast.BinaryOp.and_, lhs.data.binary.op);
    try std.testing.expectEqual(NodeTag.unary_op, lhs.data.binary.left.tag);
    try std.testing.expectEqual(ast.UnaryOp.not, lhs.data.binary.left.data.unary.op);

    const rhs = node.data.binary.right;
    try std.testing.expectEqual(NodeTag.unary_op, rhs.tag);
    try std.testing.expectEqual(ast.UnaryOp.not, rhs.data.unary.op);
}

test "parser combines boolean not with trailing has-attr operator" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "!x ? y");
    const node = try parser.parse();

    // `!` binds the has-attr test itself: not (x ? y)
    try std.testing.expectEqual(NodeTag.unary_op, node.tag);
    try std.testing.expectEqual(ast.UnaryOp.not, node.data.unary.op);
    try std.testing.expectEqual(NodeTag.has_attr, node.data.unary.expr.tag);
    try std.testing.expectEqual(@as(usize, 1), node.data.unary.expr.data.has_attr.segments.len);
}

test "parser parses with as a prefix keyword" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "with { x = 1; }; x");
    const node = try parser.parse();

    try std.testing.expectEqual(NodeTag.with_expr, node.tag);
    try std.testing.expectEqual(NodeTag.attr_set, node.data.with_expr.attr_set.tag);
    try std.testing.expectEqual(NodeTag.identifier, node.data.with_expr.body.tag);
}

test "parser parses assert as a prefix keyword" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "assert true; 1");
    const node = try parser.parse();

    try std.testing.expectEqual(NodeTag.assert, node.tag);
    try std.testing.expectEqual(NodeTag.bool_true, node.data.assert.cond.tag);
    try std.testing.expectEqual(NodeTag.integer, node.data.assert.body.tag);
}

test "parser parses rec as a prefix keyword producing a recursive attrset" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "rec { a = 1; b = a; }");
    const node = try parser.parse();

    try std.testing.expectEqual(NodeTag.attr_set, node.tag);
    try std.testing.expect(node.data.attr_set.recursive);
    try std.testing.expectEqual(@as(usize, 2), node.data.attr_set.entries.len);
}

test "parser parses let as a prefix keyword with multiple bindings" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "let a = 1; b = 2; in a + b");
    const node = try parser.parse();

    try std.testing.expectEqual(NodeTag.let_in, node.tag);
    try std.testing.expectEqual(@as(usize, 2), node.data.let_in.bindings.len);
    try std.testing.expectEqual(NodeTag.binary_op, node.data.let_in.body.tag);
}

test "parser parses deeply nested parenthesization" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "((((((((((1))))))))))");
    const node = try parser.parse();

    var current = node;
    var depth: usize = 0;
    while (current.tag == .parens) : (depth += 1) {
        current = current.data.parens;
    }

    try std.testing.expectEqual(@as(usize, 10), depth);
    try std.testing.expectEqual(NodeTag.integer, current.tag);
}

test "parser attaches or-default to attribute path produced by function application" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "f a.b or c");
    const node = try parser.parse();

    // `f (a.b or c)` — the `or` default rewraps the apply's argument.
    try std.testing.expectEqual(NodeTag.apply, node.tag);
    try std.testing.expectEqual(NodeTag.identifier, node.data.apply.func.tag);
    try std.testing.expectEqual(NodeTag.attr_or, node.data.apply.arg.tag);
    try std.testing.expectEqual(NodeTag.attr_path, node.data.apply.arg.data.attr_or.attr_path.tag);
    try std.testing.expectEqual(NodeTag.identifier, node.data.apply.arg.data.attr_or.default.tag);
}

test "parser rejects or-default on a non-attribute-path expression" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "1 or 2");
    defer parser.deinit();

    try std.testing.expectError(error.ParseError, parser.parse());
    try std.testing.expectEqual(@as(usize, 1), parser.diagnostics.items.len);
    try std.testing.expectEqualStrings("'or' default requires an attribute path.", parser.diagnostics.items[0].message);
}

test "parser reports missing binding name in attrset lambda pattern" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "{ x }@: x");
    defer parser.deinit();

    try std.testing.expectError(error.ParseError, parser.parse());
    try std.testing.expectEqual(@as(usize, 1), parser.diagnostics.items.len);
    try std.testing.expectEqualStrings(
        "Expected function argument binding name.",
        parser.diagnostics.items[0].message,
    );
}

test "parser reports missing inherit source variable name" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "{ inherit (src); }");
    defer parser.deinit();

    try std.testing.expectError(error.ParseError, parser.parse());
    try std.testing.expectEqual(@as(usize, 1), parser.diagnostics.items.len);
    try std.testing.expectEqualStrings(
        "Expected inherited variable name.",
        parser.diagnostics.items[0].message,
    );
}

test "parser reports missing variable name in let inherit" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "let inherit; in 1");
    defer parser.deinit();

    try std.testing.expectError(error.ParseError, parser.parse());
    try std.testing.expectEqual(@as(usize, 1), parser.diagnostics.items.len);
    try std.testing.expectEqualStrings(
        "Expected inherited variable name.",
        parser.diagnostics.items[0].message,
    );
}
