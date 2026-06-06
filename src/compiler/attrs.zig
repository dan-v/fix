const std = @import("std");
const compiler_mod = @import("../compiler.zig");
const ast = @import("../ast.zig");
const bytecode = @import("../bytecode.zig");
const builtins = @import("../builtins.zig");
const chunk = bytecode.chunk;
const diagnostic = @import("../diagnostic.zig");
const heap_mod = @import("../heap.zig");
const string_syntax = @import("../string_syntax.zig");
const types = @import("../types.zig");
const Value = @import("../value.zig").Value;
const OpCode = bytecode.OpCode;
const emit = @import("emit.zig");
const scope = @import("scope.zig");
const thunks = @import("thunks.zig");
const diagnostics = @import("diagnostics.zig");
const literals = @import("literals.zig");
const access = @import("access.zig");

const Compiler = compiler_mod.Compiler;
const Node = compiler_mod.Node;
const NodeTag = compiler_mod.NodeTag;
const BinaryOp = compiler_mod.BinaryOp;
const Capture = compiler_mod.Capture;
const AttrEntryView = compiler_mod.AttrEntryView;
const AttrEntryGroup = compiler_mod.AttrEntryGroup;
const AttrEntryGroups = compiler_mod.AttrEntryGroups;
const ContainerValueOptions = compiler_mod.ContainerValueOptions;
const WithScope = compiler_mod.WithScope;
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

