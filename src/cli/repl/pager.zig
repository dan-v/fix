//! The VM explorer TUI: a qualified-name tree beside the selected chunk view.
//!
//! Interactive use is deliberately a TUI rather than a pager: the name tree is
//! persistent navigation, the chunk detail is a separately scrollable pane,
//! and a header/footer make focus and available actions explicit. It runs on
//! the alternate screen and returns to the ordinary repl prompt on exit. The
//! plain (`--bare`/non-tty) fallback prints the same disassembly directly.

const std = @import("std");
const engine = @import("expr");
const runtime = @import("runtime");
const term_mod = @import("term.zig");
const keys_mod = @import("keys.zig");
const width_mod = @import("width.zig");
const ColorDepth = @import("base").terminal_color.Depth;

const Evaluator = engine.Evaluator;
const ChunkId = runtime.types.ChunkId;
const bytecode = engine.bytecode;
const disasm = engine.bytecode.disasm;

const disasm_options: disasm.Options = .{
    .show_constants = true,
    .show_source = true,
    .show_bytes = true,
    .recurse = false,
};

/// Non-interactive `:d`: the same chunk disassembly without terminal chrome.
pub fn writePlain(allocator: std.mem.Allocator, w: *std.Io.Writer, ev: *Evaluator, chunk_id: ChunkId) !void {
    const symbols: disasm.Symbols = .{ .intern = ev.internTable(), .registry = ev.chunkRegistry() };
    try writeChunk(allocator, w, ev, chunk_id, symbols, disasm_options);
}

fn writeChunk(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    ev: *Evaluator,
    chunk_id: ChunkId,
    symbols: disasm.Symbols,
    options: disasm.Options,
) !void {
    const chunk = ev.getChunk(chunk_id) orelse {
        try w.print("chunk #{d} not found\n", .{chunk_id});
        return;
    };
    try disasm.writeChunk(allocator, w, chunk_id, chunk, symbols, options);
}

/// One rendered disassembly (or the help screen).
const Page = struct {
    title: []u8,
    lines: [][]u8,
};

/// A stack entry remembers where you were on the page you left.
const Visit = struct {
    kind: Kind,
    scroll: usize = 0,
    tree_selection: usize = 0,
    x_scroll: usize = 0,

    const Kind = union(enum) {
        chunk: ChunkId,
        help,
    };
};

pub fn browse(
    allocator: std.mem.Allocator,
    io: std.Io,
    ev: *Evaluator,
    start: ChunkId,
    color_depth: ColorDepth,
) !void {
    var name_index = try bytecode.inspect.NameIndex.build(allocator, ev.chunkRegistry());
    defer name_index.deinit();
    var tui = Tui{
        .allocator = allocator,
        .io = io,
        .ev = ev,
        .color_depth = color_depth,
        .name_index = &name_index,
        .arena = std.heap.ArenaAllocator.init(allocator),
    };
    defer tui.deinit();
    try tui.run(start);
}

