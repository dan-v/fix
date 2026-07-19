//! The interactive debug console (`--debugger`).
//!
//! When a debugger is attached, evaluation pauses at `builtins.break x` (and,
//! with `--debugger`, at an evaluation error) and hands control here. The
//! console is a small line-oriented REPL over a `engine.DebugSession`: it can show
//! a backtrace with source locations, list the paused frame's locals, evaluate
//! expressions in place (with the break value bound as `it`), and continue or
//! abort. All I/O goes to the terminal via stdin/stderr so a redirected stdout
//! still receives only the final value.
//!
//! The engine upcalls through `engine.Evaluator.setDebugUi`; this file is the
//! `cli`-side implementation, so no VM internals leak below the facade.

const std = @import("std");
const engine = @import("expr");
const runtime = @import("runtime");
const presentation = @import("presentation.zig");
const term_mod = @import("repl/term.zig");
const syntax = @import("syntax");

const DebugSession = engine.DebugSession;
const Value = runtime.Value;
const TokenType = syntax.token.TokenType;

// Syntax-highlight palette (matches the value-render palette in eval/print.zig).
const col_keyword = "\x1b[35m"; // if/let/with/true/… — magenta
const col_string = "\x1b[32m"; // strings, paths — green
const col_number = "\x1b[33m"; // ints, floats — yellow
const col_reset = "\x1b[0m";

/// Returned from the console to unwind and abort the whole evaluation (`:q`).
pub const AbortError = error.DebuggerAbort;

