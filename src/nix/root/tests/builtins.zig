const std = @import("std");
const fix = @import("../../root.zig");
const Evaluator = fix.Evaluator;
const value = fix.runtime.value;
const ValueType = value.ValueType;

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
    try std.testing.expectEqual(value.ValueType.string, version.kind());

    const missing_env = try ev.evaluate("builtins.getEnv \"FIX_TEST_UNSET\"");
    try std.testing.expectEqualStrings("", ev.intern.get(missing_env.asInternId()));

    const context = try ev.evaluate("builtins.hasContext \"x\"");
    try std.testing.expect(!context.asBool());
}

test "end-to-end: builtins.toFile returns store-like string" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const file_value = try ev.evaluate("builtins.toFile \"x\" \"hello\"");
    try std.testing.expectEqual(value.ValueType.string_context, file_value.kind());
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
    try std.testing.expectEqual(value.ValueType.attrs, drv.kind());

    const user_hook = try ev.evaluate("(derivation { name = \"x\"; builder = \"b\"; system = \"s\"; userHook = null; }).userHook");
    try std.testing.expectEqual(value.ValueType.null, user_hook.kind());
}

test "end-to-end: core fetchurl import" {
    const alloc = std.testing.allocator;

    var ev = try Evaluator.init(alloc, 0);
    defer ev.deinit();

    const fetched = try ev.evaluate(
        "import <nix/fetchurl.nix> { name = \"seed\"; url = \"https://example.com/seed\"; sha256 = \"sha256-000\"; }",
    );
    try std.testing.expectEqual(value.ValueType.attrs, fetched.kind());
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
