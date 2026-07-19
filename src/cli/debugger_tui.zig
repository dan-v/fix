//! Interactive debugger surface for `fix repl`.
//!
//! The evaluator still calls a synchronous `DebugUi`; this frontend drives a
//! small full-screen event loop while the VM is paused. At an ordinary inline
//! prompt it owns raw mode + the alternate screen. When reached from `:vm`, it
//! borrows the already-active terminal session and simply redraws that screen.
//! The line-oriented `debugger.Console` remains the --no-tui/non-TTY frontend.

const std = @import("std");
const base = @import("base");
const engine = @import("expr");
const runtime = @import("runtime");
const command_mod = @import("debugger_command.zig");
const debugger = @import("debugger.zig");
const term_mod = @import("repl/term.zig");
const keys_mod = @import("repl/keys.zig");
const editor_mod = @import("repl/editor.zig");
const history_mod = @import("repl/history.zig");
const width_mod = @import("repl/width.zig");
const source_render = @import("source_render.zig");

const tui = base.tui;
const ColorDepth = base.terminal_color.Depth;
const DebugSession = engine.DebugSession;
const Evaluator = engine.Evaluator;
const Value = runtime.Value;
const disasm = engine.bytecode.disasm;

pub const DebuggerTui = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    ev: *Evaluator,
    color_depth: ColorDepth,
    editor: editor_mod.Editor,
    arena: std.heap.ArenaAllocator,
    log: std.ArrayListUnmanaged(u8) = .empty,
    raw: term_mod.RawMode = .{},
    active: bool = false,
    borrowed: bool = false,
    prompt_active: bool = false,
    selected_frame: usize = 0,
    detail: enum { source, disassembly } = .source,
    detail_scroll: isize = 0,
    context_frames: usize = 2,
    pauses: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        ev: *Evaluator,
        color_depth: ColorDepth,
        history: *history_mod.History,
    ) DebuggerTui {
        return .{
            .allocator = allocator,
            .io = io,
            .ev = ev,
            .color_depth = color_depth,
            .editor = editor_mod.Editor.init(allocator, history, .none(), .always()),
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *DebuggerTui) void {
        self.endEvaluation();
        self.editor.deinit();
        self.log.deinit(self.allocator);
        self.arena.deinit();
    }

    pub fn install(self: *DebuggerTui, ev: *Evaluator) void {
        ev.setDebugUi(self, runCallback);
    }

    pub fn uninstall(_: *DebuggerTui, ev: *Evaluator) void {
        ev.clearDebugUi();
    }

    /// Close an owned debug screen after the surrounding evaluation finishes.
    /// This catches a final `step` which runs to completion without another
    /// pause. Borrowed `:vm` sessions keep their owner's screen/raw mode intact.
    pub fn endEvaluation(self: *DebuggerTui) void {
        if (!self.active) return;
        var out_buf: [256]u8 = undefined;
        var out = std.Io.File.stdout().writerStreaming(self.io, &out_buf);
        const w = &out.interface;
        if (self.borrowed) {
            w.writeAll("\x1b[0m\x1b[?25l") catch {};
        } else {
            var screen: tui.Screen = .{
                .writer = w,
                .options = .{ .bracketed_paste = true },
            };
            screen.leave() catch {};
        }
        w.flush() catch {};
        if (!self.borrowed) self.raw.disable();
        self.active = false;
        self.borrowed = false;
        self.prompt_active = false;
        self.editor.reset();
    }

    fn runCallback(ctx: *anyopaque, session: *DebugSession) anyerror!void {
        const self: *DebuggerTui = @ptrCast(@alignCast(ctx));
        return self.drive(session);
    }

    fn begin(self: *DebuggerTui) !void {
        if (self.active) return;
        self.borrowed = term_mod.rawActive();
        if (!self.borrowed) self.raw = term_mod.RawMode.enable() catch return error.NotATerminal;
        errdefer if (!self.borrowed) self.raw.disable();

        var out_buf: [256]u8 = undefined;
        var out = std.Io.File.stdout().writerStreaming(self.io, &out_buf);
        if (!self.borrowed) {
            _ = try tui.Screen.enter(&out.interface, .{ .bracketed_paste = true });
        } else {
            try out.interface.writeAll("\x1b[?25l");
        }
        try out.interface.flush();
        self.active = true;
    }

    const Outcome = enum { stay, resume_keep, resume_close, abort };

    fn drive(self: *DebuggerTui, session: *DebugSession) !void {
        try self.begin();
        errdefer self.endEvaluation();
        self.pauses += 1;
        session.clearStep();
        self.selected_frame = session.frameCount() -| 1;
        self.detail_scroll = 0;
        self.log.clearRetainingCapacity();
        self.prompt_active = false;
        self.editor.reset();

        var decoder: keys_mod.Decoder = .{};
        var events: keys_mod.Decoder.List = .empty;
        defer events.deinit(self.allocator);
        var read_buf: [512]u8 = undefined;

        while (true) {
            try self.draw(session);
            const input = term_mod.readInput(&read_buf, if (decoder.wantsMore()) 40 else -1);
            events.clearRetainingCapacity();
            switch (input) {
                .timeout => try decoder.idleFlush(self.allocator, &events),
                .winch => continue,
                .eof => {
                    self.endEvaluation();
                    return;
                },
                .data => |n| for (read_buf[0..n]) |byte| try decoder.feed(self.allocator, byte, &events),
            }

            for (events.items) |key| {
                const outcome = if (self.prompt_active)
                    try self.handlePromptKey(session, key)
                else
                    try self.handleKey(session, key);
                switch (outcome) {
                    .stay => {},
                    .resume_keep => return,
                    .resume_close => {
                        self.endEvaluation();
                        return;
                    },
                    .abort => {
                        self.endEvaluation();
                        return debugger.AbortError;
                    },
                }
            }
        }
    }

    fn handlePromptKey(self: *DebuggerTui, session: *DebugSession, key: keys_mod.Key) !Outcome {
        if (key.code == .escape and self.editor.text().len == 0) {
            self.prompt_active = false;
            return .stay;
        }
        return switch (try self.editor.handleKey(key)) {
            .none => .stay,
            .bell => blk: {
                try self.writeControl("\x07");
                break :blk .stay;
            },
            .submit => blk: {
                const input = try self.editor.takeText();
                defer self.allocator.free(input);
                self.prompt_active = false;
                break :blk try self.execute(session, command_mod.parse(input));
            },
            .cancel => blk: {
                self.editor.reset();
                self.prompt_active = false;
                break :blk .stay;
            },
            .eof => .abort,
            .clear_screen => blk: {
                try self.writeControl("\x1b[H\x1b[2J");
                break :blk .stay;
            },
            .suspend_process => blk: {
                if (!self.borrowed) self.raw.suspendProcess();
                break :blk .stay;
            },
        };
    }

    fn handleKey(self: *DebuggerTui, session: *DebugSession, key: keys_mod.Key) !Outcome {
        switch (key.code) {
            .up => self.selectPreviousFrameRow(session),
            .down => self.selectNextFrameRow(session),
            .page_up => self.detail_scroll -= 8,
            .page_down => self.detail_scroll += 8,
            .tab => self.toggleDetail(),
            .escape => return .resume_close,
            .enter => self.prompt_active = true,
            .cp => |cp| {
                if (key.ctrl) {
                    if (cp == 'd') return .abort;
                    if (cp == 'l') try self.writeControl("\x1b[H\x1b[2J");
                    return .stay;
                }
                switch (cp) {
                    's' => return self.execute(session, .{ .step = .into }),
                    'n' => return self.execute(session, .{ .step = .over }),
                    'f' => return self.execute(session, .{ .step = .out }),
                    'c' => return .resume_close,
                    'q' => return .abort,
                    'v', '\t' => self.toggleDetail(),
                    'k' => self.selectPreviousFrameRow(session),
                    'j' => self.selectNextFrameRow(session),
                    '[', '-' => self.context_frames -|= 1,
                    ']', '+' => self.context_frames = @min(self.context_frames + 1, 6),
                    ':' => {
                        self.prompt_active = true;
                        try self.editor.insertText(":");
                    },
                    'i' => self.prompt_active = true,
                    'b' => try self.toggleFrameBreakpoint(session),
                    'B' => {
                        self.prompt_active = true;
                        try self.editor.insertText("break ");
                    },
                    '?' => try self.setLog(help_text),
                    else => {},
                }
            },
            else => {},
        }
        return .stay;
    }

    fn execute(self: *DebuggerTui, session: *DebugSession, command: command_mod.Command) !Outcome {
        switch (command) {
            .none => return .stay,
            .proceed => return .resume_close,
            .abort => return .abort,
            .step => |kind| {
                session.step(switch (kind) {
                    .over => .over,
                    .into => .into,
                    .out => .out,
                }) catch |err| {
                    try self.setError(err);
                    return .stay;
                };
                return .resume_keep;
            },
            .backtrace => try self.setLog("The stack pane is the live backtrace; use j/k or arrows to select a frame."),
            .locals => self.log.clearRetainingCapacity(),
            .value => try self.renderValue(session, session.value),
            .breakpoint => |arg| try self.addBreakpoint(session, arg),
            .breakpoints => try self.showBreakpoints(session),
            .delete => |arg| try self.deleteBreakpoint(session, arg),
            .help => try self.setLog(help_text),
            .eval => |source| {
                const scope = session.scopeAttrs() catch session.bindValueScope("it") catch null;
                const value = session.eval(source, scope) catch |err| {
                    try self.setError(err);
                    return .stay;
                };
                try self.renderValue(session, value);
            },
        }
        return .stay;
    }

    fn addBreakpoint(self: *DebuggerTui, session: *DebugSession, arg: []const u8) !void {
        const colon = std.mem.lastIndexOfScalar(u8, arg, ':') orelse {
            try self.setLog("usage: break FILE:LINE");
            return;
        };
        const file = std.mem.trim(u8, arg[0..colon], " \t");
        const line = std.fmt.parseInt(u32, std.mem.trim(u8, arg[colon + 1 ..], " \t"), 10) catch {
            try self.setLog("usage: break FILE:LINE (LINE must be a number)");
            return;
        };
        if (file.len == 0) {
            try self.setLog("usage: break FILE:LINE");
            return;
        }
        const result = session.setBreakpoint(file, line) catch |err| {
            try self.setError(err);
            return;
        };
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        try out.writer.print("breakpoint {d} {s}at {s}:{d} — {d} site(s)", .{
            result.id,
            if (result.pending) "pending " else "",
            file,
            result.line,
            result.sites,
        });
        try self.setLog(out.written());
    }

    fn toggleFrameBreakpoint(self: *DebuggerTui, session: *DebugSession) !void {
        if (session.frameCount() == 0) return self.setLog("no frame selected");
        const frame = session.frame(self.selected_frame);
        const file = frame.file orelse return self.setLog("selected frame has no source file");
        if (frame.line == 0) return self.setLog("selected frame has no executable source line");
        for (session.listBreakpoints()) |breakpoint| {
            if (breakpoint.line == frame.line and fileMatches(breakpoint.file, file)) {
                _ = session.deleteBreakpoint(breakpoint.id);
                var message: [96]u8 = undefined;
                return self.setLog(std.fmt.bufPrint(&message, "cleared breakpoint {d} at line {d}", .{ breakpoint.id, frame.line }) catch "cleared breakpoint");
            }
        }
        const result = session.setBreakpoint(file, frame.line) catch |err| {
            return self.setError(err);
        };
        var message: [128]u8 = undefined;
        try self.setLog(std.fmt.bufPrint(&message, "breakpoint {d} at {s}:{d}", .{ result.id, std.fs.path.basename(file), result.line }) catch "breakpoint set");
    }

    fn showBreakpoints(self: *DebuggerTui, session: *DebugSession) !void {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        const items = session.listBreakpoints();
        if (items.len == 0) {
            try out.writer.writeAll("(no breakpoints)");
        } else for (items) |bp| {
            try out.writer.print("{d}  {s}:{d}{s}\n", .{ bp.id, bp.file, bp.line, if (bp.pending) " (pending)" else "" });
        }
        try self.setLog(out.written());
    }

    fn deleteBreakpoint(self: *DebuggerTui, session: *DebugSession, arg: []const u8) !void {
        const id = std.fmt.parseInt(u32, std.mem.trim(u8, arg, " \t"), 10) catch {
            try self.setLog("usage: delete N");
            return;
        };
        if (session.deleteBreakpoint(id)) {
            var buf: [64]u8 = undefined;
            try self.setLog(std.fmt.bufPrint(&buf, "deleted breakpoint {d}", .{id}) catch "deleted breakpoint");
        } else {
            var buf: [64]u8 = undefined;
            try self.setLog(std.fmt.bufPrint(&buf, "no breakpoint {d}", .{id}) catch "no such breakpoint");
        }
    }

    fn renderValue(self: *DebuggerTui, session: *DebugSession, value: Value) !void {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        session.writeValue(&out.writer, value) catch |err| {
            try self.setError(err);
            return;
        };
        try self.setLog(out.written());
    }

    fn setError(self: *DebuggerTui, err: anyerror) !void {
        var buf: [160]u8 = undefined;
        try self.setLog(std.fmt.bufPrint(&buf, "error: {s}", .{@errorName(err)}) catch "error");
    }

    fn setLog(self: *DebuggerTui, text: []const u8) !void {
        self.log.clearRetainingCapacity();
        try self.log.appendSlice(self.allocator, text);
    }

    fn selectPreviousFrameRow(self: *DebuggerTui, session: *DebugSession) void {
        self.selected_frame = @min(self.selected_frame + 1, session.frameCount() -| 1);
        self.detail_scroll = 0;
    }

    fn selectNextFrameRow(self: *DebuggerTui, session: *DebugSession) void {
        if (self.selected_frame > 0) self.selected_frame -= 1;
        self.selected_frame = @min(self.selected_frame, session.frameCount() -| 1);
        self.detail_scroll = 0;
    }

    fn toggleDetail(self: *DebuggerTui) void {
        self.detail = if (self.detail == .source) .disassembly else .source;
        self.detail_scroll = 0;
    }

    fn draw(self: *DebuggerTui, session: *DebugSession) !void {
        _ = self.arena.reset(.retain_capacity);
        const arena = self.arena.allocator();
        const size = term_mod.size();
        const rows = @max(size.rows, 3);
        const cols = @max(size.cols, 20);

        var out_buf: [64 * 1024]u8 = undefined;
        var out = std.Io.File.stdout().writerStreaming(self.io, &out_buf);
        const w = &out.interface;
        var frame = tui.Frame.init(w, self.color_depth, width_mod.cpWidth);

        const selected = if (session.frameCount() > 0) session.frame(self.selected_frame) else null;
        var header_buf: [512]u8 = undefined;
        const header = if (selected) |f|
            std.fmt.bufPrint(&header_buf, " fix debug · pause {d} · {s} · {s}:{d}:{d} · frame {d}/{d} ", .{
                self.pauses,
                reasonName(session.reason),
                if (f.file) |file| std.fs.path.basename(file) else "<repl>",
                f.line,
                f.column,
                session.frameCount() - self.selected_frame,
                session.frameCount(),
            }) catch " fix debug "
        else
            " fix debug ";
        try frame.bar(1, header, cols, .header);

        const body_rows = rows - 2;
        const split = cols >= 64;
        const stack_width: usize = if (split) @min(34, @max(22, cols / 3)) else 0;
        const detail_col: usize = if (split) stack_width + 2 else 1;
        const detail_width: usize = if (split) cols - stack_width - 1 else cols;
        // Narrow terminals stack the panes vertically. Keep the backtrace
        // bounded so source and locals remain visible instead of letting a
        // deep stack consume the entire screen.
        const narrow_stack_rows = if (split)
            0
        else
            @min(session.frameCount(), @max(@as(usize, 1), body_rows / 4));
        const content_rows = body_rows -| narrow_stack_rows;
        const locals_rows = @min(content_rows, @min(@as(usize, 7), @max(@as(usize, 3), content_rows / 3)));
        const context_capacity = content_rows -| locals_rows -| 4;
        const context_count = @min(self.context_frames, @min(session.frameCount(), context_capacity -| 1));
        const context_rows = if (context_count > 0) context_count + 1 else 0;
        const detail_rows = content_rows -| locals_rows -| context_rows;

        var row: usize = 0;
        while (row < body_rows) : (row += 1) {
            const screen_row = row + 2;
            try frame.clearRow(screen_row);
            if (split) {
                try frame.at(screen_row, 1);
                try self.drawStackRow(&frame, arena, session, row, stack_width);
                try frame.divider(screen_row, stack_width + 1);
            }
            try frame.at(screen_row, detail_col);
            if (!split and row < narrow_stack_rows) {
                try self.drawStackRow(&frame, arena, session, row, detail_width);
            } else {
                const content_row = row - narrow_stack_rows;
                if (content_row < detail_rows) {
                    try self.drawDetailRow(&frame, arena, session, content_row, detail_width, detail_rows);
                } else if (content_row < detail_rows + context_rows) {
                    try self.drawContextRow(&frame, arena, session, content_row - detail_rows, detail_width, context_count);
                } else {
                    try self.drawLocalsRow(&frame, arena, session, content_row - detail_rows - context_rows, detail_width);
                }
            }
        }

        if (self.prompt_active) {
            try frame.clearRow(rows);
            try self.drawPrompt(&frame, arena, rows, cols);
        } else {
            const footer = " s step · n next · f finish · c continue · b break · [ ] context · v source/code · q abort ";
            try frame.bar(rows, footer, cols, .footer);
            try frame.cursor(false);
        }
        try w.flush();
    }

    fn drawStackRow(
        self: *DebuggerTui,
        frame: *tui.Frame,
        arena: std.mem.Allocator,
        session: *DebugSession,
        row: usize,
        width: usize,
    ) !void {
        const count = session.frameCount();
        if (row >= count) return;
        const index = count - 1 - row;
        const info = session.frame(index);
        var name: std.Io.Writer.Allocating = .init(arena);
        if (session.hasFrameName(index)) try session.writeFrameName(&name.writer, index);
        const label = try std.fmt.allocPrint(arena, "{s}#{d} {s}:{d} {s}", .{
            if (index == count - 1) "▸ " else "  ",
            row,
            if (info.file) |file| std.fs.path.basename(file) else "<repl>",
            info.line,
            name.written(),
        });
        try frame.text(label, 0, width, if (index == self.selected_frame) .selection else if (index == count - 1) .current else .plain);
    }

    fn drawDetailRow(
        self: *DebuggerTui,
        frame: *tui.Frame,
        arena: std.mem.Allocator,
        session: *DebugSession,
        row: usize,
        width: usize,
        rows: usize,
    ) !void {
        if (session.frameCount() == 0) {
            if (row == 0) try frame.text("(no live frames)", 0, width, .muted);
            return;
        }
        if (row == 0) {
            const info = session.frame(self.selected_frame);
            const title = try std.fmt.allocPrint(arena, " {s} · chunk #{d} · {s} ", .{
                if (self.detail == .source) "source" else "disassembly",
                session.frameChunkId(self.selected_frame),
                if (info.file) |file| file else "<repl>",
            });
            try frame.text(title, 0, width, .section);
            return;
        }
        if (self.detail == .source) {
            try self.drawSourceRow(frame, arena, session, row - 1, width, rows -| 1);
        } else {
            try self.drawDisassemblyRow(frame, arena, session, row - 1, width, rows -| 1);
        }
    }

    fn drawSourceRow(
        self: *DebuggerTui,
        frame: *tui.Frame,
        arena: std.mem.Allocator,
        session: *DebugSession,
        row: usize,
        width: usize,
        rows: usize,
    ) !void {
        const info = session.frame(self.selected_frame);
        const source = session.frameSourceText(self.selected_frame) orelse {
            if (row == 0) try frame.text("(source unavailable)", 0, width, .muted);
            return;
        };
        const focus_line: usize = @max(info.line, 1);
        const start_line = addScroll(focus_line -| (rows / 2), self.detail_scroll, 1);
        const line_no = start_line + row;
        const bounds = sourceLine(source, line_no) orelse return;
        const breakpoint = if (info.file) |file| hasBreakpoint(session, file, @intCast(line_no)) else false;
        const prefix = try std.fmt.allocPrint(arena, "{d: >5} {s} ", .{
            line_no,
            if (breakpoint and line_no == info.line) "◆" else if (breakpoint) "●" else if (line_no == info.line) "▶" else "┆",
        });
        try frame.text(prefix, 0, width, if (line_no == info.line) .source_focus else .muted);
        const prefix_width = width_mod.strWidth(prefix);
        if (prefix_width >= width) return;

        const span_focus: ?source_render.Range = if (info.span) |span| blk: {
            const span_start = @as(usize, span.offset);
            const span_end = span_start +| @as(usize, @max(span.len, 1));
            const start = @max(bounds.start, span_start);
            const end = @min(bounds.end, span_end);
            if (start >= end) break :blk null;
            break :blk .{ .start = start - bounds.start, .end = end - bounds.start };
        } else null;
        var highlighted: std.Io.Writer.Allocating = .init(arena);
        try source_render.writeLine(&highlighted.writer, source[bounds.start..bounds.end], .{
            .color_depth = self.color_depth,
            .focus = span_focus,
        });
        try frame.text(highlighted.written(), 0, width - prefix_width, .plain);
    }

    fn drawDisassemblyRow(
        self: *DebuggerTui,
        frame: *tui.Frame,
        arena: std.mem.Allocator,
        session: *DebugSession,
        row: usize,
        width: usize,
        rows: usize,
    ) !void {
        const info = session.frame(self.selected_frame);
        const id = session.frameChunkId(self.selected_frame);
        const chunk = self.ev.getChunk(id) orelse return;
        var output: std.Io.Writer.Allocating = .init(arena);
        const symbols: disasm.Symbols = .{ .intern = self.ev.internTable(), .registry = self.ev.chunkRegistry() };
        try disasm.writeChunk(arena, &output.writer, id, chunk, symbols, .{
            .show_constants = false,
            .show_source = true,
            .show_bytes = true,
            .color_depth = self.color_depth,
            .line_width = @intCast(@min(width, std.math.maxInt(u16))),
            .current_offset = info.instruction,
        });
        const current_line = markedLine(output.written()) orelse 0;
        const centered = current_line -| (rows / 2);
        const first = addScroll(centered, self.detail_scroll, 0);
        const line = textLine(output.written(), first + row) orelse return;
        try frame.text(line, 0, width, .plain);
    }

    fn drawContextRow(
        self: *DebuggerTui,
        frame: *tui.Frame,
        arena: std.mem.Allocator,
        session: *DebugSession,
        row: usize,
        width: usize,
        count: usize,
    ) !void {
        if (row == 0) {
            const title = try std.fmt.allocPrint(arena, " stack context · {d} frame{s} · [ / ] adjusts ", .{ count, if (count == 1) "" else "s" });
            try frame.text(title, 0, width, .section);
            return;
        }
        const from_top = row - 1;
        if (from_top >= count or from_top >= session.frameCount()) return;
        const index = session.frameCount() - 1 - from_top;
        const info = session.frame(index);
        const prefix = try std.fmt.allocPrint(arena, "#{d} {s}:{d} │ ", .{
            from_top,
            if (info.file) |file| std.fs.path.basename(file) else "<repl>",
            info.line,
        });
        const role: tui.Role = if (index == self.selected_frame) .selection_marker else if (from_top == 0) .current else .muted;
        try frame.text(prefix, 0, width, role);
        const prefix_width = width_mod.strWidth(prefix);
        if (prefix_width >= width) return;

        const source = session.frameSourceText(index) orelse return self.drawFrameName(frame, arena, session, index, width - prefix_width);
        const bounds = sourceLine(source, info.line) orelse return self.drawFrameName(frame, arena, session, index, width - prefix_width);
        const focus: ?source_render.Range = if (info.span) |span| blk: {
            const span_start: usize = @intCast(span.offset);
            const span_end = span_start +| @as(usize, @intCast(@max(span.len, 1)));
            const start = @max(bounds.start, span_start);
            const end = @min(bounds.end, span_end);
            if (start >= end) break :blk null;
            break :blk .{ .start = start - bounds.start, .end = end - bounds.start };
        } else null;
        var highlighted: std.Io.Writer.Allocating = .init(arena);
        try source_render.writeLine(&highlighted.writer, source[bounds.start..bounds.end], .{
            .color_depth = self.color_depth,
            .focus = focus,
        });
        try frame.text(highlighted.written(), 0, width - prefix_width, .plain);
    }

    fn drawFrameName(
        self: *DebuggerTui,
        frame: *tui.Frame,
        arena: std.mem.Allocator,
        session: *DebugSession,
        index: usize,
        width: usize,
    ) !void {
        _ = self;
        var name: std.Io.Writer.Allocating = .init(arena);
        if (session.hasFrameName(index)) try session.writeFrameName(&name.writer, index);
        try frame.text(if (name.written().len > 0) name.written() else "(source unavailable)", 0, width, .muted);
    }

    fn drawLocalsRow(
        self: *DebuggerTui,
        frame: *tui.Frame,
        arena: std.mem.Allocator,
        session: *DebugSession,
        row: usize,
        width: usize,
    ) !void {
        if (row == 0) {
            try frame.text(if (self.log.items.len == 0) " locals (values are not forced) " else " debugger output ", 0, width, .section);
            return;
        }
        if (self.log.items.len > 0) {
            const line = textLine(self.log.items, row - 1) orelse return;
            try frame.text(line, 0, width, .plain);
            return;
        }
        if (session.frameCount() == 0) {
            if (row == 1) try frame.text("(locals unavailable)", 0, width, .muted);
            return;
        }

        var locals: std.Io.Writer.Allocating = .init(arena);
        const index = self.selected_frame;
        for (0..session.localCount(index)) |slot| {
            const name = session.localName(index, slot) orelse continue;
            try locals.writer.print("{s} : {s}\n", .{ name, @tagName(session.localValue(index, slot).kind()) });
        }
        for (0..session.upvalueCount(index)) |slot| {
            const name = session.upvalueName(index, slot) orelse continue;
            try locals.writer.print("↑ {s} : {s}\n", .{ name, @tagName(session.upvalueValue(index, slot).kind()) });
        }
        if (locals.written().len == 0) try locals.writer.writeAll("(no named locals or upvalues)");
        const line = textLine(locals.written(), row - 1) orelse return;
        try frame.text(line, 0, width, .plain);
    }

    fn drawPrompt(self: *DebuggerTui, frame: *tui.Frame, arena: std.mem.Allocator, row: usize, width: usize) !void {
        const prompt = "(debug) ";
        const safe = try arena.dupe(u8, self.editor.text());
        for (safe) |*byte| if (byte.* == '\n' or byte.* == '\r' or byte.* == '\t') {
            byte.* = ' ';
        };
        try frame.at(row, 1);
        try frame.text(prompt, 0, @min(prompt.len, width), .section);
        if (width > prompt.len) try frame.text(safe, 0, width - prompt.len, .plain);
        const cursor_text = safe[0..@min(self.editor.cursorOffset(), safe.len)];
        const cursor_col = @min(width, prompt.len + width_mod.strWidth(cursor_text));
        try frame.at(row, @max(cursor_col + 1, 1));
        try frame.cursor(true);
    }

    fn writeControl(self: *DebuggerTui, bytes: []const u8) !void {
        var buf: [128]u8 = undefined;
        var out = std.Io.File.stdout().writerStreaming(self.io, &buf);
        try out.interface.writeAll(bytes);
        try out.interface.flush();
    }
};

