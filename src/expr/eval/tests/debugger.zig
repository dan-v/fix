//! Debugger seam tests: `builtins.break` and error-entry drive the installed
//! `DebugUi`, and the `DebugSession` facade (backtrace, break value, scoped
//! eval) behaves. These exercise the engine half — the CLI console lives in
//! `src/cli/debugger.zig`.

const std = @import("std");
const eval_mod = @import("../../evaluator.zig");
const Engine = eval_mod.Engine;
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

    fn install(self: *Probe, ev: *Engine) void {
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
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 1 });
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

test "native debug entry pauses on unchanged user source" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 1 });
    defer ev.deinit();
    var probe: Probe = .{};
    probe.install(&ev);

    const source = "let answer = 40; in answer + 2";
    const result = try ev.debugWithScopeResult(source, null);
    try std.testing.expectEqual(@as(usize, 1), probe.hits);
    try std.testing.expectEqual(eval_mod.BreakReason.entry, probe.last_reason.?);
    try std.testing.expect(probe.frame_count >= 1);
    try std.testing.expectEqual(@as(i64, 42), (try ev.forceValue(result.value)).asInt());
}

test "debug session evaluates expressions with the break value bound as it" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 1 });
    defer ev.deinit();
    var probe: Probe = .{ .eval_expr = "it.a + it.b" };
    probe.install(&ev);

    _ = try ev.evaluate("builtins.break { a = 40; b = 2; }");
    try std.testing.expectEqual(@as(usize, 1), probe.hits);
    try std.testing.expectEqualStrings("42", probe.evalResult());
}

test "scopeAttrs resolves breakpoint-scope locals and upvalues by name" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 1 });
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
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 1 });
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

test "qualified chunk names are populated always-on, without capture_names" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 1 });
    defer ev.deinit();
    // Deliberately do NOT setCaptureChunkNames — the name tree is always on.
    _ = try ev.evaluate("let myFunc = x: x + 1; in myFunc 5");

    const reg = ev.chunkRegistry();
    var found = false;
    var id: u32 = 0;
    while (id < reg.count()) : (id += 1) {
        var buf: [64]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        reg.writeQualifiedName(&w, id, ev.internTable()) catch continue;
        if (std.mem.eql(u8, buf[0..w.end], "myFunc")) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "no debug UI installed leaves builtins.break as a plain identity" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 1 });
    defer ev.deinit();
    const result = try ev.evaluate("builtins.break 7");
    try std.testing.expectEqual(@as(i64, 7), (try ev.forceValue(result)).asInt());
}

test "debug UI can be detached between evaluations" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 1 });
    defer ev.deinit();
    var probe: Probe = .{};
    probe.install(&ev);
    _ = try ev.evaluate("builtins.break 1");
    ev.clearDebugUi();
    const result = try ev.evaluate("builtins.break 2");
    try std.testing.expectEqual(@as(usize, 1), probe.hits);
    try std.testing.expectEqual(@as(i64, 2), (try ev.forceValue(result)).asInt());
}

test "throw enters the debugger, then the error still propagates" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 1 });
    defer ev.deinit();
    var probe: Probe = .{};
    probe.install(&ev);

    try std.testing.expectError(error.NixThrow, ev.evaluate("throw \"boom\""));
    try std.testing.expectEqual(@as(usize, 1), probe.hits);
    try std.testing.expectEqual(eval_mod.BreakReason.eval_error, probe.last_reason.?);
    try std.testing.expectEqualStrings("\"boom\"", probe.value());
}

test "caught debugger eval failure does not mask a later language error" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 1 });
    defer ev.deinit();

    const Ctl = struct {
        ran: bool = false,

        fn run(ctx: *anyopaque, s: *DebugSession) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (s.reason != .break_builtin or self.ran) return;
            self.ran = true;

            _ = s.eval("builtins.throw \"debugger-only failure\"", null) catch {};

            // Attrset rendering probes `type` to recognize derivations. That
            // nested force must remain on the debugger's ancillary trace.
            const attrs = try s.eval(
                "{ type = builtins.throw \"debugger render failure\"; }",
                null,
            );
            var buffer: [256]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&buffer);
            s.writeValue(&writer, attrs) catch {};
        }
    };
    var ctl: Ctl = .{};
    ev.setDebugUi(&ctl, Ctl.run);

    try std.testing.expectError(
        error.NixThrow,
        ev.evaluate(
            \\builtins.seq
            \\  (builtins.break null)
            \\  (builtins.throw "visible program failure")
        ),
    );
    try std.testing.expect(ctl.ran);
    try std.testing.expectEqualStrings("visible program failure", ev.getTrace().message.?);
}

