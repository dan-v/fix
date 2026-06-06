const std = @import("std");
const fix = @import("../../root.zig");
const Evaluator = fix.Evaluator;
const value = fix.value;
const ValueType = value.ValueType;

test "end-to-end: simple arithmetic" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
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

    var ev = try Evaluator.init(alloc, 0);
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

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const literal = try ev.evaluate("\"ab\" + \"cd\"");
    try std.testing.expectEqualStrings("abcd", ev.intern.get(literal.asInternId()));

    const bound = try ev.evaluate("let a = \"ab\"; in a + \"cd\"");
    try std.testing.expectEqualStrings("abcd", ev.intern.get(bound.asInternId()));

    try std.testing.expectError(error.TypeError, ev.evaluate("\"ab\" + 1"));
}

test "end-to-end: string concatenation coerces string-like attrs" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const out_path = try ev.evaluate("{ outPath = \"/nix/store/source\"; } + \"/subdir\"");
    try std.testing.expectEqualStrings("/nix/store/source/subdir", ev.intern.get(out_path.asInternId()));

    const custom = try ev.evaluate("{ __toString = self: self.value; value = \"left\"; } + \"-right\"");
    try std.testing.expectEqualStrings("left-right", ev.intern.get(custom.asInternId()));
}

test "end-to-end: path concatenation follows Nix left-path semantics" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const suffix = try ev.evaluate("./foo + \"x\"");
    try std.testing.expectEqual(value.ValueType.path, suffix.discriminant);
    try std.testing.expectEqualStrings("./foox", ev.intern.get(suffix.asInternId()));

    const paths = try ev.evaluate("./foo + ./bar");
    try std.testing.expectEqual(value.ValueType.path, paths.discriminant);
    try std.testing.expectEqualStrings("./foo./bar", ev.intern.get(paths.asInternId()));

    var ev_with_base = try Evaluator.init(alloc, 0);
    defer ev_with_base.deinit();
    try ev_with_base.setBasePathFromCurrentPath(std.testing.io);
    try std.testing.expectError(error.FileNotFound, ev_with_base.evaluate("\"x\" + ./missing-source-path"));
}

test "end-to-end: string interpolation" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
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

    var ev = try Evaluator.init(alloc, 0);
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

    var ev = try Evaluator.init(alloc, 0);
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

test "end-to-end: ambient builtins" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const first = try ev.evaluate("builtins.elemAt (map (x: x + 1) [ 1 2 ]) 0");
    try std.testing.expectEqual(@as(i64, 2), first.asInt());

    const shadowed = try ev.evaluate("let map = 7; in map");
    try std.testing.expectEqual(@as(i64, 7), shadowed.asInt());

    const fetchurl_shadowed = try ev.evaluate("with { fetchurl = \"pkg\"; }; fetchurl");
    try std.testing.expectEqualStrings("pkg", ev.intern.get(fetchurl_shadowed.asInternId()));

    try std.testing.expectError(error.UndefinedVariable, ev.evaluate("all"));
    try std.testing.expectError(error.UndefinedVariable, ev.evaluate("elem"));

    const all_from_with = try ev.evaluate("with { all = [ 1 ]; }; builtins.typeOf all");
    try std.testing.expectEqualStrings("list", ev.intern.get(all_from_with.asInternId()));

    const inner_with_shadows_outer_with = try ev.evaluate(
        "let outer = { all = x: x; platforms = { all = [ 1 ]; }; }; in with outer; with platforms; builtins.typeOf all",
    );
    try std.testing.expectEqualStrings("list", ev.intern.get(inner_with_shadows_outer_with.asInternId()));

    const version = try ev.evaluate("nixVersion");
    try std.testing.expectEqual(value.ValueType.string, version.discriminant);

    const missing_env = try ev.evaluate("builtins.getEnv \"FIX_TEST_UNSET\"");
    try std.testing.expectEqualStrings("", ev.intern.get(missing_env.asInternId()));

    const context = try ev.evaluate("builtins.hasContext \"x\"");
    try std.testing.expect(!context.asBool());
}

