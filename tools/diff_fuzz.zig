//! Differential fuzzer for fix.
//!
//! The generator deliberately avoids owning a second Nix grammar. It mutates a
//! corpus of real expressions, then asks real Nix and fix what each candidate
//! means.

const std = @import("std");

const Config = struct {
    iterations: usize = 100,
    seed: u64 = 0x8b5f_19d3_7442_0c11,
    corpus_dir: []const u8 = "tools/fuzz-corpus",
    failure_dir: []const u8 = "zig-out/fuzz-failures",
    fix_bin: []const u8 = "zig-out/bin/fix",
    nix_bin: []const u8 = "nix-instantiate",
    max_mutations: u8 = 5,
    shrink: bool = true,
};

const Corpus = std.ArrayListUnmanaged([]const u8);

const Outcome = enum {
    both_ok_same,
    both_ok_different,
    nix_accepts_fix_rejects,
    fix_accepts_nix_rejects,
    both_reject,
};

const CommandResult = struct {
    ok: bool,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: CommandResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

const Classification = struct {
    outcome: Outcome,
    nix: CommandResult,
    fix: CommandResult,

    fn deinit(self: Classification, allocator: std.mem.Allocator) void {
        self.nix.deinit(allocator);
        self.fix.deinit(allocator);
    }

    fn interesting(self: Classification) bool {
        return switch (self.outcome) {
            .both_ok_same, .both_reject => false,
            .both_ok_different, .nix_accepts_fix_rejects, .fix_accepts_nix_rejects => true,
        };
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var config = Config{};
    try parseArgs(allocator, &config, init);

    var corpus: Corpus = .empty;
    defer {
        for (corpus.items) |expr| allocator.free(expr);
        corpus.deinit(allocator);
    }
    try loadCorpus(allocator, init.io, config.corpus_dir, &corpus);
    if (corpus.items.len == 0) try loadDefaultCorpus(allocator, &corpus);

    var prng = std.Random.DefaultPrng.init(config.seed);
    const random = prng.random();

    std.debug.print(
        "diff-fuzz: iterations={} seed={} corpus={}\n",
        .{ config.iterations, config.seed, corpus.items.len },
    );

    var i: usize = 0;
    while (i < config.iterations) : (i += 1) {
        const expr = try mutateExpression(allocator, random, corpus.items, config.max_mutations);
        defer allocator.free(expr);

        var classification = classify(allocator, init.io, &config, expr) catch |err| {
            std.debug.print("diff-fuzz: command failed at iteration {}: {s}\n", .{ i, @errorName(err) });
            return err;
        };
        defer classification.deinit(allocator);

        if (classification.interesting()) {
            const shrunk = if (config.shrink)
                try shrinkInteresting(allocator, init.io, &config, expr, classification.outcome)
            else
                try allocator.dupe(u8, expr);
            defer allocator.free(shrunk);

            var shrunk_classification = try classify(allocator, init.io, &config, shrunk);
            defer shrunk_classification.deinit(allocator);

            try saveFailure(allocator, init.io, &config, i, shrunk, shrunk_classification);
            std.debug.print(
                "diff-fuzz: found {s} at iteration {}; saved under {s}\n",
                .{ @tagName(shrunk_classification.outcome), i, config.failure_dir },
            );
            std.debug.print("expression:\n{s}\n", .{shrunk});
            return error.DifferentialMismatch;
        }
    }

    std.debug.print("diff-fuzz: no mismatches found\n", .{});
}

fn parseArgs(allocator: std.mem.Allocator, config: *Config, init: std.process.Init) !void {
    _ = allocator;
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();

    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--iterations")) {
            config.iterations = try std.fmt.parseInt(usize, args.next() orelse return error.MissingArgument, 10);
        } else if (std.mem.eql(u8, arg, "--seed")) {
            config.seed = try std.fmt.parseInt(u64, args.next() orelse return error.MissingArgument, 0);
        } else if (std.mem.eql(u8, arg, "--corpus")) {
            config.corpus_dir = args.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--failures")) {
            config.failure_dir = args.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--fix-bin")) {
            config.fix_bin = args.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--nix-bin")) {
            config.nix_bin = args.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--max-mutations")) {
            config.max_mutations = try std.fmt.parseInt(u8, args.next() orelse return error.MissingArgument, 10);
        } else if (std.mem.eql(u8, arg, "--no-shrink")) {
            config.shrink = false;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            usage();
            std.process.exit(0);
        } else {
            std.debug.print("unknown argument: {s}\n", .{arg});
            usage();
            return error.UnknownArgument;
        }
    }
}

fn usage() void {
    std.debug.print(
        \\usage: zig build diff-fuzz -- [options]
        \\
        \\options:
        \\  --iterations N      number of generated expressions (default: 100)
        \\  --seed N            deterministic RNG seed
        \\  --corpus PATH       directory of .nix seed files
        \\  --failures PATH     directory for reproducers
        \\  --fix-bin PATH      fix executable (default: zig-out/bin/fix)
        \\  --nix-bin PATH      nix-instantiate executable
        \\  --max-mutations N   mutations per candidate (default: 5)
        \\  --no-shrink         save the original failing candidate
        \\
    , .{});
}

