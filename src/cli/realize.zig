//! Shared evaluation-to-build workflow for realizing CLI commands.

const std = @import("std");
const Engine = @import("expr").Engine;
const args = @import("args.zig");
const setup = @import("setup.zig");
const eval_support = @import("eval_support.zig");
const build_progress = @import("build_progress.zig");
const presentation = @import("presentation.zig");
const render = @import("render.zig");
const stats = @import("stats.zig");
const EvalProgress = @import("progress.zig").EvalProgress;

pub const Realized = struct {
    drv_path: []const u8,
    out_path: []const u8,
    program: ?[]const u8 = null,
    /// Set when the installable is a flake `app` (`{ type = "app"; program; }`):
    /// the absolute program path to exec directly, instead of
    /// `<out_path>/bin/<program>`.
    app_program: ?[]const u8 = null,

    fn initCopy(
        allocator: std.mem.Allocator,
        drv_path: []const u8,
        out_path: []const u8,
        program: ?[]const u8,
        app_program: ?[]const u8,
    ) !Realized {
        const owned_drv_path = try allocator.dupe(u8, drv_path);
        errdefer allocator.free(owned_drv_path);
        const owned_out_path = try allocator.dupe(u8, out_path);
        errdefer allocator.free(owned_out_path);
        const owned_program = if (program) |value| try allocator.dupe(u8, value) else null;
        errdefer if (owned_program) |value| allocator.free(value);
        const owned_app_program = if (app_program) |value| try allocator.dupe(u8, value) else null;
        errdefer if (owned_app_program) |value| allocator.free(value);
        return .{
            .drv_path = owned_drv_path,
            .out_path = owned_out_path,
            .program = owned_program,
            .app_program = owned_app_program,
        };
    }

    pub fn deinit(self: Realized, allocator: std.mem.Allocator) void {
        allocator.free(self.drv_path);
        allocator.free(self.out_path);
        if (self.program) |program| allocator.free(program);
        if (self.app_program) |program| allocator.free(program);
    }
};

pub const Result = union(enum) { ok: Realized, failed: u8 };

pub const BuildInput = eval_support.LoadedInput;

const FailureStage = enum { none, evaluation, derivation, closure };

const BuildSlot = struct {
    request: Engine.AsyncBuildRequest = undefined,
    progress_operation: build_progress.Operation = undefined,
    request_paths: [1][]const u8 = undefined,
    drv_path: ?[]u8 = null,
    out_path: ?[]u8 = null,
    derived: ?[]u8 = null,
    evaluation_failure: ?[]u8 = null,
    build_failure: ?anyerror = null,
    failure_stage: FailureStage = .none,

    fn deinit(self: *BuildSlot, allocator: std.mem.Allocator) void {
        if (self.drv_path) |path| allocator.free(path);
        if (self.out_path) |path| allocator.free(path);
        if (self.derived) |path| allocator.free(path);
        if (self.evaluation_failure) |text| allocator.free(text);
    }
};

const Pipeline = struct {
    allocator: std.mem.Allocator,
    ev: *Engine,
    slots: []BuildSlot,
    inputs: []const BuildInput,
    use_color: bool,
    show_trace: bool,

    fn complete(raw: *anyopaque, index: usize, value: ?@import("runtime").Value, failure: ?Engine.ParallelFailure) void {
        const self: *Pipeline = @ptrCast(@alignCast(raw));
        const slot = &self.slots[index];
        if (failure) |failed| {
            slot.evaluation_failure = render.captureEvalFailure(
                self.allocator,
                self.use_color,
                self.show_trace,
                self.ev,
                self.inputs[index].source.slice(),
                failed,
            ) catch null;
            return self.fail(slot, .evaluation, failed.err);
        }

        const paths = (self.ev.derivationBuildPaths(value.?) catch |err| return self.fail(slot, .derivation, err)) orelse
            return self.fail(slot, .derivation, error.NotDerivation);
        const drv = paths.drv_path;
        const out = paths.out_path;

        self.ev.ensureDerivationClosure(drv) catch |err| return self.fail(slot, .closure, err);
        slot.drv_path = self.allocator.dupe(u8, drv) catch return self.fail(slot, .closure, error.OutOfMemory);
        slot.out_path = self.allocator.dupe(u8, out) catch return self.fail(slot, .closure, error.OutOfMemory);
        slot.derived = std.fmt.allocPrint(self.allocator, "{s}!*", .{drv}) catch return self.fail(slot, .closure, error.OutOfMemory);
        slot.request_paths[0] = slot.derived.?;
        self.ev.submitBuild(&slot.request);
    }

    fn fail(_: *Pipeline, slot: *BuildSlot, stage: FailureStage, err: anyerror) void {
        slot.failure_stage = stage;
        slot.request.fail(err);
    }
};

