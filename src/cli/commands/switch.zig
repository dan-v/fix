//! `fix switch` — build a system/home configuration and activate it: the
//! nixos-rebuild / darwin-rebuild / home-manager `switch` analogue.
//!
//!   fix switch                 # rebuild + activate this host (default action)
//!   fix switch boot            # build + set profile + bootloader (no activate)
//!   fix switch test            # activate now, no profile, no bootloader
//!   fix switch build           # just build + ./result (no profile, no root)
//!   fix switch dry-activate    # show what activation would do
//!   fix switch --flake .#host  # flake source (requires the flakes feature)
//!   fix switch --target-host h # build locally, copy closure + activate on h
//!
//! Like `nixos-rebuild`, the configuration is supplied exactly as it is for the
//! nix CLI: the default source (`<nixpkgs/nixos>`, with `-I nixos-config=…`) or
//! the user's own `-E`/`--file`/`--flake`/`-A`. We append the conventional
//! toplevel attribute, build it (reusing the `fix build` machinery), create a
//! profile generation, and run the activation script.
//!
//! Privilege: the build runs as the invoking user (the daemon does the work).
//! The profile-set + activation need root, so when `euid != 0` we re-exec just
//! that half under `sudo` (`--activate-toplevel`), then propagate its exit code.
//!
//! NixOS is the fully-verified path. darwin and home-manager follow their
//! documented invocations but are unverified locally (no darwin box).

const std = @import("std");
const builtin = @import("builtin");
const engine = @import("expr");
const realization_workflow = @import("../realize.zig");
const args = @import("../args.zig");
const setup = @import("../setup.zig");
const eval_support = @import("../eval_support.zig");
const build = @import("build.zig");

const Engine = engine.Engine;
const Target = args.SwitchTarget;

/// What to do with the built configuration. The first positional (default
/// `switch`), mirroring `nixos-rebuild`'s action argument.
const Action = enum {
    @"switch", // profile generation + activate + bootloader
    boot, // profile generation + bootloader only (no activation now)
    @"test", // activate now, no profile, no bootloader
    build, // just build + ./result (no profile, no activation, no root)
    dry_activate, // show what activation would change

    fn parse(token: []const u8) ?Action {
        if (std.mem.eql(u8, token, "switch")) return .@"switch";
        if (std.mem.eql(u8, token, "boot")) return .boot;
        if (std.mem.eql(u8, token, "test")) return .@"test";
        if (std.mem.eql(u8, token, "build")) return .build;
        if (std.mem.eql(u8, token, "dry-activate")) return .dry_activate;
        return null;
    }

    /// The action word as passed to `switch-to-configuration` and re-passed to
    /// the sudo'd re-exec of ourselves.
    fn word(self: Action) []const u8 {
        return switch (self) {
            .@"switch" => "switch",
            .boot => "boot",
            .@"test" => "test",
            .build => "build",
            .dry_activate => "dry-activate",
        };
    }
};

pub const synopsis =
    \\usage: fix switch [--nixos|--darwin|--home-manager] [action] [options]
    \\
    \\build a NixOS / nix-darwin / home-manager configuration and activate it.
    \\action (first argument) is one of: switch (default), boot, test, build,
    \\dry-activate. The configuration is given like nixos-rebuild — the default
    \\source with -I nixos-config=…, or your own -E/--file/--flake/-A. The
    \\profile-set and activation run under sudo when not already root, or on a
    \\remote host with --target-host (build stays local; the closure is copied).
;

