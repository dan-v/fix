const std = @import("std");
const compiler_mod = @import("../compiler.zig");
const ast = @import("../ast.zig");
const bytecode = @import("../bytecode.zig");
const builtins = @import("../builtins.zig");
const chunk = @import("../chunk.zig");
const diagnostic = @import("../diagnostic.zig");
const heap_mod = @import("../heap.zig");
const string_syntax = @import("../string_syntax.zig");
const types = @import("../types.zig");
const Value = @import("../value.zig").Value;
const OpCode = @import("../opcode.zig").OpCode;

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
const attrEntriesDiagnosticAtom = compiler_mod.attrEntriesDiagnosticAtom;
const attrGroupsDiagnosticAtom = compiler_mod.attrGroupsDiagnosticAtom;
const attrPathDiagnosticAtom = compiler_mod.attrPathDiagnosticAtom;
const captureCount = compiler_mod.captureCount;
const diagnosticAtom = compiler_mod.diagnosticAtom;
const hasAttrDiagnosticAtom = compiler_mod.hasAttrDiagnosticAtom;
const hasAttrMixedDiagnosticAtom = compiler_mod.hasAttrMixedDiagnosticAtom;
const nodeMayEvaluateToFloat = compiler_mod.nodeMayEvaluateToFloat;
const nodeSourceSpan = compiler_mod.nodeSourceSpan;
const offsetNode = compiler_mod.offsetNode;
const u16Count = compiler_mod.u16Count;
const unwrapParens = compiler_mod.unwrapParens;

pub fn compileBinary(self: *Compiler, node: *const Node) !void {
    const bin = node.data.binary;
    switch (bin.op) {
        .and_ => return self.compileAnd(bin.left, bin.right),
        .or_ => return self.compileOr(bin.left, bin.right),
        .impl => return self.compileImpl(bin.left, bin.right),
        else => {},
    }

    try self.compileNode(bin.left);
    try self.compileNode(bin.right);

    switch (bin.op) {
        .add => try self.emitOp(if (nodeMayEvaluateToFloat(bin.left) or nodeMayEvaluateToFloat(bin.right)) .add_float else .add_int),
        .sub => try self.emitOp(if (nodeMayEvaluateToFloat(bin.left) or nodeMayEvaluateToFloat(bin.right)) .sub_float else .sub_int),
        .mul => try self.emitOp(if (nodeMayEvaluateToFloat(bin.left) or nodeMayEvaluateToFloat(bin.right)) .mul_float else .mul_int),
        .div => try self.emitOp(if (nodeMayEvaluateToFloat(bin.left) or nodeMayEvaluateToFloat(bin.right)) .div_float else .div_int),
        .eq => try self.emitOp(.eq),
        .neq => try self.emitOp(.neq),
        .lt => try self.emitOp(.lt),
        .lte => try self.emitOp(.lte),
        .gt => try self.emitOp(.gt),
        .gte => try self.emitOp(.gte),
        .and_, .or_ => unreachable,
        .update => try self.emitOp(.merge_attrs),
        .impl => unreachable,
        .concat => try self.emitOp(.concat_lists),
    }
}

pub fn compileAnd(self: *Compiler, left: *const Node, right: *const Node) !void {
    try self.compileNode(left);

    const end_jump = self.builder.code.items.len;
    try self.emitOpU32(.jump_if_false, 0);
    try self.emitOp(.pop);

    try self.compileNode(right);
    self.patchJump(end_jump, self.builder.code.items.len);
}

pub fn compileOr(self: *Compiler, left: *const Node, right: *const Node) !void {
    try self.compileNode(left);

    const false_jump = self.builder.code.items.len;
    try self.emitOpU32(.jump_if_false, 0);

    const end_jump = self.builder.code.items.len;
    try self.emitOpU32(.jump, 0);

    self.patchJump(false_jump, self.builder.code.items.len);
    try self.emitOp(.pop);

    try self.compileNode(right);
    self.patchJump(end_jump, self.builder.code.items.len);
}

pub fn compileImpl(self: *Compiler, left: *const Node, right: *const Node) !void {
    try self.compileNode(left);

    const false_jump = self.builder.code.items.len;
    try self.emitOpU32(.jump_if_false, 0);
    try self.emitOp(.pop);

    try self.compileNode(right);
    const end_jump = self.builder.code.items.len;
    try self.emitOpU32(.jump, 0);

    self.patchJump(false_jump, self.builder.code.items.len);
    try self.emitOp(.pop);
    try self.emitOp(.push_true);

    self.patchJump(end_jump, self.builder.code.items.len);
}

