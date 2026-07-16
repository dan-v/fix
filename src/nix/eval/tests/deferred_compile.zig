const std = @import("std");
const fix = @import("../../root.zig");
const Evaluator = fix.Evaluator;

test "an imported file large enough to defer per-attr compilation evaluates the forced attr correctly" {
    // Lazy per-attr compilation (attrs.zig `shouldDeferSet`) only
    // triggers for file/import compiles (source_path != null) with at
    // least min_entries (64) entries whose bodies are at least
    // min_body_bytes (100) bytes. This builds such a set, forces exactly
    // one entry, and checks it round-trips through the deferred
    // force-time compile in `deferred.compile`.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var contents: std.ArrayListUnmanaged(u8) = .empty;
    defer contents.deinit(std.testing.allocator);
    try contents.appendSlice(std.testing.allocator, "let shared = 3; in {\n");
    var i: usize = 0;
    while (i < 80) : (i += 1) {
        // Each body references the enclosing `shared` binding (forcing a
        // real scope-snapshot capture) and pads past min_body_bytes. The
        // padding must be inside the expression itself (`+ 0` chain):
        // comments and parens are not part of the body node's span.
        const line = try std.fmt.allocPrint(
            std.testing.allocator,
            "  attr{d} = shared + {d} + 0 + 0 + 0 + 0 + 0 + 0 + 0 + 0 + 0 + 0 + 0 + 0 + 0 + 0 + 0 + 0 + 0 + 0 + 0 + 0 + 0 + 0 + 0 + 0 + 0;\n",
            .{ i, i },
        );
        defer std.testing.allocator.free(line);
        try contents.appendSlice(std.testing.allocator, line);
    }
    try contents.appendSlice(std.testing.allocator, "}\n");

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "big.nix", .data = contents.items });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const file_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd, ".zig-cache", "tmp", &tmp.sub_path, "big.nix",
    });
    defer std.testing.allocator.free(file_path);

    const source = try std.fmt.allocPrint(std.testing.allocator, "(import {s}).attr42", .{file_path});
    defer std.testing.allocator.free(source);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    const result = try ev.evaluate(source);
    try std.testing.expectEqual(@as(i64, 45), result.asInt());
}

test "deferred bodies under enclosing with scopes resolve names like the eager compile" {
    // Deferral under `with` (perl-packages.nix / python-packages.nix
    // shape): the with-subject values are snapshotted into the deferred
    // thunk's env and re-established as with-scopes at force-time compile.
    // Exercises the three resolution rules: (1) with-bound names resolve,
    // (2) lexical bindings shadow any with, (3) inner withs shadow outer.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var contents: std.ArrayListUnmanaged(u8) = .empty;
    defer contents.deinit(std.testing.allocator);
    // `shared` is BOTH let-bound (3) and bound by both withs (30, 300):
    // lexical must win. `bonus` comes only from the withs: the INNER
    // with's value (20) must shadow the outer's (2000).
    try contents.appendSlice(std.testing.allocator,
        \\let shared = 3; in
        \\with { shared = 300; bonus = 2000; unused = 9; };
        \\with { shared = 30; bonus = 20; };
        \\{
        \\
    );
    var i: usize = 0;
    while (i < 80) : (i += 1) {
        // Padding inside the expression (`+ 0` chain): comments/parens are
        // not part of the body node's span, so they don't count toward
        // min_body_bytes.
        const line = try std.fmt.allocPrint(
            std.testing.allocator,
            "  attr{d} = shared + bonus + {d} + 0 + 0 + 0 + 0 + 0 + 0 + 0 + 0 + 0 + 0 + 0 + 0 + 0 + 0 + 0 + 0 + 0 + 0 + 0 + 0 + 0 + 0 + 0 + 0 + 0;\n",
            .{ i, i },
        );
        defer std.testing.allocator.free(line);
        try contents.appendSlice(std.testing.allocator, line);
    }
    try contents.appendSlice(std.testing.allocator, "}\n");

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bigwith.nix", .data = contents.items });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const file_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd, ".zig-cache", "tmp", &tmp.sub_path, "bigwith.nix",
    });
    defer std.testing.allocator.free(file_path);

    // 3 (lexical shared) + 20 (inner-with bonus) + 42 = 65.
    const source = try std.fmt.allocPrint(std.testing.allocator, "(import {s}).attr42", .{file_path});
    defer std.testing.allocator.free(source);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    const result = try ev.evaluate(source);
    try std.testing.expectEqual(@as(i64, 65), result.asInt());
}

// ---- body-span elision e2e ----------------------------------------------

/// Write `contents` into a tmp dir and return an absolute path to it
/// (owned by `allocator`). Shared by the elision tests below.
fn writeTmpNix(tmp: *std.testing.TmpDir, allocator: std.mem.Allocator, name: []const u8, contents: []const u8) ![]u8 {
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = contents });
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &.{
        cwd, ".zig-cache", "tmp", &tmp.sub_path, name,
    });
}

/// 64 filler entries to clear the parser's elision clause gate, so the
/// entries appended after this prefix parse as `.elided` spans.
fn appendElisionPrefix(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) !void {
    try list.appendSlice(allocator, "{\n");
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        try list.print(allocator, "  pre{d} = 0;\n", .{i});
    }
}

const elision_pad = "+ 0 + 0 + 0 + 0 + 0 + 0 + 0 + 0 + 0 + 0 + 0 + 0 + 0 + 0 + 0 + 0 + 0 + 0 + 0 + 0 + 0 + 0 + 0 + 0 + 0";

