const std = @import("std");

pub const Fragment = struct {
    text: []const u8,
    free_names: []const []const u8 = &.{},

    pub fn deinit(self: Fragment, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        for (self.free_names) |name| allocator.free(name);
        if (self.free_names.len != 0) allocator.free(self.free_names);
    }

    fn closed(self: Fragment) bool {
        return self.free_names.len == 0;
    }
};

pub const GeneratedCase = struct {
    index: usize,
    expr: []u8,
    skipped: bool = false,

    pub fn deinit(self: GeneratedCase, allocator: std.mem.Allocator) void {
        allocator.free(self.expr);
    }
};

pub const CaseSpace = struct {
    corpus: []const Fragment,
    seed: u64,
    min_depth: u8,
    max_depth: u8,
    total: usize,

    fn generate(self: CaseSpace, allocator: std.mem.Allocator, index: usize) !GeneratedCase {
        return generateCase(allocator, self.corpus, self.seed, index, self.min_depth, self.max_depth);
    }
};

pub const Template = enum {
    direct_add,
    let_scope,
    with_scope,
    rec_scope,
    lambda_scope,
};

pub const FragmentCorpus = std.ArrayListUnmanaged(Fragment);
pub fn loadCorpus(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    corpus: *FragmentCorpus,
) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
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

fn appendCorpusLines(allocator: std.mem.Allocator, text: []const u8, corpus: *FragmentCorpus) !void {
    var pending_free_names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (pending_free_names.items) |name| allocator.free(name);
        pending_free_names.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (trimmed[0] == '#') {
            if (std.mem.startsWith(u8, trimmed, "# free:")) {
                for (pending_free_names.items) |name| allocator.free(name);
                pending_free_names.clearRetainingCapacity();
                try appendFreeNameList(allocator, &pending_free_names, trimmed["# free:".len..]);
            }
            continue;
        }

        const free_names = try pending_free_names.toOwnedSlice(allocator);
        pending_free_names = .empty;
        const fragment_text = allocator.dupe(u8, trimmed) catch |err| {
            freeNames(allocator, free_names);
            return err;
        };
        var fragment: Fragment = .{
            .text = fragment_text,
            .free_names = free_names,
        };
        corpus.append(allocator, fragment) catch |err| {
            fragment.deinit(allocator);
            return err;
        };
    }
}

fn appendFreeNameList(
    allocator: std.mem.Allocator,
    names: *std.ArrayListUnmanaged([]const u8),
    text: []const u8,
) !void {
    var parts = std.mem.tokenizeAny(u8, text, " \t\r,");
    while (parts.next()) |name| {
        if (!validBinderName(name)) return error.InvalidFreeName;
        try appendUniqueName(allocator, names, name);
    }
}

fn validBinderName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!isIdentStart(name[0])) return false;
    for (name[1..]) |c| {
        if (!isIdentRest(c)) return false;
    }
    return true;
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentRest(c: u8) bool {
    return isIdentStart(c) or std.ascii.isDigit(c) or c == '\'' or c == '-';
}

pub fn sortCorpus(corpus: []Fragment) void {
    std.mem.sort(Fragment, corpus, {}, lessThanExpr);
}

fn lessThanExpr(_: void, lhs: Fragment, rhs: Fragment) bool {
    return std.mem.lessThan(u8, lhs.text, rhs.text);
}

pub fn dumpGeneratedCases(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: anytype,
    case_space: CaseSpace,
    reporter: anytype,
) !void {
    var cases = try DumpFile.open(io, config.dump_cases_path);
    defer cases.close();
    var skipped = try DumpFile.open(io, config.dump_skipped_path);
    defer skipped.close();

    var index: usize = 0;
    while (index < case_space.total) : (index += 1) {
        const generated = try case_space.generate(allocator, index);
        errdefer generated.deinit(allocator);

        if (generated.skipped) {
            try skipped.writeLine(generated.expr);
            reporter.skipped();
        } else {
            try cases.writeLine(generated.expr);
            reporter.checked();
        }
        generated.deinit(allocator);
        reporter.progress(index + 1, case_space.total);
    }
}

const DumpFile = struct {
    io: std.Io,
    file: ?std.Io.File = null,

    fn open(io: std.Io, maybe_path: ?[]const u8) !DumpFile {
        const path = maybe_path orelse return .{ .io = io };
        if (std.fs.path.dirname(path)) |dir| try std.Io.Dir.cwd().createDirPath(io, dir);
        return .{
            .io = io,
            .file = try std.Io.Dir.cwd().createFile(io, path, .{}),
        };
    }

    fn close(self: *DumpFile) void {
        if (self.file) |file| file.close(self.io);
        self.file = null;
    }

    fn writeLine(self: DumpFile, line: []const u8) !void {
        const file = self.file orelse return;
        try file.writeStreamingAll(self.io, line);
        try file.writeStreamingAll(self.io, "\n");
    }
};

