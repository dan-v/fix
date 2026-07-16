//! The `:disasm` browser: bytecode chunks as linked pages.
//!
//! A chunk renders as one page (via `bytecode.disasm`); every line that
//! mentions another chunk is a link. Tab/Shift-Tab move between links, Enter
//! follows one, `b` unwinds the visit stack, `r` opens a refs page (outgoing
//! + incoming) for the current chunk. `/`-search, `n`/`N`, and the usual
//! pager movement keys. Runs on the alternate screen so the shell's
//! scrollback is untouched; the plain (`--bare`/non-tty) fallback prints the
//! same text non-interactively.

const std = @import("std");
const engine = @import("engine");
const term_mod = @import("term.zig");
const keys_mod = @import("keys.zig");

const Evaluator = engine.Evaluator;
const ChunkId = engine.types.ChunkId;
const disasm = engine.bytecode.disasm;

const disasm_options: disasm.Options = .{
    .show_constants = true,
    .show_source = true,
    .recurse = false,
};

/// Non-interactive `:d`: the chunk's disassembly plus a references footer.
pub fn writePlain(allocator: std.mem.Allocator, w: *std.Io.Writer, ev: *Evaluator, chunk_id: ChunkId) !void {
    const chunk = ev.getChunk(chunk_id) orelse {
        try w.print("chunk #{d} not found\n", .{chunk_id});
        return;
    };
    const symbols: disasm.Symbols = .{ .intern = ev.internTable(), .registry = ev.chunkRegistry() };
    try disasm.writeChunk(allocator, w, chunk_id, chunk, symbols, disasm_options);

    var refs: std.ArrayListUnmanaged(ChunkId) = .empty;
    defer refs.deinit(allocator);
    disasm.collectRefs(allocator, chunk, &refs) catch {};
    if (refs.items.len > 0) {
        try w.writeAll("\nreferences:");
        for (refs.items) |id| try w.print(" #{d}", .{id});
        try w.writeAll("\n");
    }
}

/// One rendered page: a disasm listing or a refs listing.
const Page = struct {
    title: []u8,
    lines: [][]u8,
    /// line index → chunk id it links to.
    links: []Link,

    const Link = struct { line: usize, target: ChunkId };
};

/// A stack entry remembers where you were on the page you left.
const Visit = struct {
    kind: Kind,
    scroll: usize = 0,
    link: usize = 0,

    const Kind = union(enum) {
        chunk: ChunkId,
        refs: ChunkId,
        help,
    };
};

pub fn browse(allocator: std.mem.Allocator, io: std.Io, ev: *Evaluator, start: ChunkId, use_color: bool) !void {
    var pager = Pager{
        .allocator = allocator,
        .io = io,
        .ev = ev,
        .use_color = use_color,
        .arena = std.heap.ArenaAllocator.init(allocator),
    };
    defer pager.deinit();
    try pager.run(start);
}

