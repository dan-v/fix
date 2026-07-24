//! `fix flake` — inspect and manage flakes.
//!
//! Subcommands: `metadata` (source/lock/inputs), `show` (the output tree),
//! `check` (evaluate every output), `update` (re-pin the lock to latest), and
//! `lock` (create the lock if missing). Flakerefs are evaluated with plain
//! `builtins.getFlake`, so lock (re)generation reuses the same tested path.

const std = @import("std");
const engine = @import("expr");
const args = @import("../args.zig");
const setup = @import("../setup.zig");

const Evaluator = engine.Evaluator;
const Value = @import("runtime").Value;

pub const synopsis =
    \\usage: fix flake <subcommand> [flakeref] [options]
    \\
    \\subcommands:
    \\  metadata   show the flake's source info, revision, and inputs
    \\  show       show the flake's outputs as a tree
    \\  check      evaluate every output and report failures
    \\  update     re-pin the lock file to the latest inputs
    \\  lock       create the lock file if it is missing
    \\
    \\the flakeref defaults to `.` (the current directory). requires the flakes
    \\experimental feature.
;

pub fn run(process: @import("../process_context.zig").ProcessContext, init: std.process.Init, args_iter: *std.process.Args.Iterator) !u8 {
    const allocator = process.allocator;
    const sub = args_iter.next() orelse {
        args.writeHelp(init.io, synopsis, .eval);
        return 2;
    };
    if (std.mem.eql(u8, sub, "--help") or std.mem.eql(u8, sub, "-h")) {
        args.writeHelp(init.io, synopsis, .eval);
        return 0;
    }
    // A leading flag means the subcommand was omitted.
    if (sub.len > 0 and sub[0] == '-') {
        std.debug.print("error: expected a flake subcommand\n\n{s}\n", .{synopsis});
        return 2;
    }

    // Reuse the eval arg grammar: the flakeref is a bare positional, plus the
    // usual `--extra-experimental-features` / `--option` / `--impure` flags.
    var options = args.parse(allocator, args_iter, null, .eval) catch |err| switch (err) {
        error.Help => {
            args.writeHelp(init.io, synopsis, .eval);
            return 0;
        },
        else => {
            std.debug.print("error: {s}\n\n{s}\n", .{ args.errorMessage(err), synopsis });
            return 2;
        },
    };
    defer options.deinit(allocator);

    const flakeref = flakeRefOf(options);

    var ev = try Evaluator.init(allocator, try setup.workerCount(options));
    defer ev.deinit();
    _ = try setup.configure(&ev, init, options);
    if (!ev.languagePolicy().flakes_enabled) {
        std.debug.print("error: {s}\n", .{args.errorMessage(error.FlakesFeatureRequired)});
        return 2;
    }

    if (std.mem.eql(u8, sub, "metadata")) return metadata(&ev, init.io, allocator, flakeref);
    if (std.mem.eql(u8, sub, "show")) return show(&ev, init.io, allocator, flakeref);
    if (std.mem.eql(u8, sub, "check")) return check(&ev, init.io, allocator, flakeref);
    if (std.mem.eql(u8, sub, "update")) return update(&ev, init.io, allocator, flakeref, true);
    if (std.mem.eql(u8, sub, "lock")) return update(&ev, init.io, allocator, flakeref, false);

    std.debug.print("error: unknown flake subcommand '{s}'\n\n{s}\n", .{ sub, synopsis });
    return 2;
}

/// The flakeref positional, or `.` when none was given.
fn flakeRefOf(options: args.Options) []const u8 {
    if (options.sources.items.len == 0) return ".";
    return switch (options.sources.items[0]) {
        .file => |p| p,
        .flake => |f| f,
        .expr => |e| e,
    };
}

/// `builtins.getFlake "<ref>"`, owned by `allocator`.
fn getFlakeExpr(allocator: std.mem.Allocator, flakeref: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "builtins.getFlake \"");
    for (flakeref) |c| switch (c) {
        '"', '\\' => {
            try out.append(allocator, '\\');
            try out.append(allocator, c);
        },
        else => try out.append(allocator, c),
    };
    try out.appendSlice(allocator, "\"");
    return out.toOwnedSlice(allocator);
}