fn generateCase(
    allocator: std.mem.Allocator,
    corpus: []const Fragment,
    seed: u64,
    iteration: usize,
    min_depth: u8,
    max_depth: u8,
) !GeneratedCase {
    var prng = casePrng(seed, iteration);
    const random = prng.random();
    const depth = random.intRangeAtMost(u8, min_depth, max_depth);
    var fragment = try generateFragment(allocator, corpus, random, depth);
    errdefer fragment.deinit(allocator);

    const skipped = !fragment.closed();
    const expr = try allocator.dupe(u8, fragment.text);
    fragment.deinit(allocator);
    return .{ .index = iteration, .expr = expr, .skipped = skipped };
}

fn generateFragment(
    allocator: std.mem.Allocator,
    corpus: []const Fragment,
    random: std.Random,
    depth: u8,
) !Fragment {
    if (depth == 0) {
        return cloneFragment(allocator, corpus[random.uintLessThan(usize, corpus.len)]);
    }

    var left = try generateFragment(allocator, corpus, random, depth - 1);
    defer left.deinit(allocator);
    var right = try generateFragment(allocator, corpus, random, depth - 1);
    defer right.deinit(allocator);

    return composeFragments(allocator, left, right, depth);
}

fn composeFragments(allocator: std.mem.Allocator, left: Fragment, right: Fragment, depth: u8) !Fragment {
    return if (right.free_names.len != 0)
        scopedBodyFragment(allocator, left, right, depth)
    else if (left.free_names.len != 0)
        scopedBodyFragment(allocator, right, left, depth)
    else
        closedPairFragment(allocator, left, right, depth);
}

test "generated fragments recursively compose to requested depth" {
    const corpus = [_]Fragment{.{ .text = "1" }};
    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();

    var leaf = try generateFragment(std.testing.allocator, &corpus, random, 0);
    defer leaf.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("1", leaf.text);

    var one = try generateFragment(std.testing.allocator, &corpus, random, 1);
    defer one.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("(1) + (1)", one.text);

    var two = try generateFragment(std.testing.allocator, &corpus, random, 2);
    defer two.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("let x = (1) + (1); y = (1) + (1); in x + y", two.text);
}

test "generated fragments bind free names during composition" {
    const free_names = [_][]const u8{"x"};
    const value: Fragment = .{ .text = "1" };
    const body: Fragment = .{ .text = "x", .free_names = &free_names };

    var fragment = try composeFragments(std.testing.allocator, value, body, 1);
    defer fragment.deinit(std.testing.allocator);

    try std.testing.expect(fragment.closed());
    try std.testing.expectEqualStrings("let x = 1; in x", fragment.text);
}

pub fn generateWorkerCase(
    allocator: std.mem.Allocator,
    case_space: CaseSpace,
    index: usize,
) !GeneratedCase {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const generated = try case_space.generate(arena.allocator(), index);
    return .{
        .index = generated.index,
        .expr = try allocator.dupe(u8, generated.expr),
        .skipped = generated.skipped,
    };
}

fn casePrng(seed: u64, index: usize) std.Random.DefaultPrng {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, @intCast(index), .little);
    return std.Random.DefaultPrng.init(std.hash.Wyhash.hash(seed, &bytes));
}

fn closedPairFragment(allocator: std.mem.Allocator, left: Fragment, right: Fragment, depth: u8) !Fragment {
    const template = closedTemplate(depth);
    const text = switch (template) {
        .direct_add => try binary(allocator, left.text, "+", right.text),
        .let_scope => try std.mem.concat(allocator, u8, &.{ "let x = ", left.text, "; y = ", right.text, "; in x + y" }),
        .with_scope => try std.mem.concat(allocator, u8, &.{ "with { x = ", left.text, "; y = ", right.text, "; }; x + y" }),
        .rec_scope => try std.mem.concat(allocator, u8, &.{ "(rec { x = ", left.text, "; y = ", right.text, "; z = x + y; }).z" }),
        .lambda_scope => try std.mem.concat(allocator, u8, &.{ "(x: y: x + y) (", left.text, ") (", right.text, ")" }),
    };
    errdefer allocator.free(text);
    return .{
        .text = text,
        .free_names = try unionNames(allocator, left.free_names, right.free_names),
    };
}