test "debugger retains evaluated heap values for the lifetime of the pause" {
    // Keep peer workers present so the in-pause collector must complete the
    // same stop-the-world barrier used by a parallel embedding.
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 4 });
    defer ev.deinit();
    ev.configureMemory(64 << 20, null, false);

    const Ctl = struct {
        ran: bool = false,
        retained: bool = false,
        collections: u64 = 0,
        rendered: [128]u8 = undefined,
        rendered_len: usize = 0,

        fn run(ctx: *anyopaque, s: *DebugSession) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (s.reason != .break_builtin or self.ran) return;
            self.ran = true;

            const value = try s.eval("{ retained = 42; }", null);
            for (s.vm.gc_roots.temporary.items) |root| {
                if (root.bits == value.bits) self.retained = true;
            }

            // The first explicit request arms lazy tracking; the second runs a
            // full collection while the demand fiber is paused in the UI.
            // The value's producing VM is already gone, so only the session
            // root keeps it alive.
            _ = s.collectGarbage();
            self.collections = s.collectGarbage().collections;
            // Encourage the allocator to reuse anything the collection swept;
            // rendering `value` must still refer to the original object.
            _ = try s.eval("{ replacement = 99; }", null);
            var writer: std.Io.Writer = .fixed(&self.rendered);
            try s.writeValue(&writer, value);
            self.rendered_len = writer.end;
        }
    };
    var ctl: Ctl = .{};
    ev.setDebugUi(&ctl, Ctl.run);

    const result = try ev.evaluate(
        \\builtins.seq
        \\  (builtins.break null)
        \\  17
    );
    try std.testing.expect(ctl.ran);
    try std.testing.expect(ctl.retained);
    try std.testing.expect(ctl.collections > 0);
    try std.testing.expectEqualStrings("{ retained = 42; }", ctl.rendered[0..ctl.rendered_len]);
    try std.testing.expectEqual(@as(i64, 17), result.asInt());
}

test "caught debugger eval failure at error entry preserves the original failure" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 1 });
    defer ev.deinit();

    const Ctl = struct {
        ran: bool = false,

        fn run(ctx: *anyopaque, s: *DebugSession) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (s.reason != .eval_error or self.ran) return;
            self.ran = true;
            _ = s.eval("builtins.throw \"debugger-only failure\"", null) catch {};
        }
    };
    var ctl: Ctl = .{};
    ev.setDebugUi(&ctl, Ctl.run);

    try std.testing.expectError(
        error.NixThrow,
        ev.evaluate("builtins.throw \"original program failure\""),
    );
    try std.testing.expect(ctl.ran);
    try std.testing.expectEqualStrings("original program failure", ev.getTrace().message.?);
}

test "tryEval suppresses debugger error-entry for caught errors" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 1 });
    defer ev.deinit();
    var probe: Probe = .{};
    probe.install(&ev);

    _ = try ev.evaluate("builtins.tryEval (throw \"caught\")");
    try std.testing.expectEqual(@as(usize, 0), probe.hits);
}

test "source-line breakpoint fires and preserves the result" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 1 });
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
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 1 });
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
            try std.testing.expect(s.deleteBreakpoint(set.id));
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
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 1 });
    defer ev.deinit();

    // On the initial break, arm a step-into; count the resulting step pauses.
    // Mirrors the console: clear the prior step at each pause entry.
    const Ctl = struct {
        steps: usize = 0,
        armed: bool = false,
        fn run(ctx: *anyopaque, s: *DebugSession) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            s.clearStep();
            if (s.reason == .step or s.reason == .return_step) {
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

test "repeated step into preserves suspended caller operands" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 1 });
    defer ev.deinit();

    // Forcing `seed`, `base`, and the function argument suspends parent
    // handlers with their saved ip at an operand byte. Re-arming step-into at
    // each nested pause must target the following instruction, not that byte.
    const Ctl = struct {
        pauses: usize = 0,

        fn run(ctx: *anyopaque, s: *DebugSession) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            s.clearStep();
            self.pauses += 1;
            if (self.pauses < 16) try s.step(.into);
        }
    };
    var ctl: Ctl = .{};
    ev.setDebugUi(&ctl, Ctl.run);

    const src =
        \\let
        \\  base = let seed = 40; in seed + 1;
        \\  add = x: x + 1;
        \\in add base
    ;
    const result = try ev.debugWithScopeResult(src, null);
    try std.testing.expect(ctl.pauses >= 3);
    try std.testing.expectEqual(@as(i64, 42), (try ev.forceValue(result.value)).asInt());
}

