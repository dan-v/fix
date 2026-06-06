const std = @import("std");
const eval_mod = @import("../../eval.zig");
const Evaluator = eval_mod.Evaluator;
const Diagnostic = eval_mod.Diagnostic;
const Value = @import("../../value.zig").Value;
const path_ops = @import("../../runtime/paths.zig");
const helpers = @import("../test_helpers.zig");
const renderForTest = helpers.renderForTest;
const renderStrictForTest = helpers.renderStrictForTest;
const renderForTestFromCurrentPath = helpers.renderForTestFromCurrentPath;
const renderXmlForTest = helpers.renderXmlForTest;

test "evaluate path construction builtins" {
    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const file_path = try std.fs.path.join(std.testing.allocator, &.{ cwd, "test/fuzz-corpus/imported.nix" });
    defer std.testing.allocator.free(file_path);

    const store_source = try std.fmt.allocPrint(std.testing.allocator, "builtins.isString (builtins.storePath \"{s}\")", .{cwd});
    defer std.testing.allocator.free(store_source);
    const path_source = try std.fmt.allocPrint(std.testing.allocator, "builtins.isString (builtins.path {{ path = \"{s}\"; name = \"imported\"; }})", .{file_path});
    defer std.testing.allocator.free(path_source);
    const path_value_source = try std.fmt.allocPrint(std.testing.allocator, "builtins.unsafeDiscardStringContext (builtins.path {{ path = \"{s}\"; name = \"imported\"; }})", .{file_path});
    defer std.testing.allocator.free(path_value_source);
    const path_prefix_source = try std.fmt.allocPrint(std.testing.allocator, "builtins.toJSON (builtins.substring 0 11 (builtins.path {{ path = \"{s}\"; name = \"imported\"; }}))", .{file_path});
    defer std.testing.allocator.free(path_prefix_source);
    const path_append_store_context_source = try std.fmt.allocPrint(std.testing.allocator, "/foo + builtins.substring 0 11 (builtins.path {{ path = \"{s}\"; name = \"imported\"; }})", .{file_path});
    defer std.testing.allocator.free(path_append_store_context_source);
    const literal_path_source =
        \\let p = ./build.zig; in builtins.toJSON {
        \\  raw = builtins.toString p;
        \\  interp = "${p}";
        \\  concat = builtins.concatStringsSep "" [ p ];
        \\  json = builtins.toJSON p;
        \\}
    ;

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    ev.setFileIo(std.testing.io);
    try ev.setBasePathFromCurrentPath(std.testing.io);

    const store_path = try ev.evaluate(store_source);
    try std.testing.expect(store_path.asBool());

    const path = try ev.evaluate(path_source);
    try std.testing.expect(path.asBool());

    const path_value = try ev.evaluate(path_value_source);
    try std.testing.expectEqualStrings("/nix/store/375nsbsr3gvzlfpmnviljghr7racpq67-imported", ev.intern.get(path_value.asInternId()));

    const path_prefix = try ev.evaluate(path_prefix_source);
    try std.testing.expectEqual(.string_context, path_prefix.discriminant);
    const path_prefix_string = try ev.heap.getContextString(path_prefix.asObjectId());
    try std.testing.expectEqualStrings("\"/nix/store/\"", ev.intern.get(path_prefix_string.text));

    const literal_paths = try ev.evaluate(literal_path_source);
    try std.testing.expectEqual(.string_context, literal_paths.discriminant);
    const literal_paths_string = try ev.heap.getContextString(literal_paths.asObjectId());
    const literal_paths_text = ev.intern.get(literal_paths_string.text);
    try std.testing.expect(std.mem.indexOf(u8, literal_paths_text, cwd) != null);
    try std.testing.expect(std.mem.indexOf(u8, literal_paths_text, "/nix/store/") != null);
    try std.testing.expect(std.mem.indexOf(u8, literal_paths_text, "-build.zig") != null);

    try std.testing.expectError(error.InvalidPathConcatenation, ev.evaluate(path_append_store_context_source));
}

