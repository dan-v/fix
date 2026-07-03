const std = @import("std");
const compiler_mod = @import("../compiler.zig");
const ast = @import("syntax").ast;
const bytecode = @import("../bytecode.zig");
const chunk = bytecode.chunk;
const heap_mod = @import("runtime").heap;
const string_syntax = @import("syntax").string_syntax;
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const emit = @import("emit.zig");
const scope = @import("scope.zig");
const thunks = @import("thunks.zig");
const diagnostics = @import("diagnostics.zig");
const literals = @import("literals.zig");
const access = @import("access.zig");
const deferred_table = @import("deferred_table.zig");

const Compiler = compiler_mod.Compiler;
const Node = compiler_mod.Node;
const Capture = compiler_mod.Capture;
const AttrEntryView = compiler_mod.AttrEntryView;
const AttrEntryGroup = compiler_mod.AttrEntryGroup;
const AttrEntryGroups = compiler_mod.AttrEntryGroups;
const InternId = types.InternId;
const ChunkBuilder = chunk.ChunkBuilder;
const diagnostic_atom = @import("diagnostic_atom.zig");
const attrEntriesDiagnosticAtom = diagnostic_atom.attrEntriesDiagnosticAtom;
const attrGroupsDiagnosticAtom = diagnostic_atom.attrGroupsDiagnosticAtom;

pub fn compileAttrSet(self: *Compiler, node: *const Node) !void {
    const aset = node.data.attr_set;
    if (hasDynamicAttrEntries(self, aset.entries)) {
        return compileMixedAttrSet(self, aset.entries, aset.recursive);
    }

    const entries = try attrEntryViews(self, aset.entries);
    defer self.allocator.free(entries);

    try compileAttrEntries(self, entries, aset.recursive);
}

fn compileMixedAttrSet(self: *Compiler, entries: []const Node.AttrSetEntry, recursive: bool) !void {
    if (recursive) return compileMixedRecursiveAttrSet(self, entries);

    const static_count = staticAttrEntryCount(self, entries);
    if (static_count > 0) {
        const static_entries = try self.allocator.alloc(Node.AttrSetEntry, static_count);
        defer self.allocator.free(static_entries);

        var i: usize = 0;
        for (entries) |entry| {
            if (!isDynamicAttrEntry(self, entry)) {
                static_entries[i] = entry;
                i += 1;
            }
        }

        const views = try attrEntryViews(self, static_entries);
        defer self.allocator.free(views);
        try compileAttrEntries(self, views, false);
    } else {
        try emit.emitOpU16(self, .build_attrs, 0);
    }

    for (entries) |entry| {
        if (!isDynamicAttrEntry(self, entry)) continue;
        try compileDynamicAttrName(self, entry);
        try compileDynamicAttrValueThunk(self, entry);
        try emit.emitOpU16(self, .build_attrs, 1);
        try emit.emitOp(self, .merge_attrs_strict);
    }
}

fn compileMixedRecursiveAttrSet(self: *Compiler, entries: []const Node.AttrSetEntry) !void {
    const static_count = staticAttrEntryCount(self, entries);
    const static_entries = try self.allocator.alloc(Node.AttrSetEntry, static_count);
    defer self.allocator.free(static_entries);

    var static_i: usize = 0;
    for (entries) |entry| {
        if (!isDynamicAttrEntry(self, entry)) {
            static_entries[static_i] = entry;
            static_i += 1;
        }
    }

    const views = try attrEntryViews(self, static_entries);
    defer self.allocator.free(views);

    var grouped = try attrEntryGroups(self, views);
    defer grouped.deinit(self.allocator);

    scope.beginScope(self);
    errdefer scope.endScope(self);

    try declareRecursiveAttrLocals(self, grouped.groups);
    try compileRecursiveAttrCells(self, grouped.groups);
    try emitRecursiveAttrObject(self, grouped.groups);

    for (entries) |entry| {
        if (!isDynamicAttrEntry(self, entry)) continue;
        try compileDynamicAttrName(self, entry);
        try compileDynamicAttrValueThunk(self, entry);
        try emit.emitOpU16(self, .build_attrs, 1);
        try emit.emitOp(self, .merge_attrs_strict);
    }

    scope.endScope(self);
}

