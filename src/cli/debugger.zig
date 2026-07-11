//! The interactive debug console (`--debugger`).
//!
//! When a debugger is attached, evaluation pauses at `builtins.break x` (and,
//! with `--debugger`, at an evaluation error) and hands control here. The
//! console is a small line-oriented REPL over a `fix.DebugSession`: it can show
//! a backtrace with source locations, list the paused frame's locals, evaluate
//! expressions in place (with the break value bound as `it`), and continue or
//! abort. All I/O goes to the terminal via stdin/stderr so a redirected stdout
//! still receives only the final value.
//!
//! The engine upcalls through `fix.Evaluator.setDebugUi`; this file is the
//! `cli`-side implementation, so no VM internals leak below the facade.

const std = @import("std");
const fix = @import("fix");
const cli = @import("cli.zig");

const DebugSession = fix.DebugSession;
const Value = fix.Value;

/// Returned from the console to unwind and abort the whole evaluation (`:q`).
pub const AbortError = error.DebuggerAbort;

pub const Console = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    use_color: bool,
    /// Persistent stdin reader so type-ahead survives across successive breaks.
    stdin_buf: [16 * 1024]u8 = undefined,
    reader: ?std.Io.File.Reader = null,
    /// How many times we've paused (for the banner).
    hits: usize = 0,

    /// Attach this console to `ev`; `builtins.break`/errors now route here.
    pub fn install(self: *Console, ev: *fix.Evaluator) void {
        ev.setDebugUi(self, runCallback);
    }

    fn runCallback(ctx: *anyopaque, session: *DebugSession) anyerror!void {
        const self: *Console = @ptrCast(@alignCast(ctx));
        return self.drive(session);
    }

    fn reader_(self: *Console) *std.Io.File.Reader {
        if (self.reader == null) {
            self.reader = std.Io.File.stdin().readerStreaming(self.io, &self.stdin_buf);
        }
        return &self.reader.?;
    }

    fn stderr(self: *Console) std.Io.File.Writer {
        return std.Io.File.stderr().writerStreaming(self.io, &scratch);
    }

    fn drive(self: *Console, s: *DebugSession) !void {
        self.hits += 1;
        // The break value is exposed to console expressions as `it`.
        const scope = s.bindValueScope("it") catch null;

        {
            var out = self.stderr();
            defer out.interface.flush() catch {};
            const w = &out.interface;
            try self.banner(w, s);
        }

        var in = self.reader_();
        while (true) {
            {
                var out = self.stderr();
                defer out.interface.flush() catch {};
                try self.style(&out.interface, .note_label);
                try out.interface.writeAll("(debug) ");
                try cli.reset(&out.interface, self.use_color);
            }
            const raw = in.interface.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => {
                    _ = in.interface.discardDelimiterInclusive('\n') catch {};
                    continue;
                },
                else => return err,
            } orelse return; // EOF: resume as if `continue`.
            const line = std.mem.trim(u8, raw, " \t\r\n");
            if (try self.dispatch(s, line, scope)) return;
        }
    }

    /// Handle one console line. Returns true when evaluation should resume.
    fn dispatch(self: *Console, s: *DebugSession, line: []const u8, scope: ?Value) !bool {
        if (line.len == 0) return false;

        // A leading ':' is optional on commands (`:bt` == `bt`).
        const cmd = if (line[0] == ':') line[1..] else line;
        const word = firstWord(cmd);
        const rest = std.mem.trim(u8, cmd[word.len..], " \t");

        if (eq(word, "c") or eq(word, "cont") or eq(word, "continue")) return true;
        if (eq(word, "q") or eq(word, "quit") or eq(word, "abort")) return AbortError;
        if (eq(word, "help") or eq(word, "?") or eq(word, "h")) {
            try self.help();
            return false;
        }
        if (eq(word, "bt") or eq(word, "backtrace") or eq(word, "where") or eq(word, "w")) {
            try self.backtrace(s);
            return false;
        }
        if (eq(word, "l") or eq(word, "locals")) {
            try self.locals(s);
            return false;
        }
        if (eq(word, "v") or eq(word, "value")) {
            try self.printValue(s, s.value);
            return false;
        }

        // `p <expr>` prints an expression; a bare expression does the same.
        const expr = if (eq(word, "p") or eq(word, "print") or eq(word, "e") or eq(word, "eval")) rest else line;
        if (expr.len == 0) {
            try self.reportErr("empty expression", .{});
            return false;
        }
        const result = s.eval(expr, scope) catch |e| {
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
            .break_builtin => "breakpoint",
            .eval_error => "error",
        };
        try w.print("\n-- debugger ({s}) --", .{reason});
        try cli.reset(w, self.use_color);
        try w.writeByte('\n');
        if (s.currentFrame()) |f| try self.writeFrameLine(w, s, 0, f, true);
        try w.writeAll("value: ");
        self.renderTo(w, s, s.value) catch try w.writeAll("<unavailable>");
        try w.writeAll("\ntype `help` for commands, `c` to continue.\n");
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
            try self.writeFrameLine(w, s, depth, s.frame(idx), false);
        }
    }

    fn writeFrameLine(self: *Console, w: *std.Io.Writer, s: *DebugSession, depth: usize, f: fix.DebugFrame, current: bool) !void {
        _ = s;
        try w.print("#{d} ", .{depth});
        if (current) {
            try self.style(w, .note_label);
            try w.writeAll("→ ");
            try cli.reset(w, self.use_color);
        }
        try self.style(w, .path);
        if (f.file) |file| {
            try w.print("{s}", .{file});
        } else {
            try w.writeAll("<no source>");
        }
        try cli.reset(w, self.use_color);
        if (f.line != 0) try w.print(":{d}:{d}", .{ f.line, f.column });
        if (f.name) |name| {
            try w.writeAll(" ");
            try self.style(w, .name);
            try w.print("{s}", .{name});
            try cli.reset(w, self.use_color);
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
        const i = n - 1;
        const lc = s.localCount(i);
        const uc = s.upvalueCount(i);
        if (lc == 0 and uc == 0) {
            try w.writeAll("(no locals in scope)\n");
            return;
        }
        var slot: usize = 0;
        while (slot < lc) : (slot += 1) {
            try w.print("  local[{d}] = ", .{slot});
            self.renderTo(w, s, s.localValue(i, slot)) catch try w.writeAll("<error>");
            try w.writeByte('\n');
        }
        var up: usize = 0;
        while (up < uc) : (up += 1) {
            try w.print("  upvalue[{d}] = ", .{up});
            self.renderTo(w, s, s.upvalueValue(i, up)) catch try w.writeAll("<error>");
            try w.writeByte('\n');
        }
    }

    fn printValue(self: *Console, s: *DebugSession, v: Value) !void {
        var out = self.stderr();
        defer out.interface.flush() catch {};
        const w = &out.interface;
        self.renderTo(w, s, v) catch |e| {
            try self.style(w, .error_label);
            try w.writeAll("error");
            try cli.reset(w, self.use_color);
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
            \\debugger commands:
            \\  <expr>            evaluate an expression (`it` is the break value)
            \\  p / print EXPR    same, explicit
            \\  bt / backtrace    show the call stack with source locations
            \\  l / locals        show the current frame's locals and upvalues
            \\  v / value         print the value passed to builtins.break
            \\  c / continue      resume evaluation
            \\  q / quit          abort evaluation
            \\  help              this help
            \\
        );
    }

    // -- small helpers ----------------------------------------------------------

    fn style(self: *Console, w: *std.Io.Writer, which: cli.Style) !void {
        try cli.style(w, self.use_color, which);
    }

    fn reportErr(self: *Console, comptime fmt: []const u8, fmt_args: anytype) !void {
        var out = self.stderr();
        defer out.interface.flush() catch {};
        const w = &out.interface;
        try self.style(w, .error_label);
        try w.writeAll("error");
        try cli.reset(w, self.use_color);
        try w.print(": " ++ fmt ++ "\n", fmt_args);
    }
};

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn firstWord(s: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, s, " \t") orelse s.len;
    return s[0..end];
}

/// Shared scratch for the console's short-lived stderr writers (single fiber).
var scratch: [8 * 1024]u8 = undefined;