test "step into follows an import compiled after the step is armed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "imported.nix",
        .data = "{ value = 42; }\n",
    });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const file_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "imported.nix",
    });
    defer std.testing.allocator.free(file_path);
    const source = try std.fmt.allocPrint(
        std.testing.allocator,
        "builtins.seq (builtins.break null) ((import {s}).value)",
        .{file_path},
    );
    defer std.testing.allocator.free(source);

    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 1 });
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    const Ctl = struct {
        imported_step: bool = false,
        pauses: usize = 0,

        fn run(ctx: *anyopaque, s: *DebugSession) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            s.clearStep();
            self.pauses += 1;
            try std.testing.expect(self.pauses < 8);
            if (s.reason == .step) {
                if (s.currentFrame()) |frame| {
                    if (frame.file) |file| {
                        if (std.mem.endsWith(u8, file, "imported.nix")) {
                            self.imported_step = true;
                            return;
                        }
                    }
                }
            }
            try s.step(.into);
        }
    };
    var ctl: Ctl = .{};
    ev.setDebugUi(&ctl, Ctl.run);

    const result = try ev.evaluate(source);
    try std.testing.expect(ctl.imported_step);
    try std.testing.expectEqual(@as(i64, 42), (try ev.forceValue(result)).asInt());
}

test "repeated debug evaluations replay memoized imports for stepping" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "replay.nix",
        .data = "{ value = 42; }\n",
    });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const file_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "replay.nix",
    });
    defer std.testing.allocator.free(file_path);
    const source = try std.fmt.allocPrint(std.testing.allocator, "(import {s}).value", .{file_path});
    defer std.testing.allocator.free(source);

    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 1 });
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    const Ctl = struct {
        imported_hits: usize = 0,
        pauses_this_run: usize = 0,
        stepping: bool = false,

        fn run(ctx: *anyopaque, s: *DebugSession) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            s.clearStep();
            self.pauses_this_run += 1;
            try std.testing.expect(self.pauses_this_run < 8);
            if (!self.stepping) return;
            if (s.reason == .step) {
                if (s.currentFrame()) |frame| {
                    if (frame.file) |file| {
                        if (std.mem.endsWith(u8, file, "replay.nix")) {
                            self.imported_hits += 1;
                            return;
                        }
                    }
                }
            }
            try s.step(.into);
        }
    };
    var ctl: Ctl = .{};
    ev.setDebugUi(&ctl, Ctl.run);

    // First run continues from entry and warms the ordinary import memo.
    const first = try ev.debugWithScopeResult(source, null);
    try std.testing.expectEqual(@as(i64, 42), (try ev.forceValue(first.value)).asInt());
    try std.testing.expectEqual(@as(usize, 0), ctl.imported_hits);
    const chunks_after_first = ev.chunkRegistry().count();

    // Step-into must replay the import even though the ordinary result is
    // cached, and a later debug session must be replayable again.
    ctl.stepping = true;
    ctl.pauses_this_run = 0;
    const second = try ev.debugWithScopeResult(source, null);
    try std.testing.expectEqual(@as(i64, 42), (try ev.forceValue(second.value)).asInt());
    try std.testing.expectEqual(@as(usize, 1), ctl.imported_hits);
    try std.testing.expectEqual(chunks_after_first, ev.chunkRegistry().count());

    ctl.pauses_this_run = 0;
    const third = try ev.debugWithScopeResult(source, null);
    try std.testing.expectEqual(@as(i64, 42), (try ev.forceValue(third.value)).asInt());
    try std.testing.expectEqual(@as(usize, 2), ctl.imported_hits);
    try std.testing.expectEqual(chunks_after_first, ev.chunkRegistry().count());
}