const OrderedPrinter = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    ev: *Engine,
    state_dir: []const u8,
    options: *const args.Options,
    slots: []BuildSlot,
    use_color: bool,
    failed: bool = false,

    fn awaitAll(self: *OrderedPrinter) void {
        for (self.slots) |*slot| {
            slot.request.wait() catch |err| {
                self.failed = true;
                slot.build_failure = err;
                slot.progress_operation.finish(false);
                continue;
            };
            slot.progress_operation.finish(true);
        }
    }

    fn run(self: *OrderedPrinter) void {
        for (self.slots, 0..) |*slot, index| {
            if (slot.build_failure) |err| {
                if (slot.evaluation_failure) |text| {
                    self.writeFailure(text);
                    continue;
                }
                const stage = switch (slot.failure_stage) {
                    .evaluation => "evaluation",
                    .derivation => "derivation selection",
                    .closure => "derivation materialization",
                    .none => "build",
                };
                if (err == error.NotDerivation) {
                    render.messageError(self.io, self.use_color, "input {d} did not evaluate to a derivation", .{index + 1});
                } else {
                    if (slot.failure_stage == .none) {
                        if (self.ev.lastStoreError()) |message| {
                            render.messageError(self.io, self.use_color, "input {d} build failed: {s}", .{ index + 1, message });
                            continue;
                        }
                    }
                    render.messageError(self.io, self.use_color, "input {d} {s} failed: {s}", .{ index + 1, stage, @errorName(err) });
                }
                continue;
            }

            const out_path = slot.out_path.?;
            self.linkOutput(index, out_path);
            self.linkDrv(index, slot.drv_path.?);

            var buffer: [4096]u8 = undefined;
            var stdout = std.Io.File.stdout().writerStreaming(self.io, &buffer);
            stdout.interface.print("{s}\n", .{out_path}) catch {
                self.failed = true;
                continue;
            };
            stdout.interface.flush() catch {
                self.failed = true;
            };
        }
    }

    fn writeFailure(self: *OrderedPrinter, text: []const u8) void {
        var stderr_buffer: [4096]u8 = undefined;
        var stderr = presentation.lockStderr(self.io, &stderr_buffer) catch return;
        defer stderr.deinit();
        stderr.writer().writeAll(text) catch return;
        stderr.flush() catch {};
    }

    fn linkOutput(self: *OrderedPrinter, index: usize, target: []const u8) void {
        const base = self.options.add_root orelse (if (self.options.no_link) return else (self.options.out_link orelse "result"));
        const name = numberedName(self.allocator, base, index) catch return;
        defer self.allocator.free(name);
        const indirect = self.options.add_root == null or self.options.indirect;
        linkRoot(self.io, self.allocator, self.ev, self.state_dir, name, target, indirect);
    }

    fn linkDrv(self: *OrderedPrinter, index: usize, target: []const u8) void {
        if (!self.options.add_drv_link) return;
        const name = numberedName(self.allocator, self.options.drv_link orelse "derivation", index) catch return;
        defer self.allocator.free(name);
        makeLink(self.io, name, target) catch |err| {
            std.debug.print("warning: could not create ./{s}: {s}\n", .{ name, @errorName(err) });
        };
    }
};

pub fn numberedName(allocator: std.mem.Allocator, base: []const u8, index: usize) ![]u8 {
    return if (index == 0)
        allocator.dupe(u8, base)
    else
        std.fmt.allocPrint(allocator, "{s}-{d}", .{ base, index + 1 });
}

pub fn makeLink(io: std.Io, name: []const u8, target: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    cwd.deleteFile(io, name) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try cwd.symLink(io, target, name, .{});
}

pub fn linkRoot(io: std.Io, allocator: std.mem.Allocator, ev: *Engine, state_dir: []const u8, name: []const u8, target: []const u8, indirect: bool) void {
    makeLink(io, name, target) catch |err| {
        std.debug.print("warning: could not create {s}: {s}\n", .{ name, @errorName(err) });
        return;
    };
    const abs = absolutePath(io, allocator, name) catch |err| {
        std.debug.print("warning: could not resolve {s}: {s}\n", .{ name, @errorName(err) });
        return;
    };
    defer allocator.free(abs);
    if (!indirect) {
        if (!isDirectRootPath(state_dir, abs))
            std.debug.print("warning: {s} is not in the gcroots directory, so it will not be an effective GC root (pass --indirect)\n", .{abs});
        return;
    }
    ev.addIndirectRoot(abs, target) catch |err| {
        std.debug.print("warning: could not register GC root {s}: {s}\n", .{ abs, @errorName(err) });
    };
}

