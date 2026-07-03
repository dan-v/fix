const std = @import("std");
const compiler_mod = @import("../compiler.zig");
const ast = @import("syntax").ast;
const bytecode = @import("../bytecode.zig");
const builtins = @import("runtime").builtins;
const chunk = bytecode.chunk;
const diagnostic = @import("syntax").diagnostic;
const heap_mod = @import("runtime").heap;
const string_syntax = @import("syntax").string_syntax;
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const OpCode = bytecode.OpCode;
const emit = @import("emit.zig");
const scope = @import("scope.zig");
const thunks = @import("thunks.zig");
const ops = @import("ops.zig");

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

pub fn compileIfElse(self: *Compiler, node: *const Node) !void {
    try compileIfElseBody(self, node, false);
}

pub fn compileIfElseTail(self: *Compiler, node: *const Node) anyerror!void {
    try compileIfElseBody(self, node, true);
}

pub fn compileIfElseBody(self: *Compiler, node: *const Node, tail_branches: bool) anyerror!void {
    const ife = node.data.if_else;

    try self.compileNode(ife.cond);

    // Emit placeholder for jump_if_false
    const jump_pos = self.builder.code.items.len;
    try emit.emitOpU32(self, .jump_if_false, 0);
    try emit.emitOp(self, .pop);

    if (tail_branches) {
        try ops.compileTailExpression(self, ife.then_branch);
    } else {
        try self.compileNode(ife.then_branch);
    }
    const jump_over_pos = self.builder.code.items.len;
    try emit.emitOpU32(self, .jump, 0);

    // Patch jump_if_false target
    emit.patchJump(self, jump_pos, self.builder.code.items.len);

    try emit.emitOp(self, .pop);
    if (tail_branches) {
        try ops.compileTailExpression(self, ife.else_branch);
    } else {
        try self.compileNode(ife.else_branch);
    }

    // Patch jump (skip else)
    emit.patchJump(self, jump_over_pos, self.builder.code.items.len);
}

pub fn compileAssert(self: *Compiler, node: *const Node) !void {
    try compileAssertBody(self, node, false);
}

pub fn compileAssertTail(self: *Compiler, node: *const Node) anyerror!void {
    try compileAssertBody(self, node, true);
}

pub fn compileAssertBody(self: *Compiler, node: *const Node, tail_body: bool) anyerror!void {
    const assert_node = node.data.assert;

    try self.compileNode(assert_node.cond);

    const fail_jump = self.builder.code.items.len;
    try emit.emitOpU32(self, .jump_if_false, 0);
    try emit.emitOp(self, .pop);

    if (tail_body) {
        try ops.compileTailExpression(self, assert_node.body);
    } else {
        try self.compileNode(assert_node.body);
    }
    const end_jump = self.builder.code.items.len;
    try emit.emitOpU32(self, .jump, 0);

    emit.patchJump(self, fail_jump, self.builder.code.items.len);
    try emit.emitOp(self, .pop);
    try emit.emitOp(self, .fail_assertion);

    emit.patchJump(self, end_jump, self.builder.code.items.len);
}

pub fn compileWith(self: *Compiler, node: *const Node) !void {
    try compileWithBody(self, node, false);
}

pub fn compileWithTail(self: *Compiler, node: *const Node) anyerror!void {
    try compileWithBody(self, node, true);
}

pub fn compileWithBody(self: *Compiler, node: *const Node, tail_body: bool) anyerror!void {
    const with_node = node.data.with_expr;

    scope.beginScope(self);

    const scope_slot = try scope.declareLocal(self, "", try self.intern.intern(""));
    try thunks.compileThunk(self, with_node.attr_set);
    try emit.emitSetLocal(self, scope_slot);
    try self.with_scopes.append(self.allocator, .{ .kind = .local, .index = scope_slot });

    if (tail_body) {
        try ops.compileTailExpression(self, with_node.body);
    } else {
        try self.compileNode(with_node.body);
    }

    _ = self.with_scopes.pop();
    scope.endScope(self);
}

const fix = @import("../root.zig");
const Evaluator = fix.Evaluator;

test "if-else selects the matching branch" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    const then_arm = try ev.evaluate("if 1 == 1 then \"yes\" else \"no\"");
    try std.testing.expectEqualStrings("yes", ev.intern.get(then_arm.asInternId()));

    const else_arm = try ev.evaluate("if 1 == 2 then \"yes\" else \"no\"");
    try std.testing.expectEqualStrings("no", ev.intern.get(else_arm.asInternId()));
}

test "assert passes through the body when the condition holds" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    const result = try ev.evaluate("assert 1 + 1 == 2; 42");
    try std.testing.expectEqual(@as(i64, 42), result.asInt());
}

test "assert raises an error when the condition fails" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    try std.testing.expectError(error.AssertionFailed, ev.evaluate("assert 1 == 2; 42"));
}

test "with brings an attribute set's names into scope" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    const result = try ev.evaluate("with { a = 1; b = 2; }; a + b");
    try std.testing.expectEqual(@as(i64, 3), result.asInt());
}

test "an inner with shadows an outer with for the same name" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    const result = try ev.evaluate("with { a = 1; }; with { a = 2; }; a");
    try std.testing.expectEqual(@as(i64, 2), result.asInt());
}
