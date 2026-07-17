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

pub const BuildInput = struct {
    source: eval_support.Source,
};

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

    fn numberedName(self: *OrderedPrinter, base: []const u8, index: usize) ?[]u8 {
        return if (index == 0)
            self.allocator.dupe(u8, base) catch null
        else
            std.fmt.allocPrint(self.allocator, "{s}-{d}", .{ base, index + 1 }) catch null;
    }

    fn linkOutput(self: *OrderedPrinter, index: usize, target: []const u8) void {
        const base = self.options.add_root orelse (if (self.options.no_link) return else (self.options.out_link orelse "result"));
        const name = self.numberedName(base, index) orelse return;
        defer self.allocator.free(name);
        const indirect = self.options.add_root == null or self.options.indirect;
        linkRoot(self.io, self.allocator, self.ev, name, target, indirect);
    }

    fn linkDrv(self: *OrderedPrinter, index: usize, target: []const u8) void {
        if (!self.options.add_drv_link) return;
        const name = self.numberedName(self.options.drv_link orelse "derivation", index) orelse return;
        defer self.allocator.free(name);
        makeLink(self.io, name, target) catch |err| {
            std.debug.print("warning: could not create ./{s}: {s}\n", .{ name, @errorName(err) });
        };
    }
};

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
    var progress = EvalProgress.init(io, terminal.show_progress);
    if (terminal.show_progress) ev.setProgressSink(progress.sink());
    ev.progressSessionBegin("build inputs");
    ev.startProgressSampler();
    var progress_closed = false;
    defer if (!progress_closed) {
        ev.stopProgressSampler();
        ev.progressSessionEnd();
        progress.deinit(false);
    };

    var build_progress_state = build_progress.BuildProgress.init(allocator, &progress);
    defer build_progress_state.deinit();
    const sink = if (terminal.show_progress) build_progress_state.sink() else null;

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
    ev.stopProgressSampler();
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
    var progress = EvalProgress.init(io, terminal.show_progress);
    var torn_down = false;
    defer if (!torn_down) progress.deinit(false);
    if (terminal.show_progress) ev.setProgressSink(progress.sink());
    ev.progressSessionBegin(eval_support.sourceLabel(source_arg));
    ev.startProgressSampler();

    const value = ev.evaluatePathAt(source.text, source.base_path, eval_support.sourcePathOf(source_arg, source)) catch |err| {
        ev.stopProgressSampler();
        ev.progressSessionEnd();
        return .{ .failed = try eval_support.storeOrEvalFailure(io, terminal.use_color, options.show_trace, ev, source.text, err) };
    };
    const drv_path = (ev.derivationDrvPath(value) catch |err| {
        ev.stopProgressSampler();
        ev.progressSessionEnd();
        return .{ .failed = try eval_support.storeOrEvalFailure(io, terminal.use_color, options.show_trace, ev, source.text, err) };
    }) orelse {
        ev.stopProgressSampler();
        ev.progressSessionEnd();
        std.debug.print("error: that did not evaluate to a derivation\n", .{});
        return .{ .failed = 1 };
    };
    const out_path = (try ev.derivationOutPath(value)) orelse drv_path;
    const program: ?[]const u8 = if (want_program) ((try ev.derivationProgram(value)) orelse {
        ev.stopProgressSampler();
        ev.progressSessionEnd();
        std.debug.print("error: could not determine a program name to run\n", .{});
        return .{ .failed = 1 };
    }) else null;

    ev.stopProgressSampler();
    const derived = try std.fmt.allocPrint(allocator, "{s}!*", .{drv_path});
    defer allocator.free(derived);
    var realized: Realized = .{
        .drv_path = try allocator.dupe(u8, drv_path),
        .out_path = try allocator.dupe(u8, out_path),
        .program = if (program) |name| try allocator.dupe(u8, name) else null,
    };
    errdefer realized.deinit(allocator);

    var build_progress_state = build_progress.BuildProgress.init(allocator, &progress);
    const build_sink = if (terminal.show_progress) build_progress_state.sink() else null;
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
