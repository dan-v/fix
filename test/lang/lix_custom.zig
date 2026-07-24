//! The 7 python-backed Lix lang dirs, driven as explicit fix adapters (a port
//! of run.py's custom builders). Each sets up a bespoke fixture tree, runs fix,
//! and compares. Returns one-or-more Results per dir.

const std = @import("std");
const fsx = @import("fsx.zig");
const proc = @import("proc.zig");
const lix = @import("lix.zig");
const Result = @import("result.zig").Result;

/// Dispatch a python-backed dir to its adapter. Unknown dirs (pin drift) surface
/// as a visible failure rather than being dropped.
pub fn run(ctx: lix.Ctx, dir_name: []const u8, arena: std.mem.Allocator) ![]const Result {
    const case_dir = try std.fmt.allocPrint(arena, "{s}/{s}", .{ ctx.lang_dir, dir_name });
    if (std.mem.eql(u8, dir_name, "builtins.getEnv")) return one(arena, try getEnv(ctx, case_dir, arena));
    if (std.mem.eql(u8, dir_name, "builtins.readDir")) return one(arena, try readdirLike(ctx, dir_name, case_dir, arena));
    if (std.mem.eql(u8, dir_name, "builtins.readFileType")) return one(arena, try readdirLike(ctx, dir_name, case_dir, arena));
    if (std.mem.eql(u8, dir_name, "builtins.pathExists")) return one(arena, try pathExists(ctx, case_dir, arena));
    if (std.mem.eql(u8, dir_name, "err_context")) return one(arena, try errContext(ctx, arena));
    if (std.mem.eql(u8, dir_name, "parser-token-whitespace")) return ptw(ctx, case_dir, arena);
    if (std.mem.eql(u8, dir_name, "search-path")) return searchPath(ctx, case_dir, arena);
    return one(arena, Result.fail("lix", try std.fmt.allocPrint(arena, "{s}:custom", .{dir_name}), "unrecognized python-backed test dir (pin drift?)"));
}

fn one(arena: std.mem.Allocator, r: Result) ![]const Result {
    const s = try arena.alloc(Result, 1);
    s[0] = r;
    return s;
}

// --- eval helpers (mirror run.py's _eval / _cmp_eval / _cmp_eval_fail) ------

fn evalRun(ctx: lix.Ctx, cwd: []const u8, flags: []const []const u8, extra_env: []const [2][]const u8, arena: std.mem.Allocator) !proc.Output {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ ctx.fix, "eval", "--workers", "1", "--strict", "--extra-experimental-features", "flakes" });
    try argv.appendSlice(arena, flags);
    try argv.append(arena, "in.nix");
    var env = try proc.cloneEnv(ctx.gpa, ctx.parent_env);
    try env.put("HOME", cwd);
    for (extra_env) |kv| try env.put(kv[0], kv[1]);
    const out = try proc.run(ctx.gpa, ctx.io, argv.items, cwd, &env, proc.case_timeout_ns);
    env.deinit();
    return out;
}

fn cmpEval(ctx: lix.Ctx, ident: []const u8, out: proc.Output, cwd: []const u8, golden_path: []const u8, arena: std.mem.Allocator) !Result {
    const expected = fsx.readFile(arena, ctx.io, golden_path) catch return Result.fail("lix", ident, "missing golden");
    if (out.rc != 0)
        return Result.fail("lix", ident, try std.fmt.allocPrint(arena, "eval failed:\n{s}", .{std.mem.trim(u8, out.stderr, " \n\r\t")}));
    const got = try replaceAll(arena, out.stdout, cwd, "/pwd");
    if (std.mem.eql(u8, std.mem.trim(u8, got, " \n\r\t"), std.mem.trim(u8, expected, " \n\r\t")))
        return Result.pass("lix", ident);
    return Result.fail("lix", ident, try std.fmt.allocPrint(arena, "  expected: {s}\n  actual:   {s}", .{ std.mem.trim(u8, expected, " \n\r\t"), std.mem.trim(u8, got, " \n\r\t") }));
}

