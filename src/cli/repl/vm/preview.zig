//! Internal VM explorer component.
//!
//! Methods are parameterized by the private explorer state type and wired as
//! direct aliases by `operations.zig`; this module owns the behavior below.

const std = @import("std");
const engine = @import("expr");
const runtime = @import("runtime");
const term_mod = @import("../term.zig");
const width_mod = @import("../width.zig");
const render_mod = @import("../render.zig");
const transcript_mod = @import("../transcript.zig");
const vm_tree = @import("tree.zig");
const vm_model = @import("model.zig");
const vm_helpers = @import("semantics.zig");
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

        // -- drawing -----------------------------------------------------------------

        pub fn drawSession(
            self: *Explorer,
            arena: std.mem.Allocator,
            w: *std.Io.Writer,
            prompt_renderer: *render_mod.Renderer,
            prompt_view: render_mod.View,
            measured_prompt_rows: usize,
            capture: *const transcript_mod.Capture,
            prompt_active: bool,
        ) !void {
            var frame = tui.Frame.init(w, self.color_depth, width_mod.cpWidth);
            const size = term_mod.size();
            const cols = @max(@as(usize, 1), size.cols);
            const screen_rows = @max(@as(usize, 3), size.rows);
            const prompt_rows = @min(measured_prompt_rows, screen_rows - 2);
            const prompt_start = screen_rows - prompt_rows;
            const upper_rows = prompt_start -| 2;

            var explorer_rows: usize = 0;
            var transcript_rows = upper_rows;
            // The explorer stays visible even while the prompt is active: the prompt
            // claims only its own rows at the very bottom, so entering `:`/`i` no
            // longer blows the tree/inspector away.
            if (upper_rows >= 7) {
                transcript_rows = @min(@max(@as(usize, 2), upper_rows / 5), 5);
                explorer_rows = upper_rows - transcript_rows - 1;
            }

            if (explorer_rows > 0 and (self.viewport.cols != cols or self.viewport.rows != explorer_rows)) {
                self.viewport.cols = cols;
                self.viewport.rows = explorer_rows;
                try Explorer.Ops.refreshPage(self, Explorer.Ops.currentKind(self));
            }

            const mode: []const u8 = if (prompt_active) "repl" else if (self.navigation.focus == .tree) "tree" else "inspector";
            var header_buf: [512]u8 = undefined;
            const header = if (self.debug_session) |session|
                std.fmt.bufPrint(&header_buf, " fix vm  ·  ◆ paused/{s}  ·  frame {?d}  ·  {s} ", .{
                    vm_helpers.reasonName(session.reason),
                    Explorer.Ops.currentDebugFrame(self),
                    mode,
                }) catch " fix vm  ·  paused "
            else if (Explorer.Ops.currentChunk(self)) |id|
                std.fmt.bufPrint(&header_buf, " fix vm  ·  chunk[0x{x}]  ·  {s} ", .{
                    id,
                    if (prompt_active) "repl" else if (self.navigation.focus == .tree) "tree" else "inspector",
                }) catch " fix repl "
            else if (Explorer.Ops.currentHeap(self)) |view|
                std.fmt.bufPrint(&header_buf, " fix vm  ·  heap/{s}  ·  {s} ", .{
                    @tagName(view),
                    if (prompt_active) "repl" else if (self.navigation.focus == .tree) "tree" else "inspector",
                }) catch " fix vm "
            else if (Explorer.Ops.currentObject(self)) |id|
                std.fmt.bufPrint(&header_buf, " fix vm  ·  objects[0x{x}]  ·  {s} ", .{
                    id,
                    if (prompt_active) "repl" else if (self.navigation.focus == .tree) "tree" else "inspector",
                }) catch " fix vm "
            else if (Explorer.Ops.currentStoreRecord(self)) |record|
                std.fmt.bufPrint(&header_buf, " fix vm  ·  {s}[0x{x}]  ·  {s} ", .{
                    @tagName(record.view),
                    record.id,
                    if (prompt_active) "repl" else if (self.navigation.focus == .tree) "tree" else "inspector",
                }) catch " fix vm "
            else
                std.fmt.bufPrint(&header_buf, " fix vm  ·  help  ·  {s} ", .{
                    if (prompt_active) "repl" else if (self.navigation.focus == .tree) "tree" else "inspector",
                }) catch " fix vm ";
            try frame.bar(1, header, cols, .header);

            if (explorer_rows > 0) {
                try Explorer.Ops.drawExplorerBody(self, arena, &frame, 2, explorer_rows, cols);
                const separator_row = 2 + explorer_rows;
                try frame.clearRow(separator_row);
                const separator = " ─ transcript ";
                try frame.at(separator_row, 1);
                try frame.text(separator, 0, cols, .muted);
            }

            const transcript_start = 2 + explorer_rows + @intFromBool(explorer_rows > 0);
            try Explorer.Ops.drawTranscript(self, &frame, transcript_start, transcript_rows, cols, capture.written());

            var footer_buf: [512]u8 = undefined;
            const footer = if (prompt_active and capture.omitted() > 0)
                std.fmt.bufPrint(&footer_buf, " Enter evaluate · Esc explorer · Ctrl-D leave VM · Tab complete · {Bi} omitted ", .{capture.omitted()}) catch " Esc explorer "
            else if (prompt_active)
                " Enter evaluate · Esc explorer · Ctrl-D leave VM · Tab complete · Ctrl-R history "
            else if (self.debug_session != null)
                " s step · n next · f finish · c continue · p break · ↵ inspect · i expr · q abort "
            else if (Explorer.Ops.filterActive(self))
                std.fmt.bufPrint(&footer_buf, " filter '{s}' · F edit · Esc up/clear · q exit · Tab pane · ↵ inspect ", .{self.tree.filter_query.items}) catch " filtered "
            else
                " Esc up · q exit · i expr · : cmd · Tab pane · p break · F filter · ↵ inspect ";
            try frame.bar(screen_rows, footer, cols, .footer);

            prompt_renderer.invalidate();
            if (prompt_active) {
                try frame.at(prompt_start, 1);
                try frame.cursor(true);
                try prompt_renderer.draw(w, prompt_view);
            } else {
                try frame.cursor(false);
            }
        }

        pub fn drawExplorerBody(self: *Explorer, arena: std.mem.Allocator, frame: *tui.Frame, first_row: usize, rows: usize, cols: usize) !void {
            const layout_now = Explorer.Ops.layout(self);
            Explorer.Ops.clampScroll(self);
            self.navigation.tree_selection = @min(self.navigation.tree_selection, self.tree.rows.items.len -| 1);
            for (0..rows) |row| {
                const screen_row = first_row + row;
                try frame.clearRow(screen_row);
                if (layout_now.split) {
                    try frame.at(screen_row, 1);
                    try Explorer.Ops.drawChunkRow(self, arena, frame, row, layout_now.sidebar_width, rows);
                    const inspector_focused = self.navigation.focus == .subject;
                    try Explorer.Ops.drawFocusDivider(self, frame, screen_row, layout_now.sidebar_width + 1, inspector_focused);
                    try frame.at(screen_row, layout_now.main_col);
                    try Explorer.Ops.drawDisasmRow(self, frame, row, layout_now.main_width);
                } else if (self.navigation.focus == .tree) {
                    try frame.at(screen_row, 1);
                    try Explorer.Ops.drawChunkRow(self, arena, frame, row, cols, rows);
                } else {
                    try frame.at(screen_row, 1);
                    try Explorer.Ops.drawDisasmRow(self, frame, row, layout_now.main_width);
                }
            }

            // Peeks are overlays, not columns: moving the selection no longer
            // changes either pane's width or reflows the inspector.
            const popup_width = Explorer.Ops.hoverMaxOuterWidth(self, cols, layout_now) -| 2;
            const popup = if (self.navigation.focus == .tree and !Explorer.Ops.selectedTreeRowIsCurrentSubject(self))
                try Explorer.Ops.previewLines(self, arena, popup_width)
            else if (Explorer.Ops.detailPreviewAction(self) != null)
                try Explorer.Ops.detailPreviewLines(self, arena, popup_width)
            else
                &.{};
            if (popup.len > 1 and cols >= 40 and rows >= 6)
                try Explorer.Ops.drawHoverPopup(self, arena, frame, first_row, rows, cols, layout_now, popup);
        }

        pub fn previewRole(self: *const Explorer) tui.Role {
            if (self.navigation.focus == .subject) return switch (Explorer.Ops.detailPreviewAction(self) orelse return .section) {
                .chunk => .chunk,
                .object, .store_record => .object,
                else => .section,
            };
            if (self.navigation.tree_selection >= self.tree.rows.items.len) return .section;
            return switch (self.tree.rows.items[self.navigation.tree_selection]) {
                .chunk => .chunk,
                .object, .store_record, .heap => .object,
                .range => .range,
                .name => .name,
                else => .section,
            };
        }

        pub fn hoverMaxOuterWidth(self: *const Explorer, cols: usize, layout_now: Layout) usize {
            const available = if (self.navigation.focus == .tree)
                (if (layout_now.split) cols -| layout_now.sidebar_width -| 2 else cols * 2 / 3)
            else
                cols * 2 / 3;
            return @min(@as(usize, 76), available);
        }

        pub fn drawHoverPopup(
            self: *Explorer,
            arena: std.mem.Allocator,
            frame: *tui.Frame,
            first_row: usize,
            rows: usize,
            cols: usize,
            layout_now: Layout,
            lines: []const []const u8,
        ) !void {
            const max_outer = Explorer.Ops.hoverMaxOuterWidth(self, cols, layout_now);
            if (max_outer < 4) return;
            var desired: usize = @min(@as(usize, 28), max_outer);
            for (lines) |line| desired = @max(desired, tui.displayWidth(line, width_mod.cpWidth) + 2);
            const outer_width = @min(max_outer, desired);
            const content_width = outer_width - 2;
            const body_total = lines.len - 1;
            const body_visible = @min(body_total, rows - 3);
            const body_start = self.preview.window(body_total, body_visible);
            const visible = body_visible + 1;
            const outer_height = visible + 2;
            const preview_heading = if (body_total > body_visible)
                try std.fmt.allocPrint(arena, "{s} · Alt-j/k · {d}-{d}/{d}", .{
                    lines[0],
                    body_start + 1,
                    body_start + body_visible,
                    body_total,
                })
            else
                lines[0];

            const anchor_row = if (self.navigation.focus == .tree)
                Explorer.Ops.treeSelectionSlot(self, if (layout_now.split) layout_now.sidebar_width else cols, rows) orelse 0
            else
                self.navigation.detail_selection -| self.navigation.scroll;
            // Put the first content row level with the selected row whenever there
            // is room: the popup reads as attached to the cursor instead of as a
            // remote panel.
            const top = first_row + @min(anchor_row -| 1, rows - outer_height);
            const left = if (self.navigation.focus == .tree)
                if (layout_now.split)
                    layout_now.main_col
                else
                    @min(cols / 3 + 1, cols - outer_width + 1)
            else
                cols - outer_width + 1;
            const role = Explorer.Ops.previewRole(self);
            const fill = try arena.alloc(u8, content_width);
            @memset(fill, ' ');
            var horizontal: std.Io.Writer.Allocating = .init(arena);
            for (0..content_width) |_| try horizontal.writer.writeAll("─");

            try frame.at(top, left);
            try frame.text("╭", 0, 1, role);
            try frame.text(horizontal.written(), 0, content_width, role);
            try frame.text("╮", 0, 1, role);

            for (0..visible) |i| {
                const line_index = if (i == 0) 0 else 1 + body_start + i - 1;
                const display_line = if (i == 0) preview_heading else lines[line_index];
                const screen_row = top + 1 + i;
                try frame.at(screen_row, left);
                try frame.text("│", 0, 1, role);
                try frame.at(screen_row, left + 1);
                try frame.text(fill, 0, content_width, .plain);
                try frame.at(screen_row, left + 1);
                const line_width = tui.displayWidth(display_line, width_mod.cpWidth);
                if (line_width > content_width and content_width > 0) {
                    try frame.text(display_line, 0, content_width -| 1, if (i == 0) role else .plain);
                    try frame.at(screen_row, left + outer_width - 2);
                    try frame.text("…", 0, 1, if (i == 0) role else .plain);
                } else {
                    try frame.text(display_line, 0, content_width, if (i == 0) role else .plain);
                }
                try frame.at(screen_row, left + outer_width - 1);
                try frame.text("│", 0, 1, role);
            }

            const bottom = top + outer_height - 1;
            try frame.at(bottom, left);
            try frame.text("╰", 0, 1, role);
            try frame.text(horizontal.written(), 0, content_width, role);
            try frame.text("╯", 0, 1, role);
        }

        /// A compact preview of the highlighted tree row for the right-hand pane.
        /// This reflects the cursor, not the open inspector, so you can look ahead
        /// while browsing without leaving the current subject.
        pub fn previewLines(self: *Explorer, arena: std.mem.Allocator, content_width: usize) ![]const []const u8 {
            var lines: std.ArrayListUnmanaged([]const u8) = .empty;
            try lines.append(arena, " PREVIEW");
            if (self.navigation.tree_selection >= self.tree.rows.items.len) return lines.items;
            switch (self.tree.rows.items[self.navigation.tree_selection]) {
                .chunk => |entry| {
                    try lines.append(arena, try std.fmt.allocPrint(arena, " chunk[0x{x}]", .{entry.id}));
                    if (self.ev.chunkRegistry().hasQualifiedName(entry.id)) {
                        var name: std.Io.Writer.Allocating = .init(arena);
                        self.ev.chunkRegistry().writeQualifiedName(&name.writer, entry.id, self.ev.internTable()) catch {};
                        if (name.written().len > 0) try lines.append(arena, try std.fmt.allocPrint(arena, " {s}", .{name.written()}));
                    }
                    if (self.ev.getChunk(entry.id)) |chunk| {
                        try lines.append(arena, try std.fmt.allocPrint(arena, " {d} bytes · {d} consts", .{ chunk.code.len, chunk.constants.len }));
                        try lines.append(arena, try std.fmt.allocPrint(arena, " arity {d} · {d} spans", .{ chunk.arity, chunk.source_map.len }));
                        if (chunk.source_map.len > 0) {
                            try lines.append(arena, "");
                            const src = Explorer.Ops.chunkSourceText(self, entry.id, chunk);
                            for (chunk.source_map, 0..) |sm, i| {
                                if (i >= 6) break;
                                const snip = vm_helpers.spanSnippet(arena, src, sm.span, content_width -| 1) catch "";
                                if (snip.len > 0) try lines.append(arena, try std.fmt.allocPrint(arena, " {s}", .{snip}));
                            }
                        }
                        try Explorer.Ops.appendChunkCodePreview(self, &lines, arena, entry.id, chunk, preview_line_cap);
                    }
                },
                .name => |entry| {
                    const label = if (entry.id == vm_tree.root_node_id) "<root>" else if (self.tree_index.node(entry.id)) |n| n.label else "?";
                    try lines.append(arena, try std.fmt.allocPrint(arena, " {s}", .{label}));
                    try lines.append(arena, try std.fmt.allocPrint(arena, " {d} chunks in subtree", .{self.tree_index.statsOf(entry.id).chunks}));
                },
                .object => |entry| {
                    const ref_width = content_width -| 1;
                    const summary = try Explorer.Ops.objectSummary(
                        self,
                        arena,
                        entry.id,
                        Explorer.Ops.storePreviewBudget(self, "objects", entry.id, ref_width),
                    );
                    try lines.append(arena, try std.fmt.allocPrint(arena, " {s}", .{
                        try Explorer.Ops.canonicalStoreRef(self, arena, .objects, entry.id, summary, true),
                    }));
                    try Explorer.Ops.appendObjectPreview(self, &lines, arena, entry.id, content_width);
                },
                .heap => |entry| {
                    try lines.append(arena, try std.fmt.allocPrint(arena, " heap/{s}", .{@tagName(entry.view)}));
                    try lines.append(arena, try std.fmt.allocPrint(arena, " {d} live · {d} reserved", .{ Explorer.Ops.liveStoreCount(self, entry.view), Explorer.Ops.storeCount(self, entry.view) }));
                },
                .debug_frame => |entry| if (self.debug_session) |session| if (entry.index < session.frameCount()) {
                    const info = session.frame(entry.index);
                    try lines.append(arena, try std.fmt.allocPrint(arena, " frame #{d}", .{entry.index}));
                    try lines.append(arena, try std.fmt.allocPrint(arena, " {s}:{d}", .{ if (info.file) |f| std.fs.path.basename(f) else "<repl>", info.line }));
                },
                .store_record => |entry| {
                    const summary = try Explorer.Ops.storeRecordSummary(
                        self,
                        arena,
                        entry.view,
                        entry.id,
                        Explorer.Ops.storePreviewBudget(self, @tagName(entry.view), entry.id, content_width -| 1),
                    );
                    try lines.append(arena, try std.fmt.allocPrint(arena, " {s}", .{
                        try Explorer.Ops.canonicalStoreRef(self, arena, entry.view, entry.id, summary, true),
                    }));
                },
                .category => |entry| {
                    try lines.append(arena, try std.fmt.allocPrint(arena, " {s} section", .{@tagName(entry.kind)}));
                    if (entry.kind == .heap) {
                        // The heap census lives here (it's no longer a browsable folder).
                        const c = self.ev.heapCounts();
                        try lines.append(arena, "");
                        try lines.append(arena, try std.fmt.allocPrint(arena, " objects  {d} live", .{Explorer.Ops.liveStoreCount(self, .objects)}));
                        try lines.append(arena, try std.fmt.allocPrint(arena, " values   {d} live · {d} slots", .{ Explorer.Ops.liveStoreCount(self, .values), c.values }));
                        try lines.append(arena, try std.fmt.allocPrint(arena, " attrs    {d} live · {d} slots", .{ Explorer.Ops.liveStoreCount(self, .attrs), c.attrs }));
                        try lines.append(arena, try std.fmt.allocPrint(arena, " attrpos  {d} live · {d} slots", .{ Explorer.Ops.liveStoreCount(self, .attr_positions), c.attr_positions }));
                        try lines.append(arena, try std.fmt.allocPrint(arena, " intern   {d}", .{Explorer.Ops.liveStoreCount(self, .intern)}));
                        try lines.append(arena, try std.fmt.allocPrint(arena, " builtin  {d}", .{Explorer.Ops.liveStoreCount(self, .builtin)}));
                        if (self.heap_index.stats) |stats| {
                            try lines.append(arena, "");
                            try lines.append(arena, " object types");
                            for (stats.variant_counts, 0..) |count, i| {
                                try lines.append(arena, try std.fmt.allocPrint(arena, "  {s:<20} {d}", .{
                                    runtime.ObjectHeap.Stats.variantName(i),
                                    count,
                                }));
                            }
                        }
                    }
                },
                .range, .debug_root, .debug_value => {},
            }
            return lines.items;
        }

        /// The right-hand preview when inspecting a value subject: a peek at the
        /// object/chunk that the selected reference row points to, so you can see a
        /// member's contents without leaving the current subject.
        pub fn detailPreviewLines(self: *Explorer, arena: std.mem.Allocator, content_width: usize) ![]const []const u8 {
            var lines: std.ArrayListUnmanaged([]const u8) = .empty;
            try lines.append(arena, " PREVIEW");
            const action = Explorer.Ops.detailPreviewAction(self) orelse return lines.items;
            switch (action) {
                .object => |id| {
                    const ref_width = content_width -| 1;
                    try lines.append(arena, try std.fmt.allocPrint(arena, " {s}", .{
                        try Explorer.Ops.canonicalStoreRef(
                            self,
                            arena,
                            .objects,
                            id,
                            try Explorer.Ops.objectSummary(self, arena, id, Explorer.Ops.storePreviewBudget(self, "objects", id, ref_width)),
                            true,
                        ),
                    }));
                    try Explorer.Ops.appendObjectPreview(self, &lines, arena, id, content_width);
                },
                .chunk => |id| {
                    try lines.append(arena, try std.fmt.allocPrint(arena, " chunk[0x{x}]", .{id}));
                    if (self.ev.getChunk(id)) |chunk| {
                        try lines.append(arena, try std.fmt.allocPrint(arena, " {d} bytes · {d} consts", .{ chunk.code.len, chunk.constants.len }));
                        if (chunk.source_map.len > 0) {
                            const snip = vm_helpers.spanSnippet(
                                arena,
                                Explorer.Ops.chunkSourceText(self, id, chunk),
                                chunk.source_map[0].span,
                                content_width -| 1,
                            ) catch "";
                            if (snip.len > 0) try lines.append(arena, try std.fmt.allocPrint(arena, " {s}", .{snip}));
                        }
                        try Explorer.Ops.appendChunkCodePreview(self, &lines, arena, id, chunk, preview_line_cap);
                    }
                },
                .store_record => |record| {
                    const summary = try Explorer.Ops.storeRecordSummary(
                        self,
                        arena,
                        record.view,
                        record.id,
                        Explorer.Ops.storePreviewBudget(self, @tagName(record.view), record.id, content_width -| 1),
                    );
                    try lines.append(arena, try std.fmt.allocPrint(arena, " {s}", .{
                        try Explorer.Ops.canonicalStoreRef(self, arena, record.view, record.id, summary, true),
                    }));
                },
                else => {},
            }
            return lines.items;
        }

        /// Add a bounded canonical disassembly to a preview. This deliberately uses
        /// the same formatter as the full code view, including builtin resolution
        /// and syntax/source annotations, but excludes cold tables.
        pub fn appendChunkCodePreview(
            self: *Explorer,
            lines: *std.ArrayListUnmanaged([]const u8),
            arena: std.mem.Allocator,
            id: ChunkId,
            chunk: *const bytecode.Chunk,
            limit: usize,
        ) !void {
            // A preview must stay cheap even when the highlighted chunk is huge.
            // The formatter may hit the fixed writer's limit; the complete rows it
            // produced before that point are still a useful bounded preview.
            var text: std.Io.Writer = .fixed(try arena.alloc(u8, 16 * 1024));
            const symbols: disasm.Symbols = .{ .intern = self.ev.internTable(), .registry = self.ev.chunkRegistry() };
            var options = disasm_options;
            options.show_header = false;
            options.show_constants = false;
            options.show_code = true;
            options.show_bytes = false;
            options.color_depth = self.color_depth;
            options.line_width = 0;
            disasm.writeChunk(arena, &text, id, chunk, symbols, options) catch {};

            try lines.append(arena, "");
            try lines.append(arena, " CODE");
            var it = std.mem.splitScalar(u8, text.buffered(), '\n');
            var shown: usize = 0;
            while (it.next()) |line| {
                if (line.len == 0 or std.mem.startsWith(u8, base.terminal_text.stripAnsiInPlace(try arena.dupe(u8, line)), "chunk[")) continue;
                try lines.append(arena, try std.fmt.allocPrint(arena, " {s}", .{line}));
                shown += 1;
                if (shown == limit) {
                    if (it.peek() != null) try lines.append(arena, " …");
                    break;
                }
            }
        }

        /// Enrich heap-object previews where metadata alone is least useful. In
        /// particular, bytecode thunks show their body and its first instructions.
        pub fn appendObjectPreview(
            self: *Explorer,
            lines: *std.ArrayListUnmanaged([]const u8),
            arena: std.mem.Allocator,
            id: runtime.types.ObjectId,
            content_width: usize,
        ) !void {
            // A standalone debugger pause does not run the asynchronous heap-index
            // jobs. Build its live-object bitmap once, synchronously while the VM is
            // paused, so stack thunks can still expose their bodies in previews.
            if (self.heap_index.objects == null and self.debug_session != null)
                self.heap_index.objects = self.ev.heapObjectSnapshot(self.allocator) catch null;
            const snapshot = if (self.heap_index.objects) |*snap| snap else return;
            const info = self.ev.inspectHeapObject(snapshot, id) catch return;
            switch (info) {
                .attrs => if (self.ev.heapAttrsOf(id)) |attrs| {
                    try lines.append(arena, try std.fmt.allocPrint(arena, " attrs · {d} members", .{attrs.len}));
                    for (attrs[0..@min(attrs.len, preview_line_cap)]) |entry| {
                        const name = self.ev.internTable().get(entry.name);
                        const value_width = content_width -| width_mod.strWidth(name) -| 4;
                        const detail = try Explorer.Ops.shallowValueSummary(self, arena, entry.value, value_width);
                        try lines.append(arena, try std.fmt.allocPrint(arena, "  {s} = {s}", .{ name, detail }));
                    }
                    if (attrs.len > preview_line_cap) try lines.append(arena, try std.fmt.allocPrint(
                        arena,
                        "  … {d} more",
                        .{attrs.len - preview_line_cap},
                    ));
                } else |_| {},
                .list => if (self.ev.heapListOf(id)) |items| {
                    try lines.append(arena, try std.fmt.allocPrint(arena, " list · {d} items", .{items.len}));
                    for (items[0..@min(items.len, preview_line_cap)], 0..) |item, i| {
                        var prefix_buf: [32]u8 = undefined;
                        const prefix = std.fmt.bufPrint(&prefix_buf, "  [{d}] ", .{i}) catch "  ";
                        const detail = try Explorer.Ops.shallowValueSummary(
                            self,
                            arena,
                            item,
                            content_width -| width_mod.strWidth(prefix),
                        );
                        try lines.append(arena, try std.fmt.allocPrint(arena, "{s}{s}", .{ prefix, detail }));
                    }
                    if (items.len > preview_line_cap) try lines.append(arena, try std.fmt.allocPrint(
                        arena,
                        "  … {d} more",
                        .{items.len - preview_line_cap},
                    ));
                } else |_| {},
                .thunk => |thunk| {
                    try lines.append(arena, try std.fmt.allocPrint(arena, " state {s} · demanded {s}", .{
                        @tagName(thunk.state),
                        if (thunk.demanded) "yes" else "no",
                    }));
                    switch (thunk.body) {
                        .target => |target| switch (target) {
                            .bytecode => |body| {
                                try lines.append(arena, try std.fmt.allocPrint(arena, " chunk[0x{x}] · {d} captures", .{ body.chunk, body.captures }));
                                if (self.ev.getChunk(body.chunk)) |chunk|
                                    try Explorer.Ops.appendChunkCodePreview(self, lines, arena, body.chunk, chunk, preview_line_cap);
                            },
                            .closure => |value| {
                                const rendered = try Explorer.Ops.renderValueRef(self, arena, value, content_width -| 9, true);
                                try lines.append(arena, try std.fmt.allocPrint(arena, " closure {s}", .{rendered.text}));
                            },
                            .pass_through => |value| {
                                const rendered = try Explorer.Ops.renderValueRef(self, arena, value, content_width -| 7, true);
                                try lines.append(arena, try std.fmt.allocPrint(arena, " value {s}", .{rendered.text}));
                            },
                            .attr_access => |access| try lines.append(arena, try std.fmt.allocPrint(arena, " attribute intern[0x{x}]", .{access.name})),
                            .deferred => |body| try lines.append(arena, try std.fmt.allocPrint(arena, " deferred[0x{x}] · {d} captures", .{ body.id, body.captures })),
                        },
                        .result => |value| {
                            const rendered = try Explorer.Ops.renderValueRef(self, arena, value, content_width -| 8, true);
                            try lines.append(arena, try std.fmt.allocPrint(arena, " result {s}", .{rendered.text}));
                        },
                        .error_name => |name| try lines.append(arena, try std.fmt.allocPrint(arena, " error {s}", .{name})),
                    }
                },
                .builtin_closure => |closure| {
                    try lines.append(arena, try std.fmt.allocPrint(arena, " {s}", .{
                        try Explorer.Ops.locatedValue(
                            self,
                            arena,
                            "builtin",
                            closure.builtin,
                            .builtin,
                            disasm.builtinName(closure.builtin),
                            content_width -| 1,
                            true,
                        ),
                    }));
                    try lines.append(arena, try std.fmt.allocPrint(arena, " {d} arguments", .{closure.args}));
                },
                .closure => |closure| if (self.ev.getChunk(closure.chunk)) |chunk|
                    try Explorer.Ops.appendChunkCodePreview(self, lines, arena, closure.chunk, chunk, preview_line_cap),
                else => {},
            }
        }
    };
}
