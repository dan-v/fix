const std = @import("std");
const fix = @import("../../nix.zig");
const Evaluator = fix.Evaluator;
const value = fix.tooling.runtime.value;
const ValueType = value.ValueType;

test "end-to-end: attribute set" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const result = try ev.evaluate("{ a = 1; b = 2; }");
    try std.testing.expectEqual(value.ValueType.attrs, result.kind());
}

test "end-to-end: simple inherit in attrsets" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const inherited = try ev.evaluate("let x = 1; y = 2; in ({ inherit x y; }).y");
    try std.testing.expectEqual(@as(i64, 2), inherited.asInt());

    const recursive = try ev.evaluate("let a = { inherit a; }; in a");
    try std.testing.expectEqual(value.ValueType.attrs, recursive.kind());

    const nested = try ev.evaluate("(let a = { inherit a; }; in a).a.a");
    try std.testing.expectEqual(value.ValueType.attrs, nested.kind());

    const recursive_inherit = try ev.evaluate("let config = 1; in (rec { inherit config; }).config");
    try std.testing.expectEqual(@as(i64, 1), recursive_inherit.asInt());

    try std.testing.expectError(error.ParseError, ev.evaluate("rec { x = 1; inherit x; }"));
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

    // Merging a rec set with a path/non-rec set is Lix's deprecated
    // `rec-set-merges`: an error by default, so exercise the semantics with the
    // feature enabled.
    ev.policy.allow_rec_set_merges = true;
    const rec_scope = try ev.evaluate("({ a = rec { x = y; }; a.y = 1; }).a.x");
    try std.testing.expectEqual(@as(i64, 1), rec_scope.asInt());

    const duplicate_empty_attrset = try ev.evaluate("({ groups = { video = { }; audio = { }; video = { }; }; }).groups ? video");
    try std.testing.expect(duplicate_empty_attrset.asBool());

    const duplicate_attrset_merge = try ev.evaluate("({ a = { x = 1; }; a = { y = 2; }; }).a.y");
    try std.testing.expectEqual(@as(i64, 2), duplicate_attrset_merge.asInt());

    const duplicate_rec_scope = try ev.evaluate("({ a = rec { x = y; }; a = { y = 1; }; }).a.x");
    try std.testing.expectEqual(@as(i64, 1), duplicate_rec_scope.asInt());

    try std.testing.expectError(error.ParseError, ev.evaluate("{ a = 1; a.b = 2; }"));
    try std.testing.expectError(error.ParseError, ev.evaluate("{ a.b = 1; a.b = 2; }"));
    try std.testing.expectError(error.ParseError, ev.evaluate("{ a = 1; a = { }; }"));
    try std.testing.expectError(error.ParseError, ev.evaluate("{ a = { x = 1; }; a = { x = 1; }; }"));
}

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

test "end-to-end: duplicate attributes are rejected" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    try std.testing.expectError(error.ParseError, ev.evaluate("{ a = 1; a = 2; }"));
    try std.testing.expectError(error.ParseError, ev.evaluate("{ a = 1 / 0; a = 2; }"));
}

test "end-to-end: quoted attribute access" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const result = try ev.evaluate("({ foo = 42; }).\"foo\"");
    try std.testing.expectEqual(@as(i64, 42), result.asInt());
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