const Tui = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    ev: *Evaluator,
    color_depth: ColorDepth,
    name_index: *const bytecode.inspect.NameIndex,
    /// Rendered pages live here for the whole browse session.
    arena: std.heap.ArenaAllocator,

    stack: std.ArrayListUnmanaged(Visit) = .empty,
    forward: std.ArrayListUnmanaged(Visit) = .empty,
    page: Page = undefined,
    scroll: usize = 0,
    search: std.ArrayListUnmanaged(u8) = .empty,
    expanded: std.AutoHashMapUnmanaged(bytecode.name_tree.NameId, void) = .empty,
    tree_rows: std.ArrayListUnmanaged(TreeRow) = .empty,
    status_msg: []const u8 = "",
    focus: Focus = .disassembly,
    tree_selection: usize = 0,
    x_scroll: usize = 0,
    view: View = .code,

    const Focus = enum { chunks, disassembly };
    const View = enum { code, tables, source, refs };

    const TreeRow = union(enum) {
        name: struct { id: bytecode.name_tree.NameId, depth: u16 },
        chunk: struct { id: ChunkId, depth: u16 },
        more: struct { count: usize, depth: u16 },
    };

    const tree_child_cap = 200;
    const tree_chunk_cap = 100;

    fn deinit(self: *Tui) void {
        self.stack.deinit(self.allocator);
        self.forward.deinit(self.allocator);
        self.search.deinit(self.allocator);
        self.expanded.deinit(self.allocator);
        self.tree_rows.deinit(self.allocator);
        self.arena.deinit();
    }

    fn run(self: *Tui, start: ChunkId) !void {
        var raw = term_mod.RawMode.enable() catch return;
        defer raw.disable();

        var out_buf: [32 * 1024]u8 = undefined;
        var out = std.Io.File.stdout().writerStreaming(self.io, &out_buf);
        const w = &out.interface;

        // Alternate screen + hidden cursor; both restored on the way out.
        try w.writeAll("\x1b[?1049h\x1b[?25l");
        defer {
            w.writeAll("\x1b[?1049l\x1b[?25h") catch {};
            w.flush() catch {};
        }

        try self.stack.append(self.allocator, .{ .kind = .{ .chunk = start } });
        try self.expandFocusedPath(start);
        try self.rebuildTree(start);
        self.page = try self.buildPage(.{ .chunk = start });

        var decoder = keys_mod.Decoder{};
        var events: keys_mod.Decoder.List = .empty;
        defer events.deinit(self.allocator);
        var read_buf: [256]u8 = undefined;

        while (true) {
            try self.draw(w);
            try w.flush();

            const result = term_mod.readInput(&read_buf, if (decoder.wantsMore()) 40 else -1);
            events.clearRetainingCapacity();
            switch (result) {
                .timeout => try decoder.idleFlush(self.allocator, &events),
                .winch => {
                    self.page = try self.buildPage(self.currentKind());
                    self.clampScroll();
                    self.x_scroll = @min(self.x_scroll, self.maxXScroll());
                    continue;
                },
                .eof => return,
                .data => |n| for (read_buf[0..n]) |b| try decoder.feed(self.allocator, b, &events),
            }
            for (events.items) |key| {
                if (!try self.handleKey(key)) return;
            }
        }
    }

    // -- page construction ---------------------------------------------------

    fn buildPage(self: *Tui, kind: Visit.Kind) !Page {
        const arena = self.arena.allocator();
        switch (kind) {
            .chunk => |id| {
                const chunk = self.ev.getChunk(id) orelse {
                    return .{
                        .title = try std.fmt.allocPrint(arena, "chunk[0x{x}] (not found)", .{id}),
                        .lines = &.{},
                    };
                };
                var text: std.Io.Writer.Allocating = .init(arena);
                switch (self.view) {
                    .code, .tables => {
                        const symbols: disasm.Symbols = .{ .intern = self.ev.internTable(), .registry = self.ev.chunkRegistry() };
                        var options = disasm_options;
                        options.color_depth = self.color_depth;
                        options.show_constants = self.view == .tables;
                        options.show_code = self.view == .code;
                        options.line_width = @intCast(@min(self.layout().main_width, std.math.maxInt(u16)));
                        try disasm.writeChunk(arena, &text.writer, id, chunk, symbols, options);
                    },
                    .source => try self.writeSourcePage(&text.writer, id, chunk),
                    .refs => try self.writeRefsPage(&text.writer, id, chunk),
                }
                const lines = try splitLines(arena, text.written());
                return .{
                    .title = try std.fmt.allocPrint(arena, "chunk[0x{x}] · {s}", .{ id, @tagName(self.view) }),
                    .lines = lines,
                };
            },
            .help => {
                const help_text =
                    \\The VM explorer
                    \\
                    \\  Tab             switch tree/detail focus
                    \\  j/k, arrows     move in the focused pane
                    \\  Enter, →        expand a name or open a chunk
                    \\  ←               collapse a name / move to its parent
                    \\  1/2/3/4         code / tables / source / references
                    \\  h/l             scroll detail horizontally
                    \\  d/u, PgDn/PgUp  half/full page
                    \\  g/G             top/bottom
                    \\  b / f           back / forward through visited chunks
                    \\  /               search; n/N next/previous match
                    \\  ?               this help
                    \\  q               leave the browser
                    \\
                    \\The tree starts collapsed except for the focused chunk's
                    \\ancestor path. Large child/chunk sets remain bounded. On
                    \\a narrow terminal, Tab switches panes instead of splitting.
                ;
                return .{
                    .title = try arena.dupe(u8, "help"),
                    .lines = try splitLines(arena, help_text),
                };
            },
        }
    }

    fn splitLines(arena: std.mem.Allocator, text: []const u8) ![][]u8 {
        var lines: std.ArrayListUnmanaged([]u8) = .empty;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| {
            try lines.append(arena, try arena.dupe(u8, line));
        }
        // Drop a trailing empty line from a final '\n'.
        if (lines.items.len > 0 and lines.items[lines.items.len - 1].len == 0) {
            _ = lines.pop();
        }
        return lines.items;
    }

    fn writeSourcePage(self: *Tui, w: *std.Io.Writer, id: ChunkId, chunk: *const bytecode.Chunk) !void {
        try w.print("chunk #{d}: {d} source-map entries\n", .{ id, chunk.source_map.len });
        if (chunk.body_span) |span| {
            try w.writeAll("body   ");
            try self.writeSpan(w, span);
            try w.writeByte('\n');
        }
        for (chunk.source_map) |entry| {
            try w.print("{x:0>4}..{x:0>4}  ", .{ entry.start, entry.end });
            try self.writeSpan(w, entry.span);
            try w.writeByte('\n');
        }
        if (chunk.source_map.len == 0 and chunk.body_span == null) try w.writeAll("(no source information)\n");
    }

    fn writeSpan(self: *Tui, w: *std.Io.Writer, span: bytecode.Chunk.SourceSpan) !void {
        if (span.file) |file| {
            try w.writeAll(self.ev.internTable().get(file));
        } else {
            try w.writeAll("expression");
        }
        try w.print(":{d}:{d}  offset {d}+{d}", .{ span.line, span.column, span.offset, span.len });
    }

    fn writeRefsPage(self: *Tui, w: *std.Io.Writer, id: ChunkId, chunk: *const bytecode.Chunk) !void {
        var refs: std.ArrayListUnmanaged(ChunkId) = .empty;
        defer refs.deinit(self.allocator);
        try bytecode.inspect.collectRefs(self.allocator, chunk, &refs);
        try w.print("outgoing ({d})\n", .{refs.items.len});
        for (refs.items) |target| try self.writeChunkLabel(w, "  →", target);

        var incoming: usize = 0;
        const total = self.ev.chunkRegistry().count();
        var candidate: ChunkId = 0;
        while (candidate < total) : (candidate += 1) {
            const source = self.ev.getChunk(candidate) orelse continue;
            refs.clearRetainingCapacity();
            bytecode.inspect.collectRefs(self.allocator, source, &refs) catch continue;
            if (std.mem.indexOfScalar(ChunkId, refs.items, id) == null) continue;
            if (incoming == 0) try w.writeAll("incoming\n");
            try self.writeChunkLabel(w, "  ←", candidate);
            incoming += 1;
        }
        if (incoming == 0) try w.writeAll("incoming (0)\n");
    }

    fn writeChunkLabel(self: *Tui, w: *std.Io.Writer, marker: []const u8, id: ChunkId) !void {
        try w.print("{s} #{d}", .{ marker, id });
        if (self.ev.chunkRegistry().hasQualifiedName(id)) {
            try w.writeByte(' ');
            try self.ev.chunkRegistry().writeQualifiedName(w, id, self.ev.internTable());
        }
        try w.writeByte('\n');
    }

    // -- navigation ------------------------------------------------------------

    const Layout = struct {
        cols: usize,
        rows: usize,
        body_rows: usize,
        split: bool,
        sidebar_width: usize,
        main_col: usize,
        main_width: usize,
    };

    fn layout(_: *const Tui) Layout {
        const size = term_mod.size();
        const cols = @max(@as(usize, 1), size.cols);
        const rows = @max(@as(usize, 3), size.rows);
        const split = cols >= 96;
        const sidebar_width = if (split) @min(@max(cols / 4, 26), 38) else 0;
        return .{
            .cols = cols,
            .rows = rows,
            .body_rows = rows - 2,
            .split = split,
            .sidebar_width = sidebar_width,
            .main_col = if (split) sidebar_width + 2 else 1,
            .main_width = if (split) cols - sidebar_width - 1 else cols,
        };
    }

    fn currentKind(self: *const Tui) Visit.Kind {
        return self.stack.items[self.stack.items.len - 1].kind;
    }

    fn currentChunk(self: *const Tui) ?ChunkId {
        return switch (self.currentKind()) {
            .chunk => |id| id,
            .help => null,
        };
    }

    fn expandFocusedPath(self: *Tui, chunk_id: ChunkId) !void {
        try self.expanded.put(self.allocator, bytecode.root_name_id, {});
        var name = self.ev.chunkRegistry().nameOf(chunk_id) orelse bytecode.root_name_id;
        while (name != bytecode.root_name_id) {
            try self.expanded.put(self.allocator, name, {});
            name = (self.name_index.node(name) orelse break).parent;
        }
    }

    fn rebuildTree(self: *Tui, focused_chunk: ChunkId) !void {
        self.tree_rows.clearRetainingCapacity();
        try self.appendNameRows(bytecode.root_name_id, 0, focused_chunk);
        self.tree_selection = 0;
        for (self.tree_rows.items, 0..) |row, i| switch (row) {
            .chunk => |entry| if (entry.id == focused_chunk) {
                self.tree_selection = i;
                break;
            },
            else => {},
        };
    }

    fn appendNameRows(self: *Tui, name: bytecode.name_tree.NameId, depth: u16, focused_chunk: ChunkId) !void {
        try self.tree_rows.append(self.allocator, .{ .name = .{ .id = name, .depth = depth } });
        if (!self.expanded.contains(name)) return;
        const next_depth = depth +| 1;

        var child_total: usize = 0;
        var child_shown: usize = 0;
        for (self.name_index.childrenOf(name)) |child| {
            if (self.name_index.statsOf(child).chunks == 0) continue;
            child_total += 1;
            if (child_shown >= tree_child_cap) continue;
            try self.appendNameRows(child, next_depth, focused_chunk);
            child_shown += 1;
        }

        const chunks = self.name_index.chunksOf(name);
        const chunk_shown = @min(chunks.len, tree_chunk_cap);
        var focus_shown = false;
        for (chunks[0..chunk_shown]) |id| {
            try self.tree_rows.append(self.allocator, .{ .chunk = .{ .id = id, .depth = next_depth } });
            focus_shown = focus_shown or id == focused_chunk;
        }
        if (!focus_shown and std.mem.indexOfScalar(ChunkId, chunks, focused_chunk) != null) {
            try self.tree_rows.append(self.allocator, .{ .chunk = .{ .id = focused_chunk, .depth = next_depth } });
        }

        const omitted = (child_total -| child_shown) + (chunks.len -| chunk_shown);
        if (omitted > 0) try self.tree_rows.append(self.allocator, .{ .more = .{ .count = omitted, .depth = next_depth } });
    }

    fn moveTree(self: *Tui, forward: bool) void {
        const count = self.tree_rows.items.len;
        if (count == 0) return;
        if (forward) {
            self.tree_selection = @min(self.tree_selection + 1, count - 1);
        } else {
            self.tree_selection -|= 1;
        }
    }

    fn activateTreeRow(self: *Tui) !void {
        if (self.tree_selection >= self.tree_rows.items.len) return;
        switch (self.tree_rows.items[self.tree_selection]) {
            .name => |entry| {
                if (self.expanded.remove(entry.id)) {
                    // collapsed
                } else {
                    try self.expanded.put(self.allocator, entry.id, {});
                }
                const focused = self.currentChunk() orelse 0;
                try self.rebuildTree(focused);
                for (self.tree_rows.items, 0..) |row, i| switch (row) {
                    .name => |candidate| if (candidate.id == entry.id) {
                        self.tree_selection = i;
                        break;
                    },
                    else => {},
                };
            },
            .chunk => |entry| try self.open(.{ .chunk = entry.id }),
            .more => self.status_msg = "(bounded; use :vm chunks in the prompt)",
        }
    }

    fn collapseTreeRow(self: *Tui) !void {
        if (self.tree_selection >= self.tree_rows.items.len) return;
        const selected = self.tree_rows.items[self.tree_selection];
        const name: bytecode.name_tree.NameId = switch (selected) {
            .name => |entry| entry.id,
            .chunk => |entry| self.ev.chunkRegistry().nameOf(entry.id) orelse bytecode.root_name_id,
            .more => return,
        };
        if (self.expanded.remove(name)) {
            const focused = self.currentChunk() orelse 0;
            try self.rebuildTree(focused);
            for (self.tree_rows.items, 0..) |row, i| switch (row) {
                .name => |entry| if (entry.id == name) {
                    self.tree_selection = i;
                    break;
                },
                else => {},
            };
            return;
        }
        const parent = (self.name_index.node(name) orelse return).parent;
        for (self.tree_rows.items, 0..) |row, i| switch (row) {
            .name => |entry| if (entry.id == parent) {
                self.tree_selection = i;
                return;
            },
            else => {},
        };
    }

    fn open(self: *Tui, kind: Visit.Kind) !void {
        // Save current position into the top-of-stack visit.
        if (self.stack.items.len > 0) {
            const top = &self.stack.items[self.stack.items.len - 1];
            top.scroll = self.scroll;
            top.tree_selection = self.tree_selection;
            top.x_scroll = self.x_scroll;
        }
        try self.stack.append(self.allocator, .{ .kind = kind });
        self.forward.clearRetainingCapacity();
        self.page = try self.buildPage(kind);
        self.scroll = 0;
        switch (kind) {
            .chunk => |id| {
                try self.expandFocusedPath(id);
                try self.rebuildTree(id);
            },
            .help => {},
        }
        self.x_scroll = 0;
        switch (kind) {
            .help => self.focus = .disassembly,
            .chunk => {},
        }
        self.status_msg = "";
    }

    fn back(self: *Tui) !void {
        if (self.stack.items.len < 2) {
            self.status_msg = "(bottom of history)";
            return;
        }
        try self.forward.append(self.allocator, self.stack.pop().?);
        const visit = self.stack.items[self.stack.items.len - 1];
        self.page = try self.buildPage(visit.kind);
        self.scroll = visit.scroll;
        self.tree_selection = visit.tree_selection;
        self.x_scroll = visit.x_scroll;
        self.status_msg = "";
    }

    fn goForward(self: *Tui) !void {
        const visit = self.forward.pop() orelse {
            self.status_msg = "(top of history)";
            return;
        };
        if (self.stack.items.len > 0) {
            const top = &self.stack.items[self.stack.items.len - 1];
            top.scroll = self.scroll;
            top.tree_selection = self.tree_selection;
            top.x_scroll = self.x_scroll;
        }
        try self.stack.append(self.allocator, visit);
        self.page = try self.buildPage(visit.kind);
        self.scroll = visit.scroll;
        self.tree_selection = visit.tree_selection;
        self.x_scroll = visit.x_scroll;
        self.status_msg = "";
    }

    fn contentRows(self: *const Tui) usize {
        return self.layout().body_rows;
    }

    fn maxScroll(self: *const Tui) usize {
        const rows = self.contentRows();
        return if (self.page.lines.len > rows) self.page.lines.len - rows else 0;
    }

    fn clampScroll(self: *Tui) void {
        if (self.scroll > self.maxScroll()) self.scroll = self.maxScroll();
    }

    fn maxXScroll(self: *const Tui) usize {
        var widest: usize = 0;
        for (self.page.lines) |line| widest = @max(widest, displayWidth(line));
        return widest -| self.layout().main_width;
    }

    fn setView(self: *Tui, view: View) !void {
        if (self.currentChunk() == null) return;
        self.view = view;
        self.page = try self.buildPage(self.currentKind());
        self.scroll = 0;
        self.x_scroll = 0;
        self.focus = .disassembly;
    }

    fn handleKey(self: *Tui, key: keys_mod.Key) !bool {
        self.status_msg = "";
        if (key.isCtrl('c') or key.isCtrl('d')) return false;
        switch (key.code) {
            .cp => |cp| switch (cp) {
                'q' => return false,
                'j' => {
                    if (self.focus == .chunks) {
                        self.moveTree(true);
                    } else {
                        self.scroll = @min(self.scroll + 1, self.maxScroll());
                    }
                },
                'k' => {
                    if (self.focus == .chunks) {
                        self.moveTree(false);
                    } else {
                        self.scroll -|= 1;
                    }
                },
                'd' => {
                    if (self.focus == .disassembly) self.scroll = @min(self.scroll + self.contentRows() / 2, self.maxScroll());
                },
                'u' => {
                    if (self.focus == .disassembly) self.scroll -|= self.contentRows() / 2;
                },
                'g' => {
                    if (self.focus == .chunks) self.tree_selection = 0 else self.scroll = 0;
                },
                'G' => {
                    if (self.focus == .chunks) self.tree_selection = self.tree_rows.items.len -| 1 else self.scroll = self.maxScroll();
                },
                'h' => {
                    if (self.focus == .disassembly) self.x_scroll -|= 4;
                },
                'l' => {
                    if (self.focus == .disassembly) self.x_scroll = @min(self.x_scroll + 4, self.maxXScroll());
                },
                'b' => try self.back(),
                'f' => try self.goForward(),
                '1' => try self.setView(.code),
                '2' => try self.setView(.tables),
                '3' => try self.setView(.source),
                '4', 'r' => try self.setView(.refs),
                '?' => try self.open(.help),
                '/' => {
                    if (self.focus == .disassembly) try self.searchPrompt();
                },
                'n' => {
                    self.findNext(1);
                },
                'N' => {
                    self.findNext(-1);
                },
                else => {},
            },
            .up => {
                if (self.focus == .chunks) self.moveTree(false) else self.scroll -|= 1;
            },
            .down => {
                if (self.focus == .chunks) {
                    self.moveTree(true);
                } else {
                    self.scroll = @min(self.scroll + 1, self.maxScroll());
                }
            },
            .left => {
                if (self.focus == .chunks) try self.collapseTreeRow() else self.x_scroll -|= 4;
            },
            .right => {
                if (self.focus == .chunks) {
                    try self.activateTreeRow();
                } else {
                    self.x_scroll = @min(self.x_scroll + 4, self.maxXScroll());
                }
            },
            .page_up => {
                if (self.focus == .disassembly) self.scroll -|= self.contentRows();
            },
            .page_down => {
                if (self.focus == .disassembly) self.scroll = @min(self.scroll + self.contentRows(), self.maxScroll());
            },
            .home => {
                if (self.focus == .chunks) self.tree_selection = 0 else self.scroll = 0;
            },
            .end => {
                if (self.focus == .chunks) self.tree_selection = self.tree_rows.items.len -| 1 else self.scroll = self.maxScroll();
            },
            .tab, .backtab => {
                if (self.focus == .chunks) {
                    self.focus = .disassembly;
                } else if (self.currentChunk() != null) {
                    self.focus = .chunks;
                }
            },
            .enter => {
                if (self.focus == .chunks) try self.activateTreeRow();
            },
            .escape => return false,
            else => {},
        }
        return true;
    }

    /// Modal one-line search input on the status row.
    fn searchPrompt(self: *Tui) !void {
        self.search.clearRetainingCapacity();
        var out_buf: [1024]u8 = undefined;
        var out = std.Io.File.stdout().writerStreaming(self.io, &out_buf);
        const w = &out.interface;
        var decoder = keys_mod.Decoder{};
        var events: keys_mod.Decoder.List = .empty;
        defer events.deinit(self.allocator);
        var read_buf: [64]u8 = undefined;

        while (true) {
            const size = term_mod.size();
            try w.print("\x1b[{d};1H\x1b[K/{s}", .{ size.rows, self.search.items });
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
                        self.findNext(1);
                        return;
                    },
                    .escape => return,
                    .backspace => {
                        if (self.search.items.len > 0) _ = self.search.pop();
                    },
                    .cp => |cp| {
                        if (key.isCtrl('g') or key.isCtrl('c')) return;
                        if (cp >= 0x20 and cp != 0x7F) {
                            var utf8: [4]u8 = undefined;
                            const n = std.unicode.utf8Encode(cp, &utf8) catch continue;
                            try self.search.appendSlice(self.allocator, utf8[0..n]);
                        }
                    },
                    else => {},
                }
            }
        }
    }

    fn findNext(self: *Tui, dir: i2) void {
        if (self.search.items.len == 0) {
            self.status_msg = "(no search)";
            return;
        }
        const n = self.page.lines.len;
        if (n == 0) return;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const offset = i + 1;
            const line_idx = if (dir > 0)
                (self.scroll + offset) % n
            else
                (self.scroll + n - (offset % n)) % n;
            if (std.mem.indexOf(u8, self.page.lines[line_idx], self.search.items) != null) {
                self.scroll = @min(line_idx, self.maxScroll());
                return;
            }
        }
        self.status_msg = "(not found)";
    }

    // -- drawing -----------------------------------------------------------------

    fn draw(self: *Tui, w: *std.Io.Writer) !void {
        const layout_now = self.layout();
        const rows = layout_now.body_rows;
        self.clampScroll();
        self.tree_selection = @min(self.tree_selection, self.tree_rows.items.len -| 1);

        var header_buf: [512]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf, " fix vm  ·  {s}  ·  {s} pane ", .{
            self.page.title,
            if (self.focus == .chunks) "tree" else "detail",
        }) catch " fix vm ";
        try moveTo(w, 1, 1);
        try writeBar(w, header, layout_now.cols);

        var row: usize = 0;
        while (row < rows) : (row += 1) {
            try moveTo(w, row + 2, 1);
            try w.writeAll("\x1b[0m\x1b[K");
            if (layout_now.split) {
                try self.drawChunkRow(w, row, layout_now.sidebar_width, rows);
                try moveTo(w, row + 2, layout_now.sidebar_width + 1);
                try w.writeAll("\x1b[2m│\x1b[0m");
                try moveTo(w, row + 2, layout_now.main_col);
                try self.drawDisasmRow(w, row, layout_now.main_width);
            } else if (self.focus == .chunks) {
                try self.drawChunkRow(w, row, layout_now.cols, rows);
            } else {
                try self.drawDisasmRow(w, row, layout_now.main_width);
            }
        }

        const pct = if (self.page.lines.len == 0)
            100
        else
            @min(100, (self.scroll + rows) * 100 / self.page.lines.len);
        var footer_buf: [512]u8 = undefined;
        const footer = std.fmt.bufPrint(&footer_buf, " {d}% · {d}/{d} · x:{d}  {s}  tab focus · 1 code · 2 tables · 3 source · 4 refs · ↵ open · ? help · q quit ", .{
            pct,
            @min(self.scroll + 1, self.page.lines.len),
            self.page.lines.len,
            self.x_scroll,
            self.status_msg,
        }) catch " q quit ";
        try moveTo(w, layout_now.rows, 1);
        try writeBar(w, footer, layout_now.cols);
    }

    fn drawDisasmRow(self: *Tui, w: *std.Io.Writer, row: usize, width: usize) !void {
        const idx = self.scroll + row;
        if (idx < self.page.lines.len) {
            try writeAnsiWindow(w, self.page.lines[idx], self.x_scroll, width);
        } else if (idx == self.page.lines.len and self.page.lines.len != 0) {
            try writeAnsiWindow(w, "\x1b[2m(end)\x1b[0m", 0, width);
        }
    }

    fn drawChunkRow(self: *Tui, w: *std.Io.Writer, row: usize, width: usize, rows: usize) !void {
        var line_buf: [512]u8 = undefined;
        if (row == 0) {
            const root_stats = self.name_index.statsOf(bytecode.root_name_id);
            const line = std.fmt.bufPrint(&line_buf, " VM TREE  ·  {d} chunks", .{root_stats.chunks}) catch " VM TREE";
            if (self.focus == .chunks) try w.writeAll("\x1b[1m");
            try writeAnsiWindow(w, line, 0, width);
            return;
        }
        if (row == 1) {
            const id = self.currentChunk() orelse {
                try writeAnsiWindow(w, " help", 0, width);
                return;
            };
            const line = if (self.ev.getChunk(id)) |chunk|
                std.fmt.bufPrint(&line_buf, " ● #0x{x}  {d}b · {d}c · a{d}", .{ id, chunk.code.len, chunk.constants.len, chunk.arity }) catch " current chunk"
            else
                std.fmt.bufPrint(&line_buf, " ● #0x{x}  missing", .{id}) catch " current chunk";
            try writeAnsiWindow(w, line, 0, width);
            return;
        }
        if (row == 2) {
            try writeAnsiWindow(w, " ─ names / chunks ─", 0, width);
            return;
        }

        const count = self.tree_rows.items.len;
        if (count == 0) {
            if (row == 3) try writeAnsiWindow(w, "   empty registry", 0, width);
            return;
        }
        const slots = rows -| 3;
        if (slots == 0) return;
        const start = @min(self.tree_selection -| (slots / 2), count -| slots);
        const index = start + row - 3;
        if (index >= count) return;
        const selected = index == self.tree_selection;
        const line: []const u8 = switch (self.tree_rows.items[index]) {
            .name => |entry| blk: {
                const stats = self.name_index.statsOf(entry.id);
                var indent: [64]u8 = undefined;
                const indent_len = @min(@as(usize, entry.depth) * 2, indent.len);
                @memset(indent[0..indent_len], ' ');
                const label = if (entry.id == bytecode.root_name_id)
                    "<root>"
                else if (self.name_index.node(entry.id)) |node|
                    self.ev.internTable().get(node.segment)
                else
                    "?";
                break :blk std.fmt.bufPrint(&line_buf, " {s}{s} {s}  {d}", .{
                    indent[0..indent_len],
                    if (self.expanded.contains(entry.id)) "▾" else "▸",
                    label,
                    stats.chunks,
                }) catch " name";
            },
            .chunk => |entry| blk: {
                var indent: [64]u8 = undefined;
                const indent_len = @min(@as(usize, entry.depth) * 2, indent.len);
                @memset(indent[0..indent_len], ' ');
                const chunk = self.ev.getChunk(entry.id);
                break :blk if (chunk) |ch|
                    std.fmt.bufPrint(&line_buf, " {s}{s} #{d}  {Bi}", .{
                        indent[0..indent_len],
                        if (self.currentChunk() == entry.id) "●" else "·",
                        entry.id,
                        ch.code.len,
                    }) catch " chunk"
                else
                    std.fmt.bufPrint(&line_buf, " {s}! #{d} missing", .{ indent[0..indent_len], entry.id }) catch " missing";
            },
            .more => |entry| blk: {
                var indent: [64]u8 = undefined;
                const indent_len = @min(@as(usize, entry.depth) * 2, indent.len);
                @memset(indent[0..indent_len], ' ');
                break :blk std.fmt.bufPrint(&line_buf, " {s}… {d} more", .{ indent[0..indent_len], entry.count }) catch " more";
            },
        };
        if (selected and self.focus == .chunks) try w.writeAll("\x1b[7m");
        try writeAnsiWindow(w, line, 0, width);
    }
};

