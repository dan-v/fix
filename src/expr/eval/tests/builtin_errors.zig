const std = @import("std");
const std_testing = std.testing;
const effects = @import("../../effects.zig");
const Evaluator = @import("../../evaluator.zig").Evaluator;
const renderForTest = @import("../test_helpers.zig").renderForTest;

const EffectCapture = struct {
    count: usize = 0,
    kinds: [16]effects.Kind = undefined,
    lengths: [16]usize = undefined,
    messages: [16][256]u8 = undefined,

    fn emit(raw: ?*anyopaque, kind: effects.Kind, text: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        if (self.count == self.messages.len or text.len > self.messages[0].len)
            @panic("effect capture overflow");
        self.kinds[self.count] = kind;
        self.lengths[self.count] = text.len;
        @memcpy(self.messages[self.count][0..text.len], text);
        self.count += 1;
    }

    fn message(self: *const @This(), index: usize) []const u8 {
        return self.messages[index][0..self.lengths[index]];
    }
};

test "tryEval catches thrown errors but not arbitrary Zig errors" {
    const caught_throw = try renderForTest("(builtins.tryEval (builtins.throw \"boom\")).success");
    defer std_testing.allocator.free(caught_throw);
    try std_testing.expectEqualStrings("false", caught_throw);

    const caught_abort = try renderForTest("(builtins.tryEval (builtins.abort \"boom\")).success");
    defer std_testing.allocator.free(caught_abort);
    try std_testing.expectEqualStrings("false", caught_abort);

    // Division by zero is not one of tryEval's caught kinds — it propagates.
    try std_testing.expectError(error.DivisionByZero, renderForTest("builtins.tryEval (1 / 0)"));
}

test "tryEval on success reports the forced value" {
    const success = try renderForTest("(builtins.tryEval 42).value");
    defer std_testing.allocator.free(success);
    try std_testing.expectEqualStrings("42", success);
}

test "addErrorContext returns the value on success and rethrows the original error on failure" {
    const success = try renderForTest("builtins.addErrorContext \"context\" 42");
    defer std_testing.allocator.free(success);
    try std_testing.expectEqualStrings("42", success);

    try std_testing.expectError(error.NixThrow, renderForTest("builtins.addErrorContext \"context\" (builtins.throw \"boom\")"));
}

test "trace forces the message and returns the value unchanged" {
    const traced = try renderForTest("builtins.trace \"msg\" 42");
    defer std_testing.allocator.free(traced);
    try std_testing.expectEqualStrings("42", traced);

    try std_testing.expectError(error.NixThrow, renderForTest("builtins.trace (builtins.throw \"boom\") 42"));
}

test "trace, traceVerbose, and warn emit sanitized effects" {
    var capture: EffectCapture = .{};
    var ev = try Evaluator.init(std_testing.allocator, 0);
    defer ev.deinit();
    ev.setEffectSink(.{ .context = &capture, .emit_fn = EffectCapture.emit });

    const traced = try ev.evaluate("builtins.trace (builtins.fromJSON \"\\\"\\\\u001b[31mred\\\\u001b[0m\\\\rX\\\"\") 42");
    try std_testing.expectEqual(@as(i64, 42), traced.asInt());
    try std_testing.expectEqual(@as(usize, 1), capture.count);
    try std_testing.expectEqual(.trace, capture.kinds[0]);
    try std_testing.expectEqualStrings("redX", capture.message(0));

    const warned = try ev.evaluate("builtins.warn (builtins.fromJSON \"\\\"\\\\u001b[33mcareful\\\\u001b[0m\\\"\") 7");
    try std_testing.expectEqual(@as(i64, 7), warned.asInt());
    try std_testing.expectEqual(@as(usize, 2), capture.count);
    try std_testing.expectEqual(.warning, capture.kinds[1]);
    try std_testing.expectEqualStrings("careful", capture.message(1));

    // Disabled verbose tracing must not even force its message.
    const quiet = try ev.evaluate("builtins.traceVerbose (builtins.throw \"quiet\") 9");
    try std_testing.expectEqual(@as(i64, 9), quiet.asInt());
    try std_testing.expectEqual(@as(usize, 2), capture.count);
    ev.setTraceVerbose(true);
    const verbose = try ev.evaluate("builtins.traceVerbose \"verbose\" 10");
    try std_testing.expectEqual(@as(i64, 10), verbose.asInt());
    try std_testing.expectEqual(@as(usize, 3), capture.count);
    try std_testing.expectEqualStrings("verbose", capture.message(2));

    // Rendering an arbitrary message is shallow: lazy children are displayed,
    // not forced just for logging.
    const attrs = try ev.evaluate("builtins.trace { a = 1; z = builtins.throw \"boom\"; } 11");
    try std_testing.expectEqual(@as(i64, 11), attrs.asInt());
    try std_testing.expectEqual(@as(usize, 4), capture.count);
    try std_testing.expect(std.mem.indexOf(u8, capture.message(3), "a = 1") != null);
    try std_testing.expect(std.mem.indexOf(u8, capture.message(3), "z = «thunk»") != null);
}

test "effectful thunk bodies do not enter the pure result memo" {
    var capture: EffectCapture = .{};
    var ev = try Evaluator.init(std_testing.allocator, 0);
    defer ev.deinit();
    ev.setEffectSink(.{ .context = &capture, .emit_fn = EffectCapture.emit });

    const result = try ev.evaluate("let f = x: builtins.trace \"call\" (x + 1); in (f 1) + (f 1)");
    try std_testing.expectEqual(@as(i64, 4), result.asInt());
    try std_testing.expectEqual(@as(usize, 2), capture.count);
    try std_testing.expectEqualStrings("call", capture.message(0));
    try std_testing.expectEqualStrings("call", capture.message(1));
}