// Distinctive words identifying an error's gist (run.py _ERROR_GIST_WORDS).
const gist_words = [_][]const u8{ "reserved for internal use", "shadowing '<nix", "nix-path-shadow" };

fn cmpEvalFail(ctx: lix.Ctx, ident: []const u8, out: proc.Output, cwd: []const u8, expected_err_path: []const u8, arena: std.mem.Allocator) !Result {
    const expected = fsx.readFile(arena, ctx.io, expected_err_path) catch "";
    const err = try replaceAll(arena, out.stderr, cwd, "/pwd");
    if (out.rc == 1 and sharesGist(err, expected)) return Result.pass("lix", ident);
    return Result.fail("lix", ident, try std.fmt.allocPrint(arena, "expected rc 1 + a semantically-matching error; rc={d}\n  actual: {s}", .{ out.rc, std.mem.trim(u8, err, " \n\r\t") }));
}

fn sharesGist(actual: []const u8, expected: []const u8) bool {
    for (gist_words) |w| {
        if (containsCaseless(expected, w) and containsCaseless(actual, w)) return true;
    }
    return false;
}

// --- adapters ---------------------------------------------------------------

fn getEnv(ctx: lix.Ctx, case_dir: []const u8, arena: std.mem.Allocator) !Result {
    const ident = "builtins.getEnv:eval-okay";
    const src = "builtins.getEnv \"TEST_VAR\" + (if builtins.getEnv \"NO_SUCH_VAR\" == \"\" then \"bar\" else \"bla\")";
    const tmp = try fsx.makeTempDir(ctx.gpa, ctx.io);
    defer {
        fsx.removeTree(ctx.io, tmp);
        ctx.gpa.free(tmp);
    }
    try fsx.writeFile(ctx.io, try std.fmt.allocPrint(arena, "{s}/in.nix", .{tmp}), src);
    var out = try evalRun(ctx, tmp, &.{}, &.{.{ "TEST_VAR", "foo" }}, arena);
    defer out.deinit(ctx.gpa);
    return cmpEval(ctx, ident, out, tmp, try std.fmt.allocPrint(arena, "{s}/eval-okay.out.exp", .{case_dir}), arena);
}

fn readdirLike(ctx: lix.Ctx, dir_name: []const u8, case_dir: []const u8, arena: std.mem.Allocator) !Result {
    const ident = try std.fmt.allocPrint(arena, "{s}:eval-okay", .{dir_name});
    const tmp = try fsx.makeTempDir(ctx.gpa, ctx.io);
    defer {
        fsx.removeTree(ctx.io, tmp);
        ctx.gpa.free(tmp);
    }
    const rd = try std.fmt.allocPrint(arena, "{s}/readDir", .{tmp});
    try fsx.mkpath(ctx.io, try std.fmt.allocPrint(arena, "{s}/foo", .{rd}));
    try fsx.writeFile(ctx.io, try std.fmt.allocPrint(arena, "{s}/bar", .{rd}), "");
    try fsx.symlink(ctx.io, "./foo", try std.fmt.allocPrint(arena, "{s}/ldir", .{rd}));
    try fsx.symlink(ctx.io, "./bar", try std.fmt.allocPrint(arena, "{s}/linked", .{rd}));
    try fsx.copyFile(ctx.gpa, ctx.io, try std.fmt.allocPrint(arena, "{s}/in.nix", .{case_dir}), try std.fmt.allocPrint(arena, "{s}/in.nix", .{tmp}));
    var out = try evalRun(ctx, tmp, &.{}, &.{}, arena);
    defer out.deinit(ctx.gpa);
    return cmpEval(ctx, ident, out, tmp, try std.fmt.allocPrint(arena, "{s}/eval-okay.out.exp", .{case_dir}), arena);
}

