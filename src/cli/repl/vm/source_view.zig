//! Internal VM explorer component.
//!
//! Methods are parameterized by the private explorer state type and wired as
//! direct aliases by `operations.zig`; this module owns the behavior below.

const std = @import("std");
const engine = @import("expr");
const runtime = @import("runtime");
const term_mod = @import("../term.zig");
const width_mod = @import("../width.zig");
const editor_mod = @import("../editor.zig");
const render_mod = @import("../render.zig");
const vm_model = @import("model.zig");
const vm_source = @import("source.zig");
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

pub fn Methods(comptime Explorer: type) type {
    return struct {
        pub fn sessionPromptView(self: *Explorer, editor: *editor_mod.Editor, arena: std.mem.Allocator) !render_mod.View {
            _ = self;
            var view: render_mod.View = .{
                .prompt = "fix> ",
                .cont_prompt = "...> ",
                .text = editor.text(),
                .cursor = editor.cursor,
            };
            var search_buf: [96]u8 = undefined;
            if (editor.searchPrompt(&search_buf)) |prompt| {
                view.prompt = try arena.dupe(u8, prompt);
                view.cont_prompt = view.prompt;
            }
            const menu = editor.menuLines();
            if (menu.len > 0) view.overlay = try render_mod.formatColumns(arena, menu, term_mod.size().cols, 8);
            return view;
        }

        /// Index at most the newest transcript lines. The byte capture is already
        /// bounded; bounding the line projection too prevents millions of tiny
        /// output lines from turning into millions of UI allocations.
        pub fn rebuildTranscriptLines(self: *Explorer, text: []const u8) !void {
            self.transcript_lines.clearRetainingCapacity();
            var end = text.len;
            while (end > 0 and self.transcript_lines.items.len < 2000) {
                const line_end = if (text[end - 1] == '\n') end - 1 else end;
                const newline = std.mem.lastIndexOfScalar(u8, text[0..line_end], '\n');
                const start = if (newline) |at| at + 1 else 0;
                try self.transcript_lines.append(self.allocator, .{ .start = start, .end = line_end });
                if (newline) |at| {
                    end = at;
                } else {
                    break;
                }
            }
            std.mem.reverse(LineRange, self.transcript_lines.items);
        }

        pub fn appendSourceDocument(
            self: *Explorer,
            document: *PageBuilder,
            id: ChunkId,
            chunk: *const bytecode.Chunk,
            focused_span: ?bytecode.Chunk.SourceSpan,
        ) !void {
            const selecting_span = self.source_session == id;
            const span = if (selecting_span)
                focused_span orelse vm_source.first(chunk) orelse chunk.body_span
            else
                chunk.body_span orelse vm_source.first(chunk);
            const shown_span = span orelse {
                try document.heading("SOURCE");
                try document.line("(no source information)", .none);
                return;
            };

            const label, const source = if (shown_span.file) |file| blk: {
                const path = self.ev.internTable().get(file);
                break :blk .{ path, self.ev.readSourceFile(path) catch null };
            } else blk: {
                const direct = if (self.session_host) |host| host.directSource(id) else null;
                break :blk .{ "<repl expression>", direct };
            };

            try appendSourceHeading(self, document, id, chunk, shown_span);
            try document.line(try std.fmt.allocPrint(document.arena, "{s}:{d}:{d}", .{ label, shown_span.line, shown_span.column }), .none);
            const bytes = source orelse {
                try document.line("(source text is unavailable)", .none);
                return;
            };
            try appendSourceExcerpt(
                self,
                document,
                bytes,
                shown_span,
                id,
                vm_source.location(id, chunk, shown_span),
                selecting_span,
                false,
                null,
            );
        }

        pub fn appendSourceDocumentWithText(
            self: *Explorer,
            document: *PageBuilder,
            id: ChunkId,
            chunk: *const bytecode.Chunk,
            source: []const u8,
            suggested_span: bytecode.Chunk.SourceSpan,
            returned_value: ?runtime.value.Value,
        ) !void {
            const span = if (vm_source.location(id, chunk, suggested_span) != null)
                suggested_span
            else
                vm_source.first(chunk) orelse suggested_span;
            try appendSourceHeading(self, document, id, chunk, span);
            try document.line(try std.fmt.allocPrint(document.arena, "{s}:{d}:{d}", .{
                if (span.file) |file| self.ev.internTable().get(file) else "<repl expression>",
                span.line,
                span.column,
            }), .none);
            try appendSourceExcerpt(
                self,
                document,
                source,
                span,
                id,
                vm_source.location(id, chunk, span),
                true,
                self.source_session != id,
                returned_value,
            );
        }

        pub fn appendSourceHeading(
            self: *const Explorer,
            document: *PageBuilder,
            id: ChunkId,
            chunk: *const bytecode.Chunk,
            span: bytecode.Chunk.SourceSpan,
        ) !void {
            const stats = vm_source.stats(chunk, span);
            if (stats.total == 0) {
                try document.heading("SOURCE");
            } else if (self.source_session == id) {
                try document.line(
                    try std.fmt.allocPrint(document.arena, "SOURCE · {d}/{d} subexpressions", .{ stats.index, stats.total }),
                    .{ .source = id },
                );
            } else {
                try document.line(
                    try std.fmt.allocPrint(document.arena, "SOURCE · {d} subexpressions", .{stats.total}),
                    .{ .source = id },
                );
            }
        }

        pub fn focusedSourceSpan(self: *const Explorer, chunk_id: ChunkId) ?bytecode.Chunk.SourceSpan {
            const focus = self.source_focus orelse return null;
            return if (focus.chunk_id == chunk_id) focus.span else null;
        }

        /// Apply a newly selected source span by rebuilding the unified document.
        /// Afterwards, find the same source row by location so the cursor does not
        /// jump when the excerpt's line count changes.
        pub fn selectedSourceChanged(self: *Explorer) !void {
            const source_session = self.source_session orelse return;
            const selected = selectedSourceLocation(self) orelse return;
            if (selected.chunk_id != source_session) return;
            self.source_focus = .{ .chunk_id = selected.chunk_id, .span = selected.span.? };

            const source_document = switch (Explorer.Ops.view_state.currentKind(self)) {
                .debug_frame, .chunk => true,
                else => false,
            };
            if (!source_document) return;

            const kind = Explorer.Ops.view_state.currentKind(self);
            try Explorer.Ops.pages.refreshPage(self, kind);
            for (self.page.locations, 0..) |candidate, i| {
                const location = candidate orelse continue;
                const span = location.span orelse continue;
                if (location.chunk_id == selected.chunk_id and
                    location.offset == selected.offset and
                    span.offset == selected.span.?.offset and
                    span.len == selected.span.?.len)
                {
                    self.navigation.detail_selection = i;
                    Explorer.Ops.controller.ensureDetailVisible(self);
                    break;
                }
            }
        }

        pub fn selectedSourceLocation(self: *const Explorer) ?BreakpointLocation {
            if (self.navigation.detail_selection >= self.page.locations.len) return null;
            const location = self.page.locations[self.navigation.detail_selection] orelse return null;
            return if (location.span != null) location else null;
        }

        pub fn appendSourceExcerpt(
            self: *Explorer,
            document: *PageBuilder,
            source: []const u8,
            span: bytecode.Chunk.SourceSpan,
            chunk_id: ?ChunkId,
            location: ?BreakpointLocation,
            focus_active: bool,
            show_instruction_pointer: bool,
            returned_value: ?runtime.value.Value,
        ) !void {
            const focus_start = @min(@as(usize, span.offset), source.len);
            const focus_end = @min(focus_start +| @as(usize, span.len), source.len);

            var start = focus_start;
            var lines_before: usize = 0;
            while (start > 0 and lines_before < 2) {
                start -= 1;
                if (source[start] == '\n') {
                    lines_before += 1;
                    if (lines_before == 2) start += 1;
                }
            }
            var end = focus_end;
            var lines_after: usize = 0;
            while (end < source.len and lines_after < 3) : (end += 1) {
                if (source[end] == '\n') lines_after += 1;
            }

            var line_number = @as(usize, span.line) -| lines_before;
            var cursor = start;
            var shown: usize = 0;
            while (cursor <= end and cursor < source.len and shown < 24) : (shown += 1) {
                const newline = std.mem.indexOfScalarPos(u8, source, cursor, '\n') orelse source.len;
                const line_end = @min(newline, end);
                const active = cursor < focus_end and line_end >= focus_start;
                var rendered: std.Io.Writer.Allocating = .init(document.arena);
                if (active and show_instruction_pointer) {
                    if (self.color_depth.enabled()) {
                        try base.terminal_color.foreground(&rendered.writer, self.color_depth, base.terminal_color.hueColor(3), true);
                    } else {
                        try rendered.writer.writeAll("\x1b[1m");
                    }
                    try rendered.writer.writeAll("▶");
                    try rendered.writer.writeAll("\x1b[0m");
                } else {
                    try rendered.writer.writeByte(' ');
                }
                try rendered.writer.print(" {d:>5} │ ", .{line_number});
                const shown_end = @min(line_end, cursor +| 4096);
                const selected: ?source_render.Range = if (focus_active and active) blk: {
                    const selected_start = @max(cursor, focus_start);
                    const selected_end = @min(shown_end, @max(focus_end, focus_start +| 1));
                    if (selected_start >= selected_end) break :blk null;
                    break :blk .{ .start = selected_start - cursor, .end = selected_end - cursor };
                } else null;
                const breakpoints = if (chunk_id) |target|
                    try sourceBreakpointRanges(self, document.arena, target, cursor, shown_end)
                else
                    &.{};
                try source_render.writeLine(&rendered.writer, source[cursor..shown_end], .{
                    .color_depth = self.color_depth,
                    .focus = selected,
                    .breakpoints = breakpoints,
                });
                if (line_end > cursor +| 4096) try rendered.writer.writeAll(" …");
                var wrapped_result: ?[]const u8 = null;
                const result_here = active and returned_value != null and focus_end <= line_end;
                if (result_here) {
                    var annotation: std.Io.Writer.Allocating = .init(document.arena);
                    try writeReturnAnnotation(
                        self,
                        document.arena,
                        &annotation.writer,
                        returned_value.?,
                        Explorer.Ops.view_state.layout(self).main_width -| 14,
                    );
                    if (tui.displayWidth(rendered.written(), width_mod.cpWidth) +
                        tui.displayWidth(annotation.written(), width_mod.cpWidth) <= Explorer.Ops.view_state.layout(self).main_width -| 2)
                    {
                        try rendered.writer.writeAll(annotation.written());
                    } else {
                        wrapped_result = try std.fmt.allocPrint(document.arena, "        │ {s}", .{annotation.written()[2..]});
                    }
                }
                var row_action: RowAction = if (active and location != null and self.source_session == location.?.chunk_id)
                    .instruction
                else
                    .none;
                if (result_here and wrapped_result == null) {
                    const result_action = Explorer.Ops.pages.valueRowAction(self, returned_value.?);
                    if (result_action != .none) row_action = result_action;
                }
                if (active and location != null) {
                    try document.lineAt(rendered.written(), row_action, location.?);
                } else {
                    try document.line(rendered.written(), row_action);
                }
                if (wrapped_result) |result|
                    try document.line(result, Explorer.Ops.pages.valueRowAction(self, returned_value.?));
                line_number += 1;
                if (newline >= end or newline == source.len) break;
                cursor = newline + 1;
            }
        }

        /// A return result is a single styled badge. Value digests deliberately
        /// render without their own SGR resets here so the background remains
        /// continuous across the whole result.
        pub fn writeReturnAnnotation(
            self: *Explorer,
            arena: std.mem.Allocator,
            writer: *std.Io.Writer,
            value: runtime.value.Value,
            max_cells: usize,
        ) !void {
            try writer.writeAll("  ");
            if (self.color_depth.enabled()) {
                if (self.return_flash) {
                    try base.terminal_color.background(writer, self.color_depth, base.terminal_color.hueColor(3));
                    try base.terminal_color.foreground(writer, self.color_depth, .{ 15, 23, 30 }, true);
                } else {
                    try base.terminal_color.background(writer, self.color_depth, .{ 78, 62, 112 });
                    try base.terminal_color.foreground(writer, self.color_depth, .{ 246, 248, 250 }, true);
                }
            } else {
                try writer.writeAll(if (self.return_flash) "\x1b[1;7m" else "\x1b[1;4m");
            }
            try writer.writeAll("⇒ ");
            const rendered = try Explorer.Ops.pages.renderValue(self, arena, value, max_cells, false);
            try writer.writeAll(rendered.text);
            try writer.writeAll("\x1b[0m");
        }

        pub fn sourceBreakpointRanges(
            self: *const Explorer,
            arena: std.mem.Allocator,
            chunk_id: ChunkId,
            line_start: usize,
            line_end: usize,
        ) ![]const source_render.Range {
            var ranges: std.ArrayListUnmanaged(source_render.Range) = .empty;
            for (self.ev.listBreakpoints()) |request| {
                if (request.span_chunk != chunk_id) continue;
                const span = request.span orelse continue;
                const start = @max(line_start, @as(usize, span.offset));
                const end = @min(line_end, @as(usize, span.offset) +| @as(usize, span.len));
                if (start >= end) continue;
                try ranges.append(arena, .{
                    .start = start - line_start,
                    .end = end - line_start,
                });
            }
            return ranges.items;
        }

        /// Resolve the source text a chunk was compiled from (its file, or the
        /// remembered `:vm` repl expression), for source-span breakpoint snippets.
        pub fn chunkSourceText(self: *Explorer, id: ChunkId, chunk: *const bytecode.Chunk) ?[]const u8 {
            for (chunk.source_map) |entry| if (entry.span.file) |file|
                return self.ev.readSourceFile(self.ev.internTable().get(file)) catch null;
            if (chunk.body_span) |span| if (span.file) |file|
                return self.ev.readSourceFile(self.ev.internTable().get(file)) catch null;
            if (self.session_host) |host| return host.directSource(id);
            return null;
        }
    };
}
