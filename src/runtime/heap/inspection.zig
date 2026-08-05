//! Stable, read-only heap projection types for tooling.

const types = @import("../types.zig");
const ValueType = @import("../value.zig").ValueType;

pub const ObjectId = types.ObjectId;
pub const ChunkId = types.ChunkId;
pub const InternId = types.InternId;

pub const ValueRef = struct {
    kind: ValueType,
    target: Target = .none,

    pub const Target = union(enum) {
        none,
        object: ObjectId,
        chunk: ChunkId,
        intern: InternId,
        builtin: u16,
    };
};

pub const HeapReference = union(enum) {
    object: ObjectId,
    chunk: ChunkId,
};

pub const ThunkState = enum(u8) { unresolved, evaluating, resolved, blackhole, errored };

pub const ThunkTargetInfo = union(enum) {
    closure: ValueRef,
    bytecode: struct { chunk: ChunkId, captures: u32 },
    pass_through: ValueRef,
    attr_access: struct { base: ValueRef, name: InternId },
    deferred: struct { id: u32, captures: u32 },
};

pub const ThunkInfo = struct {
    state: ThunkState,
    demanded: bool,
    body: union(enum) {
        target: ThunkTargetInfo,
        result: ValueRef,
        error_name: []const u8,
    },
};

pub const ObjectInfo = union(enum) {
    list: struct { len: u32 },
    attrs: struct { len: u32, positions: u32, sibling_swept: bool },
    merge_attrs: struct {
        base: ObjectId,
        overlay: ObjectId,
        depth: u16,
        flattened: ?ObjectId,
    },
    closure: struct { chunk: ChunkId, upvalues: u32 },
    builtin_closure: struct { builtin: u16, args: u32 },
    thunk: ThunkInfo,
    context_string: struct { text: InternId, context: u32 },
    boxed_int: i64,
    partial_app: struct { function: ValueRef, args: u32 },
    heap_string: struct { len: u32 },
};
