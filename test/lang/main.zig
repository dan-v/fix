//! Differential language-conformance runner: drives the pinned Lix + snix
//! corpora through `fix` and diffs against the reference goldens. A self-
//! contained Zig program (no python/pyyaml dependency) — `zig build test-lang`.
//! Lix declarative cases live in lix.zig, the custom adapters in lix_custom.zig,
//! the snix suite in snix.zig; yaml.zig reads the pyyaml goldens for structural
//! AST comparison.

const std = @import("std");
const proc = @import("proc.zig");
const fsx = @import("fsx.zig");
const snix = @import("snix.zig");
const lix = @import("lix.zig");
const lix_custom = @import("lix_custom.zig");
const Result = @import("result.zig").Result;

const Options = struct {
    suite: enum { lix, snix, all } = .all,
    fix: []const u8 = "zig-out/bin/fix",
    repo: []const u8 = ".",
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.next(); // argv[0]

    var opts: Options = .{};
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--suite")) {
            const v = args.next() orelse fatal("--suite needs an argument", .{});
            opts.suite = if (std.mem.eql(u8, v, "lix")) .lix //
                else if (std.mem.eql(u8, v, "snix")) .snix //
                else if (std.mem.eql(u8, v, "all")) .all //
                else fatal("unknown suite '{s}'", .{v});
        } else if (std.mem.eql(u8, a, "--fix")) {
            opts.fix = args.next() orelse fatal("--fix needs an argument", .{});
        } else if (std.mem.eql(u8, a, "--repo")) {
            opts.repo = args.next() orelse fatal("--repo needs an argument", .{});
        } else if (std.mem.eql(u8, a, "-v") or std.mem.eql(u8, a, "--verbose")) {
            // Failure diffs are always shown; accepted for compatibility.
        } else {
            fatal("unexpected argument '{s}'", .{a});
        }
    }

    var arena_impl = std.heap.ArenaAllocator.init(gpa);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const cwd = init.environ_map.get("PWD") orelse ".";
    const fix_abs = try fsx.absPath(arena, cwd, opts.fix);
    if (!fsx.exists(io, fix_abs))
        fatal("fix binary not found at '{s}' (build with `zig build`)", .{fix_abs});
    const repo_abs = try fsx.absPath(arena, cwd, opts.repo);

    const ctx: snix.Ctx = .{
        .gpa = gpa,
        .io = io,
        .fix = fix_abs,
        .parent_env = init.environ_map,
        .userns_ok = probeUserns(gpa, io),
        .store_ok = storeAvailable(io, init.environ_map),
        .home = init.environ_map.get("HOME") orelse "",
    };

    const progress = std.Progress.start(io, .{ .root_name = "conformance" });
    defer progress.end();

    var total_fail: usize = 0;
    if (opts.suite == .lix or opts.suite == .all)
        total_fail += try runLix(arena, ctx, repo_abs, progress);
    if (opts.suite == .snix or opts.suite == .all)
        total_fail += try runSnix(arena, ctx, repo_abs, progress);

    std.process.exit(if (total_fail > 0) 1 else 0);
}

fn runLix(arena: std.mem.Allocator, base: snix.Ctx, repo: []const u8, progress: std.Progress.Node) !usize {
    const pin = try proc.resolvePin(base.gpa, base.io, repo, "lix");
    const lang_dir = try std.fmt.allocPrint(arena, "{s}/tests/functional2/lang", .{pin});
    const disc = try lix.discover(arena, base.io, lang_dir);
    const ctx: lix.Ctx = .{
        .gpa = base.gpa,
        .io = base.io,
        .fix = base.fix,
        .parent_env = base.parent_env,
        .lang_dir = lang_dir,
    };
    const node = progress.start("lix", disc.cases.len);
    defer node.end();

    var results: std.ArrayListUnmanaged(Result) = .empty;
    for (disc.cases) |case| {
        const leaf = node.start(case.ident, 0);
        const r = lix.runCase(ctx, case, arena) catch |e|
            Result.fail("lix", case.ident, @errorName(e));
        try results.append(arena, r);
        leaf.end();
        node.completeOne();
    }
    for (disc.custom_dirs) |d| {
        const leaf = node.start(d, 0);
        const rs = lix_custom.run(ctx, d, arena) catch |e|
            &[_]Result{Result.fail("lix", d, @errorName(e))};
        try results.appendSlice(arena, rs);
        leaf.end();
        node.completeOne();
    }
    return report("lix", results.items);
}

