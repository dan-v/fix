const std = @import("std");
const fix = @import("../../root.zig");
const Evaluator = fix.Evaluator;
const value = fix.value;
const ValueType = value.ValueType;

test "end-to-end: attrset update operator" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const added = try ev.evaluate("({ a = 1; } // { b = 2; }).b");
    try std.testing.expectEqual(@as(i64, 2), added.asInt());

    const overridden = try ev.evaluate("({ a = 1; b = 2; } // { b = 3; }).b");
    try std.testing.expectEqual(@as(i64, 3), overridden.asInt());

    const lazy = try ev.evaluate("({ a = 1 / 0; } // { a = 4; }).a");
    try std.testing.expectEqual(@as(i64, 4), lazy.asInt());

    try std.testing.expectError(error.TypeError, ev.evaluate("{ a = 1; } // 1"));
}

test "end-to-end: attr path or defaults" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const present = try ev.evaluate("({ a.b = 1; }).a.b or 2");
    try std.testing.expectEqual(@as(i64, 1), present.asInt());

    const missing_leaf = try ev.evaluate("({ a = {}; }).a.b or 2");
    try std.testing.expectEqual(@as(i64, 2), missing_leaf.asInt());

    const missing_mid = try ev.evaluate("({}).a.b or 2");
    try std.testing.expectEqual(@as(i64, 2), missing_mid.asInt());

    const dynamic_missing_mid = try ev.evaluate("let key = \"b\"; in ({}).a.${key} or 2");
    try std.testing.expectEqual(@as(i64, 2), dynamic_missing_mid.asInt());

    const dynamic_missing_mid_lazy = try ev.evaluate("let key = throw \"unused\"; in ({}).a.${key} or 2");
    try std.testing.expectEqual(@as(i64, 2), dynamic_missing_mid_lazy.asInt());

    const interpolated_present = try ev.evaluate("({ \"15\" = [ 1 2 ]; }.\"${\"15\"}\" or [ ])");
    try std.testing.expectEqual(@as(usize, 2), (try ev.heap.getList(interpolated_present.asObjectId())).len);

    const interpolated_concat = try ev.evaluate("[ 0 ] ++ ({ \"15\" = [ 1 2 ]; }.\"${\"15\"}\" or [ ])");
    try std.testing.expectEqual(@as(usize, 3), (try ev.heap.getList(interpolated_concat.asObjectId())).len);

    const interpolated_nested = try ev.evaluate("let key = \"b\"; in ({ a.b.c = 1; }).a.\"${key}\".c or 2");
    try std.testing.expectEqual(@as(i64, 1), interpolated_nested.asInt());

    const interpolated_missing_mid = try ev.evaluate("let key = \"b\"; in ({}).a.\"${key}\".c or 2");
    try std.testing.expectEqual(@as(i64, 2), interpolated_missing_mid.asInt());

    const concat_defaults = try ev.evaluate("let m = { require = [ 9 ]; }; in m.require or [ 1 ] ++ m.imports or [ 3 ]");
    try std.testing.expectEqual(@as(usize, 2), (try ev.heap.getList(concat_defaults.asObjectId())).len);

    const lazy_default = try ev.evaluate("({ a.b = 1; }).a.b or (1 / 0)");
    try std.testing.expectEqual(@as(i64, 1), lazy_default.asInt());

    const non_attr_mid = try ev.evaluate("({ a = 1; }).a.b or 2");
    try std.testing.expectEqual(@as(i64, 2), non_attr_mid.asInt());

    const non_attr_root = try ev.evaluate("(1).a or 2");
    try std.testing.expectEqual(@as(i64, 2), non_attr_root.asInt());

    try std.testing.expectError(error.DivisionByZero, ev.evaluate("({}).a.b or (1 / 0)"));
}

test "end-to-end: dynamic null attributes are omitted" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const present = try ev.evaluate("({ ${\"x\"} = 1; }).x");
    try std.testing.expectEqual(@as(i64, 1), present.asInt());

    const omitted = try ev.evaluate("builtins.attrNames { ${null} = 1; }");
    try std.testing.expectEqual(@as(usize, 0), (try ev.heap.getList(omitted.asObjectId())).len);

    try std.testing.expectError(error.TypeError, ev.evaluate("{ ${true} = 1; }"));
}

