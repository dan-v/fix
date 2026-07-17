//! Shared evaluation-to-build workflow for realizing CLI commands.

const std = @import("std");
const Evaluator = @import("expr").Evaluator;
const args = @import("args.zig");
const setup = @import("setup.zig");
const eval_support = @import("eval_support.zig");
const build_progress = @import("build_progress.zig");
const EvalProgress = @import("progress.zig").EvalProgress;

pub const Realized = struct {
    drv_path: []const u8,
    out_path: []const u8,
    program: ?[]const u8 = null,

    pub fn deinit(self: Realized, allocator: std.mem.Allocator) void {
        allocator.free(self.drv_path);
        allocator.free(self.out_path);
        if (self.program) |program| allocator.free(program);
    }
};

pub const Result = union(enum) { ok: Realized, failed: u8 };

pub const BuildInput = eval_support.LoadedInput;

const FailureStage = enum { none, evaluation, derivation, closure };

const BuildSlot = struct {
    request: Evaluator.AsyncBuildRequest = undefined,
    request_paths: [1][]const u8 = undefined,
    drv_path: ?[]u8 = null,
    out_path: ?[]u8 = null,
    derived: ?[]u8 = null,
    failure_stage: FailureStage = .none,

    fn deinit(self: *BuildSlot, allocator: std.mem.Allocator) void {
        if (self.drv_path) |path| allocator.free(path);
        if (self.out_path) |path| allocator.free(path);
        if (self.derived) |path| allocator.free(path);
    }
};

const Pipeline = struct {
    allocator: std.mem.Allocator,
    ev: *Evaluator,
    slots: []BuildSlot,

    fn complete(raw: *anyopaque, index: usize, value: ?@import("runtime").Value, eval_err: ?anyerror) void {
        const self: *Pipeline = @ptrCast(@alignCast(raw));
        const slot = &self.slots[index];
        if (eval_err) |err| return self.fail(slot, .evaluation, err);

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
    ev: *Evaluator,
    options: args.Options,
    slots: []BuildSlot,
    failed: std.atomic.Value(bool) = .init(false),

    fn run(self: *OrderedPrinter) void {
        for (self.slots, 0..) |*slot, index| {
            slot.request.wait() catch |err| {
                self.failed.store(true, .release);
                const stage = switch (slot.failure_stage) {
                    .evaluation => "evaluation",
                    .derivation => "derivation selection",
                    .closure => "derivation materialization",
                    .none => "build",
                };
                if (err == error.NotDerivation) {
                    std.debug.print("error: input {d} did not evaluate to a derivation\n", .{index + 1});
                } else {
                    if (slot.failure_stage == .none) {
                        if (self.ev.lastStoreError()) |message| {
                            std.debug.print("error: input {d} build failed: {s}\n", .{ index + 1, message });
                            continue;
                        }
                    }
                    std.debug.print("error: input {d} {s} failed: {s}\n", .{ index + 1, stage, @errorName(err) });
                }
                continue;
            };

            const out_path = slot.out_path.?;
            self.linkOutput(index, out_path);
            self.linkDrv(index, slot.drv_path.?);

            var buffer: [4096]u8 = undefined;
            var stdout = std.Io.File.stdout().writerStreaming(self.io, &buffer);
            stdout.interface.print("{s}\n", .{out_path}) catch {
                self.failed.store(true, .release);
                continue;
            };
            stdout.interface.flush() catch self.failed.store(true, .release);
        }
    }

    fn linkOutput(self: *OrderedPrinter, index: usize, target: []const u8) void {
        const base = self.options.add_root orelse (if (self.options.no_link) return else (self.options.out_link orelse "result"));
        const name = numberedName(self.allocator, base, index) catch return;
        defer self.allocator.free(name);
        const indirect = self.options.add_root == null or self.options.indirect;
        linkRoot(self.io, self.allocator, self.ev, name, target, indirect);
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

pub fn linkRoot(io: std.Io, allocator: std.mem.Allocator, ev: *Evaluator, name: []const u8, target: []const u8, indirect: bool) void {
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
        if (!std.mem.startsWith(u8, abs, "/nix/var/nix/gcroots/"))
            std.debug.print("warning: {s} is not in the gcroots directory, so it will not be an effective GC root (pass --indirect)\n", .{abs});
        return;
    }
    ev.addIndirectRoot(abs) catch |err| {
        std.debug.print("warning: could not register GC root {s}: {s}\n", .{ abs, @errorName(err) });
    };
}

fn absolutePath(io: std.Io, allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(name)) return std.fs.path.resolve(allocator, &.{name});
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &.{ cwd, name });
}