test "end-to-end: inherit quoted attribute from source" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const result = try ev.evaluate("let x = { \"or\" = 1; }; in { inherit (x) \"or\"; }.\"or\"");
    try std.testing.expectEqual(@as(i64, 1), result.asInt());
}

test "end-to-end: dynamic attribute selection" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const result = try ev.evaluate("let digits = { \"10\" = \"A\"; }; d = 10; in digits.${builtins.toString d}");
    try std.testing.expectEqualStrings("A", ev.intern.get(result.asInternId()));

    const declared = try ev.evaluate("let key = \"x\"; in ({ ${key} = 4; }).x");
    try std.testing.expectEqual(@as(i64, 4), declared.asInt());

    const declared_quoted = try ev.evaluate("let key = \"x\"; in ({ \"${key}Suffix\" = 4; }).xSuffix");
    try std.testing.expectEqual(@as(i64, 4), declared_quoted.asInt());

    const defaulted = try ev.evaluate("let key = \"missing\"; attrs = {}; in attrs.${key} or 9");
    try std.testing.expectEqual(@as(i64, 9), defaulted.asInt());

    const defaulted_missing_prefix = try ev.evaluate("let key = \"missing\"; attrs = {}; in attrs.prefix.${key} or 9");
    try std.testing.expectEqual(@as(i64, 9), defaulted_missing_prefix.asInt());

    const defaulted_arg = try ev.evaluate("let v = x: x; final = {}; in v final.gcc.arch or \"default\"");
    try std.testing.expectEqualStrings("default", ev.intern.get(defaulted_arg.asInternId()));

    const has_dynamic = try ev.evaluate("let key = \"x\"; in { x = 1; } ? ${key}");
    try std.testing.expect(has_dynamic.asBool());

    const has_dynamic_tail = try ev.evaluate("let key = \"b\"; in { a.b = 1; } ? a.${key}");
    try std.testing.expect(has_dynamic_tail.asBool());

    const has_dynamic_head = try ev.evaluate("let key = \"a\"; in { a.b = 1; } ? ${key}.b");
    try std.testing.expect(has_dynamic_head.asBool());

    const has_dynamic_missing_prefix = try ev.evaluate("let key = throw \"unused\"; in {} ? a.${key}");
    try std.testing.expect(!has_dynamic_missing_prefix.asBool());

    const has_interpolated_string = try ev.evaluate("let key = \"x\"; in { x = 1; } ? \"${key}\"");
    try std.testing.expect(has_interpolated_string.asBool());

    const quoted_interpolation = try ev.evaluate("let key = \"x\"; in { x = 1; }.\"${key}\"");
    try std.testing.expectEqual(@as(i64, 1), quoted_interpolation.asInt());
}

test "end-to-end: let binding" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const result = try ev.evaluate("let x = 10; y = 32; in x + y");
    try std.testing.expectEqual(@as(i64, 42), result.asInt());

    const right_operand = try ev.evaluate("1 + (let x = 2; in x)");
    try std.testing.expectEqual(@as(i64, 3), right_operand.asInt());

    const left_operand = try ev.evaluate("(let x = 2; in x) + 1");
    try std.testing.expectEqual(@as(i64, 3), left_operand.asInt());

    const attr_path = try ev.evaluate("let a.b = 1; in a.b");
    try std.testing.expectEqual(@as(i64, 1), attr_path.asInt());

    const nested_attr_path = try ev.evaluate("let a.b.c = 2; in a.b.c");
    try std.testing.expectEqual(@as(i64, 2), nested_attr_path.asInt());

    const recursive_attr_path = try ev.evaluate("let a.b = a.c; a.c = 3; in a.b");
    try std.testing.expectEqual(@as(i64, 3), recursive_attr_path.asInt());

    const extended_attr_path = try ev.evaluate("let a.b = { c = 1; }; a.b.d = 2; in a.b.d");
    try std.testing.expectEqual(@as(i64, 2), extended_attr_path.asInt());
}

