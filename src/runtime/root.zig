//! `runtime` module facade: the value/heap data layer.
//!
//! NaN-boxed values, the object heap, thunks, interning, and the numeric /
//! hashing / path primitives the evaluator is built on, plus the builtin value
//! registry. Depends only on the generic `base` module. Consumers import this
//! module by name (`@import("runtime")`) and
//! reach submodules through it; they must not import `runtime/*` files directly.

pub const types = @import("types.zig");
pub const value = @import("value.zig");
pub const heap = @import("heap.zig");
pub const heap_edges = @import("heap/edges.zig");
pub const heap_collector = @import("heap/collector.zig");
pub const future = @import("future.zig");
pub const failure = @import("failure.zig");
pub const thunk = @import("thunk.zig");
pub const intern = @import("intern.zig");
pub const numeric = @import("numeric.zig");
pub const grisu2 = @import("grisu2.zig");
pub const int = @import("int.zig");
pub const hash = @import("hash.zig");
pub const version = @import("version.zig");
pub const paths = @import("paths.zig");
pub const gc = @import("gc.zig");
pub const builtins = @import("builtins.zig");
pub const mem_tag = @import("mem_tag.zig");

// Common flat re-exports for the most-used types.
pub const Value = value.Value;
pub const ObjectHeap = heap.ObjectHeap;
pub const InternTable = intern.InternTable;
pub const BuiltinId = builtins.BuiltinId;

test {
    _ = types;
    _ = value;
    _ = heap;
    _ = heap_edges;
    _ = heap_collector;
    _ = future;
    _ = failure;
    _ = thunk;
    _ = intern;
    _ = numeric;
    _ = int;
    _ = hash;
    _ = version;
    _ = paths;
    _ = gc;
    _ = builtins;
    _ = grisu2;
    _ = mem_tag;
    _ = @import("concurrency_tests.zig");
}
