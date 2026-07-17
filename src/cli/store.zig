//! `fix store` — talk to the nix-daemon over the worker protocol. A thin
//! window onto the host store client, used to exercise/verify it and to
//! answer store-validity questions without shelling out to `nix`.

const std = @import("std");
const presentation = @import("presentation.zig");
const store_domain = @import("store");
const store = store_domain.daemon;
const nar = store_domain.nar;
const FileCache = store_domain.FileCache;

const usage =
    \\usage: fix store <subcommand> [args]
    \\
    \\subcommands:
    \\  info                 connect to the daemon and print protocol version + trust
    \\  is-valid PATH        print whether PATH is a valid store path
    \\  query-valid PATH...  print the subset of PATHs the daemon considers valid
    \\  add-text NAME TEXT   add TEXT to the store as NAME; print the store path
    \\  add-path PATH [NAME] NAR-add PATH (recursively) to the store; print the path
    \\
    \\  -h, --help           show this help
    \\
;

pub fn run(process: @import("process_context.zig").ProcessContext, init: std.process.Init, args_iter: *std.process.Args.Iterator) !u8 {
    const allocator = process.allocator;
    const sub = args_iter.next() orelse {
        std.debug.print("{s}", .{usage});
        return 2;
    };
    if (presentation.isHelpFlag(sub)) {
        presentation.printHelp(init.io, usage);
        return 0;
    }

    if (std.mem.eql(u8, sub, "info")) return runInfo(allocator, init);
    if (std.mem.eql(u8, sub, "is-valid")) return runIsValid(allocator, init, args_iter);
    if (std.mem.eql(u8, sub, "query-valid")) return runQueryValid(allocator, init, args_iter);
    if (std.mem.eql(u8, sub, "add-text")) return runAddText(allocator, init, args_iter);
    if (std.mem.eql(u8, sub, "add-path")) return runAddPath(allocator, init, args_iter);

    std.debug.print("error: unknown subcommand '{s}'\n\n{s}", .{ sub, usage });
    return 2;
}

fn socketPath(init: std.process.Init) []const u8 {
    // `NIX_DAEMON_SOCKET_PATH` overrides the default (empty = unset, as in Nix).
    if (init.environ_map.get("NIX_DAEMON_SOCKET_PATH")) |sock|
        if (sock.len != 0) return sock;
    return store.default_socket_path;
}

fn connect(allocator: std.mem.Allocator, init: std.process.Init) !*store.DaemonStore {
    const path = socketPath(init);
    return store.DaemonStore.connect(allocator, init.io, path) catch |err| {
        std.debug.print("error: connecting to nix-daemon at {s}: {s}\n", .{ path, @errorName(err) });
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

fn runAddText(allocator: std.mem.Allocator, init: std.process.Init, args_iter: *std.process.Args.Iterator) !u8 {
    const name = args_iter.next() orelse {
        std.debug.print("error: add-text needs NAME and TEXT\n\n{s}", .{usage});
        return 2;
    };
    const text = args_iter.next() orelse {
        std.debug.print("error: add-text needs TEXT\n\n{s}", .{usage});
        return 2;
    };
    const daemon = try connect(allocator, init);
    defer daemon.deinit();

    const path = daemon.addTextToStore(allocator, name, text, &.{}) catch |err| return reportDaemonError(daemon, err);
    defer allocator.free(path);
    var stdout_buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);
    try w.interface.print("{s}\n", .{path});
    try w.interface.flush();
    return 0;
}

fn runAddPath(allocator: std.mem.Allocator, init: std.process.Init, args_iter: *std.process.Args.Iterator) !u8 {
    const raw_path = args_iter.next() orelse {
        std.debug.print("error: add-path needs a PATH\n\n{s}", .{usage});
        return 2;
    };
    const explicit_name = args_iter.next();

    const abs = try toAbsolute(allocator, init.io, raw_path);
    defer allocator.free(abs);
    const name = explicit_name orelse std.fs.path.basename(abs);

    var files = FileCache.init(allocator);
    defer files.deinit();
    files.setIo(init.io);

    const nar_bytes = nar.serialize(allocator, &files, abs, null) catch |err| {
        std.debug.print("error: serializing {s}: {s}\n", .{ abs, @errorName(err) });
        return 1;
    };
    defer allocator.free(nar_bytes);

    const daemon = try connect(allocator, init);
    defer daemon.deinit();

    const path = daemon.addPath(allocator, name, nar_bytes, &.{}) catch |err| return reportDaemonError(daemon, err);
    defer allocator.free(path);
    var stdout_buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);
    try w.interface.print("{s}\n", .{path});
    try w.interface.flush();
    return 0;
}

fn toAbsolute(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &.{ cwd, path });
}

fn reportDaemonError(daemon: *store.DaemonStore, err: anyerror) u8 {
    if (err == error.DaemonError) {
        std.debug.print("error: daemon: {s}\n", .{daemon.last_error orelse "unknown"});
    } else {
        std.debug.print("error: {s}\n", .{@errorName(err)});
    }
    return 1;
}
