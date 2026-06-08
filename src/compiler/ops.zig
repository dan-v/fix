const std = @import("std");
const compiler_mod = @import("../compiler.zig");
const ast = @import("../ast.zig");
const bytecode = @import("../bytecode.zig");
const builtins = @import("../builtins.zig");
const chunk = bytecode.chunk;
const diagnostic = @import("../diagnostic.zig");
const heap_mod = @import("../runtime/heap.zig");
const string_syntax = @import("../string_syntax.zig");
const types = @import("../runtime/types.zig");
const Value = @import("../runtime/value.zig").Value;
const OpCode = bytecode.OpCode;
const emit = @import("emit.zig");
const scope = @import("scope.zig");
const thunks = @import("thunks.zig");
const diagnostics = @import("diagnostics.zig");
const attrs = @import("attrs.zig");
const access = @import("access.zig");
const control = @import("control.zig");

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
const diagnosticAtom = diagnostic_atom.diagnosticAtom;
const nodeMayEvaluateToFloat = ast.nodeMayEvaluateToFloat;
const unwrapParens = ast.unwrapParens;

pub fn compileBinary(self: *Compiler, node: *const Node) !void {
    const bin = node.data.binary;
    switch (bin.op) {
        .and_ => return compileAnd(self, bin.left, bin.right),
        .or_ => return compileOr(self, bin.left, bin.right),
        .impl => return compileImpl(self, bin.left, bin.right),
        else => {},
    }

    try self.compileNode(bin.left);
    try self.compileNode(bin.right);

    switch (bin.op) {
        .add => try emit.emitOp(self, if (nodeMayEvaluateToFloat(bin.left) or nodeMayEvaluateToFloat(bin.right)) .add_float else .add_int),
        .sub => try emit.emitOp(self, if (nodeMayEvaluateToFloat(bin.left) or nodeMayEvaluateToFloat(bin.right)) .sub_float else .sub_int),
        .mul => try emit.emitOp(self, if (nodeMayEvaluateToFloat(bin.left) or nodeMayEvaluateToFloat(bin.right)) .mul_float else .mul_int),
        .div => try emit.emitOp(self, if (nodeMayEvaluateToFloat(bin.left) or nodeMayEvaluateToFloat(bin.right)) .div_float else .div_int),
        .eq => try emit.emitOp(self, .eq),
        .neq => try emit.emitOp(self, .neq),
        .lt => try emit.emitOp(self, .lt),
        .lte => try emit.emitOp(self, .lte),
        .gt => try emit.emitOp(self, .gt),
        .gte => try emit.emitOp(self, .gte),
        .and_, .or_ => unreachable,
        .update => try emit.emitOp(self, .merge_attrs),
        .impl => unreachable,
        .concat => try emit.emitOp(self, .concat_lists),
    }
}

pub fn compileAnd(self: *Compiler, left: *const Node, right: *const Node) !void {
    try self.compileNode(left);

    const end_jump = self.builder.code.items.len;
    try emit.emitOpU32(self, .jump_if_false, 0);
    try emit.emitOp(self, .pop);

    try self.compileNode(right);
    emit.patchJump(self, end_jump, self.builder.code.items.len);
}

pub fn compileOr(self: *Compiler, left: *const Node, right: *const Node) !void {
    try self.compileNode(left);

    const false_jump = self.builder.code.items.len;
    try emit.emitOpU32(self, .jump_if_false, 0);

    const end_jump = self.builder.code.items.len;
    try emit.emitOpU32(self, .jump, 0);

    emit.patchJump(self, false_jump, self.builder.code.items.len);
    try emit.emitOp(self, .pop);

    try self.compileNode(right);
    emit.patchJump(self, end_jump, self.builder.code.items.len);
}

pub fn compileImpl(self: *Compiler, left: *const Node, right: *const Node) !void {
    try self.compileNode(left);

    const false_jump = self.builder.code.items.len;
    try emit.emitOpU32(self, .jump_if_false, 0);
    try emit.emitOp(self, .pop);

    try self.compileNode(right);
    const end_jump = self.builder.code.items.len;
    try emit.emitOpU32(self, .jump, 0);

    emit.patchJump(self, false_jump, self.builder.code.items.len);
    try emit.emitOp(self, .pop);
    try emit.emitOp(self, .push_true);

    emit.patchJump(self, end_jump, self.builder.code.items.len);
}