const Pager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    ev: *Evaluator,
    use_color: bool,
    /// Pages + reverse-ref cache live here for the whole browse session.
    arena: std.heap.ArenaAllocator,

    stack: std.ArrayListUnmanaged(Visit) = .empty,
    forward: std.ArrayListUnmanaged(Visit) = .empty,
    page: Page = undefined,
    scroll: usize = 0,
    /// Selected link index into page.links (or none).
    link: usize = 0,
    search: std.ArrayListUnmanaged(u8) = .empty,
    status_msg: []const u8 = "",
    /// Incoming-reference index, built lazily on first use.
    incoming: ?std.AutoArrayHashMapUnmanaged(ChunkId, std.ArrayListUnmanaged(ChunkId)) = null,

    fn deinit(self: *Pager) void {
        self.stack.deinit(self.allocator);
        self.forward.deinit(self.allocator);
        self.search.deinit(self.allocator);
        self.arena.deinit();
    }

    fn run(self: *Pager, start: ChunkId) !void {
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
                .winch => continue, // sizes are re-read every draw
                .eof => return,
                .data => |n| for (read_buf[0..n]) |b| try decoder.feed(self.allocator, b, &events),
            }
            for (events.items) |key| {
                if (!try self.handleKey(w, key)) return;
            }
        }
    }

    // -- page construction ---------------------------------------------------

    fn buildPage(self: *Pager, kind: Visit.Kind) !Page {
        const arena = self.arena.allocator();
        switch (kind) {
            .chunk => |id| {
                const chunk = self.ev.getChunk(id) orelse {
                    return .{
                        .title = try std.fmt.allocPrint(arena, "chunk #{d} (not found)", .{id}),
                        .lines = &.{},
                        .links = &.{},
                    };
                };
                var text: std.Io.Writer.Allocating = .init(arena);
                const symbols: disasm.Symbols = .{ .intern = self.ev.internTable(), .registry = self.ev.chunkRegistry() };
                var options = disasm_options;
                options.use_color = self.use_color;
                try disasm.writeChunk(arena, &text.writer, id, chunk, symbols, options);
                const lines = try splitLines(arena, text.written());
                return .{
                    .title = try std.fmt.allocPrint(arena, "chunk #{d}", .{id}),
                    .lines = lines,
                    .links = try scanLinks(arena, lines, id),
                };
            },
            .refs => |id| {
                var lines: std.ArrayListUnmanaged([]u8) = .empty;
                var links: std.ArrayListUnmanaged(Page.Link) = .empty;

                try lines.append(arena, try std.fmt.allocPrint(arena, "references of chunk #{d}", .{id}));
                try lines.append(arena, try arena.dupe(u8, ""));

                var out_refs: std.ArrayListUnmanaged(ChunkId) = .empty;
                defer out_refs.deinit(self.allocator);
                if (self.ev.getChunk(id)) |chunk| {
                    disasm.collectRefs(self.allocator, chunk, &out_refs) catch {};
                }
                try lines.append(arena, try std.fmt.allocPrint(arena, "outgoing ({d}):", .{out_refs.items.len}));
                for (out_refs.items) |ref| {
                    try links.append(arena, .{ .line = lines.items.len, .target = ref });
                    try lines.append(arena, try self.chunkSummaryLine(arena, ref));
                }

                try lines.append(arena, try arena.dupe(u8, ""));
                const in_refs = try self.incomingRefs(id);
                try lines.append(arena, try std.fmt.allocPrint(arena, "incoming ({d}):", .{in_refs.len}));
                for (in_refs) |ref| {
                    try links.append(arena, .{ .line = lines.items.len, .target = ref });
                    try lines.append(arena, try self.chunkSummaryLine(arena, ref));
                }

                return .{
                    .title = try std.fmt.allocPrint(arena, "refs #{d}", .{id}),
                    .lines = lines.items,
                    .links = links.items,
                };
            },
            .help => {
                const help_text =
                    \\The disassembly browser
                    \\
                    \\  j/k, arrows     scroll        d/u, PgDn/PgUp  half/full page
                    \\  g/G             top/bottom
                    \\  Tab/Shift-Tab   select next/previous chunk link
                    \\  Enter           follow the selected link
                    \\  b / f           back / forward through visited pages
                    \\  r               references page (outgoing + incoming)
                    \\  /               search; n/N next/previous match
                    \\  ?               this help
                    \\  q               leave the browser
                    \\
                    \\Every chunk mention (`chunk[0xN]` in a listing,
                    \\`chunk #N` on a references page) is a link: the
                    \\compiled program is a graph — browse it like pages.
                ;
                return .{
                    .title = try arena.dupe(u8, "help"),
                    .lines = try splitLines(arena, help_text),
                    .links = &.{},
                };
            },
        }
    }

    fn chunkSummaryLine(self: *Pager, arena: std.mem.Allocator, id: ChunkId) ![]u8 {
        if (self.ev.getChunk(id)) |chunk| {
            return std.fmt.allocPrint(arena, "  chunk #{d}  ({d} bytes, {d} consts, arity {d})", .{
                id, chunk.code.len, chunk.constants.len, chunk.arity,
            });
        }
        return std.fmt.allocPrint(arena, "  chunk #{d}", .{id});
    }

    /// Build (once) the whole-registry reverse reference index.
    fn incomingRefs(self: *Pager, id: ChunkId) ![]const ChunkId {
        if (self.incoming == null) {
            const arena = self.arena.allocator();
            var map: std.AutoArrayHashMapUnmanaged(ChunkId, std.ArrayListUnmanaged(ChunkId)) = .empty;
            const count = self.ev.chunkRegistry().count();
            var refs: std.ArrayListUnmanaged(ChunkId) = .empty;
            defer refs.deinit(self.allocator);
            var cid: ChunkId = 0;
            while (cid < count) : (cid += 1) {
                const chunk = self.ev.getChunk(cid) orelse continue;
                refs.clearRetainingCapacity();
                disasm.collectRefs(self.allocator, chunk, &refs) catch continue;
                for (refs.items) |target| {
                    const gop = try map.getOrPut(arena, target);
                    if (!gop.found_existing) gop.value_ptr.* = .empty;
                    try gop.value_ptr.append(arena, cid);
                }
            }
            self.incoming = map;
        }
        if (self.incoming.?.get(id)) |list| return list.items;
        return &.{};
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

    /// Every line (except the page's own header) that mentions a chunk —
    /// `chunk #N` (the pager's own pages, decimal) or `chunk[0xN]` (disasm
    /// listings, hex) — becomes a link to N.
    fn scanLinks(arena: std.mem.Allocator, lines: [][]u8, self_id: ChunkId) ![]Page.Link {
        var links: std.ArrayListUnmanaged(Page.Link) = .empty;
        for (lines, 0..) |line, i| {
            const id = parseChunkMention(line) orelse continue;
            if (i == 0 and id == self_id) continue; // the header names itself
            try links.append(arena, .{ .line = i, .target = id });
        }
        return links.items;
    }

    /// First chunk mention in `line`, either form.
    fn parseChunkMention(line: []const u8) ?ChunkId {
        if (std.mem.indexOf(u8, line, "chunk #")) |idx| {
            const start = idx + "chunk #".len;
            var end = start;
            while (end < line.len and std.ascii.isDigit(line[end])) end += 1;
            if (end > start) return std.fmt.parseInt(ChunkId, line[start..end], 10) catch null;
        }
        if (std.mem.indexOf(u8, line, "chunk[0x")) |idx| {
            const start = idx + "chunk[0x".len;
            var end = start;
            while (end < line.len and std.ascii.isHex(line[end])) end += 1;
            if (end > start and end < line.len and line[end] == ']')
                return std.fmt.parseInt(ChunkId, line[start..end], 16) catch null;
        }
        return null;
    }

    // -- navigation ------------------------------------------------------------

    fn open(self: *Pager, kind: Visit.Kind) !void {
        // Save current position into the top-of-stack visit.
        if (self.stack.items.len > 0) {
            const top = &self.stack.items[self.stack.items.len - 1];
            top.scroll = self.scroll;
            top.link = self.link;
        }
        try self.stack.append(self.allocator, .{ .kind = kind });
        self.forward.clearRetainingCapacity();
        self.page = try self.buildPage(kind);
        self.scroll = 0;
        self.link = 0;
        self.status_msg = "";
    }

    fn back(self: *Pager) !void {
        if (self.stack.items.len < 2) {
            self.status_msg = "(bottom of history)";
            return;
        }
        try self.forward.append(self.allocator, self.stack.pop().?);
        const visit = self.stack.items[self.stack.items.len - 1];
        self.page = try self.buildPage(visit.kind);
        self.scroll = visit.scroll;
        self.link = visit.link;
        self.status_msg = "";
    }

    fn goForward(self: *Pager) !void {
        const visit = self.forward.pop() orelse {
            self.status_msg = "(top of history)";
            return;
        };
        if (self.stack.items.len > 0) {
            const top = &self.stack.items[self.stack.items.len - 1];
            top.scroll = self.scroll;
            top.link = self.link;
        }
        try self.stack.append(self.allocator, visit);
        self.page = try self.buildPage(visit.kind);
        self.scroll = visit.scroll;
        self.link = visit.link;
        self.status_msg = "";
    }

    fn contentRows(_: *const Pager) usize {
        const rows = term_mod.size().rows;
        return if (rows > 1) rows - 1 else 1;
    }

    fn maxScroll(self: *const Pager) usize {
        const rows = self.contentRows();
        return if (self.page.lines.len > rows) self.page.lines.len - rows else 0;
    }

    fn clampScroll(self: *Pager) void {
        if (self.scroll > self.maxScroll()) self.scroll = self.maxScroll();
    }

    /// Keep the selected link visible.
    fn scrollToLink(self: *Pager) void {
        if (self.page.links.len == 0) return;
        const line = self.page.links[self.link].line;
        const rows = self.contentRows();
        if (line < self.scroll) self.scroll = line;
        if (line >= self.scroll + rows) self.scroll = line - rows + 1;
    }

    fn handleKey(self: *Pager, w: *std.Io.Writer, key: keys_mod.Key) !bool {
        _ = w;
        self.status_msg = "";
        if (key.isCtrl('c') or key.isCtrl('d')) return false;
        switch (key.code) {
            .cp => |cp| switch (cp) {
                'q' => return false,
                'j' => self.scroll = @min(self.scroll + 1, self.maxScroll()),
                'k' => self.scroll -|= 1,
                'd' => self.scroll = @min(self.scroll + self.contentRows() / 2, self.maxScroll()),
                'u' => self.scroll -|= self.contentRows() / 2,
                'g' => self.scroll = 0,
                'G' => self.scroll = self.maxScroll(),
                'b' => try self.back(),
                'f' => try self.goForward(),
                'r' => {
                    const current = self.stack.items[self.stack.items.len - 1].kind;
                    switch (current) {
                        .chunk => |id| try self.open(.{ .refs = id }),
                        .refs => |id| try self.open(.{ .refs = id }),
                        .help => {},
                    }
                },
                '?' => try self.open(.help),
                '/' => try self.searchPrompt(),
                'n' => self.findNext(1),
                'N' => self.findNext(-1),
                else => {},
            },
            .up => self.scroll -|= 1,
            .down => self.scroll = @min(self.scroll + 1, self.maxScroll()),
            .page_up => self.scroll -|= self.contentRows(),
            .page_down => self.scroll = @min(self.scroll + self.contentRows(), self.maxScroll()),
            .home => self.scroll = 0,
            .end => self.scroll = self.maxScroll(),
            .tab => {
                if (self.page.links.len > 0) {
                    self.link = (self.link + 1) % self.page.links.len;
                    self.scrollToLink();
                }
            },
            .backtab => {
                if (self.page.links.len > 0) {
                    self.link = (self.link + self.page.links.len - 1) % self.page.links.len;
                    self.scrollToLink();
                }
            },
            .enter => {
                if (self.page.links.len > 0) {
                    try self.open(.{ .chunk = self.page.links[self.link].target });
                }
            },
            .escape => return false,
            else => {},
        }
        return true;
    }

    /// Modal one-line search input on the status row.
    fn searchPrompt(self: *Pager) !void {
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

    fn findNext(self: *Pager, dir: i2) void {
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

    fn draw(self: *Pager, w: *std.Io.Writer) !void {
        const size = term_mod.size();
        const rows = self.contentRows();
        self.clampScroll();

        const selected_line: ?usize = if (self.page.links.len > 0)
            self.page.links[self.link].line
        else
            null;

        try w.writeAll("\x1b[H");
        var row: usize = 0;
        while (row < rows) : (row += 1) {
            const idx = self.scroll + row;
            try w.writeAll("\x1b[K");
            if (idx < self.page.lines.len) {
                const line = self.page.lines[idx];
                const shown = line[0..@min(line.len, size.cols)];
                if (selected_line != null and idx == selected_line.?) {
                    try w.writeAll("\x1b[7m");
                    try w.writeAll(shown);
                    try w.writeAll("\x1b[0m");
                } else {
                    try w.writeAll(shown);
                }
            } else if (idx == self.page.lines.len and self.page.lines.len != 0) {
                try w.writeAll("\x1b[2m(end)\x1b[0m");
            }
            try w.writeAll("\r\n");
        }

        // Status bar (inverse): title, position, key hints.
        var status_buf: [256]u8 = undefined;
        const pct = if (self.page.lines.len == 0)
            100
        else
            @min(100, (self.scroll + rows) * 100 / self.page.lines.len);
        const status = std.fmt.bufPrint(&status_buf, " {s} · {d} lines · {d}% {s}· q quit · tab/enter links · b back · r refs · ? help ", .{
            self.page.title,
            self.page.lines.len,
            pct,
            self.status_msg,
        }) catch "";
        try w.writeAll("\x1b[7m");
        try w.writeAll(status[0..@min(status.len, size.cols)]);
        try w.writeAll("\x1b[K\x1b[0m");
    }
};

const testing = std.testing;

test "scanLinks links chunk mentions but not the header" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var lines: std.ArrayListUnmanaged([]u8) = .empty;
    try lines.append(a, try a.dupe(u8, "chunk #5 (12 bytes)"));
    try lines.append(a, try a.dupe(u8, "  0000  closure  chunk #7, 2 upvalues"));
    try lines.append(a, try a.dupe(u8, "  0005  int_add"));
    try lines.append(a, try a.dupe(u8, "  0006  thunk_captures  chunk #9, 0 upvalues"));
    const links = try Pager.scanLinks(a, lines.items, 5);
    try testing.expectEqual(@as(usize, 2), links.len);
    try testing.expectEqual(@as(ChunkId, 7), links[0].target);
    try testing.expectEqual(@as(usize, 1), links[0].line);
    try testing.expectEqual(@as(ChunkId, 9), links[1].target);
}

test "scanLinks links hex disasm mentions but not the hex header" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var lines: std.ArrayListUnmanaged([]u8) = .empty;
    try lines.append(a, try a.dupe(u8, "chunk[0x1f] (12 bytes, 1 consts, 0 locals)"));
    try lines.append(a, try a.dupe(u8, "  0000   closure #0x20              ; chunk[0x20] fetchGit"));
    try lines.append(a, try a.dupe(u8, "  0005   int_add"));
    const links = try Pager.scanLinks(a, lines.items, 0x1f);
    try testing.expectEqual(@as(usize, 1), links.len);
    try testing.expectEqual(@as(ChunkId, 0x20), links[0].target);
    try testing.expectEqual(@as(usize, 1), links[0].line);
}
