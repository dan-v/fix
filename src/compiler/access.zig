const std = @import("std");
const compiler_mod = @import("../compiler.zig");
const ast = @import("syntax").ast;
const bytecode = @import("../bytecode.zig");
const builtins = @import("../builtins.zig");
const chunk = bytecode.chunk;
const diagnostic = @import("syntax").diagnostic;
const heap_mod = @import("../runtime/heap.zig");
const string_syntax = @import("syntax").string_syntax;
const types = @import("../runtime/types.zig");
const Value = @import("../runtime/value.zig").Value;
const OpCode = bytecode.OpCode;
const emit = @import("emit.zig");
const scope = @import("scope.zig");
const thunks = @import("thunks.zig");
const diagnostics = @import("diagnostics.zig");
const attrs = @import("attrs.zig");
const literals = @import("literals.zig");

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
const diagnostic_atom = @import("diagnostic_atom.zig");
const diagnosticAtom = diagnostic_atom.diagnosticAtom;
const attrPathDiagnosticAtom = diagnostic_atom.attrPathDiagnosticAtom;
const hasAttrDiagnosticAtom = diagnostic_atom.hasAttrDiagnosticAtom;
const hasAttrMixedDiagnosticAtom = diagnostic_atom.hasAttrMixedDiagnosticAtom;
const unwrapParens = ast.unwrapParens;

pub fn compileAttrPath(self: *Compiler, node: *const Node) !void {
    const apath = node.data.attr_path;
    try self.compileNode(apath.root);

    for (apath.segments) |seg| {
        if (attrs.attrSegmentHasInterpolation(self, seg)) {
            try literals.compileStringAtom(self, seg);
            try emit.emitOp(self, .get_attr_dynamic);
        } else {
            const name_id = try attrs.attrSegmentNameId(self, seg);
            try emit.emitGetAttr(self, name_id);
        }
    }
}

pub fn compileAttrDynamic(self: *Compiler, node: *const Node) !void {
    const dynamic = node.data.attr_dynamic;
    try self.compileNode(dynamic.root);
    try self.compileNode(dynamic.name);
    try emit.emitOp(self, .get_attr_dynamic);
}

pub fn compileAttrOr(self: *Compiler, node: *const Node) !void {
    const attr_or = node.data.attr_or;
    if (attr_or.attr_path.tag == .attr_dynamic) {
        const dynamic = attr_or.attr_path.data.attr_dynamic;
        if (dynamic.root.tag == .attr_path) {
            const root_path = dynamic.root.data.attr_path;
            try self.compileNode(root_path.root);
            try thunks.compileThunk(self, dynamic.name);
            try thunks.compileThunk(self, attr_or.default);
            const wide = try emit.attrSegmentsWide(self, root_path.segments);
            try emit.emitOp(self, if (wide) .get_attr_path_dynamic_or_long else .get_attr_path_dynamic_or);
            try emit.writeStaticAttrPathOperand(self, root_path.segments, attrPathDiagnosticAtom(root_path), wide);
            return;
        }
        try self.compileNode(dynamic.root);
        try thunks.compileThunk(self, dynamic.name);
        try thunks.compileThunk(self, attr_or.default);
        try emit.emitOp(self, .get_attr_dynamic_or);
        return;
    }

    const apath = attr_or.attr_path.data.attr_path;
    if (attrPathHasInterpolation(self, apath)) {
        try self.compileNode(apath.root);
        var dynamic_count: usize = 0;
        for (apath.segments) |seg| {
            if (attrs.attrSegmentHasInterpolation(self, seg)) {
                try thunks.compileStringAtomThunk(self, seg);
                dynamic_count += 1;
            }
        }
        try thunks.compileThunk(self, attr_or.default);
        try emit.emitOp(self, .get_attr_path_mixed_or);
        try emit.writeMixedAttrPathOperand(self, apath.segments, dynamic_count, attrPathDiagnosticAtom(apath));
        return;
    }

    try self.compileNode(apath.root);
    try thunks.compileThunk(self, attr_or.default);
    const wide = try emit.attrSegmentsWide(self, apath.segments);
    try emit.emitOp(self, if (wide) .get_attr_path_or_long else .get_attr_path_or);
    try emit.writeStaticAttrPathOperand(self, apath.segments, attrPathDiagnosticAtom(apath), wide);
}

pub fn attrPathHasInterpolation(self: *Compiler, path: Node.AttrPath) bool {
    for (path.segments) |seg| {
        if (attrs.attrSegmentHasInterpolation(self, seg)) return true;
    }
    return false;
}

pub fn compileHasAttr(self: *Compiler, node: *const Node) !void {
    const has_attr = node.data.has_attr;
    try self.compileNode(has_attr.root);
    if (hasAttrSegmentsHaveInterpolation(self, has_attr.segments)) {
        var dynamic_count: usize = 0;
        for (has_attr.segments) |seg| {
            if (attrs.attrSegmentHasInterpolation(self, seg)) {
                try thunks.compileStringAtomThunk(self, seg);
                dynamic_count += 1;
            }
        }
        try emit.emitOp(self, .has_attr_path_mixed);
        try emit.writeMixedAttrPathOperand(self, has_attr.segments, dynamic_count, hasAttrDiagnosticAtom(has_attr));
        return;
    }

    const wide = try emit.attrSegmentsWide(self, has_attr.segments);
    try emit.emitOp(self, if (wide) .has_attr_path_long else .has_attr_path);
    try emit.writeStaticAttrPathOperand(self, has_attr.segments, hasAttrDiagnosticAtom(has_attr), wide);
}