pub fn compileUnary(self: *Compiler, node: *const Node) !void {
    const un = node.data.unary;
    try self.compileNode(un.expr);
    switch (un.op) {
        .negate => try emit.emitOp(self, .negate_int),
        .not => try emit.emitOp(self, .not),
    }
}

pub fn compileApply(self: *Compiler, node: *const Node) !void {
    try compileApplyWithOp(self, node, .call);
}

pub fn compileTailExpression(self: *Compiler, node: *const Node) anyerror!void {
    const unwrapped = unwrapParens(node);
    switch (unwrapped.tag) {
        .apply, .if_else, .let_in, .assert, .with_expr => {},
        else => return self.compileNode(node),
    }

    {
        const start = self.builder.code.items.len;
        try compileTailNodeImpl(self, unwrapped);
        const end = self.builder.code.items.len;
        if (try diagnostics.sourceSpanForNode(self, node)) |span| {
            try self.builder.addSourceMapEntry(self.allocator, start, end, span);
        }
        return;
    }
}

pub fn compileTailNodeImpl(self: *Compiler, node: *const Node) anyerror!void {
    switch (node.tag) {
        .apply => try compileApplyWithOp(self, node, .tail_call),
        .if_else => try control.compileIfElseTail(self, node),
        .let_in => try compileLetInWithTailBody(self, node),
        .assert => try control.compileAssertTail(self, node),
        .with_expr => try control.compileWithTail(self, node),
        else => unreachable,
    }
}

pub fn compileApplyWithOp(self: *Compiler, node: *const Node, op: OpCode) !void {
    const ap = node.data.apply;
    try self.compileNode(ap.func);
    try access.compileContainerValue(self, ap.arg, .{});
    try emit.emitOp(self, op);
}

pub fn compileLambda(self: *Compiler, node: *const Node) !void {
    const lambda = node.data.lambda;
    const param_name = self.source[lambda.param_offset .. lambda.param_offset + lambda.param_len];

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

    const param_id = try self.intern.intern(param_name);
    _ = try scope.declareLocal(&child, param_name, param_id);
    compileTailExpression(&child, lambda.body) catch |err| {
        try diagnostics.absorbChildDiagnostics(self, &child);
        return err;
    };
    try emit.emitOp(&child, .ret);
    try emit.emitOp(&child, .halt);

    const child_chunk = try child_builder.finish(self.allocator, child.slot_count);
    const child_id = try self.registry.register(child_chunk);
    try emit.emitClosureWithCaptures(self, child_id, child.captures.items);
}