fn evalFlake(ev: *Evaluator, allocator: std.mem.Allocator, flakeref: []const u8) !Value {
    const expr = try getFlakeExpr(allocator, flakeref);
    defer allocator.free(expr);
    return ev.evaluate(expr);
}

fn stdoutWriter(io: std.Io, buf: []u8) std.Io.File.Writer {
    return std.Io.File.stdout().writerStreaming(io, buf);
}

fn printEvalError(err: anyerror) u8 {
    std.debug.print("error: evaluating flake: {s}\n", .{@errorName(err)});
    return 1;
}

// ---- metadata -------------------------------------------------------------

fn metadata(ev: *Evaluator, io: std.Io, allocator: std.mem.Allocator, flakeref: []const u8) !u8 {
    const flake = evalFlake(ev, allocator, flakeref) catch |err| return printEvalError(err);

    var buf: [4096]u8 = undefined;
    var w = stdoutWriter(io, &buf);
    const out = &w.interface;

    try out.print("Resolved URL:  {s}\n", .{flakeref});
    if (try ev.stringAttr(flake, "outPath")) |p| try out.print("Path:          {s}\n", .{p});
    if (try ev.stringAttr(flake, "narHash")) |h| try out.print("Locked hash:   {s}\n", .{h});
    if (try flakeDescription(ev, allocator, flake)) |d| {
        defer allocator.free(d);
        if (d.len != 0) try out.print("Description:   {s}\n", .{d});
    }
    if (try ev.stringAttr(flake, "rev")) |r| try out.print("Revision:      {s}\n", .{r});
    if (try ev.intAttr(flake, "revCount")) |n| try out.print("Revisions:     {d}\n", .{n});
    if (try ev.intAttr(flake, "lastModified")) |t| try out.print("Last modified: {d}\n", .{t});

    if (try ev.getAttr(flake, "inputs")) |inputs| {
        if (try ev.attrNames(allocator, inputs)) |names| {
            defer allocator.free(names);
            // `self` is the flake's own fixpoint, not a declared input (Nix
            // omits it from the metadata inputs list).
            var declared: usize = 0;
            for (names) |name| {
                if (!std.mem.eql(u8, name, "self")) declared += 1;
            }
            if (declared != 0) {
                try out.writeAll("Inputs:\n");
                var printed: usize = 0;
                for (names) |name| {
                    if (std.mem.eql(u8, name, "self")) continue;
                    printed += 1;
                    try out.print("{s}{s}\n", .{ if (printed == declared) "└───" else "├───", name });
                }
            }
        }
    }
    try out.flush();
    return 0;
}

/// The flake's `description`, read from its `flake.nix` (not on the result).
fn flakeDescription(ev: *Evaluator, allocator: std.mem.Allocator, flake: Value) !?[]u8 {
    const out_path = (try ev.stringAttr(flake, "outPath")) orelse return null;
    const expr = try std.fmt.allocPrint(allocator, "(import \"{s}/flake.nix\").description or \"\"", .{out_path});
    defer allocator.free(expr);
    const val = ev.evaluate(expr) catch return null;
    const text = (try ev.stringValue(val)) orelse return null;
    return try allocator.dupe(u8, text);
}

// ---- show -----------------------------------------------------------------

const Category = struct {
    name: []const u8,
    /// `<name>.<system>.<leaf>` (packages/apps/…) vs `<name>.<leaf>` (modules/…).
    system_scoped: bool,
    leaf_desc: []const u8,
    /// legacyPackages is huge; list the systems but don't recurse into packages.
    recurse: bool = true,
};

