//! Internal VM explorer component.
//!
//! Methods are parameterized by the private explorer state type and wired as
//! direct aliases by `operations.zig`; this module owns the behavior below.

const std = @import("std");
const engine = @import("expr");
const runtime = @import("runtime");
const width_mod = @import("../width.zig");
const vm_refs = @import("refs.zig");
const vm_model = @import("model.zig");
const vm_source = @import("source.zig");
const vm_helpers = @import("semantics.zig");
const source_render = @import("../../source_render.zig");
const debugger = @import("../../debugger.zig");
const base = @import("base");
const tui = base.tui;
const Engine = engine.Engine;
const DebugSession = engine.DebugSession;
const ChunkId = runtime.types.ChunkId;
const bytecode = engine.bytecode;
const disasm = engine.bytecode.disasm;

const Category = vm_model.Category;
const HeapView = vm_model.HeapView;
const RowAction = vm_model.RowAction;
const BreakpointLocation = vm_source.Location;
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

        // -- page construction ---------------------------------------------------

        pub fn refreshPage(self: *Explorer, kind: Visit.Kind) !void {
            _ = self.arena.reset(.retain_capacity);
            self.page = try Explorer.Ops.buildPage(self, kind);
            self.navigation.detail_selection = @min(self.navigation.detail_selection, self.page.lines.len -| 1);
            if (!Explorer.Ops.rowActionable(self, self.navigation.detail_selection)) self.navigation.detail_selection = Explorer.Ops.firstActionableRow(self) orelse 0;
            Explorer.Ops.ensureDetailVisible(self);
        }

        pub fn buildPage(self: *Explorer, kind: Visit.Kind) !Page {
            const arena = self.arena.allocator();
            switch (kind) {
                .chunk => |id| {
                    const chunk = self.ev.getChunk(id) orelse {
                        return .{
                            .title = try std.fmt.allocPrint(arena, "chunk[0x{x}] (not found)", .{id}),
                            .lines = &.{},
                            .actions = &.{},
                        };
                    };
                    var page: PageBuilder = .{ .arena = arena };
                    try Explorer.Ops.appendChunkEquivalence(self, &page, id);
                    try Explorer.Ops.appendSourceDocument(self, &page, id, chunk, Explorer.Ops.focusedSourceSpan(self, id));
                    try page.line("", .none);
                    try page.heading(try std.fmt.allocPrint(arena, "CODE · chunk[0x{x}]", .{id}));
                    try Explorer.Ops.appendDisassemblyAt(self, &page, id, chunk, true, null);
                    try page.line("", .none);
                    try Explorer.Ops.appendReferences(self, &page, .{ .chunk = id });
                    return .{
                        .title = try std.fmt.allocPrint(arena, "chunk[0x{x}]", .{id}),
                        .lines = page.lines.items,
                        .actions = page.actions.items,
                        .locations = page.locations.items,
                    };
                },
                .heap => |view| return Explorer.Ops.buildHeapPage(self, view),
                .object => |id| return Explorer.Ops.buildObjectPage(self, id),
                .store_record => |r| return Explorer.Ops.buildStoreRecordPage(self, r.view, r.id),
                .debug_frame => |i| return Explorer.Ops.buildDebugFramePage(self, i),
                .debug_value => return Explorer.Ops.buildReturnValuePage(self),
                .help => {
                    const help_text =
                        \\  Tab             switch tree/detail focus
                        \\  j/k, arrows     move between interactive rows
                        \\  Enter, →        expand a tree/group or open a reference
                        \\  ←               collapse a tree/group
                        \\  p               toggle a breakpoint on the selected row
                        \\  F               filter the tree by name (Esc clears)
                        \\  d/u, PgDn/PgUp  scroll the detail document
                        \\  b / f           back / forward through followed references
                        \\  /               search; n/N next/previous match
                        \\  i / :           enter an expression / command at the REPL prompt
                        \\  Esc             leave source/pane/tree layer; then return
                        \\  q               return directly to the inline REPL
                        \\
                        \\The tree starts collapsed except for the focused chunk's
                        \\ancestor path. Large child/chunk sets are exposed through
                        \\bounded range nodes instead of being truncated.
                    ;
                    var page: PageBuilder = .{ .arena = arena };
                    try page.heading("The VM explorer");
                    try page.line("", .none);
                    try page.text(help_text);
                    return .{
                        .title = try arena.dupe(u8, "help"),
                        .lines = page.lines.items,
                        .actions = page.actions.items,
                    };
                },
            }
        }

        pub fn buildHeapPage(self: *Explorer, view: HeapView) !Page {
            const arena = self.arena.allocator();
            const counts = self.ev.heapCounts();
            var page: PageBuilder = .{ .arena = arena };
            try page.heading(try std.fmt.allocPrint(arena, "HEAP · {d} object slots", .{counts.objects}));
            try page.line(try std.fmt.allocPrint(arena, "objects        {d:>12}", .{counts.objects}), .none);
            try page.line(try std.fmt.allocPrint(arena, "values         {d:>12}", .{counts.values}), .none);
            try page.line(try std.fmt.allocPrint(arena, "attrs          {d:>12}", .{counts.attrs}), .none);
            try page.line(try std.fmt.allocPrint(arena, "attr positions {d:>12}", .{counts.attr_positions}), .none);
            try page.line(try std.fmt.allocPrint(arena, "intern          {d:>12}", .{Explorer.Ops.storeCount(self, .intern)}), .none);
            try page.line(try std.fmt.allocPrint(arena, "builtin         {d:>12}", .{Explorer.Ops.storeCount(self, .builtin)}), .none);
            try page.line("", .none);

            const stats = self.heap_index.stats orelse {
                return .{
                    .title = try std.fmt.allocPrint(arena, "heap · {s}", .{@tagName(view)}),
                    .lines = page.lines.items,
                    .actions = page.actions.items,
                };
            };
            switch (view) {
                .overview, .objects => {
                    try page.heading("OBJECT VARIANTS");
                    for (stats.variant_counts, 0..) |count, i| {
                        try page.line(try std.fmt.allocPrint(arena, "{s:<20} {d:>12}", .{ runtime.ObjectHeap.Stats.variantName(i), count }), .none);
                    }
                    try page.line("", .none);
                    try page.heading("THUNK STATES");
                    for (stats.thunk_states, 0..) |count, i| {
                        try page.line(try std.fmt.allocPrint(arena, "{s:<20} {d:>12}", .{ runtime.ObjectHeap.Stats.thunkStateName(i), count }), .none);
                    }
                    try page.line(try std.fmt.allocPrint(arena, "resolved demanded     {d:>12}", .{stats.resolved_demanded}), .none);
                    try page.line(try std.fmt.allocPrint(arena, "resolved undemanded   {d:>12}", .{stats.resolved_undemanded}), .none);
                },
                .values, .attrs => {
                    try page.heading("INLINE INTEGER MAGNITUDES · values + attrs");
                    for (stats.int_buckets, 0..) |count, i| {
                        try page.line(try std.fmt.allocPrint(arena, "{s:<20} {d:>12}", .{ runtime.ObjectHeap.Stats.intBucketLabel(i), count }), .none);
                    }
                    try page.line(try std.fmt.allocPrint(arena, "i48 overflows         {d:>12}", .{stats.intOverflowsI48()}), .none);
                },
                .attr_positions => {
                    try page.heading("ATTR POSITIONS");
                    try page.line("Source-position records attached to heap attrs.", .none);
                    try page.line("Open TABLES on a chunk to inspect its compile-time attr positions.", .none);
                },
                .intern => {
                    try page.heading("INTERNED TEXT");
                    try page.line("Dense, process-local text identities used by strings, paths, names, and source files.", .none);
                },
                .builtin => {
                    try page.heading("BUILTINS");
                    try page.line("Dense evaluator builtin identities, including compiler-internal entries.", .none);
                },
            }
            return .{
                .title = try std.fmt.allocPrint(arena, "heap · {s}", .{@tagName(view)}),
                .lines = page.lines.items,
                .actions = page.actions.items,
            };
        }

        pub fn buildObjectPage(self: *Explorer, id: runtime.types.ObjectId) !Page {
            const arena = self.arena.allocator();
            var page: PageBuilder = .{ .arena = arena };
            if (self.heap_index.objects == null)
                self.heap_index.objects = self.ev.heapObjectSnapshot(self.allocator) catch null;
            const snapshot = self.heap_index.objects orelse return .{
                .title = try std.fmt.allocPrint(arena, "objects[0x{x}]", .{id}),
                .lines = page.lines.items,
                .actions = page.actions.items,
            };
            const info = self.ev.inspectHeapObject(&snapshot, id) catch {
                try page.line("this object is no longer live", .none);
                return .{
                    .title = try std.fmt.allocPrint(arena, "objects[0x{x}]", .{id}),
                    .lines = page.lines.items,
                    .actions = page.actions.items,
                };
            };
            const heading_width = Explorer.Ops.layout(self).main_width;
            try page.heading(try Explorer.Ops.canonicalStoreRef(
                self,
                arena,
                .objects,
                id,
                try Explorer.Ops.objectSummary(self, arena, id, Explorer.Ops.storePreviewBudget(self, "objects", id, heading_width)),
                true,
            ));
            try page.line("", .none);
            switch (info) {
                .list => {
                    try page.line("", .none);
                    try Explorer.Ops.appendObjectMembers(self, &page, id);
                },
                .attrs => |attrs| {
                    try page.line(try std.fmt.allocPrint(arena, "positions   {d}", .{attrs.positions}), .none);
                    try page.line(try std.fmt.allocPrint(arena, "swept       {s}", .{if (attrs.sibling_swept) "yes" else "no"}), .none);
                    try page.line("", .none);
                    try Explorer.Ops.appendObjectMembers(self, &page, id);
                },
                .merge_attrs => |merge| {
                    try Explorer.Ops.appendObjectRef(self, &page, "base", merge.base);
                    try Explorer.Ops.appendObjectRef(self, &page, "overlay", merge.overlay);
                    try page.line(try std.fmt.allocPrint(arena, "depth       {d}", .{merge.depth}), .none);
                    if (merge.flattened) |flat| try Explorer.Ops.appendObjectRef(self, &page, "flattened", flat) else try page.line("flattened   not materialized", .none);
                },
                .closure => |closure| {
                    const prefix = "chunk       ";
                    try page.line(
                        try std.fmt.allocPrint(arena, "{s}{s}", .{
                            prefix,
                            try Explorer.Ops.locatedValue(self, arena, "chunk", closure.chunk, .chunk, null, Explorer.Ops.lineRemainderWidth(self, prefix), true),
                        }),
                        .{ .chunk = closure.chunk },
                    );
                    try page.line(try std.fmt.allocPrint(arena, "upvalues    {d}", .{closure.upvalues}), .none);
                },
                .builtin_closure => |closure| {
                    const prefix = "builtin     ";
                    try page.line(try std.fmt.allocPrint(arena, "{s}{s}", .{
                        prefix,
                        try Explorer.Ops.locatedValue(
                            self,
                            arena,
                            "builtin",
                            closure.builtin,
                            .builtin,
                            disasm.builtinName(closure.builtin),
                            Explorer.Ops.lineRemainderWidth(self, prefix),
                            true,
                        ),
                    }), .none);
                    try page.line(try std.fmt.allocPrint(arena, "arguments   {d}", .{closure.args}), .none);
                },
                .thunk => |thunk| {
                    try page.line(try std.fmt.allocPrint(arena, "state       {s}", .{@tagName(thunk.state)}), .none);
                    try page.line(try std.fmt.allocPrint(arena, "demanded    {s}", .{if (thunk.demanded) "yes" else "no"}), .none);
                    switch (thunk.body) {
                        .result => |value| try Explorer.Ops.appendValueRef(self, &page, "result", value),
                        .error_name => |name| try page.line(try std.fmt.allocPrint(arena, "error       {s}", .{name}), .none),
                        .target => |target| switch (target) {
                            .closure => |value| try Explorer.Ops.appendValueRef(self, &page, "closure", value),
                            .bytecode => |body| {
                                const prefix = "chunk       ";
                                try page.line(
                                    try std.fmt.allocPrint(arena, "{s}{s}", .{
                                        prefix,
                                        try Explorer.Ops.locatedValue(self, arena, "chunk", body.chunk, .chunk, null, Explorer.Ops.lineRemainderWidth(self, prefix), true),
                                    }),
                                    .{ .chunk = body.chunk },
                                );
                                try page.line(try std.fmt.allocPrint(arena, "captures    {d}", .{body.captures}), .none);
                            },
                            .pass_through => |value| try Explorer.Ops.appendValueRef(self, &page, "value", value),
                            .attr_access => |access| {
                                try Explorer.Ops.appendValueRef(self, &page, "base", access.base);
                                const prefix = "attribute   ";
                                const attribute = try Explorer.Ops.renderValueRef(self, arena, .{
                                    .kind = .string,
                                    .target = .{ .intern = access.name },
                                }, Explorer.Ops.lineRemainderWidth(self, prefix), true);
                                try page.line(try std.fmt.allocPrint(arena, "{s}{s}", .{ prefix, attribute.text }), .none);
                            },
                            .deferred => |body| {
                                try page.line(try std.fmt.allocPrint(arena, "deferred[0x{x}]", .{body.id}), .none);
                                try page.line(try std.fmt.allocPrint(arena, "captures    {d}", .{body.captures}), .none);
                            },
                        },
                    }
                },
                .context_string => |string| {
                    const prefix = "text        ";
                    const text = try Explorer.Ops.renderValueRef(self, arena, .{
                        .kind = .string,
                        .target = .{ .intern = string.text },
                    }, Explorer.Ops.lineRemainderWidth(self, prefix), true);
                    try page.line(try std.fmt.allocPrint(arena, "{s}{s}", .{ prefix, text.text }), .none);
                    try page.line(try std.fmt.allocPrint(arena, "context     {d} entries", .{string.context}), .none);
                },
                .boxed_int => |value| try page.line(try std.fmt.allocPrint(arena, "value       {d}", .{value}), .none),
                .partial_app => |partial| {
                    try Explorer.Ops.appendValueRef(self, &page, "function", partial.function);
                    try page.line(try std.fmt.allocPrint(arena, "arguments   {d}", .{partial.args}), .none);
                },
            }
            try page.line("", .none);
            try Explorer.Ops.appendReferences(self, &page, .{ .object = id });
            return .{
                .title = try std.fmt.allocPrint(arena, "objects[0x{x}]", .{id}),
                .lines = page.lines.items,
                .actions = page.actions.items,
            };
        }

        /// One record from the value / attr / attr-position stores.
        pub fn buildStoreRecordPage(self: *Explorer, view: HeapView, id: u32) !Page {
            const arena = self.arena.allocator();
            var page: PageBuilder = .{ .arena = arena };
            const heading_width = Explorer.Ops.layout(self).main_width;
            const heading_summary = try Explorer.Ops.storeRecordSummary(
                self,
                arena,
                view,
                id,
                Explorer.Ops.storePreviewBudget(self, @tagName(view), id, heading_width),
            );
            try page.heading(try Explorer.Ops.canonicalStoreRef(self, arena, view, id, heading_summary, true));
            try page.line("", .none);
            switch (view) {
                .values => {
                    if (self.ev.heapValueAt(id)) |value| {
                        try Explorer.Ops.appendValueDetail(self, &page, "value", value.*);
                    } else try page.line("(slot is out of range)", .none);
                },
                .attrs => {
                    if (self.ev.heapAttrAt(id)) |attr| {
                        try page.line(try std.fmt.allocPrint(arena, "name   {s}", .{self.ev.internTable().get(attr.name)}), .none);
                        try Explorer.Ops.appendValueDetail(self, &page, "value", attr.value);
                    } else try page.line("(slot is out of range)", .none);
                },
                .attr_positions => {
                    if (self.ev.heapAttrPosAt(id)) |ap| {
                        try page.line(try std.fmt.allocPrint(arena, "name   {s}", .{self.ev.internTable().get(ap.name)}), .none);
                        try page.line(try std.fmt.allocPrint(arena, "file   {s}", .{self.ev.internTable().get(ap.pos.file)}), .none);
                        try page.line(try std.fmt.allocPrint(arena, "at     {d}:{d}", .{ ap.pos.line, ap.pos.column }), .none);
                    } else try page.line("(slot is out of range)", .none);
                },
                .intern => if (id < Explorer.Ops.storeCount(self, .intern)) {
                    try page.line(try Explorer.Ops.escapedQuoted(arena, "text ", self.ev.internTable().get(id), Explorer.Ops.layout(self).main_width), .none);
                } else try page.line("(slot is out of range)", .none),
                .builtin => if (disasm.builtinName(id)) |name| {
                    try page.line(try std.fmt.allocPrint(arena, "name   {s}", .{name}), .none);
                } else try page.line("(slot is out of range)", .none),
                .overview, .objects => try page.line("(not a store record)", .none),
            }
            return .{
                .title = try std.fmt.allocPrint(arena, "{s}[0x{x}]", .{ @tagName(view), id }),
                .lines = page.lines.items,
                .actions = page.actions.items,
                .locations = page.locations.items,
            };
        }

        /// The pause's break/return/error value as a first-class subject: the
        /// value's kind + scalar (or navigable ref), then its container members
        /// enumerated navigably so you can walk straight into the result.
        pub fn buildReturnValuePage(self: *Explorer) !Page {
            const arena = self.arena.allocator();
            var page: PageBuilder = .{ .arena = arena };
            const session = self.debug_session orelse {
                try page.line("(no active pause)", .none);
                return vm_helpers.debugPageOf(arena, &page, "value");
            };
            try page.heading(vm_helpers.returnValueHeading(session.reason));
            try page.line("", .none);
            try Explorer.Ops.appendValueDetail(self, &page, "value", session.value);
            try page.line("", .none);
            switch (self.ev.valueRef(session.value).target) {
                .object => |id| try Explorer.Ops.appendObjectMembers(self, &page, id),
                else => {},
            }
            return .{
                .title = try arena.dupe(u8, "value"),
                .lines = page.lines.items,
                .actions = page.actions.items,
                .locations = page.locations.items,
            };
        }

        /// Enumerate an attrs/list object's members navigably (non-forcing). Bounded
        /// so a huge container can't blow up the page.
        pub fn appendObjectMembers(self: *Explorer, page: *PageBuilder, id: runtime.types.ObjectId) !void {
            const arena = page.arena;
            const cap = 200;
            if (self.ev.heapAttrsOf(id)) |attrs| {
                try page.heading(try std.fmt.allocPrint(arena, "MEMBERS · {d}", .{attrs.len}));
                for (attrs, 0..) |entry, i| {
                    if (i >= cap) {
                        try page.line(try std.fmt.allocPrint(arena, "  … {d} more", .{attrs.len - cap}), .none);
                        break;
                    }
                    try Explorer.Ops.appendValueLine(self, page, try std.fmt.allocPrint(arena, "  {s} : ", .{self.ev.internTable().get(entry.name)}), entry.value);
                }
            } else |_| if (self.ev.heapListOf(id)) |items| {
                try page.heading(try std.fmt.allocPrint(arena, "ITEMS · {d}", .{items.len}));
                for (items, 0..) |item, i| {
                    if (i >= cap) {
                        try page.line(try std.fmt.allocPrint(arena, "  … {d} more", .{items.len - cap}), .none);
                        break;
                    }
                    try Explorer.Ops.appendValueLine(self, page, try std.fmt.allocPrint(arena, "  [{d}] ", .{i}), item);
                }
            } else |_| {}
        }

        /// One paused stack frame rendered as a single scrollable document: header,
        /// break/return value, a source excerpt around the frame, its named
        /// locals/upvalues, and the disassembly with the current instruction marked.
        /// The disassembly rows carry `(chunk_id, offset)` breakpoint locations, so
        /// `p` toggles a per-instruction breakpoint here exactly as in a chunk.
        pub fn buildDebugFramePage(self: *Explorer, index: usize) !Page {
            const arena = self.arena.allocator();
            var page: PageBuilder = .{ .arena = arena };
            const session = self.debug_session orelse {
                try page.line("(no active debug session)", .none);
                return vm_helpers.debugPageOf(arena, &page, "debug");
            };
            if (index >= session.frameCount()) {
                try page.line("(this frame is no longer live)", .none);
                return vm_helpers.debugPageOf(arena, &page, "debug");
            }
            const info = session.frame(index);
            const chunk_id = session.frameChunkId(index);

            try page.heading(try std.fmt.allocPrint(arena, "FRAME · #{d} · {s} · {s}:{d}:{d}", .{
                index,
                vm_helpers.reasonName(session.reason),
                if (info.file) |f| std.fs.path.basename(f) else "<repl>",
                info.line,
                info.column,
            }));
            if (session.hasFrameName(index)) {
                var name: std.Io.Writer.Allocating = .init(arena);
                session.writeFrameName(&name.writer, index) catch {};
                if (name.written().len > 0) try page.line(try std.fmt.allocPrint(arena, "name   {s}", .{name.written()}), .none);
            }
            try page.line("", .none);

            if (session.reason == .break_builtin or session.reason == .eval_error) {
                try page.heading(vm_helpers.returnValueHeading(session.reason));
                try Explorer.Ops.appendValueLine(self, &page, "  => ", session.value);
                try page.line("", .none);
            }

            if (self.ev.getChunk(chunk_id)) |chunk| {
                if (Explorer.Ops.focusedSourceSpan(self, chunk_id) orelse info.span) |span| if (session.frameSourceText(index)) |source| {
                    try Explorer.Ops.appendSourceDocumentWithText(
                        self,
                        &page,
                        chunk_id,
                        chunk,
                        source,
                        span,
                        if (session.reason == .return_step and index + 1 == session.frameCount()) session.value else null,
                    );
                    try page.line("", .none);
                };
            } else if (info.span) |span| if (session.frameSourceText(index)) |source| {
                try page.heading("SOURCE");
                try Explorer.Ops.appendSourceExcerpt(
                    self,
                    &page,
                    source,
                    span,
                    null,
                    null,
                    true,
                    true,
                    if (session.reason == .return_step and index + 1 == session.frameCount()) session.value else null,
                );
                try page.line("", .none);
            };

            try page.heading("LOCALS · values are not forced");
            var any = false;
            for (0..session.localCount(index)) |slot| {
                const nm = session.localName(index, slot) orelse continue;
                try Explorer.Ops.appendValueLine(self, &page, try std.fmt.allocPrint(arena, "  {s} : ", .{nm}), session.localValue(index, slot));
                any = true;
            }
            for (0..session.upvalueCount(index)) |slot| {
                const nm = session.upvalueName(index, slot) orelse continue;
                try Explorer.Ops.appendValueLine(self, &page, try std.fmt.allocPrint(arena, "  ↑ {s} : ", .{nm}), session.upvalueValue(index, slot));
                any = true;
            }
            if (!any) try page.line("  (no named locals or upvalues)", .none);
            try page.line("", .none);

            // The raw VM operand stack for this frame (top of stack first).
            const stack_n = session.stackSlotCount(index);
            if (stack_n > 0) {
                try page.heading(try std.fmt.allocPrint(arena, "VM STACK · {d}", .{stack_n}));
                var s: usize = 0;
                while (s < stack_n) : (s += 1) {
                    const slot = stack_n - 1 - s;
                    try Explorer.Ops.appendValueLine(self, &page, try std.fmt.allocPrint(arena, "  [{d}] ", .{slot}), session.stackSlot(index, slot));
                }
                try page.line("", .none);
            }

            if (self.ev.getChunk(chunk_id)) |chunk| {
                try page.heading(try std.fmt.allocPrint(arena, "CODE · chunk[0x{x}]", .{chunk_id}));
                try Explorer.Ops.appendDisassemblyAt(self, &page, chunk_id, chunk, false, info.instruction);
            }

            return .{
                .title = try std.fmt.allocPrint(arena, "frame #{d}", .{index}),
                .lines = page.lines.items,
                .actions = page.actions.items,
                .locations = page.locations.items,
            };
        }

        pub fn appendObjectRef(self: *Explorer, page: *PageBuilder, label: []const u8, id: runtime.types.ObjectId) !void {
            const prefix = try std.fmt.allocPrint(page.arena, "{s:<12} ", .{label});
            const ref_width = Explorer.Ops.lineRemainderWidth(self, prefix);
            const preview_width = Explorer.Ops.storePreviewBudget(self, "objects", id, ref_width);
            try page.line(try std.fmt.allocPrint(page.arena, "{s}{s}", .{
                prefix,
                try Explorer.Ops.canonicalStoreRef(
                    self,
                    page.arena,
                    .objects,
                    id,
                    try Explorer.Ops.objectSummary(self, page.arena, id, preview_width),
                    true,
                ),
            }), .{ .object = id });
        }

        pub fn lineRemainderWidth(self: *const Explorer, prefix: []const u8) usize {
            return Explorer.Ops.layout(self).main_width -| tui.displayWidth(prefix, width_mod.cpWidth);
        }

        /// Render a heap `Value`: the actual scalar for inline kinds (int, float,
        /// bool, null, string, path), or a navigable reference for heap-backed
        /// kinds. Inline scalars carry their data in the `Value` itself, so this is
        /// safe on a raw store slot without any heap deref or forcing.
        pub fn appendValueDetail(self: *Explorer, page: *PageBuilder, label: []const u8, value: runtime.value.Value) !void {
            try Explorer.Ops.appendValueLine(self, page, try std.fmt.allocPrint(page.arena, "{s:<12} ", .{label}), value);
        }

        /// One navigable line for a `Value`: `<prefix><digest>[ → store[0xN]]`.
        /// Object/chunk-backed values carry a `.object`/`.chunk` action so Enter
        /// (or the right-hand preview) drills into them; scalars render inline.
        pub fn appendValueLine(self: *Explorer, page: *PageBuilder, prefix: []const u8, value: runtime.value.Value) !void {
            const rendered = try Explorer.Ops.renderValue(self, page.arena, value, Explorer.Ops.lineRemainderWidth(self, prefix), true);
            try page.line(
                try std.fmt.allocPrint(page.arena, "{s}{s}", .{ prefix, rendered.text }),
                rendered.action,
            );
        }

        pub const RenderedValue = struct {
            text: []const u8,
            action: RowAction,
        };

        /// Canonical non-forcing `Value` presentation shared by locals, stack
        /// slots, return badges, and other compact value rows.
        pub fn renderValue(
            self: *Explorer,
            arena: std.mem.Allocator,
            value: runtime.value.Value,
            max_cells: usize,
            colored: bool,
        ) !RenderedValue {
            const ref = self.ev.valueRef(value);
            return switch (ref.target) {
                .object => |id| blk: {
                    const preview = try Explorer.Ops.objectTargetSummary(self, arena, value.kind(), id, max_cells);
                    break :blk .{
                        .action = .{ .object = id },
                        .text = try Explorer.Ops.locatedValue(
                            self,
                            arena,
                            "objects",
                            id,
                            .object,
                            preview,
                            max_cells,
                            colored,
                        ),
                    };
                },
                .chunk => |id| blk: {
                    break :blk .{
                        .action = .{ .chunk = id },
                        .text = try Explorer.Ops.locatedValue(
                            self,
                            arena,
                            "chunk",
                            id,
                            .chunk,
                            if (value.kind() == .closure and value.isFunction()) "function" else disasm.valueKindLabel(value.kind()),
                            max_cells,
                            colored,
                        ),
                    };
                },
                .intern => |id| blk: {
                    const preview = try Explorer.Ops.escapedQuoted(
                        arena,
                        try std.fmt.allocPrint(arena, "{s} ", .{disasm.valueKindLabel(value.kind())}),
                        self.ev.internTable().get(id),
                        Explorer.Ops.storePreviewBudget(self, "intern", id, max_cells),
                    );
                    break :blk .{
                        .action = .{ .store_record = .{ .view = .intern, .id = id } },
                        .text = try Explorer.Ops.locatedValue(self, arena, "intern", id, .intern, preview, max_cells, colored),
                    };
                },
                .builtin => |id| .{
                    .action = .{ .store_record = .{ .view = .builtin, .id = id } },
                    .text = try Explorer.Ops.locatedValue(
                        self,
                        arena,
                        "builtin",
                        id,
                        .builtin,
                        disasm.builtinName(id),
                        max_cells,
                        colored,
                    ),
                },
                else => .{
                    .action = .none,
                    .text = try Explorer.Ops.scalarValueSummary(self, arena, value, max_cells),
                },
            };
        }

        pub fn appendValueRef(self: *Explorer, page: *PageBuilder, label: []const u8, value: runtime.heap.ValueRef) !void {
            const prefix = try std.fmt.allocPrint(page.arena, "{s:<12} ", .{label});
            const rendered = try Explorer.Ops.renderValueRef(self, page.arena, value, Explorer.Ops.lineRemainderWidth(self, prefix), true);
            try page.line(
                try std.fmt.allocPrint(page.arena, "{s}{s}", .{ prefix, rendered.text }),
                rendered.action,
            );
        }

        pub fn renderValueRef(
            self: *Explorer,
            arena: std.mem.Allocator,
            value: runtime.heap.ValueRef,
            max_cells: usize,
            colored: bool,
        ) !RenderedValue {
            return switch (value.target) {
                .none => .{ .text = disasm.valueKindLabel(value.kind), .action = .none },
                .object => |id| .{
                    .text = try Explorer.Ops.locatedValue(
                        self,
                        arena,
                        "objects",
                        id,
                        .object,
                        try Explorer.Ops.objectTargetSummary(self, arena, value.kind, id, max_cells),
                        max_cells,
                        colored,
                    ),
                    .action = .{ .object = id },
                },
                .chunk => |id| blk: {
                    break :blk .{
                        .text = try Explorer.Ops.locatedValue(
                            self,
                            arena,
                            "chunk",
                            id,
                            .chunk,
                            if (value.kind == .closure) "function" else disasm.valueKindLabel(value.kind),
                            max_cells,
                            colored,
                        ),
                        .action = .{ .chunk = id },
                    };
                },
                .intern => |id| blk: {
                    const preview = try Explorer.Ops.escapedQuoted(
                        arena,
                        try std.fmt.allocPrint(arena, "{s} ", .{disasm.valueKindLabel(value.kind)}),
                        self.ev.internTable().get(id),
                        Explorer.Ops.storePreviewBudget(self, "intern", id, max_cells),
                    );
                    break :blk .{
                        .text = try Explorer.Ops.locatedValue(self, arena, "intern", id, .intern, preview, max_cells, colored),
                        .action = .{ .store_record = .{ .view = .intern, .id = id } },
                    };
                },
                .builtin => |id| .{
                    .text = try Explorer.Ops.locatedValue(self, arena, "builtin", id, .builtin, disasm.builtinName(id), max_cells, colored),
                    .action = .{ .store_record = .{ .view = .builtin, .id = id } },
                },
            };
        }

        pub fn appendDisassemblyAt(
            self: *Explorer,
            page: *PageBuilder,
            id: ChunkId,
            chunk: *const bytecode.Chunk,
            show_tables: bool,
            current_offset: ?u32,
        ) !void {
            var text: std.Io.Writer.Allocating = .init(page.arena);
            const symbols: disasm.Symbols = .{ .intern = self.ev.internTable(), .registry = self.ev.chunkRegistry() };
            var inspected_chunk = chunk.*;
            inspected_chunk.code = try self.ev.unpatchedChunkCode(page.arena, id, chunk);
            var options = disasm_options;
            options.color_depth = self.color_depth;
            options.show_header = false;
            options.show_constants = show_tables;
            options.show_code = true;
            options.current_offset = current_offset;
            options.line_width = @intCast(@min(Explorer.Ops.layout(self).main_width, std.math.maxInt(u16)));
            try disasm.writeChunk(page.arena, &text.writer, id, &inspected_chunk, symbols, options);

            var lines = std.mem.splitScalar(u8, text.written(), '\n');
            while (lines.next()) |line| {
                if (line.len == 0 and lines.peek() == null) break;
                const plain = base.terminal_text.stripAnsiInPlace(try page.arena.dupe(u8, line));
                const target = vm_helpers.disasmTarget(plain);
                const action: RowAction = if (target == .none and vm_helpers.disasmOffset(&inspected_chunk, plain) != null) .instruction else target;
                const location = Explorer.Ops.disasmLocation(self, id, &inspected_chunk, plain);
                try page.lineAt(line, action, location);
            }
        }

        pub fn valueRowAction(self: *const Explorer, value: runtime.value.Value) RowAction {
            return switch (self.ev.valueRef(value).target) {
                .object => |id| .{ .object = id },
                .chunk => |id| .{ .chunk = id },
                .intern => |id| .{ .store_record = .{ .view = .intern, .id = id } },
                .builtin => |id| .{ .store_record = .{ .view = .builtin, .id = id } },
                else => .none,
            };
        }

        pub fn rowTargetsValue(self: *const Explorer, action: RowAction, value: runtime.value.Value) bool {
            return switch (self.ev.valueRef(value).target) {
                .object => |id| switch (action) {
                    .object => |row_id| row_id == id,
                    else => false,
                },
                .chunk => |id| switch (action) {
                    .chunk => |row_id| row_id == id,
                    else => false,
                },
                .intern => |id| switch (action) {
                    .store_record => |record| record.view == .intern and record.id == id,
                    else => false,
                },
                .builtin => |id| switch (action) {
                    .store_record => |record| record.view == .builtin and record.id == id,
                    else => false,
                },
                else => false,
            };
        }

        /// Put a navigable pause result under the inspector cursor. The inline
        /// result remains part of the source document, and Enter follows it using
        /// the same object/chunk action as any other rendered value.
        pub fn focusValueRow(self: *Explorer, value: runtime.value.Value) void {
            for (self.page.actions, 0..) |action, i| {
                if (!Explorer.Ops.rowTargetsValue(self, action, value)) continue;
                self.navigation.detail_selection = i;
                Explorer.Ops.ensureDetailVisible(self);
                return;
            }
        }

        pub fn chunkEquivalence(self: *const Explorer, id: ChunkId) ?ChunkEquivalence {
            const index = &self.tree_index.equivalence;
            if (index.structuralPeer(id)) |peer| return .{ .structural = peer };
            if (index.codePeer(id)) |peer| return .{ .code = peer };
            return null;
        }

        pub fn chunkEquivalenceSuffix(self: *const Explorer, buffer: []u8, id: ChunkId) []const u8 {
            const relation = Explorer.Ops.chunkEquivalence(self, id) orelse return "";
            return switch (relation) {
                .structural => |peer| std.fmt.bufPrint(buffer, " · identical chunk[0x{x}]", .{peer}) catch "",
                .code => |peer| std.fmt.bufPrint(buffer, " · same code chunk[0x{x}]", .{peer}) catch "",
            };
        }

        pub fn appendChunkEquivalence(self: *Explorer, page: *PageBuilder, id: ChunkId) !void {
            const relation = Explorer.Ops.chunkEquivalence(self, id) orelse return;
            switch (relation) {
                .structural => |peer| try page.line(
                    try std.fmt.allocPrint(page.arena, "structurally identical to chunk[0x{x}]", .{peer}),
                    .{ .chunk = peer },
                ),
                .code => |peer| try page.line(
                    try std.fmt.allocPrint(page.arena, "same bytecode as chunk[0x{x}]; constants, source data, or metadata differ", .{peer}),
                    .{ .chunk = peer },
                ),
            }
            try page.line("", .none);
        }

        pub fn disasmLocation(self: *Explorer, id: ChunkId, chunk: *const bytecode.Chunk, plain: []const u8) ?BreakpointLocation {
            const offset = vm_helpers.disasmOffset(chunk, plain) orelse return null;
            const span = bytecode.inspect.bestSpan(chunk, offset);
            const file: []const u8 = if (span) |s|
                if (s.file orelse bytecode.inspect.chunkPrimaryFile(chunk, id, self.ev.chunkRegistry())) |f| self.ev.internTable().get(f) else ""
            else
                "";
            return .{
                .chunk_id = id,
                .offset = @intCast(offset),
                .file = file,
                .line = if (span) |s| s.line else 0,
            };
        }

        pub fn appendReferences(self: *Explorer, page: *PageBuilder, subject: vm_refs.Node) !void {
            // A standalone debugger pause has no background job loop. Build the
            // cold index only when a reference-bearing page is actually opened.
            if (self.references.graph == null and self.debug_session != null and !self.references.failed) {
                const graph = vm_refs.Graph.build(self.allocator, self.ev) catch {
                    self.references.failed = true;
                    return;
                };
                self.references.graph = graph;
            }

            const graph = self.references.graph orelse {
                // Preserve the immediately-useful chunk-to-chunk projection while
                // a full heap/chunk graph is being built in a normal :vm session.
                switch (subject) {
                    .object => return,
                    .chunk => |id| {
                        var outgoing: std.ArrayListUnmanaged(ChunkId) = .empty;
                        const chunk = self.ev.getChunk(id) orelse return;
                        try bytecode.inspect.collectRefs(page.arena, chunk, &outgoing);
                        try page.heading(try std.fmt.allocPrint(page.arena, "OUTGOING · {d}", .{outgoing.items.len}));
                        for (outgoing.items) |target| try Explorer.Ops.appendChunkLabel(self, page, "  →", target);
                        return;
                    },
                }
            };

            const outgoing = graph.outgoing(subject);
            try page.heading(try std.fmt.allocPrint(page.arena, "OUTGOING · {d}", .{outgoing.len}));
            for (outgoing) |edge| try Explorer.Ops.appendReferenceLabel(self, page, "  →", vm_refs.node(edge.target));
            try page.line("", .none);
            const incoming = graph.incoming(subject);
            try page.heading(try std.fmt.allocPrint(page.arena, "INCOMING · {d}", .{incoming.len}));
            for (incoming) |edge| try Explorer.Ops.appendReferenceLabel(self, page, "  ←", vm_refs.node(edge.target));
        }

        pub fn appendReferenceLabel(self: *Explorer, page: *PageBuilder, marker: []const u8, reference: vm_refs.Node) !void {
            switch (reference) {
                .chunk => |id| try Explorer.Ops.appendChunkLabel(self, page, marker, id),
                .object => |id| {
                    if (self.heap_index.objects == null)
                        self.heap_index.objects = self.ev.heapObjectSnapshot(self.allocator) catch null;
                    const prefix = try std.fmt.allocPrint(page.arena, "{s} ", .{marker});
                    const width = Explorer.Ops.lineRemainderWidth(self, prefix);
                    const summary = try Explorer.Ops.objectSummary(
                        self,
                        page.arena,
                        id,
                        Explorer.Ops.storePreviewBudget(self, "objects", id, width),
                    );
                    try page.line(try std.fmt.allocPrint(page.arena, "{s}{s}", .{
                        prefix,
                        try Explorer.Ops.canonicalStoreRef(self, page.arena, .objects, id, summary, true),
                    }), .{ .object = id });
                },
            }
        }

        pub fn appendChunkLabel(self: *Explorer, page: *PageBuilder, marker: []const u8, id: ChunkId) !void {
            var text: std.Io.Writer.Allocating = .init(page.arena);
            try text.writer.print("{s} chunk[0x{x}]", .{ marker, id });
            if (self.ev.chunkRegistry().hasQualifiedName(id)) {
                try text.writer.writeByte(' ');
                try self.ev.chunkRegistry().writeQualifiedName(&text.writer, id, self.ev.internTable());
            }
            try page.line(text.written(), .{ .chunk = id });
        }
    };
}