pub fn compileHasAttrDynamic(self: *Compiler, node: *const Node) !void {
    const dynamic = node.data.has_attr_dynamic;
    try self.compileNode(dynamic.root);
    try self.compileNode(dynamic.name);
    try emit.emitOp(self, .has_attr_dynamic);
}

pub fn compileHasAttrMixed(self: *Compiler, node: *const Node) !void {
    const has_attr = node.data.has_attr_mixed;
    try self.compileNode(has_attr.root);
    var dynamic_count: usize = 0;
    for (has_attr.segments) |segment| {
        switch (segment) {
            .static => |atom| {
                if (attrs.attrSegmentHasInterpolation(self, atom)) {
                    try thunks.compileStringAtomThunk(self, atom);
                    dynamic_count += 1;
                }
            },
            .dynamic => |name| {
                try thunks.compileThunk(self, name);
                dynamic_count += 1;
            },
        }
    }

    try emit.emitOp(self, .has_attr_path_mixed);
    try emit.writeHasAttrMixedOperand(self, has_attr.segments, dynamic_count, hasAttrMixedDiagnosticAtom(has_attr));
}

pub fn hasAttrSegmentsHaveInterpolation(self: *Compiler, segments: []const Node.Atom) bool {
    for (segments) |segment| {
        if (attrs.attrSegmentHasInterpolation(self, segment)) return true;
    }
    return false;
}

pub fn compileList(self: *Compiler, node: *const Node) !void {
    const list = node.data.list;
    for (list.items) |item| {
        try compileContainerValue(self, item, .{ .raw_identifier = true });
    }
    try emit.emitOpU16(self, .build_list, try diagnostics.requireU16At(self, list.items.len, diagnosticAtom(node), "too many list items"));
}

pub fn compileContainerValue(self: *Compiler, node: *const Node, options: ContainerValueOptions) !void {
    if (try compileImmediateContainerValue(self, node, options)) return;
    try thunks.compileThunkEager(self, node, options.eager);
}

/// Predicate version of `compileImmediateContainerValue` for the
/// pure-literal cases. Mirrors the branches above that don't depend
/// on scope state — useful for compile-time decisions about whether
/// a binding's RHS needs a lazy cell at all.
pub fn isLiteralContainerValue(self: *Compiler, node: *const Node) bool {
    const unwrapped = unwrapParens(node);
    return switch (unwrapped.tag) {
        .integer, .float_val, .bool_true, .bool_false, .null => true,
        .string => !stringHasInterpolation(self, unwrapped),
        .path => !pathHasInterpolation(self, unwrapped),
        .list => unwrapped.data.list.items.len == 0,
        else => false,
    };
}

pub fn compileImmediateContainerValue(self: *Compiler, node: *const Node, options: ContainerValueOptions) anyerror!bool {
    const unwrapped = unwrapParens(node);
    switch (unwrapped.tag) {
        .integer => try literals.compileInt(self, unwrapped),
        .float_val => try literals.compileFloat(self, unwrapped),
        .string => {
            if (stringHasInterpolation(self, unwrapped)) return false;
            try literals.compileString(self, unwrapped);
        },
        .path => {
            if (pathHasInterpolation(self, unwrapped)) return false;
            try literals.compilePath(self, unwrapped);
        },
        .bool_true => try emit.emitOp(self, .push_true),
        .bool_false => try emit.emitOp(self, .push_false),
        .null => try emit.emitOp(self, .push_null),
        .list => {
            if (unwrapped.data.list.items.len == 0) {
                try emit.emitOpU16(self, .build_list, 0);
            } else {
                // Build the list shell in place, then wrap in a
                // pre-resolved "lazy shell" thunk. Forcing it in the
                // future is O(1) (resolved fast path); XML lazy mode
                // still prints `<unevaluated />` until a real
                // consumer marks it demanded, matching the
                // observable laziness of a true thunk-wrapped list.
                try compileList(self, unwrapped);
                try emit.emitOp(self, .make_lazy_shell);
            }
        },
        .attr_set => {
            // Only inline in eager let-binding context (set by
            // compileLetRootBinding when strictness says forced).
            // Other contexts — attrset-entry values, function
            // arguments — break NixOS module fix-points if their
            // attrset values are eagerly compiled into the parent's
            // chunk scope. The eager let-binding path is safe
            // because strictness already guarantees the binding
            // gets forced before any consumer might observe a
            // fix-point race.
            if (!options.eager) return false;
            if (unwrapped.data.attr_set.recursive) return false;
            try @import("attrs.zig").compileAttrSet(self, unwrapped);
            try emit.emitOp(self, .make_lazy_shell);
        },
        .lambda => {
            try @import("ops.zig").compileLambda(self, unwrapped);
            try emit.emitOp(self, .make_lazy_shell);
        },
        .lambda_attrs => {
            try @import("ops.zig").compileLambdaAttrs(self, unwrapped);
            try emit.emitOp(self, .make_lazy_shell);
        },
        .identifier => {
            if (!options.raw_identifier) return false;
            if (!try compileRawIdent(self, unwrapped)) return false;
        },
        else => return false,
    }
    return true;
}

pub fn compileRawIdent(self: *Compiler, node: *const Node) !bool {
    const span = self.source[node.data.atom.offset .. node.data.atom.offset + node.data.atom.len];
    const name_id = try self.intern.intern(span);
    if (scope.resolveLocalId(self, name_id)) |slot| {
        try emit.emitCaptureLocal(self, slot);
        return true;
    }
    if (try scope.resolveCaptureId(self, span, name_id)) |slot| {
        try emit.emitOpU16(self, .capture_upvalue, slot);
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
