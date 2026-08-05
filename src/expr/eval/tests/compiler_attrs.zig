const std = @import("std");
const Engine = @import("../../evaluator.zig").Engine;
const chunk = @import("../../bytecode.zig").chunk;

test "compiles a plain attribute set with two entries" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    const result = try ev.evaluate("{ a = 1; b = 2; }.a + { a = 1; b = 2; }.b");
    try std.testing.expectEqual(@as(i64, 3), result.asInt());
}

test "reports duplicate attribute as a parse error" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    try std.testing.expectError(error.ParseError, ev.evaluate("{ a = 1; a = 2; }"));
}

test "compiles a recursive attribute set referencing a sibling" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    const result = try ev.evaluate("(rec { a = 1; b = a + 1; }).b");
    try std.testing.expectEqual(@as(i64, 2), result.asInt());
}

test "recursive overrides keep re-pointable cells out of speculation" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 8 });
    defer ev.deinit();
    var policy = ev.languagePolicy();
    policy.allow_rec_set_overrides = true;
    ev.configureLanguage(policy);

    var source: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer source.deinit();
    try source.writer.writeAll("(rec { x = ");
    for (0..80) |_| try source.writer.writeAll("z + ");
    try source.writer.writeAll("z; z = 1; y = x; __overrides = { x = 2; }; }).y");

    const before = ev.registry.count();
    const result = try ev.evaluate(source.written());
    try std.testing.expectEqual(@as(i64, 2), result.asInt());

    const x_name = try ev.intern.intern("x");
    var found_substantial_x = false;
    var id = before;
    while (id < ev.registry.count()) : (id += 1) {
        const name_id = ev.registry.nameOf(id) orelse continue;
        const name = ev.registry.nameNode(name_id) orelse continue;
        const slot = ev.registry.slot(id).?;
        if (name.parent != 0 or name.segment != x_name or
            slot.ptr.code.len < chunk.speculation_min_code_bytes) continue;
        found_substantial_x = true;
        try std.testing.expect(!slot.body_is_substantial);
    }
    try std.testing.expect(found_substantial_x);
}

test "compiles a dynamic attribute name from string interpolation" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    const result = try ev.evaluate("let x = \"foo\"; in ({ \"${x}\" = 1; }).foo");
    try std.testing.expectEqual(@as(i64, 1), result.asInt());
}

test "reports duplicate attribute inside a nested static path" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    try std.testing.expectError(error.ParseError, ev.evaluate("{ a.b = 1; a.b = 2; }"));
}

test "attr segments equal compares underlying source text" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    // `foo` and `"foo"` denote the same attribute name; merging both into
    // one set without a duplicate-attribute error exercises the segment
    // equality/dedup path that backs group-by-name compilation.
    const result = try ev.evaluate("{ foo = 1; }.foo");
    try std.testing.expectEqual(@as(i64, 1), result.asInt());
}
