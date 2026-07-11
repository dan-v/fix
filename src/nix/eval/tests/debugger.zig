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
    /// On the first pause, set this source-line breakpoint.
    set_bp: ?struct { file: []const u8, line: u32 } = null,
    /// Count of `.line_breakpoint` pauses.
    line_hits: usize = 0,

    fn install(self: *Probe, ev: *Evaluator) void {
        ev.setDebugUi(self, run);
    }

    fn run(ctx: *anyopaque, s: *DebugSession) anyerror!void {
        const self: *Probe = @ptrCast(@alignCast(ctx));
        self.hits += 1;
        self.last_reason = s.reason;
        self.frame_count = s.frameCount();
        if (s.reason == .line_breakpoint) self.line_hits += 1;

        if (self.set_bp) |bp| {
            self.set_bp = null; // once
            _ = try s.setBreakpoint(bp.file, bp.line);
        }

        var vw: std.Io.Writer = .fixed(&self.value_text);
        s.writeValue(&vw, try s.force(s.value)) catch {};
        self.value_len = vw.end;

        if (self.eval_expr) |expr| {
            const scope = try s.scopeAttrs();
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

test "scopeAttrs resolves breakpoint-scope locals and upvalues by name" {
    var ev = try Evaluator.init(std.testing.allocator, 1);
    defer ev.deinit();
    ev.setCaptureChunkNames(true); // --debugger enables this; needed for names
    var probe: Probe = .{ .eval_expr = "base * factor + n" };
    probe.install(&ev);

    // `factor` is an upvalue of `scale`, `n` a param, `base` a let-binding; the
    // break lands in the argument thunk, so scopeAttrs must merge outer frames.
    const src =
        \\let
        \\  factor = 3;
        \\  scale = n:
        \\    let base = n + 1;
        \\    in builtins.seq (builtins.break "x") (base * factor);
        \\in scale 10
    ;
    _ = try ev.evaluatePath(src, "scope.nix");
    // base=11, factor=3, n=10 -> 11*3 + 10 = 43
    try std.testing.expectEqualStrings("43", probe.evalResult());
}

test "scopeAttrs resolves with-scope bindings, inner with shadowing outer" {
    var ev = try Evaluator.init(std.testing.allocator, 1);
    defer ev.deinit();
    ev.setCaptureChunkNames(true);
    var probe: Probe = .{ .eval_expr = "hello + toString world" };
    probe.install(&ev);

    const src =
        \\let
        \\  pkgs = { hello = "hi"; world = 1; };
        \\  extra = { world = 2; };
        \\in with pkgs; with extra;
        \\   builtins.seq (builtins.break "b") (hello + toString world)
    ;
    _ = try ev.evaluatePath(src, "with.nix");
    // hello from pkgs, world from the inner `with extra` (2) -> "hi2"
    try std.testing.expectEqualStrings("\"hi2\"", probe.evalResult());
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

test "source-line breakpoint fires and preserves the result" {
    var ev = try Evaluator.init(std.testing.allocator, 1);
    defer ev.deinit();
    var probe: Probe = .{ .set_bp = .{ .file = "bp.nix", .line = 3 } };
    probe.install(&ev);

    // Line 3 is a tail apply (`id x`) — a source-mapped, breakpointable line.
    // The initial `builtins.break` pauses so the probe can set the breakpoint;
    // continuing then runs `f 7`, which hits it.
    const src =
        \\let
        \\  id = x: x;
        \\  f = x: id x;
        \\in builtins.seq (builtins.break 0) (f 7)
    ;
    const result = try ev.evaluatePath(src, "bp.nix");
    try std.testing.expect(probe.line_hits >= 1);
    try std.testing.expectEqual(eval_mod.BreakReason.line_breakpoint, probe.last_reason.?);
    // The patched opcode chained to the original: evaluation is unaffected.
    try std.testing.expectEqual(@as(i64, 7), (try ev.forceValue(result)).asInt());
}

test "deleting a source-line breakpoint stops it firing" {
    var ev = try Evaluator.init(std.testing.allocator, 1);
    defer ev.deinit();

    // Set then immediately delete on the first pause; the line must not fire.
    const Local = struct {
        hits_line: usize = 0,
        fn run(ctx: *anyopaque, s: *DebugSession) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (s.reason == .line_breakpoint) {
                self.hits_line += 1;
                return;
            }
            const set = try s.setBreakpoint("bp.nix", 3);
            try std.testing.expect(set != null);
            try std.testing.expect(s.deleteBreakpoint(set.?.id));
        }
    };
    var local: Local = .{};
    ev.setDebugUi(&local, Local.run);

    const src =
        \\let
        \\  id = x: x;
        \\  f = x: id x;
        \\in builtins.seq (builtins.break 0) (f 7)
    ;
    _ = try ev.evaluatePath(src, "bp.nix");
    try std.testing.expectEqual(@as(usize, 0), local.hits_line);
}

test "stepping pauses again and preserves the result" {
    var ev = try Evaluator.init(std.testing.allocator, 1);
    defer ev.deinit();

    // On the initial break, arm a step-into; count the resulting step pauses.
    // Mirrors the console: clear the prior step at each pause entry.
    const Ctl = struct {
        steps: usize = 0,
        armed: bool = false,
        fn run(ctx: *anyopaque, s: *DebugSession) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            s.clearStep();
            if (s.reason == .step) {
                self.steps += 1;
                return; // stop stepping; run to completion
            }
            if (!self.armed) {
                self.armed = true;
                try s.step(.into);
            }
        }
    };
    var ctl: Ctl = .{};
    ev.setDebugUi(&ctl, Ctl.run);

    const src = "let double = x: x * 2; in builtins.seq (builtins.break 0) (double 21)";
    const result = try ev.evaluatePath(src, "s.nix");
    try std.testing.expect(ctl.steps >= 1);
    try std.testing.expectEqual(@as(i64, 42), (try ev.forceValue(result)).asInt());
}

test "clearStep after a step leaves no patched bytecode behind" {
    var ev = try Evaluator.init(std.testing.allocator, 1);
    defer ev.deinit();

    // Arm a step-over on the break, immediately clear it, and continue: the
    // program must run to completion with the correct result and no stray
    // pauses (a leftover patched byte would corrupt or re-trap execution).
    const Ctl = struct {
        extra_pauses: usize = 0,
        armed: bool = false,
        fn run(ctx: *anyopaque, s: *DebugSession) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.armed) {
                self.extra_pauses += 1;
                return;
            }
            self.armed = true;
            try s.step(.over);
            s.clearStep();
        }
    };
    var ctl: Ctl = .{};
    ev.setDebugUi(&ctl, Ctl.run);

    const src = "let double = x: x * 2; in builtins.seq (builtins.break 0) (double 21)";
    const result = try ev.evaluatePath(src, "s.nix");
    try std.testing.expectEqual(@as(usize, 0), ctl.extra_pauses);
    try std.testing.expectEqual(@as(i64, 42), (try ev.forceValue(result)).asInt());
}

test "console abort error propagates out of evaluation" {
    var ev = try Evaluator.init(std.testing.allocator, 1);
    defer ev.deinit();
    var probe: Probe = .{ .return_error = error.DebuggerAbort };
    probe.install(&ev);

    try std.testing.expectError(error.DebuggerAbort, ev.evaluate("builtins.break 1"));
    try std.testing.expectEqual(@as(usize, 1), probe.hits);
}
