//! Integer helpers that bridge the inline-vs-boxed distinction.
//!
//! Value's NaN-boxed int payload is 48 bits wide; i64 values outside
//! that range overflow into a heap-boxed `Object.boxed_int` slot
//! referenced by ObjectId.
//!
//! Call sites that produce integers from sources that can exceed i48
//! (source literals, arithmetic results, JSON/TOML parsing) should
//! create the Value via `make`; sites that consume integers regardless
//! of encoding (arithmetic operands, equality, serialisation) should
//! read via `get`. The fast inline path stays branch-free; the boxed
//! path is a single heap dereference.

const std = @import("std");
const Value = @import("value.zig").Value;
const heap_mod = @import("heap.zig");
const ObjectHeap = heap_mod.ObjectHeap;
const ObjectId = heap_mod.ObjectId;

/// Inclusive bound of the inline-int payload. Values strictly outside
/// this range are heap-boxed via `boxed_int`.
const i48_min: i64 = -(@as(i64, 1) << 47);
const i48_max: i64 = (@as(i64, 1) << 47) - 1;

inline fn fitsInline(v: i64) bool {
    return v >= i48_min and v <= i48_max;
}

/// Construct a Value carrying `v`. Inlines when `|v| < 2^47`; boxes
/// via `heap.addBoxedInt` otherwise.
pub fn make(heap: *ObjectHeap, v: i64) !Value {
    if (fitsInline(v)) return Value.int(v);
    const id = try heap.addBoxedInt(v);
    return Value.boxedInt(id);
}

/// Read the i64 value carried by `v`. Asserts `v` is an int (inline or
/// boxed). Inline values cost a single accessor call; boxed values cost
/// one heap dereference.
pub fn get(v: Value, heap: *const ObjectHeap) i64 {
    if (v.isInt()) return v.asInt();
    std.debug.assert(v.isBoxedInt());
    return heap.getBoxedInt(v.asObjectId()) catch unreachable;
}

/// True iff `v` is an integer in either encoding.
pub fn isAnyInt(v: Value) bool {
    return v.isInt() or v.isBoxedInt();
}