pub fn compileUnary(self: *Compiler, node: *const Node) !void {
    const un = node.data.unary;
    try self.compileNode(un.expr);
    switch (un.op) {
        .negate => try self.emitOp(.negate_int),
        .not => try self.emitOp(.not),
    }
}

pub fn compileApply(self: *Compiler, node: *const Node) !void {
    try self.compileApplyWithOp(node, .call);
}

pub fn compileTailExpression(self: *Compiler, node: *const Node) anyerror!void {
    const unwrapped = unwrapParens(node);
    switch (unwrapped.tag) {
        .apply, .if_else, .let_in, .assert, .with_expr => {},
        else => return self.compileNode(node),
    }

    {
        const start = self.builder.code.items.len;
        try self.compileTailNodeImpl(unwrapped);
        const end = self.builder.code.items.len;
        if (try self.sourceSpanForNode(node)) |span| {
            try self.builder.addSourceMapEntry(self.allocator, start, end, span);
        }
        return;
    }
}

pub fn compileTailNodeImpl(self: *Compiler, node: *const Node) anyerror!void {
    switch (node.tag) {
        .apply => try self.compileApplyWithOp(node, .tail_call),
        .if_else => try self.compileIfElseTail(node),
        .let_in => try self.compileLetInWithTailBody(node),
        .assert => try self.compileAssertTail(node),
        .with_expr => try self.compileWithTail(node),
        else => unreachable,
    }
}

pub fn compileApplyWithOp(self: *Compiler, node: *const Node, op: OpCode) !void {
    const ap = node.data.apply;
    try self.compileNode(ap.func);
    try self.compileContainerValue(ap.arg, .{});
    try self.emitOp(op);
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
    _ = try child.declareLocal(param_name, param_id);
    child.compileTailExpression(lambda.body) catch |err| {
        try self.absorbChildDiagnostics(&child);
        return err;
    };
    try child.emitOp(.ret);
    try child.emitOp(.halt);

    const child_chunk = try child_builder.finish(self.allocator, child.slot_count);
    const child_id = try self.registry.register(child_chunk);
    try self.emitClosureWithCaptures(child_id, child.captures.items);
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

    const arg_slot = try child.declareLocal("\x00args", try self.intern.intern("\x00args"));
    if (lambda.bind_name) |bind_name| {
        const name = self.source[bind_name.offset .. bind_name.offset + bind_name.len];
        const name_id = try self.intern.intern(name);
        const slot = try child.declareLocal(name, name_id);
        try child.emitCaptureLocal(arg_slot);
        try child.emitSetLocal(slot);
    }

    var wide_params = false;
    for (lambda.params) |param| {
        const name = self.source[param.name.offset .. param.name.offset + param.name.len];
        if (try self.intern.intern(name) > std.math.maxInt(u16)) wide_params = true;
    }

    try child.emitGetLocal(arg_slot);
    try child.emitOp(if (wide_params) .validate_attrs_long else .validate_attrs);
    try child.builder.writeByte(child.allocator, if (lambda.allow_extra) 1 else 0);
    const param_count = try self.requireU16At(lambda.params.len, diagnosticAtom(node), "too many function parameters");
    try child.builder.writeU16(child.allocator, param_count);
    var function_args: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer function_args.deinit(self.allocator);
    try function_args.ensureTotalCapacity(self.allocator, lambda.params.len);
    for (lambda.params) |param| {
        const name = self.source[param.name.offset .. param.name.offset + param.name.len];
        const name_id = try self.intern.intern(name);
        try child.writeInternId(name_id, wide_params);
        function_args.appendAssumeCapacity(.{
            .name = name_id,
            .value = Value.boolVal(param.default != null),
        });
    }
    try child_builder.setFunctionArgs(self.allocator, function_args.items);

    for (lambda.params) |param| {
        const name = self.source[param.name.offset .. param.name.offset + param.name.len];
        const name_id = try self.intern.intern(name);
        try child.emitOp(.push_null);
        try child.emitOp(.make_cell);
        const slot = try child.declareLocal(name, name_id);
        try child.emitSetLocal(slot);
    }

    for (lambda.params) |param| {
        const name = self.source[param.name.offset .. param.name.offset + param.name.len];
        const name_id = try self.intern.intern(name);
        const slot = child.resolveLocal(name) orelse return error.UndefinedVariable;
        try child.compileAttrParamThunk(arg_slot, name_id, param.default);
        try child.emitSetCellLocal(slot);
    }

    child.compileTailExpression(lambda.body) catch |err| {
        try self.absorbChildDiagnostics(&child);
        return err;
    };
    try child.emitOp(.ret);
    try child.emitOp(.halt);

    const child_chunk = try child_builder.finish(self.allocator, child.slot_count);
    const child_id = try self.registry.register(child_chunk);
    try self.emitClosureWithCaptures(child_id, child.captures.items);
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

    _ = try child.addCapture("\x00args", .local, arg_slot);
    try child.emitOpU16(.get_upvalue, 0);
    if (default) |default_expr| {
        try child.compileThunk(default_expr);
        try child.emitOp(if (name_id > std.math.maxInt(u16)) .get_attr_path_or_long else .get_attr_path_or);
        try child.builder.writeByte(child.allocator, 1);
        try child.writeInternId(name_id, name_id > std.math.maxInt(u16));
    } else {
        try child.emitInternOp(.get_attr, .get_attr_long, name_id);
    }
    try child.emitOp(.ret);
    try child.emitOp(.halt);

    const child_chunk = try child_builder.finish(self.allocator, child.slot_count);
    const child_id = try self.registry.register(child_chunk);
    try self.emitThunkWithCaptures(child_id, child.captures.items);
}

