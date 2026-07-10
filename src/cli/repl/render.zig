//! Frame renderer for the repl's line editor.
//!
//! The editor is a pure state machine; this module turns its state (a `View`)
//! into terminal bytes. It keeps the previously drawn frame and emits a
//! minimal update: only rows whose content changed are rewritten, cursor-only
//! movements move the cursor and touch nothing else, and everything for one
//! update goes out in a single buffered write — so there is no flicker.
//!
//! Coordinates are frame-relative (row 0 = the prompt row). All cursor motion
//! is relative (CUU/CUD/CHA/`\n`), so the renderer never needs to know where
//! on the screen the frame starts. Growing past the bottom of the screen uses
//! real `\n`s, which scroll; every frame row shifts together, keeping the
//! relative coordinates coherent.

const std = @import("std");
const width_mod = @import("width.zig");

/// What the editor wants on screen. `text` may contain '\n' (multiline
/// input); the first logical line is prefixed by `prompt`, the rest by
/// `cont_prompt` (the two should render at the same width). `overlay` rows
/// (completion menus, search status) appear below the input, cursor stays in
/// the text area.
pub const View = struct {
    prompt: []const u8,
    cont_prompt: []const u8,
    text: []const u8,
    /// Cursor byte offset into `text`.
    cursor: usize,
    overlay: []const []const u8 = &.{},
};