test "evaluate nixpkgs-heavy collection builtins" {
    const sorted = try renderForTest("builtins.sort (a: b: a < b) [ 3 1 2 ]");
    defer std.testing.allocator.free(sorted);
    try std.testing.expectEqualStrings("[ 1 2 3 ]", sorted);

    const partitioned = try renderForTest("(builtins.partition (x: x < 3) [ 1 3 2 ]).right");
    defer std.testing.allocator.free(partitioned);
    try std.testing.expectEqualStrings("[ 1 2 ]", partitioned);

    const grouped = try renderForTest("(builtins.groupBy (x: if x < 3 then \"small\" else \"big\") [ 1 3 2 ]).small");
    defer std.testing.allocator.free(grouped);
    try std.testing.expectEqualStrings("[ 1 2 ]", grouped);

    const closure_len = try renderForTest("builtins.length (builtins.genericClosure { startSet = [ { key = 1; } ]; operator = item: if item.key < 3 then [ { key = item.key + 1; } ] else [ ]; })");
    defer std.testing.allocator.free(closure_len);
    try std.testing.expectEqualStrings("3", closure_len);

    const cat_attrs = try renderForTest("builtins.elemAt (builtins.catAttrs \"a\" [ { a = 1; } { b = 2; } { a = 3; } ]) 1");
    defer std.testing.allocator.free(cat_attrs);
    try std.testing.expectEqualStrings("3", cat_attrs);

    const cat_attrs_lazy = try renderForTest("builtins.length (builtins.catAttrs \"a\" [ { a = 1 / 0; } ])");
    defer std.testing.allocator.free(cat_attrs_lazy);
    try std.testing.expectEqualStrings("1", cat_attrs_lazy);

    const zipped_len = try renderForTest("(builtins.zipAttrsWith (name: values: builtins.length values) [ { a = 1; } { a = 2; b = 3; } ]).a");
    defer std.testing.allocator.free(zipped_len);
    try std.testing.expectEqualStrings("2", zipped_len);

    const zipped_first = try renderForTest("(builtins.zipAttrsWith (name: values: builtins.head values) [ { a = 1; } { a = 2; } ]).a");
    defer std.testing.allocator.free(zipped_first);
    try std.testing.expectEqualStrings("1", zipped_first);

    const zipped_lazy_select = try renderForTest("(builtins.zipAttrsWith (name: values: if name == \"a\" then 1 else builtins.throw \"bad\") [ { a = 1; b = 2; } ]).a");
    defer std.testing.allocator.free(zipped_lazy_select);
    try std.testing.expectEqualStrings("1", zipped_lazy_select);

    const zipped_lazy_has_attr = try renderForTest("(builtins.zipAttrsWith (name: values: builtins.throw \"bad\") [ { a = 1; } ]) ? a");
    defer std.testing.allocator.free(zipped_lazy_has_attr);
    try std.testing.expectEqualStrings("true", zipped_lazy_has_attr);
}

test "evaluate function metadata builtins" {
    const args = try renderForTest("(builtins.functionArgs ({ a, b ? 1 }: a)).b");
    defer std.testing.allocator.free(args);
    try std.testing.expectEqualStrings("true", args);

    const pos = try renderForTest("builtins.unsafeGetAttrPos \"a\" { a = 1; }");
    defer std.testing.allocator.free(pos);
    try std.testing.expectEqualStrings("null", pos);

    const expr_cur_pos = try renderForTest("let __curPos = 7; in __curPos");
    defer std.testing.allocator.free(expr_cur_pos);
    try std.testing.expectEqualStrings("null", expr_cur_pos);

    const imported_pos = try renderForTestFromCurrentPath("builtins.toJSON (builtins.unsafeGetAttrPos \"value\" (import ./test/fuzz-corpus/imported.nix))");
    defer std.testing.allocator.free(imported_pos);

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const expected_imported_pos = try std.fmt.allocPrint(
        std.testing.allocator,
        "\"{{\\\"column\\\":3,\\\"file\\\":\\\"{s}/test/fuzz-corpus/imported.nix\\\",\\\"line\\\":1}}\"",
        .{cwd},
    );
    defer std.testing.allocator.free(expected_imported_pos);
    try std.testing.expectEqualStrings(expected_imported_pos, imported_pos);

    const cur_pos = try renderForTestFromCurrentPath("builtins.toJSON (import ./test/curpos.nix)");
    defer std.testing.allocator.free(cur_pos);
    const expected_cur_pos = try std.fmt.allocPrint(
        std.testing.allocator,
        "\"{{\\\"column\\\":12,\\\"file\\\":\\\"{s}/test/curpos.nix\\\",\\\"line\\\":2}}\"",
        .{cwd},
    );
    defer std.testing.allocator.free(expected_cur_pos);
    try std.testing.expectEqualStrings(expected_cur_pos, cur_pos);
}

