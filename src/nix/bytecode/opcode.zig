//! Bytecode opcodes for the tail-calling VM.
//!
//! The interpreter is a direct-threaded bytecode loop. Each instruction
//! is a u8 opcode followed by 0–N operand bytes.
//! Multi-byte operands use little-endian encoding.

pub const OpCode = enum(u8) {
    // ---- stack ----
    /// Push a constant from the chunk constant pool (operand: 2-byte ConstIdx).
    push_const,
    /// Push null.
    push_null,
    /// Push true.
    push_true,
    /// Push false.
    push_false,

    /// Discard top of stack.
    pop,
    // ---- locals ----
    /// Push local variable at offset (operand: 1-byte offset from frame base).
    loc_get,
    /// Push local variable at offset (operand: 2-byte offset from frame base).
    loc_get_w,
    /// Push local variable without forcing lazy cells (operand: 1-byte offset).
    loc_grab,
    /// Push local variable without forcing lazy cells (operand: 2-byte offset).
    loc_grab_w,
    /// Push captured upvalue without forcing lazy cells (operand: 2-byte index).
    up_grab,
    /// Set local variable at offset, popping from stack.
    loc_set,
    /// Set local variable at offset, popping from stack (operand: 2-byte offset).
    loc_set_w,
    /// Set the value inside a local cell, popping from stack.
    cell_set,
    /// Set the value inside a local cell (operand: 2-byte offset).
    cell_set_w,
    /// Push captured upvalue at offset (operand: 2-byte closure upvalue index).
    up_get,

    // ---- arithmetic ----
    int_add,
    int_sub,
    int_mul,
    int_div,
    int_neg,
    flt_add,
    flt_sub,
    flt_mul,
    flt_div,

    // ---- comparison ----
    cmp_eq,
    cmp_ne,
    cmp_lt,
    cmp_le,
    cmp_gt,
    cmp_ge,
    /// Specialized `eq null` — pop one value, push `true` if it
    /// forces to null. Emitted by `compileBinary` when one side of
    /// `==` is a literal `null`. Skips the generic `valuesEqual`
    /// dispatch and gives the JIT a type-monomorphic null-check.
    cmp_eq_null,
    /// Specialized `neq null` — symmetric with `cmp_eq_null`.
    cmp_ne_null,

    // ---- logical ----
    bool_not,

    // ---- control flow ----
    /// Relative jump forward (operand: 4-byte unsigned offset).
    jump,
    /// Jump forward if top of stack is false (operand: 4-byte unsigned offset).
    jump_false,
    /// Raise an assertion failure.
    fail,

    // ---- data ----
    /// Build an attribute set from pairs on the stack.
    /// Operand: 2-byte count of entries.
    /// Stack layout from lower to higher indexes: [name1, val1, ..., nameN, valN].
    attrs_new,
    /// Build an attribute set from pairs on the stack and attach source positions.
    /// Operand: 2-byte count, 2-byte source-position count, then repeated
    /// 4-byte name InternId, 4-byte file InternId, 4-byte line, 4-byte column.
    attrs_new_pos,
    /// `attrs_new`, but the compiler guarantees the pairs are already on
    /// the stack in ascending interned-name order with no duplicates —
    /// static attrset literals are grouped (duplicates rejected at compile
    /// time) and emitted name-sorted, so the runtime skips the
    /// per-construction sort + duplicate scan. Operand: 2-byte count.
    attrs_new_srt,
    /// `attrs_new_pos` with the same compile-time sorted+unique
    /// guarantee as `attrs_new_srt`. Operands as `attrs_new_pos`.
    attrs_new_pos_srt,
    /// `attrs_new_srt` with the attr NAMES in the chunk's side table instead
    /// of pushed as string constants: the stack carries only the N values,
    /// and names come from `Chunk.attr_names[names_start..names_start+N]`
    /// (compile-time interned, sorted, unique). Saves a `push_const` op +
    /// dispatch + constant-pool slot per entry — attr-name pushes were ~55%
    /// of all push_const executions on a NixOS eval.
    /// Operand: count:u16 + names_start:u32.
    attrs_new_named_srt,
    /// `attrs_new_named_srt` carrying source positions too.
    /// Operand: count:u16 + names_start:u32 + pos_count:u16 + pos_start:u32.
    attrs_new_named_pos_srt,
    /// Build a list from items on the stack.
    /// Operand: 2-byte count of items.
    list_new,
    /// Merge two attrsets as parts of one attrset literal, recursively rejecting
    /// duplicate leaf attributes.
    attrs_merge_strict,
    /// Merge two attrsets, with right-hand keys overriding left-hand keys.
    attrs_merge,
    /// Concatenate two lists.
    list_cat,
    /// Concatenate N string-like values in a single pass. Stack before:
    /// [part1, ..., partN] (part1 lowest); after: [result]. Each part is
    /// coerced exactly like the binary `+` string path (string / path /
    /// attrs-with-__toString), contexts are merged in part order, and the
    /// text is assembled into one exact-size buffer and interned ONCE.
    /// Emitted for `${...}` interpolation literals: the equivalent
    /// `int_add` fold interns (hashes + copies + permanently retains)
    /// every intermediate prefix of a k-part string. With N == 1 the op
    /// is a bare string coercion — no re-intern of the coerced text.
    /// Operand: 2-byte count (N >= 1).
    str_cat,
    /// Push the evaluator-owned builtins attrset.
    push_builtins,
    /// Resolve an evaluator search-path literal.
    /// Operand: 2-byte InternId of the search path text without angle brackets.
    file_find,
    /// Resolve an evaluator search-path literal with a wide intern id.
    /// Operand: 4-byte InternId.
    file_find_w,

    // ---- closures and thunks ----
    /// Create a closure value from a chunk and captured upvalues.
    /// Operand: 2-byte ChunkId, 2-byte upvalue count.
    /// Upvalues are the top N values on the stack, popped.
    closure,
    /// Create a closure whose chunk id does not fit in the short form.
    /// Operand: 4-byte ChunkId, 2-byte upvalue count.
    closure_w,
    /// Create a closure and fill upvalues from inline capture descriptors.
    /// Operand: 2-byte ChunkId, 2-byte count, then repeated
    /// 1-byte kind (0=local, 1=upvalue), 2-byte index.
    closure_cap,
    /// Wide-chunk-id form of closure_cap.
    /// Operand: 4-byte ChunkId, 2-byte count, then repeated descriptors.
    closure_cap_w,
    /// Function-argument with a runtime-adaptive laziness decision. The
    /// callee is already on the stack (just below where the argument
    /// goes). If it is a closure whose chunk's body must-forces its
    /// parameter (`scheduling.strict_param`), the argument expression is
    /// evaluated eagerly to a value — no thunk; otherwise it is
    /// materialised as a thunk exactly like `thunk`. Lets us
    /// skip the thunk for dynamically-dispatched strict calls, which the
    /// compiler can't resolve statically.
    /// Operand: 4-byte ChunkId, 2-byte count, then repeated descriptors.
    thunk_arg,
    /// Create a thunk directly from a chunk and inline capture descriptors.
    /// Operand: 2-byte ChunkId, 2-byte count, then repeated descriptors.
    thunk,
    /// Wide-chunk-id form of thunk.
    /// Operand: 4-byte ChunkId, 2-byte count, then repeated descriptors.
    thunk_w,
    /// Same as `thunk` but submits the thunk to the urgent
    /// scheduler queue at creation time. Emitted by the compiler when
    /// strictness analysis says the surrounding chunk's body will
    /// unconditionally force this binding — turns the chunk-size
    /// speculation heuristic into a deterministic decision and
    /// bypasses the speculation backlog cap.
    thunk_eag,
    /// Wide-chunk-id form of thunk_eag.
    thunk_eag_w,

    /// Fused `thunk + cell_set`. Creates the thunk
    /// from the chunk-id + descriptors, then `publishCellBinding`s it
    /// into the cell-thunk at frame_base + slot (skipping the
    /// push/pop of the new thunk reference). Operand layout:
    ///   chunk_id:2 + K:2 + 3K descriptors + slot:1
    /// The slot byte is at the END so we can rewrite `thunk`
    /// in place at emit time without shifting the descriptor bytes.
    thunk_st_cell,
    /// Fused `thunk + loc_set`.
    thunk_st,
    /// Fused `thunk_eag + cell_set`.
    thunk_eag_st_cell,
    /// Fused `thunk_eag + loc_set`.
    thunk_eag_st,
    /// Wide-chunk-id forms of the fused thunk+store family. Past 65,536
    /// registered chunks (any real NixOS eval) every later chunk reference
    /// uses the wide encoding, so these carry the fusion win to the dominant
    /// form. Operand: chunk_id:4 + K:2 + 3K descriptors + slot:1.
    thunk_w_st_cell,
    /// Fused `thunk_w + loc_set`.
    thunk_w_st,
    /// Fused `thunk_eag_w + cell_set`.
    thunk_eag_w_st_cell,
    /// Fused `thunk_eag_w + loc_set`.
    thunk_eag_w_st,
    /// Create a frameless attr-access thunk directly: resolve ONE capture
    /// descriptor (kind:1 + index:2) to a base value and wrap it in an
    /// attr-access thunk over the 2-byte attr name. The compile-time twin of
    /// the `attr_access` trivial-body short-circuit — emitted instead of a
    /// whole `up_get_attr; ret; halt` wrapper chunk (the single most common
    /// chunk shape on a NixOS eval), which the runtime never dispatched
    /// anyway. Operand: kind:1 + index:2 + name:2.
    thunk_attr,

    // ---- calls ----
    /// Call the top-of-stack closure with the value below it as argument.
    /// The stack layout before: [closure, arg].
    /// After: [result].
    call,
    /// Call in tail position. Closure callees reuse the current frame; other
    /// callees behave like `call` and are followed by the normal `ret`.
    call_tail,
    /// Apply a callee to N arguments in one op. Stack before:
    /// [callee, arg1, ..., argN]; after: [result]. Operand: 1-byte N
    /// (N >= 1). Semantically identical to N sequential `call`s, but when
    /// the callee is an uncurried closure whose arity == N the body runs
    /// in a single frame with zero intermediate closure/PAP allocation —
    /// the uncurrying win. Under/over-application and non-closure callees
    /// fall back to one-arg-at-a-time application. See `vm/closures.zig`.
    call_n,
    /// `call_n` in tail position.
    call_tail_n,

    // ---- fused value+ret super-ops ----
    /// Fused `push_const + ret`: load constant N onto the stack and
    /// return from the current frame in one dispatch. Operand:
    /// 2-byte constant index. Emitted by `compileTailExpression`
    /// when the tail expression is a literal — saves one of the two
    /// dispatches that dominate the bytecode loop's per-thunk
    /// overhead.
    push_const_ret,
    /// Fused `loc_get + ret` (narrow slot).
    loc_get_ret,
    /// Fused `loc_get + ret` (wide slot — 2-byte operand).
    loc_get_ret_w,
    /// Fused `up_get + ret` (always 2-byte upvalue index).
    up_get_ret,

    // ---- fused compound super-ops ----
    /// Fused `up_get + attr_get` — read upvalue, force, look up
    /// attribute. Operand: 2-byte upvalue index + 2-byte name InternId.
    /// Saves the push/pop of the attrs value plus one dispatch. The
    /// `lib.foo` and `config.bar` patterns are everywhere in NixOS
    /// modules; profiling shows `up_get` is 10% of all ops and
    /// `attr_get` is 3%, much of it the same upvalue→attr chain.
    up_get_attr,
    /// Fused `loc_get + attr_get` (narrow slot — 1-byte). Operand:
    /// 1-byte slot + 2-byte name InternId.
    loc_get_attr,
    /// Fused `loc_get_w + attr_get` (wide slot — 2-byte). Operand:
    /// 2-byte slot + 2-byte name InternId.
    loc_get_attr_w,

    // ---- thunks ----
    /// Wrap the top-of-stack value in a mutable lazy cell.
    cell_new,
    /// Wrap the top-of-stack value in a pre-resolved, undemanded
    /// thunk. Used by the compiler when an eagerly-buildable shape
    /// (list / attrset / lambda) appears in a context that requires
    /// the value to *look* like a lazy thunk to renderers (XML lazy
    /// mode in particular) — we skip emitting a child chunk +
    /// `thunk` and just wrap the already-built shell. The
    /// resulting thunk's `force` is O(1) (resolved fast path); the
    /// XML serializer keeps printing `<unevaluated />` until a real
    /// caller marks it demanded.
    thunk_shell,
    /// Allocate an empty (null-wrapped) lazy cell and store it
    /// directly into a local slot. Operand: 1-byte slot index. Fuses
    /// the `push_null + cell_new + loc_set` sequence that the
    /// compiler emits once per let-binding / recursive-attrset
    /// binding / lambda parameter — saving two dispatches and the
    /// intermediate stack push/pop per call.
    cell_init,
    /// Wide-slot variant of `cell_init`. Operand: 2-byte slot index.
    cell_init_w,

    // ---- attribute access ----
    /// Select an attribute from attrset on stack top.
    /// Operand: 2-byte InternId of the attribute name.
    attr_get,
    /// Select an attribute from attrset on stack top with a wide intern id.
    /// Operand: 4-byte InternId.
    attr_get_w,
    /// Select an attribute by a runtime string name.
    /// Stack layout before: [attrs, name].
    attr_get_dyn,
    /// Select a runtime string attribute with a lazy default.
    /// Stack layout before: [attrs, name, default_thunk].
    attr_get_dyn_or,
    /// Select a static attribute path prefix followed by a runtime string
    /// attribute with a lazy default if any segment is missing.
    /// Operand: 1-byte segment count, then that many 2-byte InternIds.
    /// Stack layout before: [attrs, name, default_thunk].
    attr_get_path_dyn_or,
    /// Wide-intern-id form of attr_get_path_dyn_or.
    /// Operand: 1-byte segment count, then that many 4-byte InternIds.
    attr_get_path_dyn_or_w,
    /// Select an attribute path with a lazy default if any segment is missing.
    /// Operand: 1-byte segment count, then that many 2-byte InternIds.
    /// Stack layout before: [attrs, default_thunk].
    attr_get_path_or,
    /// Wide-intern-id form of attr_get_path_or.
    /// Operand: 1-byte segment count, then that many 4-byte InternIds.
    attr_get_path_or_w,
    /// Select an attribute path containing static and runtime string segments
    /// with a lazy default if any segment is missing.
    /// Operand: 1-byte segment count, 1-byte dynamic segment count, then for
    /// each segment a 1-byte tag: 0 followed by 4-byte InternId for static,
    /// 1 for the next runtime string from the stack.
    /// Stack layout before: [attrs, dynamic_name..., default_thunk].
    attr_get_path_mix_or,
    /// Test whether an attribute path exists without forcing the final value.
    /// Operand: 1-byte segment count, then that many 2-byte InternIds.
    /// Stack layout before: [attrs].
    attr_has_path,
    /// Wide-intern-id form of attr_has_path.
    /// Operand: 1-byte segment count, then that many 4-byte InternIds.
    attr_has_path_w,
    /// Test whether an attribute path containing static and runtime string
    /// segments exists without forcing the final value.
    /// Operand: same segment stream as attr_get_path_mix_or.
    /// Stack layout before: [attrs, dynamic_name_thunk...].
    attr_has_path_mix,
    /// Validate an attrset function argument.
    /// Operand: 1-byte allow_extra flag, 2-byte expected count, then expected InternIds.
    /// Stack layout before: [attrs].
    attr_check,
    /// Wide-intern-id form of attr_check.
    /// Operand: 1-byte allow_extra flag, 2-byte expected count, then 4-byte InternIds.
    attr_check_w,
    /// Look up a variable name through active with-scopes.
    /// Operand: 2-byte InternId, 1-byte scope count.
    /// Stack layout before: [scope1, ..., scopeN], ordered nearest to farthest.
    with_lookup,
    /// Wide-intern-id form of with_lookup.
    /// Operand: 4-byte InternId, 1-byte scope count.
    with_lookup_w,
    /// Lazy per-attr compilation: create a `.deferred` thunk for an
    /// attrset value body whose bytecode has NOT been compiled. The body
    /// is compiled on first force (see `compiler/deferred_table.zig` and
    /// `compiler/deferred.zig`).
    /// Operand: 4-byte deferred-table id, 2-byte env count, then `env`
    /// capture descriptors (kind:1, index:2) — same format as thunk.
    thunk_defer,
    // ---- termination ----
    /// Return from the current frame with the value on top of stack.
    ret,
    /// Halt execution (top-level done).
    halt,
};

pub const count = @typeInfo(OpCode).@"enum".fields.len;

const std = @import("std");

test "opcode byte values round-trip through enumFromInt" {
    inline for (@typeInfo(OpCode).@"enum".fields) |field| {
        const op: OpCode = @enumFromInt(field.value);
        try std.testing.expectEqual(@as(u8, field.value), @intFromEnum(op));
    }
}

test "opcode count matches the number of declared variants" {
    try std.testing.expectEqual(@typeInfo(OpCode).@"enum".fields.len, count);
    // Sanity bound: the opcode set is small and fits comfortably in a u8,
    // which the bytecode encoding relies on.
    try std.testing.expect(count > 0);
    try std.testing.expect(count <= 256);
}

test "opcode tag names are unique" {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(std.testing.allocator);
    inline for (@typeInfo(OpCode).@"enum".fields) |field| {
        const result = try seen.getOrPut(std.testing.allocator, field.name);
        try std.testing.expect(!result.found_existing);
    }
}