fn isDirectRootPath(state_dir: []const u8, path: []const u8) bool {
    const state = std.mem.trimEnd(u8, state_dir, "/");
    if (!std.mem.startsWith(u8, path, state)) return false;
    const rest = path[state.len..];
    return std.mem.startsWith(u8, rest, "/gcroots/");
}

fn absolutePath(io: std.Io, allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(name)) return std.fs.path.resolve(allocator, &.{name});
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &.{ cwd, name });
}

/// Evaluate independent build inputs on separate demand fibers and enqueue each
/// build as soon as its derivation closure is materialized. Once evaluator
/// workers are quiescent, print completed outputs and failures in input order.
pub fn realizeMany(
    allocator: std.mem.Allocator,
    io: std.Io,
    ev: *Engine,
    release_action: ?@import("expr").ReleaseAction,
    terminal: setup.Terminal,
    state_dir: []const u8,
    options: *const args.Options,
    progress: *EvalProgress,
    inputs: []const BuildInput,
) !u8 {
    var build_progress_state = build_progress.BuildProgress.init(allocator, io, terminal.color_depth, terminal.log_progress, progress);
    var progress_torn_down = false;
    defer if (!progress_torn_down) build_progress_state.deinit();
    // Keep typed daemon sinks active even when progress is disabled: they
    // still own build-log labeling and terminal-safe color boundaries.

    const slots = try allocator.alloc(BuildSlot, inputs.len);
    defer allocator.free(slots);
    for (slots) |*slot| {
        slot.* = .{};
        slot.progress_operation = build_progress_state.operation();
        slot.request = Engine.AsyncBuildRequest.init(slot.request_paths[0..], slot.progress_operation.sink(), eval_support.buildMode(options));
    }
    defer for (slots) |*slot| slot.deinit(allocator);

    const parallel_inputs = try allocator.alloc(Engine.ParallelInput, inputs.len);
    defer allocator.free(parallel_inputs);
    for (inputs, parallel_inputs) |input, *parallel| parallel.* = .{
        .source = input.source.slice(),
        .base_path = input.source.base_path,
        .source_path = input.source.abs_path,
    };
    var pipeline: Pipeline = .{
        .allocator = allocator,
        .ev = ev,
        .slots = slots,
        .inputs = inputs,
        .use_color = terminal.use_color,
        .show_trace = options.show_trace,
    };
    var printer: OrderedPrinter = .{
        .allocator = allocator,
        .io = io,
        .ev = ev,
        .state_dir = state_dir,
        .options = options,
        .slots = slots,
        .use_color = terminal.use_color,
    };
    ev.evaluatePathsParallel(parallel_inputs, .{ .context = &pipeline, .complete_fn = Pipeline.complete });

    // Every demand fiber has either enqueued its build or completed its request
    // with an error. Nothing below reads language values.
    if (options.stats) stats.report(ev);
    ev.finishEvaluation();
    if (release_action) |action| action.run(action.context);

    printer.awaitAll();
    build_progress_state.deinit();
    progress_torn_down = true;
    printer.run();
    return if (printer.failed) 1 else 0;
}