test "end-to-end: duplicate let bindings are rejected" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    try std.testing.expectError(error.DuplicateBinding, ev.evaluate("let x = 1; x = 2; in x"));
    try std.testing.expectError(error.DuplicateBinding, ev.evaluate("let x = 1; inherit x; in x"));
    try std.testing.expectError(error.DuplicateBinding, ev.evaluate("let inherit ({ x = 1; }) x; x = 2; in x"));
    try std.testing.expectError(error.DuplicateBinding, ev.evaluate("let or = 1; inherit ({ or = 2; }) or; in ({ inherit or; }).or"));
    try std.testing.expectError(error.DuplicateAttribute, ev.evaluate("let a = 1; a.b = 2; in a"));
    try std.testing.expectError(error.DuplicateAttribute, ev.evaluate("let a.b = 1; a.b.c = 2; in a.b"));
}

test "end-to-end: undefined variables are rejected with source diagnostics" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    try std.testing.expectError(error.UndefinedVariable, ev.evaluate("x"));
    try std.testing.expectEqual(@as(usize, 1), ev.getDiagnostics().len);
    try std.testing.expectEqualStrings("undefined variable 'x'", ev.getDiagnostics()[0].message);
    try std.testing.expectEqual(@as(u32, 0), ev.getDiagnostics()[0].offset);

    try std.testing.expectError(error.UndefinedVariable, ev.evaluate("{ inherit x; }"));
    try std.testing.expectEqual(@as(usize, 1), ev.getDiagnostics().len);
    try std.testing.expectEqualStrings("undefined variable 'x'", ev.getDiagnostics()[0].message);
    try std.testing.expectEqual(@as(u32, 10), ev.getDiagnostics()[0].offset);
}

test "end-to-end: let forward references" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const result = try ev.evaluate("let a = b + 1; b = 3; in a + b");
    try std.testing.expectEqual(@as(i64, 7), result.asInt());
}

test "end-to-end: unused let binding is not evaluated" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const result = try ev.evaluate("let x = 1 / 0; in 42");
    try std.testing.expectEqual(@as(i64, 42), result.asInt());
}

test "end-to-end: recursive let binding errors" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    try std.testing.expectError(error.RecursiveThunk, ev.evaluate("let a = a; in a"));
    try std.testing.expectError(error.RecursiveThunk, ev.evaluate("let a = b; b = a; in a"));
}

test "end-to-end: guarded recursive let bindings can terminate" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const true_guard = try ev.evaluate("let a = if true then 1 else b; b = a + 1; in b");
    try std.testing.expectEqual(@as(i64, 2), true_guard.asInt());

    const false_guard = try ev.evaluate("let a = if false then b else 1; b = a + 1; in b");
    try std.testing.expectEqual(@as(i64, 2), false_guard.asInt());
}

test "end-to-end: function arguments are lazy" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const unused_arg = try ev.evaluate("let f = x: 1; a = f b; b = a + 1; in b");
    try std.testing.expectEqual(@as(i64, 2), unused_arg.asInt());

    const guarded_arg = try ev.evaluate("let f = x: if true then 1 else x; a = f b; b = a + 1; in b");
    try std.testing.expectEqual(@as(i64, 2), guarded_arg.asInt());

    const used_arg = try ev.evaluate("let f = x: x + 1; a = f b; b = 3; in a");
    try std.testing.expectEqual(@as(i64, 4), used_arg.asInt());

    try std.testing.expectError(
        error.RecursiveThunk,
        ev.evaluate("let f = x: x + 1; a = f b; b = a + 1; in a"),
    );
}

test "end-to-end: attribute set" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const result = try ev.evaluate("{ a = 1; b = 2; }");
    try std.testing.expectEqual(value.ValueType.attrs, result.discriminant);
}

