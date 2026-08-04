//! `fix run` — evaluate to a derivation, build it, and exec a program from its
//! output (`$out/bin/<mainProgram|pname|name>`), forwarding any args after `--`.
//! The nix run analogue.

const std = @import("std");
const engine = @import("expr");
const realization_workflow = @import("../realize.zig");
const args = @import("../args.zig");
const render = @import("../render.zig");
const setup = @import("../setup.zig");
const config_discovery = @import("../config_discovery.zig");
const eval_support = @import("../eval_support.zig");

const Engine = engine.Engine;

pub const synopsis =
    \\usage: fix run [options] [path | -E <expr> | --flake <installable>] [-- args...]
    \\
    \\evaluate to a derivation, build it, and run $out/bin/<program> (from
    \\meta.mainProgram, else pname, else name). Arguments after `--` are passed
    \\to the program. With no source, uses ./default.nix.
;

pub fn run(process: @import("../process_context.zig").ProcessContext, init: std.process.Init, args_iter: *std.process.Args.Iterator) !u8 {
    const allocator = process.allocator;
    var diag: args.Diag = .{};
    var options = args.parse(allocator, args_iter, null, .run, &diag) catch |err| switch (err) {
        error.Help => {
            args.writeHelp(init.io, synopsis, .run);
            return 0;
        },
        else => {
            render.usageError(init.io, init.environ_map, args.errorMessage(err), diag.offending, synopsis);
            return 2;
        },
    };
    defer options.deinit(allocator);
    if (options.sources.items.len > 1) {
        render.usageError(init.io, init.environ_map, "this command accepts one expression or file", null, synopsis);
        return 2;
    }

    const source_arg = options.source orelse options.defaultSource();

    const worker_count = try setup.workerCount(&options);
    const memory_backing = setup.applyMemoryBacking(process, options.hugetlb);
    var settings = try config_discovery.loadLocal(allocator, init, &options);
    config_discovery.fetchFlakeSettings(allocator, init, &options, &settings);
    defer settings.deinit();
    var ev = try Engine.init(allocator, setup.engineConfig(init, worker_count, memory_backing));
    defer ev.deinit();
    const term = try setup.configure(&ev, init, &options, &settings);
    defer term.deinit(ev.hostAllocator());

    if (eval_support.sourceRequiresFlakes(source_arg) and !ev.languagePolicy().flakes_enabled) {
        render.usageError(init.io, init.environ_map, args.errorMessage(error.FlakesFeatureRequired), null, synopsis);
        return 2;
    }

    var source = eval_support.getSource(&ev, init.io, source_arg, options.sourceOptions()) catch |err| {
        render.caughtError(init.io, term.use_color, err, "reading source", .{});
        return 1;
    };
    defer source.deinit(ev.hostAllocator());

    ev.enableStoreWrites();

    const realized = switch (try realization_workflow.realize(allocator, init.io, &ev, process.eval_release, term, &options, source_arg, source, true)) {
        .failed => |code| return code,
        .ok => |r| r,
    };
    defer realized.deinit(allocator);

    // A flake `app` yields an absolute program path to exec directly; a
    // derivation yields `<out_path>/bin/<mainProgram|pname|name>`.
    const exe = if (realized.app_program) |app|
        try allocator.dupe(u8, app)
    else
        try std.fmt.allocPrint(allocator, "{s}/bin/{s}", .{ realized.out_path, realized.program.? });
    defer allocator.free(exe);
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, exe);
    while (args_iter.next()) |a| try argv.append(allocator, a);

    var child = std.process.spawn(init.io, .{
        .argv = argv.items,
        .environ_map = init.environ_map,
    }) catch |err| {
        render.caughtError(init.io, term.use_color, err, "running {s}", .{exe});
        return 127;
    };
    const status = child.wait(init.io) catch |err| {
        render.caughtError(init.io, term.use_color, err, "", .{});
        return 1;
    };
    return switch (status) {
        .exited => |code| code,
        else => 1,
    };
}