pub const Console = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    use_color: bool,
    /// Persistent stdin reader so type-ahead survives across successive breaks.
    stdin_buf: [16 * 1024]u8 = undefined,
    reader: ?std.Io.File.Reader = null,
    /// When set, read console input through this reader instead of our own —
    /// used by the bare repl, whose own buffered reader would otherwise swallow
    /// the shared stdin pipe. Null everywhere else (eval, interactive repl).
    ext_reader: ?*std.Io.File.Reader = null,
    /// How many times we've paused (for the banner).
    hits: usize = 0,

    /// Attach this console to `ev`; `builtins.break`/errors now route here.
    pub fn install(self: *Console, ev: *engine.Evaluator) void {
        ev.setDebugUi(self, runCallback);
    }

    /// Read console input from `r` (a shared reader) rather than our own — the
    /// bare repl calls this so its line reader and the console don't fight over
    /// the stdin pipe's buffer.
    pub fn attachReader(self: *Console, r: *std.Io.File.Reader) void {
        self.ext_reader = r;
    }

    fn runCallback(ctx: *anyopaque, session: *DebugSession) anyerror!void {
        const self: *Console = @ptrCast(@alignCast(ctx));
        return self.drive(session);
    }

    fn inputReader(self: *Console) *std.Io.File.Reader {
        if (self.ext_reader) |r| return r;
        if (self.reader == null) {
            self.reader = std.Io.File.stdin().readerStreaming(self.io, &self.stdin_buf);
        }
        return &self.reader.?;
    }

    fn stderr(self: *Console) std.Io.File.Writer {
        return std.Io.File.stderr().writerStreaming(self.io, &scratch);
    }

    fn drive(self: *Console, s: *DebugSession) !void {
        // A debugger pause is a nested prompt inside the full-screen REPL.
        // Temporarily reveal the ordinary terminal and restore canonical input;
        // returning to the evaluator re-enters the alternate screen/raw mode,
        // which the REPL immediately redraws. `fix eval --debugger` and bare
        // mode are already cooked, so this becomes a no-op there.
        var screen_pause = ScreenPause.begin(self.io);
        defer screen_pause.end();

        self.hits += 1;
        // Whatever step brought us here (if any) is complete — disarm its temps.
        s.clearStep();
        // Console expressions resolve against the pause's lexical scope (named
        // locals + upvalues), with the break value bound as `it`.
        const scope = s.scopeAttrs() catch s.bindValueScope("it") catch null;

        {
            var out = self.stderr();
            defer out.interface.flush() catch {};
            const w = &out.interface;
            try self.banner(w, s);
        }

        // In the nested case, read a byte at a time so the debugger cannot
        // buffer a command typed ahead for the resumed REPL. Other modes keep
        // the persistent buffered reader (or the bare REPL's shared reader).
        var nested_buf: [1]u8 = undefined;
        var nested_reader = std.Io.File.stdin().readerStreaming(self.io, &nested_buf);
        const in = if (screen_pause.cooked.active) &nested_reader else self.inputReader();
        var nested_line: std.ArrayListUnmanaged(u8) = .empty;
        defer nested_line.deinit(self.allocator);
        while (true) {
            {
                var out = self.stderr();
                defer out.interface.flush() catch {};
                try self.style(&out.interface, .note_label);
                try out.interface.writeAll("(debug) ");
                try presentation.reset(&out.interface, self.use_color);
            }
            const raw = (if (screen_pause.cooked.active)
                self.takeNestedLine(in, &nested_line)
            else
                in.interface.takeDelimiter('\n')) catch |err| switch (err) {
                error.StreamTooLong => {
                    if (!screen_pause.cooked.active) _ = in.interface.discardDelimiterInclusive('\n') catch {};
                    continue;
                },
                else => return err,
            } orelse return; // EOF: resume as if `continue`.
            const line = std.mem.trim(u8, raw, " \t\r\n");
            if (try self.dispatch(s, line, scope)) return;
        }
    }

    /// Read one canonical-mode line without consuming bytes after its newline.
    /// The one-byte `File.Reader` backing this path makes `takeByte` leave any
    /// type-ahead for the resumed full-screen REPL in the kernel input queue.
    fn takeNestedLine(self: *Console, in: *std.Io.File.Reader, line: *std.ArrayListUnmanaged(u8)) !?[]const u8 {
        line.clearRetainingCapacity();
        while (true) {
            const byte = in.interface.takeByte() catch |err| switch (err) {
                error.EndOfStream => return if (line.items.len == 0) null else line.items,
                else => return err,
            };
            if (byte == '\n') return line.items;
            if (line.items.len == 64 * 1024) {
                while (true) {
                    const discarded = in.interface.takeByte() catch return error.StreamTooLong;
                    if (discarded == '\n') return error.StreamTooLong;
                }
            }
            try line.append(self.allocator, byte);
        }
    }

    /// Handle one console line. Returns true when evaluation should resume.
    ///
    /// Commands and Nix expressions share the prompt, so a bare line is an
    /// expression unless it is *exactly* a no-arg command word (`n`, `bt`, …) —
    /// that way `n + base` evaluates instead of stepping. A leading `:` forces
    /// command interpretation. Arg commands (`break`, `delete`) match on their
    /// first word, which is never a valid expression prefix.
    fn dispatch(self: *Console, s: *DebugSession, line: []const u8, scope: ?Value) !bool {
        if (line.len == 0) return false;
        const explicit = line[0] == ':';
        const cmd = if (explicit) std.mem.trim(u8, line[1..], " \t") else line;
        if (cmd.len == 0) return false;
        const word = firstWord(cmd);
        const rest = std.mem.trim(u8, cmd[word.len..], " \t");
        const bare = rest.len == 0; // no trailing content → unambiguous command

        // No-arg commands: only when the line is exactly the word (or `:`-forced).
        if (bare or explicit) {
            if (isWord(word, &.{ "c", "cont", "continue" })) return true;
            if (isWord(word, &.{ "q", "quit", "abort" })) return AbortError;
            if (isWord(word, &.{ "n", "next" })) {
                try self.armStep(s, .over);
                return true;
            }
            if (isWord(word, &.{ "s", "step" })) {
                try self.armStep(s, .into);
                return true;
            }
            if (isWord(word, &.{ "finish", "fin", "out" })) {
                try self.armStep(s, .out);
                return true;
            }
            if (isWord(word, &.{ "bt", "backtrace", "where", "w" })) {
                try self.backtrace(s);
                return false;
            }
            if (isWord(word, &.{ "l", "locals" })) {
                try self.locals(s);
                return false;
            }
            if (isWord(word, &.{ "v", "value" })) {
                try self.printValue(s, s.value);
                return false;
            }
            if (isWord(word, &.{ "breakpoints", "info" })) {
                try self.listBreakpoints(s);
                return false;
            }
            if (isWord(word, &.{ "help", "h", "?" })) {
                try self.help();
                return false;
            }
        }
        // Arg commands: `break`/`delete` aren't valid expression prefixes.
        if (isWord(word, &.{"break"})) {
            try self.addBreakpoint(s, rest);
            return false;
        }
        if (isWord(word, &.{"delete"})) {
            try self.deleteBreakpoint(s, rest);
            return false;
        }

        // Everything else is a Nix expression evaluated in the pause scope.
        const result = s.eval(line, scope) catch |e| {
            try self.reportErr("{s}", .{@errorName(e)});
            return false;
        };
        try self.printValue(s, result);
        return false;
    }

    // -- rendering --------------------------------------------------------------

    fn banner(self: *Console, w: *std.Io.Writer, s: *DebugSession) !void {
        try self.style(w, .trace_label);
        const reason = switch (s.reason) {
            .break_builtin => "break",
            .line_breakpoint => "breakpoint",
            .step => "step",
            .eval_error => "error",
        };
        try w.print("\n-- debugger ({s}) --", .{reason});
        try presentation.reset(w, self.use_color);
        try w.writeByte('\n');
        if (s.currentFrame()) |f| {
            try self.writeFrameLine(w, s, 0, s.frameCount() - 1, true);
            try self.sourceSnippet(w, s, f);
        }
        // Only break/error carry a meaningful value; a line/step stop doesn't.
        if (s.reason == .break_builtin or s.reason == .eval_error) {
            try w.writeAll("value: ");
            self.renderTo(w, s, s.value) catch try w.writeAll("<unavailable>");
            try w.writeByte('\n');
        }
        try w.writeAll("type `help` for commands, `c` to continue.\n");
    }

    /// Print the source line at the current frame's span, syntax-highlighted,
    /// with a caret underlining the span. One line of context each side. A
    /// no-op when the source or span is unavailable (e.g. a spanless thunk).
    fn sourceSnippet(self: *Console, w: *std.Io.Writer, s: *DebugSession, f: engine.DebugFrame) !void {
        const span = f.span orelse return;
        const text = s.frameSourceText(s.frameCount() - 1) orelse return;
        if (span.offset >= text.len) return;

        const cur = lineBounds(text, span.offset);
        // A line of context before and after, when present.
        const before: ?Bounds = if (cur.start > 0) lineBounds(text, cur.start - 1) else null;
        const after: ?Bounds = if (cur.end < text.len) lineBounds(text, cur.end + 1) else null;

        if (before) |b| try self.snippetLine(w, text[b.start..b.end], f.line - 1, false);
        try self.snippetLine(w, text[cur.start..cur.end], f.line, true);
        // Caret under the span within the current line.
        const col: usize = span.offset - cur.start;
        const len: usize = @min(@as(usize, @max(span.len, 1)), (cur.end - cur.start) -| col);
        try w.writeAll("      ┆ ");
        try self.style(w, .dim);
        var i: usize = 0;
        while (i < col) : (i += 1) try w.writeByte(' ');
        try presentation.reset(w, self.use_color);
        try self.style(w, .note_label);
        i = 0;
        while (i < len) : (i += 1) try w.writeByte('^');
        try presentation.reset(w, self.use_color);
        try w.writeByte('\n');
        if (after) |a| try self.snippetLine(w, text[a.start..a.end], f.line + 1, false);
    }

    fn snippetLine(self: *Console, w: *std.Io.Writer, line: []const u8, line_no: u32, current: bool) !void {
        try self.style(w, .dim);
        try w.print("{d: >5} {s} ", .{ line_no, if (current) "▶" else "┆" });
        try presentation.reset(w, self.use_color);
        try self.highlightLine(w, line);
        try w.writeByte('\n');
    }

    /// Emit `line` with per-token color (best-effort: a line that's part of a
    /// multi-line string/comment may mis-tokenize, which only affects color).
    fn highlightLine(self: *Console, w: *std.Io.Writer, line: []const u8) !void {
        if (!self.use_color) {
            try w.writeAll(line);
            return;
        }
        var sc = syntax.scanner.Scanner.init(line);
        var last: usize = 0;
        while (true) {
            const tok = sc.next();
            if (tok.type == .eof) break;
            const end = @min(tok.offset + tok.len, line.len);
            if (end <= last) break; // no progress → stop (malformed tail)
            if (tok.offset > last) try w.writeAll(line[last..tok.offset]); // gap
            const body = line[tok.offset..end];
            if (tokenColor(tok.type)) |code| {
                try w.writeAll(code);
                try w.writeAll(body);
                try w.writeAll(col_reset);
            } else {
                try w.writeAll(body);
            }
            last = end;
        }
        if (last < line.len) try w.writeAll(line[last..]);
    }

    fn backtrace(self: *Console, s: *DebugSession) !void {
        var out = self.stderr();
        defer out.interface.flush() catch {};
        const w = &out.interface;
        const n = s.frameCount();
        if (n == 0) {
            try w.writeAll("(no frames)\n");
            return;
        }
        // Innermost first, like a conventional backtrace.
        var idx: usize = n;
        var depth: usize = 0;
        while (idx > 0) : (depth += 1) {
            idx -= 1;
            try self.writeFrameLine(w, s, depth, idx, false);
        }
    }

    fn writeFrameLine(self: *Console, w: *std.Io.Writer, s: *DebugSession, depth: usize, frame_idx: usize, current: bool) !void {
        const f = s.frame(frame_idx);
        try w.print("#{d} ", .{depth});
        if (current) {
            try self.style(w, .note_label);
            try w.writeAll("→ ");
            try presentation.reset(w, self.use_color);
        }
        try self.style(w, .path);
        if (f.file) |file| {
            try w.print("{s}", .{file});
        } else {
            try w.writeAll("<no source>");
        }
        try presentation.reset(w, self.use_color);
        if (f.line != 0) try w.print(":{d}:{d}", .{ f.line, f.column });
        // Always-on qualified name (`pkgs.hello`), from the name tree.
        if (s.hasFrameName(frame_idx)) {
            try w.writeAll(" ");
            try self.style(w, .name);
            try s.writeFrameName(w, frame_idx);
            try presentation.reset(w, self.use_color);
        }
        try w.print("  (chunk #{d})\n", .{f.chunk_id});
    }

    fn locals(self: *Console, s: *DebugSession) !void {
        var out = self.stderr();
        defer out.interface.flush() catch {};
        const w = &out.interface;
        const n = s.frameCount();
        if (n == 0) {
            try w.writeAll("(no frames)\n");
            return;
        }
        // Walk frames innermost-first; a break often lands in a small argument
        // thunk with no locals, so show every frame that carries named bindings.
        var shown = false;
        var idx: usize = n;
        var depth: usize = 0;
        while (idx > 0) : (depth += 1) {
            idx -= 1;
            if (try self.frameLocals(w, s, idx, depth)) shown = true;
        }
        if (!shown) try w.writeAll("(no named locals in scope)\n");
    }

    /// Print frame `idx`'s named locals and upvalues (with a header). Returns
    /// true if it printed anything.
    fn frameLocals(self: *Console, w: *std.Io.Writer, s: *DebugSession, idx: usize, depth: usize) !bool {
        const lc = s.localCount(idx);
        const uc = s.upvalueCount(idx);
        var any = false;
        var slot: usize = 0;
        while (slot < lc) : (slot += 1) {
            const name = s.localName(idx, slot) orelse continue;
            if (!any) try self.localsHeader(w, s, idx, depth);
            any = true;
            try w.print("  {s} = ", .{name});
            self.renderTo(w, s, s.localValue(idx, slot)) catch try w.writeAll("<error>");
            try w.writeByte('\n');
        }
        var up: usize = 0;
        while (up < uc) : (up += 1) {
            const name = s.upvalueName(idx, up) orelse continue;
            if (!any) try self.localsHeader(w, s, idx, depth);
            any = true;
            try w.print("  {s} = ", .{name});
            self.renderTo(w, s, s.upvalueValue(idx, up)) catch try w.writeAll("<error>");
            try w.writeByte('\n');
        }
        return any;
    }

    fn localsHeader(self: *Console, w: *std.Io.Writer, s: *DebugSession, idx: usize, depth: usize) !void {
        try self.style(w, .dim);
        try w.print("#{d} ", .{depth});
        if (s.hasFrameName(idx)) try s.writeFrameName(w, idx) else try w.writeAll("<anon>");
        try w.writeAll(":\n");
        try presentation.reset(w, self.use_color);
    }

    fn armStep(self: *Console, s: *DebugSession, kind: DebugSession.StepKind) !void {
        s.step(kind) catch |e| try self.reportErr("{s}", .{@errorName(e)});
    }

    /// `break FILE:LINE` — set a source-line breakpoint.
    fn addBreakpoint(self: *Console, s: *DebugSession, arg: []const u8) !void {
        const colon = std.mem.lastIndexOfScalar(u8, arg, ':') orelse {
            try self.reportErr("usage: break FILE:LINE", .{});
            return;
        };
        const file = std.mem.trim(u8, arg[0..colon], " \t");
        const line = std.fmt.parseInt(u32, std.mem.trim(u8, arg[colon + 1 ..], " \t"), 10) catch {
            try self.reportErr("usage: break FILE:LINE (LINE must be a number)", .{});
            return;
        };
        if (file.len == 0) {
            try self.reportErr("usage: break FILE:LINE", .{});
            return;
        }
        const set = s.setBreakpoint(file, line) catch |e| {
            try self.reportErr("{s}", .{@errorName(e)});
            return;
        };
        var out = self.stderr();
        defer out.interface.flush() catch {};
        const w = &out.interface;
        if (set) |r| {
            try w.print("breakpoint {d} at {s}:{d}", .{ r.id, file, r.line });
            if (r.line != line) try w.print(" (nearest code to line {d})", .{line});
            try w.print(" — {d} site(s)\n", .{r.sites});
        } else {
            try w.print("no code found for {s}:{d} in compiled chunks\n", .{ file, line });
        }
    }

    fn listBreakpoints(self: *Console, s: *DebugSession) !void {
        var out = self.stderr();
        defer out.interface.flush() catch {};
        const w = &out.interface;
        const items = s.listBreakpoints();
        if (items.len == 0) {
            try w.writeAll("(no breakpoints)\n");
            return;
        }
        for (items) |bp| try w.print("  {d}  {s}:{d}\n", .{ bp.id, bp.file, bp.line });
    }

    fn deleteBreakpoint(self: *Console, s: *DebugSession, arg: []const u8) !void {
        const id = std.fmt.parseInt(u32, std.mem.trim(u8, arg, " \t"), 10) catch {
            try self.reportErr("usage: delete N", .{});
            return;
        };
        if (s.deleteBreakpoint(id)) {
            try self.note("deleted breakpoint {d}", .{id});
        } else {
            try self.reportErr("no breakpoint {d}", .{id});
        }
    }

    fn printValue(self: *Console, s: *DebugSession, v: Value) !void {
        var out = self.stderr();
        defer out.interface.flush() catch {};
        const w = &out.interface;
        self.renderTo(w, s, v) catch |e| {
            try self.style(w, .error_label);
            try w.writeAll("error");
            try presentation.reset(w, self.use_color);
            try w.print(": {s}\n", .{@errorName(e)});
            return;
        };
        try w.writeByte('\n');
    }

    fn renderTo(self: *Console, w: *std.Io.Writer, s: *DebugSession, v: Value) !void {
        _ = self;
        // Shallow-force so the immediate value is concrete (an unforced thunk
        // otherwise renders as `...`); nested laziness still shows `...`, which
        // the user can drill into with `p <expr>`. Best-effort: a value that
        // errors on force is rendered as-is.
        const shown = s.force(v) catch v;
        try s.writeValue(w, shown);
    }

    fn help(self: *Console) !void {
        var out = self.stderr();
        defer out.interface.flush() catch {};
        const w = &out.interface;
        try w.writeAll(
            \\debugger commands (a bare line is a Nix expression in scope; `it` is
            \\the break value). A command word alone runs the command; type an
            \\expression like `n + 1` to evaluate — or `:n` to force the command.
            \\  bt / backtrace    show the call stack with source locations
            \\  l / locals        show in-scope locals and upvalues, per frame
            \\  v / value         print the value passed to builtins.break
            \\  break FILE:LINE   set a source-line breakpoint (nearest code line)
            \\  breakpoints       list breakpoints
            \\  delete N          remove breakpoint N
            \\  n / next          step to the next line (over calls)
            \\  s / step          step to the next line (into calls)
            \\  finish            run until the current frame returns
            \\  c / continue      resume evaluation
            \\  q / quit          abort evaluation
            \\  help              this help
            \\
        );
    }

    // -- small helpers ----------------------------------------------------------

    fn style(self: *Console, w: *std.Io.Writer, which: presentation.Style) !void {
        try presentation.style(w, self.use_color, which);
    }

    fn note(self: *Console, comptime fmt: []const u8, fmt_args: anytype) !void {
        var out = self.stderr();
        defer out.interface.flush() catch {};
        try out.interface.print(fmt ++ "\n", fmt_args);
    }

    fn reportErr(self: *Console, comptime fmt: []const u8, fmt_args: anytype) !void {
        var out = self.stderr();
        defer out.interface.flush() catch {};
        const w = &out.interface;
        try self.style(w, .error_label);
        try w.writeAll("error");
        try presentation.reset(w, self.use_color);
        try w.print(": " ++ fmt ++ "\n", fmt_args);
    }
};

