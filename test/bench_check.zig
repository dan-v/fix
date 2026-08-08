//! Differential correctness check for the benchmark fixtures: every
//! `bench/workloads/**.nix` is evaluated under `fix` and under a reference Nix,
//! and the two results are compared structurally. This is deliberately NOT part
//! of the benchmark (which only times) — it reuses the same fixtures to confirm
//! fix agrees with Nix on them. Run with `zig build test-bench-fixtures`.
//!
//! Both sides run `--eval --strict --json`; the results (drvPaths, records,
//! lists, numbers) are parsed as JSON and compared order-independently, so a
//! divergence in any workload's value is a visible FAIL.

const std = @import("std");
const proc = @import("lang/proc.zig");
const fsx = @import("lang/fsx.zig");
const yaml = @import("lang/yaml.zig");

const eval_timeout_ns: i96 = 600 * std.time.ns_per_s;

const Options = struct {
    fix: []const u8 = "zig-out/bin/fix",
    repo: []const u8 = ".",
    nix: []const u8 = "nix-instantiate",
    /// Fix-side worker count. The default keeps the ordinary differential
    /// deterministic; the nightly concurrency lanes pass a real worker count
    /// so the same fixtures double as a parallel-eval differential.
    workers: []const u8 = "1",
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var arena_impl = std.heap.ArenaAllocator.init(gpa);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var opts: Options = .{};
    var filters: std.ArrayListUnmanaged([]const u8) = .empty;
    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.next();
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--fix")) opts.fix = args.next() orelse fatal("--fix needs an argument") //
        else if (std.mem.eql(u8, a, "--repo")) opts.repo = args.next() orelse fatal("--repo needs an argument") //
        else if (std.mem.eql(u8, a, "--nix")) opts.nix = args.next() orelse fatal("--nix needs an argument") //
        else if (std.mem.eql(u8, a, "--workers")) opts.workers = args.next() orelse fatal("--workers needs an argument") //
        else try filters.append(arena, a); // substring selectors, e.g. `torture`
    }

    const cwd = init.environ_map.get("PWD") orelse ".";
    const fix = try fsx.absPath(arena, cwd, opts.fix);
    const repo = try fsx.absPath(arena, cwd, opts.repo);
    if (!fsx.exists(io, fix)) fatal("fix binary not found (build with `zig build`)");

    // NIX_PATH mirrors bench/harness.nix: pinned nixpkgs + home-manager (resolved
    // from that nixpkgs). Pure workloads ignore it; the nixpkgs/home-manager
    // ones need it.
    const nixpkgs = try proc.resolvePin(gpa, io, repo, "nixpkgs");
    const nix_path = try resolveNixPath(gpa, io, arena, opts.nix, nixpkgs);

    var env = try proc.cloneEnv(gpa, init.environ_map);
    defer env.deinit();
    try env.put("NIX_PATH", nix_path);

    const root = try std.fmt.allocPrint(arena, "{s}/bench/workloads", .{repo});
    var workloads: std.ArrayListUnmanaged([]const u8) = .empty;
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.path, ".nix") and matches(filters.items, entry.path))
            try workloads.append(arena, try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, entry.path }));
    }
    std.mem.sort([]const u8, workloads.items, {}, lessStr);

    const progress = std.Progress.start(io, .{ .root_name = "bench-fixtures" });
    const node = progress.start("workloads", workloads.items.len);
    var fails: usize = 0;
    for (workloads.items) |w| {
        const rel = w[root.len + 1 ..];
        const leaf = node.start(rel, 0);
        if (try check(gpa, io, arena, fix, opts.nix, opts.workers, &env, w, rel)) |detail| {
            std.debug.print("  FAIL {s}\n{s}\n", .{ rel, detail });
            fails += 1;
        } else {
            std.debug.print("  ok   {s}\n", .{rel});
        }
        leaf.end();
        node.completeOne();
    }
    node.end();
    progress.end();

    std.debug.print("\nbench-fixtures: {d}/{d} agree with {s}\n", .{ workloads.items.len - fails, workloads.items.len, opts.nix });
    std.process.exit(if (fails > 0) 1 else 0);
}