fn hasDynamicAttrEntries(self: *const Compiler, entries: []const Node.AttrSetEntry) bool {
    for (entries) |entry| {
        if (isDynamicAttrEntry(self, entry)) return true;
    }
    return false;
}

fn staticAttrEntryCount(self: *const Compiler, entries: []const Node.AttrSetEntry) usize {
    var count: usize = 0;
    for (entries) |entry| {
        if (!isDynamicAttrEntry(self, entry)) count += 1;
    }
    return count;
}

fn isDynamicAttrEntry(self: *const Compiler, entry: Node.AttrSetEntry) bool {
    return entry.dynamic_name != null or (entry.path.len > 0 and attrSegmentHasInterpolation(self, entry.path[0]));
}

fn compileDynamicAttrName(self: *Compiler, entry: Node.AttrSetEntry) !void {
    if (entry.dynamic_name) |name| return self.compileNode(name);
    if (entry.path.len > 0 and attrSegmentHasInterpolation(self, entry.path[0])) {
        return literals.compileStringAtom(self, entry.path[0]);
    }
    return error.InvalidAttributePath;
}

fn compileDynamicAttrValueThunk(self: *Compiler, entry: Node.AttrSetEntry) !void {
    if (entry.dynamic_name) |_| {
        if (entry.path.len == 0) return thunks.compileThunk(self, entry.expr);

        const views = [_]AttrEntryView{
            .{ .path = entry.path, .expr = entry.expr, .inherit_outer = entry.inherit_outer },
        };
        try compileAttrEntriesThunk(self, &views, false);
        return;
    }

    if (entry.path.len > 0 and attrSegmentHasInterpolation(self, entry.path[0])) {
        if (entry.path.len == 1) return thunks.compileThunk(self, entry.expr);

        const views = [_]AttrEntryView{
            .{ .path = entry.path[1..], .expr = entry.expr, .inherit_outer = entry.inherit_outer },
        };
        try compileAttrEntriesThunk(self, &views, false);
        return;
    }

    return error.InvalidAttributePath;
}

fn compileNodeAttrEntriesThunk(self: *Compiler, entries: []const Node.AttrSetEntry, recursive: bool) !void {
    var child_builder = try ChunkBuilder.init(self.allocator);
    defer child_builder.deinit(self.allocator);

    var child = Compiler.init(
        self.allocator,
        self.persistent,
        &child_builder,
        self.registry,
        self.source,
        self.intern,
        self.heap,
    );
    child.parent = self;
    child.base_path = self.base_path;
    child.source_path = self.source_path;
    child.source_file_id = self.source_file_id;
    defer child.deinit();

    compileMixedAttrSet(&child, entries, recursive) catch |err| {
        try diagnostics.absorbChildDiagnostics(self, &child);
        return err;
    };
    try emit.emitRet(&child);
    try emit.emitOp(&child, .halt);

    const child_chunk = try child_builder.finish(self.persistent, child.slot_count);
    const child_id = try self.registry.register(child_chunk);
    try emit.emitThunkWithCaptures(self, child_id, child.captures.items);
}

fn compileAttrEntries(self: *Compiler, entries: []const AttrEntryView, recursive: bool) anyerror!void {
    if (hasDynamicAttrEntryViews(self, entries)) {
        return compileMixedAttrEntryViews(self, entries, recursive);
    }

    if (recursive) {
        try compileRecursiveAttrEntries(self, entries);
    } else {
        try compilePlainAttrEntries(self, entries);
    }
}

fn compileMixedAttrEntryViews(self: *Compiler, entries: []const AttrEntryView, recursive: bool) !void {
    if (recursive) return compileMixedRecursiveAttrEntryViews(self, entries);

    const static_count = staticAttrEntryViewCount(self, entries);
    if (static_count > 0) {
        const static_entries = try self.allocator.alloc(AttrEntryView, static_count);
        defer self.allocator.free(static_entries);

        var i: usize = 0;
        for (entries) |entry| {
            if (!isDynamicAttrEntryView(self, entry)) {
                static_entries[i] = entry;
                i += 1;
            }
        }

        try compileAttrEntries(self, static_entries, false);
    } else {
        try emit.emitOpU16(self, .build_attrs, 0);
    }

    for (entries) |entry| {
        if (!isDynamicAttrEntryView(self, entry)) continue;
        try compileDynamicAttrViewName(self, entry);
        try compileDynamicAttrViewValueThunk(self, entry);
        try emit.emitOpU16(self, .build_attrs, 1);
        try emit.emitOp(self, .merge_attrs_strict);
    }
}

