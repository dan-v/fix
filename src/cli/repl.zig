//! `fix repl` — the interactive read-eval-print loop.
//!
//! Two strictly separated modes:
//!
//! - **Interactive** (stdin AND stdout are a tty, and `--bare` not given): a
//!   hand-rolled raw-mode line editor (`repl/editor.zig` + `repl/render.zig`)
//!   with history, completion, smart-enter multiline, and the `:disasm`
//!   pager. Raw mode is restored on every exit path, including panics and
//!   fatal signals (`repl/term.zig`).
//! - **Bare** (`--bare`, or any non-tty end): a plain read-a-line loop — no
//!   escape sequences, no raw mode, no redraw tricks. Lines are accumulated
//!   until they form a complete expression, so multiline input pipes work.
//!
//! Both modes share the same command set (`repl/commands.zig`) and the same
//! evaluation core: expressions evaluate inside an ambient scope attrset
//! holding the repl bindings (`name = expr`, `:l`, and `it`), which is also
//! registered as a GC root; a collection runs between inputs so memory does
//! not accrete across evaluations.

const std = @import("std");
const presentation = @import("presentation.zig");
const progress_ui = @import("progress.zig");
const args = @import("args.zig");
const setup = @import("setup.zig");
const debugger = @import("debugger.zig");
const render_err = @import("render.zig");
const engine = @import("expr");
const runtime = @import("runtime");
const future_mod = runtime.future;
const types = runtime.types;

const commands = @import("repl/commands.zig");
const check = @import("repl/check.zig");
const history_mod = @import("repl/history.zig");
const editor_mod = @import("repl/editor.zig");
const keys_mod = @import("repl/keys.zig");
const render_mod = @import("repl/render.zig");
const term_mod = @import("repl/term.zig");
const complete_mod = @import("repl/complete.zig");
const pager_mod = @import("repl/pager.zig");

const Options = args.Options;
const Evaluator = engine.Evaluator;
const Value = runtime.Value;

pub const synopsis =
    \\usage: fix repl [options]
    \\
    \\start an interactive read-eval-print loop.
;

const prompt_main = "fix> ";
const prompt_cont = "...> ";

/// `fix repl` subcommand entry point.
pub fn run(process: @import("process_context.zig").ProcessContext, init: std.process.Init, args_iter: *std.process.Args.Iterator) !u8 {
    const allocator = process.allocator;
    var options = args.parse(allocator, args_iter, null) catch |err| switch (err) {
        error.Help => {
            args.writeHelp(init.io, synopsis, .repl);
            return 0;
        },
        else => {
            std.debug.print("error: {s}\n\n{s}\n", .{ args.errorMessage(err), synopsis });
            return 2;
        },
    };
    defer options.deinit(allocator);
    if (options.source != null) {
        std.debug.print("error: repl takes no expression, file, or flake\n\n{s}\n", .{synopsis});
        return 2;
    }

    // THE MODE GATE. Interactive only when both ends are a terminal and
    // --bare wasn't given; everything else is the plain loop. Decided once,
    // up front — nothing downstream re-tests tty-ness.
    const stdin_tty = std.Io.File.stdin().isTty(init.io) catch false;
    const stdout_tty = std.Io.File.stdout().isTty(init.io) catch false;
    const interactive = stdin_tty and stdout_tty and !options.bare;

    // The debugger needs a deterministic pause point: one worker, no
    // speculation. Same posture as `fix eval --debugger`.
    const worker_count = if (options.debugger) 1 else try setup.workerCount(options);
    setup.applyMemoryBacking(options.hugetlb);
    var ev = try Evaluator.init(allocator, worker_count);
    defer ev.deinit();
    const term = try setup.configure(&ev, init, options);

    var console: debugger.Console = undefined;
    if (options.debugger) {
        ev.setParallelismToggles(true, true);
        ev.setCaptureChunkNames(true);
        console = .{ .allocator = allocator, .io = init.io, .use_color = term.use_color };
        console.install(&ev);
    }

    var progress = progress_ui.EvalProgress.init(init.io, term.show_progress);
    var repl_ok = false;
    defer progress.deinit(repl_ok);
    if (term.show_progress) ev.setProgressSink(progress.sink());

    // Normal repl output suppresses color in bare mode; the debugger console
    // colors by the resolved terminal decision (its banner/snippet do too).
    ev.setValueColor(if (options.debugger) term.use_color else (term.use_color and interactive));
    var repl = Repl.init(allocator, init, options, &ev, term.use_color and interactive, interactive);
    defer repl.deinit();
    if (options.debugger) repl.debug_console = &console;

    if (interactive) {
        try repl.runInteractive();
    } else {
        try repl.runBare(stdin_tty);
    }
    repl_ok = true;
    return 0;
}

