//! `runtime` module facade — the value/heap data layer.
//!
//! NaN-boxed values, the object heap, thunks, interning, and the numeric /
//! hashing / path primitives the evaluator is built on, plus the builtin value
//! registry. Concrete filesystem, network, and daemon effects live in `host`.
//! Depends only on the generic `base`
//! module. Consumers import this module by name (`@import("runtime")`) and
//! reach submodules through it; they must not import `runtime/*` files directly.

pub const types = @import("runtime/types.zig");
pub const value = @import("runtime/value.zig");
pub const heap = @import("runtime/heap.zig");
pub const thunk = @import("runtime/thunk.zig");
pub const intern = @import("runtime/intern.zig");
pub const numeric = @import("runtime/numeric.zig");
pub const int = @import("runtime/int.zig");
pub const hash = @import("runtime/hash.zig");
pub const version = @import("runtime/version.zig");
pub const paths = @import("runtime/paths.zig");
pub const gc = @import("runtime/gc.zig");
pub const builtins = @import("runtime/builtins.zig");
pub const mem_tag = @import("runtime/mem_tag.zig");

// Common flat re-exports for the most-used types.
pub const Value = value.Value;
pub const ObjectHeap = heap.ObjectHeap;
pub const InternTable = intern.InternTable;
pub const BuiltinId = builtins.BuiltinId;

test {
    _ = types;
    _ = value;
    _ = heap;
    _ = thunk;
    _ = intern;
    _ = numeric;
    _ = int;
    _ = hash;
    _ = version;
    _ = paths;
    _ = gc;
    _ = builtins;
    _ = mem_tag;
}
