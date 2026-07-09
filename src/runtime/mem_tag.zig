//! RSS attribution taxonomy for the evaluator.
//!
//! The generic region-tracker mechanism lives in `vma.zig`; this file owns
//! the fix-specific tag enum and its smaps labels, and instantiates the
//! single process-wide registry (`vma`) that every subsystem shares. Because
//! `Vma(MemTag, …)` is a memoized type, `mem_tag.vma` is one singleton no
//! matter how many modules name it.

/// Attribution category. One bucket per subsystem that owns big mappings.
pub const MemTag = enum(u8) {
    /// Object store flat reservation (heap.zig FlatStore).
    objects,
    /// Value store segments.
    values,
    /// Attr store segments.
    attrs,
    /// Attr-position store segments.
    attrpos,
    /// Fiber stacks (8 MiB lazily-committed reservations).
    fiber_stack,
    /// AST arenas (parse-time nodes; the retained ones back deferred
    /// compiles for the evaluator's lifetime).
    ast_arena,
    /// Worker arenas: per-fiber VM value stacks + frames.
    worker_arena,
    /// File cache: retained source texts.
    file_cache,
    /// Everything else big through the allocator (block_cache.zig):
    /// compile scratch, builtin temp buffers, intern data, parked
    /// free-stack blocks.
    bigblock,
};

pub fn tagName(t: MemTag) [:0]const u8 {
    return switch (t) {
        .objects => "fix:objects",
        .values => "fix:values",
        .attrs => "fix:attrs",
        .attrpos => "fix:attrpos",
        .fiber_stack => "fix:fiber-stack",
        .ast_arena => "fix:ast-arena",
        .worker_arena => "fix:worker-arena",
        .file_cache => "fix:file-cache",
        .bigblock => "fix:bigblock",
    };
}

/// The single shared region registry. `Vma(MemTag, …)` memoizes on its
/// arguments, so this is one process-wide instance everywhere it is named.
pub const vma = @import("vma.zig").Vma(MemTag, .bigblock, tagName);