const ScreenPause = struct {
    io: std.Io,
    cooked: term_mod.CookedPause,

    fn begin(io: std.Io) ScreenPause {
        const cooked = term_mod.CookedPause.begin();
        if (cooked.active) writeScreenMode(io, "\x1b[?2004l\x1b[?1049l\x1b[?25h");
        return .{ .io = io, .cooked = cooked };
    }

    fn end(self: *ScreenPause) void {
        if (!self.cooked.active) return;
        self.cooked.end();
        writeScreenMode(self.io, "\x1b[?1049h\x1b[?2004h\x1b[?25l");
    }

    fn writeScreenMode(io: std.Io, bytes: []const u8) void {
        var buffer: [128]u8 = undefined;
        var out = std.Io.File.stdout().writerStreaming(io, &buffer);
        out.interface.writeAll(bytes) catch return;
        out.interface.flush() catch {};
    }
};

fn isWord(word: []const u8, aliases: []const []const u8) bool {
    for (aliases) |a| if (std.mem.eql(u8, word, a)) return true;
    return false;
}

const Bounds = struct { start: usize, end: usize };

/// The [start,end) of the line containing byte `offset` (excluding the newline).
fn lineBounds(text: []const u8, offset: usize) Bounds {
    const off = @min(offset, text.len);
    var start = off;
    while (start > 0 and text[start - 1] != '\n') start -= 1;
    var end = off;
    while (end < text.len and text[end] != '\n') end += 1;
    return .{ .start = start, .end = end };
}

/// The highlight color for a token kind, or null to leave it default.
fn tokenColor(t: TokenType) ?[]const u8 {
    return switch (t) {
        .kw_if, .kw_then, .kw_else, .kw_assert, .kw_with, .kw_let, .kw_in, .kw_rec, .kw_inherit, .kw_or, .kw_true, .kw_false, .kw_null => col_keyword,
        .string, .path, .search_path => col_string,
        .integer, .float_val => col_number,
        else => null,
    };
}

fn firstWord(s: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, s, " \t") orelse s.len;
    return s[0..end];
}

/// Shared scratch for the console's short-lived stderr writers (single fiber).
var scratch: [8 * 1024]u8 = undefined;
