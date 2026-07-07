//! `runtime` module facade — the value/heap data layer.
//!
//! NaN-boxed values, the object heap, thunks, interning, and the numeric /
//! hashing / path primitives the evaluator is built on. Plus the builtin value
//! registry and the file/fetch caches. Self-contained: depends on nothing else
//! in the tree. Consumers import this module by name (`@import("runtime")`) and
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
pub const nar = @import("runtime/nar.zig");
pub const regex = @import("runtime/regex.zig");
pub const toml = @import("runtime/toml.zig");
pub const paths = @import("runtime/paths.zig");
pub const worker_id = @import("runtime/worker_id.zig");
pub const stable_segments = @import("runtime/stable_segments.zig");
pub const struct_census = @import("runtime/struct_census.zig");
pub const gc = @import("runtime/gc.zig");
pub const builtins = @import("runtime/builtins.zig");
pub const file_cache = @import("runtime/file_cache.zig");
pub const fetch_cache = @import("runtime/fetch_cache.zig");
pub const block_cache = @import("runtime/block_cache.zig");

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
    _ = nar;
    _ = regex;
    _ = toml;
    _ = paths;
    _ = worker_id;
    _ = stable_segments;
    _ = struct_census;
    _ = gc;
    _ = builtins;
    _ = file_cache;
    _ = fetch_cache;
    _ = block_cache;
}
