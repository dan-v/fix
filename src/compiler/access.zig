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

pub fn compileAttrPath(self: *Compiler, node: *const Node) !void {
    const apath = node.data.attr_path;
    try self.compileNode(apath.root);

    for (apath.segments) |seg| {
        if (self.attrSegmentHasInterpolation(seg)) {
            try self.compileStringAtom(seg);
            try self.emitOp(.get_attr_dynamic);
        } else {
            const name_id = try self.attrSegmentNameId(seg);
            try self.emitInternOp(.get_attr, .get_attr_long, name_id);
        }
    }
}

pub fn compileAttrDynamic(self: *Compiler, node: *const Node) !void {
    const dynamic = node.data.attr_dynamic;
    try self.compileNode(dynamic.root);
    try self.compileNode(dynamic.name);
    try self.emitOp(.get_attr_dynamic);
}

pub fn compileAttrOr(self: *Compiler, node: *const Node) !void {
    const attr_or = node.data.attr_or;
    if (attr_or.attr_path.tag == .attr_dynamic) {
        const dynamic = attr_or.attr_path.data.attr_dynamic;
        if (dynamic.root.tag == .attr_path) {
            const root_path = dynamic.root.data.attr_path;
            try self.compileNode(root_path.root);
            try self.compileThunk(dynamic.name);
            try self.compileThunk(attr_or.default);
            const wide = try self.attrSegmentsWide(root_path.segments);
            try self.emitOp(if (wide) .get_attr_path_dynamic_or_long else .get_attr_path_dynamic_or);
            try self.writeStaticAttrPathOperand(root_path.segments, attrPathDiagnosticAtom(root_path), wide);
            return;
        }
        try self.compileNode(dynamic.root);
        try self.compileThunk(dynamic.name);
        try self.compileThunk(attr_or.default);
        try self.emitOp(.get_attr_dynamic_or);
        return;
    }

    const apath = attr_or.attr_path.data.attr_path;
    if (self.attrPathHasInterpolation(apath)) {
        try self.compileNode(apath.root);
        var dynamic_count: usize = 0;
        for (apath.segments) |seg| {
            if (self.attrSegmentHasInterpolation(seg)) {
                try self.compileStringAtomThunk(seg);
                dynamic_count += 1;
            }
        }
        try self.compileThunk(attr_or.default);
        try self.emitOp(.get_attr_path_mixed_or);
        try self.writeMixedAttrPathOperand(apath.segments, dynamic_count, attrPathDiagnosticAtom(apath));
        return;
    }

    try self.compileNode(apath.root);
    try self.compileThunk(attr_or.default);
    const wide = try self.attrSegmentsWide(apath.segments);
    try self.emitOp(if (wide) .get_attr_path_or_long else .get_attr_path_or);
    try self.writeStaticAttrPathOperand(apath.segments, attrPathDiagnosticAtom(apath), wide);
}

pub fn attrPathHasInterpolation(self: *Compiler, path: Node.AttrPath) bool {
    for (path.segments) |seg| {
        if (self.attrSegmentHasInterpolation(seg)) return true;
    }
    return false;
}

pub fn compileHasAttr(self: *Compiler, node: *const Node) !void {
    const has_attr = node.data.has_attr;
    try self.compileNode(has_attr.root);
    if (self.hasAttrSegmentsHaveInterpolation(has_attr.segments)) {
        var dynamic_count: usize = 0;
        for (has_attr.segments) |seg| {
            if (self.attrSegmentHasInterpolation(seg)) {
                try self.compileStringAtomThunk(seg);
                dynamic_count += 1;
            }
        }
        try self.emitOp(.has_attr_path_mixed);
        try self.writeMixedAttrPathOperand(has_attr.segments, dynamic_count, hasAttrDiagnosticAtom(has_attr));
        return;
    }

    const wide = try self.attrSegmentsWide(has_attr.segments);
    try self.emitOp(if (wide) .has_attr_path_long else .has_attr_path);
    try self.writeStaticAttrPathOperand(has_attr.segments, hasAttrDiagnosticAtom(has_attr), wide);
}

