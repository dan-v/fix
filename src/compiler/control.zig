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

pub fn compileIfElse(self: *Compiler, node: *const Node) !void {
    try self.compileIfElseBody(node, false);
}

pub fn compileIfElseTail(self: *Compiler, node: *const Node) anyerror!void {
    try self.compileIfElseBody(node, true);
}

pub fn compileIfElseBody(self: *Compiler, node: *const Node, tail_branches: bool) anyerror!void {
    const ife = node.data.if_else;

    try self.compileNode(ife.cond);

    // Emit placeholder for jump_if_false
    const jump_pos = self.builder.code.items.len;
    try self.emitOpU32(.jump_if_false, 0);
    try self.emitOp(.pop);

    if (tail_branches) {
        try self.compileTailExpression(ife.then_branch);
    } else {
        try self.compileNode(ife.then_branch);
    }
    const jump_over_pos = self.builder.code.items.len;
    try self.emitOpU32(.jump, 0);

    // Patch jump_if_false target
    self.patchJump(jump_pos, self.builder.code.items.len);

    try self.emitOp(.pop);
    if (tail_branches) {
        try self.compileTailExpression(ife.else_branch);
    } else {
        try self.compileNode(ife.else_branch);
    }

    // Patch jump (skip else)
    self.patchJump(jump_over_pos, self.builder.code.items.len);
}

pub fn compileAssert(self: *Compiler, node: *const Node) !void {
    try self.compileAssertBody(node, false);
}

pub fn compileAssertTail(self: *Compiler, node: *const Node) anyerror!void {
    try self.compileAssertBody(node, true);
}

pub fn compileAssertBody(self: *Compiler, node: *const Node, tail_body: bool) anyerror!void {
    const assert_node = node.data.assert;

    try self.compileNode(assert_node.cond);

    const fail_jump = self.builder.code.items.len;
    try self.emitOpU32(.jump_if_false, 0);
    try self.emitOp(.pop);

    if (tail_body) {
        try self.compileTailExpression(assert_node.body);
    } else {
        try self.compileNode(assert_node.body);
    }
    const end_jump = self.builder.code.items.len;
    try self.emitOpU32(.jump, 0);

    self.patchJump(fail_jump, self.builder.code.items.len);
    try self.emitOp(.pop);
    try self.emitOp(.fail_assertion);

    self.patchJump(end_jump, self.builder.code.items.len);
}

pub fn compileWith(self: *Compiler, node: *const Node) !void {
    try self.compileWithBody(node, false);
}

pub fn compileWithTail(self: *Compiler, node: *const Node) anyerror!void {
    try self.compileWithBody(node, true);
}

pub fn compileWithBody(self: *Compiler, node: *const Node, tail_body: bool) anyerror!void {
    const with_node = node.data.with_expr;

    self.beginScope();

    const scope_slot = try self.declareLocal("", try self.intern.intern(""));
    try self.compileThunk(with_node.attr_set);
    try self.emitSetLocal(scope_slot);
    try self.with_scopes.append(self.allocator, .{ .kind = .local, .index = scope_slot });

    if (tail_body) {
        try self.compileTailExpression(with_node.body);
    } else {
        try self.compileNode(with_node.body);
    }

    _ = self.with_scopes.pop();
    self.endScope();
}
