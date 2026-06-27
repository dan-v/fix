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
    // Synthetic parent: snapshot names as locals 0..k-1, in order.
    var parent_builder = try ChunkBuilder.init(allocator);
    defer parent_builder.deinit(allocator);
    var parent = Compiler.init(allocator, &parent_builder, registry, entry.source, intern, heap);
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
    var child_builder = try ChunkBuilder.init(allocator);
    defer child_builder.deinit(allocator);
    var child = Compiler.init(allocator, &child_builder, registry, entry.source, intern, heap);
    child.parent = &parent;
    child.base_path = entry.base_path;
    child.source_path = entry.source_path;
    child.source_file_id = entry.source_file_id;
    defer child.deinit();
    for (entry.scope, 0..) |cap, i| {
        try child.captures.append(allocator, .{
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