/// One display row: the bytes to print plus how many of them are prompt
/// prefix (styled separately when color is on).
const Row = struct {
    bytes: []u8,
    prompt_len: usize,

    fn eql(a: Row, b: Row) bool {
        return a.prompt_len == b.prompt_len and std.mem.eql(u8, a.bytes, b.bytes);
    }
};

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    width: usize,
    use_color: bool,
    /// SGR prefix applied to prompt spans (e.g. cyan); reset after.
    prompt_style: []const u8,

    prev_rows: std.ArrayListUnmanaged(Row) = .empty,
    prev_cursor: Pos = .{ .row = 0, .col = 0 },
    /// Rows of the frame currently on screen (0 before the first draw).
    prev_row_count: usize = 0,

    rows: std.ArrayListUnmanaged(Row) = .empty,
    row_arena: std.heap.ArenaAllocator,

    const Pos = struct { row: usize, col: usize };

    pub fn init(allocator: std.mem.Allocator, term_width: usize, use_color: bool, prompt_style: []const u8) Renderer {
        return .{
            .allocator = allocator,
            .width = if (term_width < 2) 2 else term_width,
            .use_color = use_color,
            .prompt_style = prompt_style,
            .row_arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.freePrevRows();
        self.prev_rows.deinit(self.allocator);
        self.rows.deinit(self.allocator);
        self.row_arena.deinit();
    }

    fn freePrevRows(self: *Renderer) void {
        for (self.prev_rows.items) |r| self.allocator.free(r.bytes);
        self.prev_rows.clearRetainingCapacity();
    }

    /// Forget the on-screen frame (after ^L, a resize, or foreign output).
    /// The next `draw` repaints everything from the current cursor row.
    pub fn invalidate(self: *Renderer) void {
        self.freePrevRows();
        self.prev_row_count = 0;
        self.prev_cursor = .{ .row = 0, .col = 0 };
    }

    pub fn setWidth(self: *Renderer, term_width: usize) void {
        self.width = if (term_width < 2) 2 else term_width;
    }

    /// Render `view`, emitting the minimal update into `w`. Caller flushes.
    pub fn draw(self: *Renderer, w: *std.Io.Writer, view: View) !void {
        _ = self.row_arena.reset(.retain_capacity);
        self.rows.clearRetainingCapacity();
        var cursor_pos: Pos = .{ .row = 0, .col = 0 };
        try self.layout(view, &cursor_pos);

        var phys = self.prev_cursor;
        var moved = false;

        // Rewrite rows that differ from the previous frame.
        const common = @min(self.rows.items.len, self.prev_rows.items.len);
        for (self.rows.items, 0..) |row, i| {
            if (i < common and row.eql(self.prev_rows.items[i])) continue;
            try self.moveToRow(w, &phys, i);
            try w.writeByte('\r');
            phys.col = 0;
            try self.writeRow(w, row);
            phys.col = rowWidth(row.bytes);
            moved = true;
            // EL only when the row doesn't span the full width: after a
            // full-width row the terminal sits in the pending-wrap state,
            // where EL would erase the row's own last cell.
            if (phys.col < self.width) try w.writeAll("\x1b[K");
        }

        // The previous frame had more rows: clear the leftovers.
        if (self.prev_rows.items.len > self.rows.items.len) {
            try self.moveToRow(w, &phys, self.rows.items.len);
            try w.writeAll("\r\x1b[J");
            phys.col = 0;
            moved = true;
        }

        // Park the cursor where the editor says it is. After any motion use
        // an absolute column (CHA) — it also clears a pending-wrap state.
        if (phys.row != cursor_pos.row) moved = true;
        try self.moveToRow(w, &phys, cursor_pos.row);
        if (moved or phys.col != cursor_pos.col) {
            try w.print("\x1b[{d}G", .{cursor_pos.col + 1});
        }

        // Swap frames: current rows become the previous frame (owned copies).
        self.freePrevRows();
        for (self.rows.items) |row| {
            try self.prev_rows.append(self.allocator, .{
                .bytes = try self.allocator.dupe(u8, row.bytes),
                .prompt_len = row.prompt_len,
            });
        }
        self.prev_row_count = self.rows.items.len;
        self.prev_cursor = cursor_pos;
    }

    /// End the frame: cursor moves past the end of the last drawn row,
    /// anything below is cleared, a newline is emitted. Callers that may
    /// have an overlay or a mid-text cursor should draw a final
    /// overlay-free view first (see the repl's `closeFrame`).
    pub fn finish(self: *Renderer, w: *std.Io.Writer) !void {
        var phys = self.prev_cursor;
        const last = if (self.prev_row_count == 0) 0 else self.prev_row_count - 1;
        try self.moveToRow(w, &phys, last);
        // Park at the end of the row's content so ED can't chop it. A row
        // that spans the full width has no in-row park spot: step to the
        // next line first (which is where the cursor belongs anyway).
        const end_col = if (last < self.prev_rows.items.len)
            rowWidth(self.prev_rows.items[last].bytes)
        else
            0;
        if (end_col >= self.width) {
            try w.writeAll("\n\r\x1b[J");
        } else {
            try w.print("\x1b[{d}G\x1b[J\r\n", .{end_col + 1});
        }
        self.invalidate();
    }

    fn moveToRow(self: *Renderer, w: *std.Io.Writer, phys: *Pos, row: usize) !void {
        _ = self;
        if (row < phys.row) {
            try w.print("\x1b[{d}A", .{phys.row - row});
        } else if (row > phys.row) {
            // '\n' scrolls at the bottom of the screen (CUD would not); it
            // also returns the carriage under ONLCR, so col resets to 0.
            for (0..row - phys.row) |_| try w.writeByte('\n');
            phys.col = 0;
        }
        phys.row = row;
    }

    fn writeRow(self: *Renderer, w: *std.Io.Writer, row: Row) !void {
        if (self.use_color and row.prompt_len > 0) {
            try w.writeAll(self.prompt_style);
            try w.writeAll(row.bytes[0..row.prompt_len]);
            try w.writeAll("\x1b[0m");
            try w.writeAll(row.bytes[row.prompt_len..]);
        } else {
            try w.writeAll(row.bytes);
        }
    }

    /// Build the frame's rows from the view: logical lines (split on '\n')
    /// prefixed by their prompt, soft-wrapped at `width` columns without
    /// splitting a wide character; then the overlay rows. Sets `cursor_pos`
    /// to the frame position of the view's byte cursor.
    fn layout(self: *Renderer, view: View, cursor_pos: *Pos) !void {
        const arena = self.row_arena.allocator();
        var line_start: usize = 0;
        var first = true;
        var found_cursor = false;

        while (true) {
            const rel_end = std.mem.indexOfScalarPos(u8, view.text, line_start, '\n') orelse view.text.len;
            const line = view.text[line_start..rel_end];
            const prompt = if (first) view.prompt else view.cont_prompt;

            // Wrap this logical line into rows.
            var row_bytes: std.ArrayListUnmanaged(u8) = .empty;
            try row_bytes.appendSlice(arena, prompt);
            var col: usize = width_mod.strWidth(prompt);
            var prompt_len: usize = prompt.len;

            var it = width_mod.Utf8Iterator{ .text = line };
            while (it.next()) |cp| {
                const abs = line_start + cp.offset;
                var cw: usize = width_mod.cpWidth(cp.cp);
                if (cp.cp == '\t') cw = 1; // rendered as a space below
                if (col + cw > self.width) {
                    try self.pushRow(&row_bytes, prompt_len);
                    row_bytes = .empty;
                    col = 0;
                    prompt_len = 0;
                }
                if (abs == view.cursor and !found_cursor) {
                    cursor_pos.* = .{ .row = self.rows.items.len, .col = col };
                    found_cursor = true;
                }
                if (cp.cp == '\t') {
                    try row_bytes.append(arena, ' ');
                } else {
                    try row_bytes.appendSlice(arena, view.text[abs .. abs + cp.len]);
                }
                col += cw;
            }

            // Cursor at end of this logical line (incl. on the '\n' itself)?
            if (!found_cursor and view.cursor <= rel_end) {
                if (col >= self.width) {
                    // Cursor would sit past the last column: it lives at the
                    // start of a fresh (possibly empty) continuation row.
                    try self.pushRow(&row_bytes, prompt_len);
                    row_bytes = .empty;
                    col = 0;
                    prompt_len = 0;
                }
                cursor_pos.* = .{ .row = self.rows.items.len, .col = col };
                found_cursor = true;
            }
            try self.pushRow(&row_bytes, prompt_len);

            if (rel_end == view.text.len) break;
            line_start = rel_end + 1;
            first = false;
        }

        for (view.overlay) |line| {
            var row_bytes: std.ArrayListUnmanaged(u8) = .empty;
            // Overlay rows are pre-formatted; clip to the terminal width.
            var col: usize = 0;
            var it = width_mod.Utf8Iterator{ .text = line };
            while (it.next()) |cp| {
                const cw = width_mod.cpWidth(cp.cp);
                if (col + cw > self.width) break;
                try row_bytes.appendSlice(arena, line[cp.offset .. cp.offset + cp.len]);
                col += cw;
            }
            try self.pushRow(&row_bytes, 0);
        }
    }

    fn pushRow(self: *Renderer, bytes: *std.ArrayListUnmanaged(u8), prompt_len: usize) !void {
        try self.rows.append(self.allocator, .{
            .bytes = bytes.items,
            .prompt_len = prompt_len,
        });
    }

    fn rowWidth(bytes: []const u8) usize {
        return width_mod.strWidth(bytes);
    }
};