const Bounds = struct { start: usize, end: usize };

fn sourceLine(text: []const u8, wanted: usize) ?Bounds {
    if (wanted == 0) return null;
    var line: usize = 1;
    var start: usize = 0;
    while (line < wanted) : (line += 1) {
        const newline = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse return null;
        start = newline + 1;
    }
    const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
    return .{ .start = start, .end = end };
}

fn textLine(text: []const u8, wanted: usize) ?[]const u8 {
    var iterator = std.mem.splitScalar(u8, text, '\n');
    var index: usize = 0;
    while (iterator.next()) |line| : (index += 1) if (index == wanted) return line;
    return null;
}

fn markedLine(text: []const u8) ?usize {
    const marker = std.mem.indexOf(u8, text, "▶") orelse return null;
    return std.mem.count(u8, text[0..marker], "\n");
}

fn addScroll(anchor: usize, delta: isize, minimum: usize) usize {
    if (delta >= 0) return @max(minimum, anchor +| @as(usize, @intCast(delta)));
    const almost: usize = @intCast(-(delta + 1));
    return @max(minimum, anchor -| (almost +| 1));
}

fn reasonName(reason: engine.BreakReason) []const u8 {
    return switch (reason) {
        .entry => "entry",
        .break_builtin => "break",
        .line_breakpoint => "breakpoint",
        .step => "step",
        .eval_error => "error",
    };
}

