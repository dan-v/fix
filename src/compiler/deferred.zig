//! Force-time compilation of a deferred attrset value body (lazy
//! per-attr compilation). See `deferred_table.zig` for the table and the
//! overall design.
//!
//! The body was NOT compiled when its attrset was built; instead the
//! enclosing lexical scope was snapshotted (`Entry.scope`) and a
//! `.deferred` thunk emitted. On first force we compile the body here,
//! against a *synthetic* single-level parent whose locals are exactly the
//! snapshot names in declaration order. The child's captures are
//! pre-seeded with those same names (also in order) so that
//! `resolveCaptureId`'s dedup (`scope.zig`) maps every free var to a
//! fixed upvalue index == its position in the thunk's `env` — no
//! force-time remap, and the produced chunk is equivalent to what the
//! eager compile produced (modulo internal upvalue numbering, never
//! observable in output).

const std = @import("std");
const compiler_mod = @import("../compiler.zig");
const ast = @import("syntax").ast;
const literals = @import("literals.zig");
const Compiler = compiler_mod.Compiler;
const bytecode = @import("../bytecode.zig");
const ChunkBuilder = bytecode.chunk.ChunkBuilder;
const ChunkRegistry = bytecode.chunk.ChunkRegistry;
const ChunkId = @import("runtime").types.ChunkId;
const InternTable = @import("runtime").intern.InternTable;
const ObjectHeap = @import("runtime").heap.ObjectHeap;
const scope = @import("scope.zig");
const thunks = @import("thunks.zig");
const deferred = @import("deferred_table.zig");
const LineIndex = @import("syntax").diagnostic.LineIndex;

/// Compile one deferred body and return its registered ChunkId. Uses the
/// long-lived `allocator` (evaluator lifetime) so the registered chunk's
/// bytecode outlives this call; transient compile structures are freed
/// before returning. Safe to call concurrently from multiple workers
/// (each builds its own chunk; `register` is internally serialized).
pub fn compile(
    allocator: std.mem.Allocator,
    registry: *ChunkRegistry,
    intern: *InternTable,
    heap: *ObjectHeap,
    entry: *const deferred.Entry,
    line_index: *LineIndex,
) !ChunkId {
    // Per-body scratch arena: transient compile structures live here and are
    // freed wholesale on return; only the registered chunk's bytecode is
    // duped onto the long-lived `allocator` (at `finishCompiledChild`).
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const sa = scratch.allocator();

    // Synthetic parent: snapshot names as locals 0..k-1, in order. The
    // trailing `with_count` entries are with-subject values, not lexical
    // bindings — declared as anonymous locals at the SAME slot positions
    // (slot i == env index i) and re-established as with-scopes.
    var parent_builder = try ChunkBuilder.init(sa);
    defer parent_builder.deinit(sa);
    var parent = Compiler.init(sa, allocator, &parent_builder, registry, entry.source, intern, heap);
    parent.base_path = entry.base_path;
    parent.source_path = entry.source_path;
    parent.source_file_id = entry.source_file_id;
    // Shared line index — avoid rebuilding it over the whole source per body.
    // Take a by-value copy: `line_starts` is immutable and safely shared, but
    // `positionForOffset` mutates the embedded last-lookup cache, and
    // concurrent force-time compiles of bodies from the same file race on it
    // (a torn cache read makes `target - cache_line_start` underflow).
    var local_line_index = line_index.*;
    parent.external_line_index = &local_line_index;
    defer parent.deinit();
    // Body-span elision: the registered body (or a node nested inside it)
    // may be an `.elided` span that was never parsed. Sub-parses land in
    // this per-compile throwaway arena — deferred compiles run concurrently
    // over the shared retained AST, so `elide_mutable` stays false and the
    // shared nodes are never written (racers each materialize their own
    // copy; the chunk cache converges on one winner as usual). Nothing
    // outlives the compile except the registered chunk.
    var body_arena = ast.AstArena.init(sa);
    defer body_arena.deinit();
    parent.ast_arena = &body_arena;
    for (entry.scope) |cap| {
        _ = try scope.declareLocal(&parent, cap.name, cap.name_id);
    }
    // Re-establish the set site's with nesting. `entry.scope` stores the
    // withs innermost-first at env indices k..k+w-1; `with_scopes` is a
    // stack (outermost appended first), so push them in reverse. The
    // body's with-lookups then collect them innermost-first — the same
    // order the eager compile saw — and each capture dedups against the
    // pre-seeded child capture at its env index.
    const lexical_len = entry.scope.len - entry.with_count;
    var wi: usize = entry.scope.len;
    while (wi > lexical_len) {
        wi -= 1;
        try parent.with_scopes.append(sa, .{ .kind = .local, .index = @intCast(wi) });
    }

    // Child compiles the body against that parent. Pre-seed captures with
    // the snapshot names (in order) → upvalue index i == env index i.
    var child_builder = try ChunkBuilder.init(sa);
    defer child_builder.deinit(sa);
    var child = Compiler.init(sa, allocator, &child_builder, registry, entry.source, intern, heap);
    child.parent = &parent;
    child.base_path = entry.base_path;
    child.source_path = entry.source_path;
    child.source_file_id = entry.source_file_id;
    defer child.deinit();
    for (entry.scope, 0..) |cap, i| {
        try child.captures.append(child.allocator, .{
            .name = cap.name,
            .name_id = cap.name_id,
            .kind = .local,
            .index = @intCast(i),
        });
    }

    // A body that compiled fine eagerly compiles fine here; only resource
    // errors (OOM) realistically reach this — except an ELIDED body, whose
    // parse was skipped entirely: a syntax error inside it surfaces here,
    // at first force, the same deal deferred compilation already makes for
    // compile errors. There is no parent compiler to absorb diagnostics
    // into, so just propagate.
    const body = if (entry.node.tag == .elided)
        try literals.materializeElided(&child, entry.node)
    else
        entry.node;
    try child.compileNode(body);
    return thunks.finishCompiledChild(&child, &child_builder, body);
}

const fix = @import("../root.zig");
const Evaluator = fix.Evaluator;

test "an imported file large enough to defer per-attr compilation evaluates the forced attr correctly" {
    // Lazy per-attr compilation (attrs.zig `shouldDeferSet`) only
    // triggers for file/import compiles (source_path != null) with at
    // least MIN_ENTRIES (64) entries whose bodies are at least
    // MIN_BODY_BYTES (100) bytes. This builds such a set, forces exactly
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
        // real scope-snapshot capture) and pads past MIN_BODY_BYTES. The
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
        // MIN_BODY_BYTES.
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
    // the same deal deferred compilation makes for compile errors.
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
    // 33 enclosing let bindings exceed MAX_SCOPE (32), so the snapshot
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
