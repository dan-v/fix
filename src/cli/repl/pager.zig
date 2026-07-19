//! The VM explorer TUI: a qualified-name tree beside the selected chunk view.
//!
//! Interactive use is deliberately a TUI rather than a pager: the name tree is
//! persistent navigation, the chunk detail is a separately scrollable pane,
//! and the ordinary REPL prompt/transcript occupy the same surface. The plain
//! (`--bare`/non-tty) fallback exposes the same model through bounded commands.

const std = @import("std");
const engine = @import("expr");
const runtime = @import("runtime");
const term_mod = @import("term.zig");
const keys_mod = @import("keys.zig");
const width_mod = @import("width.zig");
const editor_mod = @import("editor.zig");
const render_mod = @import("render.zig");
const transcript_mod = @import("transcript.zig");
const base = @import("base");
const tui = base.tui;
const ColorDepth = base.terminal_color.Depth;
const sync = @import("base").sync;

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

const Section = enum(u2) { code, tables, source, references };
const Category = enum(u1) { bytecode, heap };
const HeapView = enum { overview, objects, values, attrs, attr_positions };

const RowAction = union(enum) {
    none,
    section: Section,
    chunk: ChunkId,
};

/// One rendered inspector document (or the help screen). Actions are parallel
/// to lines so section headers and references remain useful even when the
/// chunk itself is shorter than the viewport.
const Page = struct {
    title: []u8,
    lines: [][]u8,
    actions: []RowAction,
    source_lines: []const []const u8 = &.{},
};

const PageBuilder = struct {
    arena: std.mem.Allocator,
    lines: std.ArrayListUnmanaged([]u8) = .empty,
    actions: std.ArrayListUnmanaged(RowAction) = .empty,

    fn line(self: *PageBuilder, line_text: []const u8, action: RowAction) !void {
        try self.lines.append(self.arena, try self.arena.dupe(u8, line_text));
        try self.actions.append(self.arena, action);
    }

    fn text(self: *PageBuilder, contents: []const u8) !void {
        var it = std.mem.splitScalar(u8, contents, '\n');
        while (it.next()) |line_text| try self.line(line_text, .none);
        if (self.lines.items.len > 0 and self.lines.items[self.lines.items.len - 1].len == 0) {
            _ = self.lines.pop();
            _ = self.actions.pop();
        }
    }
};

/// A stack entry remembers where you were on the page you left.
const Visit = struct {
    kind: Kind,
    scroll: usize = 0,
    tree_selection: usize = 0,
    detail_selection: usize = 0,
    x_scroll: usize = 0,

    const Kind = union(enum) {
        chunk: ChunkId,
        heap: HeapView,
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
    var explorer = Tui{
        .allocator = allocator,
        .io = io,
        .ev = ev,
        .color_depth = color_depth,
        .name_index = &name_index,
        .arena = std.heap.ArenaAllocator.init(allocator),
    };
    defer explorer.deinit();
    try explorer.run(start);
}

/// The REPL owns evaluation semantics; the screen owns input/output placement.
/// This narrow interface is what lets the same prompt drive both the plain
/// loop and the richer terminal surface without teaching the explorer about
/// bindings, loading, GC, or value printing.
pub const SessionHost = struct {
    ctx: *anyopaque,
    executeFn: *const fn (ctx: *anyopaque, input: []const u8, output: *std.Io.Writer) anyerror!void,
    focusFn: *const fn (ctx: *anyopaque) ?ChunkId,
    sourceFn: *const fn (ctx: *anyopaque, chunk_id: ChunkId) ?[]const u8,
    quitFn: *const fn (ctx: *anyopaque) bool,
    takeHeapRequestFn: *const fn (ctx: *anyopaque) bool,
    start_heap: bool = false,

    fn execute(self: SessionHost, input: []const u8, output: *std.Io.Writer) !void {
        try self.executeFn(self.ctx, input, output);
    }

    fn focusedChunk(self: SessionHost) ?ChunkId {
        return self.focusFn(self.ctx);
    }

    fn directSource(self: SessionHost, chunk_id: ChunkId) ?[]const u8 {
        return self.sourceFn(self.ctx, chunk_id);
    }

    fn quitting(self: SessionHost) bool {
        return self.quitFn(self.ctx);
    }

    fn takeHeapRequest(self: SessionHost) bool {
        return self.takeHeapRequestFn(self.ctx);
    }
};

/// Run the integrated prompt/transcript/explorer surface. Evaluation remains
/// synchronous (the prompt cannot accept a second expression while the VM is
/// using its scope), while rebuilding the potentially million-node name
/// projection happens on a background thread after each registry growth.
pub fn runSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    ev: *Evaluator,
    color_depth: ColorDepth,
    editor: *editor_mod.Editor,
    transcript: *transcript_mod.Capture,
    host: SessionHost,
) !void {
    var name_index = try bytecode.inspect.NameIndex.build(allocator, ev.chunkRegistry());
    defer name_index.deinit();
    var explorer = Tui{
        .allocator = allocator,
        .io = io,
        .ev = ev,
        .color_depth = color_depth,
        .name_index = &name_index,
        .session_host = host,
        .arena = std.heap.ArenaAllocator.init(allocator),
    };
    defer explorer.deinit();
    try explorer.runSession(editor, transcript, host);
}

const IndexJob = struct {
    registry: *const bytecode.ChunkRegistry,
    thread: ?std.Thread = null,
    mutex: sync.BlockingMutex = .{},
    ready: ?bytecode.inspect.NameIndex = null,
    running: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),

    fn start(self: *IndexJob) !void {
        if (self.thread != null) return;
        self.failed.store(false, .release);
        self.running.store(true, .release);
        self.thread = std.Thread.spawn(.{}, build, .{self}) catch |err| {
            self.running.store(false, .release);
            return err;
        };
    }

    fn build(self: *IndexJob) void {
        const result = bytecode.inspect.NameIndex.build(std.heap.smp_allocator, self.registry) catch {
            self.failed.store(true, .release);
            self.running.store(false, .release);
            return;
        };
        self.mutex.lock();
        self.ready = result;
        self.mutex.unlock();
        self.running.store(false, .release);
    }

    fn poll(self: *IndexJob, current: *bytecode.inspect.NameIndex) bool {
        if (self.thread == null or self.running.load(.acquire)) return false;
        return self.finish(current);
    }

    fn finish(self: *IndexJob, current: *bytecode.inspect.NameIndex) bool {
        const thread = self.thread orelse return false;
        thread.join();
        self.thread = null;
        self.mutex.lock();
        const next = self.ready;
        self.ready = null;
        self.mutex.unlock();
        if (next) |index| {
            current.deinit();
            current.* = index;
            return true;
        }
        return false;
    }

    fn deinit(self: *IndexJob) void {
        if (self.thread) |thread| thread.join();
        self.thread = null;
        self.mutex.lock();
        if (self.ready) |*index| index.deinit();
        self.ready = null;
        self.mutex.unlock();
    }
};

const HeapJob = struct {
    ev: *Evaluator,
    thread: ?std.Thread = null,
    mutex: sync.BlockingMutex = .{},
    ready: ?runtime.ObjectHeap.Stats = null,
    running: std.atomic.Value(bool) = .init(false),

    fn start(self: *HeapJob) !void {
        if (self.thread != null) return;
        self.running.store(true, .release);
        self.thread = std.Thread.spawn(.{}, build, .{self}) catch |err| {
            self.running.store(false, .release);
            return err;
        };
    }

    fn build(self: *HeapJob) void {
        const result = self.ev.heapStats();
        self.mutex.lock();
        self.ready = result;
        self.mutex.unlock();
        self.running.store(false, .release);
    }

    fn poll(self: *HeapJob, target: *?runtime.ObjectHeap.Stats) bool {
        if (self.thread == null or self.running.load(.acquire)) return false;
        self.finish(target);
        return true;
    }

    fn finish(self: *HeapJob, target: *?runtime.ObjectHeap.Stats) void {
        if (self.thread) |thread| thread.join();
        self.thread = null;
        self.mutex.lock();
        if (self.ready) |stats| target.* = stats;
        self.ready = null;
        self.mutex.unlock();
        self.running.store(false, .release);
    }

    fn deinit(self: *HeapJob) void {
        var discard: ?runtime.ObjectHeap.Stats = null;
        self.finish(&discard);
    }
};