const categories = [_]Category{
    .{ .name = "packages", .system_scoped = true, .leaf_desc = "package" },
    .{ .name = "legacyPackages", .system_scoped = true, .leaf_desc = "package", .recurse = false },
    .{ .name = "apps", .system_scoped = true, .leaf_desc = "app" },
    .{ .name = "devShells", .system_scoped = true, .leaf_desc = "development environment" },
    .{ .name = "checks", .system_scoped = true, .leaf_desc = "derivation" },
    .{ .name = "formatter", .system_scoped = false, .leaf_desc = "formatter" },
    .{ .name = "nixosConfigurations", .system_scoped = false, .leaf_desc = "NixOS configuration" },
    .{ .name = "darwinConfigurations", .system_scoped = false, .leaf_desc = "nix-darwin configuration" },
    .{ .name = "homeConfigurations", .system_scoped = false, .leaf_desc = "home-manager configuration" },
    .{ .name = "nixosModules", .system_scoped = false, .leaf_desc = "NixOS module" },
    .{ .name = "overlays", .system_scoped = false, .leaf_desc = "Nixpkgs overlay" },
    .{ .name = "templates", .system_scoped = false, .leaf_desc = "template" },
};

const Node = struct {
    label: []const u8,
    children: std.ArrayListUnmanaged(*Node) = .empty,
};

fn show(ev: *Evaluator, io: std.Io, allocator: std.mem.Allocator, flakeref: []const u8) !u8 {
    const flake = evalFlake(ev, allocator, flakeref) catch |err| return printEvalError(err);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root = try arena.create(Node);
    root.* = .{ .label = flakeref };

    for (categories) |cat| {
        const cat_val = (ev.getAttr(flake, cat.name) catch continue) orelse continue;
        const cat_node = try arena.create(Node);
        cat_node.* = .{ .label = cat.name };
        if (cat.system_scoped) {
            const systems = (ev.attrNames(arena, cat_val) catch continue) orelse continue;
            for (systems) |system| {
                const sys_val = (ev.getAttr(cat_val, system) catch continue) orelse continue;
                const sys_node = try arena.create(Node);
                sys_node.* = .{ .label = system };
                if (cat.recurse) try appendLeaves(ev, arena, sys_node, sys_val, cat.leaf_desc);
                try cat_node.children.append(arena, sys_node);
            }
        } else {
            try appendLeaves(ev, arena, cat_node, cat_val, cat.leaf_desc);
        }
        if (cat_node.children.items.len != 0) try root.children.append(arena, cat_node);
    }

    var buf: [8192]u8 = undefined;
    var w = stdoutWriter(io, &buf);
    const out = &w.interface;
    try out.print("{s}\n", .{root.label});
    try printChildren(out, arena, root, "");
    try out.flush();
    return 0;
}

fn appendLeaves(ev: *Evaluator, arena: std.mem.Allocator, parent: *Node, value: Value, desc: []const u8) !void {
    const names = (ev.attrNames(arena, value) catch return) orelse return;
    for (names) |name| {
        const node = try arena.create(Node);
        node.* = .{ .label = try std.fmt.allocPrint(arena, "{s}: {s}", .{ name, desc }) };
        try parent.children.append(arena, node);
    }
}

fn printChildren(out: *std.Io.Writer, arena: std.mem.Allocator, node: *Node, prefix: []const u8) !void {
    for (node.children.items, 0..) |child, i| {
        const last = i + 1 == node.children.items.len;
        try out.print("{s}{s}{s}\n", .{ prefix, if (last) "└───" else "├───", child.label });
        const child_prefix = try std.fmt.allocPrint(arena, "{s}{s}", .{ prefix, if (last) "    " else "│   " });
        try printChildren(out, arena, child, child_prefix);
    }
}

// ---- check ----------------------------------------------------------------

fn check(ev: *Evaluator, io: std.Io, allocator: std.mem.Allocator, flakeref: []const u8) !u8 {
    const flake = evalFlake(ev, allocator, flakeref) catch |err| return printEvalError(err);

    var buf: [4096]u8 = undefined;
    var w = stdoutWriter(io, &buf);
    const out = &w.interface;

    var failures: usize = 0;
    var checked: usize = 0;
    for (categories) |cat| {
        if (!cat.recurse) continue; // skip legacyPackages
        const cat_val = (ev.getAttr(flake, cat.name) catch continue) orelse continue;
        if (cat.system_scoped) {
            const systems = (ev.attrNames(allocator, cat_val) catch continue) orelse continue;
            defer allocator.free(systems);
            for (systems) |system| {
                const sys_val = (ev.getAttr(cat_val, system) catch continue) orelse continue;
                try checkLeaves(ev, out, allocator, cat.name, system, sys_val, &checked, &failures);
            }
        } else {
            try checkLeaves(ev, out, allocator, cat.name, null, cat_val, &checked, &failures);
        }
    }

    if (failures == 0) {
        try out.print("checked {d} flake output(s): ok\n", .{checked});
    } else {
        try out.print("checked {d} flake output(s): {d} failed\n", .{ checked, failures });
    }
    try out.flush();
    return if (failures == 0) 0 else 1;
}