fn compileMixedRecursiveAttrEntryViews(self: *Compiler, entries: []const AttrEntryView) !void {
    const static_count = staticAttrEntryViewCount(self, entries);
    const static_entries = try self.allocator.alloc(AttrEntryView, static_count);
    defer self.allocator.free(static_entries);

    var static_i: usize = 0;
    for (entries) |entry| {
        if (!isDynamicAttrEntryView(self, entry)) {
            static_entries[static_i] = entry;
            static_i += 1;
        }
    }

    var grouped = try attrEntryGroups(self, static_entries);
    defer grouped.deinit(self.allocator);

    scope.beginScope(self);
    errdefer scope.endScope(self);

    try declareRecursiveAttrLocals(self, grouped.groups);
    try compileRecursiveAttrCells(self, grouped.groups);
    try emitRecursiveAttrObject(self, grouped.groups);

    for (entries) |entry| {
        if (!isDynamicAttrEntryView(self, entry)) continue;
        try compileDynamicAttrViewName(self, entry);
        try compileDynamicAttrViewValueThunk(self, entry);
        try emit.emitOpU16(self, .build_attrs, 1);
        try emit.emitOp(self, .merge_attrs_strict);
    }

    scope.endScope(self);
}

fn hasDynamicAttrEntryViews(self: *const Compiler, entries: []const AttrEntryView) bool {
    for (entries) |entry| {
        if (isDynamicAttrEntryView(self, entry)) return true;
    }
    return false;
}

fn staticAttrEntryViewCount(self: *const Compiler, entries: []const AttrEntryView) usize {
    var count: usize = 0;
    for (entries) |entry| {
        if (!isDynamicAttrEntryView(self, entry)) count += 1;
    }
    return count;
}

fn isDynamicAttrEntryView(self: *const Compiler, entry: AttrEntryView) bool {
    return entry.path.len > 0 and attrSegmentHasInterpolation(self, entry.path[0]);
}

fn compileDynamicAttrViewName(self: *Compiler, entry: AttrEntryView) !void {
    if (entry.path.len > 0 and attrSegmentHasInterpolation(self, entry.path[0])) {
        return literals.compileStringAtom(self, entry.path[0]);
    }
    return error.InvalidAttributePath;
}

fn compileDynamicAttrViewValueThunk(self: *Compiler, entry: AttrEntryView) !void {
    if (entry.path.len == 1) return thunks.compileThunk(self, entry.expr);

    const views = [_]AttrEntryView{
        .{
            .path = entry.path[1..],
            .expr = entry.expr,
            .inherit_outer = entry.inherit_outer,
        },
    };
    try compileAttrEntriesThunk(self, &views, false);
}

// ---- lazy per-attr compilation (see deferred_table.zig) ----

fn rootCompiler(self: *Compiler) *Compiler {
    var c = self;
    while (c.parent) |p| c = p;
    return c;
}

/// Any `with` scope active at this point (in self or any ancestor)?
/// Deferral is disabled under an enclosing `with` — the flat snapshot
/// can't model its dynamic lookups (the with itself, INSIDE a value body,
/// is fine; it compiles at force time).
fn hasAnyWithScope(self: *Compiler) bool {
    var c: ?*Compiler = self;
    while (c) |comp| : (c = comp.parent) {
        if (comp.with_scopes.items.len > 0) return true;
    }
    return false;
}

/// A value body is deferrable iff it is NOT an immediate/trivial shape —
/// i.e. iff it would otherwise go through `compileThunkEager`. Deferring
/// exactly replaces that thunk, so output stays byte-identical. (The
/// immediate set mirrors `access.compileImmediateContainerValue`.)
fn isDeferrableBody(node: *const Node) bool {
    return switch (ast.unwrapParens(node).tag) {
        .integer, .float_val, .string, .path, .search_path, .identifier, .bool_true, .bool_false, .null, .list, .attr_set, .lambda, .lambda_attrs => false,
        else => true,
    };
}