test "evaluate foldl' builtin" {
    const sum = try renderForTest("builtins.foldl' (a: b: a + b) 0 [ 1 2 3 ]");
    defer std.testing.allocator.free(sum);
    try std.testing.expectEqualStrings("6", sum);

    const ignores_item = try renderForTest("builtins.foldl' (a: b: a) 1 [ (1 / 0) ]");
    defer std.testing.allocator.free(ignores_item);
    try std.testing.expectEqualStrings("1", ignores_item);

    const returns_item = try renderForTest("builtins.foldl' (a: b: b) 0 [ 1 2 ]");
    defer std.testing.allocator.free(returns_item);
    try std.testing.expectEqualStrings("2", returns_item);
}

test "evaluate exposes parse diagnostics without printing" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    try std.testing.expectError(error.ParseError, ev.evaluate("$ $ 1"));
    const diagnostics = ev.getDiagnostics();
    try std.testing.expectEqual(@as(usize, 2), diagnostics.len);
    try std.testing.expectEqualStrings("Invalid token.", diagnostics[0].message);
    try std.testing.expectEqual(@as(u32, 0), diagnostics[0].offset);
    try std.testing.expectEqual(@as(u32, 1), diagnostics[0].column);
    try std.testing.expectEqualStrings("Invalid token.", diagnostics[1].message);
    try std.testing.expectEqual(@as(u32, 2), diagnostics[1].offset);
    try std.testing.expectEqual(@as(u32, 3), diagnostics[1].column);
}

test "evaluate exposes duplicate binding diagnostics" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    try std.testing.expectError(error.DuplicateBinding, ev.evaluate("let x = 1; x = 2; in x"));
    const diagnostics = ev.getDiagnostics();
    try std.testing.expectEqual(@as(usize, 2), diagnostics.len);
    try std.testing.expectEqual(Diagnostic.Severity.err, diagnostics[0].severity);
    try std.testing.expectEqual(Diagnostic.Kind.compile, diagnostics[0].kind);
    try std.testing.expectEqualStrings("duplicate let binding", diagnostics[0].message);
    try std.testing.expectEqual(@as(u32, 11), diagnostics[0].offset);
    try std.testing.expectEqual(Diagnostic.Severity.note, diagnostics[1].severity);
    try std.testing.expectEqualStrings("first binding defined here", diagnostics[1].message);
    try std.testing.expectEqual(@as(u32, 4), diagnostics[1].offset);
}

test "evaluate exposes duplicate attribute diagnostics" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    try std.testing.expectError(error.DuplicateAttribute, ev.evaluate("{ a = 1; a = 2; }"));
    const diagnostics = ev.getDiagnostics();
    try std.testing.expectEqual(@as(usize, 2), diagnostics.len);
    try std.testing.expectEqual(Diagnostic.Severity.err, diagnostics[0].severity);
    try std.testing.expectEqual(Diagnostic.Kind.compile, diagnostics[0].kind);
    try std.testing.expectEqualStrings("duplicate attribute", diagnostics[0].message);
    try std.testing.expectEqual(@as(u32, 9), diagnostics[0].offset);
    try std.testing.expectEqual(Diagnostic.Severity.note, diagnostics[1].severity);
    try std.testing.expectEqualStrings("first attribute defined here", diagnostics[1].message);
    try std.testing.expectEqual(@as(u32, 2), diagnostics[1].offset);
}