pub fn run(process: @import("../process_context.zig").ProcessContext, init: std.process.Init, args_iter: *std.process.Args.Iterator) !u8 {
    const allocator = process.allocator;
    // The action is the first positional (like nixos-rebuild). Peek it before
    // the shared parser, which would otherwise treat it as a source path.
    var action: Action = .@"switch";
    var first: ?[:0]const u8 = null;
    if (args_iter.next()) |t0| {
        if (t0.len != 0 and t0[0] != '-') {
            if (Action.parse(t0)) |a| action = a else first = t0;
        } else first = t0;
    }

    var options = args.parse(allocator, args_iter, first, .@"switch") catch |err| switch (err) {
        error.Help => {
            args.writeHelp(init.io, synopsis, .@"switch");
            return 0;
        },
        else => {
            std.debug.print("error: {s}\n\n{s}\n", .{ args.errorMessage(err), synopsis });
            return 2;
        },
    };
    defer options.deinit(allocator);
    if (options.sources.items.len > 1) {
        std.debug.print("error: this command accepts one expression or file\n\n{s}\n", .{synopsis});
        return 2;
    }

    // Re-exec'd privileged half: skip eval/build, activate the given path.
    if (options.activate_toplevel) |top| {
        const target = resolveTarget(init, &options) catch {
            std.debug.print("error: --activate-toplevel needs an explicit --nixos/--darwin/--home-manager\n", .{});
            return 2;
        };
        return activate(allocator, init, target, action, top);
    }

    const target = resolveTarget(init, &options) catch {
        std.debug.print("error: could not detect the target; pass --nixos, --darwin, or --home-manager\n", .{});
        return 2;
    };

    return buildAndSwitch(process, init, target, action, &options);
}

// ---------------------------------------------------------------------------
// Phase A: build the toplevel, then activate (in-process or via sudo re-exec)
// ---------------------------------------------------------------------------

