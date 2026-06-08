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
    /// Create a thunk directly from a chunk and inline capture descriptors.
    /// Operand: 2-byte ChunkId, 2-byte count, then repeated descriptors.
    thunk_captures,
    /// Wide-chunk-id form of thunk_captures.
    /// Operand: 4-byte ChunkId, 2-byte count, then repeated descriptors.
    thunk_captures_long,

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

    // ---- thunks ----
    /// Wrap the top-of-stack value in a mutable lazy cell.
    make_cell,
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