fn pathExists(ctx: lix.Ctx, case_dir: []const u8, arena: std.mem.Allocator) !Result {
    const ident = "builtins.pathExists:eval-okay";
    const tmp = try fsx.makeTempDir(ctx.gpa, ctx.io);
    defer {
        fsx.removeTree(ctx.io, tmp);
        ctx.gpa.free(tmp);
    }
    const lib = try std.fmt.allocPrint(arena, "{s}/lib.nix", .{ctx.lang_dir});
    const th = try std.fmt.allocPrint(arena, "{s}/test-home", .{tmp});
    try fsx.mkpath(ctx.io, th);
    try fsx.copyFile(ctx.gpa, ctx.io, lib, try std.fmt.allocPrint(arena, "{s}/lib.nix", .{th}));
    const work = try std.fmt.allocPrint(arena, "{s}/work", .{tmp});
    try fsx.mkpath(ctx.io, work);
    try fsx.copyFile(ctx.gpa, ctx.io, try std.fmt.allocPrint(arena, "{s}/in.nix", .{case_dir}), try std.fmt.allocPrint(arena, "{s}/in.nix", .{work}));
    try fsx.copyFile(ctx.gpa, ctx.io, lib, try std.fmt.allocPrint(arena, "{s}/lib.nix", .{work}));
    const sr = try std.fmt.allocPrint(arena, "{s}/symlink-resolution", .{work});
    try fsx.mkpath(ctx.io, try std.fmt.allocPrint(arena, "{s}/foo/lib", .{sr}));
    try fsx.writeFile(ctx.io, try std.fmt.allocPrint(arena, "{s}/foo/lib/default.nix", .{sr}), "\"test\"");
    try fsx.symlink(ctx.io, "../overlays", try std.fmt.allocPrint(arena, "{s}/foo/overlays", .{sr}));
    try fsx.mkpath(ctx.io, try std.fmt.allocPrint(arena, "{s}/overlays", .{sr}));
    try fsx.writeFile(ctx.io, try std.fmt.allocPrint(arena, "{s}/overlays/overlay.nix", .{sr}), "import ../lib");
    try fsx.symlink(ctx.io, "nonexistent", try std.fmt.allocPrint(arena, "{s}/broken", .{sr}));
    // eval runs in work/, HOME=tmp.
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ ctx.fix, "eval", "--workers", "1", "--strict", "--extra-experimental-features", "flakes", "in.nix" });
    var env = try proc.cloneEnv(ctx.gpa, ctx.parent_env);
    defer env.deinit();
    try env.put("HOME", tmp);
    var out = try proc.run(ctx.gpa, ctx.io, argv.items, work, &env, proc.case_timeout_ns);
    defer out.deinit(ctx.gpa);
    return cmpEval(ctx, ident, out, work, try std.fmt.allocPrint(arena, "{s}/eval-okay.out.exp", .{case_dir}), arena);
}

fn errContext(ctx: lix.Ctx, arena: std.mem.Allocator) !Result {
    const ident = "err_context:eval-fail";
    const expr = "builtins.addErrorContext \"Hello\" (throw \"Foo\")";
    const tmp = try fsx.makeTempDir(ctx.gpa, ctx.io);
    defer {
        fsx.removeTree(ctx.io, tmp);
        ctx.gpa.free(tmp);
    }
    const argv = [_][]const u8{ ctx.fix, "eval", "--workers", "1", "--show-trace", "-E", expr };
    var env = try proc.cloneEnv(ctx.gpa, ctx.parent_env);
    defer env.deinit();
    var out = try proc.run(ctx.gpa, ctx.io, &argv, tmp, &env, proc.case_timeout_ns);
    defer out.deinit(ctx.gpa);
    if (out.rc != 0 and std.mem.indexOf(u8, out.stderr, "Hello") != null) return Result.pass("lix", ident);
    return Result.fail("lix", ident, try std.fmt.allocPrint(arena, "expected rc!=0 with 'Hello' in stderr; rc={d}\n{s}", .{ out.rc, std.mem.trim(u8, out.stderr, " \n\r\t") }));
}

