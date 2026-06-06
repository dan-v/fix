const std = @import("std");
const eval_mod = @import("../../eval.zig");
const Evaluator = eval_mod.Evaluator;
const Diagnostic = eval_mod.Diagnostic;

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
