//! Internal VM explorer component.
//!
//! Methods are parameterized by the private explorer state type and wired as
//! direct aliases by `operations.zig`; this module owns the behavior below.

const std = @import("std");
const engine = @import("expr");
const runtime = @import("runtime");
const width_mod = @import("../width.zig");
const vm_model = @import("model.zig");
const source_render = @import("../../source_render.zig");
const debugger = @import("../../debugger.zig");
const base = @import("base");
const tui = base.tui;
const Evaluator = engine.Evaluator;
const DebugSession = engine.DebugSession;
const ChunkId = runtime.types.ChunkId;
const bytecode = engine.bytecode;
const disasm = engine.bytecode.disasm;

const Category = vm_model.Category;
const HeapView = vm_model.HeapView;
const RowAction = vm_model.RowAction;
const Page = vm_model.Page;
const PageBuilder = vm_model.PageBuilder;
const Visit = vm_model.Visit;
const RangeKind = vm_model.RangeKind;
const ChunkEquivalence = vm_model.ChunkEquivalence;
const Range = vm_model.Range;
const TreeRow = vm_model.TreeRow;
const LineRange = vm_model.LineRange;
const NavigationState = vm_model.NavigationState;
const TreeState = vm_model.TreeState;
const HeapIndexState = vm_model.HeapIndexState;
const ReferenceIndexState = vm_model.ReferenceIndexState;
const Viewport = vm_model.Viewport;

const disasm_options: disasm.Options = .{
    .show_constants = true,
    .show_source = true,
    .show_bytes = true,
    .recurse = false,
};

