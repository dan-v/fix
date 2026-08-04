//! Pre-engine configuration discovery for CLI commands.
//!
//! Local nix.conf/environment/argv loading is pure filesystem configuration.
//! Flake `nixConfig` discovery is a separate, explicitly named effect: it may
//! fetch remote inputs and constructs a short-lived evaluator. Callers perform
//! the two phases visibly before constructing their long-lived Engine.

const std = @import("std");
const engine = @import("expr");
const args = @import("args.zig");
const nix_conf = @import("nix_conf.zig");
const TextRef = @import("base").TextRef;

const Engine = engine.Engine;

pub fn loadLocal(
    allocator: std.mem.Allocator,
    init: std.process.Init,
    options: *const args.Options,
) !nix_conf.Settings {
    var settings = try nix_conf.load(allocator, init.environ_map, init.io);
    errdefer settings.deinit();
    // Environment store selection sits above nix.conf but below an explicit
    // `--store`/`--option store` CLI override.
    if (init.environ_map.get("NIX_REMOTE")) |remote|
        if (remote.len != 0) try settings.setOrAppend("store", remote);
    for (options.option_overrides.items) |override|
        try settings.setOrAppend(override.name, override.value);
    return settings;
}

/// Fetch and fold each flake installable's `nixConfig` after local config and
/// CLI overrides. Failures are best-effort and leave settings unchanged.
pub fn fetchFlakeSettings(
    allocator: std.mem.Allocator,
    init: std.process.Init,
    options: *const args.Options,
    settings: *nix_conf.Settings,
) void {
    for (options.sources.items) |source| {
        if (source != .flake) continue;
        const installable = source.flake;
        const ref = if (std.mem.indexOfScalar(u8, installable, '#')) |hash| installable[0..hash] else installable;
        var resolved = resolveRef(allocator, init.io, ref);
        defer resolved.deinit(allocator);
        foldOne(allocator, init, resolved.slice(), settings);
    }
}

fn resolveRef(allocator: std.mem.Allocator, io: std.Io, ref: []const u8) TextRef {
    if (std.mem.eql(u8, ref, ".") or std.mem.startsWith(u8, ref, "./") or std.mem.startsWith(u8, ref, "../")) {
        const cwd = std.process.currentPathAlloc(io, allocator) catch return .{ .borrowed = ref };
        defer allocator.free(cwd);
        const absolute = std.fs.path.resolve(allocator, &.{ cwd, ref }) catch return .{ .borrowed = ref };
        return .{ .owned = absolute };
    }
    return .{ .borrowed = ref };
}

fn foldOne(allocator: std.mem.Allocator, init: std.process.Init, ref: []const u8, settings: *nix_conf.Settings) void {
    // A ref with quotes/backslashes is invalid; skip rather than mis-escape it.
    if (std.mem.indexOfAny(u8, ref, "\"\\\n") != null) return;
    var ev = Engine.init(allocator, .{
        .worker_count = 1,
        .io = init.io,
        .environment = init.environ_map,
    }) catch return;
    defer ev.deinit();

    // fetchTree / parseFlakeRef need the flakes feature (which implies
    // fetch-tree). This evaluator intentionally has no store capability.
    var features: args.ExperimentalFeatures = .{};
    features.insert(.flakes);
    var policy = ev.languagePolicy();
    policy.applyFeatureSets(features, .{});
    ev.configureLanguage(policy);
    ev.setFlakeRegistryUrl(settings.get("flake-registry") orelse "https://channels.nixos.org/flake-registry.json") catch {};
    if (settings.get("access-tokens")) |tokens| ev.setAccessTokens(tokens) catch {};

    const expression = std.fmt.allocPrint(allocator,
        \\let r = builtins.parseFlakeRef "{s}";
        \\    src = builtins.fetchTree r;
        \\    d = if r ? dir then "/" + r.dir else "";
        \\    nc = (import (src.outPath + d + "/flake.nix")).nixConfig or {{}};
        \\    c = v: if builtins.isList v then builtins.concatStringsSep " " (map toString v)
        \\           else if builtins.isBool v then (if v then "true" else "false") else toString v;
        \\in builtins.concatStringsSep "\n" (map (n: n + " " + c nc.${{n}}) (builtins.attrNames nc))
    , .{ref}) catch return;
    defer allocator.free(expression);
    const value = ev.evaluate(expression) catch return;
    var buffer: [16 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    ev.writeRawValue(&writer, value) catch return;
    var lines = std.mem.splitScalar(u8, writer.buffered(), '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        settings.setOrAppend(line[0..space], line[space + 1 ..]) catch {};
    }
}
