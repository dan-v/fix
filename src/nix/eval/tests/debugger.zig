//! Debugger seam tests: `builtins.break` and error-entry drive the installed
//! `DebugUi`, and the `DebugSession` facade (backtrace, break value, scoped
//! eval) behaves. These exercise the engine half — the CLI console lives in
//! `src/cli/debugger.zig`.

const std = @import("std");
const eval_mod = @import("../../eval.zig");
const Evaluator = eval_mod.Evaluator;
const DebugSession = eval_mod.DebugSession;
const Value = @import("runtime").value.Value;

/// A scripted debugger UI: records what it saw and can run a fixed console
/// expression, so a test can assert on the pause without a terminal.
const Probe = struct {
    hits: usize = 0,
    last_reason: ?eval_mod.BreakReason = null,
    frame_count: usize = 0,
    /// Rendered break value at the last pause.
    value_text: [256]u8 = undefined,
    value_len: usize = 0,
    /// If set, evaluated in-session; its rendered result is captured.
    eval_expr: ?[]const u8 = null,
    eval_text: [256]u8 = undefined,
    eval_len: usize = 0,
    /// Return this error from the console (to test abort propagation).
    return_error: ?anyerror = null,

    fn install(self: *Probe, ev: *Evaluator) void {
        ev.setDebugUi(self, run);
    }

    fn run(ctx: *anyopaque, s: *DebugSession) anyerror!void {
        const self: *Probe = @ptrCast(@alignCast(ctx));
        self.hits += 1;
        self.last_reason = s.reason;
        self.frame_count = s.frameCount();

        var vw: std.Io.Writer = .fixed(&self.value_text);
        s.writeValue(&vw, try s.force(s.value)) catch {};
        self.value_len = vw.end;

        if (self.eval_expr) |expr| {
            const scope = try s.bindValueScope("it");
            const result = try s.eval(expr, scope);
            var ew: std.Io.Writer = .fixed(&self.eval_text);
            s.writeValue(&ew, try s.force(result)) catch {};
            self.eval_len = ew.end;
        }
        if (self.return_error) |e| return e;
    }

    fn value(self: *const Probe) []const u8 {
        return self.value_text[0..self.value_len];
    }
    fn evalResult(self: *const Probe) []const u8 {
        return self.eval_text[0..self.eval_len];
    }
};

test "builtins.break drives the debug UI and is identity" {
    var ev = try Evaluator.init(std.testing.allocator, 1);
    defer ev.deinit();
    var probe: Probe = .{};
    probe.install(&ev);

    const result = try ev.evaluate("builtins.break (2 + 3)");
    try std.testing.expectEqual(@as(usize, 1), probe.hits);
    try std.testing.expectEqual(eval_mod.BreakReason.break_builtin, probe.last_reason.?);
    // Identity: the break value flows through unchanged.
    try std.testing.expectEqual(@as(i64, 5), (try ev.forceValue(result)).asInt());
    try std.testing.expectEqualStrings("5", probe.value());
}

test "debug session evaluates expressions with the break value bound as it" {
    var ev = try Evaluator.init(std.testing.allocator, 1);
    defer ev.deinit();
    var probe: Probe = .{ .eval_expr = "it.a + it.b" };
    probe.install(&ev);

    _ = try ev.evaluate("builtins.break { a = 40; b = 2; }");
    try std.testing.expectEqual(@as(usize, 1), probe.hits);
    try std.testing.expectEqualStrings("42", probe.evalResult());
}

test "no debug UI installed leaves builtins.break as a plain identity" {
    var ev = try Evaluator.init(std.testing.allocator, 1);
    defer ev.deinit();
    const result = try ev.evaluate("builtins.break 7");
    try std.testing.expectEqual(@as(i64, 7), (try ev.forceValue(result)).asInt());
}

test "throw enters the debugger, then the error still propagates" {
    var ev = try Evaluator.init(std.testing.allocator, 1);
    defer ev.deinit();
    var probe: Probe = .{};
    probe.install(&ev);

    try std.testing.expectError(error.NixThrow, ev.evaluate("throw \"boom\""));
    try std.testing.expectEqual(@as(usize, 1), probe.hits);
    try std.testing.expectEqual(eval_mod.BreakReason.eval_error, probe.last_reason.?);
    try std.testing.expectEqualStrings("\"boom\"", probe.value());
}

test "tryEval suppresses debugger error-entry for caught errors" {
    var ev = try Evaluator.init(std.testing.allocator, 1);
    defer ev.deinit();
    var probe: Probe = .{};
    probe.install(&ev);

    _ = try ev.evaluate("builtins.tryEval (throw \"caught\")");
    try std.testing.expectEqual(@as(usize, 0), probe.hits);
}

test "console abort error propagates out of evaluation" {
    var ev = try Evaluator.init(std.testing.allocator, 1);
    defer ev.deinit();
    var probe: Probe = .{ .return_error = error.DebuggerAbort };
    probe.install(&ev);

    try std.testing.expectError(error.DebuggerAbort, ev.evaluate("builtins.break 1"));
    try std.testing.expectEqual(@as(usize, 1), probe.hits);
}