// parser-token-whitespace: 17 exprs x {(),[]} x {plain,depr} = 68 cases.
const PtwExpr = struct { e: []const u8, code_a: i32, code_b: i32 };
const ptw_exprs = [_]PtwExpr{
    .{ .e = "00012.3", .code_a = 1, .code_b = 0 },    .{ .e = "0a", .code_a = 1, .code_b = 0 },
    .{ .e = "0https://a", .code_a = 1, .code_b = 0 }, .{ .e = "0.0.0", .code_a = 1, .code_b = 0 },
    .{ .e = "foo\"1\"2", .code_a = 1, .code_b = 0 },  .{ .e = "0x10", .code_a = 1, .code_b = 0 },
    .{ .e = "0.", .code_a = 1, .code_b = 1 },         .{ .e = "1.", .code_a = 0, .code_b = 0 },
    .{ .e = "0.a", .code_a = 1, .code_b = 0 },        .{ .e = "1.a", .code_a = 1, .code_b = 0 },
    .{ .e = "0.\"\"", .code_a = 1, .code_b = 0 },     .{ .e = "1.\"\"", .code_a = 1, .code_b = 0 },
    .{ .e = "(0)(0)", .code_a = 0, .code_b = 0 },     .{ .e = "a(\"\")", .code_a = 0, .code_b = 0 },
    .{ .e = "(a).a", .code_a = 0, .code_b = 0 },      .{ .e = "(a).0", .code_a = 0, .code_b = 0 },
    .{ .e = "00.", .code_a = 1, .code_b = 1 },
};

fn ptw(ctx: lix.Ctx, case_dir: []const u8, arena: std.mem.Allocator) ![]const Result {
    var results: std.ArrayListUnmanaged(Result) = .empty;
    const tmp = try fsx.makeTempDir(ctx.gpa, ctx.io);
    defer {
        fsx.removeTree(ctx.io, tmp);
        ctx.gpa.free(tmp);
    }
    for (ptw_exprs) |pe| {
        for ([_][]const u8{ "(", "[" }) |open| {
            const close: []const u8 = if (open[0] == '(') ")" else "]";
            const wrapped = try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ open, pe.e, close });
            const f_expr = try replaceAll(arena, wrapped, "/", "-");
            const full = try std.fmt.allocPrint(arena, "with {{}}; {s}", .{wrapped});
            try results.append(arena, try ptwCase(ctx, case_dir, tmp, f_expr, full, &.{ "--extra-deprecated-features", "url-literals" }, pe.code_a, arena));
            try results.append(arena, try ptwCase(ctx, case_dir, tmp, try std.fmt.allocPrint(arena, "{s}-depr", .{f_expr}), full, &.{ "--extra-deprecated-features", "tokens-no-whitespace url-literals" }, pe.code_b, arena));
        }
    }
    return results.items;
}

fn ptwCase(ctx: lix.Ctx, case_dir: []const u8, tmp: []const u8, golden_base: []const u8, full: []const u8, flags: []const []const u8, expected_rc: i32, arena: std.mem.Allocator) !Result {
    const ident = try std.fmt.allocPrint(arena, "parser-token-whitespace:{s}", .{golden_base});
    const out_g = try std.fmt.allocPrint(arena, "{s}/{s}.out.exp", .{ case_dir, golden_base });
    const err_g = try std.fmt.allocPrint(arena, "{s}/{s}.err.exp", .{ case_dir, golden_base });

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ ctx.fix, "parse", "--json" });
    try argv.appendSlice(arena, flags);
    try argv.appendSlice(arena, &.{ "-E", full });
    var out = try proc.run(ctx.gpa, ctx.io, argv.items, tmp, null, proc.case_timeout_ns);
    defer out.deinit(ctx.gpa);

    if (out.rc != expected_rc)
        return Result.fail("lix", ident, try std.fmt.allocPrint(arena, "rc={d} (expected {d})\n  stderr={s}", .{ out.rc, expected_rc, std.mem.trim(u8, out.stderr, " \n\r\t") }));
    if (expected_rc != 0) {
        if (std.mem.trim(u8, out.stdout, " \n\r\t").len != 0)
            return Result.fail("lix", ident, "expected no AST");
        return Result.pass("lix", ident);
    }
    const expected_out = fsx.readFile(arena, ctx.io, out_g) catch "";
    if (!std.mem.eql(u8, std.mem.trimEnd(u8, out.stdout, "\n"), std.mem.trimEnd(u8, expected_out, "\n")))
        return Result.fail("lix", ident, try std.fmt.allocPrint(arena, "  expected: {s}\n  actual:   {s}", .{ std.mem.trim(u8, expected_out, " \n\r\t"), std.mem.trim(u8, out.stdout, " \n\r\t") }));
    const expected_err = fsx.readFile(arena, ctx.io, err_g) catch "";
    if (lix.warningKinds(expected_err) & ~lix.warningKinds(out.stderr) != 0)
        return Result.fail("lix", ident, "AST matches but missing warning(s)");
    return Result.pass("lix", ident);
}

