const std = @import("std");
const expr = @import("expr");
const Engine = expr.Engine;
const value = @import("runtime").value;
const ValueType = value.ValueType;

test "end-to-end: simple arithmetic" {
    const alloc = std.testing.allocator;

    var ev = try Engine.init(alloc, .{ .worker_count = 0 });
    defer ev.deinit();

    const result = try ev.evaluate("10 + 32");
    try std.testing.expectEqual(@as(i64, 42), result.asInt());

    const spaced_sub = try ev.evaluate("let n = 0; in n - 1");
    try std.testing.expectEqual(@as(i64, -1), spaced_sub.asInt());

    try std.testing.expectError(error.TypeError, ev.evaluate("let f = x: x; in f -1"));

    const recursive_sub = try ev.evaluate("let f = n: if n == -1 then true else f (n - 1); in f 0");
    try std.testing.expect(recursive_sub.asBool());
}

test "end-to-end: float arithmetic" {
    const alloc = std.testing.allocator;

    var ev = try Engine.init(alloc, .{ .worker_count = 0 });
    defer ev.deinit();

    const add = try ev.evaluate("1.5 + 2.25");
    try std.testing.expectEqual(@as(f64, 3.75), add.asFloat());

    const mixed = try ev.evaluate("1 + 2.5");
    try std.testing.expectEqual(@as(f64, 3.5), mixed.asFloat());

    const nested = try ev.evaluate("(1.5 + 2) * 2");
    try std.testing.expectEqual(@as(f64, 7.0), nested.asFloat());

    const exponent = try ev.evaluate("5.0e-2 + 1.E+2");
    try std.testing.expectEqual(@as(f64, 100.05), exponent.asFloat());

    const runtime_add = try ev.evaluate("let x = 1.5; in x + 2");
    try std.testing.expectEqual(@as(f64, 3.5), runtime_add.asFloat());

    const runtime_div_left = try ev.evaluate("let x = 5.0; in x / 2");
    try std.testing.expectEqual(@as(f64, 2.5), runtime_div_left.asFloat());

    const runtime_div_right = try ev.evaluate("let x = 5; in x / 2.0");
    try std.testing.expectEqual(@as(f64, 2.5), runtime_div_right.asFloat());

    const mixed_eq = try ev.evaluate("1 == 1.0");
    try std.testing.expect(mixed_eq.asBool());

    const mixed_neq = try ev.evaluate("1 != 1.5");
    try std.testing.expect(mixed_neq.asBool());
}

test "end-to-end: string concatenation" {
    const alloc = std.testing.allocator;

    var ev = try Engine.init(alloc, .{ .worker_count = 0 });
    defer ev.deinit();

    const literal = try ev.evaluate("\"ab\" + \"cd\"");
    try std.testing.expectEqualStrings("abcd", ev.intern.get(literal.asInternId()));

    const bound = try ev.evaluate("let a = \"ab\"; in a + \"cd\"");
    try std.testing.expectEqualStrings("abcd", ev.intern.get(bound.asInternId()));

    try std.testing.expectError(error.TypeError, ev.evaluate("\"ab\" + 1"));
}

test "end-to-end: string concatenation coerces string-like attrs" {
    const alloc = std.testing.allocator;

    var ev = try Engine.init(alloc, .{ .worker_count = 0 });
    defer ev.deinit();

    const out_path = try ev.evaluate("{ outPath = \"/nix/store/source\"; } + \"/subdir\"");
    try std.testing.expectEqualStrings("/nix/store/source/subdir", ev.intern.get(out_path.asInternId()));

    const custom = try ev.evaluate("{ __toString = self: self.value; value = \"left\"; } + \"-right\"");
    try std.testing.expectEqualStrings("left-right", ev.intern.get(custom.asInternId()));
}

test "end-to-end: path concatenation follows Nix left-path semantics" {
    const alloc = std.testing.allocator;

    var ev = try Engine.init(alloc, .{ .worker_count = 0 });
    defer ev.deinit();

    const suffix = try ev.evaluate("./foo + \"x\"");
    try std.testing.expectEqual(value.ValueType.path, suffix.kind());
    try std.testing.expectEqualStrings("./foox", ev.intern.get(suffix.asInternId()));

    const paths = try ev.evaluate("./foo + ./bar");
    try std.testing.expectEqual(value.ValueType.path, paths.kind());
    try std.testing.expectEqualStrings("./foo./bar", ev.intern.get(paths.asInternId()));

    var ev_with_base = try Engine.init(alloc, .{ .worker_count = 0 });
    defer ev_with_base.deinit();
    try ev_with_base.setBasePathFromCurrentPath(std.testing.io);
    try std.testing.expectError(error.FileNotFound, ev_with_base.evaluate("\"x\" + ./missing-source-path"));
}

test "end-to-end: string interpolation" {
    const alloc = std.testing.allocator;

    var ev = try Engine.init(alloc, .{ .worker_count = 0 });
    defer ev.deinit();

    const literal = try ev.evaluate("\"a${\"b\"}c\"");
    try std.testing.expectEqualStrings("abc", ev.intern.get(literal.asInternId()));

    const bound = try ev.evaluate("let x = \"b\"; in \"a${x}c\"");
    try std.testing.expectEqualStrings("abc", ev.intern.get(bound.asInternId()));

    const inherit_source = try ev.evaluate(
        \\let cfg = { host = "127.0.0.1"; port = 5000; threads = 8; };
        \\in "${({ inherit (cfg) host port threads; }).host}"
    );
    try std.testing.expectEqualStrings("127.0.0.1", ev.intern.get(inherit_source.asInternId()));

    try std.testing.expectError(error.TypeError, ev.evaluate("\"a${1}c\""));
}

