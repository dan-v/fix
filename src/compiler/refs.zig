const std = @import("std");
const compiler_mod = @import("../compiler.zig");

const Compiler = compiler_mod.Compiler;
const Node = compiler_mod.Node;

/// Walk `node` and add every identifier name encountered to `out`,
/// including textual matches inside `${...}` interpolation in atoms.
/// Conservatively mirrors `nodeReferencesName`'s coverage — false
/// positives just keep cells (and bindings) around, never break
/// semantics.
pub fn collectReferencedNames(self: *Compiler, node: *const Node, out: *std.StringHashMapUnmanaged(void)) anyerror!void {
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
