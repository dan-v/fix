//! String and path machinery for the language: coercion to language strings
//! (`__toString` / outPath), `+` and `str_cat` concatenation, and
//! string-context (store-path dependency set) accumulation and merging.
const std = @import("std");
const vm_mod = @import("../vm.zig");
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const InternId = types.InternId;
const ObjectId = types.ObjectId;
const heap_mod = @import("runtime").heap;
const source_paths = @import("derivation").source_path;

const closures = @import("closures.zig");
const force = @import("force.zig");
const trace = @import("trace.zig");
const prof = @import("probe").prof;
const prof_census = @import("probe").prof_census;

const VM = vm_mod.VM;

pub fn concatInternedString(self: *VM, a: InternId, b: InternId) !InternId {
    const t_start = prof.tscMainOnly();
    const s_a = self.intern.get(a);
    const s_b = self.intern.get(b);
    const buf = try self.allocator.alloc(u8, s_a.len + s_b.len);
    defer self.allocator.free(buf);

    @memcpy(buf[0..s_a.len], s_a);
    @memcpy(buf[s_a.len..], s_b);

    const pre_entries = if (prof.enabled) self.intern.entries.count() else 0;
    const id = try self.intern.intern(buf);
    if (prof.enabled and t_start != 0) {
        prof_census.str.concat_calls += 1;
        prof_census.str.concat_cycles += prof.tscMainOnly() - t_start;
        prof_census.str.concat_bytes += buf.len;
        if (self.intern.entries.count() != pre_entries) {
            prof_census.str.concat_new += 1;
            prof_census.str.concat_new_bytes += buf.len;
        }
    }
    return id;
}

pub fn stringLikeValue(self: *VM, value: Value) !Value {
    const forced = try force.forceValue(self, value);
    return switch (forced.kind()) {
        .string, .path, .string_context => forced,
        .attrs => try attrsStringLikeValue(self, forced),
        else => trace.typeErrorExpected(self, "string or path", forced),
    };
}

pub fn stringLikeInternId(self: *VM, value: Value) !InternId {
    return stringTextInternId(self, try stringLikeValue(self, value));
}

pub fn stringTextInternId(self: *VM, value: Value) !InternId {
    return switch (value.kind()) {
        .string, .path => value.asInternId(),
        .string_context => (try self.heap.getContextString(value.asObjectId())).text,
        else => error.TypeError,
    };
}

pub fn stringTextInternIdsEqual(self: *VM, left: Value, right: Value) !bool {
    if (!left.isContextString() and !right.isContextString()) {
        return left.asInternId() == right.asInternId();
    }
    return (try stringTextInternId(self, left)) == (try stringTextInternId(self, right));
}

pub fn isPlainString(value: Value) bool {
    return value.isString() or value.isContextString();
}

pub fn attrsStringLikeValue(self: *VM, attrs: Value) !Value {
    const gc_roots = force.rootsBegin(self);
    defer force.rootsEnd(self, gc_roots);
    force.rootKeep(self, attrs); // held across getAttrValue + callValue + recurse
    const to_string_id = try self.intern.intern("__toString");
    if (self.heap.getAttrValue(attrs.asObjectId(), to_string_id)) |to_string| {
        return stringLikeValue(self, try closures.callValue(self, try force.forceValue(self, to_string), attrs));
    } else |err| switch (err) {
        error.MissingAttribute => {},
        else => return err,
    }

    const out_path_id = try self.intern.intern("outPath");
    const out_path = self.heap.getAttrValue(attrs.asObjectId(), out_path_id) catch |err| switch (err) {
        error.MissingAttribute => return trace.typeErrorExpected(self, "string or path", attrs),
        else => return err,
    };
    return stringLikeValue(self, out_path);
}

pub fn concatPathLike(self: *VM, left: Value, right: Value) !Value {
    const right_like = try stringLikeValue(self, right);
    const raw_text_id = try concatInternedString(self, left.asInternId(), try stringTextInternId(self, right_like));
    const raw_text = self.intern.get(raw_text_id);
    const text_id = if (std.fs.path.isAbsolute(raw_text)) text_id: {
        const normalized = try std.fs.path.resolve(self.allocator, &.{raw_text});
        defer self.allocator.free(normalized);
        break :text_id try self.intern.intern(normalized);
    } else raw_text_id;

    var context: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer context.deinit(self.allocator);
    if (right_like.isContextString()) {
        if (try hasStorePathContext(self, right_like)) return error.InvalidPathConcatenation;
        try appendStringContext(self, &context, right_like);
    }
    if (context.items.len == 0) return Value.path(text_id);
    return Value.contextString(try self.heap.addContextString(text_id, context.items));
}