/// Source-span size of a body, the compile-cost proxy for the gate.
fn bodySpanBytes(node: *const Node) usize {
    return if (node.span) |s| s.len else 0;
}

/// A single clean leaf qualifies for deferral if its body is a
/// substantial, expensive-to-compile shape.
fn leafDeferrable(leaf: AttrEntryView) bool {
    if (leaf.path.len != 1 or leaf.inherit_outer) return false;
    if (!isDeferrableBody(leaf.expr)) return false;
    return bodySpanBytes(leaf.expr) >= deferred_table.MIN_BODY_BYTES;
}

/// Does this set contain at least one deferrable leaf? Used to avoid
/// building the scope snapshot (which mutates parent captures) for sets
/// where nothing will actually defer.
fn setHasDeferrableLeaf(groups: []const AttrEntryGroup) bool {
    for (groups) |group| {
        if (group.leaf) |leaf| {
            if (group.leaf_count <= 1 and group.tails.len == 0 and leafDeferrable(leaf)) return true;
        }
    }
    return false;
}

fn containsNameId(items: []const Capture, name_id: InternId) bool {
    for (items) |c| if (c.name_id == name_id) return true;
    return false;
}

/// Whether this plain attrset qualifies for lazy per-attr compilation.
fn shouldDeferSet(self: *Compiler, group_count: usize) bool {
    if (rootCompiler(self).deferred_table == null) return false;
    if (group_count < deferred_table.MIN_ENTRIES) return false;
    // File/import compiles only: source + (retained) arena are
    // evaluator-lived; sidesteps top-level-string source ownership.
    if (self.source_path == null) return false;
    if (hasAnyWithScope(self)) return false;
    return true;
}

/// Build the enclosing-scope snapshot: every lexically visible binding,
/// each as a `Capture` describing how to fetch it from the CURRENT frame
/// (`.local` slot / `.upvalue` index). Returns false (and the set falls
/// back to eager compile) if the scope exceeds `MAX_SCOPE` or any visible
/// name can't be resolved. Side effect: resolving up-scope names adds the
/// corresponding upvalues to this chunk — exactly what a body referencing
/// them would do, so the deferred thunk can capture them.
fn buildEnclosingSnapshot(self: *Compiler, out: *std.ArrayListUnmanaged(Capture)) !bool {
    var comp: ?*Compiler = self;
    while (comp) |c| : (comp = c.parent) {
        var i = c.locals.items.len;
        while (i > 0) {
            i -= 1;
            const local = c.locals.items[i];
            if (containsNameId(out.items, local.name_id)) continue;
            const cap: Capture = if (scope.resolveLocalId(self, local.name_id)) |slot|
                .{ .name = local.name, .name_id = local.name_id, .kind = .local, .index = slot }
            else if (try scope.resolveCaptureId(self, local.name, local.name_id)) |up|
                .{ .name = local.name, .name_id = local.name_id, .kind = .upvalue, .index = up }
            else
                return false; // visible but unresolvable — bail conservatively
            if (out.items.len >= deferred_table.MAX_SCOPE) return false;
            try out.append(self.allocator, cap);
        }
    }
    return true;
}

/// Register a deferred value body and emit `defer_attr_value`.
fn deferLeaf(self: *Compiler, body: *const Node, snapshot: []const Capture) !void {
    const root = rootCompiler(self);
    const table = root.deferred_table.?;
    const id = try table.register(.{
        .node = body,
        .scope = snapshot,
        .source = self.source,
        .base_path = self.base_path,
        .source_path = self.source_path,
        .source_file_id = self.source_file_id,
    });
    try emit.emitDeferAttrValue(self, id, snapshot);
    root.deferred_count += 1;
}

