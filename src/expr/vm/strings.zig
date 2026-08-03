//! String and path machinery for the language: coercion to language strings
//! (`__toString` / outPath), `+` and `str_cat` concatenation, and
//! string-context (store-path dependency set) accumulation and merging.
const std = @import("std");
const vm_mod = @import("context.zig");
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const InternId = types.InternId;
const ObjectId = types.ObjectId;
const heap_mod = @import("runtime").heap;
const int_mod = @import("runtime").int;
const source_paths = @import("store").realization.source_path;

const closures = @import("closures.zig");
const force = @import("force.zig");
const context_merge = @import("context_merge.zig");
const trace = @import("trace.zig");
const prof = @import("../probe.zig").prof;
const prof_census = @import("../probe.zig").prof_census;

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
        else => trace.coercionError(self, forced),
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
        error.MissingAttribute => return trace.coercionError(self, attrs),
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
    if (comptime prof.enabled) if (self.workerId() == 0)
        prof_census.recordLongString(self.intern.get(text_id).len, context.items.len != 0);
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
        self.stack[base + i] = try coerceLanguageStringValueOpt(self, self.stack[base + i], true);
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

    if (comptime prof.enabled) if (self.workerId() == 0)
        prof_census.recordLongString(total, any_context);
    const text_id = try internConcatParts(self, slices, total);
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

/// `path_cat` opcode body: concatenate the top `count` stack operands into a
/// single path, canonicalizing ONCE at the end. The first operand supplies the
/// base path text; the rest are coerced string-like and appended raw. Mirrors
/// `concatPathLike` (used by binary `path + x`) but over N parts with a single
/// canonicalization, so separators between adjacent `${…}` interpolations in a
/// path literal survive.
pub fn concatStackPath(self: *VM, count: u32) !Value {
    std.debug.assert(count >= 1 and self.sp >= count);
    const base = self.sp - count;

    // Coerce every part in place (each stays a precise GC root in its slot).
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        self.stack[base + i] = try stringLikeValue(self, self.stack[base + i]);
    }

    // Assemble the raw concatenated text, then canonicalize once.
    var total: usize = 0;
    i = 0;
    while (i < count) : (i += 1) {
        total += self.intern.get(try stringTextInternId(self, self.stack[base + i])).len;
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
    const raw_text_id = try self.intern.intern(buf);
    const raw_text = self.intern.get(raw_text_id);
    const text_id = if (std.fs.path.isAbsolute(raw_text)) text_id: {
        const normalized = try std.fs.path.resolve(self.allocator, &.{raw_text});
        defer self.allocator.free(normalized);
        break :text_id try self.intern.intern(normalized);
    } else raw_text_id;

    // Merge context from any context-string parts; store-path context is
    // illegal inside a path (matches concatPathLike).
    var context: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer context.deinit(self.allocator);
    i = 0;
    while (i < count) : (i += 1) {
        const v = self.stack[base + i];
        if (v.isContextString()) {
            if (try hasStorePathContext(self, v)) return error.InvalidPathConcatenation;
            const gc_roots = force.rootsBegin(self);
            defer force.rootsEnd(self, gc_roots);
            for (context.items) |e| force.rootKeep(self, e.value);
            try appendStringContext(self, &context, v);
        }
    }
    if (context.items.len == 0) return Value.path(text_id);
    return Value.contextString(try self.heap.addContextString(text_id, context.items));
}

pub fn coerceLanguageStringValue(self: *VM, value: Value) !Value {
    return coerceLanguageStringValueOpt(self, value, false);
}

/// String coercion for `+`/`str_cat`. `allow_int` enables the `coerce-integers`
/// experimental feature — but ONLY on the `${…}` interpolation path (Nix does
/// not coerce integers for binary `+` or `substring`).
pub fn coerceLanguageStringValueOpt(self: *VM, value: Value, allow_int: bool) !Value {
    const gc_roots = force.rootsBegin(self);
    defer force.rootsEnd(self, gc_roots);
    const forced = try force.forceValue(self, value);
    force.rootKeep(self, forced); // held across getAttrValue + callValue + recurse
    return switch (forced.kind()) {
        .string, .string_context => forced,
        .path => try sourcePathStringValue(self, forced.asInternId()),
        .int, .boxed_int => if (allow_int and self.policy.coerce_integers_enabled) blk: {
            const s = try std.fmt.allocPrint(self.allocator, "{}", .{int_mod.get(forced, self.heap)});
            defer self.allocator.free(s);
            break :blk Value.string(try self.intern.intern(s));
        } else trace.coercionError(self, forced),
        .attrs => blk: {
            const to_string_id = try self.intern.intern("__toString");
            if (self.heap.getAttrValue(forced.asObjectId(), to_string_id)) |to_string| {
                break :blk try coerceLanguageStringValueOpt(self, try closures.callValue(self, try force.forceValue(self, to_string), forced), allow_int);
            } else |err| switch (err) {
                error.MissingAttribute => {},
                else => return err,
            }

            const out_path_id = try self.intern.intern("outPath");
            const out_path = self.heap.getAttrValue(forced.asObjectId(), out_path_id) catch |err| switch (err) {
                error.MissingAttribute => return trace.coercionError(self, forced),
                else => return err,
            };
            break :blk try coerceLanguageStringValueOpt(self, out_path, allow_int);
        },
        else => trace.coercionError(self, forced),
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
    const store_path = try source_paths.storePathForSource(self.allocator, self.realization, self.files, path);
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
            try context_merge.appendContextEntry(self, context, value.asInternId(), try pathContextValue(self));
        },
        .string_context => {
            const gc_roots = force.rootsBegin(self);
            defer force.rootsEnd(self, gc_roots);
            force.rootKeep(self, value); // owns string.context slice, held across appendContextEntry forces
            const string = try self.heap.getContextString(value.asObjectId());
            for (string.context) |entry| try context_merge.appendContextEntry(self, context, entry.name, entry.value);
        },
        else => return error.TypeError,
    }
}

pub fn hasStorePathContext(self: *VM, value: Value) !bool {
    if (!value.isContextString()) return false;
    const store_dir = self.realization.store_dir;
    const string = try self.heap.getContextString(value.asObjectId());
    for (string.context) |entry| {
        const name = self.intern.get(entry.name);
        if (std.mem.startsWith(u8, name, store_dir) and name.len > store_dir.len and name[store_dir.len] == '/') return true;
    }
    return false;
}

pub fn pathContextValue(self: *VM) !Value {
    const entries = [_]heap_mod.AttrEntry{
        .{ .name = try self.intern.intern("path"), .value = Value.boolVal(true) },
    };
    return Value.attrs(try self.heap.addAttrs(&entries));
}