/// Evaluate independent build inputs on separate demand fibers, enqueue each
/// build as soon as its derivation closure is materialized, and print completed
/// outputs in input order. Evaluation state is released immediately after the
/// final enqueue while daemon builds and ordered printing continue.
pub fn realizeMany(
    allocator: std.mem.Allocator,
    io: std.Io,
    ev: *Evaluator,
    release_action: ?@import("expr").ReleaseAction,
    terminal: setup.Terminal,
    options: args.Options,
    inputs: []const BuildInput,
) !u8 {
    var progress = EvalProgress.init(io, terminal.show_progress, terminal.log_progress, terminal.use_color);
    if (terminal.progressEnabled()) ev.setProgressSink(progress.sink());
    ev.progressSessionBegin("build inputs");
    var progress_closed = false;
    defer if (!progress_closed) {
        ev.progressSessionEnd();
        progress.deinit(false);
    };

    var build_progress_state = build_progress.BuildProgress.init(allocator, io, terminal.use_color, terminal.log_progress, &progress);
    defer build_progress_state.deinit();
    // Keep the typed daemon sink active even when progress is disabled: it
    // still owns build-log labeling and terminal-safe color boundaries.
    const sink = build_progress_state.sink();

    const slots = try allocator.alloc(BuildSlot, inputs.len);
    defer allocator.free(slots);
    for (slots) |*slot| {
        slot.* = .{};
        slot.request = Evaluator.AsyncBuildRequest.init(slot.request_paths[0..], sink, eval_support.buildMode(options));
    }
    defer for (slots) |*slot| slot.deinit(allocator);

    const parallel_inputs = try allocator.alloc(Evaluator.ParallelInput, inputs.len);
    defer allocator.free(parallel_inputs);
    for (inputs, parallel_inputs) |input, *parallel| parallel.* = .{
        .source = input.source.text,
        .base_path = input.source.base_path,
        .source_path = input.source.abs_path,
    };
    var pipeline: Pipeline = .{
        .allocator = allocator,
        .ev = ev,
        .slots = slots,
    };
    var printer: OrderedPrinter = .{ .allocator = allocator, .io = io, .ev = ev, .options = options, .slots = slots };
    const printer_thread = try std.Thread.spawn(.{}, OrderedPrinter.run, .{&printer});
    ev.evaluatePathsParallel(parallel_inputs, .{ .context = &pipeline, .complete_fn = Pipeline.complete });

    // Every demand fiber has either enqueued its build or completed its request
    // with an error. Nothing below reads language values.
    ev.releaseEvalState();
    if (release_action) |action| action.run(action.context);

    printer_thread.join();
    const ok = !printer.failed.load(.acquire);
    build_progress_state.deinit();
    ev.progressSessionEnd();
    progress.deinit(ok);
    progress_closed = true;
    return if (ok) 0 else 1;
}