pub fn compileMixedAttrSet(self: *Compiler, entries: []const Node.AttrSetEntry, recursive: bool) !void {
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

pub fn compileMixedRecursiveAttrSet(self: *Compiler, entries: []const Node.AttrSetEntry) !void {
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

pub fn hasDynamicAttrEntries(self: *const Compiler, entries: []const Node.AttrSetEntry) bool {
    for (entries) |entry| {
        if (isDynamicAttrEntry(self, entry)) return true;
    }
    return false;
}

pub fn staticAttrEntryCount(self: *const Compiler, entries: []const Node.AttrSetEntry) usize {
    var count: usize = 0;
    for (entries) |entry| {
        if (!isDynamicAttrEntry(self, entry)) count += 1;
    }
    return count;
}

pub fn isDynamicAttrEntry(self: *const Compiler, entry: Node.AttrSetEntry) bool {
    return entry.dynamic_name != null or (entry.path.len > 0 and attrSegmentHasInterpolation(self, entry.path[0]));
}

pub fn compileDynamicAttrName(self: *Compiler, entry: Node.AttrSetEntry) !void {
    if (entry.dynamic_name) |name| return self.compileNode(name);
    if (entry.path.len > 0 and attrSegmentHasInterpolation(self, entry.path[0])) {
        return literals.compileStringAtom(self, entry.path[0]);
    }
    return error.InvalidAttributePath;
}

pub fn compileDynamicAttrValueThunk(self: *Compiler, entry: Node.AttrSetEntry) !void {
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

pub fn compileNodeAttrEntriesThunk(self: *Compiler, entries: []const Node.AttrSetEntry, recursive: bool) !void {
    var child_builder = try ChunkBuilder.init(self.allocator);
    defer child_builder.deinit(self.allocator);

    var child = Compiler.init(
        self.allocator,
        &child_builder,
        self.registry,
        self.source,
        self.intern,
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
    try emit.emitOp(&child, .ret);
    try emit.emitOp(&child, .halt);

    const child_chunk = try child_builder.finish(self.allocator, child.slot_count);
    const child_id = try self.registry.register(child_chunk);
    try emit.emitThunkWithCaptures(self, child_id, child.captures.items);
}

pub fn compileAttrEntries(self: *Compiler, entries: []const AttrEntryView, recursive: bool) anyerror!void {
    if (hasDynamicAttrEntryViews(self, entries)) {
        return compileMixedAttrEntryViews(self, entries, recursive);
    }

    if (recursive) {
        try compileRecursiveAttrEntries(self, entries);
    } else {
        try compilePlainAttrEntries(self, entries);
    }
}

pub fn compileMixedAttrEntryViews(self: *Compiler, entries: []const AttrEntryView, recursive: bool) !void {
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

pub fn compileMixedRecursiveAttrEntryViews(self: *Compiler, entries: []const AttrEntryView) !void {
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

pub fn hasDynamicAttrEntryViews(self: *const Compiler, entries: []const AttrEntryView) bool {
    for (entries) |entry| {
        if (isDynamicAttrEntryView(self, entry)) return true;
    }
    return false;
}

pub fn staticAttrEntryViewCount(self: *const Compiler, entries: []const AttrEntryView) usize {
    var count: usize = 0;
    for (entries) |entry| {
        if (!isDynamicAttrEntryView(self, entry)) count += 1;
    }
    return count;
}

pub fn isDynamicAttrEntryView(self: *const Compiler, entry: AttrEntryView) bool {
    return entry.path.len > 0 and attrSegmentHasInterpolation(self, entry.path[0]);
}

pub fn compileDynamicAttrViewName(self: *Compiler, entry: AttrEntryView) !void {
    if (entry.path.len > 0 and attrSegmentHasInterpolation(self, entry.path[0])) {
        return literals.compileStringAtom(self, entry.path[0]);
    }
    return error.InvalidAttributePath;
}

pub fn compileDynamicAttrViewValueThunk(self: *Compiler, entry: AttrEntryView) !void {
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

pub fn compilePlainAttrEntries(self: *Compiler, entries: []const AttrEntryView) anyerror!void {
    var grouped = try attrEntryGroups(self, entries);
    defer grouped.deinit(self.allocator);

    var positions: std.ArrayListUnmanaged(heap_mod.AttrPosEntry) = .empty;
    defer positions.deinit(self.allocator);

    for (grouped.groups) |group| {
        try compilePlainAttrGroup(self, &positions, group);
    }

    const count = try diagnostics.requireU16At(self, grouped.groups.len, attrEntriesDiagnosticAtom(entries), "too many attributes in set");
    try emit.emitBuildAttrs(self, count, positions.items);
}

pub fn compileRecursiveAttrEntries(self: *Compiler, entries: []const AttrEntryView) anyerror!void {
    var grouped = try attrEntryGroups(self, entries);
    defer grouped.deinit(self.allocator);

    scope.beginScope(self);
    errdefer scope.endScope(self);

    try declareRecursiveAttrLocals(self, grouped.groups);
    try compileRecursiveAttrCells(self, grouped.groups);
    try emitRecursiveAttrObject(self, grouped.groups);
    scope.endScope(self);
}

pub fn compilePlainAttrGroup(
    self: *Compiler,
    positions: *std.ArrayListUnmanaged(heap_mod.AttrPosEntry),
    group: AttrEntryGroup,
) anyerror!void {
    const leaf = group.leaf;
    if (leaf == null) {
        try emitAttrNameId(self, group.name_id);
        try compileAttrEntriesThunk(self, group.tails, false);
        try appendAttrPosition(self, positions, group.first, group.name_id);
        return;
    }

    if (group.leaf_count > 1 or group.tails.len > 0) {
        const duplicate = if (leaf.?.expr.tag != .attr_set)
            group.duplicate_leaf orelse group.first_nested
        else
            nonAttrSetDuplicateLeaf(self, group);
        if (duplicate) |entry| {
            try reportDuplicateAttribute(self, entry.path[0], leaf.?.path[0]);
            return error.DuplicateAttribute;
        }
        try emitAttrNameId(self, group.name_id);
        try compileExtendedAttrSetLiteralThunk(self, group.leaves, group.tails);
        try appendAttrPosition(self, positions, group.first, group.name_id);
        return;
    }

    try emitAttrNameId(self, group.name_id);
    try access.compileContainerValue(self, leaf.?.expr, .{ .raw_identifier = true });
    try appendAttrPosition(self, positions, group.first, group.name_id);
}

pub fn declareRecursiveAttrLocals(self: *Compiler, groups: []const AttrEntryGroup) anyerror!void {
    for (groups) |group| {
        try emit.emitOp(self, .push_null);
        try emit.emitOp(self, .make_cell);
        const slot = try scope.declareLocal(self, group.name, group.name_id);
        try emit.emitSetLocal(self, slot);
    }
}

pub fn compileRecursiveAttrCells(self: *Compiler, groups: []const AttrEntryGroup) anyerror!void {
    for (groups) |group| {
        const slot = scope.resolveLocalId(self, group.name_id) orelse return error.UndefinedVariable;
        const leaf = group.leaf;
        if (leaf == null) {
            try compileAttrEntriesThunk(self, group.tails, false);
            try emit.emitSetCellLocal(self, slot);
            continue;
        }

        if (group.leaf_count > 1 or group.tails.len > 0) {
            const duplicate = if (leaf.?.expr.tag != .attr_set)
                group.duplicate_leaf orelse group.first_nested
            else
                nonAttrSetDuplicateLeaf(self, group);
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

pub fn emitRecursiveAttrObject(self: *Compiler, groups: []const AttrEntryGroup) anyerror!void {
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

pub fn nonAttrSetDuplicateLeaf(self: *Compiler, group: AttrEntryGroup) ?AttrEntryView {
    _ = self;
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
        &child_builder,
        self.registry,
        self.source,
        self.intern,
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
    try emit.emitOp(&child, .ret);
    try emit.emitOp(&child, .halt);

    const child_chunk = try child_builder.finish(self.allocator, child.slot_count);
    const child_id = try self.registry.register(child_chunk);
    try emit.emitThunkWithCaptures(self, child_id, child.captures.items);
}

pub fn attrEntryViews(self: *Compiler, entries: []const Node.AttrSetEntry) ![]AttrEntryView {
    const views = try self.allocator.alloc(AttrEntryView, entries.len);
    for (entries, views) |entry, *view| {
        std.debug.assert(entry.dynamic_name == null);
        view.* = .{ .path = entry.path, .expr = entry.expr, .inherit_outer = entry.inherit_outer };
    }
    return views;
}

pub fn attrEntryGroups(self: *Compiler, entries: []const AttrEntryView) !AttrEntryGroups {
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
