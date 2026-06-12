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
const strictness = @import("strictness.zig");

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

    // Specialized comparison with literal `null`. Emit only the
    // non-null side and use `eq_null`/`neq_null` so the runtime
    // (and the eventual JIT) sees a type-monomorphic null check.
    if (bin.op == .eq or bin.op == .neq) {
        const left_null = unwrapParens(bin.left).tag == .null;
        const right_null = unwrapParens(bin.right).tag == .null;
        if (left_null != right_null) {
            try self.compileNode(if (left_null) bin.right else bin.left);
            try emit.emitOp(self, if (bin.op == .eq) .eq_null else .neq_null);
            return;
        }
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
        self.heap,
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
    try strictness.stampOnBuilder(&child, lambda.body);
    try emit.emitRet(&child);
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
        self.heap,
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
    try strictness.stampOnBuilder(&child, lambda.body);
    try emit.emitRet(&child);
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
        self.heap,
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
        try emit.emitGetAttr(&child, name_id);
    }
    try emit.emitRet(&child);
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
    // compiled. Four kinds:
    //   .unreferenced      — nothing else in this let (or its body)
    //                        mentions the name; skip the binding
    //                        entirely. Nix is pure and lazy: if no
    //                        one forces the RHS, its side-effects
    //                        never fire, so omitting it is observably
    //                        equivalent.
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
    const kinds = try classifyLetBindings(self, let_in.bindings, let_in.body);
    defer self.allocator.free(kinds);

    // Strictness-driven eagerness: analyze the body once, then for
    // each binding whose name appears in body's shallow strict set
    // emit the eager thunk variant. That submits the thunk to the
    // urgent scheduler queue at creation so helpers can race ahead.
    const eager_flags = try self.allocator.alloc(bool, let_in.bindings.len);
    defer self.allocator.free(eager_flags);
    {
        const binding_name_ids = try self.allocator.alloc(InternId, let_in.bindings.len);
        defer self.allocator.free(binding_name_ids);
        for (let_in.bindings, binding_name_ids) |binding, *nid| {
            const name = attrs.attrSegmentSpan(self, binding.path[0]);
            nid.* = try self.intern.intern(name);
        }
        try @import("strictness.zig").analyzeLetEagerness(
            self.allocator,
            self.intern,
            self.source,
            let_in.body,
            binding_name_ids,
            eager_flags,
        );
    }

    for (let_in.bindings, kinds, 0..) |binding, kind, index| {
        if (bindingRootSeen(self, let_in.bindings[0..index], binding.path[0])) continue;
        if (kind == .unreferenced) continue;
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
            .unreferenced => unreachable,
        }
    }

    for (let_in.bindings, kinds, 0..) |binding, kind, index| {
        if (bindingRootSeen(self, let_in.bindings[0..index], binding.path[0])) continue;
        if (kind == .literal or kind == .unreferenced) continue;
        const name = attrs.attrSegmentSpan(self, binding.path[0]);
        const slot = scope.resolveLocal(self, name) orelse return error.UndefinedVariable;
        try compileLetRootBinding(self, let_in.bindings, binding.path[0], slot, eager_flags[index]);
        switch (kind) {
            .needs_cell => try emit.emitSetCellLocal(self, slot),
            .uncaptured => try emit.emitSetLocal(self, slot),
            .literal, .unreferenced => unreachable,
        }
    }

    if (tail_body) {
        try compileTailExpression(self, let_in.body);
    } else {
        try self.compileNode(let_in.body);
    }

    scope.endScope(self);
}

const LetBindingKind = enum { unreferenced, literal, uncaptured, needs_cell };