fn moveTo(w: *std.Io.Writer, row: usize, col: usize) !void {
    try w.print("\x1b[{d};{d}H", .{ row, col });
}

/// A full-width reverse-video bar. Explicit spaces are emitted after the
/// clipped content because terminals disagree on whether erase-to-EOL carries
/// the current background/reverse attributes.
fn writeBar(w: *std.Io.Writer, line: []const u8, width: usize) !void {
    try w.writeAll("\x1b[7m");
    try writeAnsiWindow(w, line, 0, width);
    const used = @min(displayWidth(line), width);
    if (used < width) {
        try w.writeAll("\x1b[7m");
        try w.splatByteAll(' ', width - used);
    }
    try w.writeAll("\x1b[0m");
}

/// Render a horizontal cell window without counting or splitting ANSI CSI
/// sequences. This keeps the TUI faithful to the colorized `fix disasm`
/// listing while clipping it safely to pane boundaries.
fn writeAnsiWindow(w: *std.Io.Writer, line: []const u8, start: usize, width: usize) !void {
    var i: usize = 0;
    var col: usize = 0;
    var written: usize = 0;
    while (i < line.len) {
        if (line[i] == 0x1b) {
            const end = ansiSequenceEnd(line, i);
            try w.writeAll(line[i..end]);
            i = end;
            continue;
        }

        const len = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
        const safe_len = if (i + len <= line.len) len else 1;
        const cp = std.unicode.utf8Decode(line[i .. i + safe_len]) catch 0xFFFD;
        const cell_width: usize = if (cp == '\t') 1 else width_mod.cpWidth(cp);
        if (col + cell_width <= start) {
            col += cell_width;
            i += safe_len;
            continue;
        }
        if (col < start) {
            col += cell_width;
            i += safe_len;
            continue;
        }
        if (written + cell_width > width) break;
        try w.writeAll(line[i .. i + safe_len]);
        written += cell_width;
        col += cell_width;
        i += safe_len;
    }
    try w.writeAll("\x1b[0m");
}