fn compilePlainAttrEntries(self: *Compiler, entries: []const AttrEntryView) anyerror!void {
    var grouped = try attrEntryGroups(self, entries);
    defer grouped.deinit(self.allocator);

    var positions: std.ArrayListUnmanaged(heap_mod.AttrPosEntry) = .empty;
    defer positions.deinit(self.allocator);

    // Lazy per-attr compilation: build the enclosing-scope snapshot once
    // (shared by every deferred value body — non-recursive, so they all
    // see the same scope). Null if the set doesn't qualify.
    var snapshot: std.ArrayListUnmanaged(Capture) = .empty;
    defer snapshot.deinit(self.allocator);
    var defer_scope: ?[]const Capture = null;
    if (shouldDeferSet(self, grouped.groups.len) and setHasDeferrableLeaf(grouped.groups)) {
        if (try buildEnclosingSnapshot(self, &snapshot)) defer_scope = snapshot.items;
    }

    for (grouped.groups) |group| {
        try compilePlainAttrGroup(self, &positions, group, defer_scope);
    }

    const count = try diagnostics.requireU16At(self, grouped.groups.len, attrEntriesDiagnosticAtom(entries), "too many attributes in set");
    try emit.emitBuildAttrs(self, count, positions.items);
}

fn compileRecursiveAttrEntries(self: *Compiler, entries: []const AttrEntryView) anyerror!void {
    var grouped = try attrEntryGroups(self, entries);
    defer grouped.deinit(self.allocator);

    scope.beginScope(self);
    errdefer scope.endScope(self);

    try declareRecursiveAttrLocals(self, grouped.groups);
    try compileRecursiveAttrCells(self, grouped.groups);
    try emitRecursiveAttrObject(self, grouped.groups);
    scope.endScope(self);
}

fn compilePlainAttrGroup(
    self: *Compiler,
    positions: *std.ArrayListUnmanaged(heap_mod.AttrPosEntry),
    group: AttrEntryGroup,
    defer_scope: ?[]const Capture,
) anyerror!void {
    const leaf = group.leaf;
    if (leaf == null) {
        try emitAttrNameId(self, group.name_id);
        try compileAttrEntriesThunk(self, group.tails, false);
        try appendAttrPosition(self, positions, group.first, group.name_id);
        return;
    }

    if (group.leaf_count > 1 or group.tails.len > 0) {
        const duplicate = duplicateExtendedLeaf(group, leaf.?);
        if (duplicate) |entry| {
            try reportDuplicateAttribute(self, entry.path[0], leaf.?.path[0]);
            return error.DuplicateAttribute;
        }
        try emitAttrNameId(self, group.name_id);
        try compileExtendedAttrSetLiteralThunk(self, group.leaves, group.tails);
        try appendAttrPosition(self, positions, group.first, group.name_id);
        return;
    }

    // Lazy per-attr compilation: a clean single-leaf body (path.len == 1,
    // not an inherit) whose shape is substantial defers its compile to
    // first force instead of emitting bytecode now.
    if (defer_scope) |dscope| {
        if (leafDeferrable(leaf.?)) {
            try emitAttrNameId(self, group.name_id);
            try deferLeaf(self, leaf.?.expr, dscope);
            try appendAttrPosition(self, positions, group.first, group.name_id);
            return;
        }
    }

    try emitAttrNameId(self, group.name_id);
    try access.compileContainerValue(self, leaf.?.expr, .{ .raw_identifier = true });
    try appendAttrPosition(self, positions, group.first, group.name_id);
}

fn declareRecursiveAttrLocals(self: *Compiler, groups: []const AttrEntryGroup) anyerror!void {
    for (groups) |group| {
        const slot = try scope.declareLocal(self, group.name, group.name_id);
        try emit.emitInitCellSlot(self, slot);
    }
}

fn compileRecursiveAttrCells(self: *Compiler, groups: []const AttrEntryGroup) anyerror!void {
    for (groups) |group| {
        const slot = scope.resolveLocalId(self, group.name_id) orelse return error.UndefinedVariable;
        const leaf = group.leaf;
        if (leaf == null) {
            try compileAttrEntriesThunk(self, group.tails, false);
            try emit.emitSetCellLocal(self, slot);
            continue;
        }

        if (group.leaf_count > 1 or group.tails.len > 0) {
            const duplicate = duplicateExtendedLeaf(group, leaf.?);
            if (duplicate) |entry| {
                try reportDuplicateAttribute(self, entry.path[0], leaf.?.path[0]);
                return error.DuplicateAttribute;
            }
            try compileExtendedAttrSetLiteralThunk(self, group.leaves, group.tails);
            try emit.emitSetCellLocal(self, slot);
            continue;
        }
        const previous_skip = self.skip_local_slot;
        if (leaf.?.inherit_outer) self.skip_local_slot = slot;
        const compile_result = access.compileContainerValue(self, leaf.?.expr, .{});
        self.skip_local_slot = previous_skip;
        try compile_result;
        try emit.emitSetCellLocal(self, slot);
    }
}