/// Decide for each binding whether it can skip the cell. A binding
/// needs a cell iff some *earlier* binding (which gets compiled first
/// in pass 2) references it by name — only then is the cell's
/// mutable-handle behaviour load-bearing. Later bindings and the body
/// always see the bound value because pass 2 fills slots in source
/// order before the body emits.
///
/// To keep compile cost reasonable on big lets the analysis builds
/// per-RHS reference hashsets once up front. Per-binding membership
/// checks are then O(1) instead of O(total source bytes) — a
/// measurable `mem.eql`-dominance saving on workloads with hundreds
/// of let bindings (e.g. nixpkgs).
fn classifyLetBindings(self: *Compiler, bindings: []const Node.Binding, body: *const Node) ![]LetBindingKind {
    const kinds = try self.allocator.alloc(LetBindingKind, bindings.len);
    errdefer self.allocator.free(kinds);

    var body_refs: std.StringHashMapUnmanaged(void) = .empty;
    defer body_refs.deinit(self.allocator);
    try collectReferencedNames(self, body, &body_refs);

    const rhs_refs = try self.allocator.alloc(std.StringHashMapUnmanaged(void), bindings.len);
    defer {
        for (rhs_refs) |*s| s.deinit(self.allocator);
        self.allocator.free(rhs_refs);
    }
    for (rhs_refs) |*s| s.* = .empty;
    var any_path_nested = false;
    for (bindings, 0..) |binding, i| {
        if (binding.path.len > 1) {
            // Nested-path bindings synthesise an attr-set thunk
            // whose captures we don't statically track; conservative:
            // any such binding "references" every other.
            any_path_nested = true;
        }
        try collectReferencedNames(self, binding.expr, &rhs_refs[i]);
    }

    for (bindings, 0..) |binding, i| {
        if (bindingRootSeen(self, bindings[0..i], binding.path[0])) {
            kinds[i] = .needs_cell;
            continue;
        }
        const name = attrs.attrSegmentSpan(self, binding.path[0]);

        const externally_referenced = body_refs.contains(name) or any_path_nested or
            referencedByOtherRhs(rhs_refs, i, name);
        if (!externally_referenced) {
            kinds[i] = .unreferenced;
            continue;
        }
        if (isLiteralLeafBinding(self, bindings, binding.path[0])) {
            kinds[i] = .literal;
            continue;
        }
        if (groupNeedsCellFromSets(rhs_refs, i, name)) {
            kinds[i] = .needs_cell;
        } else {
            kinds[i] = .uncaptured;
        }
    }
    return kinds;
}

fn referencedByOtherRhs(
    rhs_refs: []const std.StringHashMapUnmanaged(void),
    target_index: usize,
    name: []const u8,
) bool {
    for (rhs_refs, 0..) |s, i| {
        if (i == target_index) continue;
        if (s.contains(name)) return true;
    }
    return false;
}

/// Cell-needed predicate using the precomputed reference sets. A
/// binding's name is "earlier-or-self referenced" when any binding
/// in `0..=target_index` mentions it: that's exactly the set whose
/// pass-2 compile would either capture before the slot is filled
/// (earlier sibling) or during its own thunk construction (self).
fn groupNeedsCellFromSets(
    rhs_refs: []const std.StringHashMapUnmanaged(void),
    target_index: usize,
    name: []const u8,
) bool {
    var i: usize = 0;
    while (i <= target_index) : (i += 1) {
        if (rhs_refs[i].contains(name)) return true;
    }
    return false;
}

