//! The one GC-safe VM string-context merge algorithm.
//!
//! String concatenation (`vm/strings.zig`) and the context builtins
//! (`vm/builtins/string_context.zig`) both merge string-context attrsets. They
//! previously each carried their own copy, which drifted: one had weaker GC
//! rooting than the other. Keeping the algorithm here — descriptor
//! insertion/merge, `outputs` union/dedup/sort, GC rooting, and post-force slice
//! re-fetching — means the rooting and set rules stay in lock-step.
//!
//! Every operation takes the concrete `*VM` interface used by the builtins.

const std = @import("std");
const VM = @import("context.zig").VM;
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const InternId = types.InternId;
const ObjectId = types.ObjectId;
const heap_mod = @import("runtime").heap;
const vm_force = @import("force.zig");
const strings = @import("strings.zig");

/// Insert `value` under `name`, merging into any existing entry for `name`.
pub fn appendContextEntry(self: *VM, context: *std.ArrayListUnmanaged(heap_mod.AttrEntry), name: InternId, value: Value) !void {
    for (context.items) |*entry| {
        if (entry.name == name) {
            // GC: mergeContextValues forces; the already-accumulated entries in
            // `context` (caller-owned, not on the VM stack) plus the incoming
            // `value` must survive the walk.
            const gc_roots = vm_force.rootsBegin(self);
            defer vm_force.rootsEnd(self, gc_roots);
            for (context.items) |held| vm_force.rootKeep(self, held.value);
            vm_force.rootKeep(self, value);
            entry.value = try mergeContextValues(self, entry.value, value);
            return;
        }
    }
    try context.append(self.allocator, .{ .name = name, .value = value });
}

pub fn mergeContextValues(self: *VM, left: Value, right: Value) !Value {
    // GC: `left` is held across the force of `right`, and both forced ids are
    // held across mergeContextAttrs (which forces). Root both across the walk.
    const gc_roots = vm_force.rootsBegin(self);
    defer vm_force.rootsEnd(self, gc_roots);
    vm_force.rootKeep(self, left);
    vm_force.rootKeep(self, right);
    const left_forced = try vm_force.forceValue(self, left);
    const right_forced = try vm_force.forceValue(self, right);
    if (left_forced.isAttrs() and right_forced.isAttrs()) {
        return Value.attrs(try mergeContextAttrs(self, left_forced.asObjectId(), right_forced.asObjectId()));
    }
    return right;
}

pub fn mergeContextAttrs(self: *VM, left_id: ObjectId, right_id: ObjectId) !ObjectId {
    // GC: `left`/`right` are raw attr slices held across mergeContextAttrValue
    // -> mergeContextOutputs forces; keep their owner objects live.
    const gc_roots = vm_force.rootsBegin(self);
    defer vm_force.rootsEnd(self, gc_roots);
    vm_force.rootKeep(self, Value.attrs(left_id));
    vm_force.rootKeep(self, Value.attrs(right_id));
    var left = try self.heap.getAttrs(left_id);
    var right = try self.heap.getAttrs(right_id);
    const left_len = left.len;
    const right_len = right.len;

    var merged = try std.ArrayListUnmanaged(heap_mod.AttrEntry).initCapacity(self.allocator, left_len + right_len);
    defer merged.deinit(self.allocator);

    var left_i: usize = 0;
    var right_i: usize = 0;
    while (left_i < left_len and right_i < right_len) {
        // gc: re-fetch — ranges may move across mergeContextAttrValue's force
        left = try self.heap.getAttrs(left_id);
        right = try self.heap.getAttrs(right_id);
        const l = left[left_i];
        const r = right[right_i];
        if (l.name < r.name) {
            merged.appendAssumeCapacity(l);
            left_i += 1;
        } else if (l.name > r.name) {
            merged.appendAssumeCapacity(r);
            right_i += 1;
        } else {
            const value = try mergeContextAttrValue(self, l.name, l.value, r.value);
            merged.appendAssumeCapacity(.{ .name = l.name, .value = value });
            left_i += 1;
            right_i += 1;
        }
    }
    // gc: re-fetch — ranges may have moved across the loop's forces
    left = try self.heap.getAttrs(left_id);
    right = try self.heap.getAttrs(right_id);
    while (left_i < left_len) : (left_i += 1) {
        merged.appendAssumeCapacity(left[left_i]);
    }
    while (right_i < right_len) : (right_i += 1) {
        merged.appendAssumeCapacity(right[right_i]);
    }

    return self.heap.addAttrsSorted(merged.items);
}

pub fn mergeContextAttrValue(self: *VM, name: InternId, left: Value, right: Value) !Value {
    if (name == try self.intern.intern("outputs")) return mergeContextOutputs(self, left, right);
    return right;
}

pub fn mergeContextOutputs(self: *VM, left: Value, right: Value) !Value {
    // GC: `left`/`right` (and their forced list slices) are held across the
    // per-item forces in appendUniqueContextOutput; keep the lists live.
    const gc_roots = vm_force.rootsBegin(self);
    defer vm_force.rootsEnd(self, gc_roots);
    vm_force.rootKeep(self, left);
    vm_force.rootKeep(self, right);
    const left_list = try vm_force.forceValue(self, left);
    const right_list = try vm_force.forceValue(self, right);
    if (!left_list.isList() or !right_list.isList()) return error.TypeError;

    var outputs: std.ArrayListUnmanaged(Value) = .empty;
    defer outputs.deinit(self.allocator);

    // gc: re-fetch — ranges may move across appendUniqueContextOutput's force
    const left_id = left_list.asObjectId();
    const left_n = try self.heap.getListLen(left_id);
    var li: usize = 0;
    while (li < left_n) : (li += 1) try appendUniqueContextOutput(self, &outputs, try self.heap.getListItem(left_id, li));
    const right_id = right_list.asObjectId();
    const right_n = try self.heap.getListLen(right_id);
    var ri: usize = 0;
    while (ri < right_n) : (ri += 1) try appendUniqueContextOutput(self, &outputs, try self.heap.getListItem(right_id, ri));

    // Nix stores output names in a sorted set; sort so context identity
    // comparisons hold regardless of merge order.
    const Ctx = struct {
        intern: @TypeOf(self.intern),
        fn lt(ctx: @This(), a: Value, b: Value) bool {
            return std.mem.order(u8, ctx.intern.get(a.asInternId()), ctx.intern.get(b.asInternId())) == .lt;
        }
    };
    std.mem.sort(Value, outputs.items, Ctx{ .intern = self.intern }, Ctx.lt);
    return Value.list(try self.heap.addList(outputs.items));
}

pub fn appendUniqueContextOutput(self: *VM, outputs: *std.ArrayListUnmanaged(Value), item: Value) !void {
    const value = try vm_force.forceValue(self, item);
    if (!strings.isPlainString(value)) return error.TypeError;
    const text = try strings.stringTextInternId(self, value);
    for (outputs.items) |existing| {
        if (try strings.stringTextInternId(self, existing) == text) return;
    }
    try outputs.append(self.allocator, Value.string(text));
}
