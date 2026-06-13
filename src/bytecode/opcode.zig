//! Bytecode opcodes for the tail-calling VM.
//!
//! The interpreter is a direct-threaded bytecode loop. Each instruction
//! is a u8 opcode followed by 0–N operand bytes.
//! Multi-byte operands use little-endian encoding.

pub const OpCode = enum(u8) {
    // ---- stack ----
    /// Push a constant from the chunk constant pool (operand: 2-byte ConstIdx).
    constant,
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
    get_local,
    /// Push local variable at offset (operand: 2-byte offset from frame base).
    get_local_long,
    /// Push local variable without forcing lazy cells (operand: 1-byte offset).
    capture_local,
    /// Push local variable without forcing lazy cells (operand: 2-byte offset).
    capture_local_long,
    /// Push captured upvalue without forcing lazy cells (operand: 2-byte index).
    capture_upvalue,
    /// Set local variable at offset, popping from stack.
    set_local,
    /// Set local variable at offset, popping from stack (operand: 2-byte offset).
    set_local_long,
    /// Set the value inside a local cell, popping from stack.
    set_cell_local,
    /// Set the value inside a local cell (operand: 2-byte offset).
    set_cell_local_long,
    /// Push captured upvalue at offset (operand: 2-byte closure upvalue index).
    get_upvalue,

    // ---- arithmetic ----
    add_int,
    sub_int,
    mul_int,
    div_int,
    negate_int,
    add_float,
    sub_float,
    mul_float,
    div_float,

    // ---- comparison ----
    eq,
    neq,
    lt,
    lte,
    gt,
    gte,
    /// Specialized `eq null` — pop one value, push `true` if it
    /// forces to null. Emitted by `compileBinary` when one side of
    /// `==` is a literal `null`. Skips the generic `valuesEqual`
    /// dispatch and gives the JIT a type-monomorphic null-check.
    eq_null,
    /// Specialized `neq null` — symmetric with `eq_null`.
    neq_null,

    // ---- logical ----
    not,

    // ---- control flow ----
    /// Relative jump forward (operand: 4-byte unsigned offset).
    jump,
    /// Jump forward if top of stack is false (operand: 4-byte unsigned offset).
    jump_if_false,
    /// Raise an assertion failure.
    fail_assertion,

    // ---- data ----
    /// Build an attribute set from pairs on the stack.
    /// Operand: 2-byte count of entries.
    /// Stack layout from lower to higher indexes: [name1, val1, ..., nameN, valN].
    build_attrs,
    /// Build an attribute set from pairs on the stack and attach source positions.
    /// Operand: 2-byte count, 2-byte source-position count, then repeated
    /// 4-byte name InternId, 4-byte file InternId, 4-byte line, 4-byte column.
    build_attrs_with_pos,
    /// Build a list from items on the stack.
    /// Operand: 2-byte count of items.
    build_list,
    /// Merge two attrsets as parts of one attrset literal, recursively rejecting
    /// duplicate leaf attributes.
    merge_attrs_strict,
    /// Merge two attrsets, with right-hand keys overriding left-hand keys.
    merge_attrs,
    /// Concatenate two lists.
    concat_lists,
    /// Push the evaluator-owned builtins attrset.
    push_builtins,
    /// Resolve an evaluator search-path literal.
    /// Operand: 2-byte InternId of the search path text without angle brackets.
    find_file,
    /// Resolve an evaluator search-path literal with a wide intern id.
    /// Operand: 4-byte InternId.
    find_file_long,

    // ---- closures and thunks ----
    /// Create a closure value from a chunk and captured upvalues.
    /// Operand: 2-byte ChunkId, 2-byte upvalue count.
    /// Upvalues are the top N values on the stack, popped.
    closure,
    /// Create a closure whose chunk id does not fit in the short form.
    /// Operand: 4-byte ChunkId, 2-byte upvalue count.
    closure_long,
    /// Create a closure and fill upvalues from inline capture descriptors.
    /// Operand: 2-byte ChunkId, 2-byte count, then repeated
    /// 1-byte kind (0=local, 1=upvalue), 2-byte index.
    closure_captures,
    /// Wide-chunk-id form of closure_captures.
    /// Operand: 4-byte ChunkId, 2-byte count, then repeated descriptors.
    closure_captures_long,
    /// Function-argument with a runtime-adaptive laziness decision. The
    /// callee is already on the stack (just below where the argument
    /// goes). If it is a closure whose chunk's body must-forces its
    /// parameter (`scheduling.strict_param`), the argument expression is
    /// evaluated eagerly to a value — no thunk; otherwise it is
    /// materialised as a thunk exactly like `thunk_captures`. Lets us
    /// skip the thunk for dynamically-dispatched strict calls, which the
    /// compiler can't resolve statically.
    /// Operand: 4-byte ChunkId, 2-byte count, then repeated descriptors.
    apply_arg,
    /// Create a thunk directly from a chunk and inline capture descriptors.
    /// Operand: 2-byte ChunkId, 2-byte count, then repeated descriptors.
    thunk_captures,
    /// Wide-chunk-id form of thunk_captures.
    /// Operand: 4-byte ChunkId, 2-byte count, then repeated descriptors.
    thunk_captures_long,
    /// Same as `thunk_captures` but submits the thunk to the urgent
    /// scheduler queue at creation time. Emitted by the compiler when
    /// strictness analysis says the surrounding chunk's body will
    /// unconditionally force this binding — turns the chunk-size
    /// speculation heuristic into a deterministic decision and
    /// bypasses the speculation backlog cap.
    thunk_captures_eager,
    /// Wide-chunk-id form of thunk_captures_eager.
    thunk_captures_eager_long,

    /// Fused `thunk_captures + set_cell_local`. Creates the thunk
    /// from the chunk-id + descriptors, then `publishCellBinding`s it
    /// into the cell-thunk at frame_base + slot (skipping the
    /// push/pop of the new thunk reference). Operand layout:
    ///   chunk_id:2 + K:2 + 3K descriptors + slot:1
    /// The slot byte is at the END so we can rewrite `thunk_captures`
    /// in place at emit time without shifting the descriptor bytes.
    thunk_captures_store_cell_local,
    /// Fused `thunk_captures + set_local`.
    thunk_captures_store_local,
    /// Fused `thunk_captures_eager + set_cell_local`.
    thunk_captures_eager_store_cell_local,
    /// Fused `thunk_captures_eager + set_local`.
    thunk_captures_eager_store_local,

    // ---- calls ----
    /// Call the top-of-stack closure with the value below it as argument.
    /// The stack layout before: [closure, arg].
    /// After: [result].
    call,
    /// Call in tail position. Closure callees reuse the current frame; other
    /// callees behave like `call` and are followed by the normal `ret`.
    tail_call,

    // ---- fused value+ret super-ops ----
    /// Fused `constant + ret`: load constant N onto the stack and
    /// return from the current frame in one dispatch. Operand:
    /// 2-byte constant index. Emitted by `compileTailExpression`
    /// when the tail expression is a literal — saves one of the two
    /// dispatches that dominate the bytecode loop's per-thunk
    /// overhead.
    constant_ret,
    /// Fused `get_local + ret` (narrow slot).
    get_local_ret,
    /// Fused `get_local + ret` (wide slot — 2-byte operand).
    get_local_ret_long,
    /// Fused `get_upvalue + ret` (always 2-byte upvalue index).
    get_upvalue_ret,

    // ---- fused compound super-ops ----
    /// Fused `get_upvalue + get_attr` — read upvalue, force, look up
    /// attribute. Operand: 2-byte upvalue index + 2-byte name InternId.
    /// Saves the push/pop of the attrs value plus one dispatch. The
    /// `lib.foo` and `config.bar` patterns are everywhere in NixOS
    /// modules; profiling shows `get_upvalue` is 10% of all ops and
    /// `get_attr` is 3%, much of it the same upvalue→attr chain.
    get_upvalue_attr,
    /// Fused `get_local + get_attr` (narrow slot — 1-byte). Operand:
    /// 1-byte slot + 2-byte name InternId.
    get_local_attr,
    /// Fused `get_local_long + get_attr` (wide slot — 2-byte). Operand:
    /// 2-byte slot + 2-byte name InternId.
    get_local_attr_long,

    // ---- thunks ----
    /// Wrap the top-of-stack value in a mutable lazy cell.
    make_cell,
    /// Wrap the top-of-stack value in a pre-resolved, undemanded
    /// thunk. Used by the compiler when an eagerly-buildable shape
    /// (list / attrset / lambda) appears in a context that requires
    /// the value to *look* like a lazy thunk to renderers (XML lazy
    /// mode in particular) — we skip emitting a child chunk +
    /// `thunk_captures` and just wrap the already-built shell. The
    /// resulting thunk's `force` is O(1) (resolved fast path); the
    /// XML serializer keeps printing `<unevaluated />` until a real
    /// caller marks it demanded.
    make_lazy_shell,
    /// Allocate an empty (null-wrapped) lazy cell and store it
    /// directly into a local slot. Operand: 1-byte slot index. Fuses
    /// the `push_null + make_cell + set_local` sequence that the
    /// compiler emits once per let-binding / recursive-attrset
    /// binding / lambda parameter — saving two dispatches and the
    /// intermediate stack push/pop per call.
    init_cell_slot,
    /// Wide-slot variant of `init_cell_slot`. Operand: 2-byte slot index.
    init_cell_slot_long,

    // ---- attribute access ----
    /// Select an attribute from attrset on stack top.
    /// Operand: 2-byte InternId of the attribute name.
    get_attr,
    /// Select an attribute from attrset on stack top with a wide intern id.
    /// Operand: 4-byte InternId.
    get_attr_long,
    /// Select an attribute by a runtime string name.
    /// Stack layout before: [attrs, name].
    get_attr_dynamic,
    /// Select a runtime string attribute with a lazy default.
    /// Stack layout before: [attrs, name, default_thunk].
    get_attr_dynamic_or,
    /// Select a static attribute path prefix followed by a runtime string
    /// attribute with a lazy default if any segment is missing.
    /// Operand: 1-byte segment count, then that many 2-byte InternIds.
    /// Stack layout before: [attrs, name, default_thunk].
    get_attr_path_dynamic_or,
    /// Wide-intern-id form of get_attr_path_dynamic_or.
    /// Operand: 1-byte segment count, then that many 4-byte InternIds.
    get_attr_path_dynamic_or_long,
    /// Select an attribute path with a lazy default if any segment is missing.
    /// Operand: 1-byte segment count, then that many 2-byte InternIds.
    /// Stack layout before: [attrs, default_thunk].
    get_attr_path_or,
    /// Wide-intern-id form of get_attr_path_or.
    /// Operand: 1-byte segment count, then that many 4-byte InternIds.
    get_attr_path_or_long,
    /// Select an attribute path containing static and runtime string segments
    /// with a lazy default if any segment is missing.
    /// Operand: 1-byte segment count, 1-byte dynamic segment count, then for
    /// each segment a 1-byte tag: 0 followed by 4-byte InternId for static,
    /// 1 for the next runtime string from the stack.
    /// Stack layout before: [attrs, dynamic_name..., default_thunk].
    get_attr_path_mixed_or,
    /// Test whether an attribute path exists without forcing the final value.
    /// Operand: 1-byte segment count, then that many 2-byte InternIds.
    /// Stack layout before: [attrs].
    has_attr_path,
    /// Wide-intern-id form of has_attr_path.
    /// Operand: 1-byte segment count, then that many 4-byte InternIds.
    has_attr_path_long,
    /// Test whether a runtime string attribute exists.
    /// Stack layout before: [attrs, name].
    has_attr_dynamic,
    /// Test whether an attribute path containing static and runtime string
    /// segments exists without forcing the final value.
    /// Operand: same segment stream as get_attr_path_mixed_or.
    /// Stack layout before: [attrs, dynamic_name_thunk...].
    has_attr_path_mixed,
    /// Validate an attrset function argument.
    /// Operand: 1-byte allow_extra flag, 2-byte expected count, then expected InternIds.
    /// Stack layout before: [attrs].
    validate_attrs,
    /// Wide-intern-id form of validate_attrs.
    /// Operand: 1-byte allow_extra flag, 2-byte expected count, then 4-byte InternIds.
    validate_attrs_long,
    /// Look up a variable name through active with-scopes.
    /// Operand: 2-byte InternId, 1-byte scope count.
    /// Stack layout before: [scope1, ..., scopeN], ordered nearest to farthest.
    lookup_with,
    /// Wide-intern-id form of lookup_with.
    /// Operand: 4-byte InternId, 1-byte scope count.
    lookup_with_long,
    // ---- termination ----
    /// Return from the current frame with the value on top of stack.
    ret,
    /// Halt execution (top-level done).
    halt,
};

pub const count = @typeInfo(OpCode).@"enum".fields.len;
