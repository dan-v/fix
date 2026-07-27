//! Internal VM explorer component.
//!
//! Methods are parameterized by the private explorer state type and wired as
//! direct aliases by `operations.zig`; this module owns the behavior below.

const std = @import("std");
const engine = @import("expr");
const runtime = @import("runtime");
const term_mod = @import("../term.zig");
const keys_mod = @import("../keys.zig");
const width_mod = @import("../width.zig");
const vm_navigation = @import("navigation.zig");
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
        const RenderedValue = Explorer.Ops.pages.RenderedValue;
        const Layout = Explorer.Ops.view_state.Layout;
        const StoreRecord = Explorer.Ops.view_state.StoreRecord;
        const TreeViewport = Explorer.Ops.tree_render.TreeViewport;
        const TreeCell = Explorer.Ops.tree_render.TreeCell;
        const DebugOutcome = Explorer.Ops.debug_view.DebugOutcome;
        const DebugCloseIntent = Explorer.Ops.debug_view.DebugCloseIntent;
        const range_leaf = Explorer.range_leaf;
        const range_branch = Explorer.range_branch;
        const preview_line_cap = Explorer.preview_line_cap;

        /// Escape unwinds one interaction layer. It leaves an in-place source
        /// session first, then the inspector, then nested/expanded tree rows. Only
        /// an Escape at the tree root asks the caller to leave the explorer.
        pub fn escapeLayer(self: *Explorer) !bool {
            switch (vm_navigation.escapeAction(.{
                .source_active = self.source_session != null,
                .focus = self.navigation.focus,
                .filter_active = Explorer.Ops.tree_projection.filterActive(self),
                .tree_can_move_up = Explorer.Ops.tree_projection.treeSelectionCanMoveUp(self),
            })) {
                .leave_source => {
                    try Explorer.Ops.controller.leaveSourceSession(self, self.source_session.?);
                    self.status_msg = "";
                    return true;
                },
                .focus_tree => {
                    self.navigation.focus = .tree;
                    self.preview.reset();
                    Explorer.Ops.tree_projection.selectCurrentTreeSubject(self);
                    return true;
                },
                .clear_filter => {
                    self.tree.filter_query.clearRetainingCapacity();
                    try Explorer.Ops.tree_projection.rebuildTreeForCurrent(self);
                    self.status_msg = "(filter cleared)";
                    return true;
                },
                .tree_up => {
                    try Explorer.Ops.tree_projection.collapseTreeRow(self);
                    self.preview.reset();
                    return true;
                },
                .exit => return false,
            }
        }

        /// `.push` records a back/forward history entry (following a reference link,
        /// or entering a debug pause). `.replace` swaps the current view in place so
        /// ordinary tree browsing doesn't accumulate a noisy history trail.
        pub const OpenMode = enum { push, replace };

        pub fn open(self: *Explorer, kind: Visit.Kind) !void {
            return Explorer.Ops.controller.openMode(self, kind, .push);
        }

        pub fn openMode(self: *Explorer, kind: Visit.Kind, mode: OpenMode) !void {
            // Save current position into the top-of-stack visit.
            if (self.navigation.back.items.len > 0) {
                const top = &self.navigation.back.items[self.navigation.back.items.len - 1];
                top.scroll = self.navigation.scroll;
                top.tree_selection = self.navigation.tree_selection;
                top.detail_selection = self.navigation.detail_selection;
                top.x_scroll = self.navigation.x_scroll;
            }
            if (mode == .replace and self.navigation.back.items.len > 0) {
                self.navigation.back.items[self.navigation.back.items.len - 1] = .{ .kind = kind };
            } else {
                try self.navigation.back.append(self.allocator, .{ .kind = kind });
            }
            self.navigation.forward.clearRetainingCapacity();
            self.source_focus = null;
            self.source_session = null;
            self.preview.reset();
            try Explorer.Ops.pages.refreshPage(self, kind);
            self.navigation.scroll = 0;
            self.navigation.detail_selection = Explorer.Ops.controller.firstActionableRow(self) orelse 0;
            try Explorer.Ops.source_view.selectedSourceChanged(self);
            // A tree row is already visible, so opening it must not rebuild or
            // re-project the tree. Only subjects reached from outside the tree
            // reveal their path/store.
            if (mode == .push) switch (kind) {
                .chunk => |id| {
                    try Explorer.Ops.tree_projection.expandFocusedPath(self, id);
                    try Explorer.Ops.tree_projection.rebuildTree(self, id);
                },
                .object => |id| {
                    self.tree.projected_heap = .{ .view = .objects, .id = id };
                    self.tree.categories[@intFromEnum(Category.heap)] = true;
                    try Explorer.Ops.tree_projection.rebuildTreeForCurrent(self);
                },
                .store_record => |record| {
                    self.tree.projected_heap = .{ .view = record.view, .id = record.id };
                    self.tree.categories[@intFromEnum(Category.heap)] = true;
                    try Explorer.Ops.tree_projection.rebuildTreeForCurrent(self);
                },
                .heap => {
                    self.tree.categories[@intFromEnum(Category.heap)] = true;
                    try Explorer.Ops.tree_projection.rebuildTreeForCurrent(self);
                },
                .debug_frame, .debug_value => try Explorer.Ops.tree_projection.rebuildTreeForCurrent(self),
                .help => {},
            };
            self.navigation.x_scroll = 0;
            // Replacing the subject is tree browsing: keep the cursor in the tree.
            // Pushed visits originate outside it (detail links, debugger entry,
            // commands) and may choose the inspector as their natural destination.
            if (mode == .push) switch (kind) {
                .help => self.navigation.focus = .subject,
                .heap, .object, .store_record, .debug_frame, .debug_value => self.navigation.focus = .subject,
                .chunk => {},
            };
            self.status_msg = "";
        }

        pub fn back(self: *Explorer) !void {
            if (self.navigation.back.items.len < 2) {
                self.status_msg = "(bottom of history)";
                return;
            }
            try self.navigation.forward.append(self.allocator, self.navigation.back.pop().?);
            const visit = self.navigation.back.items[self.navigation.back.items.len - 1];
            self.source_focus = null;
            self.source_session = null;
            try Explorer.Ops.pages.refreshPage(self, visit.kind);
            switch (visit.kind) {
                .chunk => |id| try Explorer.Ops.tree_projection.expandFocusedPath(self, id),
                else => {},
            }
            try Explorer.Ops.tree_projection.rebuildTreeForCurrent(self);
            self.navigation.scroll = visit.scroll;
            self.navigation.tree_selection = visit.tree_selection;
            self.navigation.detail_selection = visit.detail_selection;
            self.navigation.x_scroll = visit.x_scroll;
            try Explorer.Ops.source_view.selectedSourceChanged(self);
            self.status_msg = "";
        }

        pub fn goForward(self: *Explorer) !void {
            const visit = self.navigation.forward.pop() orelse {
                self.status_msg = "(top of history)";
                return;
            };
            if (self.navigation.back.items.len > 0) {
                const top = &self.navigation.back.items[self.navigation.back.items.len - 1];
                top.scroll = self.navigation.scroll;
                top.tree_selection = self.navigation.tree_selection;
                top.detail_selection = self.navigation.detail_selection;
                top.x_scroll = self.navigation.x_scroll;
            }
            try self.navigation.back.append(self.allocator, visit);
            self.source_focus = null;
            self.source_session = null;
            try Explorer.Ops.pages.refreshPage(self, visit.kind);
            switch (visit.kind) {
                .chunk => |id| try Explorer.Ops.tree_projection.expandFocusedPath(self, id),
                else => {},
            }
            try Explorer.Ops.tree_projection.rebuildTreeForCurrent(self);
            self.navigation.scroll = visit.scroll;
            self.navigation.tree_selection = visit.tree_selection;
            self.navigation.detail_selection = visit.detail_selection;
            self.navigation.x_scroll = visit.x_scroll;
            try Explorer.Ops.source_view.selectedSourceChanged(self);
            self.status_msg = "";
        }

        pub fn contentRows(self: *const Explorer) usize {
            return Explorer.Ops.view_state.layout(self).body_rows;
        }

        pub fn maxScroll(self: *const Explorer) usize {
            const rows = Explorer.Ops.controller.contentRows(self);
            return if (self.page.lines.len > rows) self.page.lines.len - rows else 0;
        }

        pub fn clampScroll(self: *Explorer) void {
            if (self.navigation.scroll > Explorer.Ops.controller.maxScroll(self)) self.navigation.scroll = Explorer.Ops.controller.maxScroll(self);
        }

        pub fn maxXScroll(self: *const Explorer) usize {
            var widest: usize = 0;
            for (self.page.lines) |line| widest = @max(widest, tui.displayWidth(line, width_mod.cpWidth));
            return widest -| Explorer.Ops.view_state.layout(self).main_width;
        }

        pub fn rowActionable(self: *const Explorer, index: usize) bool {
            if (index >= self.page.actions.len) return false;
            return switch (self.page.actions[index]) {
                .chunk, .object, .store_record, .source, .instruction => true,
                .none, .section => false,
            };
        }

        pub fn firstActionableRow(self: *const Explorer) ?usize {
            for (self.page.actions, 0..) |action, i| switch (action) {
                .chunk, .object, .store_record, .source, .instruction => return i,
                .none, .section => {},
            };
            return null;
        }

        pub fn toggleSelectedBreakpoint(self: *Explorer) !void {
            if (self.navigation.focus != .subject) {
                self.status_msg = "(focus the code pane first)";
                return;
            }
            if (self.navigation.detail_selection < self.page.actions.len and
                self.page.actions[self.navigation.detail_selection] == .source)
            {
                self.status_msg = "(Enter SOURCE to select a subexpression)";
                return;
            }
            if (self.navigation.detail_selection >= self.page.locations.len) {
                self.status_msg = "(select an instruction with source)";
                return;
            }
            const location = self.page.locations[self.navigation.detail_selection] orelse {
                self.status_msg = "(selected row has no instruction)";
                return;
            };
            if (Explorer.Ops.tree_render.hasBreakpoint(self, location)) {
                if (location.span) |span|
                    _ = self.ev.deleteBreakpointSpan(location.chunk_id, span)
                else
                    _ = self.ev.deleteBreakpointAt(location.chunk_id, location.offset);
                self.status_msg = if (location.span) |span|
                    std.fmt.bufPrint(&self.status_buf, "cleared breakpoint · chunk[0x{x}] L{d}:{d}", .{
                        location.chunk_id,
                        span.line,
                        span.column,
                    }) catch "cleared breakpoint"
                else
                    std.fmt.bufPrint(&self.status_buf, "cleared breakpoint · chunk[0x{x}] @0x{x}", .{
                        location.chunk_id,
                        location.offset,
                    }) catch "cleared breakpoint";
                return;
            }
            const result = (if (location.span) |span|
                self.ev.setBreakpointSpan(location.chunk_id, span)
            else
                self.ev.setBreakpointAt(location.chunk_id, location.offset)) catch |err| {
                self.status_msg = std.fmt.bufPrint(&self.status_buf, "breakpoint failed: {s}", .{@errorName(err)}) catch "breakpoint failed";
                return;
            };
            if (result.sites == 0) {
                self.status_msg = if (location.span != null)
                    "(span has no distinct execution site)"
                else
                    "(not an instruction boundary)";
                return;
            }
            self.status_msg = if (location.span) |span|
                std.fmt.bufPrint(&self.status_buf, "breakpoint · chunk[0x{x}] L{d}:{d}", .{
                    location.chunk_id,
                    span.line,
                    span.column,
                }) catch "breakpoint set"
            else
                std.fmt.bufPrint(&self.status_buf, "breakpoint · chunk[0x{x}] @0x{x}", .{
                    location.chunk_id,
                    location.offset,
                }) catch "breakpoint set";
        }

        pub fn moveDetail(self: *Explorer, forward: bool) void {
            if (self.page.actions.len == 0) return;
            self.preview.reset();
            if (Explorer.Ops.source_view.selectedSourceLocation(self)) |location| {
                if (self.source_session == location.chunk_id) if (self.ev.getChunk(location.chunk_id)) |chunk| {
                    if (vm_source.adjacent(chunk, location.span.?, forward)) |span| {
                        self.source_focus = .{ .chunk_id = location.chunk_id, .span = span };
                        const kind = Explorer.Ops.view_state.currentKind(self);
                        Explorer.Ops.pages.refreshPage(self, kind) catch {
                            self.status_msg = "(source preview unavailable)";
                            return;
                        };
                        for (self.page.locations, 0..) |candidate, i| {
                            const next = candidate orelse continue;
                            const next_span = next.span orelse continue;
                            if (next.chunk_id == location.chunk_id and vm_source.eql(next_span, span)) {
                                self.navigation.detail_selection = i;
                                Explorer.Ops.controller.ensureDetailVisible(self);
                                break;
                            }
                        }
                        return;
                    }
                };
            }
            var cursor = self.navigation.detail_selection;
            while (true) {
                if (forward) {
                    if (cursor + 1 >= self.page.actions.len) return;
                    cursor += 1;
                } else {
                    if (cursor == 0) return;
                    cursor -= 1;
                }
                if (Explorer.Ops.controller.rowActionable(self, cursor)) {
                    self.navigation.detail_selection = cursor;
                    Explorer.Ops.controller.ensureDetailVisible(self);
                    Explorer.Ops.source_view.selectedSourceChanged(self) catch {
                        self.status_msg = "(source preview unavailable)";
                    };
                    return;
                }
            }
        }

        pub fn ensureDetailVisible(self: *Explorer) void {
            const rows = Explorer.Ops.controller.contentRows(self);
            if (rows == 0) return;
            if (self.navigation.detail_selection < self.navigation.scroll) self.navigation.scroll = self.navigation.detail_selection;
            if (self.navigation.detail_selection >= self.navigation.scroll + rows) self.navigation.scroll = self.navigation.detail_selection - rows + 1;
            Explorer.Ops.controller.clampScroll(self);
        }

        pub fn activateDetailRow(self: *Explorer) !void {
            if (self.navigation.detail_selection >= self.page.actions.len) return;
            switch (self.page.actions[self.navigation.detail_selection]) {
                .chunk => |id| try Explorer.Ops.controller.open(self, .{ .chunk = id }),
                .object => |id| try Explorer.Ops.controller.open(self, .{ .object = id }),
                .store_record => |record| try Explorer.Ops.controller.open(self, .{ .store_record = .{ .view = record.view, .id = record.id } }),
                .source => |id| try Explorer.Ops.controller.enterSourceSession(self, id),
                .instruction, .none, .section => {},
            }
        }

        pub fn enterSourceSession(self: *Explorer, chunk_id: ChunkId) !void {
            const chunk = self.ev.getChunk(chunk_id) orelse return;
            var span = Explorer.Ops.source_view.focusedSourceSpan(self, chunk_id);
            if (span == null) span = vm_source.first(chunk);
            if (span == null) for (self.page.locations) |candidate| {
                const location = candidate orelse continue;
                if (location.chunk_id == chunk_id and location.span != null) {
                    span = location.span;
                    break;
                }
            };
            const selected_span = span orelse return;
            self.source_focus = .{ .chunk_id = chunk_id, .span = selected_span };
            self.source_session = chunk_id;
            try Explorer.Ops.pages.refreshPage(self, Explorer.Ops.view_state.currentKind(self));
            for (self.page.locations, 0..) |candidate, i| {
                const location = candidate orelse continue;
                const candidate_span = location.span orelse continue;
                if (location.chunk_id == chunk_id and vm_source.eql(candidate_span, selected_span)) {
                    self.navigation.detail_selection = i;
                    Explorer.Ops.controller.ensureDetailVisible(self);
                    return;
                }
            }
        }

        pub fn leaveSourceSession(self: *Explorer, chunk_id: ChunkId) !void {
            self.source_session = null;
            try Explorer.Ops.pages.refreshPage(self, Explorer.Ops.view_state.currentKind(self));
            for (self.page.actions, 0..) |action, i| switch (action) {
                .source => |id| if (id == chunk_id) {
                    self.navigation.detail_selection = i;
                    Explorer.Ops.controller.ensureDetailVisible(self);
                    return;
                },
                else => {},
            };
        }

        pub fn toggleHelp(self: *Explorer) !void {
            if (Explorer.Ops.view_state.currentKind(self) == .help and self.navigation.back.items.len > 1) {
                try Explorer.Ops.controller.back(self);
            } else if (Explorer.Ops.view_state.currentKind(self) != .help) {
                try Explorer.Ops.controller.open(self, .help);
            }
        }

        pub fn handleKey(self: *Explorer, key: keys_mod.Key) !bool {
            self.status_msg = "";
            if (key.isCtrl('c') or key.isCtrl('d')) return false;
            if (key.alt) switch (key.code) {
                .cp => |cp| switch (cp) {
                    'j' => {
                        self.preview.move(1);
                        return true;
                    },
                    'k' => {
                        self.preview.move(-1);
                        return true;
                    },
                    else => {},
                },
                .down => {
                    self.preview.move(1);
                    return true;
                },
                .up => {
                    self.preview.move(-1);
                    return true;
                },
                else => {},
            };
            switch (key.code) {
                .cp => |cp| switch (cp) {
                    'q' => return false,
                    'j' => {
                        if (self.navigation.focus == .tree) {
                            Explorer.Ops.tree_projection.moveTree(self, true);
                        } else {
                            Explorer.Ops.controller.moveDetail(self, true);
                        }
                    },
                    'k' => {
                        if (self.navigation.focus == .tree) {
                            Explorer.Ops.tree_projection.moveTree(self, false);
                        } else {
                            Explorer.Ops.controller.moveDetail(self, false);
                        }
                    },
                    'd' => {
                        if (self.navigation.focus == .subject) self.navigation.scroll = @min(self.navigation.scroll + Explorer.Ops.controller.contentRows(self) / 2, Explorer.Ops.controller.maxScroll(self));
                    },
                    'u' => {
                        if (self.navigation.focus == .subject) self.navigation.scroll -|= Explorer.Ops.controller.contentRows(self) / 2;
                    },
                    'g' => {
                        if (self.navigation.focus == .tree) {
                            self.navigation.tree_selection = 0;
                        } else {
                            self.navigation.detail_selection = Explorer.Ops.controller.firstActionableRow(self) orelse 0;
                            Explorer.Ops.controller.ensureDetailVisible(self);
                            try Explorer.Ops.source_view.selectedSourceChanged(self);
                        }
                    },
                    'G' => {
                        if (self.navigation.focus == .tree) {
                            self.navigation.tree_selection = self.tree.rows.items.len -| 1;
                        } else {
                            var row = self.page.actions.len;
                            while (row > 0) {
                                row -= 1;
                                if (Explorer.Ops.controller.rowActionable(self, row)) {
                                    self.navigation.detail_selection = row;
                                    break;
                                }
                            }
                            Explorer.Ops.controller.ensureDetailVisible(self);
                            try Explorer.Ops.source_view.selectedSourceChanged(self);
                        }
                    },
                    'h' => {
                        if (self.navigation.focus == .subject) self.navigation.x_scroll -|= 4;
                    },
                    'l' => {
                        if (self.navigation.focus == .subject) self.navigation.x_scroll = @min(self.navigation.x_scroll + 4, Explorer.Ops.controller.maxXScroll(self));
                    },
                    'b' => try Explorer.Ops.controller.back(self),
                    'f' => try Explorer.Ops.controller.goForward(self),
                    'p' => try Explorer.Ops.controller.toggleSelectedBreakpoint(self),
                    'F' => try Explorer.Ops.controller.filterPrompt(self),
                    '?' => try Explorer.Ops.controller.toggleHelp(self),
                    '/' => {
                        if (self.navigation.focus == .subject) try Explorer.Ops.controller.searchPrompt(self);
                    },
                    'n' => {
                        Explorer.Ops.controller.findNext(self, 1);
                    },
                    'N' => {
                        Explorer.Ops.controller.findNext(self, -1);
                    },
                    else => {},
                },
                .up => {
                    if (self.navigation.focus == .tree) Explorer.Ops.tree_projection.moveTree(self, false) else Explorer.Ops.controller.moveDetail(self, false);
                },
                .down => {
                    if (self.navigation.focus == .tree) {
                        Explorer.Ops.tree_projection.moveTree(self, true);
                    } else {
                        Explorer.Ops.controller.moveDetail(self, true);
                    }
                },
                .left => {
                    if (self.navigation.focus == .tree) try Explorer.Ops.tree_projection.collapseTreeRow(self) else self.navigation.x_scroll -|= 4;
                },
                .right => {
                    if (self.navigation.focus == .tree) {
                        try Explorer.Ops.tree_projection.activateTreeRow(self);
                    } else {
                        self.navigation.x_scroll = @min(self.navigation.x_scroll + 4, Explorer.Ops.controller.maxXScroll(self));
                    }
                },
                .page_up => {
                    if (self.navigation.focus == .subject) self.navigation.scroll -|= Explorer.Ops.controller.contentRows(self);
                },
                .page_down => {
                    if (self.navigation.focus == .subject) self.navigation.scroll = @min(self.navigation.scroll + Explorer.Ops.controller.contentRows(self), Explorer.Ops.controller.maxScroll(self));
                },
                .home => {
                    if (self.navigation.focus == .tree) self.navigation.tree_selection = 0 else {
                        self.navigation.detail_selection = Explorer.Ops.controller.firstActionableRow(self) orelse 0;
                        Explorer.Ops.controller.ensureDetailVisible(self);
                        try Explorer.Ops.source_view.selectedSourceChanged(self);
                    }
                },
                .end => {
                    if (self.navigation.focus == .tree) self.navigation.tree_selection = self.tree.rows.items.len -| 1 else self.navigation.scroll = Explorer.Ops.controller.maxScroll(self);
                },
                .tab, .backtab => {
                    if (self.navigation.focus == .tree) {
                        self.navigation.focus = .subject;
                    } else {
                        self.navigation.focus = .tree;
                    }
                },
                .enter => {
                    if (self.navigation.focus == .tree) try Explorer.Ops.tree_projection.activateTreeRow(self) else try Explorer.Ops.controller.activateDetailRow(self);
                },
                .escape => return true,
                else => {},
            }
            return true;
        }

        /// Modal one-line search input on the status row.
        pub fn searchPrompt(self: *Explorer) !void {
            self.navigation.search.clearRetainingCapacity();
            var out_buf: [1024]u8 = undefined;
            var out = std.Io.File.stdout().writerStreaming(self.io, &out_buf);
            const w = &out.interface;
            var decoder = keys_mod.Decoder{};
            var events: keys_mod.Decoder.List = .empty;
            defer events.deinit(self.allocator);
            var read_buf: [64]u8 = undefined;

            while (true) {
                const size = term_mod.size();
                var frame = tui.Frame.init(w, self.color_depth, width_mod.cpWidth);
                try frame.clearRow(size.rows);
                try frame.at(size.rows, 1);
                var search_buf: [1024]u8 = undefined;
                const search_line = std.fmt.bufPrint(&search_buf, "/{s}", .{self.navigation.search.items}) catch "/";
                try frame.text(search_line, 0, size.cols, .section);
                try w.flush();
                const result = term_mod.readInput(&read_buf, if (decoder.wantsMore()) 40 else -1);
                events.clearRetainingCapacity();
                switch (result) {
                    .timeout => try decoder.idleFlush(self.allocator, &events),
                    .winch => continue,
                    .eof => return,
                    .data => |n| for (read_buf[0..n]) |b| try decoder.feed(self.allocator, b, &events),
                }
                for (events.items) |key| {
                    switch (key.code) {
                        .enter => {
                            Explorer.Ops.controller.findNext(self, 1);
                            return;
                        },
                        .escape => return,
                        .backspace => {
                            if (self.navigation.search.items.len > 0) _ = self.navigation.search.pop();
                        },
                        .cp => |cp| {
                            if (key.isCtrl('g') or key.isCtrl('c')) return;
                            if (cp >= 0x20 and cp != 0x7F) {
                                var utf8: [4]u8 = undefined;
                                const n = std.unicode.utf8Encode(cp, &utf8) catch continue;
                                try self.navigation.search.appendSlice(self.allocator, utf8[0..n]);
                            }
                        },
                        else => {},
                    }
                }
            }
        }

        /// Modal filter input on the status row. Enter applies the substring filter
        /// to the bytecode name tree; Esc clears it. An empty query means no filter.
        pub fn filterPrompt(self: *Explorer) !void {
            var out_buf: [1024]u8 = undefined;
            var out = std.Io.File.stdout().writerStreaming(self.io, &out_buf);
            const w = &out.interface;
            var decoder = keys_mod.Decoder{};
            var events: keys_mod.Decoder.List = .empty;
            defer events.deinit(self.allocator);
            var read_buf: [64]u8 = undefined;

            while (true) {
                const size = term_mod.size();
                var frame = tui.Frame.init(w, self.color_depth, width_mod.cpWidth);
                try frame.clearRow(size.rows);
                try frame.at(size.rows, 1);
                var line_buf: [1024]u8 = undefined;
                const line = std.fmt.bufPrint(&line_buf, "filter (name): {s}", .{self.tree.filter_query.items}) catch "filter:";
                try frame.text(line, 0, size.cols, .section);
                try w.flush();
                const result = term_mod.readInput(&read_buf, if (decoder.wantsMore()) 40 else -1);
                events.clearRetainingCapacity();
                switch (result) {
                    .timeout => try decoder.idleFlush(self.allocator, &events),
                    .winch => continue,
                    .eof => return,
                    .data => |n| for (read_buf[0..n]) |b| try decoder.feed(self.allocator, b, &events),
                }
                for (events.items) |key| {
                    switch (key.code) {
                        .enter => {
                            try Explorer.Ops.tree_projection.rebuildTreeForCurrent(self);
                            self.status_msg = if (Explorer.Ops.tree_projection.filterActive(self)) "(filter applied)" else "(filter cleared)";
                            return;
                        },
                        .escape => {
                            self.tree.filter_query.clearRetainingCapacity();
                            try Explorer.Ops.tree_projection.rebuildTreeForCurrent(self);
                            self.status_msg = "(filter cleared)";
                            return;
                        },
                        .backspace => {
                            if (self.tree.filter_query.items.len > 0) _ = self.tree.filter_query.pop();
                        },
                        .cp => |cp| {
                            if (key.isCtrl('g') or key.isCtrl('c')) {
                                self.tree.filter_query.clearRetainingCapacity();
                                try Explorer.Ops.tree_projection.rebuildTreeForCurrent(self);
                                return;
                            }
                            if (cp >= 0x20 and cp != 0x7F) {
                                var utf8: [4]u8 = undefined;
                                const n = std.unicode.utf8Encode(cp, &utf8) catch continue;
                                try self.tree.filter_query.appendSlice(self.allocator, utf8[0..n]);
                            }
                        },
                        else => {},
                    }
                }
            }
        }

        pub fn findNext(self: *Explorer, dir: i2) void {
            if (self.navigation.search.items.len == 0) {
                self.status_msg = "(no search)";
                return;
            }
            const n = self.page.lines.len;
            if (n == 0) return;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const offset = i + 1;
                const line_idx = if (dir > 0)
                    (self.navigation.scroll + offset) % n
                else
                    (self.navigation.scroll + n - (offset % n)) % n;
                if (std.mem.indexOf(u8, self.page.lines[line_idx], self.navigation.search.items) != null) {
                    self.navigation.scroll = @min(line_idx, Explorer.Ops.controller.maxScroll(self));
                    return;
                }
            }
            self.status_msg = "(not found)";
        }
    };
}