pub fn compileLambdaAttrs(self: *Compiler, node: *const Node) !void {
    const lambda = node.data.lambda_attrs;

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

    const arg_slot = try scope.declareLocal(&child, "\x00args", try self.intern.intern("\x00args"));
    if (lambda.bind_name) |bind_name| {
        const name = self.source[bind_name.offset .. bind_name.offset + bind_name.len];
        const name_id = try self.intern.intern(name);
        const slot = try scope.declareLocal(&child, name, name_id);
        try emit.emitCaptureLocal(&child, arg_slot);
        try emit.emitSetLocal(&child, slot);
    }

    var wide_params = false;
    for (lambda.params) |param| {
        const name = self.source[param.name.offset .. param.name.offset + param.name.len];
        if (try self.intern.intern(name) > std.math.maxInt(u16)) wide_params = true;
    }

    try emit.emitGetLocal(&child, arg_slot);
    try emit.emitOp(&child, if (wide_params) .validate_attrs_long else .validate_attrs);
    try child.builder.writeByte(child.allocator, if (lambda.allow_extra) 1 else 0);
    const param_count = try diagnostics.requireU16At(self, lambda.params.len, diagnosticAtom(node), "too many function parameters");
    try child.builder.writeU16(child.allocator, param_count);
    var function_args: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer function_args.deinit(self.allocator);
    try function_args.ensureTotalCapacity(self.allocator, lambda.params.len);
    for (lambda.params) |param| {
        const name = self.source[param.name.offset .. param.name.offset + param.name.len];
        const name_id = try self.intern.intern(name);
        try emit.writeInternId(&child, name_id, wide_params);
        function_args.appendAssumeCapacity(.{
            .name = name_id,
            .value = Value.boolVal(param.default != null),
        });
    }
    try child_builder.setFunctionArgs(self.allocator, function_args.items);

    for (lambda.params) |param| {
        const name = self.source[param.name.offset .. param.name.offset + param.name.len];
        const name_id = try self.intern.intern(name);
        const slot = try scope.declareLocal(&child, name, name_id);
        try emit.emitInitCellSlot(&child, slot);
    }

    for (lambda.params) |param| {
        const name = self.source[param.name.offset .. param.name.offset + param.name.len];
        const name_id = try self.intern.intern(name);
        const slot = scope.resolveLocal(&child, name) orelse return error.UndefinedVariable;
        try compileAttrParamThunk(&child, arg_slot, name_id, param.default);
        try emit.emitSetCellLocal(&child, slot);
    }

    compileTailExpression(&child, lambda.body) catch |err| {
        try diagnostics.absorbChildDiagnostics(self, &child);
        return err;
    };
    try emit.emitOp(&child, .ret);
    try emit.emitOp(&child, .halt);

    const child_chunk = try child_builder.finish(self.allocator, child.slot_count);
    const child_id = try self.registry.register(child_chunk);
    try emit.emitClosureWithCaptures(self, child_id, child.captures.items);
}

pub fn compileAttrParamThunk(self: *Compiler, arg_slot: u16, name_id: InternId, default: ?*const Node) !void {
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

    _ = try scope.addCapture(&child, "\x00args", .local, arg_slot);
    try emit.emitOpU16(&child, .get_upvalue, 0);
    if (default) |default_expr| {
        try thunks.compileThunk(&child, default_expr);
        try emit.emitOp(&child, if (name_id > std.math.maxInt(u16)) .get_attr_path_or_long else .get_attr_path_or);
        try child.builder.writeByte(child.allocator, 1);
        try emit.writeInternId(&child, name_id, name_id > std.math.maxInt(u16));
    } else {
        try emit.emitInternOp(&child, .get_attr, .get_attr_long, name_id);
    }
    try emit.emitOp(&child, .ret);
    try emit.emitOp(&child, .halt);

    const child_chunk = try child_builder.finish(self.allocator, child.slot_count);
    const child_id = try self.registry.register(child_chunk);
    try emit.emitThunkWithCaptures(self, child_id, child.captures.items);
}

pub fn compileLetIn(self: *Compiler, node: *const Node) !void {
    try compileLetInBody(self, node, false);
}

pub fn compileLetInWithTailBody(self: *Compiler, node: *const Node) anyerror!void {
    try compileLetInBody(self, node, true);
}