fn displayWidth(line: []const u8) usize {
    var i: usize = 0;
    var result: usize = 0;
    while (i < line.len) {
        if (line[i] == 0x1b) {
            i = ansiSequenceEnd(line, i);
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
        const safe_len = if (i + len <= line.len) len else 1;
        const cp = std.unicode.utf8Decode(line[i .. i + safe_len]) catch 0xFFFD;
        result += if (cp == '\t') 1 else width_mod.cpWidth(cp);
        i += safe_len;
    }
    return result;
}

fn ansiSequenceEnd(line: []const u8, start: usize) usize {
    if (start + 1 >= line.len or line[start] != 0x1b) return @min(start + 1, line.len);
    if (line[start + 1] != '[') return @min(start + 2, line.len);
    var i = start + 2;
    while (i < line.len) : (i += 1) {
        if (line[i] >= 0x40 and line[i] <= 0x7e) return i + 1;
    }
    return line.len;
}

const testing = std.testing;

test "ANSI-aware window clips cells without cutting color or UTF-8" {
    const line = "\x1b[31mab中cd\x1b[0m";
    try testing.expectEqual(@as(usize, 6), displayWidth(line));

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeAnsiWindow(&out.writer, line, 2, 3);
    try testing.expectEqualStrings("\x1b[31m中c\x1b[0m", out.written());

    out.clearRetainingCapacity();
    try writeAnsiWindow(&out.writer, line, 3, 2);
    try testing.expectEqualStrings("\x1b[31mc\x1b[0m", out.written());
}

test "full-width bars explicitly paint their trailing cells" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    try writeBar(&out.writer, " vm ", 8);
    try testing.expectEqualStrings("\x1b[7m vm \x1b[0m\x1b[7m    \x1b[0m", out.written());
}