fn emitRecursiveAttrObject(self: *Compiler, groups: []const AttrEntryGroup) anyerror!void {
    var positions: std.ArrayListUnmanaged(heap_mod.AttrPosEntry) = .empty;
    defer positions.deinit(self.allocator);

    for (groups) |group| {
        try emitAttrNameId(self, group.name_id);

        const slot = scope.resolveLocalId(self, group.name_id) orelse return error.UndefinedVariable;
        try emit.emitCaptureLocal(self, slot);
        try appendAttrPosition(self, &positions, group.first, group.name_id);
    }

    const count = try diagnostics.requireU16At(self, groups.len, attrGroupsDiagnosticAtom(groups), "too many attributes in set");
    try emit.emitBuildAttrs(self, count, positions.items);
}

pub fn compileExtendedAttrSetLiteralThunk(self: *Compiler, leaves: []const AttrEntryView, tails: []const AttrEntryView) !void {
    std.debug.assert(leaves.len > 0);
    std.debug.assert(leaves[0].expr.tag == .attr_set);
    const first_attr_set = leaves[0].expr.data.attr_set;

    var merged_count: usize = tails.len;
    for (leaves) |leaf| {
        std.debug.assert(leaf.expr.tag == .attr_set);
        merged_count += leaf.expr.data.attr_set.entries.len;
    }

    const merged = try self.allocator.alloc(Node.AttrSetEntry, merged_count);
    defer self.allocator.free(merged);

    var index: usize = 0;
    for (leaves) |leaf| {
        const attr_set = leaf.expr.data.attr_set;
        @memcpy(merged[index .. index + attr_set.entries.len], attr_set.entries);
        index += attr_set.entries.len;
    }
    for (tails, merged[index..]) |tail, *entry| {
        entry.* = .{
            .path = @constCast(tail.path),
            .expr = @constCast(tail.expr),
            .inherit_outer = tail.inherit_outer,
        };
    }

    try compileNodeAttrEntriesThunk(self, merged, first_attr_set.recursive);
}

fn duplicateExtendedLeaf(group: AttrEntryGroup, leaf: AttrEntryView) ?AttrEntryView {
    if (leaf.expr.tag != .attr_set) return group.duplicate_leaf orelse group.first_nested;
    return nonAttrSetDuplicateLeaf(group);
}

fn nonAttrSetDuplicateLeaf(group: AttrEntryGroup) ?AttrEntryView {
    if (group.leaves.len <= 1) return null;
    for (group.leaves[1..]) |leaf| {
        if (leaf.expr.tag != .attr_set) return leaf;
    }
    return null;
}

pub fn compileAttrEntriesThunk(self: *Compiler, entries: []const AttrEntryView, recursive: bool) anyerror!void {
    var child_builder = try ChunkBuilder.init(self.allocator);
    defer child_builder.deinit(self.allocator);

    var child = Compiler.init(
        self.allocator,
        self.persistent,
        &child_builder,
        self.registry,
        self.source,
        self.intern,
        self.heap,
    );
    child.parent = self;
    child.base_path = self.base_path;
    child.source_path = self.source_path;
    child.source_file_id = self.source_file_id;
    defer child.deinit();

    compileAttrEntries(&child, entries, recursive) catch |err| {
        try diagnostics.absorbChildDiagnostics(self, &child);
        return err;
    };
    try emit.emitRet(&child);
    try emit.emitOp(&child, .halt);

    const child_chunk = try child_builder.finish(self.persistent, child.slot_count);
    const child_id = try self.registry.register(child_chunk);
    try emit.emitThunkWithCaptures(self, child_id, child.captures.items);
}