pub fn concatStringLike(self: *VM, left: Value, right: Value) !Value {
    const gc_roots = force.rootsBegin(self);
    defer force.rootsEnd(self, gc_roots);
    const left_like = try coerceLanguageStringValue(self, left);
    force.rootKeep(self, left_like); // held across the `right` coercion + appendStringContext forces
    const right_like = try coerceLanguageStringValue(self, right);
    force.rootKeep(self, right_like); // held across appendStringContext forces
    const text_id = try concatInternedString(self, try stringTextInternId(self, left_like), try stringTextInternId(self, right_like));

    var context: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer context.deinit(self.allocator);
    try appendStringContext(self, &context, left_like);
    try appendStringContext(self, &context, right_like);
    if (context.items.len == 0) return Value.string(text_id);
    return Value.contextString(try self.heap.addContextString(text_id, context.items));
}

/// `str_cat` opcode body: coerce the top `count` stack operands
/// to language strings IN PLACE (each stays in its slot — a precise GC
/// root — across the later parts' coercions), then assemble the result
/// text in one pass and intern it once. The caller pops the operands
/// after we return. Semantically identical to the left fold
/// `((p1 + p2) + p3) + ...` over `concatStringLike`, minus the
/// intermediate allocations/interns.
pub fn concatStackStrings(self: *VM, count: u32) !Value {
    std.debug.assert(count >= 1 and self.sp >= count);
    const base = self.sp - count;

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        self.stack[base + i] = try coerceLanguageStringValue(self, self.stack[base + i]);
    }
    // Single part: the coerced value is the result — its text is already
    // interned, so re-interning (what `"" + x` pays) would be a no-op probe.
    if (count == 1) return self.stack[base];

    var total: usize = 0;
    var any_context = false;
    i = 0;
    while (i < count) : (i += 1) {
        const v = self.stack[base + i];
        total += self.intern.get(try stringTextInternId(self, v)).len;
        if (v.isContextString()) any_context = true;
    }

    const buf = try self.allocator.alloc(u8, total);
    defer self.allocator.free(buf);
    var off: usize = 0;
    i = 0;
    while (i < count) : (i += 1) {
        const s = self.intern.get(try stringTextInternId(self, self.stack[base + i]));
        @memcpy(buf[off..][0..s.len], s);
        off += s.len;
    }
    const text_id = try self.intern.intern(buf);
    if (!any_context) return Value.string(text_id);

    var context: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer context.deinit(self.allocator);
    i = 0;
    while (i < count) : (i += 1) {
        // GC: appendStringContext can force (context merges); the
        // already-accumulated context values live only in Zig memory,
        // so re-root them across each part's walk. The parts themselves
        // stay rooted in their stack slots.
        const gc_roots = force.rootsBegin(self);
        defer force.rootsEnd(self, gc_roots);
        for (context.items) |e| force.rootKeep(self, e.value);
        try appendStringContext(self, &context, self.stack[base + i]);
    }
    if (context.items.len == 0) return Value.string(text_id);
    return Value.contextString(try self.heap.addContextString(text_id, context.items));
}

pub fn coerceLanguageStringValue(self: *VM, value: Value) !Value {
    const gc_roots = force.rootsBegin(self);
    defer force.rootsEnd(self, gc_roots);
    const forced = try force.forceValue(self, value);
    force.rootKeep(self, forced); // held across getAttrValue + callValue + recurse
    return switch (forced.kind()) {
        .string, .string_context => forced,
        .path => try sourcePathStringValue(self, forced.asInternId()),
        .attrs => blk: {
            const to_string_id = try self.intern.intern("__toString");
            if (self.heap.getAttrValue(forced.asObjectId(), to_string_id)) |to_string| {
                break :blk try coerceLanguageStringValue(self, try closures.callValue(self, try force.forceValue(self, to_string), forced));
            } else |err| switch (err) {
                error.MissingAttribute => {},
                else => return err,
            }

            const out_path_id = try self.intern.intern("outPath");
            const out_path = self.heap.getAttrValue(forced.asObjectId(), out_path_id) catch |err| switch (err) {
                error.MissingAttribute => return trace.typeErrorExpected(self, "string or path", forced),
                else => return err,
            };
            break :blk try coerceLanguageStringValue(self, out_path);
        },
        else => trace.typeErrorExpected(self, "string or path", forced),
    };
}

