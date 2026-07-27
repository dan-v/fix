const std = @import("std");
const Engine = @import("../../evaluator.zig").Engine;

test "has-attr path within the segment-count limit compiles and evaluates" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    const result = try ev.evaluate("{ a = { b = 1; }; } ? a.b");
    try std.testing.expect(result.asBool());
}

test "has-attr path exceeding the u8 segment limit is a compile error" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    // `requireU8At` guards the has-attr-path segment count operand
    // (written as a single byte); a path with more than 255 segments
    // must fail to compile rather than silently truncate.
    var source: std.ArrayListUnmanaged(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    try source.appendSlice(std.testing.allocator, "{} ? a");
    var i: usize = 0;
    while (i < 260) : (i += 1) {
        try source.appendSlice(std.testing.allocator, ".a");
    }

    try std.testing.expectError(error.BytecodeOperandTooLarge, ev.evaluate(source.items));
}