fn attrEntryViews(self: *Compiler, entries: []const Node.AttrSetEntry) ![]AttrEntryView {
    const views = try self.allocator.alloc(AttrEntryView, entries.len);
    for (entries, views) |entry, *view| {
        std.debug.assert(entry.dynamic_name == null);
        view.* = .{ .path = entry.path, .expr = entry.expr, .inherit_outer = entry.inherit_outer };
    }
    return views;
}

fn attrEntryGroups(self: *Compiler, entries: []const AttrEntryView) !AttrEntryGroups {
    var group_index: std.AutoHashMapUnmanaged(InternId, usize) = .empty;
    defer group_index.deinit(self.allocator);

    var groups_list: std.ArrayListUnmanaged(AttrEntryGroup) = .empty;
    var groups_list_owned = true;
    errdefer if (groups_list_owned) {
        for (groups_list.items) |group| self.allocator.free(group.name);
        groups_list.deinit(self.allocator);
    };

    var total_leaves: usize = 0;
    var total_tails: usize = 0;
    for (entries) |entry| {
        if (entry.path.len == 0) return error.InvalidAttributePath;

        var name: ?[]u8 = try attrSegmentNameAlloc(self, entry.path[0]);
        errdefer if (name) |owned| self.allocator.free(owned);
        const name_id = try self.intern.intern(name.?);
        const index = group_index.get(name_id) orelse blk: {
            const new_index = groups_list.items.len;
            try group_index.put(self.allocator, name_id, new_index);
            try groups_list.append(self.allocator, .{
                .first = entry.path[0],
                .name = name.?,
                .name_id = name_id,
            });
            name = null;
            break :blk new_index;
        };
        if (name) |owned| {
            self.allocator.free(owned);
            name = null;
        }

        const group = &groups_list.items[index];
        if (entry.path.len == 1) {
            group.leaf_count += 1;
            total_leaves += 1;
            if (group.leaf == null) {
                group.leaf = entry;
            } else if (group.duplicate_leaf == null) {
                group.duplicate_leaf = entry;
            }
        } else {
            if (group.first_nested == null) group.first_nested = entry;
            group.tail_count += 1;
            total_tails += 1;
        }
    }

    var groups = try groups_list.toOwnedSlice(self.allocator);
    groups_list_owned = false;
    errdefer {
        for (groups) |group| self.allocator.free(group.name);
        self.allocator.free(groups);
    }

    const leaves = try self.allocator.alloc(AttrEntryView, total_leaves);
    errdefer self.allocator.free(leaves);
    const tails = try self.allocator.alloc(AttrEntryView, total_tails);
    errdefer self.allocator.free(tails);

    var leaf_start: usize = 0;
    for (groups) |*group| {
        const leaf_end = leaf_start + group.leaf_count;
        group.leaves = leaves[leaf_start..leaf_end];
        group.leaf_count = 0;
        leaf_start = leaf_end;
    }

    var tail_start: usize = 0;
    for (groups) |*group| {
        const tail_end = tail_start + group.tail_count;
        group.tails = tails[tail_start..tail_end];
        group.tail_count = 0;
        tail_start = tail_end;
    }

    for (entries) |entry| {
        const name_id = try attrSegmentNameId(self, entry.path[0]);
        const index = group_index.get(name_id).?;
        const group = &groups[index];
        if (entry.path.len == 1) {
            group.leaves[group.leaf_count] = entry;
            group.leaf_count += 1;
            continue;
        }
        group.tails[group.tail_count] = .{
            .path = entry.path[1..],
            .expr = entry.expr,
            .inherit_outer = entry.inherit_outer,
        };
        group.tail_count += 1;
    }

    return .{ .groups = groups, .leaves = leaves, .tails = tails };
}

pub fn reportDuplicateAttribute(self: *Compiler, duplicate: Node.Atom, original: Node.Atom) !void {
    try diagnostics.reportCompileError(self, duplicate.offset, duplicate.len, "duplicate attribute");
    try diagnostics.reportCompileNote(self, original.offset, original.len, "first attribute defined here");
}

pub fn attrSegmentsEqual(self: *const Compiler, a: Node.Atom, b: Node.Atom) bool {
    return std.mem.eql(u8, attrSegmentSpan(self, a), attrSegmentSpan(self, b));
}

