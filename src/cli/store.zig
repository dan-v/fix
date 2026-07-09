//! `fix store` — talk to the nix-daemon over the worker protocol. A thin
//! window onto the `runtime.store` client, used to exercise/verify it and to
//! answer store-validity questions without shelling out to `nix`.

const std = @import("std");
const cli = @import("cli.zig");
const store = @import("runtime").store;

const usage =
    \\usage: fix store <subcommand> [args]
    \\
    \\subcommands:
    \\  info                 connect to the daemon and print protocol version + trust
    \\  is-valid PATH        print whether PATH is a valid store path
    \\  query-valid PATH...  print the subset of PATHs the daemon considers valid
    \\
    \\  -h, --help           show this help
    \\
;

pub fn run(allocator: std.mem.Allocator, init: std.process.Init, args_iter: *std.process.Args.Iterator) !u8 {
    const sub = args_iter.next() orelse {
        std.debug.print("{s}", .{usage});
        return 2;
    };
    if (cli.isHelpFlag(sub)) {
        cli.printHelp(init.io, usage);
        return 0;
    }

    if (std.mem.eql(u8, sub, "info")) return runInfo(allocator, init);
    if (std.mem.eql(u8, sub, "is-valid")) return runIsValid(allocator, init, args_iter);
    if (std.mem.eql(u8, sub, "query-valid")) return runQueryValid(allocator, init, args_iter);

    std.debug.print("error: unknown subcommand '{s}'\n\n{s}", .{ sub, usage });
    return 2;
}

fn connect(allocator: std.mem.Allocator, init: std.process.Init) !*store.DaemonStore {
    return store.DaemonStore.connect(allocator, init.io, store.default_socket_path) catch |err| {
        std.debug.print("error: connecting to nix-daemon at {s}: {s}\n", .{ store.default_socket_path, @errorName(err) });
        return err;
    };
}

fn runInfo(allocator: std.mem.Allocator, init: std.process.Init) !u8 {
    const daemon = try connect(allocator, init);
    defer daemon.deinit();

    const wire = store.wire;
    var stdout_buf: [512]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);
    try w.interface.print("daemon protocol version: {d}.{d}\n", .{
        wire.protocolMajor(daemon.daemon_version) >> 8,
        wire.protocolMinor(daemon.daemon_version),
    });
    try w.interface.print("trusted client: {s}\n", .{@tagName(daemon.trusted)});
    try w.interface.flush();
    return 0;
}

fn runIsValid(allocator: std.mem.Allocator, init: std.process.Init, args_iter: *std.process.Args.Iterator) !u8 {
    const path = args_iter.next() orelse {
        std.debug.print("error: is-valid needs a store path\n\n{s}", .{usage});
        return 2;
    };
    const daemon = try connect(allocator, init);
    defer daemon.deinit();

    const valid = daemon.isValidPath(path) catch |err| return reportDaemonError(daemon, err);
    var stdout_buf: [256]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);
    try w.interface.print("{s}\n", .{if (valid) "valid" else "invalid"});
    try w.interface.flush();
    return if (valid) 0 else 1;
}

fn runQueryValid(allocator: std.mem.Allocator, init: std.process.Init, args_iter: *std.process.Args.Iterator) !u8 {
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer paths.deinit(allocator);
    while (args_iter.next()) |p| try paths.append(allocator, p);
    if (paths.items.len == 0) {
        std.debug.print("error: query-valid needs at least one store path\n\n{s}", .{usage});
        return 2;
    }

    const daemon = try connect(allocator, init);
    defer daemon.deinit();

    const valid = daemon.queryValidPaths(allocator, paths.items, false) catch |err| return reportDaemonError(daemon, err);
    defer {
        for (valid) |s| allocator.free(s);
        allocator.free(valid);
    }
    var stdout_buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);
    for (valid) |p| try w.interface.print("{s}\n", .{p});
    try w.interface.flush();
    return 0;
}

fn reportDaemonError(daemon: *store.DaemonStore, err: anyerror) u8 {
    if (err == error.DaemonError) {
        std.debug.print("error: daemon: {s}\n", .{daemon.last_error orelse "unknown"});
    } else {
        std.debug.print("error: {s}\n", .{@errorName(err)});
    }
    return 1;
}
