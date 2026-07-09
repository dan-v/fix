//! Data-structure builders: attrset and list literal construction from stack
//! operands, the `//` update merge (lazy layered + strict recursive), and list
//! concatenation.
const std = @import("std");
const vm_mod = @import("../vm.zig");
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const heap_mod = @import("runtime").heap;

const force = @import("force.zig");
const stack = @import("stack.zig");
const trace = @import("trace.zig");

const VM = vm_mod.VM;

// ---- data structure builders ----

pub fn buildAttrs(self: *VM, count: u16) !void {
    const value_count: u32 = @as(u32, count) * 2;
    const start = self.sp - value_count;
    const id = try self.heap.addAttrsFromStackPairs(self.stack[start..self.sp]);
    self.sp = start;
    try stack.push(self, Value.attrs(id));
}

pub fn buildAttrsWithPositions(self: *VM, count: u16, positions: []const heap_mod.AttrPosEntry) !void {
    const value_count: u32 = @as(u32, count) * 2;
    const start = self.sp - value_count;
    const id = try self.heap.addAttrsFromStackPairsWithPositions(self.stack[start..self.sp], positions);
    self.sp = start;
    try stack.push(self, Value.attrs(id));
}

/// `build_attrs_sorted(_with_pos)`: pairs are compile-time sorted by
/// interned name and duplicate-free — skip the construction sort.
pub fn buildAttrsSorted(self: *VM, count: u16, positions: []const heap_mod.AttrPosEntry) !void {
    const value_count: u32 = @as(u32, count) * 2;
    const start = self.sp - value_count;
    const id = try self.heap.addAttrsFromStackPairsSorted(self.stack[start..self.sp], positions);
    self.sp = start;
    try stack.push(self, Value.attrs(id));
}

pub fn buildList(self: *VM, count: u16) !void {
    const start = self.sp - count;
    const id = try self.heap.addList(self.stack[start..self.sp]);
    self.sp = start;
    try stack.push(self, Value.list(id));
}

pub fn mergeAttrs(self: *VM, left: Value, right: Value) !Value {
    if (!left.isAttrs()) return trace.typeErrorExpected(self, "attrs", left);
    if (!right.isAttrs()) return trace.typeErrorExpected(self, "attrs", right);
    return Value.attrs(try self.heap.mergeAttrsLayered(left.asObjectId(), right.asObjectId()));
}

pub fn mergeAttrsStrict(self: *VM, left: Value, right: Value) !Value {
    if (!left.isAttrs()) return trace.typeErrorExpected(self, "attrs", left);
    if (!right.isAttrs()) return trace.typeErrorExpected(self, "attrs", right);
    return Value.attrs(try mergeAttrLiteralObjects(self, left.asObjectId(), right.asObjectId()));
}

pub fn mergeAttrLiteralObjects(self: *VM, left_id: types.ObjectId, right_id: types.ObjectId) anyerror!types.ObjectId {
    // Recursive calls receive nested attr ids that are NOT on the operand
    // stack; root the input objects so their `left`/`right` slices survive
    // the forces inside mergeAttrLiteralValue.
    const gc_roots = force.rootsBegin(self);
    defer force.rootsEnd(self, gc_roots);
    force.rootKeep(self, Value.attrs(left_id));
    force.rootKeep(self, Value.attrs(right_id));

    var left = try self.heap.getAttrs(left_id);
    var right = try self.heap.getAttrs(right_id);
    const left_len = left.len;
    const right_len = right.len;

    // Reserve worst-case (no overlap) directly in heap attr storage
    // and walk both sides in lockstep, writing the merge in place.
    // Both inputs are sorted+deduped (heap invariant), so the output
    // is sorted+unique by construction. Skips a per-merge ArrayList
    // alloc + one copy compared to the staged-then-flush pattern.
    const cap: u32 = @intCast(left_len + right_len);
    const reserved = try self.heap.reserveAttrsForMerge(cap);
    const dst = self.heap.attrsMutSlice(reserved);

    var out: usize = 0;
    var left_i: usize = 0;
    var right_i: usize = 0;
    while (left_i < left_len and right_i < right_len) {
        // gc: re-fetch — the input ranges may move across mergeAttrLiteralValue's force
        left = try self.heap.getAttrs(left_id);
        right = try self.heap.getAttrs(right_id);
        const l = left[left_i];
        const r = right[right_i];
        if (l.name < r.name) {
            dst[out] = l;
            out += 1;
            left_i += 1;
        } else if (l.name > r.name) {
            dst[out] = r;
            out += 1;
            right_i += 1;
        } else {
            // Duplicate name. `mergeAttrLiteralValue` reads from the
            // heap so it's safe to call while we hold a reserved
            // range — the merge target is its own segment of the
            // attr store, not the inputs we're reading.
            const value = try mergeAttrLiteralValue(self, l.value, r.value);
            dst[out] = .{ .name = l.name, .value = value };
            out += 1;
            left_i += 1;
            right_i += 1;
        }
    }
    // gc: re-fetch — ranges may have moved across the loop's forces
    left = try self.heap.getAttrs(left_id);
    right = try self.heap.getAttrs(right_id);
    if (left_i < left_len) {
        const n = left_len - left_i;
        @memcpy(dst[out..][0..n], left[left_i..]);
        out += n;
    }
    if (right_i < right_len) {
        const n = right_len - right_i;
        @memcpy(dst[out..][0..n], right[right_i..]);
        out += n;
    }

    return self.heap.publishMergedAttrs(reserved, @intCast(out));
}

pub fn mergeAttrLiteralValue(self: *VM, left: Value, right: Value) anyerror!Value {
    const left_forced = try force.forceValue(self, left);
    const right_forced = try force.forceValue(self, right);
    if (left_forced.isAttrs() and right_forced.isAttrs()) {
        return Value.attrs(try mergeAttrLiteralObjects(self, left_forced.asObjectId(), right_forced.asObjectId()));
    }
    return error.DuplicateAttribute;
}

pub fn concatLists(self: *VM, left: Value, right: Value) !Value {
    if (!left.isList()) return trace.typeErrorExpected(self, "list", left);
    if (!right.isList()) return trace.typeErrorExpected(self, "list", right);
    return Value.list(try self.heap.addConcatenatedLists(left.asObjectId(), right.asObjectId()));
}