pub fn sourcePathStringValue(self: *VM, path_id: InternId) !Value {
    const path = self.intern.get(path_id);
    if (!std.fs.path.isAbsolute(path)) {
        const entries = [_]heap_mod.AttrEntry{
            .{ .name = path_id, .value = try pathContextValue(self) },
        };
        return Value.contextString(try self.heap.addContextString(path_id, &entries));
    }
    if (!try self.files.pathExists(path)) return error.FileNotFound;
    const src_span = self.storeCopySpanBegin(std.fs.path.basename(path));
    defer self.storeCopySpanEnd(src_span);
    const store_path = try source_paths.storePathForSource(self.allocator, self.derivations, self.files, path);
    defer self.allocator.free(store_path);
    const store_path_id = try self.intern.intern(store_path);
    const entries = [_]heap_mod.AttrEntry{
        .{ .name = store_path_id, .value = try pathContextValue(self) },
    };
    return Value.contextString(try self.heap.addContextString(store_path_id, &entries));
}

pub fn appendStringContext(self: *VM, context: *std.ArrayListUnmanaged(heap_mod.AttrEntry), value: Value) !void {
    switch (value.kind()) {
        .string => {},
        .path => {
            const path = self.intern.get(value.asInternId());
            if (!try self.files.pathExists(path)) return error.FileNotFound;
            try appendContextEntry(self, context, value.asInternId(), try pathContextValue(self));
        },
        .string_context => {
            const gc_roots = force.rootsBegin(self);
            defer force.rootsEnd(self, gc_roots);
            force.rootKeep(self, value); // owns string.context slice, held across appendContextEntry forces
            const string = try self.heap.getContextString(value.asObjectId());
            for (string.context) |entry| try appendContextEntry(self, context, entry.name, entry.value);
        },
        else => return error.TypeError,
    }
}

pub fn hasStorePathContext(self: *VM, value: Value) !bool {
    if (!value.isContextString()) return false;
    const string = try self.heap.getContextString(value.asObjectId());
    for (string.context) |entry| {
        if (std.mem.startsWith(u8, self.intern.get(entry.name), "/nix/store/")) return true;
    }
    return false;
}

pub fn appendContextEntry(self: *VM, context: *std.ArrayListUnmanaged(heap_mod.AttrEntry), name: InternId, value: Value) !void {
    for (context.items) |*entry| {
        if (entry.name == name) {
            entry.value = try mergeContextValues(self, entry.value, value);
            return;
        }
    }
    try context.append(self.allocator, .{ .name = name, .value = value });
}

pub fn mergeContextValues(self: *VM, left: Value, right: Value) !Value {
    const gc_roots = force.rootsBegin(self);
    defer force.rootsEnd(self, gc_roots);
    const left_forced = try force.forceValue(self, left);
    force.rootKeep(self, left_forced); // held across the `right` force + mergeContextAttrs
    const right_forced = try force.forceValue(self, right);
    if (left_forced.isAttrs() and right_forced.isAttrs()) {
        return Value.attrs(try mergeContextAttrs(self, left_forced.asObjectId(), right_forced.asObjectId()));
    }
    return right;
}

pub fn mergeContextAttrs(self: *VM, left_id: ObjectId, right_id: ObjectId) !ObjectId {
    const gc_roots = force.rootsBegin(self);
    defer force.rootsEnd(self, gc_roots);
    force.rootKeep(self, Value.attrs(left_id)); // owns `left` slice, held across mergeContextAttrValue forces
    force.rootKeep(self, Value.attrs(right_id)); // owns `right` slice
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
    const gc_roots = force.rootsBegin(self);
    defer force.rootsEnd(self, gc_roots);
    const left_list = try force.forceValue(self, left);
    force.rootKeep(self, left_list); // owns getList slice, held across appendUniqueContextOutput forces
    const right_list = try force.forceValue(self, right);
    force.rootKeep(self, right_list); // owns getList slice, held across appendUniqueContextOutput forces
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

    return Value.list(try self.heap.addList(outputs.items));
}

pub fn appendUniqueContextOutput(self: *VM, outputs: *std.ArrayListUnmanaged(Value), item: Value) !void {
    const value = try force.forceValue(self, item);
    if (!isPlainString(value)) return error.TypeError;
    const text = try stringTextInternId(self, value);
    for (outputs.items) |existing| {
        if (existing.asInternId() == text) return;
    }
    try outputs.append(self.allocator, Value.string(text));
}

pub fn pathContextValue(self: *VM) !Value {
    const entries = [_]heap_mod.AttrEntry{
        .{ .name = try self.intern.intern("path"), .value = Value.boolVal(true) },
    };
    return Value.attrs(try self.heap.addAttrs(&entries));
}