test "evaluate exposes undefined variable diagnostics" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    try std.testing.expectError(error.UndefinedVariable, ev.evaluate("let y = x; in y"));
    const diagnostics = ev.getDiagnostics();
    try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
    try std.testing.expectEqual(Diagnostic.Severity.err, diagnostics[0].severity);
    try std.testing.expectEqual(Diagnostic.Kind.compile, diagnostics[0].kind);
    try std.testing.expectEqualStrings("undefined variable 'x'", diagnostics[0].message);
    try std.testing.expectEqual(@as(u32, 8), diagnostics[0].offset);
    try std.testing.expectEqual(@as(u32, 9), diagnostics[0].column);
}

test "evaluate exposes invalid numeric literal diagnostics" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    try std.testing.expectError(error.InvalidNumber, ev.evaluate("9223372036854775808"));
    const diagnostics = ev.getDiagnostics();
    try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
    try std.testing.expectEqual(Diagnostic.Kind.compile, diagnostics[0].kind);
    try std.testing.expectEqualStrings("invalid integer literal", diagnostics[0].message);
    try std.testing.expectEqual(@as(u32, 0), diagnostics[0].offset);
}

test "evaluate exposes interpolation parse diagnostics" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    try std.testing.expectError(error.ParseError, ev.evaluate("\"${$}\""));
    const diagnostics = ev.getDiagnostics();
    try std.testing.expect(diagnostics.len >= 1);
    try std.testing.expectEqual(Diagnostic.Kind.parse, diagnostics[0].kind);
    try std.testing.expectEqualStrings("Invalid token.", diagnostics[0].message);
    try std.testing.expectEqual(@as(u32, 3), diagnostics[0].offset);
    try std.testing.expectEqual(@as(u32, 4), diagnostics[0].column);
}

test "evaluate records runtime error message and expression trace" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    try std.testing.expectError(error.TypeError, ev.evaluate("let y = 1 + \"x\"; in y"));

    const trace = ev.getTrace();
    try std.testing.expect(trace.message != null);
    try std.testing.expectEqualStrings("expected string or path, got int", trace.message.?);
    try std.testing.expect(trace.frames.items.len >= 2);
    try std.testing.expect(trace.frames.items[0].diagnostic != null);
    try std.testing.expect(trace.frames.items[0].source_path == null);
    try std.testing.expectEqualStrings("while evaluating", trace.frames.items[0].message);
    try std.testing.expectEqual(@as(u32, 1), trace.frames.items[0].diagnostic.?.line);
    try std.testing.expectEqual(@as(u32, 9), trace.frames.items[0].diagnostic.?.column);
}

test "evaluate records imported file source trace" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "boom.nix", .data = "let y = 1 + \"x\"; in y\n" });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const file_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "boom.nix",
    });
    defer std.testing.allocator.free(file_path);

    const source = try std.fmt.allocPrint(std.testing.allocator, "import {s}", .{file_path});
    defer std.testing.allocator.free(source);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    try std.testing.expectError(error.TypeError, ev.evaluate(source));

    const trace = ev.getTrace();
    try std.testing.expect(trace.message != null);
    try std.testing.expectEqualStrings("expected string or path, got int", trace.message.?);
    try std.testing.expect(trace.frames.items.len >= 1);
    try std.testing.expect(trace.frames.items[0].diagnostic != null);
    try std.testing.expect(trace.frames.items[0].source_path != null);
    try std.testing.expectEqualStrings(file_path, trace.frames.items[0].source_path.?);
    try std.testing.expectEqual(@as(u32, 1), trace.frames.items[0].diagnostic.?.line);
    try std.testing.expectEqual(@as(u32, 9), trace.frames.items[0].diagnostic.?.column);
}