/// Returns null on agreement, else a failure detail.
fn check(gpa: std.mem.Allocator, io: std.Io, arena: std.mem.Allocator, fix: []const u8, nix: []const u8, workers: []const u8, env: *const std.process.Environ.Map, workload: []const u8, rel: []const u8) !?[]const u8 {
    _ = rel;
    var fout = try proc.run(gpa, io, &.{ fix, "eval", "--json", "--strict", "--workers", workers, "--file", workload }, null, env, eval_timeout_ns);
    defer fout.deinit(gpa);
    var nout = try proc.run(gpa, io, &.{ nix, "--eval", "--strict", "--json", workload }, null, env, eval_timeout_ns);
    defer nout.deinit(gpa);

    if (nout.rc != 0)
        return try std.fmt.allocPrint(arena, "    reference nix failed (rc={d}); cannot compare:\n{s}", .{ nout.rc, indent(std.mem.trim(u8, nout.stderr, " \n\r\t")) });
    if (fout.rc != 0)
        return try std.fmt.allocPrint(arena, "    fix eval failed (rc={d}):\n{s}", .{ fout.rc, indent(std.mem.trim(u8, fout.stderr, " \n\r\t")) });

    const fv = std.json.parseFromSliceLeaky(std.json.Value, arena, fout.stdout, .{}) catch |e|
        return try std.fmt.allocPrint(arena, "    fix output is not valid JSON: {s}", .{@errorName(e)});
    const nv = std.json.parseFromSliceLeaky(std.json.Value, arena, nout.stdout, .{}) catch |e|
        return try std.fmt.allocPrint(arena, "    nix output is not valid JSON: {s}", .{@errorName(e)});
    if (yaml.equals(fv, nv)) return null;
    return try std.fmt.allocPrint(arena, "    fix:  {s}\n    nix:  {s}", .{ trunc(std.mem.trim(u8, fout.stdout, " \n\r\t")), trunc(std.mem.trim(u8, nout.stdout, " \n\r\t")) });
}

fn resolveNixPath(gpa: std.mem.Allocator, io: std.Io, arena: std.mem.Allocator, nix: []const u8, nixpkgs: []const u8) ![]const u8 {
    // home-manager is not an npins pin; take it from the pinned nixpkgs, exactly
    // as bench.nix does (pkgs.home-manager.src).
    const expr = try std.fmt.allocPrint(arena, "builtins.toString (import {s} {{}}).home-manager.src", .{nixpkgs});
    var out = try proc.run(gpa, io, &.{ nix, "--eval", "--strict", "--raw", "--expr", expr }, null, null, eval_timeout_ns);
    defer out.deinit(gpa);
    if (out.rc == 0) {
        const hm = std.mem.trim(u8, out.stdout, " \n\r\t");
        return std.fmt.allocPrint(arena, "nixpkgs={s}:home-manager={s}", .{ nixpkgs, hm });
    }
    // home-manager unavailable: the hm workloads will fail visibly rather than
    // silently pass.
    return std.fmt.allocPrint(arena, "nixpkgs={s}", .{nixpkgs});
}

fn matches(filters: []const []const u8, path: []const u8) bool {
    if (filters.len == 0) return true;
    for (filters) |f| if (std.mem.indexOf(u8, path, f) != null) return true;
    return false;
}

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn indent(s: []const u8) []const u8 {
    return s; // detail already prefixed by the caller's format
}

fn trunc(s: []const u8) []const u8 {
    return if (s.len > 200) s[0..200] else s;
}

fn fatal(msg: []const u8) noreturn {
    std.debug.print("bench-fixtures: {s}\n", .{msg});
    std.process.exit(2);
}
