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
    /// Duplicate top of stack.
    dup,

    // ---- locals ----
    /// Push local variable at offset (operand: 1-byte offset from frame base).
    get_local,
    /// Push local variable without forcing lazy cells (operand: 1-byte offset).
    capture_local,
    /// Push captured upvalue without forcing lazy cells (operand: 1-byte offset).
    capture_upvalue,
    /// Set local variable at offset, popping from stack.
    set_local,
    /// Set the value inside a local cell, popping from stack.
    set_cell_local,
    /// Push captured upvalue at offset (operand: 1-byte closure upvalue index).
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
    negate_float,

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
    /// Relative jump forward (operand: 2-byte signed offset).
    jump,
    /// Jump forward if top of stack is truthy (operand: 2-byte signed offset).
    jump_if_false,
    /// Jump backward (operand: 2-byte signed offset, interpreted as negative).
    jump_back,

    // ---- data ----
    /// Build an attribute set from pairs on the stack.
    /// Operand: 2-byte count of entries.
    /// Stack layout from lower to higher indexes: [name1, val1, ..., nameN, valN].
    build_attrs,
    /// Build a list from items on the stack.
    /// Operand: 2-byte count of items.
    build_list,
    /// Concatenate the top two strings and push result.
    concat_string,
    /// Interpolate: replace placeholders in a template string.
    /// Operand: 2-byte count of substitutions.
    interpolate,

    // ---- closures and thunks ----
    /// Create a closure value from a chunk and captured upvalues.
    /// Operand: 2-byte ChunkId, 1-byte upvalue count.
    /// Upvalues are the top N values on the stack, popped.
    closure,

    // ---- calls ----
    /// Call the top-of-stack closure with the value below it as argument.
    /// The stack layout before: [closure, arg].
    /// After: [result].
    call,
    /// Tail call: replace current frame with a call to the closure below top.
    tail_call,

    // ---- thunks ----
    /// Wrap the top-of-stack zero-argument closure into a lazy thunk.
    make_thunk,
    /// Wrap the top-of-stack value in a mutable lazy cell.
    make_cell,

    // ---- attribute access ----
    /// Select an attribute from attrset on stack top.
    /// Operand: 2-byte InternId of the attribute name.
    get_attr,
    /// Like get_attr, but if missing, return the default value below the attrset.
    get_attr_or,

    // ---- environment ----
    /// Push a with-scope environment entry.
    push_env,
    /// Pop one environment entry.
    pop_env,

    // ---- termination ----
    /// Return from the current frame with the value on top of stack.
    ret,
    /// Halt execution (top-level done).
    halt,
};
