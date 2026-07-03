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

    // Synthetic parent: snapshot names as locals 0..k-1, in order.
    var parent_builder = try ChunkBuilder.init(sa);
    defer parent_builder.deinit(sa);
    var parent = Compiler.init(sa, allocator, &parent_builder, registry, entry.source, intern, heap);
    parent.base_path = entry.base_path;
    parent.source_path = entry.source_path;
    parent.source_file_id = entry.source_file_id;
    // Shared line index — avoid rebuilding it over the whole source per body.
    parent.external_line_index = line_index;
    defer parent.deinit();
    for (entry.scope) |cap| {
        _ = try scope.declareLocal(&parent, cap.name, cap.name_id);
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
    // errors (OOM) realistically reach this. There is no parent compiler
    // to absorb diagnostics into, so just propagate.
    try child.compileNode(entry.node);
    return thunks.finishCompiledChild(&child, &child_builder, entry.node);
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
        // real scope-snapshot capture) and pads past MIN_BODY_BYTES.
        const line = try std.fmt.allocPrint(
            std.testing.allocator,
            "  attr{d} = shared + {d} /* padding padding padding padding padding padding padding */;\n",
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
