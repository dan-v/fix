const std = @import("std");
const ast = @import("../ast.zig");
const compiler_types = @import("types.zig");

const Node = ast.Node;
const AttrEntryView = compiler_types.AttrEntryView;
const AttrEntryGroup = compiler_types.AttrEntryGroup;

pub fn captureCount(count: usize) !u16 {
    if (count > std.math.maxInt(u16)) return error.TooManyCaptures;
    return @intCast(count);
}

pub fn u16Count(count: usize) !u16 {
    if (count > std.math.maxInt(u16)) return error.BytecodeOperandTooLarge;
    return @intCast(count);
}

pub fn diagnosticAtom(node: *const Node) Node.Atom {
    return node.span orelse .{ .offset = 0, .len = 1 };
}

pub fn attrEntriesDiagnosticAtom(entries: []const AttrEntryView) Node.Atom {
    if (entries.len == 0) return .{ .offset = 0, .len = 1 };
    if (entries[0].path.len == 0) return diagnosticAtom(entries[0].expr);
    return entries[0].path[0];
}

pub fn attrGroupsDiagnosticAtom(groups: []const AttrEntryGroup) Node.Atom {
    if (groups.len == 0) return .{ .offset = 0, .len = 1 };
    return groups[0].first;
}

pub fn attrPathDiagnosticAtom(path: Node.AttrPath) Node.Atom {
    if (path.segments.len == 0) return diagnosticAtom(path.root);
    return path.segments[0];
}

pub fn hasAttrDiagnosticAtom(path: Node.HasAttr) Node.Atom {
    if (path.segments.len == 0) return diagnosticAtom(path.root);
    return path.segments[0];
}

pub fn hasAttrMixedDiagnosticAtom(path: Node.HasAttrMixed) Node.Atom {
    if (path.segments.len == 0) return diagnosticAtom(path.root);
    return switch (path.segments[0]) {
        .static => |atom| atom,
        .dynamic => |node| diagnosticAtom(node),
    };
}

pub fn nodeMayEvaluateToFloat(node: *const Node) bool {
    return switch (node.tag) {
        .float_val => true,
        .parens => nodeMayEvaluateToFloat(node.data.parens),
        .unary_op => nodeMayEvaluateToFloat(node.data.unary.expr),
        .binary_op => switch (node.data.binary.op) {
            .add, .sub, .mul, .div => nodeMayEvaluateToFloat(node.data.binary.left) or
                nodeMayEvaluateToFloat(node.data.binary.right),
            else => false,
        },
        else => false,
    };
}

pub fn nodeSourceSpan(node: *const Node) ?Node.Atom {
    return node.span;
}

pub fn unwrapParens(node: *const Node) *const Node {
    var current = node;
    while (current.tag == .parens) current = current.data.parens;
    return current;
}

pub fn offsetNode(node: *Node, offset: u32) void {
    if (node.span) |*span| span.offset += offset;
    switch (node.tag) {
        .integer, .float_val, .string, .path, .search_path, .identifier, .bool_true, .bool_false, .null => {
            node.data.atom.offset += offset;
        },
        .unary_op => offsetNode(node.data.unary.expr, offset),
        .binary_op => {
            offsetNode(node.data.binary.left, offset);
            offsetNode(node.data.binary.right, offset);
        },
        .apply => {
            offsetNode(node.data.apply.func, offset);
            offsetNode(node.data.apply.arg, offset);
        },
        .lambda => {
            node.data.lambda.param_offset += offset;
            offsetNode(node.data.lambda.body, offset);
        },
        .lambda_attrs => {
            if (node.data.lambda_attrs.bind_name) |*bind_name| {
                bind_name.offset += offset;
            }
            for (node.data.lambda_attrs.params) |*param| {
                param.name.offset += offset;
                if (param.default) |default| offsetNode(default, offset);
            }
            offsetNode(node.data.lambda_attrs.body, offset);
        },
        .let_in => {
            for (node.data.let_in.bindings) |*binding| {
                binding.name_offset += offset;
                for (binding.path) |*segment| {
                    segment.offset += offset;
                }
                offsetNode(binding.expr, offset);
            }
            offsetNode(node.data.let_in.body, offset);
        },
        .if_else => {
            offsetNode(node.data.if_else.cond, offset);
            offsetNode(node.data.if_else.then_branch, offset);
            offsetNode(node.data.if_else.else_branch, offset);
        },
        .assert => {
            offsetNode(node.data.assert.cond, offset);
            offsetNode(node.data.assert.body, offset);
        },
        .with_expr => {
            offsetNode(node.data.with_expr.attr_set, offset);
            offsetNode(node.data.with_expr.body, offset);
        },
        .attr_set => {
            for (node.data.attr_set.entries) |*entry| {
                for (entry.path) |*segment| {
                    segment.offset += offset;
                }
                if (entry.dynamic_name) |dynamic_name| offsetNode(dynamic_name, offset);
                offsetNode(entry.expr, offset);
            }
        },
        .attr_path => {
            offsetNode(node.data.attr_path.root, offset);
            for (node.data.attr_path.segments) |*segment| {
                segment.offset += offset;
            }
        },
        .attr_dynamic => {
            offsetNode(node.data.attr_dynamic.root, offset);
            offsetNode(node.data.attr_dynamic.name, offset);
        },
        .attr_or => {
            offsetNode(node.data.attr_or.attr_path, offset);
            offsetNode(node.data.attr_or.default, offset);
        },
        .has_attr => {
            offsetNode(node.data.has_attr.root, offset);
            for (node.data.has_attr.segments) |*segment| {
                segment.offset += offset;
            }
        },
        .has_attr_dynamic => {
            offsetNode(node.data.has_attr_dynamic.root, offset);
            offsetNode(node.data.has_attr_dynamic.name, offset);
        },
        .has_attr_mixed => {
            offsetNode(node.data.has_attr_mixed.root, offset);
            for (node.data.has_attr_mixed.segments) |*segment| {
                switch (segment.*) {
                    .static => |*atom| atom.offset += offset,
                    .dynamic => |dynamic| offsetNode(dynamic, offset),
                }
            }
        },
        .list => {
            for (node.data.list.items) |item| {
                offsetNode(item, offset);
            }
        },
        .parens => offsetNode(node.data.parens, offset),
    }
}