/// Format completion candidates into readline-style columns for the overlay.
/// Returns up to `max_rows` rows (allocated in `allocator`); if the items
/// don't fit, the last row says how many more there are.
pub fn formatColumns(
    allocator: std.mem.Allocator,
    items: []const []const u8,
    term_width: usize,
    max_rows: usize,
) ![]const []const u8 {
    var rows: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer rows.deinit(allocator);
    if (items.len == 0) return rows.toOwnedSlice(allocator);

    var col_width: usize = 0;
    for (items) |item| col_width = @max(col_width, width_mod.strWidth(item));
    col_width += 2;
    const cols = @max(@as(usize, 1), term_width / col_width);
    const need_rows = (items.len + cols - 1) / cols;
    const shown_rows = @min(need_rows, max_rows);
    const shown_items = @min(items.len, shown_rows * cols);

    var i: usize = 0;
    while (i < shown_items) {
        var line: std.ArrayListUnmanaged(u8) = .empty;
        errdefer line.deinit(allocator);
        const row_end = @min(i + cols, shown_items);
        while (i < row_end) : (i += 1) {
            try line.appendSlice(allocator, items[i]);
            if (i + 1 < row_end) {
                const pad = col_width - width_mod.strWidth(items[i]);
                try line.appendNTimes(allocator, ' ', pad);
            }
        }
        try rows.append(allocator, try line.toOwnedSlice(allocator));
    }
    if (shown_items < items.len) {
        const more = try std.fmt.allocPrint(allocator, "… and {d} more", .{items.len - shown_items});
        try rows.append(allocator, more);
    }
    return rows.toOwnedSlice(allocator);
}

