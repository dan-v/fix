//! The VM explorer TUI: a qualified-name tree beside the selected chunk view.
//!
//! Interactive use is deliberately a TUI rather than a pager: the name tree is
//! persistent navigation, the chunk detail is a separately scrollable pane,
//! and the ordinary REPL prompt/transcript occupy the same surface. The plain
//! (`--no-tui`/non-tty) fallback exposes the same model through bounded commands.

const std = @import("std");
const engine = @import("expr");
const runtime = @import("runtime");
const term_mod = @import("term.zig");
const keys_mod = @import("keys.zig");
const width_mod = @import("width.zig");
const editor_mod = @import("editor.zig");
const render_mod = @import("render.zig");
const transcript_mod = @import("transcript.zig");
const vm_tree = @import("vm_tree.zig");
const source_render = @import("../source_render.zig");
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

/// Non-interactive `:vm`: the focused chunk without terminal chrome.
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

const Panel = enum(u2) { code, tables, source, references };
const Category = enum(u1) { bytecode, heap };
const HeapView = enum { overview, objects, values, attrs, attr_positions };

const RowAction = union(enum) {
    none,
    heading: Panel,
    instruction,
    chunk: ChunkId,
    object: runtime.types.ObjectId,
};

const BreakpointLocation = struct {
    file: []const u8,
    line: u32,
};

/// One rendered inspector document (or the help screen). Actions are parallel
/// to lines so references remain useful even when the chunk itself is shorter
/// than the viewport.
const Page = struct {
    title: []u8,
    lines: [][]u8,
    actions: []RowAction,
    locations: []const ?BreakpointLocation = &.{},
    source_lines: []const []const u8 = &.{},
};

const PageBuilder = struct {
    arena: std.mem.Allocator,
    lines: std.ArrayListUnmanaged([]u8) = .empty,
    actions: std.ArrayListUnmanaged(RowAction) = .empty,
    locations: std.ArrayListUnmanaged(?BreakpointLocation) = .empty,

    fn line(self: *PageBuilder, line_text: []const u8, action: RowAction) !void {
        try self.lineAt(line_text, action, null);
    }

    fn lineAt(self: *PageBuilder, line_text: []const u8, action: RowAction, location: ?BreakpointLocation) !void {
        try self.lines.append(self.arena, try self.arena.dupe(u8, line_text));
        try self.actions.append(self.arena, action);
        try self.locations.append(self.arena, location);
    }

    fn text(self: *PageBuilder, contents: []const u8) !void {
        var it = std.mem.splitScalar(u8, contents, '\n');
        while (it.next()) |line_text| try self.line(line_text, .none);
        if (self.lines.items.len > 0 and self.lines.items[self.lines.items.len - 1].len == 0) {
            _ = self.lines.pop();
            _ = self.actions.pop();
            _ = self.locations.pop();
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
        object: runtime.types.ObjectId,
        help,
    };
};

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
    var tree_index = try vm_tree.Index.build(allocator, ev.chunkRegistry(), ev.internTable(), ev.basePath());
    defer tree_index.deinit();
    var explorer = Tui{
        .allocator = allocator,
        .io = io,
        .ev = ev,
        .color_depth = color_depth,
        .tree_index = &tree_index,
        .session_host = host,
        .arena = std.heap.ArenaAllocator.init(allocator),
    };
    defer explorer.deinit();
    try explorer.runSession(editor, transcript, host);
}

const IndexJob = struct {
    registry: *const bytecode.ChunkRegistry,
    intern: *const runtime.InternTable,
    base_path: ?[]const u8,
    thread: ?std.Thread = null,
    mutex: sync.BlockingMutex = .{},
    ready: ?vm_tree.Index = null,
    running: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),

    fn start(self: *IndexJob) !void {
        if (self.thread != null) return;
        self.running.store(true, .release);
        self.thread = std.Thread.spawn(.{}, build, .{self}) catch |err| {
            self.failed.store(true, .release);
            self.running.store(false, .release);
            return err;
        };
    }

    fn build(self: *IndexJob) void {
        const result = vm_tree.Index.build(std.heap.smp_allocator, self.registry, self.intern, self.base_path) catch {
            self.failed.store(true, .release);
            self.running.store(false, .release);
            return;
        };
        self.mutex.lock();
        self.ready = result;
        self.mutex.unlock();
        self.running.store(false, .release);
    }

    fn poll(self: *IndexJob, current: *vm_tree.Index) bool {
        if (self.thread == null or self.running.load(.acquire)) return false;
        return self.finish(current);
    }

    fn finish(self: *IndexJob, current: *vm_tree.Index) bool {
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

const ObjectJob = struct {
    ev: *Evaluator,
    thread: ?std.Thread = null,
    mutex: sync.BlockingMutex = .{},
    ready: ?runtime.ObjectHeap.ObjectSnapshot = null,
    running: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),

    fn start(self: *ObjectJob) !void {
        if (self.thread != null) return;
        self.running.store(true, .release);
        self.thread = std.Thread.spawn(.{}, build, .{self}) catch |err| {
            self.failed.store(true, .release);
            self.running.store(false, .release);
            return err;
        };
    }

    fn build(self: *ObjectJob) void {
        const result = self.ev.heapObjectSnapshot(std.heap.smp_allocator) catch {
            self.failed.store(true, .release);
            self.running.store(false, .release);
            return;
        };
        self.mutex.lock();
        self.ready = result;
        self.mutex.unlock();
        self.running.store(false, .release);
    }

    fn poll(self: *ObjectJob, target: *?runtime.ObjectHeap.ObjectSnapshot) bool {
        if (self.thread == null or self.running.load(.acquire)) return false;
        self.finish(target);
        return true;
    }

    fn finish(self: *ObjectJob, target: *?runtime.ObjectHeap.ObjectSnapshot) void {
        if (self.thread) |thread| thread.join();
        self.thread = null;
        self.mutex.lock();
        if (self.ready) |snapshot| {
            if (target.*) |*old| old.deinit();
            target.* = snapshot;
        }
        self.ready = null;
        self.mutex.unlock();
        self.running.store(false, .release);
    }

    fn deinit(self: *ObjectJob) void {
        var discard: ?runtime.ObjectHeap.ObjectSnapshot = null;
        self.finish(&discard);
        if (discard) |*snapshot| snapshot.deinit();
    }
};

const RefJob = struct {
    registry: *const bytecode.ChunkRegistry,
    thread: ?std.Thread = null,
    mutex: sync.BlockingMutex = .{},
    ready: ?bytecode.inspect.RefGraph = null,
    running: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),

    fn start(self: *RefJob) !void {
        if (self.thread != null) return;
        self.running.store(true, .release);
        self.thread = std.Thread.spawn(.{}, build, .{self}) catch |err| {
            self.failed.store(true, .release);
            self.running.store(false, .release);
            return err;
        };
    }

    fn build(self: *RefJob) void {
        const result = bytecode.inspect.RefGraph.build(std.heap.smp_allocator, self.registry) catch {
            self.failed.store(true, .release);
            self.running.store(false, .release);
            return;
        };
        self.mutex.lock();
        self.ready = result;
        self.mutex.unlock();
        self.running.store(false, .release);
    }

    fn poll(self: *RefJob, target: *?bytecode.inspect.RefGraph) bool {
        if (self.thread == null or self.running.load(.acquire)) return false;
        return self.finish(target);
    }

    fn finish(self: *RefJob, target: *?bytecode.inspect.RefGraph) bool {
        const thread = self.thread orelse return false;
        thread.join();
        self.thread = null;
        self.mutex.lock();
        const next = self.ready;
        self.ready = null;
        self.mutex.unlock();
        if (next) |graph| {
            if (target.*) |*old| old.deinit();
            target.* = graph;
            return true;
        }
        return false;
    }

    fn deinit(self: *RefJob) void {
        if (self.thread) |thread| thread.join();
        self.thread = null;
        self.mutex.lock();
        if (self.ready) |*graph| graph.deinit();
        self.ready = null;
        self.mutex.unlock();
    }
};