const help_text =
    \\s / n / f      step into / next / finish
    \\c              continue and close the debug screen
    \\b              toggle a breakpoint on the selected source line
    \\B              enter `break FILE:LINE`
    \\i              evaluate an expression in the selected pause scope
    \\v / Tab        toggle source and disassembly
    \\j/k, arrows    select a stack frame
    \\[ / ]          show fewer / more stack-context snippets
    \\:              enter any console command
    \\q / Ctrl-D     abort evaluation
;

fn hasBreakpoint(session: *const DebugSession, file: []const u8, line: u32) bool {
    for (session.listBreakpoints()) |breakpoint| {
        if (breakpoint.line == line and fileMatches(breakpoint.file, file)) return true;
    }
    return false;
}

fn fileMatches(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b) or std.mem.eql(u8, std.fs.path.basename(a), std.fs.path.basename(b));
}

test "sourceLine returns one-based source rows" {
    try std.testing.expectEqualStrings("two", blk: {
        const bounds = sourceLine("one\ntwo\nthree", 2).?;
        break :blk "one\ntwo\nthree"[bounds.start..bounds.end];
    });
}

test "signed detail scrolling moves around a centered location" {
    try std.testing.expectEqual(@as(usize, 12), addScroll(20, -8, 1));
    try std.testing.expectEqual(@as(usize, 1), addScroll(3, -8, 1));
    try std.testing.expectEqual(@as(usize, 28), addScroll(20, 8, 1));
}