pub fn freeColumns(allocator: std.mem.Allocator, rows: []const []const u8) void {
    for (rows) |r| allocator.free(r);
    allocator.free(rows);
}

// ---------------------------------------------------------------------------
// Tests: a tiny terminal emulator interprets the emitted bytes, and every
// draw is checked against a from-scratch render of the same view. That makes
// the diffing path prove itself equivalent to a full repaint.
// ---------------------------------------------------------------------------

const testing = std.testing;

const TestTerm = struct {
    width: usize,
    grid: std.ArrayListUnmanaged(std.ArrayListUnmanaged(u21)) = .empty,
    row: usize = 0,
    col: usize = 0,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, w: usize) TestTerm {
        return .{ .allocator = allocator, .width = w };
    }

    fn deinit(self: *TestTerm) void {
        for (self.grid.items) |*r| r.deinit(self.allocator);
        self.grid.deinit(self.allocator);
    }

    fn ensureRow(self: *TestTerm, r: usize) !void {
        while (self.grid.items.len <= r) try self.grid.append(self.allocator, .empty);
    }

    fn putCp(self: *TestTerm, cp: u21) !void {
        try self.ensureRow(self.row);
        var line = &self.grid.items[self.row];
        const w: usize = width_mod.cpWidth(cp);
        while (line.items.len < self.col + @max(w, 1)) try line.append(self.allocator, ' ');
        line.items[self.col] = cp;
        // A wide char's second cell is a sentinel `0` so re-encoding the row
        // doesn't invent a phantom space after it.
        if (w == 2) line.items[self.col + 1] = 0;
        self.col += w;
    }

    fn feed(self: *TestTerm, bytes: []const u8) !void {
        var i: usize = 0;
        while (i < bytes.len) {
            const b = bytes[i];
            if (b == '\r') {
                self.col = 0;
                i += 1;
            } else if (b == '\n') {
                self.row += 1;
                self.col = 0; // ONLCR semantics (matches the tty config)
                try self.ensureRow(self.row);
                i += 1;
            } else if (b == 0x1B) {
                i += 1;
                if (i >= bytes.len or bytes[i] != '[') @panic("unsupported escape");
                i += 1;
                var n: usize = 0;
                var has_n = false;
                while (i < bytes.len and bytes[i] >= '0' and bytes[i] <= '9') : (i += 1) {
                    n = n * 10 + (bytes[i] - '0');
                    has_n = true;
                }
                const final = bytes[i];
                i += 1;
                switch (final) {
                    'A' => self.row -|= if (has_n) n else 1,
                    'B' => self.row += if (has_n) n else 1,
                    'G' => self.col = if (has_n) n - 1 else 0,
                    'K' => {
                        try self.ensureRow(self.row);
                        var line = &self.grid.items[self.row];
                        if (self.col < line.items.len) line.shrinkRetainingCapacity(self.col);
                    },
                    'J' => {
                        try self.ensureRow(self.row);
                        var line = &self.grid.items[self.row];
                        if (self.col < line.items.len) line.shrinkRetainingCapacity(self.col);
                        var r = self.row + 1;
                        while (r < self.grid.items.len) : (r += 1) self.grid.items[r].clearRetainingCapacity();
                    },
                    'm' => {}, // SGR: styling ignored
                    else => @panic("unsupported CSI"),
                }
            } else {
                const len = std.unicode.utf8ByteSequenceLength(b) catch 1;
                const cp = std.unicode.utf8Decode(bytes[i .. i + len]) catch 0xFFFD;
                try self.putCp(cp);
                i += len;
            }
        }
    }

    fn rowText(self: *TestTerm, allocator: std.mem.Allocator, r: usize) ![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        if (r < self.grid.items.len) {
            for (self.grid.items[r].items) |cp| {
                if (cp == 0) continue; // wide-char second cell
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &buf) catch 1;
                try out.appendSlice(allocator, buf[0..n]);
            }
        }
        // Trailing spaces are display-equivalent to cleared cells.
        while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') _ = out.pop();
        return out.toOwnedSlice(allocator);
    }
};