fn runSnix(arena: std.mem.Allocator, ctx: snix.Ctx, repo: []const u8, progress: std.Progress.Node) !usize {
    const pin = try proc.resolvePin(ctx.gpa, ctx.io, repo, "snix");
    const cases_root = try std.fmt.allocPrint(arena, "{s}/contrib/nix-language-test-suite/tests/cases", .{pin});

    const kdls = try collectKdl(arena, ctx.io, cases_root);
    const node = progress.start("snix", kdls.len);
    defer node.end();

    var results: std.ArrayListUnmanaged(Result) = .empty;
    for (kdls) |kdl_path| {
        const leaf = node.start(std.fs.path.basename(kdl_path), 0);
        const case = snix.loadCase(arena, ctx.io, kdl_path, cases_root) catch |e| {
            try results.append(arena, Result.fail("snix", kdl_path, @errorName(e)));
            leaf.end();
            node.completeOne();
            continue;
        };
        const r = snix.runCase(ctx, case, arena) catch |e|
            Result.fail("snix", case.ident, @errorName(e));
        try results.append(arena, r);
        leaf.end();
        node.completeOne();
    }
    return report("snix", results.items);
}

/// Recursively collect and sort every `*.kdl` under root.
fn collectKdl(arena: std.mem.Allocator, io: std.Io, root: []const u8) ![]const []const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.path, ".kdl")) {
            try list.append(arena, try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, entry.path }));
        }
    }
    std.mem.sort([]const u8, list.items, {}, lessStr);
    return list.items;
}

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Print the per-suite report (to stderr, like run.py) and return the fail count.
fn report(suite: []const u8, results: []const Result) usize {
    var n_pass: usize = 0;
    var n_fail: usize = 0;
    var n_block: usize = 0;
    for (results) |r| switch (r.status) {
        .pass => n_pass += 1,
        .fail => n_fail += 1,
        .blocked => n_block += 1,
    };
    std.debug.print("[{s}] {d} pass, {d} fail, {d} blocked\n", .{ suite, n_pass, n_fail, n_block });

    // Deterministic order for diffing against the oracle.
    var idx: std.ArrayListUnmanaged(usize) = .empty;
    var buf: [4096]usize = undefined;
    var fba = std.heap.FixedBufferAllocator.init(std.mem.sliceAsBytes(buf[0..]));
    idx.ensureTotalCapacity(fba.allocator(), results.len) catch {};
    for (0..results.len) |i| idx.appendAssumeCapacity(i);
    std.mem.sort(usize, idx.items, results, identLess);

    for (idx.items) |i| {
        if (results[i].status != .fail) continue;
        std.debug.print("  FAIL {s}\n", .{results[i].ident});
        if (results[i].detail.len > 0) printIndented(results[i].detail);
    }
    for (idx.items) |i| {
        if (results[i].status != .blocked) continue;
        std.debug.print("  BLOCKED {s} ({s})\n", .{ results[i].ident, results[i].detail });
    }
    return n_fail;
}

fn identLess(results: []const Result, a: usize, b: usize) bool {
    return std.mem.lessThan(u8, results[a].ident, results[b].ident);
}

fn printIndented(text: []const u8) void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| std.debug.print("      {s}\n", .{line});
}

// --- environment probes -----------------------------------------------------

fn storeAvailable(io: std.Io, env: *const std.process.Environ.Map) bool {
    const sock = env.get("NIX_DAEMON_SOCKET") orelse "/nix/var/nix/daemon-socket/socket";
    if (std.Io.Dir.cwd().statFile(io, sock, .{})) |st| {
        if (st.kind == .unix_domain_socket) return true;
    } else |_| {}
    std.Io.Dir.cwd().access(io, "/nix/store", .{ .write = true }) catch return false;
    return true;
}

fn probeUserns(gpa: std.mem.Allocator, io: std.Io) bool {
    const probe = fsx.makeTempDir(gpa, io) catch return false;
    defer {
        fsx.removeTree(io, probe);
        gpa.free(probe);
    }
    const mp = std.fmt.allocPrint(gpa, "{s}/probe", .{probe}) catch return false;
    defer gpa.free(mp);
    fsx.writeFile(io, mp, "") catch return false;
    const inner = std.fmt.allocPrint(gpa, "mount --bind /dev/null {s} && [ -c {s} ]", .{ mp, mp }) catch return false;
    defer gpa.free(inner);
    const argv = [_][]const u8{ "unshare", "--map-root-user", "--user", "--mount", "sh", "-c", inner };
    var out = proc.run(gpa, io, &argv, null, null, proc.case_timeout_ns) catch return false;
    defer out.deinit(gpa);
    return out.rc == 0;
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("test/lang: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}
