//! `fix run` — evaluate to a derivation, build it, and exec a program from its
//! output (`$out/bin/<mainProgram|pname|name>`), forwarding any args after `--`.
//! The nix run analogue.

const std = @import("std");
const engine = @import("nix");
const cli = @import("cli.zig");
const args = @import("args.zig");
const setup = @import("setup.zig");
const run = @import("run.zig");

const Evaluator = engine.Evaluator;

pub const synopsis =
    \\usage: fix run [options] [path | -e <expr>] [-- args...]
    \\
    \\evaluate to a derivation, build it, and run $out/bin/<program> (from
    \\meta.mainProgram, else pname, else name). Arguments after `--` are passed
    \\to the program. With no source, uses ./default.nix (or, with --flake, the
    \\flake in the current directory).
;

pub fn run_cmd(allocator: std.mem.Allocator, init: std.process.Init, args_iter: *std.process.Args.Iterator) !u8 {
    var options = args.parse(allocator, args_iter, null) catch |err| switch (err) {
        error.Help => {
            args.writeHelp(init.io, synopsis, .run);
            return 0;
        },
        else => {
            std.debug.print("error: {s}\n\n{s}\n", .{ args.errorMessage(err), synopsis });
            return 2;
        },
    };
    defer options.deinit(allocator);

    const source_arg = options.source orelse options.defaultSource();

    const worker_count = try setup.workerCount(options);
    setup.applyMemoryBacking(options.hugetlb);
    var ev = try Evaluator.init(allocator, worker_count);
    defer ev.deinit();
    const term = try setup.configure(&ev, init, options);

    if (source_arg == .flake and !ev.policy.flakes_enabled) {
        std.debug.print("error: {s}\n\n{s}\n", .{ args.errorMessage(error.FlakesFeatureRequired), synopsis });
        return 2;
    }

    const source = run.getSource(&ev, source_arg, options) catch |err| {
        std.debug.print("error: reading source: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer source.deinit(ev.allocator);

    ev.enableStoreWrites();

    const realized = switch (try cli.realize(allocator, init.io, &ev, term, options, source_arg, source, true)) {
        .failed => |code| return code,
        .ok => |r| r,
    };
    defer realized.deinit(allocator);
    const out_path = realized.out_path;
    const program = realized.program.?;

    // Assemble argv = [$out/bin/<program>] ++ (args after `--`) and exec it.
    const exe = try std.fmt.allocPrint(allocator, "{s}/bin/{s}", .{ out_path, program });
    defer allocator.free(exe);
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, exe);
    while (args_iter.next()) |a| try argv.append(allocator, a);

    var child = std.process.spawn(init.io, .{
        .argv = argv.items,
        .environ_map = init.environ_map,
    }) catch |err| {
        std.debug.print("error: running {s}: {s}\n", .{ exe, @errorName(err) });
        return 127;
    };
    const status = child.wait(init.io) catch |err| {
        std.debug.print("error: {s}\n", .{@errorName(err)});
        return 1;
    };
    return switch (status) {
        .exited => |code| code,
        else => 1,
    };
}