fn searchPath(ctx: lix.Ctx, case_dir: []const u8, arena: std.mem.Allocator) ![]const Result {
    var results: std.ArrayListUnmanaged(Result) = .empty;

    // (i) full search path, deprecated shadow-internal-symbols
    {
        const tmp = try spSetup(ctx, case_dir, &.{ "dir1", "dir2", "dir3", "dir4" }, "in.nix", true, arena);
        defer cleanup(ctx, tmp);
        var out = try evalRunFlagsEnv(ctx, tmp, &.{ "--extra-deprecated-features", "shadow-internal-symbols", "-I", "dir1", "-I", "dir2", "-I", "dir5=dir3" }, &.{ .{ "NIX_PATH", "dir3:dir4" }, .{ "HOME", tmp } }, arena);
        defer out.deinit(ctx.gpa);
        try results.append(arena, try cmpEval(ctx, "search-path:eval-okay", out, tmp, try std.fmt.allocPrint(arena, "{s}/eval-okay.out.exp", .{case_dir}), arena));
    }
    // (ii) nix=... prefix, deprecation silenced
    {
        const tmp = try spSetup(ctx, case_dir, &.{"nix-shadow"}, "in-fetchurl.nix", false, arena);
        defer cleanup(ctx, tmp);
        var out = try evalRunFlagsEnv(ctx, tmp, &.{ "--extra-deprecated-features", "nix-path-shadow" }, &.{ .{ "NIX_PATH", "nix=nix-shadow" }, .{ "HOME", tmp } }, arena);
        defer out.deinit(ctx.gpa);
        try results.append(arena, try cmpEval(ctx, "search-path:prefixed-deprecated", out, tmp, try std.fmt.allocPrint(arena, "{s}/eval-okay-prefixed.out.exp", .{case_dir}), arena));
    }
    // (iii) nix=... prefix without deprecation -> reserved-prefix error
    {
        const tmp = try spSetup(ctx, case_dir, &.{"nix-shadow"}, "in-fetchurl.nix", false, arena);
        defer cleanup(ctx, tmp);
        var out = try evalRunFlagsEnv(ctx, tmp, &.{}, &.{ .{ "NIX_PATH", "nix=nix-shadow" }, .{ "HOME", tmp } }, arena);
        defer out.deinit(ctx.gpa);
        try results.append(arena, try cmpEvalFail(ctx, "search-path:prefixed", out, tmp, try std.fmt.allocPrint(arena, "{s}/eval-okay-prefixed.err.exp", .{case_dir}), arena));
    }
    // (iv) prefixless -I, deprecation silenced
    {
        const tmp = try spSetup(ctx, case_dir, &.{"nix-shadow"}, "in-fetchurl.nix", false, arena);
        defer cleanup(ctx, tmp);
        var out = try evalRunFlagsEnv(ctx, tmp, &.{ "--extra-deprecated-features", "nix-path-shadow", "-I", "nix-shadow" }, &.{.{ "HOME", tmp }}, arena);
        defer out.deinit(ctx.gpa);
        try results.append(arena, try cmpEval(ctx, "search-path:prefixless-deprecated", out, tmp, try std.fmt.allocPrint(arena, "{s}/eval-okay-prefixless.out.exp", .{case_dir}), arena));
    }
    // (v) prefixless -I without deprecation -> shadow error
    {
        const tmp = try spSetup(ctx, case_dir, &.{"nix-shadow"}, "in-fetchurl.nix", false, arena);
        defer cleanup(ctx, tmp);
        var out = try evalRunFlagsEnv(ctx, tmp, &.{ "-I", "nix-shadow" }, &.{.{ "HOME", tmp }}, arena);
        defer out.deinit(ctx.gpa);
        try results.append(arena, try cmpEvalFail(ctx, "search-path:prefixless", out, tmp, try std.fmt.allocPrint(arena, "{s}/eval-okay-prefixless.err.exp", .{case_dir}), arena));
    }
    // (vi) empty search path -> corepkg fetchurl
    {
        const tmp = try spSetup(ctx, case_dir, &.{}, "in-fetchurl.nix", false, arena);
        defer cleanup(ctx, tmp);
        var out = try evalRunFlagsEnv(ctx, tmp, &.{}, &.{.{ "HOME", tmp }}, arena);
        defer out.deinit(ctx.gpa);
        try results.append(arena, try cmpEval(ctx, "search-path:empty", out, tmp, try std.fmt.allocPrint(arena, "{s}/eval-okay-fetchurl.out.exp", .{case_dir}), arena));
    }
    return results.items;
}