fn buildAndSwitch(process: @import("../process_context.zig").ProcessContext, init: std.process.Init, target: Target, action: Action, options: *args.Options) !u8 {
    const allocator = process.allocator;
    // Construct the installable per target, unless the user fully specified one
    // with `-A`. For flakes, the whole attr path is baked into the fragment; for
    // the legacy path we set the default source expr + append the toplevel attr.
    var flake_installable: ?[]const u8 = null;
    defer if (flake_installable) |s| allocator.free(s);

    const source_arg: args.SourceArg = if (options.source != null and options.source.? == .flake) blk: {
        const raw = options.source.?.flake;
        const hash = std.mem.indexOfScalar(u8, raw, '#');
        const ref = if (hash) |i| raw[0..i] else raw;
        const frag = if (hash) |i| raw[i + 1 ..] else "";
        const name = if (frag.len > 0)
            try allocator.dupe(u8, frag)
        else
            try defaultName(allocator, init, target);
        defer allocator.free(name);
        flake_installable = try std.fmt.allocPrint(allocator, "{s}#{s}.{s}.{s}", .{
            ref, flakePrefix(target), name, flakeAttrSuffix(target),
        });
        // The fragment carries the full attr path; don't also append `-A`.
        options.attr = null;
        break :blk .{ .flake = flake_installable.? };
    } else blk: {
        if (options.source == null) options.source = .{ .expr = legacyDefaultExpr(target) };
        if (options.attr == null) options.attr = attrSuffix(target);
        break :blk options.source.?;
    };

    const worker_count = try setup.workerCount(options);
    const memory_backing = setup.applyMemoryBacking(process, options.hugetlb);
    var settings = try setup.loadSettingsAndFlakeConfig(allocator, init, options);
    defer settings.deinit();
    var ev = try Engine.init(allocator, setup.engineConfig(init, worker_count, memory_backing));
    defer ev.deinit();
    const term = try setup.configure(&ev, init, options, &settings);

    if (eval_support.sourceRequiresFlakes(source_arg) and !ev.languagePolicy().flakes_enabled) {
        std.debug.print("error: {s}\n\n{s}\n", .{ args.errorMessage(error.FlakesFeatureRequired), synopsis });
        return 2;
    }

    var source = eval_support.getSource(&ev, init.io, source_arg, options.sourceOptions()) catch |err| {
        std.debug.print("error: reading source: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer source.deinit(ev.hostAllocator());

    ev.enableStoreWrites();

    const realized = switch (try realization_workflow.realize(allocator, init.io, &ev, process.eval_release, term, options, source_arg, source, false)) {
        .failed => |code| return code,
        .ok => |r| r,
    };
    defer realized.deinit(allocator);
    const out_path = realized.out_path;

    // `build`: just link ./result and print the path, like `fix build`.
    if (action == .build) {
        build.linkRoot(init.io, allocator, &ev, "result", out_path, true);
        var stdout_buf: [4096]u8 = undefined;
        var w = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);
        try w.interface.print("{s}\n", .{out_path});
        try w.interface.flush();
        return 0;
    }

    // Protect the toplevel from a concurrent GC across the activation window
    // (which may block for seconds on a sudo password prompt) with an indirect
    // root, cleaned up once we're done.
    const gc_link = ".fix-switch-gcroot";
    build.linkRoot(init.io, allocator, &ev, gc_link, out_path, true);
    defer std.Io.Dir.cwd().deleteFile(init.io, gc_link) catch {};

    // Remote deploy: copy the closure and activate on the target host over SSH.
    // The local side stays unprivileged; root (if needed) is on the remote.
    if (options.target_host) |host| {
        return deployRemote(allocator, init, target, action, out_path, host, options.use_remote_sudo);
    }

    // Local activation needs root for nixos/darwin. Elevate that half only.
    if (needsRoot(target, action) and effectiveUid() != 0) {
        return sudoReexec(allocator, init, target, action, out_path);
    }
    return activate(allocator, init, target, action, out_path);
}

// ---------------------------------------------------------------------------
// Remote deploy: nix-copy-closure + activate over SSH (nixos-rebuild
// --target-host). The build already ran locally; here we stage the closure to
// the remote store and drive its profile-set + activation.
// ---------------------------------------------------------------------------

fn deployRemote(allocator: std.mem.Allocator, init: std.process.Init, target: Target, action: Action, top: []const u8, host: []const u8, remote_sudo: bool) !u8 {
    // 1. Copy the closure to the remote store (nix-copy-closure reads NIX_SSHOPTS
    // from the inherited environment for SSH options).
    {
        const argv = [_][]const u8{ "nix-copy-closure", "--to", host, top };
        var child = std.process.spawn(init.io, .{ .argv = &argv, .environ_map = init.environ_map }) catch |err| {
            std.debug.print("error: launching nix-copy-closure: {s}\n", .{@errorName(err)});
            return 127;
        };
        const code = try waitCode(init.io, &child);
        if (code != 0) {
            std.debug.print("error: copying the closure to {s} failed\n", .{host});
            return code;
        }
    }

    // 2. Set the remote system profile (switch/boot). Done with the target's own
    // `nix-env` over SSH — the remote profile dir is root-owned there too.
    if (setsProfile(target, action)) {
        const code = try remoteRun(allocator, init, host, remote_sudo, &.{
            "nix-env", "-p", "/nix/var/nix/profiles/system", "--set", top,
        });
        if (code != 0) return code;
    }

    // 3. Run the remote activation script.
    const stc = try std.fmt.allocPrint(allocator, "{s}/bin/switch-to-configuration", .{top});
    defer allocator.free(stc);
    const activate_cmd: []const u8 = try std.fmt.allocPrint(allocator, "{s}/activate", .{top});
    defer allocator.free(activate_cmd);
    const remote_cmd: []const []const u8 = switch (target) {
        .nixos => &.{ stc, action.word() },
        .darwin, .home_manager => &.{activate_cmd},
    };
    return remoteRun(allocator, init, host, remote_sudo, remote_cmd);
}

/// Run `cmd` on `host` over SSH, optionally under `sudo`, inheriting stdio.
/// `NIX_SSHOPTS` (as used by nix-copy-closure) is split onto the ssh argv so
/// custom ports/keys/jump-hosts apply here too.
fn remoteRun(allocator: std.mem.Allocator, init: std.process.Init, host: []const u8, remote_sudo: bool, cmd: []const []const u8) !u8 {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "ssh");
    if (init.environ_map.get("NIX_SSHOPTS")) |opts| {
        var it = std.mem.tokenizeAny(u8, opts, " \t");
        while (it.next()) |tok| try argv.append(allocator, tok);
    }
    try argv.append(allocator, host);
    if (remote_sudo) try argv.append(allocator, "sudo");
    try argv.appendSlice(allocator, cmd);

    var child = std.process.spawn(init.io, .{ .argv = argv.items, .environ_map = init.environ_map }) catch |err| {
        std.debug.print("error: launching ssh: {s}\n", .{@errorName(err)});
        return 127;
    };
    return waitCode(init.io, &child);
}

