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
        try emit.emitOp(&child, .push_null);
        try emit.emitOp(&child, .make_cell);
        const slot = try scope.declareLocal(&child, name, name_id);
        try emit.emitSetLocal(&child, slot);
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

    for (let_in.bindings, 0..) |binding, index| {
        if (bindingRootSeen(self, let_in.bindings[0..index], binding.path[0])) continue;
        const name = attrs.attrSegmentSpan(self, binding.path[0]);
        const name_id = try self.intern.intern(name);
        try emit.emitOp(self, .push_null);
        try emit.emitOp(self, .make_cell);
        const slot = try scope.declareLocal(self, name, name_id);
        try emit.emitSetLocal(self, slot);
    }

    for (let_in.bindings, 0..) |binding, index| {
        if (bindingRootSeen(self, let_in.bindings[0..index], binding.path[0])) continue;
        const name = attrs.attrSegmentSpan(self, binding.path[0]);
        const slot = scope.resolveLocal(self, name) orelse return error.UndefinedVariable;
        try compileLetRootBinding(self, let_in.bindings, binding.path[0], slot);
        try emit.emitSetCellLocal(self, slot);
    }

    if (tail_body) {
        try compileTailExpression(self, let_in.body);
    } else {
        try self.compileNode(let_in.body);
    }

    scope.endScope(self);
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