test "end-to-end: nested interpolation in strings" {
    const alloc = std.testing.allocator;

    var ev = try Engine.init(alloc, .{ .worker_count = 0 });
    defer ev.deinit();

    const literal_brace = try ev.evaluate("\"a${{ x = \"}\"; }.x}b\"");
    try std.testing.expectEqualStrings("a}b", ev.intern.get(literal_brace.asInternId()));

    const nested_attr = try ev.evaluate("\"a${{ x = { y = \"b\"; }; }.x.y}c\"");
    try std.testing.expectEqualStrings("abc", ev.intern.get(nested_attr.asInternId()));

    const escaped_interpolation = try ev.evaluate("let x = \"X\"; in \"a$${x}b\"");
    try std.testing.expectEqualStrings("a$${x}b", ev.intern.get(escaped_interpolation.asInternId()));

    const odd_dollar_run_interpolates = try ev.evaluate("let x = \"X\"; in \"a$$${x}b\"");
    try std.testing.expectEqualStrings("a$$Xb", ev.intern.get(odd_dollar_run_interpolates.asInternId()));

    const even_dollar_run_escapes = try ev.evaluate("let x = \"X\"; in \"a$$$${x}b\"");
    try std.testing.expectEqualStrings("a$$$${x}b", ev.intern.get(even_dollar_run_escapes.asInternId()));
}

test "end-to-end: indented strings" {
    const alloc = std.testing.allocator;

    var ev = try Engine.init(alloc, .{ .worker_count = 0 });
    defer ev.deinit();

    const plain = try ev.evaluate(
        \\''
        \\  a
        \\  b
        \\''
    );
    try std.testing.expectEqualStrings("a\nb\n", ev.intern.get(plain.asInternId()));

    const interpolated = try ev.evaluate(
        \\let x = "b"; in ''
        \\  a
        \\  ${x}
        \\  c
        \\''
    );
    try std.testing.expectEqualStrings("a\nb\nc\n", ev.intern.get(interpolated.asInternId()));

    const escaped = try ev.evaluate("'' ''${ ''' ''\\n ''");
    try std.testing.expectEqualStrings("${ '' \n", ev.intern.get(escaped.asInternId()));

    const escaped_interpolation = try ev.evaluate("let x = \"X\"; in ''a$${x}b''");
    try std.testing.expectEqualStrings("a$${x}b", ev.intern.get(escaped_interpolation.asInternId()));

    const odd_dollar_run_interpolates = try ev.evaluate("let x = \"X\"; in ''a$$${x}b''");
    try std.testing.expectEqualStrings("a$$Xb", ev.intern.get(odd_dollar_run_interpolates.asInternId()));

    const even_dollar_run_escapes = try ev.evaluate("let x = \"X\"; in ''a$$$${x}b''");
    try std.testing.expectEqualStrings("a$$$${x}b", ev.intern.get(even_dollar_run_escapes.asInternId()));
}

test "end-to-end: list elements are lazy" {
    const alloc = std.testing.allocator;

    var ev = try Engine.init(alloc, .{ .worker_count = 0 });
    defer ev.deinit();

    const result = try ev.evaluate("[ 1 (1 / 0) ]");
    try std.testing.expectEqual(value.ValueType.list, result.kind());
}

test "end-to-end: list concatenation" {
    const alloc = std.testing.allocator;

    var ev = try Engine.init(alloc, .{ .worker_count = 0 });
    defer ev.deinit();

    const combined = try ev.evaluate("[ 1 ] ++ [ 2 3 ] == [ 1 2 3 ]");
    try std.testing.expect(combined.asBool());

    const lazy = try ev.evaluate("[ (1 / 0) ] ++ []");
    try std.testing.expectEqual(value.ValueType.list, lazy.kind());

    try std.testing.expectError(error.TypeError, ev.evaluate("[ 1 ] ++ 2"));
}

test "end-to-end: if else false branch" {
    const alloc = std.testing.allocator;

    var ev = try Engine.init(alloc, .{ .worker_count = 0 });
    defer ev.deinit();

    const result = try ev.evaluate("if false then 1 else 2");
    try std.testing.expectEqual(@as(i64, 2), result.asInt());
}

test "end-to-end: boolean operators short-circuit" {
    const alloc = std.testing.allocator;

    var ev = try Engine.init(alloc, .{ .worker_count = 0 });
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

    var ev = try Engine.init(alloc, .{ .worker_count = 0 });
    defer ev.deinit();

    try std.testing.expectError(error.TypeError, ev.evaluate("if 1 then 2 else 3"));
    try std.testing.expectError(error.TypeError, ev.evaluate("!1"));
    try std.testing.expectError(error.TypeError, ev.evaluate("1 && true"));
    try std.testing.expectError(error.TypeError, ev.evaluate("0 || false"));
}

test "end-to-end: comparisons reject incompatible types" {
    const alloc = std.testing.allocator;

    var ev = try Engine.init(alloc, .{ .worker_count = 0 });
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

    var ev = try Engine.init(alloc, .{ .worker_count = 0 });
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

test "end-to-end: assert and implication" {
    const alloc = std.testing.allocator;

    var ev = try Engine.init(alloc, .{ .worker_count = 0 });
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