/// Re-exec `sudo fix switch <action> <target> --activate-toplevel <top>` so the
/// profile-set + activation run as root. No rebuild happens in the child.
fn sudoReexec(allocator: std.mem.Allocator, init: std.process.Init, target: Target, action: Action, top: []const u8) !u8 {
    const self = std.process.executablePathAlloc(init.io, allocator) catch |err| {
        std.debug.print("error: cannot locate own executable to re-exec under sudo: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer allocator.free(self);

    const argv = [_][]const u8{
        "sudo",             self,                  "switch", action.word(),
        targetFlag(target), "--activate-toplevel", top,
    };
    var child = std.process.spawn(init.io, .{ .argv = &argv, .environ_map = init.environ_map }) catch |err| {
        std.debug.print("error: launching sudo: {s}\n", .{@errorName(err)});
        return 127;
    };
    return waitCode(init.io, &child);
}

// ---------------------------------------------------------------------------
// Phase B: profile-set (root) + run the activation script
// ---------------------------------------------------------------------------

fn activate(allocator: std.mem.Allocator, init: std.process.Init, target: Target, action: Action, top: []const u8) !u8 {
    if (setsProfile(target, action)) {
        setSystemProfile(init.io, top) catch |err| {
            std.debug.print("error: setting the system profile: {s}\n", .{@errorName(err)});
            return 1;
        };
    }
    return runActivation(allocator, init, target, action, top);
}

/// The system profile all NixOS/nix-darwin generations hang off. The profiles
/// directory is itself a GC-roots indirection (`/nix/var/nix/gcroots/profiles`),
/// so a new generation link is a GC root the moment it exists.
const profiles_dir = "/nix/var/nix/profiles";
const profile_name = "system";

/// Create a new generation of the system profile pointing at `top` and swap the
/// `system` symlink onto it — the `nix-env -p …/system --set <top>` equivalent,
/// done in-tree (no `nix-env`). Needs write access to `profiles_dir` (root).
fn setSystemProfile(io: std.Io, top: []const u8) !void {
    var dir = try std.Io.Dir.openDirAbsolute(io, profiles_dir, .{ .iterate = true });
    defer dir.close(io);

    // Highest existing `system-<N>-link`.
    var max_gen: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const num = generationNumber(entry.name) orelse continue;
        if (num > max_gen) max_gen = num;
    }

    // Create the fresh generation link (absolute target). Skip forward on the
    // off chance the name already exists.
    var gen: usize = max_gen + 1;
    var gen_buf: [64]u8 = undefined;
    const gen_name = while (gen < max_gen + 64) : (gen += 1) {
        const name = try std.fmt.bufPrint(&gen_buf, "{s}-{d}-link", .{ profile_name, gen });
        dir.symLink(io, top, name, .{}) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        break name;
    } else return error.TooManyGenerations;

    // Atomically point `system` at the new generation via a temp link + rename.
    // The `system` symlink uses a relative target, matching nix.
    const tmp = ".system.fix.tmp";
    dir.deleteFile(io, tmp) catch {};
    try dir.symLink(io, gen_name, tmp, .{});
    try dir.rename(tmp, dir, profile_name, io);
}

/// The `N` of a `system-<N>-link` generation entry, else null.
fn generationNumber(name: []const u8) ?usize {
    const prefix = profile_name ++ "-";
    const suffix = "-link";
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    if (!std.mem.endsWith(u8, name, suffix)) return null;
    const digits = name[prefix.len .. name.len - suffix.len];
    if (digits.len == 0) return null;
    return std.fmt.parseInt(usize, digits, 10) catch null;
}

/// Run the target's activation script, inheriting stdio, and return its exit
/// code. nixos: `<top>/bin/switch-to-configuration <action>`; darwin/hm:
/// `<top>/activate`.
fn runActivation(allocator: std.mem.Allocator, init: std.process.Init, target: Target, action: Action, top: []const u8) !u8 {
    const exe = switch (target) {
        .nixos => try std.fmt.allocPrint(allocator, "{s}/bin/switch-to-configuration", .{top}),
        .darwin, .home_manager => try std.fmt.allocPrint(allocator, "{s}/activate", .{top}),
    };
    defer allocator.free(exe);

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, exe);
    // switch-to-configuration takes the action word; darwin/hm `activate` do not
    // distinguish switch/boot/test — they always fully activate.
    if (target == .nixos) try argv.append(allocator, action.word());

    var child = std.process.spawn(init.io, .{ .argv = argv.items, .environ_map = init.environ_map }) catch |err| {
        std.debug.print("error: running {s}: {s}\n", .{ exe, @errorName(err) });
        return 127;
    };
    return waitCode(init.io, &child);
}