fn loadCorpus(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    corpus: *Corpus,
) !void {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |e| return e,
    };
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".nix")) continue;

        const text = try dir.readFileAlloc(io, entry.name, allocator, .limited(1024 * 1024));
        defer allocator.free(text);
        try appendCorpusLines(allocator, text, corpus);
    }
}

fn loadDefaultCorpus(allocator: std.mem.Allocator, corpus: *Corpus) !void {
    const defaults = [_][]const u8{
        "1",
        "1 + 2",
        "let x = 1; in x",
        "{ a = 1; }",
        "[ 1 2 ]",
        "(x: x) 1",
    };
    for (defaults) |expr| try corpus.append(allocator, try allocator.dupe(u8, expr));
}

fn appendCorpusLines(allocator: std.mem.Allocator, text: []const u8, corpus: *Corpus) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        try corpus.append(allocator, try allocator.dupe(u8, trimmed));
    }
}

fn mutateExpression(
    allocator: std.mem.Allocator,
    random: std.Random,
    corpus: []const []const u8,
    max_mutations: u8,
) ![]u8 {
    var expr = try allocator.dupe(u8, corpus[random.intRangeLessThan(usize, 0, corpus.len)]);
    errdefer allocator.free(expr);

    const mutation_count = random.intRangeAtMost(u8, 1, @max(max_mutations, 1));
    var i: u8 = 0;
    while (i < mutation_count) : (i += 1) {
        const next = try mutateOnce(allocator, random, expr, corpus);
        allocator.free(expr);
        expr = next;
    }
    return expr;
}

fn mutateOnce(
    allocator: std.mem.Allocator,
    random: std.Random,
    expr: []const u8,
    corpus: []const []const u8,
) ![]u8 {
    const other = corpus[random.intRangeLessThan(usize, 0, corpus.len)];
    return switch (random.intRangeLessThan(u8, 0, 17)) {
        0 => wrap(allocator, "(", expr, ")"),
        1 => wrap(allocator, "let x = ", expr, "; in x"),
        2 => wrap(allocator, "if true then ", expr, " else 1"),
        3 => wrap(allocator, "if false then 1 else ", expr, ""),
        4 => wrap(allocator, "[ ", expr, " ]"),
        5 => wrap(allocator, "{ a = ", expr, "; }"),
        6 => wrap(allocator, "({ a = ", expr, "; }).a"),
        7 => wrap(allocator, "(rec { a = ", expr, "; b = a; }).b"),
        8 => wrap(allocator, "with { x = ", expr, "; }; x"),
        9 => wrap(allocator, "assert true; ", expr, ""),
        10 => wrap(allocator, "(x: ", expr, ") 1"),
        11 => binary(allocator, expr, "+", other),
        12 => binary(allocator, expr, "==", other),
        13 => binary(allocator, expr, "//", other),
        14 => binary(allocator, expr, "or", other),
        15 => replaceLiteral(allocator, random),
        else => spliceLet(allocator, expr, other),
    };
}

fn wrap(allocator: std.mem.Allocator, prefix: []const u8, expr: []const u8, suffix: []const u8) ![]u8 {
    return std.mem.concat(allocator, u8, &.{ prefix, expr, suffix });
}

fn binary(allocator: std.mem.Allocator, left: []const u8, op: []const u8, right: []const u8) ![]u8 {
    return std.mem.concat(allocator, u8, &.{ "(", left, ") ", op, " (", right, ")" });
}

fn spliceLet(allocator: std.mem.Allocator, left: []const u8, right: []const u8) ![]u8 {
    return std.mem.concat(allocator, u8, &.{ "let x = ", left, "; y = ", right, "; in x" });
}

fn replaceLiteral(allocator: std.mem.Allocator, random: std.Random) ![]u8 {
    const literals = [_][]const u8{
        "0",
        "1",
        "-1",
        "1.5",
        "true",
        "false",
        "null",
        "\"x\"",
        "\"\"",
        "[]",
        "{}",
        "1 / 0",
    };
    return allocator.dupe(u8, literals[random.intRangeLessThan(usize, 0, literals.len)]);
}

fn classify(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: *const Config,
    expr: []const u8,
) !Classification {
    const nix = try runCommand(allocator, io, &.{ config.nix_bin, "--eval", "--expr", expr });
    errdefer nix.deinit(allocator);

    const fix = try runCommand(allocator, io, &.{ config.fix_bin, expr });
    errdefer fix.deinit(allocator);

    const outcome: Outcome = if (nix.ok and fix.ok)
        if (!comparableOutput(nix.stdout) or !comparableOutput(fix.stdout) or std.mem.eql(u8, normalize(nix.stdout), normalize(fix.stdout))) .both_ok_same else .both_ok_different
    else if (nix.ok and !fix.ok)
        .nix_accepts_fix_rejects
    else if (!nix.ok and fix.ok)
        .fix_accepts_nix_rejects
    else
        .both_reject;

    return .{
        .outcome = outcome,
        .nix = nix,
        .fix = fix,
    };
}

