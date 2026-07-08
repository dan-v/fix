//! Selects the representative source atom (offset/len) to anchor a compile
//! diagnostic for each AST construct — attr entries, groups, paths, and
//! has-attr forms — falling back to the head span when a list is empty.

const ast = @import("syntax").ast;
const compiler_types = @import("types.zig");

const Node = ast.Node;
const AttrEntryView = compiler_types.AttrEntryView;
const AttrEntryGroup = compiler_types.AttrEntryGroup;

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