test "end-to-end: simple inherit in attrsets" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const inherited = try ev.evaluate("let x = 1; y = 2; in ({ inherit x y; }).y");
    try std.testing.expectEqual(@as(i64, 2), inherited.asInt());

    const recursive = try ev.evaluate("let a = { inherit a; }; in a");
    try std.testing.expectEqual(value.ValueType.attrs, recursive.discriminant);

    const nested = try ev.evaluate("(let a = { inherit a; }; in a).a.a");
    try std.testing.expectEqual(value.ValueType.attrs, nested.discriminant);

    const recursive_inherit = try ev.evaluate("let config = 1; in (rec { inherit config; }).config");
    try std.testing.expectEqual(@as(i64, 1), recursive_inherit.asInt());

    try std.testing.expectError(error.DuplicateAttribute, ev.evaluate("rec { x = 1; inherit x; }"));
}

test "end-to-end: inherit from source expression" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const inherited = try ev.evaluate("let src = { x = 7; y = 8; }; in ({ inherit (src) x y; }).x");
    try std.testing.expectEqual(@as(i64, 7), inherited.asInt());

    const literal_source = try ev.evaluate("({ inherit ({ x = 1; }) x; }).x");
    try std.testing.expectEqual(@as(i64, 1), literal_source.asInt());

    const lazy = try ev.evaluate("let src = 1 / 0; in { inherit (src) x; }");
    try std.testing.expectEqual(value.ValueType.attrs, lazy.discriminant);
}

test "end-to-end: inherit in let bindings" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const outer = try ev.evaluate("let x = 1; in let inherit x; in x");
    try std.testing.expectEqual(@as(i64, 1), outer.asInt());

    const sourced = try ev.evaluate("let inherit ({ x = 2; }) x; in x");
    try std.testing.expectEqual(@as(i64, 2), sourced.asInt());

    const contextual_or = try ev.evaluate("let inherit ({ or = 4; }) or; in ({ inherit or; }).or");
    try std.testing.expectEqual(@as(i64, 4), contextual_or.asInt());

    const lazy_source = try ev.evaluate("let src = 1 / 0; inherit (src) x; in { inherit x; }");
    try std.testing.expectEqual(value.ValueType.attrs, lazy_source.discriminant);
}

test "end-to-end: or is contextual in attr names" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const direct = try ev.evaluate("({ or = 2; }).or");
    try std.testing.expectEqual(@as(i64, 2), direct.asInt());

    const nested = try ev.evaluate("({ x.or = 3; }).x.or");
    try std.testing.expectEqual(@as(i64, 3), nested.asInt());

    const inherited = try ev.evaluate("let or = 4; in ({ inherit or; }).or");
    try std.testing.expectEqual(@as(i64, 4), inherited.asInt());

    const inherited_from = try ev.evaluate("({ inherit ({ or = 5; }) or; }).or");
    try std.testing.expectEqual(@as(i64, 5), inherited_from.asInt());

    const attr_or = try ev.evaluate("({ x.or = 6; }).x.or or 9");
    try std.testing.expectEqual(@as(i64, 6), attr_or.asInt());
}

test "end-to-end: list elements are lazy" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const result = try ev.evaluate("[ 1 (1 / 0) ]");
    try std.testing.expectEqual(value.ValueType.list, result.discriminant);
}

test "end-to-end: list concatenation" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const combined = try ev.evaluate("[ 1 ] ++ [ 2 3 ] == [ 1 2 3 ]");
    try std.testing.expect(combined.asBool());

    const lazy = try ev.evaluate("[ (1 / 0) ] ++ []");
    try std.testing.expectEqual(value.ValueType.list, lazy.discriminant);

    try std.testing.expectError(error.TypeError, ev.evaluate("[ 1 ] ++ 2"));
}

test "end-to-end: attribute access" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const result = try ev.evaluate("({ a = 42; }).a");
    try std.testing.expectEqual(@as(i64, 42), result.asInt());
}