/// Evaluate and instantiate build inputs, then ask the daemon for its missing
/// path plan. No build/substitution operation is issued and no result links are
/// created.
pub fn dryRunMany(
    allocator: std.mem.Allocator,
    io: std.Io,
    ev: *Engine,
    release_action: ?@import("expr").ReleaseAction,
    terminal: setup.Terminal,
    options: *const args.Options,
    inputs: []const BuildInput,
) !u8 {
    const derived = try allocator.alloc([]const u8, inputs.len);
    var derived_count: usize = 0;
    defer {
        for (derived[0..derived_count]) |path| allocator.free(path);
        allocator.free(derived);
    }

    for (inputs, 0..) |input, index| {
        const value = ev.evaluatePathAt(input.source.slice(), input.source.base_path, input.source.abs_path) catch |err| {
            _ = try eval_support.storeOrEvalFailure(io, terminal.use_color, options.show_trace, ev, input.source.slice(), err);
            return 1;
        };
        const paths = (ev.derivationBuildPaths(value) catch |err| {
            _ = try eval_support.storeOrEvalFailure(io, terminal.use_color, options.show_trace, ev, input.source.slice(), err);
            return 1;
        }) orelse {
            std.debug.print("error: input {d} did not evaluate to a derivation\n", .{index + 1});
            return 1;
        };
        derived[derived_count] = try std.fmt.allocPrint(allocator, "{s}!*", .{paths.drv_path});
        derived_count += 1;
    }

    if (options.stats) stats.report(ev);
    var session = ev.beginBuildPhase(derived[0..derived_count], release_action) catch |err| {
        return eval_support.buildFailure(io, terminal.use_color, ev.lastStoreError(), err);
    };
    defer session.deinit();
    var plan = session.queryMissing(derived[0..derived_count]) catch |err| {
        return eval_support.buildFailure(io, terminal.use_color, session.lastStoreError(), err);
    };
    defer plan.deinit();

    writeMissingGroup("derivations will be built", plan.will_build);
    if (plan.will_substitute.len != 0) {
        std.debug.print("these {d} paths will be fetched ({d} bytes download, {d} bytes unpacked):\n", .{
            plan.will_substitute.len,
            plan.download_size,
            plan.nar_size,
        });
        for (plan.will_substitute) |path| std.debug.print("  {s}\n", .{path});
    }
    writeMissingGroup("paths are unknown", plan.unknown);
    return if (plan.unknown.len == 0) 0 else 1;
}

fn writeMissingGroup(label: []const u8, paths: []const []const u8) void {
    if (paths.len == 0) return;
    std.debug.print("these {d} {s}:\n", .{ paths.len, label });
    for (paths) |path| std.debug.print("  {s}\n", .{path});
}

const InterleaveRendezvous = struct {
    blocked_subject: []const u8,
    release_subject: []const u8,
    blocked_seen: std.atomic.Value(bool) = .init(false),
    release_seen: std.atomic.Value(bool) = .init(false),
    blocked_crossed: std.atomic.Value(bool) = .init(false),
    release_crossed: std.atomic.Value(bool) = .init(false),
    timed_out: std.atomic.Value(bool) = .init(false),

    fn hook(raw: *anyopaque, subject: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (std.mem.eql(u8, subject, self.blocked_subject)) {
            self.blocked_seen.store(true, .release);
            if (self.waitFor(&self.release_seen)) self.blocked_crossed.store(true, .release);
        } else if (std.mem.eql(u8, subject, self.release_subject)) {
            self.release_seen.store(true, .release);
            if (self.waitFor(&self.blocked_seen)) self.release_crossed.store(true, .release);
        }
    }

    /// The rendezvous itself is event-driven. This bounded poll is only a
    /// deadlock watchdog so a regression fails in finite time instead of
    /// hanging the test runner forever.
    fn waitFor(self: *@This(), flag: *std.atomic.Value(bool)) bool {
        for (0..5_000) |_| {
            if (flag.load(.acquire)) return true;
            @import("base").sync.sleepNs(std.time.ns_per_ms);
        }
        self.timed_out.store(true, .release);
        return false;
    }
};