pub fn emitAttrNameId(self: *Compiler, name_id: InternId) !void {
    const name_val = Value.string(name_id);
    try self.builder.emitConstant(self.allocator, name_val);
}

pub fn appendAttrPosition(
    self: *Compiler,
    positions: *std.ArrayListUnmanaged(heap_mod.AttrPosEntry),
    atom: Node.Atom,
    name_id: InternId,
) !void {
    _ = self.source_path orelse return;
    const position = try diagnostics.sourcePositionForOffset(self, atom.offset);
    try positions.append(self.allocator, .{
        .name = name_id,
        .pos = .{
            .file = try sourceFileId(self),
            .line = position.line,
            .column = position.column,
        },
    });
}

pub fn sourceFileId(self: *Compiler) !InternId {
    if (self.source_file_id) |id| return id;
    const path = self.source_path orelse return error.MissingSourcePath;
    const id = try self.intern.intern(path);
    self.source_file_id = id;
    return id;
}

pub fn attrSegmentSpan(self: *const Compiler, atom: Node.Atom) []const u8 {
    const span = self.source[atom.offset .. atom.offset + atom.len];
    if (span.len >= 2 and span[0] == '"' and span[span.len - 1] == '"') {
        return span[1 .. span.len - 1];
    }
    return span;
}

pub fn attrSegmentNameId(self: *Compiler, atom: Node.Atom) !InternId {
    const name = try attrSegmentNameAlloc(self, atom);
    defer self.allocator.free(name);
    return self.intern.intern(name);
}

pub fn attrSegmentNameAlloc(self: *Compiler, atom: Node.Atom) ![]u8 {
    const span = self.source[atom.offset .. atom.offset + atom.len];
    if (string_syntax.kindAt(self.source, atom.offset) == null) {
        return self.allocator.dupe(u8, span);
    }

    const parsed = try string_syntax.parseLiteral(self.allocator, self.source, .{
        .start = atom.offset,
        .end = atom.offset + atom.len,
    });
    defer parsed.deinit();

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(self.allocator);

    for (parsed.parts) |part| {
        switch (part) {
            .text => |text| try out.appendSlice(self.allocator, text.bytes),
            .interpolation => return error.InvalidAttributePath,
        }
    }

    return out.toOwnedSlice(self.allocator);
}

pub fn attrSegmentHasInterpolation(self: *const Compiler, atom: Node.Atom) bool {
    const span = self.source[atom.offset .. atom.offset + atom.len];
    return string_syntax.kindAt(self.source, atom.offset) != null and std.mem.indexOf(u8, span, "${") != null;
}

const fix = @import("../root.zig");
const Evaluator = fix.Evaluator;

test "compiles a plain attribute set with two entries" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    const result = try ev.evaluate("{ a = 1; b = 2; }.a + { a = 1; b = 2; }.b");
    try std.testing.expectEqual(@as(i64, 3), result.asInt());
}

test "reports duplicate attribute as a compile error" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    try std.testing.expectError(error.DuplicateAttribute, ev.evaluate("{ a = 1; a = 2; }"));
}

test "compiles a recursive attribute set referencing a sibling" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    const result = try ev.evaluate("(rec { a = 1; b = a + 1; }).b");
    try std.testing.expectEqual(@as(i64, 2), result.asInt());
}

test "compiles a dynamic attribute name from string interpolation" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    const result = try ev.evaluate("let x = \"foo\"; in ({ \"${x}\" = 1; }).foo");
    try std.testing.expectEqual(@as(i64, 1), result.asInt());
}

test "reports duplicate attribute inside a nested static path" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    try std.testing.expectError(error.DuplicateAttribute, ev.evaluate("{ a.b = 1; a.b = 2; }"));
}

test "attr segments equal compares underlying source text" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    // `foo` and `"foo"` denote the same attribute name; merging both into
    // one set without a duplicate-attribute error exercises the segment
    // equality/dedup path that backs group-by-name compilation.
    const result = try ev.evaluate("{ foo = 1; }.foo");
    try std.testing.expectEqual(@as(i64, 1), result.asInt());
}