/// Evaluate and instantiate build inputs, then ask the daemon for its missing
/// path plan. No build/substitution operation is issued and no result links are
/// created.
pub fn dryRunMany(
    allocator: std.mem.Allocator,
    io: std.Io,
    ev: *Evaluator,
    release_action: ?@import("expr").ReleaseAction,
    terminal: setup.Terminal,
    options: args.Options,
    inputs: []const BuildInput,
) !u8 {
    var progress = EvalProgress.init(io, terminal.show_progress, terminal.log_progress, terminal.use_color);
    var progress_ok = false;
    defer progress.deinit(progress_ok);
    if (terminal.progressEnabled()) ev.setProgressSink(progress.sink());
    ev.progressSessionBegin("dry-run inputs");
    defer ev.progressSessionEnd();

    const derived = try allocator.alloc([]const u8, inputs.len);
    var derived_count: usize = 0;
    defer {
        for (derived[0..derived_count]) |path| allocator.free(path);
        allocator.free(derived);
    }

    for (inputs, 0..) |input, index| {
        const value = ev.evaluatePathAt(input.source.text, input.source.base_path, input.source.abs_path) catch |err| {
            _ = try eval_support.storeOrEvalFailure(io, terminal.use_color, options.show_trace, ev, input.source.text, err);
            return 1;
        };
        const paths = (ev.derivationBuildPaths(value) catch |err| {
            _ = try eval_support.storeOrEvalFailure(io, terminal.use_color, options.show_trace, ev, input.source.text, err);
            return 1;
        }) orelse {
            std.debug.print("error: input {d} did not evaluate to a derivation\n", .{index + 1});
            return 1;
        };
        derived[derived_count] = try std.fmt.allocPrint(allocator, "{s}!*", .{paths.drv_path});
        derived_count += 1;
    }

    var session = ev.beginBuildPhase(derived[0..derived_count], release_action) catch |err| {
        return eval_support.buildFailure(ev.lastStoreError(), err);
    };
    defer session.deinit();
    var plan = session.queryMissing(derived[0..derived_count]) catch |err| {
        return eval_support.buildFailure(session.lastStoreError(), err);
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
    progress_ok = plan.unknown.len == 0;
    return if (progress_ok) 0 else 1;
}

fn writeMissingGroup(label: []const u8, paths: []const []const u8) void {
    if (paths.len == 0) return;
    std.debug.print("these {d} {s}:\n", .{ paths.len, label });
    for (paths) |path| std.debug.print("  {s}\n", .{path});
}

pub fn realize(
    allocator: std.mem.Allocator,
    io: std.Io,
    ev: *Evaluator,
    release_action: ?@import("expr").ReleaseAction,
    terminal: setup.Terminal,
    options: args.Options,
    source_arg: args.SourceArg,
    source: eval_support.Source,
    want_program: bool,
) !Result {
    var progress = EvalProgress.init(io, terminal.show_progress, terminal.log_progress, terminal.use_color);
    var torn_down = false;
    defer if (!torn_down) progress.deinit(false);
    if (terminal.progressEnabled()) ev.setProgressSink(progress.sink());
    ev.progressSessionBegin(eval_support.sourceLabel(source_arg));

    const value = ev.evaluatePathAt(source.text, source.base_path, eval_support.sourcePathOf(source_arg, source)) catch |err| {
        ev.progressSessionEnd();
        return .{ .failed = try eval_support.storeOrEvalFailure(io, terminal.use_color, options.show_trace, ev, source.text, err) };
    };
    const drv_path = (ev.derivationDrvPath(value) catch |err| {
        ev.progressSessionEnd();
        return .{ .failed = try eval_support.storeOrEvalFailure(io, terminal.use_color, options.show_trace, ev, source.text, err) };
    }) orelse {
        ev.progressSessionEnd();
        std.debug.print("error: that did not evaluate to a derivation\n", .{});
        return .{ .failed = 1 };
    };
    const out_path = (try ev.derivationOutPath(value)) orelse drv_path;
    const program: ?[]const u8 = if (want_program) ((try ev.derivationProgram(value)) orelse {
        ev.progressSessionEnd();
        std.debug.print("error: could not determine a program name to run\n", .{});
        return .{ .failed = 1 };
    }) else null;

    const derived = try std.fmt.allocPrint(allocator, "{s}!*", .{drv_path});
    defer allocator.free(derived);
    var realized: Realized = .{
        .drv_path = try allocator.dupe(u8, drv_path),
        .out_path = try allocator.dupe(u8, out_path),
        .program = if (program) |name| try allocator.dupe(u8, name) else null,
    };
    errdefer realized.deinit(allocator);

    var build_progress_state = build_progress.BuildProgress.init(allocator, io, terminal.use_color, terminal.log_progress, &progress);
    const build_sink = build_progress_state.sink();
    var build_session = ev.beginBuildPhase(&.{derived}, release_action) catch |err| {
        build_progress_state.deinit();
        ev.progressSessionEnd();
        return .{ .failed = eval_support.buildFailure(ev.lastStoreError(), err) };
    };
    defer build_session.deinit();
    build_session.buildPaths(&.{derived}, build_sink, eval_support.buildMode(options)) catch |err| {
        build_progress_state.deinit();
        ev.progressSessionEnd();
        return .{ .failed = eval_support.buildFailure(build_session.lastStoreError(), err) };
    };
    build_progress_state.deinit();
    ev.progressSessionEnd();
    progress.deinit(true);
    torn_down = true;
    return .{ .ok = realized };
}