pub fn compileLetInBody(self: *Compiler, node: *const Node, tail_body: bool) anyerror!void {
    const let_in = node.data.let_in;

    scope.beginScope(self);

    // For each unique binding root, classify how it should be
    // compiled. Three kinds:
    //   .literal           — RHS is a pure literal; eagerly bind value
    //                        directly into the slot (no cell).
    //   .uncaptured        — non-literal RHS, no earlier binding in
    //                        this let references the name; we can skip
    //                        the cell and just `set_local` the lazy
    //                        thunk value in pass 2. The body and any
    //                        later binding's RHS will see the bound
    //                        thunk and force normally.
    //   .needs_cell        — non-literal RHS that *is* referenced by
    //                        an earlier binding (forward reference);
    //                        the cell exists so the earlier RHS can
    //                        capture a mutable handle that this
    //                        binding's pass 2 mutates.
    const kinds = try classifyLetBindings(self, let_in.bindings);
    defer self.allocator.free(kinds);

    for (let_in.bindings, kinds, 0..) |binding, kind, index| {
        if (bindingRootSeen(self, let_in.bindings[0..index], binding.path[0])) continue;
        const name = attrs.attrSegmentSpan(self, binding.path[0]);
        const name_id = try self.intern.intern(name);
        const slot = try scope.declareLocal(self, name, name_id);
        switch (kind) {
            .literal => {
                const leaf = singleLeafBinding(self, let_in.bindings, binding.path[0]).?;
                try access.compileContainerValue(self, leaf.expr, .{});
                try emit.emitSetLocal(self, slot);
            },
            .uncaptured => {}, // pass 2 will fill the slot directly
            .needs_cell => try emit.emitInitCellSlot(self, slot),
        }
    }

    for (let_in.bindings, kinds, 0..) |binding, kind, index| {
        if (bindingRootSeen(self, let_in.bindings[0..index], binding.path[0])) continue;
        if (kind == .literal) continue;
        const name = attrs.attrSegmentSpan(self, binding.path[0]);
        const slot = scope.resolveLocal(self, name) orelse return error.UndefinedVariable;
        try compileLetRootBinding(self, let_in.bindings, binding.path[0], slot);
        switch (kind) {
            .needs_cell => try emit.emitSetCellLocal(self, slot),
            .uncaptured => try emit.emitSetLocal(self, slot),
            .literal => unreachable,
        }
    }

    if (tail_body) {
        try compileTailExpression(self, let_in.body);
    } else {
        try self.compileNode(let_in.body);
    }

    scope.endScope(self);
}

const LetBindingKind = enum { literal, uncaptured, needs_cell };

/// Decide for each binding whether it can skip the cell. A binding
/// needs a cell iff some *earlier* binding (which gets compiled first
/// in pass 2) references it by name — only then is the cell's
/// mutable-handle behaviour load-bearing. Later bindings and the body
/// always see the bound value because pass 2 fills slots in source
/// order before the body emits.
fn classifyLetBindings(self: *Compiler, bindings: []const Node.Binding) ![]LetBindingKind {
    const kinds = try self.allocator.alloc(LetBindingKind, bindings.len);
    errdefer self.allocator.free(kinds);

    for (bindings, 0..) |binding, i| {
        if (bindingRootSeen(self, bindings[0..i], binding.path[0])) {
            // Duplicate root segment — the original binding's
            // classification covers it; this slot is unused.
            kinds[i] = .needs_cell;
            continue;
        }
        if (isLiteralLeafBinding(self, bindings, binding.path[0])) {
            kinds[i] = .literal;
            continue;
        }
        const name = attrs.attrSegmentSpan(self, binding.path[0]);
        if (groupNeedsCell(self, bindings, i, name)) {
            kinds[i] = .needs_cell;
        } else {
            kinds[i] = .uncaptured;
        }
    }
    return kinds;
}

/// True if the binding rooted at `bindings[target_index]` must keep a
/// cell. A cell is needed if:
///   - any binding at index ≤ target_index references `name`
///     (forward-or-self reference: capture happens before the
///     pass-2 set runs), OR
///   - the binding's group contains nested paths or sibling tails —
///     these synthesise an attr-set thunk whose captures we
///     conservatively treat as touching every name in scope.
fn groupNeedsCell(self: *Compiler, bindings: []const Node.Binding, target_index: usize, name: []const u8) bool {
    const target = bindings[target_index];
    if (target.path.len > 1) return true;

    // Scan earlier siblings: any reference forces the cell.
    var i: usize = 0;
    while (i < target_index) : (i += 1) {
        const binding = bindings[i];
        if (binding.path.len > 1) return true;
        if (nodeReferencesName(self, binding.expr, name)) return true;
    }
    // Self-reference (binding[target_index]'s RHS mentions `name`):
    // capture would happen during this binding's own thunk
    // construction, before set_local runs — needs cell.
    if (nodeReferencesName(self, target.expr, name)) return true;

    // Also check later siblings sharing the same root path — a
    // duplicate-root group with a tail forces compileLetRootBinding
    // into the attr-set-thunk path, whose captures we can't safely
    // skip cells for.
    var j: usize = target_index + 1;
    while (j < bindings.len) : (j += 1) {
        if (attrs.attrSegmentsEqual(self, bindings[j].path[0], target.path[0])) return true;
    }
    return false;
}