pub fn compileLetIn(self: *Compiler, node: *const Node) !void {
    try self.compileLetInBody(node, false);
}

pub fn compileLetInWithTailBody(self: *Compiler, node: *const Node) anyerror!void {
    try self.compileLetInBody(node, true);
}

pub fn compileLetInBody(self: *Compiler, node: *const Node, tail_body: bool) anyerror!void {
    const let_in = node.data.let_in;

    self.beginScope();

    for (let_in.bindings, 0..) |binding, index| {
        if (self.bindingRootSeen(let_in.bindings[0..index], binding.path[0])) continue;
        const name = self.attrSegmentSpan(binding.path[0]);
        const name_id = try self.intern.intern(name);
        try self.emitOp(.push_null);
        try self.emitOp(.make_cell);
        const slot = try self.declareLocal(name, name_id);
        try self.emitSetLocal(slot);
    }

    for (let_in.bindings, 0..) |binding, index| {
        if (self.bindingRootSeen(let_in.bindings[0..index], binding.path[0])) continue;
        const name = self.attrSegmentSpan(binding.path[0]);
        const slot = self.resolveLocal(name) orelse return error.UndefinedVariable;
        try self.compileLetRootBinding(let_in.bindings, binding.path[0], slot);
        try self.emitSetCellLocal(slot);
    }

    if (tail_body) {
        try self.compileTailExpression(let_in.body);
    } else {
        try self.compileNode(let_in.body);
    }

    self.endScope();
}

pub fn compileLetRootBinding(self: *Compiler, bindings: []const Node.Binding, root: Node.Atom, slot: u16) !void {
    var leaf: ?Node.Binding = null;
    var tail_count: usize = 0;

    for (bindings) |binding| {
        if (!self.attrSegmentsEqual(binding.path[0], root)) continue;
        if (binding.path.len == 1) {
            if (leaf) |previous| {
                try self.reportCompileError(binding.name_offset, binding.name_len, "duplicate let binding");
                try self.reportCompileNote(previous.name_offset, previous.name_len, "first binding defined here");
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
        const compile_result = self.compileContainerValue(binding.expr, .{});
        self.skip_local_slot = previous_skip;
        return compile_result;
    }

    const tails = try self.allocator.alloc(AttrEntryView, tail_count);
    defer self.allocator.free(tails);
    var i: usize = 0;
    for (bindings) |binding| {
        if (!self.attrSegmentsEqual(binding.path[0], root) or binding.path.len == 1) continue;
        tails[i] = .{
            .path = binding.path[1..],
            .expr = binding.expr,
            .inherit_outer = binding.inherit_outer,
        };
        i += 1;
    }

    if (leaf) |root_leaf| {
        if (root_leaf.expr.tag != .attr_set) {
            try self.reportDuplicateAttribute(tails[0].path[0], root_leaf.path[0]);
            return error.DuplicateAttribute;
        }
        const leaves = [_]AttrEntryView{.{
            .path = root_leaf.path,
            .expr = root_leaf.expr,
            .inherit_outer = root_leaf.inherit_outer,
        }};
        return self.compileExtendedAttrSetLiteralThunk(&leaves, tails);
    }

    return self.compileAttrEntriesThunk(tails, true);
}

pub fn bindingRootSeen(self: *const Compiler, bindings: []const Node.Binding, root: Node.Atom) bool {
    for (bindings) |binding| {
        if (binding.path.len > 0 and self.attrSegmentsEqual(binding.path[0], root)) return true;
    }
    return false;
}