const Harness = struct {
    term: TestTerm,
    renderer: Renderer,
    out: std.Io.Writer.Allocating,

    fn init(w: usize) Harness {
        return .{
            .term = TestTerm.init(testing.allocator, w),
            .renderer = Renderer.init(testing.allocator, w, false, ""),
            .out = .init(testing.allocator),
        };
    }

    fn deinit(self: *Harness) void {
        self.term.deinit();
        self.renderer.deinit();
        self.out.deinit();
    }

    fn draw(self: *Harness, view: View) !void {
        self.out.clearRetainingCapacity();
        try self.renderer.draw(&self.out.writer, view);
        try self.term.feed(self.out.written());
    }

    /// Assert the grid matches a from-scratch layout of `view`, and the
    /// physical cursor sits where the view's byte-cursor says.
    fn expectView(self: *Harness, view: View) !void {
        var fresh = Renderer.init(testing.allocator, self.term.width, false, "");
        defer fresh.deinit();
        var pos: Renderer.Pos = .{ .row = 0, .col = 0 };
        try fresh.layout(view, &pos);
        for (fresh.rows.items, 0..) |row, r| {
            const got = try self.term.rowText(testing.allocator, r);
            defer testing.allocator.free(got);
            var want = try testing.allocator.dupe(u8, row.bytes);
            defer testing.allocator.free(want);
            var wl = want.len;
            while (wl > 0 and want[wl - 1] == ' ') wl -= 1;
            try testing.expectEqualStrings(want[0..wl], got);
        }
        // Any grid rows beyond the layout must be blank.
        var r = fresh.rows.items.len;
        while (r < self.term.grid.items.len) : (r += 1) {
            const got = try self.term.rowText(testing.allocator, r);
            defer testing.allocator.free(got);
            try testing.expectEqualStrings("", got);
        }
        try testing.expectEqual(pos.row, self.term.row);
        try testing.expectEqual(pos.col, self.term.col);
    }
};

test "draw and edit a short line" {
    var h = Harness.init(40);
    defer h.deinit();

    var v: View = .{ .prompt = "fix> ", .cont_prompt = "...> ", .text = "", .cursor = 0 };
    try h.draw(v);
    try h.expectView(v);

    v.text = "1 + 2";
    v.cursor = 5;
    try h.draw(v);
    try h.expectView(v);

    // Cursor-only move: no content change.
    v.cursor = 2;
    try h.draw(v);
    try h.expectView(v);

    // Edit in the middle.
    v.text = "1 * 2";
    v.cursor = 3;
    try h.draw(v);
    try h.expectView(v);
}

