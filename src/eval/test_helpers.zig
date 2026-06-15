const std = @import("std");
const eval_mod = @import("../eval.zig");
const Evaluator = eval_mod.Evaluator;

pub fn renderForTest(source: []const u8) ![]u8 {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    const result = try ev.evaluate(source);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try ev.writeValue(&out.writer, result);
    return out.toOwnedSlice();
}

pub fn renderStrictForTest(source: []const u8) ![]u8 {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    const result = try ev.evaluate(source);
    try ev.forceDeep(result);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try ev.writeValue(&out.writer, result);
    return out.toOwnedSlice();
}

pub fn renderForTestFromCurrentPath(source: []const u8) ![]u8 {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    try ev.setBasePathFromCurrentPath(std.testing.io);

    const result = try ev.evaluate(source);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try ev.writeValue(&out.writer, result);
    return out.toOwnedSlice();
}

pub fn renderXmlForTest(source: []const u8) ![]u8 {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    // Lazy shells (eager shapes that render `<unevaluated />`) are only
    // built when the render observes them — mirror the CLI's `--xml`.
    ev.lazy_shells_visible = true;

    const result = try ev.evaluate(source);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try ev.writeXmlValue(&out.writer, result);
    return out.toOwnedSlice();
}