// ---------------------------------------------------------------------------
// Target / action semantics
// ---------------------------------------------------------------------------

/// Resolve the activation target: an explicit flag, else auto-detect from the
/// host (`uname == Darwin` → darwin; a NixOS marker → nixos). home-manager is
/// never auto-detected — it coexists with a system.
fn resolveTarget(init: std.process.Init, options: *const args.Options) !Target {
    if (options.switch_target) |t| return t;
    const u = std.posix.uname();
    if (std.mem.eql(u8, std.mem.sliceTo(&u.sysname, 0), "Darwin")) return .darwin;
    if (pathExists(init.io, "/run/current-system") or pathExists(init.io, "/etc/NixOS")) return .nixos;
    return error.CannotDetectTarget;
}

/// Activation needs root for a real system (nixos/darwin). home-manager runs
/// entirely as the user, and `build` never activates.
fn needsRoot(target: Target, action: Action) bool {
    if (target == .home_manager) return false;
    return action != .build;
}

/// Only `switch`/`boot` create a new profile generation. `test`/`dry-activate`
/// leave the profile untouched (matching nixos-rebuild); home-manager manages
/// its own profile inside its activate script.
fn setsProfile(target: Target, action: Action) bool {
    if (target == .home_manager) return false;
    return action == .@"switch" or action == .boot;
}

fn legacyDefaultExpr(target: Target) []const u8 {
    return switch (target) {
        .nixos => "import <nixpkgs/nixos>",
        .darwin => "import <darwin>",
        .home_manager => "import <home-manager/home-manager>",
    };
}

fn attrSuffix(target: Target) []const u8 {
    return switch (target) {
        .nixos, .darwin => "config.system.build.toplevel",
        .home_manager => "activationPackage",
    };
}

fn flakePrefix(target: Target) []const u8 {
    return switch (target) {
        .nixos => "nixosConfigurations",
        .darwin => "darwinConfigurations",
        .home_manager => "homeConfigurations",
    };
}

fn flakeAttrSuffix(target: Target) []const u8 {
    return switch (target) {
        .nixos => "config.system.build.toplevel",
        .darwin => "system",
        .home_manager => "activationPackage",
    };
}

fn targetFlag(target: Target) []const u8 {
    return switch (target) {
        .nixos => "--nixos",
        .darwin => "--darwin",
        .home_manager => "--home-manager",
    };
}

/// The default configuration name when none is given in a `--flake` fragment:
/// the hostname for a system, `$USER` for home-manager. Caller owns the result.
fn defaultName(allocator: std.mem.Allocator, init: std.process.Init, target: Target) ![]const u8 {
    if (target == .home_manager)
        return allocator.dupe(u8, init.environ_map.get("USER") orelse "default");
    const u = std.posix.uname();
    return allocator.dupe(u8, std.mem.sliceTo(&u.nodename, 0));
}

// ---------------------------------------------------------------------------
// Small host helpers
// ---------------------------------------------------------------------------

fn effectiveUid() std.posix.uid_t {
    // std.os.linux.geteuid is Linux-only; std.c.geteuid covers darwin. The
    // comptime tag prunes the inactive branch, so neither leaks cross-target.
    return if (builtin.os.tag == .linux) std.os.linux.geteuid() else std.c.geteuid();
}

fn pathExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn waitCode(io: std.Io, child: *std.process.Child) !u8 {
    const status = child.wait(io) catch |err| {
        std.debug.print("error: {s}\n", .{@errorName(err)});
        return 1;
    };
    return switch (status) {
        .exited => |code| code,
        else => 1,
    };
}