test "end-to-end: builtins.toFile returns store-like string" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const file_value = try ev.evaluate("builtins.toFile \"x\" \"hello\"");
    try std.testing.expectEqual(value.ValueType.string_context, file_value.discriminant);
    const string = try ev.heap.getContextString(file_value.asObjectId());
    const text = ev.intern.get(string.text);
    try std.testing.expectEqualStrings("/nix/store/4g4g9i669dl63abpww0djbl2jxl6bwiz-x", text);

    try std.testing.expectError(error.InvalidStorePathName, ev.evaluate("builtins.toFile \"x y\" \"hello\""));
    try std.testing.expectError(error.TypeError, ev.evaluate("builtins.toFile \"x\" 1"));
}

test "end-to-end: derivation preserves original attrs" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const drv = try ev.evaluate(
        "derivation { name = \"x\"; builder = { outPath = \"/nix/store/builder\"; }; system = \"x\"; src = { outPath = \"/nix/store/src\"; }; PATH = [ { outPath = \"/nix/store/bin\"; } ]; }",
    );
    try std.testing.expectEqual(value.ValueType.attrs, drv.discriminant);

    const user_hook = try ev.evaluate("(derivation { name = \"x\"; builder = \"b\"; system = \"s\"; userHook = null; }).userHook");
    try std.testing.expectEqual(value.ValueType.null, user_hook.discriminant);
}

test "end-to-end: core fetchurl import" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const fetched = try ev.evaluate(
        "import <nix/fetchurl.nix> { name = \"seed\"; url = \"https://example.com/seed\"; sha256 = \"sha256-000\"; }",
    );
    try std.testing.expectEqual(value.ValueType.attrs, fetched.discriminant);
}

test "end-to-end: with expressions" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const simple = try ev.evaluate("with { x = 40; y = 2; }; x + y");
    try std.testing.expectEqual(@as(i64, 42), simple.asInt());

    const lexical_shadow = try ev.evaluate("let x = 1; in with { x = 2; }; x");
    try std.testing.expectEqual(@as(i64, 1), lexical_shadow.asInt());

    const nested_shadow = try ev.evaluate("with { x = 1; }; with { x = 2; }; x");
    try std.testing.expectEqual(@as(i64, 2), nested_shadow.asInt());

    const outer_fallback = try ev.evaluate("with { x = 1; }; with { y = 2; }; x + y");
    try std.testing.expectEqual(@as(i64, 3), outer_fallback.asInt());

    const escaped_lambda = try ev.evaluate("let f = with { x = 41; }; y: x + y; in f 1");
    try std.testing.expectEqual(@as(i64, 42), escaped_lambda.asInt());

    const escaped_attr_thunk = try ev.evaluate("let a = with { x = 42; }; { y = x; }; in a.y");
    try std.testing.expectEqual(@as(i64, 42), escaped_attr_thunk.asInt());

    const lazy_unused_scope = try ev.evaluate("with (1 / 0); 42");
    try std.testing.expectEqual(@as(i64, 42), lazy_unused_scope.asInt());

    const lazy_unused_attr = try ev.evaluate("with { x = 42; y = 1 / 0; }; x");
    try std.testing.expectEqual(@as(i64, 42), lazy_unused_attr.asInt());

    const operand_position = try ev.evaluate("1 + (with { x = 2; }; x)");
    try std.testing.expectEqual(@as(i64, 3), operand_position.asInt());

    try std.testing.expectError(error.TypeError, ev.evaluate("with 1; x"));
}

test "end-to-end: duplicate attributes are rejected" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    try std.testing.expectError(error.DuplicateAttribute, ev.evaluate("{ a = 1; a = 2; }"));
    try std.testing.expectError(error.DuplicateAttribute, ev.evaluate("{ a = 1 / 0; a = 2; }"));
}

test "end-to-end: quoted attribute access" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const result = try ev.evaluate("({ foo = 42; }).\"foo\"");
    try std.testing.expectEqual(@as(i64, 42), result.asInt());
}

test "end-to-end: if else false branch" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const result = try ev.evaluate("if false then 1 else 2");
    try std.testing.expectEqual(@as(i64, 2), result.asInt());
}

test "end-to-end: boolean operators short-circuit" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const and_result = try ev.evaluate("true && false");
    try std.testing.expect(!and_result.asBool());

    const or_result = try ev.evaluate("false || true");
    try std.testing.expect(or_result.asBool());

    const short_and = try ev.evaluate("false && (1 / 0)");
    try std.testing.expect(!short_and.asBool());

    const short_or = try ev.evaluate("true || (1 / 0)");
    try std.testing.expect(short_or.asBool());
}