const Repl = struct {
    allocator: std.mem.Allocator,
    proc_init: std.process.Init,
    io: std.Io,
    options: Options,
    ev: *Evaluator,
    use_color: bool,
    interactive: bool,
    /// The debug console when `--debugger` is set, so the bare loop can share
    /// its stdin reader (see `runBare`). Null otherwise.
    debug_console: ?*debugger.Console = null,

    /// Scope bindings, insertion-ordered. Keys are owned; values are heap
    /// Values kept alive via `gc_extra_roots` + the scope attrset.
    bindings: std.StringArrayHashMapUnmanaged(Value) = .empty,
    /// The bindings as one attrset value, rebuilt when bindings change.
    /// Compiled into every input chunk as its ambient scope.
    scope: ?Value = null,
    /// Files loaded with :l, in order, for :r. Owned.
    loaded: std.ArrayListUnmanaged([]u8) = .empty,
    history: history_mod.History,
    quit: bool = false,

    fn init(
        allocator: std.mem.Allocator,
        proc_init: std.process.Init,
        options: Options,
        ev: *Evaluator,
        use_color: bool,
        interactive: bool,
    ) Repl {
        return .{
            .allocator = allocator,
            .proc_init = proc_init,
            .io = proc_init.io,
            .options = options,
            .ev = ev,
            .use_color = use_color,
            .interactive = interactive,
            .history = history_mod.History.init(allocator),
        };
    }

    fn deinit(self: *Repl) void {
        var it = self.bindings.iterator();
        while (it.next()) |e| self.allocator.free(e.key_ptr.*);
        self.bindings.deinit(self.allocator);
        for (self.loaded.items) |p| self.allocator.free(p);
        self.loaded.deinit(self.allocator);
        self.history.deinit();
    }

    // -- bare mode -----------------------------------------------------------

    /// The plain loop: read lines, accumulate until the input parses as a
    /// complete expression, process. No escape sequences anywhere; a prompt
    /// is written only when stdin is a terminal (`--bare` at a terminal).
    fn runBare(self: *Repl, show_prompt: bool) !void {
        var stdin_buffer: [64 * 1024]u8 = undefined;
        var stdin = std.Io.File.stdin().readerStreaming(self.io, &stdin_buffer);
        // Share this reader with the debug console so a break mid-evaluation
        // reads its commands from the same buffered pipe instead of racing it.
        if (self.debug_console) |c| c.attachReader(&stdin);

        var pending: std.ArrayListUnmanaged(u8) = .empty;
        defer pending.deinit(self.allocator);

        while (!self.quit) {
            if (show_prompt) {
                var out = self.stdout();
                defer out.interface.flush() catch {};
                out.interface.writeAll(if (pending.items.len == 0) prompt_main else prompt_cont) catch {};
            }
            const line = stdin.interface.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => {
                    try self.printError("input line is too long", .{});
                    _ = stdin.interface.discardDelimiterInclusive('\n') catch {};
                    pending.clearRetainingCapacity();
                    continue;
                },
                else => return err,
            } orelse {
                // EOF: process whatever is pending so a piped script's last
                // (unterminated) expression still runs.
                if (std.mem.trim(u8, pending.items, " \t\r\n").len > 0) {
                    try self.processInput(pending.items);
                }
                break;
            };

            if (pending.items.len == 0) {
                const trimmed = std.mem.trim(u8, line, " \t\r");
                if (trimmed.len == 0) continue;
                // Commands never continue across lines.
                if (trimmed[0] == ':') {
                    try self.processInput(trimmed);
                    continue;
                }
            }
            try pending.appendSlice(self.allocator, line);
            if (check.isComplete(self.allocator, pending.items)) {
                try self.processInput(pending.items);
                pending.clearRetainingCapacity();
            } else {
                try pending.append(self.allocator, '\n');
            }
        }
    }

    // -- interactive mode ------------------------------------------------------

    fn runInteractive(self: *Repl) !void {
        const env = self.proc_init.environ_map;
        const hint_off = env.get("FIX_REPL_NO_HINT") != null;
        if (!hint_off) {
            var out = self.stdout();
            defer out.interface.flush() catch {};
            try presentation.style(&out.interface, self.use_color, .dim);
            try out.interface.writeAll("fix repl — :? for help, :q or Ctrl-D to quit\n");
            try presentation.reset(&out.interface, self.use_color);
        }

        self.history.open(self.io, env);

        var completer_ctx = complete_mod.Ctx{
            .ev = self.ev,
            .io = self.io,
            .bindings = &self.bindings,
        };
        var editor = editor_mod.Editor.init(
            self.allocator,
            &self.history,
            complete_mod.completer(&completer_ctx),
            .{ .ctx = self, .isCompleteFn = isCompleteThunk },
        );
        defer editor.deinit();

        while (!self.quit) {
            const line = self.readLine(&editor) catch |err| switch (err) {
                error.NotATerminal => return self.runBare(false),
                else => return err,
            } orelse break;
            defer self.allocator.free(line);

            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len == 0) continue;
            try self.history.add(trimmed);
            try self.processInput(trimmed);
        }
    }

    fn isCompleteThunk(ctx: *anyopaque, text: []const u8) bool {
        const self: *Repl = @ptrCast(@alignCast(ctx));
        return check.isComplete(self.allocator, text);
    }

    /// Read one (possibly multiline) input with the raw-mode editor.
    /// Returns null on EOF (Ctrl-D at an empty prompt).
    fn readLine(self: *Repl, editor: *editor_mod.Editor) !?[]u8 {
        var raw = term_mod.RawMode.enable() catch return error.NotATerminal;
        defer raw.disable();

        var stdout_buffer: [8 * 1024]u8 = undefined;
        var stdout_w = std.Io.File.stdout().writerStreaming(self.io, &stdout_buffer);
        const w = &stdout_w.interface;

        // Bracketed paste on for the duration of the edit.
        try w.writeAll("\x1b[?2004h");
        defer {
            w.writeAll("\x1b[?2004l") catch {};
            w.flush() catch {};
        }

        var renderer = render_mod.Renderer.init(
            self.allocator,
            term_mod.size().cols,
            self.use_color,
            presentation.styleCode(true, .trace_label),
        );
        defer renderer.deinit();

        editor.reset();
        var decoder = keys_mod.Decoder{};
        var events: keys_mod.Decoder.List = .empty;
        defer events.deinit(self.allocator);
        var overlay_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer overlay_arena.deinit();

        var read_buf: [512]u8 = undefined;
        while (true) {
            // Draw the current editor state (row diffing makes repeated
            // draws cheap; unchanged frames emit nothing).
            _ = overlay_arena.reset(.retain_capacity);
            try renderer.draw(w, try self.buildView(editor, overlay_arena.allocator()));
            try w.flush();

            const result = term_mod.readInput(&read_buf, if (decoder.wantsMore()) 40 else -1);
            events.clearRetainingCapacity();
            switch (result) {
                .timeout => try decoder.idleFlush(self.allocator, &events),
                .winch => {
                    renderer.setWidth(term_mod.size().cols);
                    renderer.invalidate();
                    // The terminal reflowed our frame unpredictably; start
                    // this row fresh and repaint everything below.
                    try w.writeAll("\r\x1b[J");
                    continue;
                },
                .eof => {
                    try renderer.finish(w);
                    return null;
                },
                .data => |n| for (read_buf[0..n]) |b| try decoder.feed(self.allocator, b, &events),
            }

            for (events.items) |key| {
                switch (try editor.handleKey(key)) {
                    .none => {},
                    .bell => try w.writeAll("\x07"),
                    .submit => {
                        try closeFrame(&renderer, w, editor.text());
                        try w.flush();
                        return try editor.takeText();
                    },
                    .eof => {
                        try closeFrame(&renderer, w, editor.text());
                        try w.flush();
                        return null;
                    },
                    .cancel => {
                        try closeFrame(&renderer, w, editor.text());
                        editor.reset();
                    },
                    .clear_screen => {
                        try w.writeAll("\x1b[H\x1b[2J");
                        renderer.invalidate();
                    },
                    .suspend_process => {
                        try closeFrame(&renderer, w, editor.text());
                        try w.flush();
                        raw.suspendProcess();
                        renderer.setWidth(term_mod.size().cols);
                        renderer.invalidate();
                    },
                }
            }
        }
    }

    /// Leave the edit frame cleanly: one last overlay-free draw with the
    /// cursor at the end of the text, then `finish` (clears anything below
    /// and emits the newline). Used on submit/cancel/eof/suspend.
    fn closeFrame(renderer: *render_mod.Renderer, w: *std.Io.Writer, text: []const u8) !void {
        try renderer.draw(w, .{
            .prompt = prompt_main,
            .cont_prompt = prompt_cont,
            .text = text,
            .cursor = text.len,
        });
        try renderer.finish(w);
    }

    fn buildView(self: *Repl, editor: *editor_mod.Editor, arena: std.mem.Allocator) !render_mod.View {
        _ = self;
        var view: render_mod.View = .{
            .prompt = prompt_main,
            .cont_prompt = prompt_cont,
            .text = editor.text(),
            .cursor = editor.cursor,
        };
        var sp_buf: [96]u8 = undefined;
        if (editor.searchPrompt(&sp_buf)) |sp| {
            view.prompt = try arena.dupe(u8, sp);
            view.cont_prompt = view.prompt;
        }
        const menu = editor.menuLines();
        if (menu.len > 0) {
            view.overlay = try render_mod.formatColumns(arena, menu, term_mod.size().cols, 8);
        }
        return view;
    }

    // -- input processing (shared by both modes) -------------------------------

    fn processInput(self: *Repl, input: []const u8) !void {
        const trimmed = std.mem.trim(u8, input, " \t\r\n");
        if (trimmed.len == 0) return;
        if (trimmed[0] == ':') {
            try self.runCommand(trimmed);
            return;
        }
        if (parseBinding(trimmed)) |b| {
            if (try self.evalExpr(b.expr)) |value| {
                try self.bind(b.name, value);
                try self.collectBetweenInputs();
            }
            return;
        }
        if (try self.evalExpr(trimmed)) |value| {
            // Root the result as `it` BEFORE printing forces anything else,
            // and before the between-inputs collection.
            try self.bind("it", value);
            try self.printResult(value, trimmed);
            try self.collectBetweenInputs();
        }
    }

    fn runCommand(self: *Repl, input: []const u8) !void {
        const word_end = std.mem.indexOfAny(u8, input, " \t") orelse input.len;
        const word = input[0..word_end];
        const rest = std.mem.trim(u8, input[word_end..], " \t");

        const cmd = commands.find(word) orelse {
            try self.printError("unknown command `{s}` — :? lists commands", .{word});
            return;
        };
        switch (cmd.arg) {
            .expr, .path => if (rest.len == 0) {
                try self.printError("{s} needs {s} — :? for details", .{ word, cmd.metavar });
                return;
            },
            .none => if (rest.len != 0) {
                try self.printError("{s} takes no argument", .{word});
                return;
            },
            .opt_expr => {},
        }

        switch (cmd.id) {
            .help => {
                var out = self.stdout();
                defer out.interface.flush() catch {};
                try commands.writeHelp(&out.interface);
            },
            .quit => self.quit = true,
            .load => {
                if (try self.loadFile(rest)) {
                    try self.loaded.append(self.allocator, try self.allocator.dupe(u8, rest));
                    try self.collectBetweenInputs();
                }
            },
            .reload => {
                for (self.loaded.items) |path| {
                    if (!try self.loadFile(path)) break;
                }
                try self.collectBetweenInputs();
            },
            .type_of => {
                if (try self.evalExpr(rest)) |v| {
                    const forced = self.ev.forceValue(v) catch v;
                    var out = self.stdout();
                    defer out.interface.flush() catch {};
                    try self.describeType(&out.interface, forced);
                    try out.interface.writeByte('\n');
                    try self.collectBetweenInputs();
                }
            },
            .print => {
                if (try self.evalExpr(rest)) |v| {
                    try self.bind("it", v);
                    self.ev.forceDeep(v) catch |err| {
                        try render_err.evaluationError(self.io, self.use_color, self.options.show_trace, self.ev, rest, err);
                        return;
                    };
                    try self.printResult(v, rest);
                    try self.collectBetweenInputs();
                }
            },
            .inspect => {
                if (try self.evalExpr(rest)) |v| {
                    var out = self.stdout();
                    defer out.interface.flush() catch {};
                    try self.inspectValue(&out.interface, v);
                    try self.collectBetweenInputs();
                }
            },
            .disasm => try self.disasm(rest),
            .env => {
                var out = self.stdout();
                defer out.interface.flush() catch {};
                if (self.bindings.count() == 0) {
                    try out.interface.writeAll("no bindings — `name = expr` creates one\n");
                } else {
                    var it = self.bindings.iterator();
                    while (it.next()) |e| {
                        try presentation.style(&out.interface, self.use_color, .name);
                        try out.interface.writeAll(e.key_ptr.*);
                        try presentation.reset(&out.interface, self.use_color);
                        try out.interface.writeAll(" : ");
                        try self.describeType(&out.interface, e.value_ptr.*);
                        try out.interface.writeByte('\n');
                    }
                }
            },
            .gc => {
                const r = self.ev.collectMajorNow();
                var out = self.stdout();
                defer out.interface.flush() catch {};
                if (!r.ran) {
                    try out.interface.writeAll("gc: collector inactive (non-gc build, --max-memory=0, or nothing evaluated yet)\n");
                } else {
                    try out.interface.print("gc: heap reserved {d:.1} MiB -> {d:.1} MiB\n", .{
                        @as(f64, @floatFromInt(r.reserved_before)) / (1 << 20),
                        @as(f64, @floatFromInt(r.reserved_after)) / (1 << 20),
                    });
                }
            },
        }
    }

    // -- evaluation ------------------------------------------------------------

    /// Evaluate an expression in the repl scope. Failures render to stderr
    /// and yield null.
    fn evalExpr(self: *Repl, source: []const u8) !?Value {
        self.ev.progressSessionBegin("input");
        defer self.ev.progressSessionEnd();
        self.ev.startProgressSampler();
        defer self.ev.stopProgressSampler();

        const value = self.ev.evaluateWithScope(source, self.scope) catch |err| {
            try render_err.evalFailure(self.io, self.use_color, self.options.show_trace, self.ev, source, err);
            return null;
        };
        return value;
    }

    fn printResult(self: *Repl, value: Value, source: []const u8) !void {
        const mode = self.options.evaluationMode();
        if (mode.strict) {
            self.ev.forceDeep(value) catch |err| {
                try render_err.evaluationError(self.io, self.use_color, self.options.show_trace, self.ev, source, err);
                return;
            };
        }
        var out = self.stdout();
        defer out.interface.flush() catch {};
        const w = &out.interface;
        const write_err: ?anyerror = blk: {
            switch (mode.output) {
                .nix => self.ev.writeValue(w, value) catch |err| break :blk err,
                .json => self.ev.writeJsonValue(w, value) catch |err| break :blk err,
                .xml => self.ev.writeXmlValue(w, value) catch |err| break :blk err,
            }
            break :blk null;
        };
        if (write_err) |err| {
            if (err == error.WriteFailed) return err;
            w.flush() catch {};
            try render_err.evaluationError(self.io, self.use_color, self.options.show_trace, self.ev, source, err);
            return;
        }
        if (mode.output != .xml) try w.writeByte('\n');
    }

    /// `:l PATH` — evaluate a file (auto-calling a top-level function with
    /// `{}`, as nix repl does) and merge its attrset into the scope.
    fn loadFile(self: *Repl, path: []const u8) !bool {
        var expr: std.ArrayListUnmanaged(u8) = .empty;
        defer expr.deinit(self.allocator);
        try expr.appendSlice(self.allocator, "let __fix_l = import (");
        if (path.len > 0 and path[0] == '<') {
            try expr.appendSlice(self.allocator, path);
        } else if (path.len > 0 and (path[0] == '/' or path[0] == '.' or path[0] == '~')) {
            try expr.appendSlice(self.allocator, path);
        } else {
            try expr.appendSlice(self.allocator, "./");
            try expr.appendSlice(self.allocator, path);
        }
        try expr.appendSlice(self.allocator, "); in if builtins.isFunction __fix_l then __fix_l {} else __fix_l");

        const value = (try self.evalExpr(expr.items)) orelse return false;
        const forced = self.ev.forceValue(value) catch |err| {
            try render_err.evaluationError(self.io, self.use_color, self.options.show_trace, self.ev, path, err);
            return false;
        };
        if (!forced.isAttrs()) {
            try self.printError("{s} did not evaluate to an attrset", .{path});
            return false;
        }
        const tooling = self.ev.tooling();
        const entries = tooling.attrs(forced) catch return false;
        var added: usize = 0;
        for (entries) |entry| {
            const name = tooling.internText(entry.name);
            try self.bindNoRebuild(name, entry.value);
            added += 1;
        }
        // One scope rebuild for the whole file, not one per attribute.
        try self.rebuildScope();
        var out = self.stdout();
        defer out.interface.flush() catch {};
        try out.interface.print("added {d} bindings\n", .{added});
        return true;
    }

    // -- bindings & GC ----------------------------------------------------------

    /// Bind `name` to `value` and rebuild the scope attrset + GC roots.
    fn bind(self: *Repl, name: []const u8, value: Value) !void {
        try self.bindNoRebuild(name, value);
        try self.rebuildScope();
    }

    fn bindNoRebuild(self: *Repl, name: []const u8, value: Value) !void {
        const gop = try self.bindings.getOrPut(self.allocator, name);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, name);
        }
        gop.value_ptr.* = value;
    }

    /// Ask the evaluator to rebuild the scope attrset and replace its GC roots
    /// as one operation.
    fn rebuildScope(self: *Repl) !void {
        var bindings: std.ArrayListUnmanaged(Evaluator.ScopeBinding) = .empty;
        defer bindings.deinit(self.allocator);

        var it = self.bindings.iterator();
        while (it.next()) |e| {
            try bindings.append(self.allocator, .{ .name = e.key_ptr.*, .value = e.value_ptr.* });
        }
        self.scope = try self.ev.replaceExternalScope(bindings.items);
    }

    /// The between-inputs collection: reclaim the last evaluation's garbage
    /// so repl memory tracks the live bindings, not the session's history.
    /// The first call arms tracking (cheap); later calls run a full MAJOR
    /// collection — the repl is idle here, so pay for reclaiming tenured
    /// garbage too (a minor leaves the old generation, which under parallel
    /// workers otherwise ratchets reserved memory up across inputs).
    fn collectBetweenInputs(self: *Repl) !void {
        _ = self.ev.collectMajorNow();
    }

    // -- introspection ----------------------------------------------------------

    fn describeType(self: *Repl, w: *std.Io.Writer, value: Value) !void {
        switch (value.kind()) {
            .null => try w.writeAll("null"),
            .bool_true, .bool_false => try w.writeAll("a boolean"),
            .int, .boxed_int => try w.writeAll("an integer"),
            .float => try w.writeAll("a float"),
            .string, .string_context => try w.writeAll("a string"),
            .path => try w.writeAll("a path"),
            .list => {
                const n = self.ev.tooling().listLen(value) catch 0;
                try w.print("a list ({d} item{s})", .{ n, if (n == 1) "" else "s" });
            },
            .attrs => {
                const entries = self.ev.tooling().attrs(value) catch &.{};
                try w.print("a set ({d} attr{s})", .{ entries.len, if (entries.len == 1) "" else "s" });
            },
            .closure, .builtin, .builtin_closure, .partial_app => try w.writeAll("a function"),
            .thunk => try w.writeAll("a thunk (unforced)"),
        }
    }

    /// `:i` — one value, inspected without forcing: kind, thunk state and
    /// backing chunk, closure chunk/arity, container sizes.
    fn inspectValue(self: *Repl, w: *std.Io.Writer, value: Value) !void {
        switch (value.kind()) {
            .thunk => {
                const id = value.asObjectId();
                const thunk = self.ev.tooling().thunk(value) catch {
                    try w.writeAll("thunk (unreadable)\n");
                    return;
                };
                const state: future_mod.FutureState = @enumFromInt(thunk.future.state.load(.acquire));
                try w.print("thunk #{d}: {s}", .{ id, @tagName(state) });
                switch (state) {
                    .resolved => {
                        try w.writeAll(" -> ");
                        try self.describeType(w, thunk.payload.result);
                        try w.writeByte('\n');
                    },
                    .errored => try w.writeAll(" (cached failure)\n"),
                    else => {
                        switch (thunk.targetKind()) {
                            .bytecode => try w.print(" (bytecode, chunk #{d} — :d it)\n", .{thunk.payload.target.bytecode.chunk_id}),
                            .closure => try w.writeAll(" (closure application)\n"),
                            .pass_through => try w.writeAll(" (pass-through cell)\n"),
                            .attr_access => try w.writeAll(" (attribute access)\n"),
                            .deferred => try w.writeAll(" (deferred compile — forced on first use)\n"),
                        }
                    },
                }
            },
            .closure => {
                const closure = self.ev.tooling().closure(value) catch {
                    try w.writeAll("closure (unreadable)\n");
                    return;
                };
                var arity: usize = 1;
                if (self.ev.getChunk(closure.chunk_id)) |chunk| arity = chunk.arity;
                try w.print("closure: chunk #{d}, arity {d}, {d} upvalue{s} — :d it\n", .{
                    closure.chunk_id,
                    arity,
                    closure.upvalues.len,
                    if (closure.upvalues.len == 1) "" else "s",
                });
            },
            else => {
                try self.describeType(w, value);
                try w.writeByte('\n');
            },
        }
    }

    /// `:d EXPR` — find the chunk behind the expression: a closure or
    /// unforced bytecode thunk exposes its own chunk; anything else
    /// disassembles the expression's compiled top chunk.
    fn disasm(self: *Repl, expr: []const u8) !void {
        var chunk_id: ?types.ChunkId = null;

        // Value-first: `:d f` on a function should show f's body, not the
        // trivial lookup chunk.
        if (try self.evalExpr(expr)) |value| {
            switch (value.kind()) {
                .closure => {
                    if (self.ev.tooling().closure(value)) |c| {
                        chunk_id = c.chunk_id;
                    } else |_| {}
                },
                .thunk => {
                    if (self.ev.tooling().thunk(value)) |t| {
                        if (t.targetKind() == .bytecode) chunk_id = t.payload.target.bytecode.chunk_id;
                    } else |_| {}
                },
                else => {},
            }
        } else return; // evaluation failed; error already rendered

        if (chunk_id == null) {
            chunk_id = self.ev.compileSourceScoped(expr, self.scope) catch |err| {
                try self.printError("compilation failed: {s}", .{@errorName(err)});
                return;
            };
        }

        if (self.interactive) {
            try pager_mod.browse(self.allocator, self.io, self.ev, chunk_id.?, self.use_color);
        } else {
            var out = self.stdout();
            defer out.interface.flush() catch {};
            try pager_mod.writePlain(self.allocator, &out.interface, self.ev, chunk_id.?);
        }
        try self.collectBetweenInputs();
    }

    // -- small output helpers ----------------------------------------------------

    fn stdout(self: *Repl) std.Io.File.Writer {
        // A fresh short-lived buffered writer per print keeps interleaving
        // with the engine's own stdout writes (writeValue) safe.
        return std.Io.File.stdout().writerStreaming(self.io, &stdout_scratch);
    }

    fn printError(self: *Repl, comptime fmt: []const u8, fmt_args: anytype) !void {
        var stderr_buffer: [1024]u8 = undefined;
        var stderr = try presentation.lockStderr(self.io, &stderr_buffer);
        defer stderr.deinit();
        const w = stderr.writer();
        try presentation.style(w, self.use_color, .error_label);
        try w.writeAll("error");
        try presentation.reset(w, self.use_color);
        try w.print(": " ++ fmt ++ "\n", fmt_args);
        try stderr.flush();
    }
};