fn proveBuildStartsBeforeOtherEvaluationFinishes(slow_index: usize) !void {
    const testing = std.testing;
    const FakeDaemon = @import("store").realization.testing.FakeDaemon;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(testing.io, "store", .default_dir);
    const cwd = try std.process.currentPathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(cwd);
    const store_dir = try std.fs.path.resolve(testing.allocator, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "store" });
    defer testing.allocator.free(store_dir);

    const fake = try FakeDaemon.start(testing.allocator, testing.io);
    defer fake.deinit();
    var ev = try Engine.init(testing.allocator, .{ .worker_count = 2 });
    defer ev.deinit();
    ev.setFileIo(testing.io);
    ev.store.realization.store_dir = store_dir;
    ev.store.realization.setDaemonSocketBorrowedForTest(fake.socketPath());
    ev.store.daemon_runtime.pool_workers = 2;
    ev.enableStoreWrites();

    const gate_source =
        \\builtins.derivation {
        \\  name = "pipeline-eval-gate";
        \\  system = "x86_64-linux";
        \\  builder = "/bin/sh";
        \\}
    ;
    const quick_source =
        \\builtins.derivation {
        \\  name = "pipeline-quick-terminal";
        \\  system = "x86_64-linux";
        \\  builder = "/bin/sh";
        \\}
    ;
    const slow_source =
        \\let
        \\  gate = builtins.derivation {
        \\    name = "pipeline-eval-gate";
        \\    system = "x86_64-linux";
        \\    builder = "/bin/sh";
        \\  };
        \\  terminal = builtins.derivation {
        \\    name = "pipeline-slow-terminal";
        \\    system = "x86_64-linux";
        \\    builder = "/bin/sh";
        \\  };
        \\in builtins.seq (builtins.readFile gate.outPath) terminal
    ;

    // Compute the exact IFD and quick terminal subjects without building them.
    const gate_value = try ev.evaluate(gate_source);
    const gate_paths = (try ev.derivationBuildPaths(gate_value)) orelse return error.NotDerivation;
    const quick_value = try ev.evaluate(quick_source);
    const quick_paths = (try ev.derivationBuildPaths(quick_value)) orelse return error.NotDerivation;
    const blocked_subject = try std.fmt.allocPrint(testing.allocator, "{s}!out", .{gate_paths.drv_path});
    defer testing.allocator.free(blocked_subject);
    const release_subject = try std.fmt.allocPrint(testing.allocator, "{s}!*", .{quick_paths.drv_path});
    defer testing.allocator.free(release_subject);
    try fake.registerBuildFile(blocked_subject, gate_paths.out_path, "gate opened\n");

    var rendezvous: InterleaveRendezvous = .{
        .blocked_subject = blocked_subject,
        .release_subject = release_subject,
    };
    fake.setBuildHook(.{ .context = &rendezvous, .run = InterleaveRendezvous.hook });
    defer fake.setBuildHook(null);

    var inputs: [2]BuildInput = undefined;
    const quick_index = 1 - slow_index;
    inputs[slow_index] = .{
        .source_arg = .{ .expr = slow_source },
        .source = .{ .text = .{ .borrowed = slow_source } },
    };
    inputs[quick_index] = .{
        .source_arg = .{ .expr = quick_source },
        .source = .{ .text = .{ .borrowed = quick_source } },
    };

    var slots: [2]BuildSlot = .{ .{}, .{} };
    for (&slots) |*slot| {
        slot.request = Engine.AsyncBuildRequest.init(slot.request_paths[0..], null, .normal);
    }
    defer for (&slots) |*slot| slot.deinit(testing.allocator);
    const parallel_inputs = [_]Engine.ParallelInput{
        .{ .source = inputs[0].source.slice() },
        .{ .source = inputs[1].source.slice() },
    };
    var pipeline: Pipeline = .{
        .allocator = testing.allocator,
        .ev = &ev,
        .slots = &slots,
        .inputs = &inputs,
        .use_color = false,
        .show_trace = false,
    };
    ev.evaluatePathsParallel(&parallel_inputs, .{ .context = &pipeline, .complete_fn = Pipeline.complete });
    for (&slots) |*slot| try slot.request.wait();

    try testing.expect(rendezvous.blocked_seen.load(.acquire));
    try testing.expect(rendezvous.release_seen.load(.acquire));
    try testing.expect(rendezvous.blocked_crossed.load(.acquire));
    try testing.expect(rendezvous.release_crossed.load(.acquire));
    try testing.expect(!rendezvous.timed_out.load(.acquire));
}

test "build 1 starts before slow evaluation 2 finishes" {
    try proveBuildStartsBeforeOtherEvaluationFinishes(1);
}

test "build 2 starts before slow evaluation 1 finishes" {
    try proveBuildStartsBeforeOtherEvaluationFinishes(0);
}

test "direct GC roots follow NIX_STATE_DIR with path boundaries" {
    try std.testing.expect(isDirectRootPath("/custom/state", "/custom/state/gcroots/project/result"));
    try std.testing.expect(isDirectRootPath("/custom/state/", "/custom/state/gcroots/result"));
    try std.testing.expect(!isDirectRootPath("/custom/state", "/custom/state/gcroots-other/result"));
    try std.testing.expect(!isDirectRootPath("/custom/state", "/custom/stateful/gcroots/result"));
}