test "end-to-end: boolean contexts require booleans" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    try std.testing.expectError(error.TypeError, ev.evaluate("if 1 then 2 else 3"));
    try std.testing.expectError(error.TypeError, ev.evaluate("!1"));
    try std.testing.expectError(error.TypeError, ev.evaluate("1 && true"));
    try std.testing.expectError(error.TypeError, ev.evaluate("0 || false"));
}

test "end-to-end: comparisons reject incompatible types" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    try std.testing.expectError(error.TypeError, ev.evaluate("1 < true"));
    try std.testing.expectError(error.TypeError, ev.evaluate("\"a\" < 1"));
    try std.testing.expectError(error.TypeError, ev.evaluate("true < false"));

    const mixed_lt = try ev.evaluate("1 < 1.5");
    try std.testing.expect(mixed_lt.asBool());

    const mixed_gt = try ev.evaluate("2 > 1.5");
    try std.testing.expect(mixed_gt.asBool());
}

test "end-to-end: lists and attrs compare structurally" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const lists_equal = try ev.evaluate("[ 1 2 ] == [ 1 2 ]");
    try std.testing.expect(lists_equal.asBool());

    const lists_not_equal = try ev.evaluate("[ 1 2 ] == [ 1 3 ]");
    try std.testing.expect(!lists_not_equal.asBool());

    const attrs_equal = try ev.evaluate("{ b = 2; a = 1; } == { a = 1; b = 2; }");
    try std.testing.expect(attrs_equal.asBool());

    const attrs_not_equal = try ev.evaluate("{ a = 1; } == { a = 2; }");
    try std.testing.expect(!attrs_not_equal.asBool());

    const derivations_equal_by_out_path = try ev.evaluate(
        \\{
        \\  type = "derivation";
        \\  outPath = "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-a";
        \\  x = 1;
        \\} == {
        \\  type = "derivation";
        \\  outPath = "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-a";
        \\  x = 2;
        \\}
    );
    try std.testing.expect(derivations_equal_by_out_path.asBool());

    const derivations_not_equal_by_out_path = try ev.evaluate(
        \\{
        \\  type = "derivation";
        \\  outPath = "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-a";
        \\} == {
        \\  type = "derivation";
        \\  outPath = "/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-b";
        \\}
    );
    try std.testing.expect(!derivations_not_equal_by_out_path.asBool());

    const plain_out_path_attrs_stay_structural = try ev.evaluate(
        \\{
        \\  outPath = "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-a";
        \\  x = 1;
        \\} == {
        \\  outPath = "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-a";
        \\  x = 2;
        \\}
    );
    try std.testing.expect(!plain_out_path_attrs_stay_structural.asBool());

    const derivations_without_out_path_stay_structural = try ev.evaluate(
        \\{ type = "derivation"; x = 1; } == { type = "derivation"; x = 2; }
    );
    try std.testing.expect(!derivations_without_out_path_stay_structural.asBool());

    const same_lambda = try ev.evaluate("let f = x: x; in { inherit f; } == { inherit f; }");
    try std.testing.expect(same_lambda.asBool());

    const distinct_lambdas = try ev.evaluate("{ f = x: x; } == { f = x: x; }");
    try std.testing.expect(!distinct_lambdas.asBool());

    try std.testing.expectError(error.DivisionByZero, ev.evaluate("[ 1 (1 / 0) ] == [ 1 2 ]"));
    try std.testing.expectError(error.DivisionByZero, ev.evaluate("{ a = 1 / 0; } == { a = 1; }"));

    const recursive = try ev.evaluate("let x = rec { a = [ x ]; }; in x == x");
    try std.testing.expect(recursive.asBool());
}

test "end-to-end: single argument lambdas" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const direct = try ev.evaluate("(x: x + 1) 41");
    try std.testing.expectEqual(@as(i64, 42), direct.asInt());

    const bound = try ev.evaluate("let inc = x: x + 1; in inc 41");
    try std.testing.expectEqual(@as(i64, 42), bound.asInt());

    const shadowed = try ev.evaluate("(x: (x: x + 1) 41) 0");
    try std.testing.expectEqual(@as(i64, 42), shadowed.asInt());

    const precedence = try ev.evaluate("(x: x) 1 + 2");
    try std.testing.expectEqual(@as(i64, 3), precedence.asInt());

    const repeated_calls = try ev.evaluate("let f = x: x; in (f 1) + (f 2)");
    try std.testing.expectEqual(@as(i64, 3), repeated_calls.asInt());

    const captured = try ev.evaluate("let y = 1; in (x: x + y) 41");
    try std.testing.expectEqual(@as(i64, 42), captured.asInt());

    const functor = try ev.evaluate("let f = { base = 40; __functor = self: x: self.base + x; }; in f 2");
    try std.testing.expectEqual(@as(i64, 42), functor.asInt());

    const returned_functor = try ev.evaluate("let f = { __functor = self: x: x; }; g = { __functor = self: x: f; }; in g 0 42");
    try std.testing.expectEqual(@as(i64, 42), returned_functor.asInt());
}