fn scopedBodyFragment(allocator: std.mem.Allocator, value: Fragment, body: Fragment, depth: u8) !Fragment {
    var fragment = try cloneFragment(allocator, body);
    errdefer fragment.deinit(allocator);

    var step: u8 = 0;
    while (step < depth and fragment.free_names.len != 0) : (step += 1) {
        const name = fragment.free_names[0];
        const template = binderTemplate(step);
        const next = try bindOneFreeName(allocator, template, value, fragment, name);
        fragment.deinit(allocator);
        fragment = next;
    }

    return fragment;
}

fn closedTemplate(depth: u8) Template {
    const tier = if (depth == 0) 0 else (depth - 1) % 5;
    return switch (tier) {
        0 => .direct_add,
        1 => .let_scope,
        2 => .with_scope,
        3 => .rec_scope,
        else => .lambda_scope,
    };
}

fn binderTemplate(step: u8) Template {
    return switch (step % 4) {
        0 => .let_scope,
        1 => .with_scope,
        2 => .rec_scope,
        else => .lambda_scope,
    };
}

fn bindOneFreeName(
    allocator: std.mem.Allocator,
    template: Template,
    value: Fragment,
    body: Fragment,
    name: []const u8,
) !Fragment {
    const text = switch (template) {
        .let_scope => try std.mem.concat(allocator, u8, &.{ "let ", name, " = ", value.text, "; in ", body.text }),
        .with_scope => try std.mem.concat(allocator, u8, &.{ "with { ", name, " = ", value.text, "; }; ", body.text }),
        .rec_scope => try std.mem.concat(allocator, u8, &.{ "(rec { ", name, " = ", value.text, "; result = ", body.text, "; }).result" }),
        .lambda_scope => try std.mem.concat(allocator, u8, &.{ "(", name, ": ", body.text, ") (", value.text, ")" }),
        .direct_add => unreachable,
    };
    errdefer allocator.free(text);

    const remaining_body_names = try subtractName(allocator, body.free_names, name);
    defer freeNames(allocator, remaining_body_names);
    return .{
        .text = text,
        .free_names = try unionNames(allocator, value.free_names, remaining_body_names),
    };
}

fn cloneFragment(allocator: std.mem.Allocator, fragment: Fragment) !Fragment {
    return .{
        .text = try allocator.dupe(u8, fragment.text),
        .free_names = try dupeNames(allocator, fragment.free_names),
    };
}

fn dupeNames(allocator: std.mem.Allocator, names: []const []const u8) ![]const []const u8 {
    if (names.len == 0) return &.{};
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (out.items) |name| allocator.free(name);
        out.deinit(allocator);
    }
    for (names) |name| try appendUniqueName(allocator, &out, name);
    return out.toOwnedSlice(allocator);
}

fn unionNames(allocator: std.mem.Allocator, left: []const []const u8, right: []const []const u8) ![]const []const u8 {
    if (left.len == 0 and right.len == 0) return &.{};
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (out.items) |name| allocator.free(name);
        out.deinit(allocator);
    }
    for (left) |name| try appendUniqueName(allocator, &out, name);
    for (right) |name| try appendUniqueName(allocator, &out, name);
    return out.toOwnedSlice(allocator);
}

fn subtractName(allocator: std.mem.Allocator, names: []const []const u8, bound: []const u8) ![]const []const u8 {
    if (names.len == 0) return &.{};
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (out.items) |name| allocator.free(name);
        out.deinit(allocator);
    }
    for (names) |name| {
        if (!std.mem.eql(u8, name, bound)) try appendUniqueName(allocator, &out, name);
    }
    if (out.items.len == 0) return &.{};
    return out.toOwnedSlice(allocator);
}

fn appendUniqueName(
    allocator: std.mem.Allocator,
    names: *std.ArrayListUnmanaged([]const u8),
    name: []const u8,
) !void {
    for (names.items) |existing| {
        if (std.mem.eql(u8, existing, name)) return;
    }
    try names.append(allocator, try allocator.dupe(u8, name));
}

fn freeNames(allocator: std.mem.Allocator, names: []const []const u8) void {
    for (names) |name| allocator.free(name);
    if (names.len != 0) allocator.free(names);
}

fn binary(allocator: std.mem.Allocator, left: []const u8, op: []const u8, right: []const u8) ![]u8 {
    return std.mem.concat(allocator, u8, &.{ "(", left, ") ", op, " (", right, ")" });
}