test "an elided attr body is deferred and compiles correctly at first force" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var contents: std.ArrayListUnmanaged(u8) = .empty;
    defer contents.deinit(std.testing.allocator);
    try contents.appendSlice(std.testing.allocator, "let shared = 3; in ");
    try appendElisionPrefix(&contents, std.testing.allocator);
    try contents.print(std.testing.allocator, "  target = shared + 39 {s};\n}}\n", .{elision_pad});

    const file_path = try writeTmpNix(&tmp, std.testing.allocator, "elided.nix", contents.items);
    defer std.testing.allocator.free(file_path);
    const source = try std.fmt.allocPrint(std.testing.allocator, "(import {s}).target", .{file_path});
    defer std.testing.allocator.free(source);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    const result = try ev.evaluate(source);
    try std.testing.expectEqual(@as(i64, 42), result.asInt());
}

test "a syntax error inside an elided body surfaces at force time, not parse time" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var contents: std.ArrayListUnmanaged(u8) = .empty;
    defer contents.deinit(std.testing.allocator);
    try appendElisionPrefix(&contents, std.testing.allocator);
    // Token-balanced but malformed (`if` with no `else`): an eager parse
    // rejects the file; the elided parse defers the error to first force —
    // the same deal deferred compilation already makes for compile errors.
    try contents.print(std.testing.allocator, "  bad = if true then 1 {s};\n  good = 7 {s};\n}}\n", .{ elision_pad, elision_pad });

    const file_path = try writeTmpNix(&tmp, std.testing.allocator, "badbody.nix", contents.items);
    defer std.testing.allocator.free(file_path);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    // Forcing a healthy attr proves the file parsed (i.e. `bad` was elided).
    const good_src = try std.fmt.allocPrint(std.testing.allocator, "(import {s}).good", .{file_path});
    defer std.testing.allocator.free(good_src);
    const good = try ev.evaluate(good_src);
    try std.testing.expectEqual(@as(i64, 7), good.asInt());

    // Forcing the malformed one reports the (deferred) parse error.
    const bad_src = try std.fmt.allocPrint(std.testing.allocator, "(import {s}).bad", .{file_path});
    defer std.testing.allocator.free(bad_src);
    try std.testing.expectError(error.ParseError, ev.evaluate(bad_src));
}

test "an elided leaf in an extended group materializes for the duplicate check" {
    // `dup = <elided>; dup.extra = 2;` — whether this merges or errors
    // depends on the leaf's true shape, so the compiler must materialize
    // the elided body before deciding. Here the body is an application,
    // so it must be a duplicate-attribute error (at compile/import time).
    var contents: std.ArrayListUnmanaged(u8) = .empty;
    defer contents.deinit(std.testing.allocator);
    try contents.appendSlice(std.testing.allocator, "let f = x: { }; in ");
    try appendElisionPrefix(&contents, std.testing.allocator);
    try contents.print(std.testing.allocator, "  dup = f 1 {s};\n  dup.extra = 2;\n}}\n", .{elision_pad});

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    try std.testing.expectError(
        error.DuplicateAttribute,
        ev.compileSource(contents.items, "/elision-dup-test.nix"),
    );
}

test "elided bodies fall back to eager materialization when the set cannot defer" {
    // 33 enclosing let bindings exceed max_scope_size (32), so the snapshot
    // bails and the set compiles eagerly — elided bodies must be sub-parsed
    // at compile time and produce the same values.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var contents: std.ArrayListUnmanaged(u8) = .empty;
    defer contents.deinit(std.testing.allocator);
    try contents.appendSlice(std.testing.allocator, "let\n");
    var i: usize = 0;
    while (i < 33) : (i += 1) {
        try contents.print(std.testing.allocator, "v{d} = {d};\n", .{ i, i });
    }
    try contents.appendSlice(std.testing.allocator, "in ");
    try appendElisionPrefix(&contents, std.testing.allocator);
    try contents.print(std.testing.allocator, "  target = v32 + 10 {s};\n}}\n", .{elision_pad});

    const file_path = try writeTmpNix(&tmp, std.testing.allocator, "eagerback.nix", contents.items);
    defer std.testing.allocator.free(file_path);
    const source = try std.fmt.allocPrint(std.testing.allocator, "(import {s}).target", .{file_path});
    defer std.testing.allocator.free(source);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    const result = try ev.evaluate(source);
    try std.testing.expectEqual(@as(i64, 42), result.asInt());
}

test "an elided body under a dynamic attribute name compiles via the thunk path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var contents: std.ArrayListUnmanaged(u8) = .empty;
    defer contents.deinit(std.testing.allocator);
    try contents.appendSlice(std.testing.allocator, "let suffix = \"X\"; base = 40; in ");
    try appendElisionPrefix(&contents, std.testing.allocator);
    try contents.print(std.testing.allocator, "  \"dyn${{suffix}}\" = base + 2 {s};\n}}\n", .{elision_pad});

    const file_path = try writeTmpNix(&tmp, std.testing.allocator, "dynelide.nix", contents.items);
    defer std.testing.allocator.free(file_path);
    const source = try std.fmt.allocPrint(std.testing.allocator, "(import {s}).dynX", .{file_path});
    defer std.testing.allocator.free(source);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    const result = try ev.evaluate(source);
    try std.testing.expectEqual(@as(i64, 42), result.asInt());
}