test "soft wrap across rows and shrink back" {
    var h = Harness.init(10);
    defer h.deinit();

    // 5-char prompt + 12 chars → wraps into 2 rows (5+5, then 7).
    var v: View = .{ .prompt = "fix> ", .cont_prompt = "...> ", .text = "abcdefghijkl", .cursor = 12 };
    try h.draw(v);
    try h.expectView(v);

    // Cursor at a wrap boundary lands on the next row's column 0.
    v.cursor = 5;
    try h.draw(v);
    try h.expectView(v);

    // Shrink to a single row: the second row must be cleared.
    v.text = "ab";
    v.cursor = 2;
    try h.draw(v);
    try h.expectView(v);
}

test "cursor at exactly-full row gets a continuation row" {
    var h = Harness.init(10);
    defer h.deinit();
    // Prompt 5 + 5 chars fills the row exactly; cursor at end must sit on
    // row 1 col 0 (a fresh empty row), not col 10.
    const v: View = .{ .prompt = "fix> ", .cont_prompt = "...> ", .text = "abcde", .cursor = 5 };
    try h.draw(v);
    try h.expectView(v);
    try testing.expectEqual(@as(usize, 1), h.term.row);
    try testing.expectEqual(@as(usize, 0), h.term.col);
}

test "multiline text with continuation prompts" {
    var h = Harness.init(40);
    defer h.deinit();
    var v: View = .{ .prompt = "fix> ", .cont_prompt = "...> ", .text = "let\n  x = 1;\nin x", .cursor = 17 };
    try h.draw(v);
    try h.expectView(v);

    // Move the cursor into the middle line.
    v.cursor = 6;
    try h.draw(v);
    try h.expectView(v);

    // Collapse back to one line.
    v.text = "let in x";
    v.cursor = 0;
    try h.draw(v);
    try h.expectView(v);
}

test "wide characters never split at the wrap boundary" {
    var h = Harness.init(8);
    defer h.deinit();
    // prompt(5) + 中(2) = 7; the next 中 would need cols 7..9 → wraps whole.
    const v: View = .{ .prompt = "fix> ", .cont_prompt = "...> ", .text = "中中中", .cursor = 9 };
    try h.draw(v);
    try h.expectView(v);
}

test "overlay rows appear and clear" {
    var h = Harness.init(40);
    defer h.deinit();
    var v: View = .{ .prompt = "fix> ", .cont_prompt = "...> ", .text = "bui", .cursor = 3 };
    try h.draw(v);

    v.overlay = &.{ "builtins  buildEnv", "builder" };
    try h.draw(v);
    try h.expectView(v);

    v.overlay = &.{};
    try h.draw(v);
    try h.expectView(v);
}

test "finish clears overlay and moves past the input" {
    var h = Harness.init(40);
    defer h.deinit();
    const v: View = .{
        .prompt = "fix> ",
        .cont_prompt = "...> ",
        .text = "x",
        .cursor = 1,
        .overlay = &.{"menu"},
    };
    try h.draw(v);
    // The driver's close contract: draw the final overlay-free frame, then
    // finish (see repl.zig closeFrame).
    var final = v;
    final.overlay = &.{};
    try h.draw(final);
    h.out.clearRetainingCapacity();
    try h.renderer.finish(&h.out.writer);
    try h.term.feed(h.out.written());
    // Overlay row cleared; cursor on the row after the input.
    const got = try h.term.rowText(testing.allocator, 1);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("", got);
    try testing.expectEqual(@as(usize, 1), h.term.row);
    try testing.expectEqual(@as(usize, 0), h.term.col);
}

test "formatColumns fits items and reports overflow" {
    const items = [_][]const u8{ "alpha", "beta", "gamma", "delta", "epsilon" };
    const rows = try formatColumns(testing.allocator, &items, 20, 2);
    defer freeColumns(testing.allocator, rows);
    // col_width = 7+2 = 9 → 2 cols per row → 2 rows shown, 1 item overflow.
    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expect(std.mem.indexOf(u8, rows[2], "1 more") != null);
}
