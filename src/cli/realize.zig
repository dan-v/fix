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

    const value = ev.evaluatePath(source.text, eval_support.sourcePathOf(source_arg, source)) catch |err| {
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