pub fn realize(
    allocator: std.mem.Allocator,
    io: std.Io,
    ev: *Engine,
    release_action: ?@import("expr").ReleaseAction,
    terminal: setup.Terminal,
    options: *const args.Options,
    source_arg: args.SourceArg,
    source: eval_support.Source,
    want_program: bool,
) !Result {
    var progress = EvalProgress.init(io, ev.basePath() orelse "", terminal.log_progress, terminal.color_depth, options.verbose);
    var torn_down = false;
    defer if (!torn_down) progress.deinit(false);
    if (terminal.progressEnabled()) ev.setObserver(progress.observer());

    const value = ev.evaluatePathAt(source.slice(), source.base_path, eval_support.sourcePathOf(source_arg, source)) catch |err| {
        return .{ .failed = try eval_support.storeOrEvalFailure(io, terminal.use_color, options.show_trace, ev, source.slice(), err) };
    };

    // A flake `app` (`{ type = "app"; program = …; }`): build the derivation in
    // the program's context, then exec the program path directly (not
    // `$out/bin/<name>`). Strings are duped before the build phase releases the
    // language heap.
    if (want_program) {
        if (try ev.appProgram(value)) |app| {
            const app_drv = app.drv_path orelse "";
            const realized = try Realized.initCopy(allocator, app_drv, "", null, app.program);
            var transfer_realized = false;
            defer if (!transfer_realized) realized.deinit(allocator);
            if (app.drv_path != null) {
                const derived_app = try std.fmt.allocPrint(allocator, "{s}!*", .{realized.drv_path});
                defer allocator.free(derived_app);
                if (options.stats) stats.report(ev);
                var bps = build_progress.BuildProgress.init(allocator, io, terminal.color_depth, terminal.log_progress, &progress);
                var bop = bps.operation();
                var session = ev.beginBuildPhase(&.{derived_app}, release_action) catch |err| {
                    bop.finish(false);
                    bps.deinit();
                    return .{ .failed = eval_support.buildFailure(io, terminal.use_color, ev.lastStoreError(), err) };
                };
                defer session.deinit();
                session.buildPaths(&.{derived_app}, bop.sink(), eval_support.buildMode(options)) catch |err| {
                    bop.finish(false);
                    bps.deinit();
                    return .{ .failed = eval_support.buildFailure(io, terminal.use_color, session.lastStoreError(), err) };
                };
                bop.finish(true);
                bps.deinit();
            }
            progress.deinit(true);
            torn_down = true;
            transfer_realized = true;
            return .{ .ok = realized };
        }
    }

    const drv_path = (ev.derivationDrvPath(value) catch |err| {
        return .{ .failed = try eval_support.storeOrEvalFailure(io, terminal.use_color, options.show_trace, ev, source.slice(), err) };
    }) orelse {
        std.debug.print("error: that did not evaluate to a derivation\n", .{});
        return .{ .failed = 1 };
    };
    const out_path = (try ev.derivationOutPath(value)) orelse drv_path;
    const program: ?[]const u8 = if (want_program) ((try ev.derivationProgram(value)) orelse {
        std.debug.print("error: could not determine a program name to run\n", .{});
        return .{ .failed = 1 };
    }) else null;

    const derived = try std.fmt.allocPrint(allocator, "{s}!*", .{drv_path});
    defer allocator.free(derived);
    const realized = try Realized.initCopy(allocator, drv_path, out_path, program, null);
    var transfer_realized = false;
    defer if (!transfer_realized) realized.deinit(allocator);

    if (options.stats) stats.report(ev);
    var build_progress_state = build_progress.BuildProgress.init(allocator, io, terminal.color_depth, terminal.log_progress, &progress);
    var build_operation = build_progress_state.operation();
    const build_sink = build_operation.sink();
    var build_session = ev.beginBuildPhase(&.{derived}, release_action) catch |err| {
        build_operation.finish(false);
        build_progress_state.deinit();
        return .{ .failed = eval_support.buildFailure(io, terminal.use_color, ev.lastStoreError(), err) };
    };
    defer build_session.deinit();
    build_session.buildPaths(&.{derived}, build_sink, eval_support.buildMode(options)) catch |err| {
        build_operation.finish(false);
        build_progress_state.deinit();
        return .{ .failed = eval_support.buildFailure(io, terminal.use_color, build_session.lastStoreError(), err) };
    };
    build_operation.finish(true);
    build_progress_state.deinit();
    progress.deinit(true);
    torn_down = true;
    transfer_realized = true;
    return .{ .ok = realized };
}

fn checkRealizedAllocationFailures(allocator: std.mem.Allocator) !void {
    const realized = try Realized.initCopy(
        allocator,
        "/nix/store/example.drv",
        "/nix/store/example",
        "example",
        "/nix/store/example/bin/example",
    );
    defer realized.deinit(allocator);
}

test "realized output handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkRealizedAllocationFailures,
        .{},
    );
}