/// Walk `node` and add every identifier name encountered to `out`,
/// including textual matches inside `${...}` interpolation in atoms.
/// Conservatively mirrors `nodeReferencesName`'s coverage — false
/// positives just keep cells (and bindings) around, never break
/// semantics.
fn collectReferencedNames(self: *Compiler, node: *const Node, out: *std.StringHashMapUnmanaged(void)) anyerror!void {
    switch (node.tag) {
        .integer, .float_val, .bool_true, .bool_false, .null, .search_path => {},
        .string, .path => try collectIdentifiersInSpan(self, node.data.atom, out),
        .identifier => {
            const ident = self.source[node.data.atom.offset .. node.data.atom.offset + node.data.atom.len];
            try out.put(self.allocator, ident, {});
        },
        .unary_op => try collectReferencedNames(self, node.data.unary.expr, out),
        .binary_op => {
            try collectReferencedNames(self, node.data.binary.left, out);
            try collectReferencedNames(self, node.data.binary.right, out);
        },
        .apply => {
            try collectReferencedNames(self, node.data.apply.func, out);
            try collectReferencedNames(self, node.data.apply.arg, out);
        },
        .lambda => try collectReferencedNames(self, node.data.lambda.body, out),
        .lambda_attrs => {
            const la = node.data.lambda_attrs;
            for (la.params) |param| {
                if (param.default) |default| try collectReferencedNames(self, default, out);
            }
            try collectReferencedNames(self, la.body, out);
        },
        .let_in => {
            const li = node.data.let_in;
            for (li.bindings) |b| try collectReferencedNames(self, b.expr, out);
            try collectReferencedNames(self, li.body, out);
        },
        .if_else => {
            const ie = node.data.if_else;
            try collectReferencedNames(self, ie.cond, out);
            try collectReferencedNames(self, ie.then_branch, out);
            try collectReferencedNames(self, ie.else_branch, out);
        },
        .assert => {
            try collectReferencedNames(self, node.data.assert.cond, out);
            try collectReferencedNames(self, node.data.assert.body, out);
        },
        .with_expr => {
            try collectReferencedNames(self, node.data.with_expr.attr_set, out);
            try collectReferencedNames(self, node.data.with_expr.body, out);
        },
        .attr_set => {
            for (node.data.attr_set.entries) |entry| {
                if (entry.dynamic_name) |dn| try collectReferencedNames(self, dn, out);
                for (entry.path) |seg| try collectIdentifiersInSpan(self, seg, out);
                try collectReferencedNames(self, entry.expr, out);
            }
        },
        .attr_path => {
            try collectReferencedNames(self, node.data.attr_path.root, out);
            for (node.data.attr_path.segments) |seg| try collectIdentifiersInSpan(self, seg, out);
        },
        .attr_dynamic => {
            try collectReferencedNames(self, node.data.attr_dynamic.root, out);
            try collectReferencedNames(self, node.data.attr_dynamic.name, out);
        },
        .attr_or => {
            try collectReferencedNames(self, node.data.attr_or.attr_path, out);
            try collectReferencedNames(self, node.data.attr_or.default, out);
        },
        .has_attr => {
            try collectReferencedNames(self, node.data.has_attr.root, out);
            for (node.data.has_attr.segments) |seg| try collectIdentifiersInSpan(self, seg, out);
        },
        .has_attr_dynamic => {
            try collectReferencedNames(self, node.data.has_attr_dynamic.root, out);
            try collectReferencedNames(self, node.data.has_attr_dynamic.name, out);
        },
        .has_attr_mixed => {
            const ham = node.data.has_attr_mixed;
            try collectReferencedNames(self, ham.root, out);
            for (ham.segments) |seg| switch (seg) {
                .static => |a| try collectIdentifiersInSpan(self, a, out),
                .dynamic => |n| try collectReferencedNames(self, n, out),
            };
        },
        .list => {
            for (node.data.list.items) |item| try collectReferencedNames(self, item, out);
        },
        .parens => try collectReferencedNames(self, node.data.parens, out),
    }
}

/// Pull out every identifier-shaped substring from a source span and
/// add it to `out`. Catches references inside `${...}` interpolation
/// in atom-typed fields without expanding through the string parser.
fn collectIdentifiersInSpan(self: *Compiler, atom: Node.Atom, out: *std.StringHashMapUnmanaged(void)) !void {
    const text = self.source[atom.offset .. atom.offset + atom.len];
    var i: usize = 0;
    while (i < text.len) {
        if (isIdentStart(text[i])) {
            const start = i;
            while (i < text.len and isIdentChar(text[i])) : (i += 1) {}
            try out.put(self.allocator, text[start..i], {});
        } else {
            i += 1;
        }
    }
}

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
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

pub fn compileLetRootBinding(self: *Compiler, bindings: []const Node.Binding, root: Node.Atom, slot: u16, eager: bool) !void {
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
        const compile_result = access.compileContainerValue(self, binding.expr, .{ .eager = eager });
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