fn checkLeaves(ev: *Evaluator, out: *std.Io.Writer, allocator: std.mem.Allocator, category: []const u8, system: ?[]const u8, value: Value, checked: *usize, failures: *usize) !void {
    const names = (ev.attrNames(allocator, value) catch return) orelse return;
    defer allocator.free(names);
    for (names) |name| {
        checked.* += 1;
        const leaf = (ev.getAttr(value, name) catch {
            try reportCheckFailure(out, category, system, name);
            failures.* += 1;
            continue;
        }) orelse continue;
        // Force the output to WHNF; that's enough to surface an evaluation error
        // (a broken derivation/output).
        _ = ev.forceValue(leaf) catch {
            try reportCheckFailure(out, category, system, name);
            failures.* += 1;
        };
    }
}

fn reportCheckFailure(out: *std.Io.Writer, category: []const u8, system: ?[]const u8, name: []const u8) !void {
    if (system) |s| {
        try out.print("  FAIL {s}.{s}.{s}\n", .{ category, s, name });
    } else {
        try out.print("  FAIL {s}.{s}\n", .{ category, name });
    }
}

// ---- update / lock --------------------------------------------------------

fn update(ev: *Evaluator, io: std.Io, allocator: std.mem.Allocator, flakeref: []const u8, force: bool) !u8 {
    const dir = localFlakeDir(allocator, io, flakeref) orelse {
        std.debug.print("error: `flake {s}` needs a local flake (got '{s}')\n", .{ if (force) "update" else "lock", flakeref });
        return 2;
    };
    defer allocator.free(dir);
    const lock_path = try std.fs.path.join(allocator, &.{ dir, "flake.lock" });
    defer allocator.free(lock_path);

    // `update` re-pins to latest: back up and remove the existing lock so
    // getFlake's no-lock path recomputes it. `lock` keeps an existing lock.
    var backup: ?[]u8 = null;
    defer if (backup) |b| allocator.free(b);
    if (force) {
        backup = std.Io.Dir.cwd().readFileAlloc(io, lock_path, allocator, .limited(1 << 24)) catch null;
        if (backup != null) std.Io.Dir.cwd().deleteFile(io, lock_path) catch {};
    }

    _ = evalFlake(ev, allocator, flakeref) catch |err| {
        // Restore the previous lock so a failed relock doesn't lose it.
        if (backup) |b| std.Io.Dir.cwd().writeFile(io, .{ .sub_path = lock_path, .data = b }) catch {};
        return printEvalError(err);
    };

    // getFlake writes the lock during eval — but only when the flake has inputs.
    if (std.Io.Dir.cwd().access(io, lock_path, .{})) |_| {
        std.debug.print("{s} lock file: {s}\n", .{ if (force) "updated" else "wrote", lock_path });
    } else |_| {
        std.debug.print("flake has no inputs; no lock file needed\n", .{});
    }
    return 0;
}

/// The local directory of a flakeref, or null for a remote/scheme ref.
fn localFlakeDir(allocator: std.mem.Allocator, io: std.Io, flakeref: []const u8) ?[]u8 {
    if (std.mem.startsWith(u8, flakeref, "path:")) return allocator.dupe(u8, flakeref["path:".len..]) catch null;
    if (flakeref.len > 0 and flakeref[0] == '/') return allocator.dupe(u8, flakeref) catch null;
    if (std.mem.eql(u8, flakeref, ".") or std.mem.startsWith(u8, flakeref, "./") or std.mem.startsWith(u8, flakeref, "../")) {
        const cwd = std.process.currentPathAlloc(io, allocator) catch return null;
        defer allocator.free(cwd);
        return std.fs.path.resolve(allocator, &.{ cwd, flakeref }) catch null;
    }
    return null;
}
