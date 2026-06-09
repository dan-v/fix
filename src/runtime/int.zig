//! Integer helpers that bridge the inline-vs-boxed distinction.
//!
//! Under Value16 (default) every i64 fits inline in the Value's payload
//! and `boxed_int` is never created. Under Value8 (NaN-boxed), the
//! payload only holds i48; rarer i64 values overflow into a heap-boxed
//! `Object.boxed_int` slot referenced by ObjectId.
//!
//! Call sites that produce integers from sources that can exceed i48
//! (source literals, arithmetic results, JSON/TOML parsing) should
//! create the Value via `make`; sites that consume integers regardless
//! of encoding (arithmetic operands, equality, serialisation) should
//! read via `get`. The fast inline path stays branch-free; the boxed
//! path is a single heap dereference.

const std = @import("std");
const build_options = @import("build_options");
const Value = @import("value.zig").Value;
const heap_mod = @import("heap.zig");
const ObjectHeap = heap_mod.ObjectHeap;
const ObjectId = heap_mod.ObjectId;

/// Inclusive bound of the inline-int payload. Values strictly outside
/// this range require boxing under Value8. Value16 ignores the limit
/// and inlines any i64.
const I48_MIN: i64 = -(@as(i64, 1) << 47);
const I48_MAX: i64 = (@as(i64, 1) << 47) - 1;

inline fn fitsInline(v: i64) bool {
    // Value16's inline payload holds the full i64; only Value8 needs the
    // i48 check. Branch on the build flag at comptime so Value16 builds
    // never even reference the boxed_int Object variant.
    if (!build_options.value8) return true;
    return v >= I48_MIN and v <= I48_MAX;
}

/// Construct a Value carrying `v`. Inlines when possible, boxes via
/// `heap.addBoxedInt` when not. Safe to call regardless of build flag —
/// Value16 always inlines.
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