test "end-to-end: tail calls reuse lambda frames" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const countdown = try ev.evaluate("let f = n: if n == 0 then 42 else f (n - 1); in f 1500");
    try std.testing.expectEqual(@as(i64, 42), countdown.asInt());
}

test "end-to-end: builtins.toString" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const int_string = try ev.evaluate("builtins.toString 42");
    try std.testing.expectEqualStrings("42", ev.intern.get(int_string.asInternId()));

    const bool_string = try ev.evaluate("builtins.toString true");
    try std.testing.expectEqualStrings("1", ev.intern.get(bool_string.asInternId()));

    const false_string = try ev.evaluate("builtins.toString false");
    try std.testing.expectEqualStrings("", ev.intern.get(false_string.asInternId()));

    const string_passthrough = try ev.evaluate("builtins.toString \"x\"");
    try std.testing.expectEqualStrings("x", ev.intern.get(string_passthrough.asInternId()));

    const shadowed = try ev.evaluate("let builtins = { toString = x: \"shadow\"; }; in builtins.toString 1");
    try std.testing.expectEqualStrings("shadow", ev.intern.get(shadowed.asInternId()));

    const list_string = try ev.evaluate("builtins.toString [ 1 \"a\" false null ]");
    try std.testing.expectEqualStrings("1 a  ", ev.intern.get(list_string.asInternId()));

    const attr_string = try ev.evaluate("builtins.toString { __toString = self: self.name; name = \"pkg\"; }");
    try std.testing.expectEqualStrings("pkg", ev.intern.get(attr_string.asInternId()));

    const out_path_string = try ev.evaluate("builtins.toString { outPath = \"/nix/store/example\"; }");
    try std.testing.expectEqualStrings("/nix/store/example", ev.intern.get(out_path_string.asInternId()));

    try std.testing.expectError(error.TypeError, ev.evaluate("builtins.toString {}"));
}

test "end-to-end: builtin type predicates" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    try std.testing.expect((try ev.evaluate("builtins.isAttrs {}")).asBool());
    try std.testing.expect(!(try ev.evaluate("builtins.isAttrs []")).asBool());

    try std.testing.expect((try ev.evaluate("builtins.isList [ 1 2 ]")).asBool());
    try std.testing.expect((try ev.evaluate("builtins.isString \"x\"")).asBool());
    try std.testing.expect((try ev.evaluate("builtins.isInt 1")).asBool());
    try std.testing.expect(!(try ev.evaluate("builtins.isInt 1.5")).asBool());
    try std.testing.expect((try ev.evaluate("builtins.isBool false")).asBool());
    try std.testing.expect((try ev.evaluate("builtins.isNull null")).asBool());
}

test "end-to-end: has-attr binds tighter than boolean not" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    try std.testing.expect(!(try ev.evaluate("!{ a = 1; } ? a")).asBool());
    try std.testing.expect((try ev.evaluate("!{ } ? a")).asBool());

    const applied = try ev.evaluate("let f = x: x; in !f { a = 1; } ? a");
    try std.testing.expect(!applied.asBool());
}

test "end-to-end: assert and implication" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const passed = try ev.evaluate("assert 1 < 2; 42");
    try std.testing.expectEqual(@as(i64, 42), passed.asInt());

    try std.testing.expectError(error.AssertionFailed, ev.evaluate("assert false; 42"));
    try std.testing.expectError(error.TypeError, ev.evaluate("assert 1; 42"));

    const vacuous = try ev.evaluate("false -> (1 / 0)");
    try std.testing.expect(vacuous.asBool());

    const true_case = try ev.evaluate("true -> 1 < 2");
    try std.testing.expect(true_case.asBool());

    const false_case = try ev.evaluate("true -> false");
    try std.testing.expect(!false_case.asBool());

    const right_assoc = try ev.evaluate("false -> false -> builtins.throw \"unreachable\"");
    try std.testing.expect(right_assoc.asBool());

    const implication_precedence = try ev.evaluate("true || false -> false");
    try std.testing.expect(!implication_precedence.asBool());

    const nixpkgs_shape = try ev.evaluate("let testing = false; stable = false; in testing -> !stable -> builtins.throw \"unreachable\"");
    try std.testing.expect(nixpkgs_shape.asBool());
}