/// Shared scratch for the repl's short-lived stdout writers (single-threaded).
var stdout_scratch: [8 * 1024]u8 = undefined;

// -- `name = expr` binding detection -----------------------------------------

const Binding = struct { name: []const u8, expr: []const u8 };

const nix_keywords = [_][]const u8{
    "let", "in", "if", "then", "else", "with", "rec", "inherit", "assert", "or",
};

/// Recognize a top-level `name = expr` binding (nix-repl style). The name
/// must be a plain identifier (not a keyword), the `=` must not begin `==`,
/// and the right side must be non-empty.
fn parseBinding(input: []const u8) ?Binding {
    var i: usize = 0;
    if (i >= input.len) return null;
    const first = input[0];
    if (!(std.ascii.isAlphabetic(first) or first == '_')) return null;
    while (i < input.len and (std.ascii.isAlphanumeric(input[i]) or
        input[i] == '_' or input[i] == '\'' or input[i] == '-')) : (i += 1)
    {}
    const name = input[0..i];
    for (nix_keywords) |kw| {
        if (std.mem.eql(u8, name, kw)) return null;
    }
    while (i < input.len and (input[i] == ' ' or input[i] == '\t')) i += 1;
    if (i >= input.len or input[i] != '=') return null;
    i += 1;
    if (i < input.len and input[i] == '=') return null; // `a == b`
    const expr = std.mem.trim(u8, input[i..], " \t\r\n");
    if (expr.len == 0) return null;
    return .{ .name = name, .expr = expr };
}

test {
    _ = @import("repl/keys.zig");
    _ = @import("repl/width.zig");
    _ = @import("repl/editor.zig");
    _ = @import("repl/render.zig");
    _ = @import("repl/history.zig");
    _ = @import("repl/check.zig");
    _ = @import("repl/commands.zig");
    _ = @import("repl/complete.zig");
    _ = @import("repl/pager.zig");
}

const testing = std.testing;

test "parseBinding recognizes bindings, rejects comparisons and keywords" {
    const b = parseBinding("x = 1 + 2").?;
    try testing.expectEqualStrings("x", b.name);
    try testing.expectEqualStrings("1 + 2", b.expr);

    const c = parseBinding("foo-bar' = { }").?;
    try testing.expectEqualStrings("foo-bar'", c.name);

    try testing.expect(parseBinding("x == 1") == null);
    try testing.expect(parseBinding("let = 1") == null);
    try testing.expect(parseBinding("1 = 2") == null);
    try testing.expect(parseBinding("x =") == null);
    try testing.expect(parseBinding("{ a = 1; }") == null);
    try testing.expect(parseBinding("x.y = 1") == null); // attr path: not a plain binding
}