fn nodeReferencesName(self: *Compiler, node: *const Node, name: []const u8) bool {
    switch (node.tag) {
        .integer, .float_val, .bool_true, .bool_false, .null, .search_path => return false,
        .string => {
            // Interpolation parts are inside the source span; the
            // parser surfaces them via separate child nodes only when
            // wrapped in an apply/binary tree, but raw string atoms
            // can contain `${name}` which references identifiers
            // textually. Conservative: any occurrence of the name in
            // the literal span counts.
            return spanContainsIdentifier(self, node.data.atom, name);
        },
        .path => {
            return spanContainsIdentifier(self, node.data.atom, name);
        },
        .identifier => {
            const ident = self.source[node.data.atom.offset .. node.data.atom.offset + node.data.atom.len];
            return std.mem.eql(u8, ident, name);
        },
        .unary_op => return nodeReferencesName(self, node.data.unary.expr, name),
        .binary_op => {
            return nodeReferencesName(self, node.data.binary.left, name) or
                nodeReferencesName(self, node.data.binary.right, name);
        },
        .apply => {
            return nodeReferencesName(self, node.data.apply.func, name) or
                nodeReferencesName(self, node.data.apply.arg, name);
        },
        .lambda => return nodeReferencesName(self, node.data.lambda.body, name),
        .lambda_attrs => {
            const la = node.data.lambda_attrs;
            for (la.params) |param| {
                if (param.default) |default| {
                    if (nodeReferencesName(self, default, name)) return true;
                }
            }
            return nodeReferencesName(self, la.body, name);
        },
        .let_in => {
            const li = node.data.let_in;
            for (li.bindings) |b| {
                if (nodeReferencesName(self, b.expr, name)) return true;
            }
            return nodeReferencesName(self, li.body, name);
        },
        .if_else => {
            const ie = node.data.if_else;
            return nodeReferencesName(self, ie.cond, name) or
                nodeReferencesName(self, ie.then_branch, name) or
                nodeReferencesName(self, ie.else_branch, name);
        },
        .assert => return nodeReferencesName(self, node.data.assert.cond, name) or
            nodeReferencesName(self, node.data.assert.body, name),
        .with_expr => return nodeReferencesName(self, node.data.with_expr.attr_set, name) or
            nodeReferencesName(self, node.data.with_expr.body, name),
        .attr_set => {
            for (node.data.attr_set.entries) |entry| {
                if (entry.dynamic_name) |dn| {
                    if (nodeReferencesName(self, dn, name)) return true;
                }
                if (nodeReferencesName(self, entry.expr, name)) return true;
            }
            return false;
        },
        .attr_path => return nodeReferencesName(self, node.data.attr_path.root, name),
        .attr_dynamic => return nodeReferencesName(self, node.data.attr_dynamic.root, name) or
            nodeReferencesName(self, node.data.attr_dynamic.name, name),
        .attr_or => return nodeReferencesName(self, node.data.attr_or.attr_path, name) or
            nodeReferencesName(self, node.data.attr_or.default, name),
        .has_attr => return nodeReferencesName(self, node.data.has_attr.root, name),
        .has_attr_dynamic => return nodeReferencesName(self, node.data.has_attr_dynamic.root, name) or
            nodeReferencesName(self, node.data.has_attr_dynamic.name, name),
        .has_attr_mixed => {
            const ham = node.data.has_attr_mixed;
            if (nodeReferencesName(self, ham.root, name)) return true;
            for (ham.segments) |seg| switch (seg) {
                .static => {},
                .dynamic => |n| if (nodeReferencesName(self, n, name)) return true,
            };
            return false;
        },
        .list => {
            for (node.data.list.items) |item| {
                if (nodeReferencesName(self, item, name)) return true;
            }
            return false;
        },
        .parens => return nodeReferencesName(self, node.data.parens, name),
    }
}