pub fn compileHasAttrDynamic(self: *Compiler, node: *const Node) !void {
    const dynamic = node.data.has_attr_dynamic;
    try self.compileNode(dynamic.root);
    try self.compileNode(dynamic.name);
    try self.emitOp(.has_attr_dynamic);
}

pub fn compileHasAttrMixed(self: *Compiler, node: *const Node) !void {
    const has_attr = node.data.has_attr_mixed;
    try self.compileNode(has_attr.root);
    var dynamic_count: usize = 0;
    for (has_attr.segments) |segment| {
        switch (segment) {
            .static => |atom| {
                if (self.attrSegmentHasInterpolation(atom)) {
                    try self.compileStringAtomThunk(atom);
                    dynamic_count += 1;
                }
            },
            .dynamic => |name| {
                try self.compileThunk(name);
                dynamic_count += 1;
            },
        }
    }

    try self.emitOp(.has_attr_path_mixed);
    try self.writeHasAttrMixedOperand(has_attr.segments, dynamic_count, hasAttrMixedDiagnosticAtom(has_attr));
}

pub fn hasAttrSegmentsHaveInterpolation(self: *Compiler, segments: []const Node.Atom) bool {
    for (segments) |segment| {
        if (self.attrSegmentHasInterpolation(segment)) return true;
    }
    return false;
}

pub fn compileList(self: *Compiler, node: *const Node) !void {
    const list = node.data.list;
    for (list.items) |item| {
        try self.compileContainerValue(item, .{ .raw_identifier = true });
    }
    try self.emitOpU16(.build_list, try self.requireU16At(list.items.len, diagnosticAtom(node), "too many list items"));
}

pub fn compileContainerValue(self: *Compiler, node: *const Node, options: ContainerValueOptions) !void {
    if (try self.compileImmediateContainerValue(node, options)) return;
    try self.compileThunk(node);
}

pub fn compileImmediateContainerValue(self: *Compiler, node: *const Node, options: ContainerValueOptions) !bool {
    const unwrapped = unwrapParens(node);
    switch (unwrapped.tag) {
        .integer => try self.compileInt(unwrapped),
        .float_val => try self.compileFloat(unwrapped),
        .string => {
            if (self.stringHasInterpolation(unwrapped)) return false;
            try self.compileString(unwrapped);
        },
        .path => {
            if (self.pathHasInterpolation(unwrapped)) return false;
            try self.compilePath(unwrapped);
        },
        .bool_true => try self.emitOp(.push_true),
        .bool_false => try self.emitOp(.push_false),
        .null => try self.emitOp(.push_null),
        .list => {
            if (unwrapped.data.list.items.len != 0) return false;
            try self.emitOpU16(.build_list, 0);
        },
        .identifier => {
            if (!options.raw_identifier) return false;
            if (!try self.compileRawIdent(unwrapped)) return false;
        },
        else => return false,
    }
    return true;
}

pub fn compileRawIdent(self: *Compiler, node: *const Node) !bool {
    const span = self.source[node.data.atom.offset .. node.data.atom.offset + node.data.atom.len];
    if (self.resolveLocal(span)) |slot| {
        try self.emitCaptureLocal(slot);
        return true;
    }
    if (try self.resolveCapture(span)) |slot| {
        try self.emitOpU16(.capture_upvalue, slot);
        return true;
    }
    return false;
}

pub fn stringHasInterpolation(self: *Compiler, node: *const Node) bool {
    const atom = node.data.atom;
    const span = self.source[atom.offset .. atom.offset + atom.len];
    return std.mem.indexOf(u8, span, "${") != null;
}

pub fn pathHasInterpolation(self: *Compiler, node: *const Node) bool {
    const atom = node.data.atom;
    const span = self.source[atom.offset .. atom.offset + atom.len];
    return std.mem.indexOf(u8, span, "${") != null;
}