fn runCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
) !CommandResult {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });

    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };

    return .{
        .ok = ok,
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

fn normalize(bytes: []const u8) []const u8 {
    return std.mem.trim(u8, bytes, " \t\r\n");
}

fn comparableOutput(bytes: []const u8) bool {
    const trimmed = normalize(bytes);
    if (trimmed.len == 0) return false;
    if (std.mem.indexOf(u8, trimmed, "...") != null) return false;
    return switch (trimmed[0]) {
        '[', '{' => false,
        else => true,
    };
}

fn shrinkInteresting(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: *const Config,
    expr: []const u8,
    target: Outcome,
) ![]u8 {
    var current = try allocator.dupe(u8, expr);
    errdefer allocator.free(current);

    var changed = true;
    while (changed) {
        changed = false;

        var candidates: Corpus = .empty;
        defer {
            for (candidates.items) |candidate| allocator.free(candidate);
            candidates.deinit(allocator);
        }
        try shrinkCandidates(allocator, current, &candidates);

        for (candidates.items) |candidate| {
            if (candidate.len == 0 or candidate.len >= current.len) continue;
            var c = try classify(allocator, io, config, candidate);
            defer c.deinit(allocator);
            if (c.outcome == target) {
                allocator.free(current);
                current = try allocator.dupe(u8, candidate);
                changed = true;
                break;
            }
        }
    }

    return current;
}

fn shrinkCandidates(allocator: std.mem.Allocator, expr: []const u8, out: *Corpus) !void {
    const constants = [_][]const u8{ "1", "true", "false", "null", "[]", "{}" };
    for (constants) |constant| try out.append(allocator, try allocator.dupe(u8, constant));

    const trimmed = std.mem.trim(u8, expr, " \t\r\n");
    if (trimmed.len >= 2 and trimmed[0] == '(' and trimmed[trimmed.len - 1] == ')' and balanced(trimmed[1 .. trimmed.len - 1])) {
        try out.append(allocator, try allocator.dupe(u8, trimmed[1 .. trimmed.len - 1]));
    }

    var i: usize = 0;
    while (i < expr.len) : (i += 1) {
        if (expr[i] != '(' and expr[i] != '[' and expr[i] != '{') continue;
        if (matchingClose(expr[i])) |close| {
            if (findMatching(expr, i, close)) |end| {
                try out.append(allocator, try std.mem.concat(allocator, u8, &.{ expr[0..i], "1", expr[end + 1 ..] }));
            }
        }
    }
}

fn matchingClose(open: u8) ?u8 {
    return switch (open) {
        '(' => ')',
        '[' => ']',
        '{' => '}',
        else => null,
    };
}

fn findMatching(expr: []const u8, start: usize, close: u8) ?usize {
    var depth: usize = 0;
    var in_string = false;
    var i = start;
    while (i < expr.len) : (i += 1) {
        const c = expr[i];
        if (in_string) {
            if (c == '\\') {
                i += 1;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        if (c == '"') {
            in_string = true;
        } else if (c == expr[start]) {
            depth += 1;
        } else if (c == close) {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn balanced(expr: []const u8) bool {
    var parens: isize = 0;
    var brackets: isize = 0;
    var braces: isize = 0;
    var in_string = false;

    var i: usize = 0;
    while (i < expr.len) : (i += 1) {
        const c = expr[i];
        if (in_string) {
            if (c == '\\') {
                i += 1;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '(' => parens += 1,
            ')' => parens -= 1,
            '[' => brackets += 1,
            ']' => brackets -= 1,
            '{' => braces += 1,
            '}' => braces -= 1,
            else => {},
        }
        if (parens < 0 or brackets < 0 or braces < 0) return false;
    }
    return !in_string and parens == 0 and brackets == 0 and braces == 0;
}

fn saveFailure(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: *const Config,
    iteration: usize,
    expr: []const u8,
    classification: Classification,
) !void {
    try std.Io.Dir.cwd().createDirPath(io, config.failure_dir);

    const prefix = try std.fmt.allocPrint(allocator, "{s}/case-{d}-{s}", .{
        config.failure_dir,
        iteration,
        @tagName(classification.outcome),
    });
    defer allocator.free(prefix);

    const expr_path = try std.fmt.allocPrint(allocator, "{s}.nix", .{prefix});
    defer allocator.free(expr_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = expr_path, .data = expr });

    const report = try std.fmt.allocPrint(allocator,
        \\outcome: {s}
        \\iteration: {d}
        \\
        \\expression:
        \\{s}
        \\
        \\nix ok: {}
        \\nix stdout:
        \\{s}
        \\nix stderr:
        \\{s}
        \\
        \\fix ok: {}
        \\fix stdout:
        \\{s}
        \\fix stderr:
        \\{s}
        \\
    , .{
        @tagName(classification.outcome),
        iteration,
        expr,
        classification.nix.ok,
        classification.nix.stdout,
        classification.nix.stderr,
        classification.fix.ok,
        classification.fix.stdout,
        classification.fix.stderr,
    });
    defer allocator.free(report);

    const report_path = try std.fmt.allocPrint(allocator, "{s}.txt", .{prefix});
    defer allocator.free(report_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = report_path, .data = report });
}