test "end-to-end: unused attribute values are lazy" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const result = try ev.evaluate("({ a = 42; b = 1 / 0; }).a");
    try std.testing.expectEqual(@as(i64, 42), result.asInt());

    try std.testing.expectError(error.DivisionByZero, ev.evaluate("({ a = 1 / 0; }).a"));
}

test "end-to-end: recursive attribute sets" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const forward = try ev.evaluate("(rec { a = b + 1; b = 3; }).a");
    try std.testing.expectEqual(@as(i64, 4), forward.asInt());

    const guarded = try ev.evaluate("(rec { a = if true then 1 else b; b = a + 1; }).b");
    try std.testing.expectEqual(@as(i64, 2), guarded.asInt());

    try std.testing.expectError(error.RecursiveThunk, ev.evaluate("(rec { a = a; }).a"));
}

test "end-to-end: nested attribute declarations" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const nested = try ev.evaluate("({ a.b = 1; a.c = 2; }).a.c");
    try std.testing.expectEqual(@as(i64, 2), nested.asInt());

    const quoted = try ev.evaluate("({ a.\"b\" = 3; }).a.b");
    try std.testing.expectEqual(@as(i64, 3), quoted.asInt());

    const dynamic_head_decl = try ev.evaluate("let iface = \"eth0\"; network = \"1111::/64\"; in ({ ${iface}.rules.${network} = 7; }).eth0.rules.\"1111::/64\"");
    try std.testing.expectEqual(@as(i64, 7), dynamic_head_decl.asInt());

    const alternating_dynamic_decl = try ev.evaluate("let x = \"b\"; y = \"d\"; in ({ a.${x}.c.${y}.e = 9; }).a.b.c.d.e");
    try std.testing.expectEqual(@as(i64, 9), alternating_dynamic_decl.asInt());

    const lazy = try ev.evaluate("({ a.b = 1; a.c = 1 / 0; }).a.b");
    try std.testing.expectEqual(@as(i64, 1), lazy.asInt());

    const rec_nested = try ev.evaluate("(rec { a.b = x + 1; x = 3; }).a.b");
    try std.testing.expectEqual(@as(i64, 4), rec_nested.asInt());

    const extended_attr = try ev.evaluate("({ a = { b = 1; }; a.c = 2; }).a.c");
    try std.testing.expectEqual(@as(i64, 2), extended_attr.asInt());

    const plain_scope = try ev.evaluate("let y = 2; in ({ a = { x = y; }; a.y = 1; }).a.x");
    try std.testing.expectEqual(@as(i64, 2), plain_scope.asInt());

    const rec_scope = try ev.evaluate("({ a = rec { x = y; }; a.y = 1; }).a.x");
    try std.testing.expectEqual(@as(i64, 1), rec_scope.asInt());

    const duplicate_empty_attrset = try ev.evaluate("({ groups = { video = { }; audio = { }; video = { }; }; }).groups ? video");
    try std.testing.expect(duplicate_empty_attrset.asBool());

    const duplicate_attrset_merge = try ev.evaluate("({ a = { x = 1; }; a = { y = 2; }; }).a.y");
    try std.testing.expectEqual(@as(i64, 2), duplicate_attrset_merge.asInt());

    const duplicate_rec_scope = try ev.evaluate("({ a = rec { x = y; }; a = { y = 1; }; }).a.x");
    try std.testing.expectEqual(@as(i64, 1), duplicate_rec_scope.asInt());

    try std.testing.expectError(error.DuplicateAttribute, ev.evaluate("{ a = 1; a.b = 2; }"));
    try std.testing.expectError(error.DuplicateAttribute, ev.evaluate("{ a.b = 1; a.b = 2; }"));
    try std.testing.expectError(error.DuplicateAttribute, ev.evaluate("{ a = 1; a = { }; }"));
    try std.testing.expectError(error.DuplicateAttribute, ev.evaluate("{ a = { x = 1; }; a = { x = 1; }; }"));
}