pub fn Methods(comptime Explorer: type) type {
    return struct {
        const RenderedValue = Explorer.Ops.RenderedValue;
        const Layout = Explorer.Ops.Layout;
        const StoreRecord = Explorer.Ops.StoreRecord;
        const OpenMode = Explorer.Ops.OpenMode;
        const TreeViewport = Explorer.Ops.TreeViewport;
        const TreeCell = Explorer.Ops.TreeCell;
        const DebugOutcome = Explorer.Ops.DebugOutcome;
        const DebugCloseIntent = Explorer.Ops.DebugCloseIntent;
        const range_leaf = Explorer.range_leaf;
        const range_branch = Explorer.range_branch;
        const preview_line_cap = Explorer.preview_line_cap;

        pub fn identityForStore(view: HeapView) disasm.Identity {
            return switch (view) {
                .overview, .objects => .object,
                .values => .value,
                .attrs => .attr,
                .attr_positions => .attr_position,
                .intern => .intern,
                .builtin => .builtin,
            };
        }

        pub fn canonicalStoreRef(
            self: *Explorer,
            arena: std.mem.Allocator,
            view: HeapView,
            id: u32,
            preview: ?[]const u8,
            colored: bool,
        ) ![]const u8 {
            var rendered: std.Io.Writer.Allocating = .init(arena);
            try disasm.writeStoreRef(
                &rendered.writer,
                @tagName(view),
                id,
                identityForStore(view),
                preview,
                if (colored) self.color_depth else .none,
            );
            return rendered.written();
        }

        pub fn storeRecordSummary(
            self: *Explorer,
            arena: std.mem.Allocator,
            view: HeapView,
            id: u32,
            max_cells: usize,
        ) ![]const u8 {
            const raw: []const u8 = switch (view) {
                .values => if (self.ev.heapValueAt(id)) |value|
                    try Explorer.Ops.valueSummary(self, arena, value.*, max_cells)
                else
                    "",
                .attrs => if (self.ev.heapAttrAt(id)) |attr|
                    try std.fmt.allocPrint(arena, "{s} = {s}", .{
                        self.ev.internTable().get(attr.name),
                        try Explorer.Ops.valueSummary(self, arena, attr.value, max_cells),
                    })
                else
                    "",
                .attr_positions => if (self.ev.heapAttrPosAt(id)) |position|
                    try std.fmt.allocPrint(arena, "{s} @ {s}:{d}:{d}", .{
                        self.ev.internTable().get(position.name),
                        std.fs.path.basename(self.ev.internTable().get(position.pos.file)),
                        position.pos.line,
                        position.pos.column,
                    })
                else
                    "",
                .intern => if (id < Explorer.Ops.storeCount(self, .intern))
                    try escapedQuoted(arena, "text ", self.ev.internTable().get(id), max_cells)
                else
                    "",
                .builtin => disasm.builtinName(id) orelse "",
                .overview, .objects => "",
            };
            return width_mod.endEllipsis(arena, raw, max_cells);
        }

        pub fn storePreviewBudget(self: *Explorer, store: []const u8, id: u64, max_cells: usize) usize {
            _ = self;
            var location_buf: [64]u8 = undefined;
            const location = std.fmt.bufPrint(&location_buf, "{s}[0x{x}] → ", .{ store, id }) catch return max_cells;
            return max_cells -| width_mod.strWidth(location);
        }

        /// Render a store-backed value in canonical address-first order. The
        /// preview is bounded before color escapes are introduced, so truncation
        /// remains terminal-cell-aware.
        pub fn locatedValue(
            self: *Explorer,
            arena: std.mem.Allocator,
            store: []const u8,
            id: u64,
            identity: disasm.Identity,
            preview: ?[]const u8,
            max_cells: usize,
            colored: bool,
        ) ![]const u8 {
            const bounded = if (preview) |text|
                try width_mod.endEllipsis(arena, text, Explorer.Ops.storePreviewBudget(self, store, id, max_cells))
            else
                null;
            var rendered: std.Io.Writer.Allocating = .init(arena);
            try disasm.writeStoreRef(
                &rendered.writer,
                store,
                id,
                identity,
                bounded,
                if (colored) self.color_depth else .none,
            );
            return rendered.written();
        }

        pub fn canonicalStoreRange(
            self: *Explorer,
            arena: std.mem.Allocator,
            view: HeapView,
            start: u32,
            end: u32,
            live: u32,
            colored: bool,
        ) ![]const u8 {
            var rendered: std.Io.Writer.Allocating = .init(arena);
            try disasm.writeStoreRange(
                &rendered.writer,
                @tagName(view),
                start,
                end,
                live,
                identityForStore(view),
                if (colored) self.color_depth else .none,
            );
            return rendered.written();
        }

        pub fn escapedQuoted(
            arena: std.mem.Allocator,
            prefix: []const u8,
            text: []const u8,
            max_cells: usize,
        ) ![]const u8 {
            var escaped: std.Io.Writer.Allocating = .init(arena);
            for (text) |c| switch (c) {
                '\\' => try escaped.writer.writeAll("\\\\"),
                '"' => try escaped.writer.writeAll("\\\""),
                '\n' => try escaped.writer.writeAll("\\n"),
                '\r' => try escaped.writer.writeAll("\\r"),
                '\t' => try escaped.writer.writeAll("\\t"),
                else => try escaped.writer.writeByte(c),
            };
            const inner_width = max_cells -| width_mod.strWidth(prefix) -| 2;
            const short = try width_mod.endEllipsis(arena, escaped.written(), inner_width);
            return std.fmt.allocPrint(arena, "{s}\"{s}\"", .{ prefix, short });
        }

        pub fn floatSummary(arena: std.mem.Allocator, value: f64) ![]const u8 {
            const short = try std.fmt.allocPrint(arena, "{d:.3}", .{value});
            if (!std.math.isFinite(value)) return std.fmt.allocPrint(arena, "float {s}", .{short});
            const parsed = std.fmt.parseFloat(f64, short) catch value;
            return std.fmt.allocPrint(arena, "float {s}{s}", .{
                if (parsed == value) "" else "~",
                short,
            });
        }

        /// A bounded, non-forcing digest using the same address-first grammar as
        /// locals, stack slots, return values, and disassembly.
        pub fn valueSummary(self: *Explorer, arena: std.mem.Allocator, value: runtime.value.Value, max_cells: usize) ![]const u8 {
            return (try Explorer.Ops.renderValue(self, arena, value, max_cells, false)).text;
        }

        pub fn scalarValueSummary(self: *Explorer, arena: std.mem.Allocator, value: runtime.value.Value, max_cells: usize) ![]const u8 {
            _ = self;
            const raw: []const u8 = switch (value.kind()) {
                .null => "null",
                .bool_false => "bool false",
                .bool_true => "bool true",
                .int => try std.fmt.allocPrint(arena, "int {d}", .{value.asInt()}),
                .float => try floatSummary(arena, value.asFloat()),
                .string,
                .path,
                .builtin,
                .list,
                .attrs,
                .closure,
                .thunk,
                .builtin_closure,
                .string_context,
                .boxed_int,
                .partial_app,
                => unreachable,
            };
            return width_mod.endEllipsis(arena, raw, max_cells);
        }

        pub fn objectSummary(self: *Explorer, arena: std.mem.Allocator, id: runtime.types.ObjectId, max_cells: usize) ![]const u8 {
            if (self.heap_index.objects) |*snapshot| {
                if (self.ev.inspectHeapObject(snapshot, id)) |info| {
                    const text: []const u8 = switch (info) {
                        .list => if (self.ev.heapListOf(id)) |items|
                            try std.fmt.allocPrint(arena, "list ({d})", .{items.len})
                        else |_|
                            "list",
                        .attrs => if (self.ev.heapAttrsOf(id)) |attrs|
                            try std.fmt.allocPrint(arena, "attrs ({d})", .{attrs.len})
                        else |_|
                            "attrs",
                        .merge_attrs => |merge| try std.fmt.allocPrint(arena, "attrs merge · depth {d}", .{merge.depth}),
                        .closure => |closure| try std.fmt.allocPrint(arena, "closure → chunk[0x{x}] · {d} upvalues", .{ closure.chunk, closure.upvalues }),
                        .builtin_closure => |closure| try std.fmt.allocPrint(arena, "builtin closure → {s} · {d} args", .{
                            try Explorer.Ops.locatedValue(
                                self,
                                arena,
                                "builtin",
                                closure.builtin,
                                .builtin,
                                disasm.builtinName(closure.builtin),
                                max_cells -| 20,
                                false,
                            ),
                            closure.args,
                        }),
                        .thunk => |thunk| try std.fmt.allocPrint(arena, "thunk · {s}{s}", .{
                            @tagName(thunk.state),
                            if (thunk.demanded) " · demanded" else "",
                        }),
                        .context_string => |string| try std.fmt.allocPrint(arena, "context string · {d} entries", .{string.context}),
                        .boxed_int => |value| try std.fmt.allocPrint(arena, "int {d}", .{value}),
                        .partial_app => |partial| try std.fmt.allocPrint(arena, "partial application · {d} args", .{partial.args}),
                    };
                    return width_mod.endEllipsis(arena, text, max_cells);
                } else |_| {}
            }
            return "?";
        }

        /// A useful, non-forcing description for an `objects[0xN]` value. Known
        /// list/attribute membership can be summarized safely; thunks are never
        /// forced and lazy attributes are never demanded.
        pub fn objectTargetSummary(
            self: *Explorer,
            arena: std.mem.Allocator,
            kind: runtime.value.ValueType,
            id: runtime.types.ObjectId,
            max_cells: usize,
        ) !?[]const u8 {
            switch (kind) {
                .list => if (self.ev.heapListOf(id)) |items| {
                    var out: std.Io.Writer.Allocating = .init(arena);
                    try out.writer.print("list ({d})", .{items.len});
                    if (items.len > 0) {
                        try out.writer.writeAll(" [");
                        for (items[0..@min(items.len, 3)], 0..) |item, i| {
                            if (i != 0) try out.writer.writeAll(", ");
                            try out.writer.writeAll(try Explorer.Ops.shallowValueSummary(
                                self,
                                arena,
                                item,
                                @max(@as(usize, 8), max_cells / 3),
                            ));
                        }
                        if (items.len > 3) try out.writer.writeAll(", …");
                        try out.writer.writeByte(']');
                    }
                    return try width_mod.endEllipsis(arena, out.written(), max_cells);
                } else |_| {},
                .attrs => if (self.ev.heapAttrsOf(id)) |attrs| {
                    var out: std.Io.Writer.Allocating = .init(arena);
                    try out.writer.print("attrs ({d})", .{attrs.len});
                    if (attrs.len > 0) {
                        try out.writer.writeAll(" {");
                        for (attrs[0..@min(attrs.len, 2)], 0..) |attr, i| {
                            if (i != 0) try out.writer.writeAll(", ");
                            try out.writer.writeAll(self.ev.internTable().get(attr.name));
                            if (try Explorer.Ops.scalarText(self, arena, attr.value, @max(@as(usize, 8), max_cells / 2))) |scalar|
                                try out.writer.print(" = {s}", .{scalar});
                        }
                        if (attrs.len > 2) try out.writer.writeAll(", …");
                        try out.writer.writeByte('}');
                    }
                    return try width_mod.endEllipsis(arena, out.written(), max_cells);
                } else |_| {},
                else => {},
            }

            const summary = try Explorer.Ops.objectSummary(self, arena, id, max_cells);
            return if (std.mem.eql(u8, summary, "?")) disasm.valueKindLabel(kind) else summary;
        }

        /// The rendered scalar for an inline `Value` (null/bool/int/float/string/
        /// path), or null for heap-backed kinds. Safe on a raw store slot — inline
        /// scalars carry their data in the `Value` bits with no heap deref.
        pub fn scalarText(
            self: *Explorer,
            arena: std.mem.Allocator,
            value: runtime.value.Value,
            max_cells: usize,
        ) !?[]const u8 {
            return switch (value.kind()) {
                .null,
                .bool_false,
                .bool_true,
                .int,
                .float,
                => try Explorer.Ops.scalarValueSummary(self, arena, value, max_cells),
                .string, .path => blk: {
                    const id = value.asInternId();
                    const preview = try escapedQuoted(
                        arena,
                        try std.fmt.allocPrint(arena, "{s} ", .{disasm.valueKindLabel(value.kind())}),
                        self.ev.internTable().get(id),
                        Explorer.Ops.storePreviewBudget(self, "intern", id, max_cells),
                    );
                    break :blk try Explorer.Ops.locatedValue(self, arena, "intern", id, .intern, preview, max_cells, false);
                },
                .builtin => blk: {
                    const id = value.asBuiltinId();
                    break :blk try Explorer.Ops.locatedValue(self, arena, "builtin", id, .builtin, disasm.builtinName(id), max_cells, false);
                },
                else => null,
            };
        }

        /// Render a nested member without following it into another container.
        /// This preserves its identity and type while keeping list/attrs previews
        /// bounded and cycle-safe.
        pub fn shallowValueSummary(
            self: *Explorer,
            arena: std.mem.Allocator,
            value: runtime.value.Value,
            max_cells: usize,
        ) ![]const u8 {
            if (try Explorer.Ops.scalarText(self, arena, value, max_cells)) |scalar|
                return width_mod.endEllipsis(arena, scalar, max_cells);
            if (value.kind() == .closure and value.isFunction())
                return Explorer.Ops.locatedValue(self, arena, "chunk", value.asFunctionChunkId(), .chunk, "function", max_cells, false);
            return Explorer.Ops.locatedValue(
                self,
                arena,
                "objects",
                value.asObjectId(),
                .object,
                disasm.valueKindLabel(value.kind()),
                max_cells,
                false,
            );
        }
    };
}
