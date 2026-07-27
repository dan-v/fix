//! Internal VM explorer component.
//!
//! Methods are parameterized by the private explorer state type and wired as
//! direct aliases by `operations.zig`; this module owns the behavior below.

const std = @import("std");
const engine = @import("expr");
const runtime = @import("runtime");
const term_mod = @import("../term.zig");
const keys_mod = @import("../keys.zig");
const editor_mod = @import("../editor.zig");
const render_mod = @import("../render.zig");
const transcript_mod = @import("../transcript.zig");
const vm_model = @import("model.zig");
const vm_helpers = @import("semantics.zig");
const history_mod = @import("../history.zig");
const source_render = @import("../../source_render.zig");
const command_mod = @import("../../debugger_command.zig");
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
        const OpenMode = Explorer.Ops.controller.OpenMode;
        const TreeViewport = Explorer.Ops.tree_render.TreeViewport;
        const TreeCell = Explorer.Ops.tree_render.TreeCell;
        const range_leaf = Explorer.range_leaf;
        const range_branch = Explorer.range_branch;
        const preview_line_cap = Explorer.preview_line_cap;

        // -- debug pause ------------------------------------------------------------

        pub const DebugOutcome = enum { running, resume_keep, resume_close, abort };
        /// Whether the caller should keep the (owned) alternate screen up after this
        /// pause returns. A step keeps it (another pause is imminent); continue/eof
        /// closes it. `VmDebugger` owns the screen so it survives across steps.
        pub const DebugCloseIntent = enum { keep, close };

        /// The `DebugUi` upcall body: run a nested interactive loop over the paused
        /// VM, reusing the explorer's tree + inspector. The alternate screen and raw
        /// mode are already active (owned by `VmDebugger`, or borrowed from a live
        /// `:vm` session), so this only draws. Returns `debugger.AbortError` on abort.
        pub fn debugRun(self: *Explorer, session: *DebugSession, history: *history_mod.History) !DebugCloseIntent {
            var out_buf: [64 * 1024]u8 = undefined;
            var out = std.Io.File.stdout().writerStreaming(self.io, &out_buf);
            const w = &out.interface;

            const step_focus = self.pending_step_focus;
            self.pending_step_focus = null;
            self.debug_session = session;
            self.return_flash = session.reason == .return_step;
            // A previous pause may have indexed the heap before the VM resumed.
            // Every new pause is a new immutable inspection boundary.
            self.clearHeapSnapshots();
            self.clearReferenceGraph();
            self.refreshPausedTreeSnapshots();
            session.clearStep();
            self.debug_nav_mark = self.navigation.back.items.len;
            defer {
                self.return_flash = false;
                Explorer.Ops.debug_view.exitDebugView(self);
            }
            try Explorer.Ops.controller.open(self, .{ .debug_frame = session.frameCount() -| 1 });
            if (session.reason == .return_step) Explorer.Ops.pages.focusValueRow(self, session.value);
            // `open` updates the subject and normally focuses it. Across a requested
            // step, keep whichever pane owned interaction focus while still showing
            // the newly-current frame in the subject.
            if (step_focus) |focus| self.navigation.focus = focus;

            var editor = editor_mod.Editor.init(self.allocator, history, .none(), .always());
            defer editor.deinit();
            var capture = transcript_mod.Capture.init(self.allocator, 256 * 1024);
            defer capture.deinit();
            try Explorer.Ops.source_view.rebuildTranscriptLines(self, capture.written());

            var prompt_style_buf: [64]u8 = undefined;
            var prompt_renderer = render_mod.Renderer.init(
                self.allocator,
                term_mod.size().cols,
                self.color_depth.enabled(),
                try tui.roleCode(&prompt_style_buf, self.color_depth, .section),
            );
            defer prompt_renderer.deinit();
            var frame_arena = std.heap.ArenaAllocator.init(self.allocator);
            defer frame_arena.deinit();

            var prompt_active = false;
            var decoder = keys_mod.Decoder{};
            var events: keys_mod.Decoder.List = .empty;
            defer events.deinit(self.allocator);
            var read_buf: [512]u8 = undefined;

            while (true) {
                // Deliberately no pollSessionJobs: the paused fiber may mutate the
                // heap via `session.eval`, so we draw from the (possibly stale)
                // existing indexes rather than racing a background snapshot.
                _ = frame_arena.reset(.retain_capacity);
                var prompt_view = try Explorer.Ops.source_view.sessionPromptView(self, &editor, frame_arena.allocator());
                const size = term_mod.size();
                prompt_renderer.setWidth(size.cols);
                prompt_view.max_rows = size.rows -| 2;
                const prompt_rows = if (prompt_active) try prompt_renderer.measure(prompt_view) else 0;
                try Explorer.Ops.preview.drawSession(self, frame_arena.allocator(), w, &prompt_renderer, prompt_view, prompt_rows, &capture, prompt_active);
                try w.flush();

                const flash_drawn = self.return_flash;
                const result = term_mod.readInput(&read_buf, if (decoder.wantsMore()) 40 else if (flash_drawn) 180 else -1);
                if (flash_drawn) {
                    self.return_flash = false;
                    try Explorer.Ops.pages.refreshPage(self, Explorer.Ops.view_state.currentKind(self));
                }
                events.clearRetainingCapacity();
                switch (result) {
                    .timeout => try decoder.idleFlush(self.allocator, &events),
                    .winch => {
                        prompt_renderer.invalidate();
                        continue;
                    },
                    .eof => return .close,
                    .data => |n| for (read_buf[0..n]) |b| try decoder.feed(self.allocator, b, &events),
                }

                for (events.items) |key| {
                    const outcome = if (prompt_active)
                        try Explorer.Ops.debug_view.debugPromptKey(self, session, &editor, &capture, &prompt_active, w, &prompt_renderer, key)
                    else
                        try Explorer.Ops.debug_view.debugKey(self, session, &editor, &prompt_active, key);
                    switch (outcome) {
                        .running => {},
                        .resume_keep => return .keep,
                        .resume_close => return .close,
                        .abort => return debugger.AbortError,
                    }
                }
            }
        }

        pub fn debugKey(self: *Explorer, session: *DebugSession, editor: *editor_mod.Editor, prompt_active: *bool, key: keys_mod.Key) !DebugOutcome {
            self.status_msg = "";
            switch (key.code) {
                .escape => return if (try Explorer.Ops.controller.escapeLayer(self)) .running else .resume_close,
                .cp => |cp| {
                    if (key.ctrl) {
                        if (cp == 'd') return .abort;
                        _ = try Explorer.Ops.controller.handleKey(self, key);
                        return .running;
                    }
                    switch (cp) {
                        's' => return Explorer.Ops.debug_view.debugStep(self, session, .into),
                        'n' => return Explorer.Ops.debug_view.debugStep(self, session, .over),
                        'f' => return Explorer.Ops.debug_view.debugStep(self, session, .out),
                        'c' => return .resume_close,
                        'q' => return .abort,
                        ':' => {
                            prompt_active.* = true;
                            _ = try editor.handleKey(key);
                            return .running;
                        },
                        'i' => {
                            prompt_active.* = true;
                            return .running;
                        },
                        else => {
                            _ = try Explorer.Ops.controller.handleKey(self, key);
                            return .running;
                        },
                    }
                },
                else => {
                    _ = try Explorer.Ops.controller.handleKey(self, key);
                    return .running;
                },
            }
        }

        pub fn debugStep(self: *Explorer, session: *DebugSession, kind: DebugSession.StepKind) DebugOutcome {
            session.step(kind) catch |err| {
                self.status_msg = std.fmt.bufPrint(&self.status_buf, "step failed: {s}", .{@errorName(err)}) catch "step failed";
                return .running;
            };
            self.pending_step_focus = self.navigation.focus;
            return .resume_keep;
        }

        pub fn debugPromptKey(
            self: *Explorer,
            session: *DebugSession,
            editor: *editor_mod.Editor,
            capture: *transcript_mod.Capture,
            prompt_active: *bool,
            w: *std.Io.Writer,
            prompt_renderer: *render_mod.Renderer,
            key: keys_mod.Key,
        ) !DebugOutcome {
            if (key.code == .escape and editor.text().len == 0) {
                prompt_active.* = false;
                return .running;
            }
            switch (try editor.handleKey(key)) {
                .none => {},
                .bell => try w.writeAll("\x07"),
                .submit => {
                    const input = try editor.takeText();
                    defer self.allocator.free(input);
                    prompt_active.* = false;
                    return Explorer.Ops.debug_view.debugExecute(self, session, capture, std.mem.trim(u8, input, " \t\r\n"));
                },
                .eof => return .abort,
                .cancel => {
                    editor.reset();
                    prompt_active.* = false;
                },
                // The alternate screen and raw mode are owned by the caller
                // (`VmDebugger` or the borrowed explorer); a nested pause only draws.
                .clear_screen => try w.writeAll("\x1b[H\x1b[2J"),
                .suspend_process => prompt_renderer.invalidate(),
            }
            return .running;
        }

        pub fn debugExecute(self: *Explorer, session: *DebugSession, capture: *transcript_mod.Capture, input: []const u8) !DebugOutcome {
            if (input.len == 0) return .running;
            switch (command_mod.parse(input)) {
                .none => {},
                .proceed => return .resume_close,
                .abort => return .abort,
                .step => |kind| return Explorer.Ops.debug_view.debugStep(self, session, switch (kind) {
                    .over => .over,
                    .into => .into,
                    .out => .out,
                }),
                .help => try Explorer.Ops.debug_view.debugSetCapture(self, capture, vm_helpers.debug_help_text),
                .backtrace, .locals => try Explorer.Ops.debug_view.debugSetCapture(self, capture, "The tree shows the paused stack; select a frame to inspect its source, locals, and code."),
                .value => try Explorer.Ops.debug_view.debugRenderValue(self, session, capture, session.value),
                .eval => |source| {
                    const scope = session.scopeAttrs() catch session.bindValueScope("it") catch null;
                    const value = session.eval(source, scope) catch |err| {
                        try Explorer.Ops.debug_view.debugSetCaptureFmt(self, capture, "error: {s}", .{@errorName(err)});
                        return .running;
                    };
                    // Debugger evaluation may allocate or resolve objects without
                    // leaving the pause, so discard its old read-only indexes.
                    self.clearHeapSnapshots();
                    self.clearReferenceGraph();
                    self.refreshPausedTreeSnapshots();
                    try Explorer.Ops.tree_projection.rebuildTreeForCurrent(self);
                    try Explorer.Ops.debug_view.debugRenderValue(self, session, capture, value);
                    try Explorer.Ops.pages.refreshPage(self, Explorer.Ops.view_state.currentKind(self));
                },
                .breakpoint => |arg| try Explorer.Ops.debug_view.debugAddBreakpoint(self, session, capture, arg),
                .breakpoints => try Explorer.Ops.debug_view.debugListBreakpoints(self, session, capture),
                .delete => |arg| try Explorer.Ops.debug_view.debugDeleteBreakpoint(self, session, capture, arg),
            }
            try Explorer.Ops.source_view.rebuildTranscriptLines(self, capture.written());
            return .running;
        }

        pub fn debugSetCapture(self: *Explorer, capture: *transcript_mod.Capture, text: []const u8) !void {
            _ = self;
            try capture.writer.writeAll(text);
            if (text.len == 0 or text[text.len - 1] != '\n') try capture.writer.writeByte('\n');
        }

        pub fn debugSetCaptureFmt(self: *Explorer, capture: *transcript_mod.Capture, comptime fmt: []const u8, args: anytype) !void {
            _ = self;
            try capture.writer.print(fmt, args);
            try capture.writer.writeByte('\n');
        }

        pub fn debugRenderValue(self: *Explorer, session: *DebugSession, capture: *transcript_mod.Capture, value: runtime.Value) !void {
            _ = self;
            command_mod.writeValue(session, &capture.writer, value) catch |err| {
                try capture.writer.print("error: {s}", .{@errorName(err)});
            };
            try capture.writer.writeByte('\n');
        }

        pub fn debugAddBreakpoint(self: *Explorer, session: *DebugSession, capture: *transcript_mod.Capture, arg: []const u8) !void {
            _ = self;
            try command_mod.addBreakpoint(session, &capture.writer, arg);
            try capture.writer.writeByte('\n');
        }

        pub fn debugListBreakpoints(self: *Explorer, session: *DebugSession, capture: *transcript_mod.Capture) !void {
            _ = self;
            try command_mod.listBreakpoints(session, &capture.writer, "");
            try capture.writer.writeByte('\n');
        }

        pub fn debugDeleteBreakpoint(self: *Explorer, session: *DebugSession, capture: *transcript_mod.Capture, arg: []const u8) !void {
            _ = self;
            try command_mod.deleteBreakpoint(session, &capture.writer, arg);
            try capture.writer.writeByte('\n');
        }

        /// Tear down the debug view on resume: null the session, restore the outer
        /// explorer's navigation exactly as the pause found it (essential in the
        /// borrowed case, where this loop mutated the same `Tui`).
        pub fn exitDebugView(self: *Explorer) void {
            self.debug_session = null;
            if (self.navigation.back.items.len > self.debug_nav_mark)
                self.navigation.back.shrinkRetainingCapacity(self.debug_nav_mark);
            self.navigation.forward.clearRetainingCapacity();
            if (self.navigation.back.items.len == 0) return;
            const visit = self.navigation.back.items[self.navigation.back.items.len - 1];
            Explorer.Ops.tree_projection.rebuildTreeForCurrent(self) catch {};
            Explorer.Ops.pages.refreshPage(self, visit.kind) catch {};
            self.navigation.scroll = visit.scroll;
            self.navigation.tree_selection = visit.tree_selection;
            self.navigation.detail_selection = visit.detail_selection;
            self.navigation.x_scroll = visit.x_scroll;
        }
    };
}