const Tui = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    ev: *Evaluator,
    color_depth: ColorDepth,
    name_index: *bytecode.inspect.NameIndex,
    session_host: ?SessionHost = null,
    /// Only the current rendered page lives here. Persistent REPL sessions
    /// reset it on every view/focus change instead of accumulating every
    /// disassembly ever visited.
    arena: std.heap.ArenaAllocator,
    viewport_cols: usize = 80,
    viewport_rows: usize = 22,

    stack: std.ArrayListUnmanaged(Visit) = .empty,
    forward: std.ArrayListUnmanaged(Visit) = .empty,
    page: Page = undefined,
    scroll: usize = 0,
    search: std.ArrayListUnmanaged(u8) = .empty,
    expanded: std.AutoHashMapUnmanaged(bytecode.name_tree.NameId, void) = .empty,
    expanded_ranges: std.AutoHashMapUnmanaged(u128, void) = .empty,
    focus_path: std.AutoHashMapUnmanaged(bytecode.name_tree.NameId, void) = .empty,
    tree_rows: std.ArrayListUnmanaged(TreeRow) = .empty,
    transcript_lines: std.ArrayListUnmanaged(LineRange) = .empty,
    status_msg: []const u8 = "",
    indexing: bool = false,
    focus: Focus = .disassembly,
    tree_selection: usize = 0,
    detail_selection: usize = 0,
    x_scroll: usize = 0,
    sections: [4]bool = .{ true, false, true, false },
    category_expanded: [2]bool = .{ false, false },
    heap_stats: ?runtime.ObjectHeap.Stats = null,

    const Focus = enum { chunks, disassembly };
    const TreeRow = union(enum) {
        category: struct { kind: Category, depth: u16 },
        name: struct { id: bytecode.name_tree.NameId, depth: u16 },
        chunk: struct { id: ChunkId, depth: u16 },
        range: Range,
        heap: struct { view: HeapView, depth: u16 },
    };
    const RangeKind = enum(u1) { names, chunks };
    const Range = struct {
        kind: RangeKind,
        parent: bytecode.name_tree.NameId,
        start: u32,
        len: u32,
        depth: u16,

        fn key(self: Range) u128 {
            return (@as(u128, @intFromEnum(self.kind)) << 96) |
                (@as(u128, self.parent) << 64) |
                (@as(u128, self.start) << 32) |
                @as(u128, self.len);
        }
    };
    const LineRange = struct { start: usize, end: usize };

    const range_leaf = 128;
    const range_branch = 4096;

    fn deinit(self: *Tui) void {
        self.stack.deinit(self.allocator);
        self.forward.deinit(self.allocator);
        self.search.deinit(self.allocator);
        self.expanded.deinit(self.allocator);
        self.expanded_ranges.deinit(self.allocator);
        self.focus_path.deinit(self.allocator);
        self.tree_rows.deinit(self.allocator);
        self.transcript_lines.deinit(self.allocator);
        self.arena.deinit();
    }

    fn run(self: *Tui, start: ChunkId) !void {
        var raw = term_mod.RawMode.enable() catch return;
        defer raw.disable();

        var out_buf: [32 * 1024]u8 = undefined;
        var out = std.Io.File.stdout().writerStreaming(self.io, &out_buf);
        const w = &out.interface;

        var screen = try tui.Screen.enter(w, .{});
        defer {
            screen.leave() catch {};
            w.flush() catch {};
        }

        const initial_size = term_mod.size();
        self.viewport_cols = initial_size.cols;
        self.viewport_rows = initial_size.rows -| 2;
        try self.stack.append(self.allocator, .{ .kind = .{ .chunk = start } });
        try self.expandFocusedPath(start);
        try self.rebuildTree(start);
        try self.refreshPage(.{ .chunk = start });

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
                    const resized = term_mod.size();
                    self.viewport_cols = resized.cols;
                    self.viewport_rows = resized.rows -| 2;
                    try self.refreshPage(self.currentKind());
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

    fn runSession(self: *Tui, editor: *editor_mod.Editor, capture: *transcript_mod.Capture, host: SessionHost) !void {
        var raw = term_mod.RawMode.enable() catch return error.NotATerminal;
        defer raw.disable();

        var out_buf: [64 * 1024]u8 = undefined;
        var out = std.Io.File.stdout().writerStreaming(self.io, &out_buf);
        const w = &out.interface;
        var screen = try tui.Screen.enter(w, .{ .bracketed_paste = true });
        defer {
            screen.leave() catch {};
            w.flush() catch {};
        }

        try self.rebuildTranscriptLines(capture.written());

        const first_focus = host.focusedChunk();
        if (host.start_heap) self.category_expanded[@intFromEnum(Category.heap)] = true;
        const initial_kind: Visit.Kind = if (host.start_heap)
            .{ .heap = .overview }
        else if (first_focus) |id|
            .{ .chunk = id }
        else
            .help;
        try self.stack.append(self.allocator, .{ .kind = initial_kind });
        if (first_focus) |id| {
            try self.expandFocusedPath(id);
            try self.rebuildTree(id);
        } else {
            try self.expanded.put(self.allocator, bytecode.root_name_id, {});
            try self.rebuildTree(std.math.maxInt(ChunkId));
        }
        if (host.start_heap) {
            for (self.tree_rows.items, 0..) |row, i| switch (row) {
                .heap => |entry| if (entry.view == .overview) {
                    self.tree_selection = i;
                    break;
                },
                else => {},
            };
        }
        try self.refreshPage(initial_kind);

        var index_job = IndexJob{ .registry = self.ev.chunkRegistry() };
        defer index_job.deinit();
        var heap_job = HeapJob{ .ev = self.ev };
        defer heap_job.deinit();
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
            if (index_job.poll(self.name_index)) {
                self.indexing = false;
                if (host.focusedChunk()) |id| {
                    try self.expandFocusedPath(id);
                    try self.rebuildTree(id);
                }
            }
            const registry = self.ev.chunkRegistry();
            const stale = self.name_index.registry_count != registry.count() or self.name_index.name_count != registry.nameCount();
            if (stale and index_job.thread == null) {
                index_job.start() catch {
                    self.status_msg = "(name index failed)";
                };
            }
            self.indexing = stale or index_job.running.load(.acquire);
            if (heap_job.poll(&self.heap_stats)) {
                if (self.currentHeap() != null) try self.refreshPage(self.currentKind());
            }
            if (self.currentHeap() != null and self.heap_stats == null and heap_job.thread == null) {
                heap_job.start() catch {
                    self.status_msg = "(heap census failed)";
                };
            }

            _ = frame_arena.reset(.retain_capacity);
            var prompt_view = try self.sessionPromptView(editor, frame_arena.allocator());
            const size = term_mod.size();
            prompt_renderer.setWidth(size.cols);
            prompt_view.max_rows = size.rows -| 2;
            const prompt_rows = try prompt_renderer.measure(prompt_view);
            try self.drawSession(w, &prompt_renderer, prompt_view, prompt_rows, capture, prompt_active);
            try w.flush();

            // Keep polling while a thread handle exists, even if the worker
            // finished between drawing and this check; otherwise a very fast
            // build could leave us in an infinite blocking read before its
            // completed generation is adopted.
            const timeout: i32 = if (decoder.wantsMore()) 40 else if (index_job.thread != null or heap_job.thread != null) 50 else -1;
            const result = term_mod.readInput(&read_buf, timeout);
            events.clearRetainingCapacity();
            switch (result) {
                .timeout => try decoder.idleFlush(self.allocator, &events),
                .winch => {
                    prompt_renderer.invalidate();
                    continue;
                },
                .eof => return,
                .data => |n| for (read_buf[0..n]) |b| try decoder.feed(self.allocator, b, &events),
            }

            for (events.items) |key| {
                if (prompt_active) {
                    if (key.code == .escape and editor.text().len == 0) {
                        prompt_active = false;
                        continue;
                    }
                    switch (try editor.handleKey(key)) {
                        .none => {},
                        .bell => try w.writeAll("\x07"),
                        .submit => {
                            const input = try editor.takeText();
                            defer self.allocator.free(input);
                            const trimmed = std.mem.trim(u8, input, " \t\r\n");
                            if (trimmed.len == 0) continue;
                            try capture.writer.writeAll("fix> ");
                            try capture.writer.writeAll(trimmed);
                            try capture.writer.writeByte('\n');
                            _ = index_job.finish(self.name_index);
                            heap_job.finish(&self.heap_stats);
                            try host.execute(trimmed, &capture.writer);
                            self.heap_stats = null;
                            if (capture.written().len > 0 and capture.written()[capture.written().len - 1] != '\n')
                                try capture.writer.writeByte('\n');
                            try self.rebuildTranscriptLines(capture.written());
                            if (host.takeHeapRequest()) {
                                try self.open(.{ .heap = .overview });
                            } else if (host.focusedChunk()) |id| {
                                if (self.currentChunk() != id) {
                                    try self.open(.{ .chunk = id });
                                } else {
                                    try self.refreshPage(.{ .chunk = id });
                                }
                            }
                            if (host.quitting()) return;
                        },
                        .eof => return,
                        .cancel => {
                            editor.reset();
                            try capture.writer.writeAll("^C\n");
                            try self.rebuildTranscriptLines(capture.written());
                        },
                        .clear_screen => try screen.clear(),
                        .suspend_process => {
                            try w.flush();
                            raw.suspendProcess();
                            prompt_renderer.invalidate();
                        },
                    }
                    continue;
                }

                const leave_explorer = switch (key.code) {
                    .escape => true,
                    .cp => |cp| cp == 'q',
                    else => false,
                };
                if (leave_explorer) {
                    return;
                }
                const enter_command = switch (key.code) {
                    .cp => |cp| cp == ':',
                    else => false,
                };
                if (enter_command) {
                    prompt_active = true;
                    _ = try editor.handleKey(key);
                    continue;
                }
                const enter_expression = switch (key.code) {
                    .cp => |cp| cp == 'i',
                    else => false,
                };
                if (enter_expression) {
                    prompt_active = true;
                    continue;
                }
                if (!try self.handleKey(key)) {
                    prompt_active = true;
                    _ = try editor.handleKey(key);
                }
            }
        }
    }

    // -- page construction ---------------------------------------------------

    fn refreshPage(self: *Tui, kind: Visit.Kind) !void {
        _ = self.arena.reset(.retain_capacity);
        self.page = try self.buildPage(kind);
        self.detail_selection = @min(self.detail_selection, self.page.lines.len -| 1);
        if (!self.rowActionable(self.detail_selection)) self.detail_selection = self.firstActionableRow() orelse 0;
        self.ensureDetailVisible();
    }

    fn buildPage(self: *Tui, kind: Visit.Kind) !Page {
        const arena = self.arena.allocator();
        switch (kind) {
            .chunk => |id| {
                const chunk = self.ev.getChunk(id) orelse {
                    return .{
                        .title = try std.fmt.allocPrint(arena, "chunk[0x{x}] (not found)", .{id}),
                        .lines = &.{},
                        .actions = &.{},
                    };
                };
                var page: PageBuilder = .{ .arena = arena };
                const source_lines = if (self.sections[@intFromEnum(Section.source)])
                    try self.sourceDocument(id, chunk)
                else
                    &.{};
                for (std.meta.tags(Section)) |section| {
                    try page.line(try self.sectionHeader(section), .{ .section = section });
                    if (!self.sections[@intFromEnum(section)]) continue;

                    switch (section) {
                        .code, .tables => {
                            var text: std.Io.Writer.Allocating = .init(arena);
                            const symbols: disasm.Symbols = .{ .intern = self.ev.internTable(), .registry = self.ev.chunkRegistry() };
                            var options = disasm_options;
                            options.color_depth = self.color_depth;
                            options.show_constants = section == .tables;
                            options.show_code = section == .code;
                            options.line_width = @intCast(@min(self.layout().main_width, std.math.maxInt(u16)));
                            try disasm.writeChunk(arena, &text.writer, id, chunk, symbols, options);
                            try page.text(text.written());
                        },
                        .source => {
                            if (self.layout().source_split) {
                                try page.line("  source is shown alongside the inspector", .none);
                            } else {
                                for (source_lines) |source_line| try page.line(source_line, .none);
                            }
                        },
                        .references => try self.appendRefs(&page, id, chunk),
                    }
                }
                return .{
                    .title = try std.fmt.allocPrint(arena, "chunk[0x{x}]", .{id}),
                    .lines = page.lines.items,
                    .actions = page.actions.items,
                    .source_lines = if (self.layout().source_split) source_lines else &.{},
                };
            },
            .heap => |view| return self.buildHeapPage(view),
            .help => {
                const help_text =
                    \\The VM explorer
                    \\
                    \\  Tab             switch tree/detail focus
                    \\  j/k, arrows     move between interactive rows
                    \\  Enter, →        expand a tree/group/section or open a reference
                    \\  ←               collapse a tree/group/section
                    \\  c/t/s/r         toggle code/tables/source/references
                    \\  d/u, PgDn/PgUp  scroll the detail document
                    \\  b / f           back / forward through visited chunks
                    \\  /               search; n/N next/previous match
                    \\  i / :           enter an expression / command at the REPL prompt
                    \\  q, Esc          return to the inline REPL
                    \\
                    \\The tree starts collapsed except for the focused chunk's
                    \\ancestor path. Large child/chunk sets are exposed through
                    \\bounded range nodes instead of being truncated.
                ;
                var page: PageBuilder = .{ .arena = arena };
                try page.text(help_text);
                return .{
                    .title = try arena.dupe(u8, "help"),
                    .lines = page.lines.items,
                    .actions = page.actions.items,
                };
            },
        }
    }

    fn buildHeapPage(self: *Tui, view: HeapView) !Page {
        const arena = self.arena.allocator();
        const counts = self.ev.heapCounts();
        var page: PageBuilder = .{ .arena = arena };
        try page.line(try std.fmt.allocPrint(arena, "HEAP · {d} object slots", .{counts.objects}), .none);
        try page.line(try std.fmt.allocPrint(arena, "objects        {d:>12}", .{counts.objects}), .none);
        try page.line(try std.fmt.allocPrint(arena, "values         {d:>12}", .{counts.values}), .none);
        try page.line(try std.fmt.allocPrint(arena, "attrs          {d:>12}", .{counts.attrs}), .none);
        try page.line(try std.fmt.allocPrint(arena, "attr positions {d:>12}", .{counts.attr_positions}), .none);
        try page.line("", .none);

        const stats = self.heap_stats orelse {
            try page.line("scanning the detailed heap census asynchronously…", .none);
            return .{
                .title = try std.fmt.allocPrint(arena, "heap · {s}", .{@tagName(view)}),
                .lines = page.lines.items,
                .actions = page.actions.items,
            };
        };

        switch (view) {
            .overview, .objects => {
                try page.line("OBJECT VARIANTS", .none);
                for (stats.variant_counts, 0..) |count, i| {
                    try page.line(try std.fmt.allocPrint(arena, "{s:<20} {d:>12}", .{ runtime.ObjectHeap.Stats.variantName(i), count }), .none);
                }
                try page.line("", .none);
                try page.line("THUNK STATES", .none);
                for (stats.thunk_states, 0..) |count, i| {
                    try page.line(try std.fmt.allocPrint(arena, "{s:<20} {d:>12}", .{ runtime.ObjectHeap.Stats.thunkStateName(i), count }), .none);
                }
                try page.line(try std.fmt.allocPrint(arena, "resolved demanded     {d:>12}", .{stats.resolved_demanded}), .none);
                try page.line(try std.fmt.allocPrint(arena, "resolved undemanded   {d:>12}", .{stats.resolved_undemanded}), .none);
            },
            .values, .attrs => {
                try page.line("INLINE INTEGER MAGNITUDES · values + attrs", .none);
                for (stats.int_buckets, 0..) |count, i| {
                    try page.line(try std.fmt.allocPrint(arena, "{s:<20} {d:>12}", .{ runtime.ObjectHeap.Stats.intBucketLabel(i), count }), .none);
                }
                try page.line(try std.fmt.allocPrint(arena, "i48 overflows         {d:>12}", .{stats.intOverflowsI48()}), .none);
            },
            .attr_positions => {
                try page.line("Source-position records attached to heap attrs.", .none);
                try page.line("Open TABLES on a chunk to inspect its compile-time attr positions.", .none);
            },
        }
        return .{
            .title = try std.fmt.allocPrint(arena, "heap · {s}", .{@tagName(view)}),
            .lines = page.lines.items,
            .actions = page.actions.items,
        };
    }

    fn sectionHeader(self: *Tui, section: Section) ![]u8 {
        const arena = self.arena.allocator();
        const is_open = self.sections[@intFromEnum(section)];
        const label = switch (section) {
            .code => "BYTECODE",
            .tables => "TABLES",
            .source => "SOURCE",
            .references => "REFERENCES",
        };
        return std.fmt.allocPrint(arena, "{s} {s}", .{ if (is_open) "▾" else "▸", label });
    }

    fn appendRefs(self: *Tui, page: *PageBuilder, id: ChunkId, chunk: *const bytecode.Chunk) !void {
        var refs: std.ArrayListUnmanaged(ChunkId) = .empty;
        defer refs.deinit(self.allocator);
        try bytecode.inspect.collectRefs(self.allocator, chunk, &refs);
        try page.line(try std.fmt.allocPrint(page.arena, "outgoing ({d})", .{refs.items.len}), .none);
        for (refs.items) |target| try self.appendChunkLabel(page, "  →", target);

        var incoming: usize = 0;
        const total = self.ev.chunkRegistry().count();
        var candidate: ChunkId = 0;
        while (candidate < total) : (candidate += 1) {
            const source = self.ev.getChunk(candidate) orelse continue;
            refs.clearRetainingCapacity();
            bytecode.inspect.collectRefs(self.allocator, source, &refs) catch continue;
            if (std.mem.indexOfScalar(ChunkId, refs.items, id) == null) continue;
            if (incoming == 0) try page.line("incoming", .none);
            try self.appendChunkLabel(page, "  ←", candidate);
            incoming += 1;
        }
        if (incoming == 0) try page.line("incoming (0)", .none);
    }

    fn appendChunkLabel(self: *Tui, page: *PageBuilder, marker: []const u8, id: ChunkId) !void {
        var text: std.Io.Writer.Allocating = .init(page.arena);
        try text.writer.print("{s} #{d}", .{ marker, id });
        if (self.ev.chunkRegistry().hasQualifiedName(id)) {
            try text.writer.writeByte(' ');
            try self.ev.chunkRegistry().writeQualifiedName(&text.writer, id, self.ev.internTable());
        }
        try page.line(text.written(), .{ .chunk = id });
    }

    fn sessionPromptView(self: *Tui, editor: *editor_mod.Editor, arena: std.mem.Allocator) !render_mod.View {
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
    fn rebuildTranscriptLines(self: *Tui, text: []const u8) !void {
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

    fn sourceDocument(self: *Tui, id: ChunkId, chunk: *const bytecode.Chunk) ![][]u8 {
        const arena = self.arena.allocator();
        const span = chunk.body_span orelse if (chunk.source_map.len > 0) chunk.source_map[0].span else {
            var missing: PageBuilder = .{ .arena = arena };
            try missing.line("(no source information)", .none);
            return missing.lines.items;
        };

        const label, const source = if (span.file) |file| blk: {
            const path = self.ev.internTable().get(file);
            break :blk .{ path, self.ev.readSourceFile(path) catch null };
        } else blk: {
            const direct = if (self.session_host) |host| host.directSource(id) else null;
            break :blk .{ "<repl expression>", direct };
        };

        var document: PageBuilder = .{ .arena = arena };
        try document.line(try std.fmt.allocPrint(arena, "{s}:{d}:{d}", .{ label, span.line, span.column }), .none);
        const bytes = source orelse {
            try document.line("(source text is unavailable)", .none);
            return document.lines.items;
        };
        try self.appendSourceExcerpt(&document, bytes, span);
        return document.lines.items;
    }

    fn appendSourceExcerpt(_: *Tui, document: *PageBuilder, source: []const u8, span: bytecode.Chunk.SourceSpan) !void {
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
            try rendered.writer.print("{s} {d:>5} │ ", .{ if (active) "▶" else " ", line_number });
            try writeSanitizedSource(&rendered.writer, source[cursor..@min(line_end, cursor +| 4096)]);
            if (line_end > cursor +| 4096) try rendered.writer.writeAll(" …");
            try document.line(rendered.written(), .none);
            line_number += 1;
            if (newline >= end or newline == source.len) break;
            cursor = newline + 1;
        }
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
        source_split: bool,
        source_col: usize,
        source_width: usize,
    };

    fn layout(self: *const Tui) Layout {
        const cols = @max(@as(usize, 1), self.viewport_cols);
        const body_rows = self.viewport_rows;
        const split = cols >= 96;
        const sidebar_width = if (split) @min(@max(cols / 4, 26), 38) else 0;
        const source_split = split and cols >= 140 and self.currentChunk() != null and self.sections[@intFromEnum(Section.source)];
        const inspector_width = if (split) cols - sidebar_width - 1 else cols;
        const source_width = if (source_split) @min(@max(cols / 3, 38), 64) else 0;
        const main_width = inspector_width -| source_width -| @intFromBool(source_split);
        const main_col = if (split) sidebar_width + 2 else 1;
        return .{
            .cols = cols,
            .rows = body_rows + 2,
            .body_rows = body_rows,
            .split = split,
            .sidebar_width = sidebar_width,
            .main_col = main_col,
            .main_width = main_width,
            .source_split = source_split,
            .source_col = main_col + main_width + @intFromBool(source_split),
            .source_width = source_width,
        };
    }

    fn currentKind(self: *const Tui) Visit.Kind {
        return self.stack.items[self.stack.items.len - 1].kind;
    }

    fn currentChunk(self: *const Tui) ?ChunkId {
        return switch (self.currentKind()) {
            .chunk => |id| id,
            .heap, .help => null,
        };
    }

    fn currentHeap(self: *const Tui) ?HeapView {
        return switch (self.currentKind()) {
            .heap => |view| view,
            else => null,
        };
    }

    fn expandFocusedPath(self: *Tui, chunk_id: ChunkId) !void {
        self.category_expanded[@intFromEnum(Category.bytecode)] = true;
        self.focus_path.clearRetainingCapacity();
        try self.expanded.put(self.allocator, bytecode.root_name_id, {});
        try self.focus_path.put(self.allocator, bytecode.root_name_id, {});
        var name = self.ev.chunkRegistry().nameOf(chunk_id) orelse bytecode.root_name_id;
        while (name != bytecode.root_name_id) {
            try self.expanded.put(self.allocator, name, {});
            try self.focus_path.put(self.allocator, name, {});
            name = (self.name_index.node(name) orelse break).parent;
        }
    }

    fn rebuildTree(self: *Tui, focused_chunk: ChunkId) !void {
        self.tree_rows.clearRetainingCapacity();
        try self.tree_rows.append(self.allocator, .{ .category = .{ .kind = .heap, .depth = 0 } });
        if (self.category_expanded[@intFromEnum(Category.heap)]) {
            for (std.meta.tags(HeapView)) |view| {
                try self.tree_rows.append(self.allocator, .{ .heap = .{ .view = view, .depth = 1 } });
            }
        }
        try self.tree_rows.append(self.allocator, .{ .category = .{ .kind = .bytecode, .depth = 0 } });
        if (self.category_expanded[@intFromEnum(Category.bytecode)]) {
            try self.appendNameRows(bytecode.root_name_id, 1, focused_chunk);
        }
        self.tree_selection = 0;
        for (self.tree_rows.items, 0..) |row, i| switch (row) {
            .chunk => |entry| if (entry.id == focused_chunk) {
                self.tree_selection = i;
                break;
            },
            else => {},
        };
    }

    fn appendNameRows(self: *Tui, name: bytecode.name_tree.NameId, depth: u16, focused_chunk: ChunkId) std.mem.Allocator.Error!void {
        try self.tree_rows.append(self.allocator, .{ .name = .{ .id = name, .depth = depth } });
        if (!self.expanded.contains(name)) return;
        const next_depth = depth +| 1;
        const children = self.name_index.childrenOf(name);
        try self.appendNameRange(name, children, 0, @intCast(children.len), next_depth, focused_chunk);

        const chunks = self.name_index.chunksOf(name);
        try self.appendChunkRange(name, chunks, 0, @intCast(chunks.len), next_depth, focused_chunk);
    }

    fn appendNameRange(
        self: *Tui,
        parent: bytecode.name_tree.NameId,
        children: []const bytecode.name_tree.NameId,
        start: u32,
        len: u32,
        depth: u16,
        focused_chunk: ChunkId,
    ) std.mem.Allocator.Error!void {
        if (len == 0) return;
        if (len <= range_leaf) {
            for (children[start .. start + len]) |child| {
                if (self.name_index.statsOf(child).chunks == 0) continue;
                try self.appendNameRows(child, depth, focused_chunk);
            }
            return;
        }

        const span: u32 = if (len > range_branch) range_branch else range_leaf;
        var offset: u32 = 0;
        while (offset < len) : (offset += span) {
            const range: Range = .{
                .kind = .names,
                .parent = parent,
                .start = start + offset,
                .len = @min(span, len - offset),
                .depth = depth,
            };
            try self.tree_rows.append(self.allocator, .{ .range = range });
            var contains_focus = false;
            for (children[range.start .. range.start + range.len]) |child| {
                if (self.focus_path.contains(child)) {
                    contains_focus = true;
                    break;
                }
            }
            if (contains_focus or self.expanded_ranges.contains(range.key())) {
                try self.appendNameRange(parent, children, range.start, range.len, depth +| 1, focused_chunk);
            }
        }
    }

    fn appendChunkRange(
        self: *Tui,
        parent: bytecode.name_tree.NameId,
        chunks: []const ChunkId,
        start: u32,
        len: u32,
        depth: u16,
        focused_chunk: ChunkId,
    ) std.mem.Allocator.Error!void {
        if (len == 0) return;
        if (len <= range_leaf) {
            for (chunks[start .. start + len]) |id| {
                try self.tree_rows.append(self.allocator, .{ .chunk = .{ .id = id, .depth = depth } });
            }
            return;
        }

        const span: u32 = if (len > range_branch) range_branch else range_leaf;
        var offset: u32 = 0;
        while (offset < len) : (offset += span) {
            const range: Range = .{
                .kind = .chunks,
                .parent = parent,
                .start = start + offset,
                .len = @min(span, len - offset),
                .depth = depth,
            };
            try self.tree_rows.append(self.allocator, .{ .range = range });
            const slice = chunks[range.start .. range.start + range.len];
            if (std.mem.indexOfScalar(ChunkId, slice, focused_chunk) != null or self.expanded_ranges.contains(range.key())) {
                try self.appendChunkRange(parent, chunks, range.start, range.len, depth +| 1, focused_chunk);
            }
        }
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
            .category => |entry| {
                const index = @intFromEnum(entry.kind);
                self.category_expanded[index] = !self.category_expanded[index];
                const focused = self.currentChunk() orelse 0;
                try self.rebuildTree(focused);
                for (self.tree_rows.items, 0..) |row, i| switch (row) {
                    .category => |candidate| if (candidate.kind == entry.kind) {
                        self.tree_selection = i;
                        break;
                    },
                    else => {},
                };
            },
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
            .heap => |entry| try self.open(.{ .heap = entry.view }),
            .range => |range| {
                if (!self.expanded_ranges.remove(range.key())) try self.expanded_ranges.put(self.allocator, range.key(), {});
                const focused = self.currentChunk() orelse 0;
                try self.rebuildTree(focused);
                for (self.tree_rows.items, 0..) |row, i| switch (row) {
                    .range => |candidate| if (candidate.key() == range.key()) {
                        self.tree_selection = i;
                        break;
                    },
                    else => {},
                };
            },
        }
    }

    fn collapseTreeRow(self: *Tui) !void {
        if (self.tree_selection >= self.tree_rows.items.len) return;
        const selected = self.tree_rows.items[self.tree_selection];
        switch (selected) {
            .category => |entry| {
                const index = @intFromEnum(entry.kind);
                if (self.category_expanded[index]) {
                    self.category_expanded[index] = false;
                    const focused = self.currentChunk() orelse 0;
                    try self.rebuildTree(focused);
                    for (self.tree_rows.items, 0..) |row, i| switch (row) {
                        .category => |candidate| if (candidate.kind == entry.kind) {
                            self.tree_selection = i;
                            return;
                        },
                        else => {},
                    };
                }
                return;
            },
            .heap => {
                for (self.tree_rows.items, 0..) |row, i| switch (row) {
                    .category => |entry| if (entry.kind == .heap) {
                        self.tree_selection = i;
                        return;
                    },
                    else => {},
                };
                return;
            },
            else => {},
        }
        if (selected == .range) {
            const range = selected.range;
            if (self.expanded_ranges.remove(range.key())) {
                const focused = self.currentChunk() orelse 0;
                try self.rebuildTree(focused);
                for (self.tree_rows.items, 0..) |row, i| switch (row) {
                    .range => |candidate| if (candidate.key() == range.key()) {
                        self.tree_selection = i;
                        return;
                    },
                    else => {},
                };
            }
            for (self.tree_rows.items, 0..) |row, i| switch (row) {
                .name => |entry| if (entry.id == range.parent) {
                    self.tree_selection = i;
                    return;
                },
                else => {},
            };
            return;
        }
        const name: bytecode.name_tree.NameId = switch (selected) {
            .name => |entry| entry.id,
            .chunk => |entry| self.ev.chunkRegistry().nameOf(entry.id) orelse bytecode.root_name_id,
            .range => unreachable,
            .category, .heap => unreachable,
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
            top.detail_selection = self.detail_selection;
            top.x_scroll = self.x_scroll;
        }
        try self.stack.append(self.allocator, .{ .kind = kind });
        self.forward.clearRetainingCapacity();
        try self.refreshPage(kind);
        self.scroll = 0;
        self.detail_selection = self.firstActionableRow() orelse 0;
        switch (kind) {
            .chunk => |id| {
                try self.expandFocusedPath(id);
                try self.rebuildTree(id);
            },
            .heap, .help => {},
        }
        self.x_scroll = 0;
        switch (kind) {
            .help => self.focus = .disassembly,
            .heap => self.focus = .disassembly,
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
        try self.refreshPage(visit.kind);
        self.scroll = visit.scroll;
        self.tree_selection = visit.tree_selection;
        self.detail_selection = visit.detail_selection;
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
            top.detail_selection = self.detail_selection;
            top.x_scroll = self.x_scroll;
        }
        try self.stack.append(self.allocator, visit);
        try self.refreshPage(visit.kind);
        self.scroll = visit.scroll;
        self.tree_selection = visit.tree_selection;
        self.detail_selection = visit.detail_selection;
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
        for (self.page.lines) |line| widest = @max(widest, tui.displayWidth(line, width_mod.cpWidth));
        return widest -| self.layout().main_width;
    }

    fn rowActionable(self: *const Tui, index: usize) bool {
        if (index >= self.page.actions.len) return false;
        return switch (self.page.actions[index]) {
            .none => false,
            else => true,
        };
    }

    fn firstActionableRow(self: *const Tui) ?usize {
        for (self.page.actions, 0..) |action, i| switch (action) {
            .none => {},
            else => return i,
        };
        return null;
    }

    fn moveDetail(self: *Tui, forward: bool) void {
        if (self.page.actions.len == 0) return;
        var cursor = self.detail_selection;
        while (true) {
            if (forward) {
                if (cursor + 1 >= self.page.actions.len) return;
                cursor += 1;
            } else {
                if (cursor == 0) return;
                cursor -= 1;
            }
            if (self.rowActionable(cursor)) {
                self.detail_selection = cursor;
                self.ensureDetailVisible();
                return;
            }
        }
    }

    fn ensureDetailVisible(self: *Tui) void {
        const rows = self.contentRows();
        if (rows == 0) return;
        if (self.detail_selection < self.scroll) self.scroll = self.detail_selection;
        if (self.detail_selection >= self.scroll + rows) self.scroll = self.detail_selection - rows + 1;
        self.clampScroll();
    }

    fn toggleSection(self: *Tui, section: Section, desired: ?bool) !void {
        if (self.currentChunk() == null) return;
        const index = @intFromEnum(section);
        self.sections[index] = desired orelse !self.sections[index];
        try self.refreshPage(self.currentKind());
        for (self.page.actions, 0..) |action, row| switch (action) {
            .section => |candidate| if (candidate == section) {
                self.detail_selection = row;
                self.ensureDetailVisible();
                break;
            },
            else => {},
        };
        self.focus = .disassembly;
    }

    fn activateDetailRow(self: *Tui) !void {
        if (self.detail_selection >= self.page.actions.len) return;
        switch (self.page.actions[self.detail_selection]) {
            .none => {},
            .section => |section| try self.toggleSection(section, null),
            .chunk => |id| try self.open(.{ .chunk = id }),
        }
    }

    fn setDetailSection(self: *Tui, expand: bool) !void {
        if (self.detail_selection >= self.page.actions.len) return;
        switch (self.page.actions[self.detail_selection]) {
            .section => |section| try self.toggleSection(section, expand),
            else => {},
        }
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
                        self.moveDetail(true);
                    }
                },
                'k' => {
                    if (self.focus == .chunks) {
                        self.moveTree(false);
                    } else {
                        self.moveDetail(false);
                    }
                },
                'd' => {
                    if (self.focus == .disassembly) self.scroll = @min(self.scroll + self.contentRows() / 2, self.maxScroll());
                },
                'u' => {
                    if (self.focus == .disassembly) self.scroll -|= self.contentRows() / 2;
                },
                'g' => {
                    if (self.focus == .chunks) {
                        self.tree_selection = 0;
                    } else {
                        self.detail_selection = self.firstActionableRow() orelse 0;
                        self.ensureDetailVisible();
                    }
                },
                'G' => {
                    if (self.focus == .chunks) {
                        self.tree_selection = self.tree_rows.items.len -| 1;
                    } else {
                        var row = self.page.actions.len;
                        while (row > 0) {
                            row -= 1;
                            if (self.rowActionable(row)) {
                                self.detail_selection = row;
                                break;
                            }
                        }
                        self.ensureDetailVisible();
                    }
                },
                'h' => {
                    if (self.focus == .disassembly) self.x_scroll -|= 4;
                },
                'l' => {
                    if (self.focus == .disassembly) self.x_scroll = @min(self.x_scroll + 4, self.maxXScroll());
                },
                'b' => try self.back(),
                'f' => try self.goForward(),
                'c' => try self.toggleSection(.code, null),
                't' => try self.toggleSection(.tables, null),
                's' => try self.toggleSection(.source, null),
                'r' => try self.toggleSection(.references, null),
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
                if (self.focus == .chunks) self.moveTree(false) else self.moveDetail(false);
            },
            .down => {
                if (self.focus == .chunks) {
                    self.moveTree(true);
                } else {
                    self.moveDetail(true);
                }
            },
            .left => {
                if (self.focus == .chunks) try self.collapseTreeRow() else try self.setDetailSection(false);
            },
            .right => {
                if (self.focus == .chunks) {
                    try self.activateTreeRow();
                } else {
                    try self.setDetailSection(true);
                }
            },
            .page_up => {
                if (self.focus == .disassembly) self.scroll -|= self.contentRows();
            },
            .page_down => {
                if (self.focus == .disassembly) self.scroll = @min(self.scroll + self.contentRows(), self.maxScroll());
            },
            .home => {
                if (self.focus == .chunks) self.tree_selection = 0 else {
                    self.detail_selection = self.firstActionableRow() orelse 0;
                    self.ensureDetailVisible();
                }
            },
            .end => {
                if (self.focus == .chunks) self.tree_selection = self.tree_rows.items.len -| 1 else self.scroll = self.maxScroll();
            },
            .tab, .backtab => {
                if (self.focus == .chunks) {
                    self.focus = .disassembly;
                } else {
                    self.focus = .chunks;
                }
            },
            .enter => {
                if (self.focus == .chunks) try self.activateTreeRow() else try self.activateDetailRow();
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
            var frame = tui.Frame.init(w, self.color_depth, width_mod.cpWidth);
            try frame.clearRow(size.rows);
            try frame.at(size.rows, 1);
            var search_buf: [1024]u8 = undefined;
            const search_line = std.fmt.bufPrint(&search_buf, "/{s}", .{self.search.items}) catch "/";
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

    fn drawSession(
        self: *Tui,
        w: *std.Io.Writer,
        prompt_renderer: *render_mod.Renderer,
        prompt_view: render_mod.View,
        measured_prompt_rows: usize,
        capture: *const transcript_mod.Capture,
        prompt_active: bool,
    ) !void {
        var frame = tui.Frame.init(w, self.color_depth, width_mod.cpWidth);
        const size = term_mod.size();
        const cols = @max(@as(usize, 1), size.cols);
        const screen_rows = @max(@as(usize, 3), size.rows);
        const prompt_rows = @min(measured_prompt_rows, screen_rows - 2);
        const prompt_start = screen_rows - prompt_rows;
        const upper_rows = prompt_start -| 2;

        var explorer_rows: usize = 0;
        var transcript_rows = upper_rows;
        // Prompt mode belongs to the transcript. The explorer only claims the
        // body after the user deliberately leaves the prompt with Escape.
        if (!prompt_active and upper_rows >= 7) {
            transcript_rows = @min(@max(@as(usize, 2), upper_rows / 5), 5);
            explorer_rows = upper_rows - transcript_rows - 1;
        }

        if (explorer_rows > 0 and (self.viewport_cols != cols or self.viewport_rows != explorer_rows)) {
            self.viewport_cols = cols;
            self.viewport_rows = explorer_rows;
            try self.refreshPage(self.currentKind());
        }

        var header_buf: [512]u8 = undefined;
        const header = if (self.currentChunk()) |id|
            std.fmt.bufPrint(&header_buf, " fix vm  ·  chunk #0x{x}  ·  {s} ", .{
                id,
                if (prompt_active) "repl" else if (self.focus == .chunks) "tree" else "inspector",
            }) catch " fix repl "
        else if (self.currentHeap()) |view|
            std.fmt.bufPrint(&header_buf, " fix vm  ·  heap/{s}  ·  {s} ", .{
                @tagName(view),
                if (prompt_active) "repl" else if (self.focus == .chunks) "tree" else "inspector",
            }) catch " fix vm "
        else
            std.fmt.bufPrint(&header_buf, " fix vm  ·  help  ·  {s} ", .{
                if (prompt_active) "repl" else if (self.focus == .chunks) "tree" else "inspector",
            }) catch " fix vm ";
        try frame.bar(1, header, cols, .header);

        if (explorer_rows > 0) {
            try self.drawExplorerBody(&frame, 2, explorer_rows, cols);
            const separator_row = 2 + explorer_rows;
            try frame.clearRow(separator_row);
            const separator = if (self.indexing)
                " ─ transcript · indexing VM names asynchronously "
            else
                " ─ transcript ";
            try frame.at(separator_row, 1);
            try frame.text(separator, 0, cols, .muted);
        }

        const transcript_start = 2 + explorer_rows + @intFromBool(explorer_rows > 0);
        try self.drawTranscript(&frame, transcript_start, transcript_rows, cols, capture.written());

        var footer_buf: [512]u8 = undefined;
        const footer = if (prompt_active and capture.omitted() > 0)
            std.fmt.bufPrint(&footer_buf, " Enter evaluate · Esc explorer · Ctrl-D leave VM · Tab complete · {Bi} omitted ", .{capture.omitted()}) catch " Esc explorer "
        else if (prompt_active)
            " Enter evaluate · Esc explorer · Ctrl-D leave VM · Tab complete · Ctrl-R history "
        else
            std.fmt.bufPrint(&footer_buf, " q/Esc exit · i expression · : command · Tab pane · ↵ interact{s} ", .{
                if (self.indexing) " · indexing" else "",
            }) catch " q exit ";
        try frame.bar(screen_rows, footer, cols, .footer);

        try frame.at(prompt_start, 1);
        prompt_renderer.invalidate();
        try frame.cursor(prompt_active);
        try prompt_renderer.draw(w, prompt_view);
        if (!prompt_active) try frame.cursor(false);
    }

    fn drawExplorerBody(self: *Tui, frame: *tui.Frame, first_row: usize, rows: usize, cols: usize) !void {
        const layout_now = self.layout();
        self.clampScroll();
        self.tree_selection = @min(self.tree_selection, self.tree_rows.items.len -| 1);
        for (0..rows) |row| {
            const screen_row = first_row + row;
            try frame.clearRow(screen_row);
            if (layout_now.split) {
                try frame.at(screen_row, 1);
                try self.drawChunkRow(frame, row, layout_now.sidebar_width, rows);
                try frame.divider(screen_row, layout_now.sidebar_width + 1);
                try frame.at(screen_row, layout_now.main_col);
                try self.drawDisasmRow(frame, row, layout_now.main_width);
                if (layout_now.source_split) {
                    try frame.divider(screen_row, layout_now.source_col - 1);
                    try frame.at(screen_row, layout_now.source_col);
                    try self.drawSourceRow(frame, row, layout_now.source_width);
                }
            } else if (self.focus == .chunks) {
                try frame.at(screen_row, 1);
                try self.drawChunkRow(frame, row, cols, rows);
            } else {
                try frame.at(screen_row, 1);
                try self.drawDisasmRow(frame, row, layout_now.main_width);
            }
        }
    }

    fn drawTranscript(self: *Tui, frame: *tui.Frame, first_row: usize, rows: usize, cols: usize, text: []const u8) !void {
        const shown = @min(rows, self.transcript_lines.items.len);
        const first_line = self.transcript_lines.items.len -| shown;
        const top_padding = rows -| shown;
        for (0..rows) |row| {
            try frame.clearRow(first_row + row);
            if (row < top_padding) continue;
            const range = self.transcript_lines.items[first_line + row - top_padding];
            const line = std.mem.trimEnd(u8, text[range.start..range.end], "\r");
            try frame.at(first_row + row, 1);
            try frame.text(line, 0, cols, .plain);
        }
    }

    fn draw(self: *Tui, w: *std.Io.Writer) !void {
        var frame = tui.Frame.init(w, self.color_depth, width_mod.cpWidth);
        const layout_now = self.layout();
        const rows = layout_now.body_rows;
        self.clampScroll();
        self.tree_selection = @min(self.tree_selection, self.tree_rows.items.len -| 1);

        var header_buf: [512]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf, " fix vm  ·  {s}  ·  {s} pane ", .{
            self.page.title,
            if (self.focus == .chunks) "tree" else "detail",
        }) catch " fix vm ";
        try frame.bar(1, header, layout_now.cols, .header);

        var row: usize = 0;
        while (row < rows) : (row += 1) {
            const screen_row = row + 2;
            try frame.clearRow(screen_row);
            if (layout_now.split) {
                try frame.at(screen_row, 1);
                try self.drawChunkRow(&frame, row, layout_now.sidebar_width, rows);
                try frame.divider(screen_row, layout_now.sidebar_width + 1);
                try frame.at(screen_row, layout_now.main_col);
                try self.drawDisasmRow(&frame, row, layout_now.main_width);
                if (layout_now.source_split) {
                    try frame.divider(screen_row, layout_now.source_col - 1);
                    try frame.at(screen_row, layout_now.source_col);
                    try self.drawSourceRow(&frame, row, layout_now.source_width);
                }
            } else if (self.focus == .chunks) {
                try frame.at(screen_row, 1);
                try self.drawChunkRow(&frame, row, layout_now.cols, rows);
            } else {
                try frame.at(screen_row, 1);
                try self.drawDisasmRow(&frame, row, layout_now.main_width);
            }
        }

        const pct = if (self.page.lines.len == 0)
            100
        else
            @min(100, (self.scroll + rows) * 100 / self.page.lines.len);
        var footer_buf: [512]u8 = undefined;
        const footer = std.fmt.bufPrint(&footer_buf, " {d}% · {d}/{d} · x:{d}  {s}  tab focus · c/t/s/r sections · ↵ interact · ? help · q exit ", .{
            pct,
            @min(self.scroll + 1, self.page.lines.len),
            self.page.lines.len,
            self.x_scroll,
            self.status_msg,
        }) catch " q quit ";
        try frame.bar(layout_now.rows, footer, layout_now.cols, .footer);
    }

    fn drawDisasmRow(self: *Tui, frame: *tui.Frame, row: usize, width: usize) !void {
        const idx = self.scroll + row;
        if (idx < self.page.lines.len) {
            const selected = idx == self.detail_selection and self.focus == .disassembly and self.rowActionable(idx);
            if (selected and width >= 2) {
                try frame.text("› ", 0, 2, .selection_marker);
                try frame.text(self.page.lines[idx], self.x_scroll, width - 2, self.detailRole(idx));
            } else {
                try frame.text(self.page.lines[idx], self.x_scroll, width, self.detailRole(idx));
            }
        } else if (idx == self.page.lines.len and self.page.lines.len != 0) {
            try frame.text("(end)", 0, width, .muted);
        }
    }

    fn detailRole(self: *const Tui, index: usize) tui.Role {
        if (index < self.page.actions.len) switch (self.page.actions[index]) {
            .section => return .section,
            .chunk => return .chunk,
            .none => {},
        };
        return if (std.mem.startsWith(u8, self.page.lines[index], "▶")) .source_focus else .plain;
    }

    fn drawSourceRow(self: *Tui, frame: *tui.Frame, row: usize, width: usize) !void {
        if (row < self.page.source_lines.len) {
            const role: tui.Role = if (std.mem.startsWith(u8, self.page.source_lines[row], "▶")) .source_focus else .plain;
            try frame.text(self.page.source_lines[row], 0, width, role);
        }
    }

    const TreeViewport = struct {
        pinned: [64]usize = undefined,
        pin_count: usize = 0,
        start: usize = 0,

        fn index(self: *const TreeViewport, slot: usize) ?usize {
            if (slot < self.pin_count) return self.pinned[slot];
            return self.start + slot - self.pin_count;
        }
    };

    fn treeRowDepth(row: TreeRow) u16 {
        return switch (row) {
            .category => |entry| entry.depth,
            .name => |entry| entry.depth,
            .chunk => |entry| entry.depth,
            .range => |entry| entry.depth,
            .heap => |entry| entry.depth,
        };
    }

    fn treeViewport(self: *const Tui, slots: usize) TreeViewport {
        var result: TreeViewport = .{};
        const count = self.tree_rows.items.len;
        if (slots == 0 or count == 0) return result;

        var normal_slots = slots;
        var pass: usize = 0;
        while (pass < 2) : (pass += 1) {
            result.start = @min(self.tree_selection -| (normal_slots / 2), count -| normal_slots);
            var hidden_nearest: [64]usize = undefined;
            const hidden_count = self.hiddenTreeAncestors(result.start, &hidden_nearest);
            result.pin_count = @min(@min(hidden_count, hidden_nearest.len), slots -| 1);
            var i: usize = 0;
            while (i < result.pin_count) : (i += 1) {
                result.pinned[i] = hidden_nearest[result.pin_count - i - 1];
            }
            normal_slots = slots - result.pin_count;
        }
        result.start = @min(self.tree_selection -| (normal_slots / 2), count -| normal_slots);
        return result;
    }

    /// Collect off-screen ancestors nearest-first. Keeping the nearest entries
    /// means very deep trees degrade into a useful partial breadcrumb.
    fn hiddenTreeAncestors(self: *const Tui, start: usize, out: *[64]usize) usize {
        if (self.tree_selection >= self.tree_rows.items.len) return 0;
        var wanted_depth = treeRowDepth(self.tree_rows.items[self.tree_selection]);
        var cursor = self.tree_selection;
        var count: usize = 0;
        while (cursor > 0 and wanted_depth > 0) {
            cursor -= 1;
            const depth = treeRowDepth(self.tree_rows.items[cursor]);
            if (depth >= wanted_depth) continue;
            if (cursor < start and count < out.len) {
                out[count] = cursor;
                count += 1;
            }
            wanted_depth = depth;
        }
        return count;
    }

    fn drawChunkRow(self: *Tui, frame: *tui.Frame, row: usize, width: usize, rows: usize) !void {
        var line_buf: [512]u8 = undefined;
        if (row == 0) {
            const root_stats = self.name_index.statsOf(bytecode.root_name_id);
            const heap_counts = self.ev.heapCounts();
            const line = if (self.indexing)
                std.fmt.bufPrint(&line_buf, " VM STATE · {d} chunks · {d} object slots · indexing…", .{ root_stats.chunks, heap_counts.objects }) catch " VM STATE"
            else
                std.fmt.bufPrint(&line_buf, " VM STATE · {d} chunks · {d} object slots", .{ root_stats.chunks, heap_counts.objects }) catch " VM STATE";
            try frame.text(line, 0, width, .section);
            return;
        }
        if (row == 1) {
            const id = self.currentChunk() orelse {
                if (self.currentHeap()) |view| {
                    const line = std.fmt.bufPrint(&line_buf, " ● heap/{s}", .{@tagName(view)}) catch " heap";
                    try frame.text(line, 0, width, .current);
                } else {
                    try frame.text(" help", 0, width, .muted);
                }
                return;
            };
            const line = if (self.ev.getChunk(id)) |chunk|
                std.fmt.bufPrint(&line_buf, " ● #0x{x}  {d}b · {d}c · a{d}", .{ id, chunk.code.len, chunk.constants.len, chunk.arity }) catch " current chunk"
            else
                std.fmt.bufPrint(&line_buf, " ● #0x{x}  missing", .{id}) catch " current chunk";
            try frame.text(line, 0, width, .current);
            return;
        }
        if (row == 2) {
            try frame.text(" ─ runtime state ─", 0, width, .muted);
            return;
        }

        const count = self.tree_rows.items.len;
        if (count == 0) {
            if (row == 3) try frame.text("   empty registry", 0, width, .muted);
            return;
        }
        const slots = rows -| 3;
        if (slots == 0) return;
        const viewport = self.treeViewport(slots);
        const slot = row - 3;
        const index = viewport.index(slot) orelse return;
        if (index >= count) return;
        const pinned = slot < viewport.pin_count;
        const selected = index == self.tree_selection;
        const line: []const u8 = switch (self.tree_rows.items[index]) {
            .category => |entry| blk: {
                const is_open = self.category_expanded[@intFromEnum(entry.kind)];
                break :blk switch (entry.kind) {
                    .bytecode => blk2: {
                        const stats = self.name_index.statsOf(bytecode.root_name_id);
                        break :blk2 std.fmt.bufPrint(&line_buf, " {s} BYTECODE  {d} chunks", .{ if (is_open) "▾" else "▸", stats.chunks }) catch " bytecode";
                    },
                    .heap => blk2: {
                        const counts = self.ev.heapCounts();
                        break :blk2 std.fmt.bufPrint(&line_buf, " {s} HEAP  {d} object slots", .{ if (is_open) "▾" else "▸", counts.objects }) catch " heap";
                    },
                };
            },
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
            .range => |entry| blk: {
                var indent: [64]u8 = undefined;
                const indent_len = @min(@as(usize, entry.depth) * 2, indent.len);
                @memset(indent[0..indent_len], ' ');
                const is_open = self.expanded_ranges.contains(entry.key());
                break :blk switch (entry.kind) {
                    .names => std.fmt.bufPrint(&line_buf, " {s}{s} names {d}–{d}", .{
                        indent[0..indent_len],
                        if (is_open) "▾" else "▸",
                        entry.start + 1,
                        entry.start + entry.len,
                    }) catch " name range",
                    .chunks => blk2: {
                        const chunks = self.name_index.chunksOf(entry.parent);
                        const first = chunks[entry.start];
                        const last = chunks[entry.start + entry.len - 1];
                        break :blk2 std.fmt.bufPrint(&line_buf, " {s}{s} chunks #{d}–#{d}", .{
                            indent[0..indent_len],
                            if (is_open) "▾" else "▸",
                            first,
                            last,
                        }) catch " chunk range";
                    },
                };
            },
            .heap => |entry| blk: {
                const counts = self.ev.heapCounts();
                const store_count = switch (entry.view) {
                    .overview, .objects => counts.objects,
                    .values => counts.values,
                    .attrs => counts.attrs,
                    .attr_positions => counts.attr_positions,
                };
                var indent: [64]u8 = undefined;
                const indent_len = @min(@as(usize, entry.depth) * 2, indent.len);
                @memset(indent[0..indent_len], ' ');
                break :blk std.fmt.bufPrint(&line_buf, " {s}· {s}  {d}", .{ indent[0..indent_len], @tagName(entry.view), store_count }) catch " heap store";
            },
        };
        const role: tui.Role = if (selected and self.focus == .chunks)
            .selection
        else if (pinned)
            .muted
        else switch (self.tree_rows.items[index]) {
            .category => .section,
            .name => .name,
            .chunk => |entry| if (self.currentChunk() == entry.id) .current else .chunk,
            .range => .range,
            .heap => |entry| switch (self.currentKind()) {
                .heap => |view| if (view == entry.view) .current else .chunk,
                else => .chunk,
            },
        };
        try frame.text(line, 0, width, role);
    }
};

fn writeSanitizedSource(w: *std.Io.Writer, source: []const u8) !void {
    for (source) |byte| switch (byte) {
        '\t' => try w.writeAll("    "),
        '\r' => {},
        0x1b => try w.writeAll("␛"),
        0...8, 10...12, 14...26, 28...0x1f, 0x7f => try w.writeByte('?'),
        else => try w.writeByte(byte),
    };
}
