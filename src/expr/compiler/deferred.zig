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
const compiler_mod = @import("context.zig");
const compiler_driver = @import("driver.zig");
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
    registration_sink: ?compiler_mod.ChunkRegistrationSink,
    entry: *const deferred.Entry,
    line_index: *LineIndex,
) !ChunkId {
    // Per-body scratch arena: transient compile structures live here and are
    // freed wholesale on return; only the registered chunk's bytecode is
    // duped onto the long-lived `allocator` (at `finishCompiledChild`).
    var scratch = @import("base").arena.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const sa = scratch.allocator();

    // Synthetic parent: snapshot names as locals 0..k-1, in order. The
    // trailing `with_count` entries are with-subject values, not lexical
    // bindings — declared as anonymous locals at the SAME slot positions
    // (slot i == env index i) and re-established as with-scopes.
    var parent_builder = try ChunkBuilder.init(sa);
    defer parent_builder.deinit(sa);
    var parent = Compiler.init(&compiler_driver.driver, sa, allocator, &parent_builder, registry, entry.source, intern, heap);
    parent.registration_sink = registration_sink;
    parent.base_path = entry.base_path;
    parent.source_path = entry.source_path;
    parent.source_file_id = entry.source_file_id;
    parent.policy = entry.policy;
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
    var child = Compiler.init(&compiler_driver.driver, sa, allocator, &child_builder, registry, entry.source, intern, heap);
    child.registration_sink = registration_sink;
    child.parent = &parent;
    child.base_path = entry.base_path;
    child.source_path = entry.source_path;
    child.source_file_id = entry.source_file_id;
    child.policy = entry.policy;
    child.name_id = entry.name_id; // qualified name (traces/errors/disasm)
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