/// Substring-with-word-boundary check on a source-text span. Used to
/// catch references inside string interpolation (`${name}`) and path
/// interpolation without expanding the AST through the string parser.
/// False positives (a substring that's not a real identifier
/// reference) just keep the cell — sound but conservative.
fn spanContainsIdentifier(self: *Compiler, atom: Node.Atom, name: []const u8) bool {
    const text = self.source[atom.offset .. atom.offset + atom.len];
    var i: usize = 0;
    while (i + name.len <= text.len) : (i += 1) {
        if (!std.mem.eql(u8, text[i .. i + name.len], name)) continue;
        // Check word boundaries — adjacent identifier chars mean
        // it's part of a longer name, not a standalone reference.
        if (i > 0 and isIdentChar(text[i - 1])) continue;
        if (i + name.len < text.len and isIdentChar(text[i + name.len])) continue;
        return true;
    }
    return false;
}

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '_' or c == '\'' or c == '-';
}

/// True when the binding group sharing `root` is exactly one leaf
/// (no nested attr paths, no duplicates) and that leaf's RHS is a
/// pure literal — i.e. eager evaluation can replace the cell-wrap
/// without changing observable behaviour.
fn isLiteralLeafBinding(self: *Compiler, bindings: []const Node.Binding, root: Node.Atom) bool {
    const leaf = singleLeafBinding(self, bindings, root) orelse return false;
    return access.isLiteralContainerValue(self, leaf.expr);
}

fn singleLeafBinding(self: *Compiler, bindings: []const Node.Binding, root: Node.Atom) ?Node.Binding {
    var found: ?Node.Binding = null;
    for (bindings) |binding| {
        if (!attrs.attrSegmentsEqual(self, binding.path[0], root)) continue;
        if (binding.path.len != 1) return null;
        if (binding.inherit_outer) return null;
        if (found != null) return null;
        found = binding;
    }
    return found;
}

pub fn compileLetRootBinding(self: *Compiler, bindings: []const Node.Binding, root: Node.Atom, slot: u16) !void {
    var leaf: ?Node.Binding = null;
    var tail_count: usize = 0;

    for (bindings) |binding| {
        if (!attrs.attrSegmentsEqual(self, binding.path[0], root)) continue;
        if (binding.path.len == 1) {
            if (leaf) |previous| {
                try diagnostics.reportCompileError(self, binding.name_offset, binding.name_len, "duplicate let binding");
                try diagnostics.reportCompileNote(self, previous.name_offset, previous.name_len, "first binding defined here");
                return error.DuplicateBinding;
            }
            leaf = binding;
        } else {
            tail_count += 1;
        }
    }

    if (tail_count == 0) {
        const binding = leaf orelse return error.UndefinedVariable;
        const previous_skip = self.skip_local_slot;
        if (binding.inherit_outer) self.skip_local_slot = slot;
        const compile_result = access.compileContainerValue(self, binding.expr, .{});
        self.skip_local_slot = previous_skip;
        return compile_result;
    }

    const tails = try self.allocator.alloc(AttrEntryView, tail_count);
    defer self.allocator.free(tails);
    var i: usize = 0;
    for (bindings) |binding| {
        if (!attrs.attrSegmentsEqual(self, binding.path[0], root) or binding.path.len == 1) continue;
        tails[i] = .{
            .path = binding.path[1..],
            .expr = binding.expr,
            .inherit_outer = binding.inherit_outer,
        };
        i += 1;
    }

    if (leaf) |root_leaf| {
        if (root_leaf.expr.tag != .attr_set) {
            try attrs.reportDuplicateAttribute(self, tails[0].path[0], root_leaf.path[0]);
            return error.DuplicateAttribute;
        }
        const leaves = [_]AttrEntryView{.{
            .path = root_leaf.path,
            .expr = root_leaf.expr,
            .inherit_outer = root_leaf.inherit_outer,
        }};
        return attrs.compileExtendedAttrSetLiteralThunk(self, &leaves, tails);
    }

    return attrs.compileAttrEntriesThunk(self, tails, true);
}

pub fn bindingRootSeen(self: *const Compiler, bindings: []const Node.Binding, root: Node.Atom) bool {
    for (bindings) |binding| {
        if (binding.path.len > 0 and attrs.attrSegmentsEqual(self, binding.path[0], root)) return true;
    }
    return false;
}
