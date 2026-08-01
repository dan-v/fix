//! End-to-end semantic differentials for parallel evaluator execution.

const std = @import("std");
const Engine = @import("../evaluator.zig").Engine;

test "concurrency: parallel shared-thunk fan-in agrees with serial evaluation" {
    const source =
        \\let
        \\  shared = builtins.foldl' (acc: x: acc + x) 0 (builtins.genList (x: x + 1) 400);
        \\  demands = builtins.genList (_: shared) 400;
        \\in builtins.deepSeq demands shared
    ;

    var serial = try Engine.init(std.testing.allocator, .{ .worker_count = 1 });
    defer serial.deinit();
    const expected = try serial.evaluate(source);

    var parallel = try Engine.init(std.testing.allocator, .{ .worker_count = 8 });
    defer parallel.deinit();
    const actual = try parallel.evaluate(source);

    try std.testing.expectEqual(expected.asInt(), actual.asInt());
}

test "concurrency: cached parallel failures preserve the serial error" {
    const source =
        \\let
        \\  shared = builtins.throw "shared failure";
        \\  demands = builtins.genList (_: shared) 128;
        \\in builtins.deepSeq demands 0
    ;

    var serial = try Engine.init(std.testing.allocator, .{ .worker_count = 1 });
    defer serial.deinit();
    try std.testing.expectError(error.NixThrow, serial.evaluate(source));
    const serial_message = serial.getTrace().message orelse return error.MissingSerialMessage;

    var parallel = try Engine.init(std.testing.allocator, .{ .worker_count = 8 });
    defer parallel.deinit();
    try std.testing.expectError(error.NixThrow, parallel.evaluate(source));
    const parallel_message = parallel.getTrace().message orelse return error.MissingParallelMessage;

    try std.testing.expectEqualStrings(serial_message, parallel_message);
}