fn spSetup(ctx: lix.Ctx, case_dir: []const u8, trees: []const []const u8, in_src: []const u8, lib: bool, arena: std.mem.Allocator) ![]const u8 {
    const tmp = try fsx.makeTempDir(ctx.gpa, ctx.io);
    for (trees) |t|
        try fsx.copyTree(ctx.gpa, ctx.io, try std.fmt.allocPrint(arena, "{s}/{s}", .{ case_dir, t }), try std.fmt.allocPrint(arena, "{s}/{s}", .{ tmp, t }));
    if (lib)
        try fsx.copyFile(ctx.gpa, ctx.io, try std.fmt.allocPrint(arena, "{s}/lib.nix", .{ctx.lang_dir}), try std.fmt.allocPrint(arena, "{s}/lib.nix", .{tmp}));
    try fsx.copyFile(ctx.gpa, ctx.io, try std.fmt.allocPrint(arena, "{s}/{s}", .{ case_dir, in_src }), try std.fmt.allocPrint(arena, "{s}/in.nix", .{tmp}));
    return tmp;
}

fn evalRunFlagsEnv(ctx: lix.Ctx, cwd: []const u8, flags: []const []const u8, extra_env: []const [2][]const u8, arena: std.mem.Allocator) !proc.Output {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ ctx.fix, "eval", "--workers", "1", "--strict", "--extra-experimental-features", "flakes" });
    try argv.appendSlice(arena, flags);
    try argv.append(arena, "in.nix");
    var env = try proc.cloneEnv(ctx.gpa, ctx.parent_env);
    for (extra_env) |kv| try env.put(kv[0], kv[1]);
    const out = try proc.run(ctx.gpa, ctx.io, argv.items, cwd, &env, proc.case_timeout_ns);
    env.deinit();
    return out;
}

fn cleanup(ctx: lix.Ctx, tmp: []const u8) void {
    fsx.removeTree(ctx.io, tmp);
    ctx.gpa.free(tmp);
}

// --- helpers ----------------------------------------------------------------

fn replaceAll(arena: std.mem.Allocator, haystack: []const u8, needle: []const u8, repl: []const u8) ![]const u8 {
    if (needle.len == 0 or std.mem.indexOf(u8, haystack, needle) == null) return haystack;
    const size = std.mem.replacementSize(u8, haystack, needle, repl);
    const buf = try arena.alloc(u8, size);
    _ = std.mem.replace(u8, haystack, needle, repl, buf);
    return buf;
}

fn containsCaseless(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}