test "pending import breakpoint preserves the parent stack and finish returns to it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "pending.nix",
        .data = "{ value = 41; }\n",
    });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const file_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "pending.nix",
    });
    defer std.testing.allocator.free(file_path);
    const source = try std.fmt.allocPrint(std.testing.allocator, "(import {s}).value + 1", .{file_path});
    defer std.testing.allocator.free(source);

    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 1 });
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    const Ctl = struct {
        state: enum { entry, awaiting_import, finishing, returned } = .entry,
        imported_frames: usize = 0,

        fn run(ctx: *anyopaque, s: *DebugSession) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            s.clearStep();
            switch (self.state) {
                .entry => {
                    try std.testing.expectEqual(eval_mod.BreakReason.entry, s.reason);
                    const set = try s.setBreakpoint("pending.nix", 1);
                    try std.testing.expect(set.pending);
                    try std.testing.expectEqual(@as(usize, 0), set.sites);
                    self.state = .awaiting_import;
                    try s.step(.into);
                },
                .awaiting_import => {
                    if (s.reason == .step) {
                        try s.step(.into);
                        return;
                    }
                    try std.testing.expectEqual(eval_mod.BreakReason.line_breakpoint, s.reason);
                    const current = s.currentFrame().?;
                    try std.testing.expect(current.file != null);
                    try std.testing.expect(std.mem.endsWith(u8, current.file.?, "pending.nix"));
                    self.imported_frames = s.frameCount();
                    try std.testing.expect(self.imported_frames >= 2);
                    try std.testing.expect(s.frame(0).file == null);
                    self.state = .finishing;
                    try s.step(.out);
                },
                .finishing => {
                    try std.testing.expectEqual(eval_mod.BreakReason.return_step, s.reason);
                    try std.testing.expectEqual(.attrs, s.value.kind());
                    try std.testing.expect(s.currentFrame().?.file == null);
                    try std.testing.expect(s.frameCount() < self.imported_frames);
                    self.state = .returned;
                },
                .returned => return error.TestUnexpectedResult,
            }
        }
    };
    var ctl: Ctl = .{};
    ev.setDebugUi(&ctl, Ctl.run);

    const result = try ev.debugWithScopeResult(source, null);
    try std.testing.expectEqual(.returned, ctl.state);
    try std.testing.expectEqual(@as(i64, 42), (try ev.forceValue(result.value)).asInt());
}

test "finish pauses in the caller with the returned value" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 1 });
    defer ev.deinit();

    const Ctl = struct {
        state: enum { at_break, forced_argument, returned } = .at_break,
        frames_before: usize = 0,
        saw_return: bool = false,

        fn run(ctx: *anyopaque, s: *DebugSession) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            s.clearStep();
            switch (self.state) {
                .at_break => {
                    try std.testing.expectEqual(eval_mod.BreakReason.break_builtin, s.reason);
                    self.frames_before = s.frameCount();
                    self.state = .forced_argument;
                    try s.step(.out);
                },
                .forced_argument => {
                    // `x` was being forced for builtins.break: its passthrough
                    // frame returns first, before the surrounding function.
                    try std.testing.expectEqual(eval_mod.BreakReason.return_step, s.reason);
                    try std.testing.expect(s.frameCount() < self.frames_before);
                    try std.testing.expectEqual(@as(i64, 41), s.value.asInt());
                    self.frames_before = s.frameCount();
                    self.state = .returned;
                    try s.step(.out);
                },
                .returned => {
                    try std.testing.expectEqual(eval_mod.BreakReason.return_step, s.reason);
                    try std.testing.expect(s.frameCount() < self.frames_before);
                    try std.testing.expectEqual(@as(i64, 42), s.value.asInt());
                    var text: [32]u8 = undefined;
                    var writer: std.Io.Writer = .fixed(&text);
                    try s.writeValueSummary(&writer, s.value);
                    try std.testing.expectEqualStrings("int 42", text[0..writer.end]);
                    self.saw_return = true;
                },
            }
        }
    };
    var ctl: Ctl = .{};
    ev.setDebugUi(&ctl, Ctl.run);

    const source = "let f = x: builtins.seq (builtins.break x) (x + 1); in (f 41) + 0";
    const result = try ev.evaluatePath(source, "return-step.nix");
    try std.testing.expect(ctl.saw_return);
    try std.testing.expectEqual(@as(i64, 42), (try ev.forceValue(result)).asInt());
}

test "clearStep after a step leaves no patched bytecode behind" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 1 });
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
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 1 });
    defer ev.deinit();
    var probe: Probe = .{ .return_error = error.DebuggerAbort };
    probe.install(&ev);

    try std.testing.expectError(error.DebuggerAbort, ev.evaluate("builtins.break 1"));
    try std.testing.expectEqual(@as(usize, 1), probe.hits);
}