const Focus = enum { chunks, disassembly };
const RangeKind = enum(u2) { names, chunks, objects };
const ChunkEquivalence = union(enum) {
    structural: ChunkId,
    code: ChunkId,
};
const Range = struct {
    kind: RangeKind,
    parent: u32,
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
const TreeRow = union(enum) {
    category: struct { kind: Category, depth: u16 },
    name: struct { id: u32, depth: u16 },
    chunk: struct { id: ChunkId, depth: u16, label: ?u32 = null },
    range: Range,
    heap: struct { view: HeapView, depth: u16 },
    object: struct { id: runtime.types.ObjectId, depth: u16 },
};
const LineRange = struct { start: usize, end: usize };

const NavigationState = struct {
    back: std.ArrayListUnmanaged(Visit) = .empty,
    forward: std.ArrayListUnmanaged(Visit) = .empty,
    search: std.ArrayListUnmanaged(u8) = .empty,
    focus: Focus = .disassembly,
    tree_selection: usize = 0,
    detail_selection: usize = 0,
    scroll: usize = 0,
    x_scroll: usize = 0,
    panel: Panel = .code,
};

const TreeState = struct {
    expanded_names: std.AutoHashMapUnmanaged(u32, void) = .empty,
    expanded_ranges: std.AutoHashMapUnmanaged(u128, void) = .empty,
    focus_path: std.AutoHashMapUnmanaged(u32, void) = .empty,
    rows: std.ArrayListUnmanaged(TreeRow) = .empty,
    indexing: bool = false,
    categories: [2]bool = .{ false, false },
    heap_views: [5]bool = @splat(false),
};

const HeapIndexState = struct {
    stats: ?runtime.ObjectHeap.Stats = null,
    objects: ?runtime.ObjectHeap.ObjectSnapshot = null,
    objects_failed: bool = false,
};

const ReferenceIndexState = struct {
    graph: ?bytecode.inspect.RefGraph = null,
    indexing: bool = false,
    failed: bool = false,
};

const Viewport = struct {
    cols: usize = 80,
    rows: usize = 22,
};

const SessionJobs = struct {
    names: IndexJob,
    heap: HeapJob,
    objects: ObjectJob,
    references: RefJob,

    fn init(ev: *Evaluator) SessionJobs {
        return .{
            .names = .{
                .registry = ev.chunkRegistry(),
                .intern = ev.internTable(),
                .base_path = ev.basePath(),
            },
            .heap = .{ .ev = ev },
            .objects = .{ .ev = ev },
            .references = .{ .registry = ev.chunkRegistry() },
        };
    }

    fn deinit(self: *SessionJobs) void {
        self.names.deinit();
        self.heap.deinit();
        self.objects.deinit();
        self.references.deinit();
    }

    fn finish(self: *SessionJobs, explorer: *Tui) void {
        _ = self.names.finish(explorer.tree_index);
        self.heap.finish(&explorer.heap_index.stats);
        self.objects.finish(&explorer.heap_index.objects);
        _ = self.references.finish(&explorer.references.graph);
    }

    fn clearFailures(self: *SessionJobs) void {
        self.names.failed.store(false, .release);
        self.objects.failed.store(false, .release);
        self.references.failed.store(false, .release);
    }

    fn hasThread(self: *const SessionJobs) bool {
        return self.names.thread != null or self.heap.thread != null or self.objects.thread != null or self.references.thread != null;
    }
};

const Tui = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    ev: *Evaluator,
    color_depth: ColorDepth,
    tree_index: *vm_tree.Index,
    session_host: ?SessionHost = null,
    /// Only the current rendered page lives here. Persistent REPL sessions
    /// reset it on every view/focus change instead of accumulating every
    /// disassembly ever visited.
    arena: std.heap.ArenaAllocator,
    viewport: Viewport = .{},
    navigation: NavigationState = .{},
    tree: TreeState = .{},
    heap_index: HeapIndexState = .{},
    references: ReferenceIndexState = .{},
    page: Page = undefined,
    transcript_lines: std.ArrayListUnmanaged(LineRange) = .empty,
    status_msg: []const u8 = "",
    status_buf: [256]u8 = undefined,

    const range_leaf = 128;
    const range_branch = 4096;

    fn deinit(self: *Tui) void {
        self.navigation.back.deinit(self.allocator);
        self.navigation.forward.deinit(self.allocator);
        self.navigation.search.deinit(self.allocator);
        self.tree.expanded_names.deinit(self.allocator);
        self.tree.expanded_ranges.deinit(self.allocator);
        self.tree.focus_path.deinit(self.allocator);
        self.tree.rows.deinit(self.allocator);
        self.transcript_lines.deinit(self.allocator);
        if (self.references.graph) |*graph| graph.deinit();
        if (self.heap_index.objects) |*snapshot| snapshot.deinit();
        self.arena.deinit();
    }

    fn initializeSession(self: *Tui, host: SessionHost) !void {
        const focused = host.focusedChunk();
        if (host.start_heap) self.tree.categories[@intFromEnum(Category.heap)] = true;
        const initial: Visit.Kind = if (host.start_heap)
            .{ .heap = .overview }
        else if (focused) |id|
            .{ .chunk = id }
        else
            .help;
        try self.navigation.back.append(self.allocator, .{ .kind = initial });
        if (focused) |id| {
            try self.expandFocusedPath(id);
            try self.rebuildTree(id);
        } else {
            try self.rebuildTree(std.math.maxInt(ChunkId));
        }
        if (host.start_heap) {
            for (self.tree.rows.items, 0..) |row, i| switch (row) {
                .heap => |entry| if (entry.view == .overview) {
                    self.navigation.tree_selection = i;
                    break;
                },
                else => {},
            };
        }
        try self.refreshPage(initial);
    }

    fn pollSessionJobs(self: *Tui, host: SessionHost, jobs: *SessionJobs) !void {
        if (jobs.names.poll(self.tree_index)) {
            self.tree.indexing = false;
            if (host.focusedChunk()) |id| {
                try self.expandFocusedPath(id);
                try self.rebuildTree(id);
            }
        }
        const registry = self.ev.chunkRegistry();
        const names_stale = self.tree_index.registry_count != registry.count() or self.tree_index.name_count != registry.nameCount();
        if (names_stale and jobs.names.thread == null and !jobs.names.failed.load(.acquire)) {
            jobs.names.start() catch {
                self.status_msg = "(name index failed)";
            };
        }
        const names_failed = jobs.names.failed.load(.acquire);
        self.tree.indexing = !names_failed and (names_stale or jobs.names.running.load(.acquire));
        if (names_stale and names_failed) self.status_msg = "(name index failed)";

        if (jobs.heap.poll(&self.heap_index.stats) and self.currentHeap() != null)
            try self.refreshPage(self.currentKind());
        if (self.currentHeap() != null and self.heap_index.stats == null and jobs.heap.thread == null) {
            jobs.heap.start() catch {
                self.status_msg = "(heap census failed)";
            };
        }

        if (jobs.objects.poll(&self.heap_index.objects)) {
            try self.rebuildTreeForCurrent();
            if (self.currentObject() != null) try self.refreshPage(self.currentKind());
        }
        const objects_failed = jobs.objects.failed.load(.acquire);
        if (objects_failed != self.heap_index.objects_failed) {
            self.heap_index.objects_failed = objects_failed;
            if (self.currentObject() != null) try self.refreshPage(self.currentKind());
        }
        const wants_objects = self.currentObject() != null or self.tree.heap_views[@intFromEnum(HeapView.objects)];
        if (wants_objects and objects_failed) self.status_msg = "(object index failed)";
        if (wants_objects and self.heap_index.objects == null and jobs.objects.thread == null and !objects_failed) {
            jobs.objects.start() catch {
                self.status_msg = "(object index failed)";
            };
        }

        if (jobs.references.poll(&self.references.graph)) {
            self.references.indexing = false;
            if (self.currentChunk() != null and self.navigation.panel == .references)
                try self.refreshPage(self.currentKind());
        }
        const references_failed = jobs.references.failed.load(.acquire);
        if (references_failed != self.references.failed) {
            self.references.failed = references_failed;
            if (self.currentChunk() != null and self.navigation.panel == .references)
                try self.refreshPage(self.currentKind());
        }
        const wants_references = self.currentChunk() != null and self.navigation.panel == .references;
        if (wants_references and references_failed) self.status_msg = "(reference index failed)";
        const references_stale = self.references.graph == null or self.references.graph.?.registry_count != registry.count();
        if (wants_references and references_stale and jobs.references.thread == null and !references_failed) {
            jobs.references.start() catch {
                self.status_msg = "(reference index failed)";
            };
        }
        const indexing_references = wants_references and !references_failed and (references_stale or jobs.references.running.load(.acquire));
        if (indexing_references != self.references.indexing) {
            self.references.indexing = indexing_references;
            try self.refreshPage(self.currentKind());
        }
    }

    fn executeCommand(self: *Tui, input: []const u8, capture: *transcript_mod.Capture, host: SessionHost, jobs: *SessionJobs) !bool {
        jobs.finish(self);
        try host.execute(input, &capture.writer);
        jobs.clearFailures();
        self.heap_index.objects_failed = false;
        self.references.failed = false;
        self.heap_index.stats = null;
        if (self.heap_index.objects) |*snapshot| snapshot.deinit();
        self.heap_index.objects = null;
        if (capture.written().len > 0 and capture.written()[capture.written().len - 1] != '\n')
            try capture.writer.writeByte('\n');
        try self.rebuildTranscriptLines(capture.written());
        if (host.takeHeapRequest()) {
            try self.open(.{ .heap = .overview });
        } else if (host.focusedChunk()) |id| {
            if (self.currentChunk() != id)
                try self.open(.{ .chunk = id })
            else
                try self.refreshPage(.{ .chunk = id });
        }
        return host.quitting();
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
        try self.initializeSession(host);

        var jobs = SessionJobs.init(self.ev);
        defer jobs.deinit();
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
            try self.pollSessionJobs(host, &jobs);

            _ = frame_arena.reset(.retain_capacity);
            var prompt_view = try self.sessionPromptView(editor, frame_arena.allocator());
            const size = term_mod.size();
            prompt_renderer.setWidth(size.cols);
            prompt_view.max_rows = size.rows -| 2;
            const prompt_rows = if (prompt_active) try prompt_renderer.measure(prompt_view) else 0;
            try self.drawSession(frame_arena.allocator(), w, &prompt_renderer, prompt_view, prompt_rows, capture, prompt_active);
            try w.flush();

            // Keep polling while a thread handle exists, even if the worker
            // finished between drawing and this check; otherwise a very fast
            // build could leave us in an infinite blocking read before its
            // completed generation is adopted.
            const timeout: i32 = if (decoder.wantsMore()) 40 else if (jobs.hasThread()) 50 else -1;
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
                            if (try self.executeCommand(trimmed, capture, host, &jobs)) return;
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
        self.navigation.detail_selection = @min(self.navigation.detail_selection, self.page.lines.len -| 1);
        if (!self.rowActionable(self.navigation.detail_selection)) self.navigation.detail_selection = self.firstActionableRow() orelse 0;
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
                try self.appendChunkEquivalence(&page, id);
                const source_lines = if (self.navigation.panel == .source)
                    try self.sourceDocument(id, chunk)
                else
                    &.{};
                if (self.navigation.panel == .source and !self.layout().source_split) {
                    for (source_lines) |source_line| try page.line(source_line, .none);
                } else switch (self.navigation.panel) {
                    .code, .source => try self.appendDisassembly(&page, id, chunk, .code),
                    .tables => try self.appendDisassembly(&page, id, chunk, .tables),
                    .references => try self.appendRefs(&page, id),
                }
                return .{
                    .title = try std.fmt.allocPrint(arena, "chunk[0x{x}]", .{id}),
                    .lines = page.lines.items,
                    .actions = page.actions.items,
                    .locations = page.locations.items,
                    .source_lines = if (self.layout().source_split) source_lines else &.{},
                };
            },
            .heap => |view| return self.buildHeapPage(view),
            .object => |id| return self.buildObjectPage(id),
            .help => {
                const help_text =
                    \\The VM explorer
                    \\
                    \\  Tab             switch tree/detail focus
                    \\  j/k, arrows     move between interactive rows
                    \\  Enter, →        expand a tree/group or open a reference
                    \\  ←               collapse a tree/group
                    \\  c/t/s/r         show code/tables/source/references panel
                    \\  p               toggle breakpoint at selected instruction
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

        const stats = self.heap_index.stats orelse {
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

    fn buildObjectPage(self: *Tui, id: runtime.types.ObjectId) !Page {
        const arena = self.arena.allocator();
        var page: PageBuilder = .{ .arena = arena };
        const snapshot = self.heap_index.objects orelse {
            try page.line(if (self.heap_index.objects_failed) "live-object index unavailable" else "building the live-object index asynchronously…", .none);
            return .{
                .title = try std.fmt.allocPrint(arena, "object[#{d}]", .{id}),
                .lines = page.lines.items,
                .actions = page.actions.items,
            };
        };
        const info = self.ev.inspectHeapObject(&snapshot, id) catch {
            try page.line("this object is no longer live", .none);
            return .{
                .title = try std.fmt.allocPrint(arena, "object[#{d}]", .{id}),
                .lines = page.lines.items,
                .actions = page.actions.items,
            };
        };
        try page.line(try std.fmt.allocPrint(arena, "OBJECT #{d} · {s}", .{ id, @tagName(info) }), .none);
        try page.line("", .none);
        switch (info) {
            .list => |list| try page.line(try std.fmt.allocPrint(arena, "items       {d}", .{list.len}), .none),
            .attrs => |attrs| {
                try page.line(try std.fmt.allocPrint(arena, "attributes  {d}", .{attrs.len}), .none);
                try page.line(try std.fmt.allocPrint(arena, "positions   {d}", .{attrs.positions}), .none);
                try page.line(try std.fmt.allocPrint(arena, "swept       {s}", .{if (attrs.sibling_swept) "yes" else "no"}), .none);
            },
            .merge_attrs => |merge| {
                try self.appendObjectRef(&page, "base", merge.base);
                try self.appendObjectRef(&page, "overlay", merge.overlay);
                try page.line(try std.fmt.allocPrint(arena, "depth       {d}", .{merge.depth}), .none);
                if (merge.flattened) |flat| try self.appendObjectRef(&page, "flattened", flat) else try page.line("flattened   not materialized", .none);
            },
            .closure => |closure| {
                try page.line(try std.fmt.allocPrint(arena, "chunk       #{d}", .{closure.chunk}), .{ .chunk = closure.chunk });
                try page.line(try std.fmt.allocPrint(arena, "upvalues    {d}", .{closure.upvalues}), .none);
            },
            .builtin_closure => |closure| {
                try page.line(try std.fmt.allocPrint(arena, "builtin     #{d}", .{closure.builtin}), .none);
                try page.line(try std.fmt.allocPrint(arena, "arguments   {d}", .{closure.args}), .none);
            },
            .thunk => |thunk| {
                try page.line(try std.fmt.allocPrint(arena, "state       {s}", .{@tagName(thunk.state)}), .none);
                try page.line(try std.fmt.allocPrint(arena, "demanded    {s}", .{if (thunk.demanded) "yes" else "no"}), .none);
                switch (thunk.body) {
                    .result => |value| try self.appendValueRef(&page, "result", value),
                    .error_name => |name| try page.line(try std.fmt.allocPrint(arena, "error       {s}", .{name}), .none),
                    .target => |target| switch (target) {
                        .closure => |value| try self.appendValueRef(&page, "closure", value),
                        .bytecode => |body| {
                            try page.line(try std.fmt.allocPrint(arena, "chunk       #{d}", .{body.chunk}), .{ .chunk = body.chunk });
                            try page.line(try std.fmt.allocPrint(arena, "captures    {d}", .{body.captures}), .none);
                        },
                        .pass_through => |value| try self.appendValueRef(&page, "value", value),
                        .attr_access => |access| {
                            try self.appendValueRef(&page, "base", access.base);
                            try page.line(try std.fmt.allocPrint(arena, "attribute   intern #{d}", .{access.name}), .none);
                        },
                        .deferred => |body| {
                            try page.line(try std.fmt.allocPrint(arena, "deferred    #{d}", .{body.id}), .none);
                            try page.line(try std.fmt.allocPrint(arena, "captures    {d}", .{body.captures}), .none);
                        },
                    },
                }
            },
            .context_string => |string| {
                try page.line(try std.fmt.allocPrint(arena, "text        intern #{d}", .{string.text}), .none);
                try page.line(try std.fmt.allocPrint(arena, "context     {d} entries", .{string.context}), .none);
            },
            .boxed_int => |value| try page.line(try std.fmt.allocPrint(arena, "value       {d}", .{value}), .none),
            .partial_app => |partial| {
                try self.appendValueRef(&page, "function", partial.function);
                try page.line(try std.fmt.allocPrint(arena, "arguments   {d}", .{partial.args}), .none);
            },
        }
        return .{
            .title = try std.fmt.allocPrint(arena, "object[#{d}]", .{id}),
            .lines = page.lines.items,
            .actions = page.actions.items,
        };
    }

    fn appendObjectRef(self: *Tui, page: *PageBuilder, label: []const u8, id: runtime.types.ObjectId) !void {
        _ = self;
        try page.line(try std.fmt.allocPrint(page.arena, "{s:<12} object #{d}", .{ label, id }), .{ .object = id });
    }

    fn appendValueRef(self: *Tui, page: *PageBuilder, label: []const u8, value: runtime.heap.ValueRef) !void {
        _ = self;
        switch (value.target) {
            .none => try page.line(try std.fmt.allocPrint(page.arena, "{s:<12} {s}", .{ label, @tagName(value.kind) }), .none),
            .object => |id| try page.line(try std.fmt.allocPrint(page.arena, "{s:<12} {s} object #{d}", .{ label, @tagName(value.kind), id }), .{ .object = id }),
            .chunk => |id| try page.line(try std.fmt.allocPrint(page.arena, "{s:<12} {s} chunk #{d}", .{ label, @tagName(value.kind), id }), .{ .chunk = id }),
            .intern => |id| try page.line(try std.fmt.allocPrint(page.arena, "{s:<12} {s} intern #{d}", .{ label, @tagName(value.kind), id }), .none),
            .builtin => |id| try page.line(try std.fmt.allocPrint(page.arena, "{s:<12} {s} #{d}", .{ label, @tagName(value.kind), id }), .none),
        }
    }

    fn appendDisassembly(self: *Tui, page: *PageBuilder, id: ChunkId, chunk: *const bytecode.Chunk, panel: Panel) !void {
        var text: std.Io.Writer.Allocating = .init(page.arena);
        const symbols: disasm.Symbols = .{ .intern = self.ev.internTable(), .registry = self.ev.chunkRegistry() };
        var options = disasm_options;
        options.color_depth = self.color_depth;
        options.show_constants = panel == .tables;
        options.show_code = panel == .code;
        options.line_width = @intCast(@min(self.layout().main_width, std.math.maxInt(u16)));
        try disasm.writeChunk(page.arena, &text.writer, id, chunk, symbols, options);

        var lines = std.mem.splitScalar(u8, text.written(), '\n');
        while (lines.next()) |line| {
            if (line.len == 0 and lines.peek() == null) break;
            const plain = base.terminal_text.stripAnsiInPlace(try page.arena.dupe(u8, line));
            const target = disasmTarget(plain);
            const action: RowAction = if (target == .none and disasmOffset(chunk, plain) != null) .instruction else target;
            try page.lineAt(line, action, self.disasmLocation(id, chunk, plain));
        }
    }

    fn chunkEquivalence(self: *const Tui, id: ChunkId) ?ChunkEquivalence {
        const index = &self.tree_index.equivalence;
        if (index.structuralPeer(id)) |peer| return .{ .structural = peer };
        if (index.codePeer(id)) |peer| return .{ .code = peer };
        return null;
    }

    fn chunkEquivalenceSuffix(self: *const Tui, buffer: []u8, id: ChunkId) []const u8 {
        const relation = self.chunkEquivalence(id) orelse return "";
        return switch (relation) {
            .structural => |peer| std.fmt.bufPrint(buffer, " · identical #{d}", .{peer}) catch "",
            .code => |peer| std.fmt.bufPrint(buffer, " · same code #{d}", .{peer}) catch "",
        };
    }

    fn appendChunkEquivalence(self: *Tui, page: *PageBuilder, id: ChunkId) !void {
        const relation = self.chunkEquivalence(id) orelse return;
        switch (relation) {
            .structural => |peer| try page.line(
                try std.fmt.allocPrint(page.arena, "structurally identical to chunk #{d}", .{peer}),
                .{ .chunk = peer },
            ),
            .code => |peer| try page.line(
                try std.fmt.allocPrint(page.arena, "same bytecode as chunk #{d}; constants, source data, or metadata differ", .{peer}),
                .{ .chunk = peer },
            ),
        }
        try page.line("", .none);
    }

    fn disasmLocation(self: *Tui, id: ChunkId, chunk: *const bytecode.Chunk, plain: []const u8) ?BreakpointLocation {
        const offset = disasmOffset(chunk, plain) orelse return null;
        const span = bytecode.inspect.bestSpan(chunk, offset) orelse return null;
        const file_id = span.file orelse bytecode.inspect.chunkPrimaryFile(chunk, id, self.ev.chunkRegistry()) orelse return null;
        return .{ .file = self.ev.internTable().get(file_id), .line = span.line };
    }

    fn appendRefs(self: *Tui, page: *PageBuilder, id: ChunkId) !void {
        const graph = self.references.graph orelse {
            try page.line(if (self.references.failed) "chunk reference index unavailable" else "indexing the chunk reference graph asynchronously…", .none);
            return;
        };
        const outgoing = graph.outgoing(id);
        try page.line(try std.fmt.allocPrint(page.arena, "outgoing ({d})", .{outgoing.len}), .none);
        for (outgoing) |target| try self.appendChunkLabel(page, "  →", target);

        const incoming = graph.incoming(id);
        try page.line(try std.fmt.allocPrint(page.arena, "incoming ({d})", .{incoming.len}), .none);
        for (incoming) |source| try self.appendChunkLabel(page, "  ←", source);
        if (self.references.failed) {
            try page.line("reference update failed; showing the previous graph", .none);
        } else if (self.references.indexing) {
            try page.line("updating references for newly compiled chunks…", .none);
        }
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

    fn appendSourceExcerpt(self: *Tui, document: *PageBuilder, source: []const u8, span: bytecode.Chunk.SourceSpan) !void {
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
            const shown_end = @min(line_end, cursor +| 4096);
            const selected: ?source_render.Range = if (active) blk: {
                const selected_start = @max(cursor, focus_start);
                const selected_end = @min(shown_end, @max(focus_end, focus_start +| 1));
                if (selected_start >= selected_end) break :blk null;
                break :blk .{ .start = selected_start - cursor, .end = selected_end - cursor };
            } else null;
            try source_render.writeLine(&rendered.writer, source[cursor..shown_end], .{
                .color_depth = self.color_depth,
                .focus = selected,
            });
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
        const cols = @max(@as(usize, 1), self.viewport.cols);
        const body_rows = self.viewport.rows;
        const split = cols >= 96;
        const sidebar_width = if (split) @max(cols * 3 / 10, 28) else 0;
        const source_split = split and cols >= 140 and self.currentChunk() != null and self.navigation.panel == .source;
        const inspector_width = if (split) cols - sidebar_width - 1 else cols;
        const source_width = if (source_split) @max(cols * 3 / 10, 42) else 0;
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
        return self.navigation.back.items[self.navigation.back.items.len - 1].kind;
    }

    fn currentChunk(self: *const Tui) ?ChunkId {
        return switch (self.currentKind()) {
            .chunk => |id| id,
            .heap, .object, .help => null,
        };
    }

    fn currentHeap(self: *const Tui) ?HeapView {
        return switch (self.currentKind()) {
            .heap => |view| view,
            else => null,
        };
    }

    fn currentObject(self: *const Tui) ?runtime.types.ObjectId {
        return switch (self.currentKind()) {
            .object => |id| id,
            else => null,
        };
    }

    fn rebuildTreeForCurrent(self: *Tui) !void {
        try self.rebuildTree(self.currentChunk() orelse std.math.maxInt(ChunkId));
    }

    fn expandFocusedPath(self: *Tui, chunk_id: ChunkId) !void {
        self.tree.categories[@intFromEnum(Category.bytecode)] = true;
        self.tree.focus_path.clearRetainingCapacity();
        try self.tree.focus_path.put(self.allocator, vm_tree.root_node_id, {});
        var name = self.tree_index.nodeForChunk(chunk_id);
        while (name != vm_tree.root_node_id) {
            try self.tree.focus_path.put(self.allocator, name, {});
            name = (self.tree_index.node(name) orelse break).parent;
        }
    }

    fn rebuildTree(self: *Tui, focused_chunk: ChunkId) !void {
        self.tree.rows.clearRetainingCapacity();
        try self.tree.rows.append(self.allocator, .{ .category = .{ .kind = .heap, .depth = 0 } });
        const heap_open = self.tree.categories[@intFromEnum(Category.heap)];
        if (heap_open or self.currentObject() != null) {
            for (std.meta.tags(HeapView)) |view| {
                if (!heap_open and view != .objects) continue;
                try self.tree.rows.append(self.allocator, .{ .heap = .{ .view = view, .depth = 1 } });
                if (view == .objects and (self.tree.heap_views[@intFromEnum(view)] or self.currentObject() != null)) {
                    if (self.heap_index.objects) |*snapshot| {
                        try self.appendObjectRange(
                            snapshot,
                            0,
                            snapshot.high_water,
                            2,
                            !heap_open or !self.tree.heap_views[@intFromEnum(view)],
                        );
                    }
                }
            }
        }
        try self.tree.rows.append(self.allocator, .{ .category = .{ .kind = .bytecode, .depth = 0 } });
        if (self.tree.categories[@intFromEnum(Category.bytecode)]) {
            try self.appendNameRows(vm_tree.root_node_id, 1, focused_chunk);
        } else if (self.currentChunk() != null) {
            try self.appendFocusedNameRows(vm_tree.root_node_id, 1, focused_chunk);
        }
        self.navigation.tree_selection = 0;
        for (self.tree.rows.items, 0..) |row, i| switch (row) {
            .chunk => |entry| if (entry.id == focused_chunk) {
                self.navigation.tree_selection = i;
                break;
            },
            .object => |entry| if (entry.id == self.currentObject()) {
                self.navigation.tree_selection = i;
                break;
            },
            .heap => |entry| if (self.currentHeap() == entry.view) {
                self.navigation.tree_selection = i;
                break;
            },
            else => {},
        };
    }

    fn appendFocusedNameRows(self: *Tui, name: u32, depth: u16, focused_chunk: ChunkId) std.mem.Allocator.Error!void {
        const children = self.tree_index.childrenOf(name);
        const chunks = self.tree_index.chunksOf(name);
        if (name != vm_tree.root_node_id and children.len == 0 and chunks.len == 1) {
            try self.tree.rows.append(self.allocator, .{ .chunk = .{ .id = chunks[0], .depth = depth, .label = name } });
            return;
        }
        try self.tree.rows.append(self.allocator, .{ .name = .{ .id = name, .depth = depth } });
        const next_depth = depth +| 1;
        for (children) |child| {
            if (self.tree.focus_path.contains(child)) try self.appendFocusedNameRows(child, next_depth, focused_chunk);
        }
        if (self.tree_index.nodeForChunk(focused_chunk) == name and self.ev.getChunk(focused_chunk) != null) {
            try self.tree.rows.append(self.allocator, .{ .chunk = .{ .id = focused_chunk, .depth = next_depth } });
        }
    }

    fn appendObjectRange(
        self: *Tui,
        snapshot: *const runtime.ObjectHeap.ObjectSnapshot,
        start: u32,
        len: u32,
        depth: u16,
        projected_only: bool,
    ) std.mem.Allocator.Error!void {
        if (len == 0) return;
        const end = start + len;
        const focused = self.currentObject();
        if (len <= range_leaf) {
            if (projected_only) {
                if (focused) |id| if (id >= start and id < end and snapshot.isLive(id)) {
                    try self.tree.rows.append(self.allocator, .{ .object = .{ .id = id, .depth = depth } });
                };
                return;
            }
            var next = snapshot.nextLive(start);
            while (next) |id| : (next = snapshot.nextLive(id + 1)) {
                if (id >= end) break;
                try self.tree.rows.append(self.allocator, .{ .object = .{ .id = id, .depth = depth } });
            }
            return;
        }

        var span: u32 = range_leaf;
        while ((len + span - 1) / span > 64) span *= 64;
        var offset: u32 = 0;
        while (offset < len) : (offset += span) {
            const child_start = start + offset;
            const child_len = @min(span, len - offset);
            const child_end = child_start + child_len;
            const contains_focus = if (focused) |id| id >= child_start and id < child_end else false;
            if (projected_only and !contains_focus) continue;
            const first_live = snapshot.nextLive(child_start) orelse continue;
            if (first_live >= child_end) continue;
            const range: Range = .{
                .kind = .objects,
                .parent = 0,
                .start = child_start,
                .len = child_len,
                .depth = depth,
            };
            try self.tree.rows.append(self.allocator, .{ .range = range });
            if (self.tree.expanded_ranges.contains(range.key())) {
                try self.appendObjectRange(snapshot, child_start, child_len, depth +| 1, false);
            } else if (contains_focus) {
                try self.appendObjectRange(snapshot, child_start, child_len, depth +| 1, true);
            }
        }
    }

    fn appendNameRows(self: *Tui, name: u32, depth: u16, focused_chunk: ChunkId) std.mem.Allocator.Error!void {
        const children = self.tree_index.childrenOf(name);
        const chunks = self.tree_index.chunksOf(name);
        if (name != vm_tree.root_node_id and children.len == 0 and chunks.len == 1) {
            try self.tree.rows.append(self.allocator, .{ .chunk = .{ .id = chunks[0], .depth = depth, .label = name } });
            return;
        }
        try self.tree.rows.append(self.allocator, .{ .name = .{ .id = name, .depth = depth } });
        const next_depth = depth +| 1;
        if (!self.tree.expanded_names.contains(name)) {
            if (!self.tree.focus_path.contains(name)) return;
            for (children) |child| {
                if (self.tree.focus_path.contains(child)) try self.appendNameRows(child, next_depth, focused_chunk);
            }
            if (self.tree_index.nodeForChunk(focused_chunk) == name and self.ev.getChunk(focused_chunk) != null) {
                try self.tree.rows.append(self.allocator, .{ .chunk = .{ .id = focused_chunk, .depth = next_depth } });
            }
            return;
        }
        try self.appendNameRange(name, children, 0, @intCast(children.len), next_depth, focused_chunk);
        try self.appendChunkRange(name, chunks, 0, @intCast(chunks.len), next_depth, focused_chunk);
    }

    fn appendNameRange(
        self: *Tui,
        parent: u32,
        children: []const u32,
        start: u32,
        len: u32,
        depth: u16,
        focused_chunk: ChunkId,
    ) std.mem.Allocator.Error!void {
        if (len == 0) return;
        if (len <= range_leaf) {
            for (children[start .. start + len]) |child| {
                if (self.tree_index.statsOf(child).chunks == 0) continue;
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
            try self.tree.rows.append(self.allocator, .{ .range = range });
            var contains_focus = false;
            for (children[range.start .. range.start + range.len]) |child| {
                if (self.tree.focus_path.contains(child)) {
                    contains_focus = true;
                    break;
                }
            }
            if (contains_focus or self.tree.expanded_ranges.contains(range.key())) {
                try self.appendNameRange(parent, children, range.start, range.len, depth +| 1, focused_chunk);
            }
        }
    }

    fn appendChunkRange(
        self: *Tui,
        parent: u32,
        chunks: []const ChunkId,
        start: u32,
        len: u32,
        depth: u16,
        focused_chunk: ChunkId,
    ) std.mem.Allocator.Error!void {
        if (len == 0) return;
        if (len <= range_leaf) {
            for (chunks[start .. start + len]) |id| {
                try self.tree.rows.append(self.allocator, .{ .chunk = .{ .id = id, .depth = depth } });
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
            try self.tree.rows.append(self.allocator, .{ .range = range });
            const slice = chunks[range.start .. range.start + range.len];
            if (std.mem.indexOfScalar(ChunkId, slice, focused_chunk) != null or self.tree.expanded_ranges.contains(range.key())) {
                try self.appendChunkRange(parent, chunks, range.start, range.len, depth +| 1, focused_chunk);
            }
        }
    }

    fn moveTree(self: *Tui, forward: bool) void {
        const count = self.tree.rows.items.len;
        if (count == 0) return;
        if (forward) {
            self.navigation.tree_selection = @min(self.navigation.tree_selection + 1, count - 1);
        } else {
            self.navigation.tree_selection -|= 1;
        }
    }

    fn activateTreeRow(self: *Tui) !void {
        if (self.navigation.tree_selection >= self.tree.rows.items.len) return;
        switch (self.tree.rows.items[self.navigation.tree_selection]) {
            .category => |entry| {
                const index = @intFromEnum(entry.kind);
                self.tree.categories[index] = !self.tree.categories[index];
                try self.rebuildTreeForCurrent();
                for (self.tree.rows.items, 0..) |row, i| switch (row) {
                    .category => |candidate| if (candidate.kind == entry.kind) {
                        self.navigation.tree_selection = i;
                        break;
                    },
                    else => {},
                };
            },
            .name => |entry| {
                if (self.tree.expanded_names.remove(entry.id)) {
                    // collapsed
                } else {
                    try self.tree.expanded_names.put(self.allocator, entry.id, {});
                }
                try self.rebuildTreeForCurrent();
                for (self.tree.rows.items, 0..) |row, i| switch (row) {
                    .name => |candidate| if (candidate.id == entry.id) {
                        self.navigation.tree_selection = i;
                        break;
                    },
                    else => {},
                };
            },
            .chunk => |entry| try self.open(.{ .chunk = entry.id }),
            .heap => |entry| {
                if (entry.view == .objects) {
                    const index = @intFromEnum(entry.view);
                    self.tree.heap_views[index] = !self.tree.heap_views[index];
                }
                try self.open(.{ .heap = entry.view });
                try self.rebuildTreeForCurrent();
            },
            .object => |entry| try self.open(.{ .object = entry.id }),
            .range => |range| {
                if (!self.tree.expanded_ranges.remove(range.key())) try self.tree.expanded_ranges.put(self.allocator, range.key(), {});
                try self.rebuildTreeForCurrent();
                for (self.tree.rows.items, 0..) |row, i| switch (row) {
                    .range => |candidate| if (candidate.key() == range.key()) {
                        self.navigation.tree_selection = i;
                        break;
                    },
                    else => {},
                };
            },
        }
    }

    fn collapseTreeRow(self: *Tui) !void {
        if (self.navigation.tree_selection >= self.tree.rows.items.len) return;
        const selected = self.tree.rows.items[self.navigation.tree_selection];
        switch (selected) {
            .category => |entry| {
                const index = @intFromEnum(entry.kind);
                if (self.tree.categories[index]) {
                    self.tree.categories[index] = false;
                    try self.rebuildTreeForCurrent();
                    for (self.tree.rows.items, 0..) |row, i| switch (row) {
                        .category => |candidate| if (candidate.kind == entry.kind) {
                            self.navigation.tree_selection = i;
                            return;
                        },
                        else => {},
                    };
                }
                return;
            },
            .heap => |entry| {
                if (entry.view == .objects and self.tree.heap_views[@intFromEnum(HeapView.objects)]) {
                    self.tree.heap_views[@intFromEnum(HeapView.objects)] = false;
                    try self.rebuildTreeForCurrent();
                    return;
                }
                for (self.tree.rows.items, 0..) |row, i| switch (row) {
                    .category => |candidate| if (candidate.kind == .heap) {
                        self.navigation.tree_selection = i;
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
            if (self.tree.expanded_ranges.remove(range.key())) {
                try self.rebuildTreeForCurrent();
                for (self.tree.rows.items, 0..) |row, i| switch (row) {
                    .range => |candidate| if (candidate.key() == range.key()) {
                        self.navigation.tree_selection = i;
                        return;
                    },
                    else => {},
                };
            }
            if (range.kind == .objects) {
                const selected_depth = range.depth;
                var cursor = self.navigation.tree_selection;
                while (cursor > 0) {
                    cursor -= 1;
                    const candidate = self.tree.rows.items[cursor];
                    if (treeRowDepth(candidate) >= selected_depth) continue;
                    self.navigation.tree_selection = cursor;
                    return;
                }
                return;
            }
            for (self.tree.rows.items, 0..) |row, i| switch (row) {
                .name => |entry| if (entry.id == range.parent) {
                    self.navigation.tree_selection = i;
                    return;
                },
                else => {},
            };
            return;
        }
        const name: u32 = switch (selected) {
            .name => |entry| entry.id,
            .chunk => |entry| self.tree_index.nodeForChunk(entry.id),
            .object => {
                var cursor = self.navigation.tree_selection;
                while (cursor > 0) {
                    cursor -= 1;
                    if (self.tree.rows.items[cursor] == .range) {
                        self.navigation.tree_selection = cursor;
                        return;
                    }
                }
                return;
            },
            .range => unreachable,
            .category, .heap => unreachable,
        };
        if (self.tree.expanded_names.remove(name)) {
            const focused = self.currentChunk() orelse 0;
            try self.rebuildTree(focused);
            for (self.tree.rows.items, 0..) |row, i| switch (row) {
                .name => |entry| if (entry.id == name) {
                    self.navigation.tree_selection = i;
                    break;
                },
                else => {},
            };
            return;
        }
        const parent = (self.tree_index.node(name) orelse return).parent;
        for (self.tree.rows.items, 0..) |row, i| switch (row) {
            .name => |entry| if (entry.id == parent) {
                self.navigation.tree_selection = i;
                return;
            },
            else => {},
        };
    }

    fn open(self: *Tui, kind: Visit.Kind) !void {
        // Save current position into the top-of-stack visit.
        if (self.navigation.back.items.len > 0) {
            const top = &self.navigation.back.items[self.navigation.back.items.len - 1];
            top.scroll = self.navigation.scroll;
            top.tree_selection = self.navigation.tree_selection;
            top.detail_selection = self.navigation.detail_selection;
            top.x_scroll = self.navigation.x_scroll;
        }
        try self.navigation.back.append(self.allocator, .{ .kind = kind });
        self.navigation.forward.clearRetainingCapacity();
        try self.refreshPage(kind);
        self.navigation.scroll = 0;
        self.navigation.detail_selection = self.firstActionableRow() orelse 0;
        switch (kind) {
            .chunk => |id| {
                try self.expandFocusedPath(id);
                try self.rebuildTree(id);
            },
            .object => {
                self.tree.categories[@intFromEnum(Category.heap)] = true;
                try self.rebuildTreeForCurrent();
            },
            .heap => {
                self.tree.categories[@intFromEnum(Category.heap)] = true;
                try self.rebuildTreeForCurrent();
            },
            .help => {},
        }
        self.navigation.x_scroll = 0;
        switch (kind) {
            .help => self.navigation.focus = .disassembly,
            .heap, .object => self.navigation.focus = .disassembly,
            .chunk => {},
        }
        self.status_msg = "";
    }

    fn back(self: *Tui) !void {
        if (self.navigation.back.items.len < 2) {
            self.status_msg = "(bottom of history)";
            return;
        }
        try self.navigation.forward.append(self.allocator, self.navigation.back.pop().?);
        const visit = self.navigation.back.items[self.navigation.back.items.len - 1];
        try self.refreshPage(visit.kind);
        switch (visit.kind) {
            .chunk => |id| try self.expandFocusedPath(id),
            else => {},
        }
        try self.rebuildTreeForCurrent();
        self.navigation.scroll = visit.scroll;
        self.navigation.tree_selection = visit.tree_selection;
        self.navigation.detail_selection = visit.detail_selection;
        self.navigation.x_scroll = visit.x_scroll;
        self.status_msg = "";
    }

    fn goForward(self: *Tui) !void {
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
        try self.refreshPage(visit.kind);
        switch (visit.kind) {
            .chunk => |id| try self.expandFocusedPath(id),
            else => {},
        }
        try self.rebuildTreeForCurrent();
        self.navigation.scroll = visit.scroll;
        self.navigation.tree_selection = visit.tree_selection;
        self.navigation.detail_selection = visit.detail_selection;
        self.navigation.x_scroll = visit.x_scroll;
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
        if (self.navigation.scroll > self.maxScroll()) self.navigation.scroll = self.maxScroll();
    }

    fn maxXScroll(self: *const Tui) usize {
        var widest: usize = 0;
        for (self.page.lines) |line| widest = @max(widest, tui.displayWidth(line, width_mod.cpWidth));
        return widest -| self.layout().main_width;
    }

    fn rowActionable(self: *const Tui, index: usize) bool {
        if (index >= self.page.actions.len) return false;
        if (index < self.page.locations.len and self.page.locations[index] != null) return true;
        return switch (self.page.actions[index]) {
            .chunk, .object, .instruction => true,
            .none, .heading => false,
        };
    }

    fn firstActionableRow(self: *const Tui) ?usize {
        for (self.page.actions, 0..) |action, i| switch (action) {
            .chunk, .object, .instruction => return i,
            .none, .heading => if (i < self.page.locations.len and self.page.locations[i] != null) return i,
        };
        return null;
    }

    fn toggleSelectedBreakpoint(self: *Tui) !void {
        if (self.navigation.focus != .disassembly) {
            self.status_msg = "(focus the code pane first)";
            return;
        }
        if (self.navigation.detail_selection >= self.page.locations.len) {
            self.status_msg = "(select an instruction with source)";
            return;
        }
        const location = self.page.locations[self.navigation.detail_selection] orelse {
            self.status_msg = "(selected row has no source location)";
            return;
        };
        for (self.ev.listBreakpoints()) |breakpoint| {
            if (breakpoint.line == location.line and sourceFileMatches(breakpoint.file, location.file)) {
                _ = self.ev.deleteBreakpoint(breakpoint.id);
                self.status_msg = std.fmt.bufPrint(&self.status_buf, "cleared breakpoint {d} at {s}:{d}", .{
                    breakpoint.id,
                    std.fs.path.basename(location.file),
                    location.line,
                }) catch "cleared breakpoint";
                return;
            }
        }
        const result = self.ev.setBreakpoint(location.file, location.line) catch |err| {
            self.status_msg = std.fmt.bufPrint(&self.status_buf, "breakpoint failed: {s}", .{@errorName(err)}) catch "breakpoint failed";
            return;
        };
        self.status_msg = std.fmt.bufPrint(&self.status_buf, "breakpoint {d} at {s}:{d}", .{
            result.id,
            std.fs.path.basename(location.file),
            result.line,
        }) catch "breakpoint set";
    }

    fn moveDetail(self: *Tui, forward: bool) void {
        if (self.page.actions.len == 0) return;
        var cursor = self.navigation.detail_selection;
        while (true) {
            if (forward) {
                if (cursor + 1 >= self.page.actions.len) return;
                cursor += 1;
            } else {
                if (cursor == 0) return;
                cursor -= 1;
            }
            if (self.rowActionable(cursor)) {
                self.navigation.detail_selection = cursor;
                self.ensureDetailVisible();
                return;
            }
        }
    }

    fn ensureDetailVisible(self: *Tui) void {
        const rows = self.contentRows();
        if (rows == 0) return;
        if (self.navigation.detail_selection < self.navigation.scroll) self.navigation.scroll = self.navigation.detail_selection;
        if (self.navigation.detail_selection >= self.navigation.scroll + rows) self.navigation.scroll = self.navigation.detail_selection - rows + 1;
        self.clampScroll();
    }

    fn selectPanel(self: *Tui, panel: Panel) !void {
        if (self.currentChunk() == null) return;
        self.navigation.panel = panel;
        try self.refreshPage(self.currentKind());
        self.navigation.focus = .disassembly;
    }

    fn activateDetailRow(self: *Tui) !void {
        if (self.navigation.detail_selection >= self.page.actions.len) return;
        switch (self.page.actions[self.navigation.detail_selection]) {
            .chunk => |id| try self.open(.{ .chunk = id }),
            .object => |id| try self.open(.{ .object = id }),
            .none, .heading, .instruction => {},
        }
    }

    fn toggleHelp(self: *Tui) !void {
        if (self.currentKind() == .help and self.navigation.back.items.len > 1) {
            try self.back();
        } else if (self.currentKind() != .help) {
            try self.open(.help);
        }
    }

    fn handleKey(self: *Tui, key: keys_mod.Key) !bool {
        self.status_msg = "";
        if (key.isCtrl('c') or key.isCtrl('d')) return false;
        switch (key.code) {
            .cp => |cp| switch (cp) {
                'q' => return false,
                'j' => {
                    if (self.navigation.focus == .chunks) {
                        self.moveTree(true);
                    } else {
                        self.moveDetail(true);
                    }
                },
                'k' => {
                    if (self.navigation.focus == .chunks) {
                        self.moveTree(false);
                    } else {
                        self.moveDetail(false);
                    }
                },
                'd' => {
                    if (self.navigation.focus == .disassembly) self.navigation.scroll = @min(self.navigation.scroll + self.contentRows() / 2, self.maxScroll());
                },
                'u' => {
                    if (self.navigation.focus == .disassembly) self.navigation.scroll -|= self.contentRows() / 2;
                },
                'g' => {
                    if (self.navigation.focus == .chunks) {
                        self.navigation.tree_selection = 0;
                    } else {
                        self.navigation.detail_selection = self.firstActionableRow() orelse 0;
                        self.ensureDetailVisible();
                    }
                },
                'G' => {
                    if (self.navigation.focus == .chunks) {
                        self.navigation.tree_selection = self.tree.rows.items.len -| 1;
                    } else {
                        var row = self.page.actions.len;
                        while (row > 0) {
                            row -= 1;
                            if (self.rowActionable(row)) {
                                self.navigation.detail_selection = row;
                                break;
                            }
                        }
                        self.ensureDetailVisible();
                    }
                },
                'h' => {
                    if (self.navigation.focus == .disassembly) self.navigation.x_scroll -|= 4;
                },
                'l' => {
                    if (self.navigation.focus == .disassembly) self.navigation.x_scroll = @min(self.navigation.x_scroll + 4, self.maxXScroll());
                },
                'b' => try self.back(),
                'f' => try self.goForward(),
                'c' => try self.selectPanel(.code),
                't' => try self.selectPanel(.tables),
                's' => try self.selectPanel(.source),
                'r' => try self.selectPanel(.references),
                'p' => try self.toggleSelectedBreakpoint(),
                '?' => try self.toggleHelp(),
                '/' => {
                    if (self.navigation.focus == .disassembly) try self.searchPrompt();
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
                if (self.navigation.focus == .chunks) self.moveTree(false) else self.moveDetail(false);
            },
            .down => {
                if (self.navigation.focus == .chunks) {
                    self.moveTree(true);
                } else {
                    self.moveDetail(true);
                }
            },
            .left => {
                if (self.navigation.focus == .chunks) try self.collapseTreeRow() else self.navigation.x_scroll -|= 4;
            },
            .right => {
                if (self.navigation.focus == .chunks) {
                    try self.activateTreeRow();
                } else {
                    self.navigation.x_scroll = @min(self.navigation.x_scroll + 4, self.maxXScroll());
                }
            },
            .page_up => {
                if (self.navigation.focus == .disassembly) self.navigation.scroll -|= self.contentRows();
            },
            .page_down => {
                if (self.navigation.focus == .disassembly) self.navigation.scroll = @min(self.navigation.scroll + self.contentRows(), self.maxScroll());
            },
            .home => {
                if (self.navigation.focus == .chunks) self.navigation.tree_selection = 0 else {
                    self.navigation.detail_selection = self.firstActionableRow() orelse 0;
                    self.ensureDetailVisible();
                }
            },
            .end => {
                if (self.navigation.focus == .chunks) self.navigation.tree_selection = self.tree.rows.items.len -| 1 else self.navigation.scroll = self.maxScroll();
            },
            .tab, .backtab => {
                if (self.navigation.focus == .chunks) {
                    self.navigation.focus = .disassembly;
                } else {
                    self.navigation.focus = .chunks;
                }
            },
            .enter => {
                if (self.navigation.focus == .chunks) try self.activateTreeRow() else try self.activateDetailRow();
            },
            .escape => return false,
            else => {},
        }
        return true;
    }

    /// Modal one-line search input on the status row.
    fn searchPrompt(self: *Tui) !void {
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
                        self.findNext(1);
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

    fn findNext(self: *Tui, dir: i2) void {
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
                self.navigation.scroll = @min(line_idx, self.maxScroll());
                return;
            }
        }
        self.status_msg = "(not found)";
    }

    // -- drawing -----------------------------------------------------------------

    fn drawSession(
        self: *Tui,
        arena: std.mem.Allocator,
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

        if (explorer_rows > 0 and (self.viewport.cols != cols or self.viewport.rows != explorer_rows)) {
            self.viewport.cols = cols;
            self.viewport.rows = explorer_rows;
            try self.refreshPage(self.currentKind());
        }

        var header_buf: [512]u8 = undefined;
        const header = if (self.currentChunk()) |id|
            std.fmt.bufPrint(&header_buf, " fix vm  ·  chunk #0x{x}  ·  {s} ", .{
                id,
                if (prompt_active) "repl" else if (self.navigation.focus == .chunks) "tree" else "inspector",
            }) catch " fix repl "
        else if (self.currentHeap()) |view|
            std.fmt.bufPrint(&header_buf, " fix vm  ·  heap/{s}  ·  {s} ", .{
                @tagName(view),
                if (prompt_active) "repl" else if (self.navigation.focus == .chunks) "tree" else "inspector",
            }) catch " fix vm "
        else if (self.currentObject()) |id|
            std.fmt.bufPrint(&header_buf, " fix vm  ·  object #{d}  ·  {s} ", .{
                id,
                if (prompt_active) "repl" else if (self.navigation.focus == .chunks) "tree" else "inspector",
            }) catch " fix vm "
        else
            std.fmt.bufPrint(&header_buf, " fix vm  ·  help  ·  {s} ", .{
                if (prompt_active) "repl" else if (self.navigation.focus == .chunks) "tree" else "inspector",
            }) catch " fix vm ";
        try frame.bar(1, header, cols, .header);

        if (explorer_rows > 0) {
            try self.drawExplorerBody(arena, &frame, 2, explorer_rows, cols);
            const separator_row = 2 + explorer_rows;
            try frame.clearRow(separator_row);
            const separator = if (self.tree.indexing)
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
            std.fmt.bufPrint(&footer_buf, " q/Esc exit · i expression · : command · Tab pane · c/t/s/r panel · p breakpoint · ↵ inspect{s} ", .{
                if (self.tree.indexing) " · indexing" else "",
            }) catch " q exit ";
        try frame.bar(screen_rows, footer, cols, .footer);

        prompt_renderer.invalidate();
        if (prompt_active) {
            try frame.at(prompt_start, 1);
            try frame.cursor(true);
            try prompt_renderer.draw(w, prompt_view);
        } else {
            try frame.cursor(false);
        }
    }

    fn drawExplorerBody(self: *Tui, arena: std.mem.Allocator, frame: *tui.Frame, first_row: usize, rows: usize, cols: usize) !void {
        const layout_now = self.layout();
        self.clampScroll();
        self.navigation.tree_selection = @min(self.navigation.tree_selection, self.tree.rows.items.len -| 1);
        for (0..rows) |row| {
            const screen_row = first_row + row;
            try frame.clearRow(screen_row);
            if (layout_now.split) {
                try frame.at(screen_row, 1);
                try self.drawChunkRow(arena, frame, row, layout_now.sidebar_width, rows);
                try frame.divider(screen_row, layout_now.sidebar_width + 1);
                try frame.at(screen_row, layout_now.main_col);
                try self.drawDisasmRow(frame, row, layout_now.main_width);
                if (layout_now.source_split) {
                    try frame.divider(screen_row, layout_now.source_col - 1);
                    try frame.at(screen_row, layout_now.source_col);
                    try self.drawSourceRow(frame, row, layout_now.source_width);
                }
            } else if (self.navigation.focus == .chunks) {
                try frame.at(screen_row, 1);
                try self.drawChunkRow(arena, frame, row, cols, rows);
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

    fn drawDisasmRow(self: *Tui, frame: *tui.Frame, row: usize, width: usize) !void {
        const idx = self.navigation.scroll + row;
        if (idx < self.page.lines.len) {
            const selected = idx == self.navigation.detail_selection and self.navigation.focus == .disassembly and self.rowActionable(idx);
            const breakpoint = idx < self.page.locations.len and if (self.page.locations[idx]) |location| self.hasBreakpoint(location) else false;
            if ((selected or breakpoint) and width >= 2) {
                try frame.text(if (selected and breakpoint) "◆ " else if (selected) "› " else "● ", 0, 2, if (selected) .selection_marker else .current);
                try frame.text(self.page.lines[idx], self.navigation.x_scroll, width - 2, self.detailRole(idx));
            } else {
                try frame.text(self.page.lines[idx], self.navigation.x_scroll, width, self.detailRole(idx));
            }
        } else if (idx == self.page.lines.len and self.page.lines.len != 0) {
            try frame.text("(end)", 0, width, .muted);
        }
    }

    fn hasBreakpoint(self: *const Tui, location: BreakpointLocation) bool {
        for (self.ev.listBreakpoints()) |breakpoint| {
            if (breakpoint.line == location.line and sourceFileMatches(breakpoint.file, location.file)) return true;
        }
        return false;
    }

    fn detailRole(self: *const Tui, index: usize) tui.Role {
        if (index < self.page.actions.len) switch (self.page.actions[index]) {
            .heading => return .section,
            .chunk, .object => return .chunk,
            .none, .instruction => {},
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
            .object => |entry| entry.depth,
        };
    }

    fn treeViewport(self: *const Tui, slots: usize) TreeViewport {
        var result: TreeViewport = .{};
        const count = self.tree.rows.items.len;
        if (slots == 0 or count == 0) return result;

        var normal_slots = slots;
        var pass: usize = 0;
        while (pass < 2) : (pass += 1) {
            result.start = @min(self.navigation.tree_selection -| (normal_slots / 2), count -| normal_slots);
            var hidden_nearest: [64]usize = undefined;
            const hidden_count = self.hiddenTreeAncestors(result.start, &hidden_nearest);
            result.pin_count = @min(@min(hidden_count, hidden_nearest.len), slots -| 1);
            var i: usize = 0;
            while (i < result.pin_count) : (i += 1) {
                result.pinned[i] = hidden_nearest[result.pin_count - i - 1];
            }
            normal_slots = slots - result.pin_count;
        }
        result.start = @min(self.navigation.tree_selection -| (normal_slots / 2), count -| normal_slots);
        return result;
    }

    /// Collect off-screen ancestors nearest-first. Keeping the nearest entries
    /// means very deep trees degrade into a useful partial breadcrumb.
    fn hiddenTreeAncestors(self: *const Tui, start: usize, out: *[64]usize) usize {
        if (self.navigation.tree_selection >= self.tree.rows.items.len) return 0;
        var wanted_depth = treeRowDepth(self.tree.rows.items[self.navigation.tree_selection]);
        var cursor = self.navigation.tree_selection;
        var count: usize = 0;
        while (cursor > 0 and wanted_depth > 0) {
            cursor -= 1;
            const depth = treeRowDepth(self.tree.rows.items[cursor]);
            if (depth >= wanted_depth) continue;
            if (cursor < start and count < out.len) {
                out[count] = cursor;
                count += 1;
            }
            wanted_depth = depth;
        }
        return count;
    }

    const TreeCell = struct {
        index: usize,
        segment: usize,
        pinned: bool,
        wrapped: bool,
    };

    /// Map one physical sidebar row to a logical tree row. Selected rows and
    /// pinned breadcrumbs may consume several rows; ordinary rows stay one
    /// line and are middle-ellipsized by the renderer below.
    fn treeCell(self: *const Tui, slot: usize, width: usize, slots: usize) ?TreeCell {
        const viewport = self.treeViewport(slots);
        var pin_start: usize = 0;
        var pin_height: usize = 0;
        for (viewport.pinned[0..viewport.pin_count]) |index| pin_height += self.treeDisplayHeight(index, width, slots, true);
        const selected_height = self.treeDisplayHeight(self.navigation.tree_selection, width, slots, false);
        while (pin_start < viewport.pin_count and pin_height + selected_height > slots) : (pin_start += 1) {
            pin_height -|= self.treeDisplayHeight(viewport.pinned[pin_start], width, slots, true);
        }

        var normal_start = viewport.start;
        var before_selected = self.navigation.tree_selection -| normal_start;
        while (normal_start < self.navigation.tree_selection and pin_height + before_selected + selected_height > slots) {
            normal_start += 1;
            before_selected -|= 1;
        }

        var physical: usize = 0;
        for (viewport.pinned[pin_start..viewport.pin_count]) |index| {
            const height = self.treeDisplayHeight(index, width, slots, true);
            if (slot < physical + height) return .{
                .index = index,
                .segment = slot - physical,
                .pinned = true,
                .wrapped = height > 1,
            };
            physical += height;
        }

        var index = normal_start;
        while (index < self.tree.rows.items.len and physical < slots) : (index += 1) {
            const height = self.treeDisplayHeight(index, width, slots, false);
            if (slot < physical + height) return .{
                .index = index,
                .segment = slot - physical,
                .pinned = false,
                .wrapped = height > 1,
            };
            physical += height;
        }
        return null;
    }

    fn treeDisplayHeight(self: *const Tui, index: usize, width: usize, slots: usize, pinned: bool) usize {
        if (index >= self.tree.rows.items.len or width < 8) return 1;
        const selected = index == self.navigation.tree_selection and self.navigation.focus == .chunks;
        if (!pinned and !selected) return 1;
        const content_width = self.longTreeContentWidth(self.tree.rows.items[index]) orelse return 1;
        const prefix = @min(1 + @as(usize, treeRowDepth(self.tree.rows.items[index])) * 2 + 2, width - 1);
        const available = width - prefix;
        const height = @max(@as(usize, 1), (content_width + available - 1) / available);
        const limit = if (pinned) @max(@as(usize, 2), @min(@as(usize, 3), slots / 3)) else @max(@as(usize, 2), slots / 2);
        return @min(height, limit);
    }

    /// Width after indentation/marker for the node rows whose labels may be
    /// arbitrarily long. Other row kinds never need multiline treatment.
    fn longTreeContentWidth(self: *const Tui, row: TreeRow) ?usize {
        var suffix_buf: [96]u8 = undefined;
        var relation_buf: [96]u8 = undefined;
        return switch (row) {
            .name => |entry| blk: {
                const node = self.tree_index.node(entry.id) orelse return null;
                const suffix = std.fmt.bufPrint(&suffix_buf, "  {d}", .{self.tree_index.statsOf(entry.id).chunks}) catch "";
                break :blk width_mod.strWidth(node.label) + width_mod.strWidth(suffix);
            },
            .chunk => |entry| if (entry.label) |node_id| blk: {
                const node = self.tree_index.node(node_id) orelse return null;
                const chunk = self.ev.getChunk(entry.id) orelse return null;
                const relation = self.chunkEquivalenceSuffix(&relation_buf, entry.id);
                const suffix = std.fmt.bufPrint(&suffix_buf, "  #{d} · {Bi}{s}", .{ entry.id, chunk.code.len, relation }) catch "";
                break :blk width_mod.strWidth(node.label) + width_mod.strWidth(suffix);
            } else null,
            else => null,
        };
    }

    fn drawTreeHeader(self: *Tui, frame: *tui.Frame, row: usize, width: usize) !bool {
        var line_buf: [512]u8 = undefined;
        switch (row) {
            0 => {
                const root_stats = self.tree_index.statsOf(vm_tree.root_node_id);
                const heap_counts = self.ev.heapCounts();
                const line = if (self.tree.indexing)
                    std.fmt.bufPrint(&line_buf, " VM STATE · {d} chunks · {d} object slots · indexing…", .{ root_stats.chunks, heap_counts.objects }) catch " VM STATE"
                else
                    std.fmt.bufPrint(&line_buf, " VM STATE · {d} chunks · {d} object slots", .{ root_stats.chunks, heap_counts.objects }) catch " VM STATE";
                try frame.text(line, 0, width, .section);
            },
            1 => {
                const id = self.currentChunk() orelse {
                    if (self.currentObject()) |object_id| {
                        const line = std.fmt.bufPrint(&line_buf, " ● object #{d}", .{object_id}) catch " object";
                        try frame.text(line, 0, width, .current);
                    } else if (self.currentHeap()) |view| {
                        const line = std.fmt.bufPrint(&line_buf, " ● heap/{s}", .{@tagName(view)}) catch " heap";
                        try frame.text(line, 0, width, .current);
                    } else {
                        try frame.text(" help", 0, width, .muted);
                    }
                    return true;
                };
                var relation_buf: [96]u8 = undefined;
                const relation = self.chunkEquivalenceSuffix(&relation_buf, id);
                const line = if (self.ev.getChunk(id)) |chunk|
                    std.fmt.bufPrint(&line_buf, " ● #0x{x}  {d}b · {d}c · a{d}{s}", .{ id, chunk.code.len, chunk.constants.len, chunk.arity, relation }) catch " current chunk"
                else
                    std.fmt.bufPrint(&line_buf, " ● #0x{x}  missing", .{id}) catch " current chunk";
                try frame.text(line, 0, width, .current);
            },
            2 => try frame.text(" ─ runtime state ─", 0, width, .muted),
            else => return false,
        }
        return true;
    }

    fn drawChunkRow(self: *Tui, arena: std.mem.Allocator, frame: *tui.Frame, row: usize, width: usize, rows: usize) !void {
        var line_buf: [512]u8 = undefined;
        if (try self.drawTreeHeader(frame, row, width)) return;

        const count = self.tree.rows.items.len;
        if (count == 0) {
            if (row == 3) try frame.text("   empty registry", 0, width, .muted);
            return;
        }
        const slots = rows -| 3;
        if (slots == 0) return;
        const slot = row - 3;
        const cell = self.treeCell(slot, width, slots) orelse return;
        const index = cell.index;
        if (index >= count) return;
        const pinned = cell.pinned;
        const selected = index == self.navigation.tree_selection;
        const line: []const u8 = switch (self.tree.rows.items[index]) {
            .category => |entry| blk: {
                const is_open = self.tree.categories[@intFromEnum(entry.kind)];
                const projected = !is_open and switch (entry.kind) {
                    .bytecode => self.currentChunk() != null,
                    .heap => self.currentObject() != null,
                };
                break :blk switch (entry.kind) {
                    .bytecode => blk2: {
                        const stats = self.tree_index.statsOf(vm_tree.root_node_id);
                        break :blk2 std.fmt.bufPrint(&line_buf, " {s} BYTECODE  {d} chunks", .{ if (is_open) "▾" else if (projected) "›" else "▸", stats.chunks }) catch " bytecode";
                    },
                    .heap => blk2: {
                        const counts = self.ev.heapCounts();
                        break :blk2 std.fmt.bufPrint(&line_buf, " {s} HEAP  {d} object slots", .{ if (is_open) "▾" else if (projected) "›" else "▸", counts.objects }) catch " heap";
                    },
                };
            },
            .name => |entry| blk: {
                const stats = self.tree_index.statsOf(entry.id);
                var indent: [64]u8 = undefined;
                const indent_len = @min(@as(usize, entry.depth) * 2, indent.len);
                @memset(indent[0..indent_len], ' ');
                const label = if (entry.id == vm_tree.root_node_id)
                    "<root>"
                else if (self.tree_index.node(entry.id)) |node|
                    node.label
                else
                    "?";
                break :blk try std.fmt.allocPrint(arena, " {s}{s} {s}  {d}", .{
                    indent[0..indent_len],
                    if (self.tree.expanded_names.contains(entry.id)) "▾" else if (self.tree.focus_path.contains(entry.id)) "›" else "▸",
                    label,
                    stats.chunks,
                });
            },
            .chunk => |entry| blk: {
                var indent: [64]u8 = undefined;
                const indent_len = @min(@as(usize, entry.depth) * 2, indent.len);
                @memset(indent[0..indent_len], ' ');
                const chunk = self.ev.getChunk(entry.id);
                const label = if (entry.label) |node_id| (self.tree_index.node(node_id) orelse return).label else "";
                var relation_buf: [96]u8 = undefined;
                const relation = self.chunkEquivalenceSuffix(&relation_buf, entry.id);
                break :blk if (chunk) |ch|
                    if (label.len > 0)
                        try std.fmt.allocPrint(arena, " {s}{s} {s}  #{d} · {Bi}{s}", .{
                            indent[0..indent_len],
                            if (self.currentChunk() == entry.id) "●" else "·",
                            label,
                            entry.id,
                            ch.code.len,
                            relation,
                        })
                    else
                        std.fmt.bufPrint(&line_buf, " {s}{s} #{d}  {Bi}{s}", .{
                            indent[0..indent_len],
                            if (self.currentChunk() == entry.id) "●" else "·",
                            entry.id,
                            ch.code.len,
                            relation,
                        }) catch " chunk"
                else
                    std.fmt.bufPrint(&line_buf, " {s}! #{d} missing", .{ indent[0..indent_len], entry.id }) catch " missing";
            },
            .range => |entry| blk: {
                var indent: [64]u8 = undefined;
                const indent_len = @min(@as(usize, entry.depth) * 2, indent.len);
                @memset(indent[0..indent_len], ' ');
                const is_open = self.tree.expanded_ranges.contains(entry.key());
                break :blk switch (entry.kind) {
                    .names => std.fmt.bufPrint(&line_buf, " {s}{s} names {d}–{d}", .{
                        indent[0..indent_len],
                        if (is_open) "▾" else "▸",
                        entry.start + 1,
                        entry.start + entry.len,
                    }) catch " name range",
                    .chunks => blk2: {
                        const chunks = self.tree_index.chunksOf(entry.parent);
                        const first = chunks[entry.start];
                        const last = chunks[entry.start + entry.len - 1];
                        break :blk2 std.fmt.bufPrint(&line_buf, " {s}{s} chunks #{d}–#{d}", .{
                            indent[0..indent_len],
                            if (is_open) "▾" else "▸",
                            first,
                            last,
                        }) catch " chunk range";
                    },
                    .objects => std.fmt.bufPrint(&line_buf, " {s}{s} objects #{d}–#{d}", .{
                        indent[0..indent_len],
                        if (is_open) "▾" else if (self.currentObject()) |id| (if (id >= entry.start and id < entry.start + entry.len) "›" else "▸") else "▸",
                        entry.start,
                        entry.start + entry.len - 1,
                    }) catch " object range",
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
                const marker = if (entry.view == .objects)
                    (if (self.tree.heap_views[@intFromEnum(entry.view)]) "▾" else if (self.currentObject() != null) "›" else "▸")
                else
                    "·";
                break :blk std.fmt.bufPrint(&line_buf, " {s}{s} {s}  {d}", .{ indent[0..indent_len], marker, @tagName(entry.view), store_count }) catch " heap store";
            },
            .object => |entry| blk: {
                var indent: [64]u8 = undefined;
                const indent_len = @min(@as(usize, entry.depth) * 2, indent.len);
                @memset(indent[0..indent_len], ' ');
                const kind = if (self.heap_index.objects) |*snapshot|
                    if (self.ev.inspectHeapObject(snapshot, entry.id)) |info| @tagName(info) else |_| "?"
                else
                    "?";
                break :blk std.fmt.bufPrint(&line_buf, " {s}{s} #{d}  {s}", .{
                    indent[0..indent_len],
                    if (self.currentObject() == entry.id) "●" else "·",
                    entry.id,
                    kind,
                }) catch " object";
            },
        };
        const role: tui.Role = if (selected and self.navigation.focus == .chunks)
            .selection
        else if (pinned)
            .muted
        else switch (self.tree.rows.items[index]) {
            .category => .section,
            .name => .name,
            .chunk => |entry| if (self.currentChunk() == entry.id) .current else .chunk,
            .range => .range,
            .object => |entry| if (self.currentObject() == entry.id) .current else .chunk,
            .heap => |entry| switch (self.currentKind()) {
                .heap => |view| if (view == entry.view) .current else .chunk,
                else => .chunk,
            },
        };
        if (cell.wrapped) {
            const prefix_width = @min(1 + @as(usize, treeRowDepth(self.tree.rows.items[index])) * 2 + 2, width -| 1);
            if (cell.segment == 0) {
                try frame.text(line, 0, width, role);
            } else if (prefix_width < width) {
                const indent = try arena.alloc(u8, prefix_width);
                @memset(indent, ' ');
                try frame.text(indent, 0, prefix_width, role);
                const available = width - prefix_width;
                const start = prefix_width + cell.segment * (width - prefix_width);
                try frame.text(line, start, available, role);
            }
        } else {
            const shown = try width_mod.middleEllipsis(arena, line, width);
            try frame.text(shown, 0, width, role);
        }
    }
};

fn disasmTarget(line: []const u8) RowAction {
    const chunk_prefixes = [_][]const u8{ "chunk[0x", "function[0x" };
    for (chunk_prefixes) |prefix| if (storeRefId(line, prefix)) |id| {
        return .{ .chunk = @intCast(id) };
    };
    const object_prefixes = [_][]const u8{
        "list[0x",
        "attrs[0x",
        "closure[0x",
        "thunk[0x",
        "builtin_closure[0x",
        "string_ctx[0x",
        "boxed_int[0x",
        "partial_app[0x",
    };
    for (object_prefixes) |prefix| if (storeRefId(line, prefix)) |id| {
        return .{ .object = @intCast(id) };
    };
    return .none;
}

fn disasmOffset(chunk: *const bytecode.Chunk, line: []const u8) ?usize {
    const trimmed = std.mem.trimStart(u8, line, " │\t");
    const end = std.mem.indexOfAny(u8, trimmed, " \t") orelse return null;
    const offset = std.fmt.parseInt(usize, trimmed[0..end], 16) catch return null;
    return if (offset < chunk.code.len) offset else null;
}

fn storeRefId(line: []const u8, prefix: []const u8) ?u64 {
    const start = (std.mem.indexOf(u8, line, prefix) orelse return null) + prefix.len;
    const end = std.mem.indexOfScalarPos(u8, line, start, ']') orelse return null;
    return std.fmt.parseInt(u64, line[start..end], 16) catch null;
}

fn sourceFileMatches(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b) or std.mem.eql(u8, std.fs.path.basename(a), std.fs.path.basename(b));
}

test "disassembly targets recognize chunk and heap links" {
    try std.testing.expectEqual(@as(ChunkId, 0x2a), disasmTarget("closure chunk[0x2a]").chunk);
    try std.testing.expectEqual(@as(runtime.types.ObjectId, 0x31), disasmTarget("push thunk[0x31]").object);
    try std.testing.expect(disasmTarget("push str[0x1]") == .none);
}
