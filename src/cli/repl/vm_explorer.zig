//! The integrated VM explorer: tree navigation, inspection, and debugger UI.
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
const vm_jobs = @import("vm_jobs.zig");
const vm_refs = @import("vm_refs.zig");
const vm_tree = @import("vm_tree.zig");
const vm_navigation = @import("vm_navigation.zig");
const history_mod = @import("history.zig");
const source_render = @import("../source_render.zig");
const command_mod = @import("../debugger_command.zig");
const debugger = @import("../debugger.zig");
const base = @import("base");
const tui = base.tui;
const ColorDepth = base.terminal_color.Depth;
const Evaluator = engine.Evaluator;
const DebugSession = engine.DebugSession;
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
        try w.print("chunk[0x{x}] not found\n", .{chunk_id});
        return;
    };
    try disasm.writeChunk(allocator, w, chunk_id, chunk, symbols, options);
}

const Category = enum(u1) { bytecode, heap };
const HeapView = enum { overview, objects, values, attrs, attr_positions, intern, builtin };

const RowAction = union(enum) {
    none,
    section,
    source: ChunkId,
    instruction,
    chunk: ChunkId,
    object: runtime.types.ObjectId,
    store_record: struct { view: HeapView, id: u32 },
};

/// A breakpoint target attached to a rendered row. Instruction rows use the
/// exact `(chunk_id, offset)` site; source rows retain the full span so nested
/// expressions that share an entry offset remain independent.
const BreakpointLocation = struct {
    chunk_id: ChunkId,
    offset: u32,
    file: []const u8 = "",
    line: u32 = 0,
    /// Present on source-span rows so the document's source excerpt can follow
    /// the highlighted sub-expression rather than remaining on the chunk body.
    span: ?bytecode.Chunk.SourceSpan = null,
};

/// One rendered inspector document (or the help screen). Actions are parallel
/// to lines so references remain useful even when the chunk itself is shorter
/// than the viewport.
const Page = struct {
    title: []u8,
    lines: [][]u8,
    actions: []RowAction,
    locations: []const ?BreakpointLocation = &.{},
};

const PageBuilder = struct {
    arena: std.mem.Allocator,
    lines: std.ArrayListUnmanaged([]u8) = .empty,
    actions: std.ArrayListUnmanaged(RowAction) = .empty,
    locations: std.ArrayListUnmanaged(?BreakpointLocation) = .empty,

    fn line(self: *PageBuilder, line_text: []const u8, action: RowAction) !void {
        try self.lineAt(line_text, action, null);
    }

    fn heading(self: *PageBuilder, line_text: []const u8) !void {
        try self.line(line_text, .section);
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
        /// One record in a value/attr/attr-position store.
        store_record: struct { view: HeapView, id: u32 },
        /// A paused stack frame (index into the live `DebugSession`). Only
        /// reachable while `Tui.debug_session != null`.
        debug_frame: usize,
        /// The pause's break/return/error value as a full inspectable subject.
        debug_value,
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
    dbg: ?*VmDebugger,
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
    // Register the live explorer with the persistent debugger so a pause that
    // fires mid-eval borrows this surface instead of opening its own.
    if (dbg) |d| d.active_tui = &explorer;
    defer if (dbg) |d| {
        d.active_tui = null;
    };
    try explorer.runSession(editor, transcript, host);
}

/// Persistent `DebugUi` adapter, owned by the Repl for the whole session. When
/// the evaluator pauses it drives the VM explorer as the single debug surface:
/// reusing the live `:vm` `Tui` if one is open (borrowed screen), or building a
/// throwaway explorer that focuses the paused stack otherwise (owned screen).
pub const VmDebugger = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    ev: *Evaluator,
    color_depth: ColorDepth,
    history: *history_mod.History,
    /// Set by `runSession` for the lifetime of an interactive `:vm` session.
    active_tui: ?*Tui = null,
    /// Owned raw mode / alternate screen for pauses that opened their own
    /// terminal (no `:vm` active). Kept up across consecutive steps so a
    /// step never flickers the screen; closed on continue/abort or when a
    /// straight-through step finishes (`endEvaluation`).
    owned_raw: term_mod.RawMode = .{},
    owned_active: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        ev: *Evaluator,
        color_depth: ColorDepth,
        history: *history_mod.History,
    ) VmDebugger {
        return .{
            .allocator = allocator,
            .io = io,
            .ev = ev,
            .color_depth = color_depth,
            .history = history,
        };
    }

    pub fn install(self: *VmDebugger, ev: *Evaluator) void {
        ev.setDebugUi(self, runCallback);
    }

    pub fn uninstall(_: *VmDebugger, ev: *Evaluator) void {
        ev.clearDebugUi();
    }

    /// Close an owned screen left up by a final step that ran to completion
    /// without another pause. A borrowed or already-closed screen is a no-op.
    pub fn endEvaluation(self: *VmDebugger) void {
        self.leaveOwnedScreen();
    }

    fn ensureOwnedScreen(self: *VmDebugger) !void {
        if (self.owned_active) return;
        self.owned_raw = term_mod.RawMode.enable() catch return error.NotATerminal;
        var buf: [64]u8 = undefined;
        var out = std.Io.File.stdout().writerStreaming(self.io, &buf);
        _ = try tui.Screen.enter(&out.interface, .{ .bracketed_paste = true });
        try out.interface.flush();
        self.owned_active = true;
    }

    fn leaveOwnedScreen(self: *VmDebugger) void {
        if (!self.owned_active) return;
        var buf: [64]u8 = undefined;
        var out = std.Io.File.stdout().writerStreaming(self.io, &buf);
        var screen: tui.Screen = .{ .writer = &out.interface, .options = .{ .bracketed_paste = true } };
        screen.leave() catch {};
        out.interface.flush() catch {};
        self.owned_raw.disable();
        self.owned_active = false;
    }

    fn runCallback(ctx: *anyopaque, session: *DebugSession) anyerror!void {
        const self: *VmDebugger = @ptrCast(@alignCast(ctx));
        // Borrowed: a live `:vm` explorer already owns the screen; just drive it.
        if (self.active_tui) |tui_ptr| {
            _ = try tui_ptr.debugRun(session, self.history);
            return;
        }

        // Owned: ensure our own screen (kept across steps) and drive a throwaway
        // explorer focused on the paused stack.
        try self.ensureOwnedScreen();
        var tree_index = try vm_tree.Index.build(self.allocator, self.ev.chunkRegistry(), self.ev.internTable(), self.ev.basePath());
        defer tree_index.deinit();
        var explorer = Tui{
            .allocator = self.allocator,
            .io = self.io,
            .ev = self.ev,
            .color_depth = self.color_depth,
            .tree_index = &tree_index,
            .session_host = null,
            .arena = std.heap.ArenaAllocator.init(self.allocator),
        };
        defer explorer.deinit();
        const intent = explorer.debugRun(session, self.history) catch |err| {
            self.leaveOwnedScreen();
            return err;
        };
        if (intent == .close) self.leaveOwnedScreen();
    }
};

const RangeKind = enum(u4) { names, chunks, objects, values, attrs, attr_positions, intern, builtin };
const ChunkEquivalence = union(enum) {
    structural: ChunkId,
    code: ChunkId,
};
const Range = struct {
    kind: RangeKind,
    parent: u32,
    start: u32,
    len: u32,
    /// Number of live records in this half-open range. This is deliberately
    /// separate from `len`: sparse stores must not advertise backing capacity
    /// as if every reserved slot were an object.
    live: u32,
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
    /// One record in the value/attr/attr-position stores.
    store_record: struct { view: HeapView, id: u32, depth: u16 },
    /// Rows that only exist while a debug pause is live (`debug_session`).
    debug_root: struct { depth: u16 },
    debug_frame: struct { index: u32, depth: u16 },
    debug_value: struct { depth: u16 },
};
const LineRange = struct { start: usize, end: usize };

const NavigationState = struct {
    back: std.ArrayListUnmanaged(Visit) = .empty,
    forward: std.ArrayListUnmanaged(Visit) = .empty,
    search: std.ArrayListUnmanaged(u8) = .empty,
    focus: vm_navigation.Focus = .subject,
    tree_selection: usize = 0,
    detail_selection: usize = 0,
    scroll: usize = 0,
    x_scroll: usize = 0,
};

const TreeState = struct {
    expanded_names: std.AutoHashMapUnmanaged(u32, void) = .empty,
    expanded_ranges: std.AutoHashMapUnmanaged(u128, void) = .empty,
    focus_path: std.AutoHashMapUnmanaged(u32, void) = .empty,
    rows: std.ArrayListUnmanaged(TreeRow) = .empty,
    indexing: bool = false,
    categories: [2]bool = .{ false, false },
    heap_views: [std.meta.fields(HeapView).len]bool = @splat(false),
    /// Case-insensitive substring filter on the bytecode name tree. When set,
    /// only name nodes on a path to a match (and their chunks) are shown.
    filter_query: std.ArrayListUnmanaged(u8) = .empty,
    filter_keep: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// Subject whose path is projected through otherwise-collapsed name nodes.
    /// Tree-origin inspection does not change this anchor: opening a visible
    /// row must never reshape the tree around the newly opened subject.
    projected_chunk: ?ChunkId = null,
};

const HeapIndexState = struct {
    stats: ?runtime.ObjectHeap.Stats = null,
    objects: ?runtime.ObjectHeap.ObjectSnapshot = null,
    objects_failed: bool = false,
    /// Lazily-built live-slot snapshots for the range stores (values/attrs/
    /// attr_positions), rebuilt when the store's slot count changes. Cheap
    /// enough to build synchronously on demand (a bitmap over the free lists).
    values: ?runtime.ObjectHeap.ObjectSnapshot = null,
    values_count: u32 = 0,
    attrs: ?runtime.ObjectHeap.ObjectSnapshot = null,
    attrs_count: u32 = 0,
    attr_positions: ?runtime.ObjectHeap.ObjectSnapshot = null,
    attr_positions_count: u32 = 0,
};

const ReferenceIndexState = struct {
    graph: ?vm_refs.Graph = null,
    failed: bool = false,
};

const Viewport = struct {
    cols: usize = 80,
    rows: usize = 22,
};

const SessionJobs = struct {
    names: vm_jobs.NameIndex,
    heap: vm_jobs.HeapCensus,
    objects: vm_jobs.ObjectSnapshot,
    references: vm_jobs.References,

    fn init(ev: *Evaluator) SessionJobs {
        return .{
            .names = .{
                .registry = ev.chunkRegistry(),
                .intern = ev.internTable(),
                .base_path = ev.basePath(),
            },
            .heap = .{ .ev = ev },
            .objects = .{ .ev = ev },
            .references = .{ .ev = ev },
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
    /// The source-map span currently selected in an inspector. Chunk and frame
    /// documents use it when rebuilding their embedded source excerpt.
    source_focus: ?struct {
        chunk_id: ChunkId,
        span: bytecode.Chunk.SourceSpan,
    } = null,
    /// The source section currently owns j/k. Selecting a SOURCE heading and
    /// pressing Enter sets this without opening another page.
    source_session: ?ChunkId = null,
    /// Vertical offset within the current hover preview. Normal cursor motion
    /// resets it; Alt+j/k and Alt+Up/Down adjust it without moving the tree.
    preview: vm_navigation.PreviewScroll = .{},
    /// True only for the first rendered frame of a return pause. The inline
    /// result starts as a bright badge, then settles to its persistent style.
    return_flash: bool = false,

    /// Set for the duration of a debug pause driven by `debugRun`. While non-null
    /// the tree grows a Debug subtree and the debug-control keys are live.
    debug_session: ?*DebugSession = null,
    /// `navigation.back` length captured on pause entry, restored on resume so a
    /// borrowed pause leaves the outer explorer's history exactly as it found it.
    debug_nav_mark: usize = 0,

    const range_leaf = 256;
    const range_branch = 4096;
    const preview_line_cap = 200;

    fn deinit(self: *Tui) void {
        self.navigation.back.deinit(self.allocator);
        self.navigation.forward.deinit(self.allocator);
        self.navigation.search.deinit(self.allocator);
        self.tree.expanded_names.deinit(self.allocator);
        self.tree.expanded_ranges.deinit(self.allocator);
        self.tree.focus_path.deinit(self.allocator);
        self.tree.filter_query.deinit(self.allocator);
        self.tree.filter_keep.deinit(self.allocator);
        self.tree.rows.deinit(self.allocator);
        self.transcript_lines.deinit(self.allocator);
        if (self.references.graph) |*graph| graph.deinit();
        self.clearHeapSnapshots();
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
        try self.selectedSourceChanged();
    }

    fn pollSessionJobs(self: *Tui, jobs: *SessionJobs) !void {
        if (jobs.names.poll(self.tree_index)) {
            self.tree.indexing = false;
            try self.rebuildTreeForCurrent();
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
        // The collapsed HEAP row owns the aggregate census preview, so populate
        // it for every explorer session rather than waiting for a folder/page
        // to be opened.
        if (self.heap_index.stats == null and jobs.heap.thread == null) {
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

        // References are part of chunk and heap-object inspector documents.
        const shows_references = self.currentChunk() != null or self.currentObject() != null;
        if (jobs.references.poll(&self.references.graph)) {
            if (shows_references) try self.refreshPage(self.currentKind());
        }
        const references_failed = jobs.references.failed.load(.acquire);
        self.references.failed = references_failed;
        const references_stale = self.references.graph == null or
            self.references.graph.?.registry_count != registry.count() or
            self.references.graph.?.object_high_water != self.ev.heapCounts().objects;
        if (shows_references and references_stale and jobs.references.thread == null and !references_failed) {
            jobs.references.start() catch {};
        }
    }

    fn executeCommand(self: *Tui, input: []const u8, capture: *transcript_mod.Capture, host: SessionHost, jobs: *SessionJobs) !bool {
        jobs.finish(self);
        try host.execute(input, &capture.writer);
        jobs.clearFailures();
        self.heap_index.objects_failed = false;
        self.references.failed = false;
        self.heap_index.stats = null;
        self.clearHeapSnapshots();
        self.clearReferenceGraph();
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

    /// An evaluation can fill a previously reserved slot without advancing a
    /// store's high-water count, so count-keyed snapshots are not sufficient
    /// invalidation. Drop every liveness bitmap at the command boundary.
    fn clearHeapSnapshots(self: *Tui) void {
        if (self.heap_index.objects) |*snapshot| snapshot.deinit();
        if (self.heap_index.values) |*snapshot| snapshot.deinit();
        if (self.heap_index.attrs) |*snapshot| snapshot.deinit();
        if (self.heap_index.attr_positions) |*snapshot| snapshot.deinit();
        self.heap_index.objects = null;
        self.heap_index.values = null;
        self.heap_index.attrs = null;
        self.heap_index.attr_positions = null;
        self.heap_index.values_count = 0;
        self.heap_index.attrs_count = 0;
        self.heap_index.attr_positions_count = 0;
    }

    fn clearReferenceGraph(self: *Tui) void {
        if (self.references.graph) |*graph| graph.deinit();
        self.references.graph = null;
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
            try self.pollSessionJobs(&jobs);

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

                if (key.code == .escape) {
                    if (try self.escapeLayer()) continue;
                    return;
                }
                const leave_explorer = switch (key.code) {
                    .cp => |cp| cp == 'q',
                    else => false,
                };
                if (leave_explorer) return;
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
                try self.appendSourceDocument(&page, id, chunk, self.focusedSourceSpan(id));
                try page.line("", .none);
                try page.heading(try std.fmt.allocPrint(arena, "CODE · chunk[0x{x}]", .{id}));
                try self.appendDisassemblyAt(&page, id, chunk, true, null);
                try page.line("", .none);
                try self.appendReferences(&page, .{ .chunk = id });
                return .{
                    .title = try std.fmt.allocPrint(arena, "chunk[0x{x}]", .{id}),
                    .lines = page.lines.items,
                    .actions = page.actions.items,
                    .locations = page.locations.items,
                };
            },
            .heap => |view| return self.buildHeapPage(view),
            .object => |id| return self.buildObjectPage(id),
            .store_record => |r| return self.buildStoreRecordPage(r.view, r.id),
            .debug_frame => |i| return self.buildDebugFramePage(i),
            .debug_value => return self.buildReturnValuePage(),
            .help => {
                const help_text =
                    \\  Tab             switch tree/detail focus
                    \\  j/k, arrows     move between interactive rows
                    \\  Enter, →        expand a tree/group or open a reference
                    \\  ←               collapse a tree/group
                    \\  p               toggle a breakpoint on the selected row
                    \\  F               filter the tree by name (Esc clears)
                    \\  d/u, PgDn/PgUp  scroll the detail document
                    \\  b / f           back / forward through followed references
                    \\  /               search; n/N next/previous match
                    \\  i / :           enter an expression / command at the REPL prompt
                    \\  Esc             leave source/pane/tree layer; then return
                    \\  q               return directly to the inline REPL
                    \\
                    \\The tree starts collapsed except for the focused chunk's
                    \\ancestor path. Large child/chunk sets are exposed through
                    \\bounded range nodes instead of being truncated.
                ;
                var page: PageBuilder = .{ .arena = arena };
                try page.heading("The VM explorer");
                try page.line("", .none);
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
        try page.heading(try std.fmt.allocPrint(arena, "HEAP · {d} object slots", .{counts.objects}));
        try page.line(try std.fmt.allocPrint(arena, "objects        {d:>12}", .{counts.objects}), .none);
        try page.line(try std.fmt.allocPrint(arena, "values         {d:>12}", .{counts.values}), .none);
        try page.line(try std.fmt.allocPrint(arena, "attrs          {d:>12}", .{counts.attrs}), .none);
        try page.line(try std.fmt.allocPrint(arena, "attr positions {d:>12}", .{counts.attr_positions}), .none);
        try page.line(try std.fmt.allocPrint(arena, "intern          {d:>12}", .{self.storeCount(.intern)}), .none);
        try page.line(try std.fmt.allocPrint(arena, "builtin         {d:>12}", .{self.storeCount(.builtin)}), .none);
        try page.line("", .none);

        const stats = self.heap_index.stats orelse {
            return .{
                .title = try std.fmt.allocPrint(arena, "heap · {s}", .{@tagName(view)}),
                .lines = page.lines.items,
                .actions = page.actions.items,
            };
        };
        switch (view) {
            .overview, .objects => {
                try page.heading("OBJECT VARIANTS");
                for (stats.variant_counts, 0..) |count, i| {
                    try page.line(try std.fmt.allocPrint(arena, "{s:<20} {d:>12}", .{ runtime.ObjectHeap.Stats.variantName(i), count }), .none);
                }
                try page.line("", .none);
                try page.heading("THUNK STATES");
                for (stats.thunk_states, 0..) |count, i| {
                    try page.line(try std.fmt.allocPrint(arena, "{s:<20} {d:>12}", .{ runtime.ObjectHeap.Stats.thunkStateName(i), count }), .none);
                }
                try page.line(try std.fmt.allocPrint(arena, "resolved demanded     {d:>12}", .{stats.resolved_demanded}), .none);
                try page.line(try std.fmt.allocPrint(arena, "resolved undemanded   {d:>12}", .{stats.resolved_undemanded}), .none);
            },
            .values, .attrs => {
                try page.heading("INLINE INTEGER MAGNITUDES · values + attrs");
                for (stats.int_buckets, 0..) |count, i| {
                    try page.line(try std.fmt.allocPrint(arena, "{s:<20} {d:>12}", .{ runtime.ObjectHeap.Stats.intBucketLabel(i), count }), .none);
                }
                try page.line(try std.fmt.allocPrint(arena, "i48 overflows         {d:>12}", .{stats.intOverflowsI48()}), .none);
            },
            .attr_positions => {
                try page.heading("ATTR POSITIONS");
                try page.line("Source-position records attached to heap attrs.", .none);
                try page.line("Open TABLES on a chunk to inspect its compile-time attr positions.", .none);
            },
            .intern => {
                try page.heading("INTERNED TEXT");
                try page.line("Dense, process-local text identities used by strings, paths, names, and source files.", .none);
            },
            .builtin => {
                try page.heading("BUILTINS");
                try page.line("Dense evaluator builtin identities, including compiler-internal entries.", .none);
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
        if (self.heap_index.objects == null)
            self.heap_index.objects = self.ev.heapObjectSnapshot(self.allocator) catch null;
        const snapshot = self.heap_index.objects orelse return .{
            .title = try std.fmt.allocPrint(arena, "objects[0x{x}]", .{id}),
            .lines = page.lines.items,
            .actions = page.actions.items,
        };
        const info = self.ev.inspectHeapObject(&snapshot, id) catch {
            try page.line("this object is no longer live", .none);
            return .{
                .title = try std.fmt.allocPrint(arena, "objects[0x{x}]", .{id}),
                .lines = page.lines.items,
                .actions = page.actions.items,
            };
        };
        const heading_width = self.layout().main_width;
        try page.heading(try self.canonicalStoreRef(
            arena,
            .objects,
            id,
            try self.objectSummary(arena, id, self.storePreviewBudget("objects", id, heading_width)),
            true,
        ));
        try page.line("", .none);
        switch (info) {
            .list => {
                try page.line("", .none);
                try self.appendObjectMembers(&page, id);
            },
            .attrs => |attrs| {
                try page.line(try std.fmt.allocPrint(arena, "positions   {d}", .{attrs.positions}), .none);
                try page.line(try std.fmt.allocPrint(arena, "swept       {s}", .{if (attrs.sibling_swept) "yes" else "no"}), .none);
                try page.line("", .none);
                try self.appendObjectMembers(&page, id);
            },
            .merge_attrs => |merge| {
                try self.appendObjectRef(&page, "base", merge.base);
                try self.appendObjectRef(&page, "overlay", merge.overlay);
                try page.line(try std.fmt.allocPrint(arena, "depth       {d}", .{merge.depth}), .none);
                if (merge.flattened) |flat| try self.appendObjectRef(&page, "flattened", flat) else try page.line("flattened   not materialized", .none);
            },
            .closure => |closure| {
                const prefix = "chunk       ";
                try page.line(
                    try std.fmt.allocPrint(arena, "{s}{s}", .{
                        prefix,
                        try self.locatedValue(arena, "chunk", closure.chunk, .chunk, null, self.lineRemainderWidth(prefix), true),
                    }),
                    .{ .chunk = closure.chunk },
                );
                try page.line(try std.fmt.allocPrint(arena, "upvalues    {d}", .{closure.upvalues}), .none);
            },
            .builtin_closure => |closure| {
                const prefix = "builtin     ";
                try page.line(try std.fmt.allocPrint(arena, "{s}{s}", .{
                    prefix,
                    try self.locatedValue(
                        arena,
                        "builtin",
                        closure.builtin,
                        .builtin,
                        disasm.builtinName(closure.builtin),
                        self.lineRemainderWidth(prefix),
                        true,
                    ),
                }), .none);
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
                            const prefix = "chunk       ";
                            try page.line(
                                try std.fmt.allocPrint(arena, "{s}{s}", .{
                                    prefix,
                                    try self.locatedValue(arena, "chunk", body.chunk, .chunk, null, self.lineRemainderWidth(prefix), true),
                                }),
                                .{ .chunk = body.chunk },
                            );
                            try page.line(try std.fmt.allocPrint(arena, "captures    {d}", .{body.captures}), .none);
                        },
                        .pass_through => |value| try self.appendValueRef(&page, "value", value),
                        .attr_access => |access| {
                            try self.appendValueRef(&page, "base", access.base);
                            const prefix = "attribute   ";
                            const attribute = try self.renderValueRef(arena, .{
                                .kind = .string,
                                .target = .{ .intern = access.name },
                            }, self.lineRemainderWidth(prefix), true);
                            try page.line(try std.fmt.allocPrint(arena, "{s}{s}", .{ prefix, attribute.text }), .none);
                        },
                        .deferred => |body| {
                            try page.line(try std.fmt.allocPrint(arena, "deferred[0x{x}]", .{body.id}), .none);
                            try page.line(try std.fmt.allocPrint(arena, "captures    {d}", .{body.captures}), .none);
                        },
                    },
                }
            },
            .context_string => |string| {
                const prefix = "text        ";
                const text = try self.renderValueRef(arena, .{
                    .kind = .string,
                    .target = .{ .intern = string.text },
                }, self.lineRemainderWidth(prefix), true);
                try page.line(try std.fmt.allocPrint(arena, "{s}{s}", .{ prefix, text.text }), .none);
                try page.line(try std.fmt.allocPrint(arena, "context     {d} entries", .{string.context}), .none);
            },
            .boxed_int => |value| try page.line(try std.fmt.allocPrint(arena, "value       {d}", .{value}), .none),
            .partial_app => |partial| {
                try self.appendValueRef(&page, "function", partial.function);
                try page.line(try std.fmt.allocPrint(arena, "arguments   {d}", .{partial.args}), .none);
            },
        }
        try page.line("", .none);
        try self.appendReferences(&page, .{ .object = id });
        return .{
            .title = try std.fmt.allocPrint(arena, "objects[0x{x}]", .{id}),
            .lines = page.lines.items,
            .actions = page.actions.items,
        };
    }

    /// One record from the value / attr / attr-position stores.
    fn buildStoreRecordPage(self: *Tui, view: HeapView, id: u32) !Page {
        const arena = self.arena.allocator();
        var page: PageBuilder = .{ .arena = arena };
        const heading_width = self.layout().main_width;
        const heading_summary = try self.storeRecordSummary(
            arena,
            view,
            id,
            self.storePreviewBudget(@tagName(view), id, heading_width),
        );
        try page.heading(try self.canonicalStoreRef(arena, view, id, heading_summary, true));
        try page.line("", .none);
        switch (view) {
            .values => {
                if (self.ev.heapValueAt(id)) |value| {
                    try self.appendValueDetail(&page, "value", value.*);
                } else try page.line("(slot is out of range)", .none);
            },
            .attrs => {
                if (self.ev.heapAttrAt(id)) |attr| {
                    try page.line(try std.fmt.allocPrint(arena, "name   {s}", .{self.ev.internTable().get(attr.name)}), .none);
                    try self.appendValueDetail(&page, "value", attr.value);
                } else try page.line("(slot is out of range)", .none);
            },
            .attr_positions => {
                if (self.ev.heapAttrPosAt(id)) |ap| {
                    try page.line(try std.fmt.allocPrint(arena, "name   {s}", .{self.ev.internTable().get(ap.name)}), .none);
                    try page.line(try std.fmt.allocPrint(arena, "file   {s}", .{self.ev.internTable().get(ap.pos.file)}), .none);
                    try page.line(try std.fmt.allocPrint(arena, "at     {d}:{d}", .{ ap.pos.line, ap.pos.column }), .none);
                } else try page.line("(slot is out of range)", .none);
            },
            .intern => if (id < self.storeCount(.intern)) {
                try page.line(try escapedQuoted(arena, "text ", self.ev.internTable().get(id), self.layout().main_width), .none);
            } else try page.line("(slot is out of range)", .none),
            .builtin => if (disasm.builtinName(id)) |name| {
                try page.line(try std.fmt.allocPrint(arena, "name   {s}", .{name}), .none);
            } else try page.line("(slot is out of range)", .none),
            .overview, .objects => try page.line("(not a store record)", .none),
        }
        return .{
            .title = try std.fmt.allocPrint(arena, "{s}[0x{x}]", .{ @tagName(view), id }),
            .lines = page.lines.items,
            .actions = page.actions.items,
            .locations = page.locations.items,
        };
    }

    /// The pause's break/return/error value as a first-class subject: the
    /// value's kind + scalar (or navigable ref), then its container members
    /// enumerated navigably so you can walk straight into the result.
    fn buildReturnValuePage(self: *Tui) !Page {
        const arena = self.arena.allocator();
        var page: PageBuilder = .{ .arena = arena };
        const session = self.debug_session orelse {
            try page.line("(no active pause)", .none);
            return debugPageOf(arena, &page, "value");
        };
        try page.heading(returnValueHeading(session.reason));
        try page.line("", .none);
        try self.appendValueDetail(&page, "value", session.value);
        try page.line("", .none);
        switch (self.ev.valueRef(session.value).target) {
            .object => |id| try self.appendObjectMembers(&page, id),
            else => {},
        }
        return .{
            .title = try arena.dupe(u8, "value"),
            .lines = page.lines.items,
            .actions = page.actions.items,
            .locations = page.locations.items,
        };
    }

    /// Enumerate an attrs/list object's members navigably (non-forcing). Bounded
    /// so a huge container can't blow up the page.
    fn appendObjectMembers(self: *Tui, page: *PageBuilder, id: runtime.types.ObjectId) !void {
        const arena = page.arena;
        const cap = 200;
        if (self.ev.heapAttrsOf(id)) |attrs| {
            try page.heading(try std.fmt.allocPrint(arena, "MEMBERS · {d}", .{attrs.len}));
            for (attrs, 0..) |entry, i| {
                if (i >= cap) {
                    try page.line(try std.fmt.allocPrint(arena, "  … {d} more", .{attrs.len - cap}), .none);
                    break;
                }
                try self.appendValueLine(page, try std.fmt.allocPrint(arena, "  {s} : ", .{self.ev.internTable().get(entry.name)}), entry.value);
            }
        } else |_| if (self.ev.heapListOf(id)) |items| {
            try page.heading(try std.fmt.allocPrint(arena, "ITEMS · {d}", .{items.len}));
            for (items, 0..) |item, i| {
                if (i >= cap) {
                    try page.line(try std.fmt.allocPrint(arena, "  … {d} more", .{items.len - cap}), .none);
                    break;
                }
                try self.appendValueLine(page, try std.fmt.allocPrint(arena, "  [{d}] ", .{i}), item);
            }
        } else |_| {}
    }

    /// One paused stack frame rendered as a single scrollable document: header,
    /// break/return value, a source excerpt around the frame, its named
    /// locals/upvalues, and the disassembly with the current instruction marked.
    /// The disassembly rows carry `(chunk_id, offset)` breakpoint locations, so
    /// `p` toggles a per-instruction breakpoint here exactly as in a chunk.
    fn buildDebugFramePage(self: *Tui, index: usize) !Page {
        const arena = self.arena.allocator();
        var page: PageBuilder = .{ .arena = arena };
        const session = self.debug_session orelse {
            try page.line("(no active debug session)", .none);
            return debugPageOf(arena, &page, "debug");
        };
        if (index >= session.frameCount()) {
            try page.line("(this frame is no longer live)", .none);
            return debugPageOf(arena, &page, "debug");
        }
        const info = session.frame(index);
        const chunk_id = session.frameChunkId(index);

        try page.heading(try std.fmt.allocPrint(arena, "FRAME · #{d} · {s} · {s}:{d}:{d}", .{
            index,
            reasonName(session.reason),
            if (info.file) |f| std.fs.path.basename(f) else "<repl>",
            info.line,
            info.column,
        }));
        if (session.hasFrameName(index)) {
            var name: std.Io.Writer.Allocating = .init(arena);
            session.writeFrameName(&name.writer, index) catch {};
            if (name.written().len > 0) try page.line(try std.fmt.allocPrint(arena, "name   {s}", .{name.written()}), .none);
        }
        try page.line("", .none);

        if (session.reason == .break_builtin or session.reason == .eval_error) {
            try page.heading(returnValueHeading(session.reason));
            try self.appendValueLine(&page, "  => ", session.value);
            try page.line("", .none);
        }

        if (self.ev.getChunk(chunk_id)) |chunk| {
            if (self.focusedSourceSpan(chunk_id) orelse info.span) |span| if (session.frameSourceText(index)) |source| {
                try self.appendSourceDocumentWithText(
                    &page,
                    chunk_id,
                    chunk,
                    source,
                    span,
                    if (session.reason == .return_step and index + 1 == session.frameCount()) session.value else null,
                );
                try page.line("", .none);
            };
        } else if (info.span) |span| if (session.frameSourceText(index)) |source| {
            try page.heading("SOURCE");
            try self.appendSourceExcerpt(
                &page,
                source,
                span,
                null,
                null,
                true,
                true,
                if (session.reason == .return_step and index + 1 == session.frameCount()) session.value else null,
            );
            try page.line("", .none);
        };

        try page.heading("LOCALS · values are not forced");
        var any = false;
        for (0..session.localCount(index)) |slot| {
            const nm = session.localName(index, slot) orelse continue;
            try self.appendValueLine(&page, try std.fmt.allocPrint(arena, "  {s} : ", .{nm}), session.localValue(index, slot));
            any = true;
        }
        for (0..session.upvalueCount(index)) |slot| {
            const nm = session.upvalueName(index, slot) orelse continue;
            try self.appendValueLine(&page, try std.fmt.allocPrint(arena, "  ↑ {s} : ", .{nm}), session.upvalueValue(index, slot));
            any = true;
        }
        if (!any) try page.line("  (no named locals or upvalues)", .none);
        try page.line("", .none);

        // The raw VM operand stack for this frame (top of stack first).
        const stack_n = session.stackSlotCount(index);
        if (stack_n > 0) {
            try page.heading(try std.fmt.allocPrint(arena, "VM STACK · {d}", .{stack_n}));
            var s: usize = 0;
            while (s < stack_n) : (s += 1) {
                const slot = stack_n - 1 - s;
                try self.appendValueLine(&page, try std.fmt.allocPrint(arena, "  [{d}] ", .{slot}), session.stackSlot(index, slot));
            }
            try page.line("", .none);
        }

        if (self.ev.getChunk(chunk_id)) |chunk| {
            try page.heading(try std.fmt.allocPrint(arena, "CODE · chunk[0x{x}]", .{chunk_id}));
            try self.appendDisassemblyAt(&page, chunk_id, chunk, false, info.instruction);
        }

        return .{
            .title = try std.fmt.allocPrint(arena, "frame #{d}", .{index}),
            .lines = page.lines.items,
            .actions = page.actions.items,
            .locations = page.locations.items,
        };
    }

    fn appendObjectRef(self: *Tui, page: *PageBuilder, label: []const u8, id: runtime.types.ObjectId) !void {
        const prefix = try std.fmt.allocPrint(page.arena, "{s:<12} ", .{label});
        const ref_width = self.lineRemainderWidth(prefix);
        const preview_width = self.storePreviewBudget("objects", id, ref_width);
        try page.line(try std.fmt.allocPrint(page.arena, "{s}{s}", .{
            prefix,
            try self.canonicalStoreRef(
                page.arena,
                .objects,
                id,
                try self.objectSummary(page.arena, id, preview_width),
                true,
            ),
        }), .{ .object = id });
    }

    fn lineRemainderWidth(self: *const Tui, prefix: []const u8) usize {
        return self.layout().main_width -| tui.displayWidth(prefix, width_mod.cpWidth);
    }

    /// Render a heap `Value`: the actual scalar for inline kinds (int, float,
    /// bool, null, string, path), or a navigable reference for heap-backed
    /// kinds. Inline scalars carry their data in the `Value` itself, so this is
    /// safe on a raw store slot without any heap deref or forcing.
    fn appendValueDetail(self: *Tui, page: *PageBuilder, label: []const u8, value: runtime.value.Value) !void {
        try self.appendValueLine(page, try std.fmt.allocPrint(page.arena, "{s:<12} ", .{label}), value);
    }

    /// One navigable line for a `Value`: `<prefix><digest>[ → store[0xN]]`.
    /// Object/chunk-backed values carry a `.object`/`.chunk` action so Enter
    /// (or the right-hand preview) drills into them; scalars render inline.
    fn appendValueLine(self: *Tui, page: *PageBuilder, prefix: []const u8, value: runtime.value.Value) !void {
        const rendered = try self.renderValue(page.arena, value, self.lineRemainderWidth(prefix), true);
        try page.line(
            try std.fmt.allocPrint(page.arena, "{s}{s}", .{ prefix, rendered.text }),
            rendered.action,
        );
    }

    const RenderedValue = struct {
        text: []const u8,
        action: RowAction,
    };

    /// Canonical non-forcing `Value` presentation shared by locals, stack
    /// slots, return badges, and other compact value rows.
    fn renderValue(
        self: *Tui,
        arena: std.mem.Allocator,
        value: runtime.value.Value,
        max_cells: usize,
        colored: bool,
    ) !RenderedValue {
        const ref = self.ev.valueRef(value);
        return switch (ref.target) {
            .object => |id| blk: {
                const preview = try self.objectTargetSummary(arena, value.kind(), id, max_cells);
                break :blk .{
                    .action = .{ .object = id },
                    .text = try self.locatedValue(
                        arena,
                        "objects",
                        id,
                        .object,
                        preview,
                        max_cells,
                        colored,
                    ),
                };
            },
            .chunk => |id| blk: {
                break :blk .{
                    .action = .{ .chunk = id },
                    .text = try self.locatedValue(
                        arena,
                        "chunk",
                        id,
                        .chunk,
                        if (value.kind() == .closure and value.isFunction()) "function" else disasm.valueKindLabel(value.kind()),
                        max_cells,
                        colored,
                    ),
                };
            },
            .intern => |id| blk: {
                const preview = try escapedQuoted(
                    arena,
                    try std.fmt.allocPrint(arena, "{s} ", .{disasm.valueKindLabel(value.kind())}),
                    self.ev.internTable().get(id),
                    self.storePreviewBudget("intern", id, max_cells),
                );
                break :blk .{
                    .action = .{ .store_record = .{ .view = .intern, .id = id } },
                    .text = try self.locatedValue(arena, "intern", id, .intern, preview, max_cells, colored),
                };
            },
            .builtin => |id| .{
                .action = .{ .store_record = .{ .view = .builtin, .id = id } },
                .text = try self.locatedValue(
                    arena,
                    "builtin",
                    id,
                    .builtin,
                    disasm.builtinName(id),
                    max_cells,
                    colored,
                ),
            },
            else => .{
                .action = .none,
                .text = try self.scalarValueSummary(arena, value, max_cells),
            },
        };
    }

    fn appendValueRef(self: *Tui, page: *PageBuilder, label: []const u8, value: runtime.heap.ValueRef) !void {
        const prefix = try std.fmt.allocPrint(page.arena, "{s:<12} ", .{label});
        const rendered = try self.renderValueRef(page.arena, value, self.lineRemainderWidth(prefix), true);
        try page.line(
            try std.fmt.allocPrint(page.arena, "{s}{s}", .{ prefix, rendered.text }),
            rendered.action,
        );
    }

    fn renderValueRef(
        self: *Tui,
        arena: std.mem.Allocator,
        value: runtime.heap.ValueRef,
        max_cells: usize,
        colored: bool,
    ) !RenderedValue {
        return switch (value.target) {
            .none => .{ .text = disasm.valueKindLabel(value.kind), .action = .none },
            .object => |id| .{
                .text = try self.locatedValue(
                    arena,
                    "objects",
                    id,
                    .object,
                    try self.objectTargetSummary(arena, value.kind, id, max_cells),
                    max_cells,
                    colored,
                ),
                .action = .{ .object = id },
            },
            .chunk => |id| blk: {
                break :blk .{
                    .text = try self.locatedValue(
                        arena,
                        "chunk",
                        id,
                        .chunk,
                        if (value.kind == .closure) "function" else disasm.valueKindLabel(value.kind),
                        max_cells,
                        colored,
                    ),
                    .action = .{ .chunk = id },
                };
            },
            .intern => |id| blk: {
                const preview = try escapedQuoted(
                    arena,
                    try std.fmt.allocPrint(arena, "{s} ", .{disasm.valueKindLabel(value.kind)}),
                    self.ev.internTable().get(id),
                    self.storePreviewBudget("intern", id, max_cells),
                );
                break :blk .{
                    .text = try self.locatedValue(arena, "intern", id, .intern, preview, max_cells, colored),
                    .action = .{ .store_record = .{ .view = .intern, .id = id } },
                };
            },
            .builtin => |id| .{
                .text = try self.locatedValue(arena, "builtin", id, .builtin, disasm.builtinName(id), max_cells, colored),
                .action = .{ .store_record = .{ .view = .builtin, .id = id } },
            },
        };
    }

    fn appendDisassemblyAt(
        self: *Tui,
        page: *PageBuilder,
        id: ChunkId,
        chunk: *const bytecode.Chunk,
        show_tables: bool,
        current_offset: ?u32,
    ) !void {
        var text: std.Io.Writer.Allocating = .init(page.arena);
        const symbols: disasm.Symbols = .{ .intern = self.ev.internTable(), .registry = self.ev.chunkRegistry() };
        var inspected_chunk = chunk.*;
        inspected_chunk.code = try self.ev.unpatchedChunkCode(page.arena, id, chunk);
        var options = disasm_options;
        options.color_depth = self.color_depth;
        options.show_header = false;
        options.show_constants = show_tables;
        options.show_code = true;
        options.current_offset = current_offset;
        options.line_width = @intCast(@min(self.layout().main_width, std.math.maxInt(u16)));
        try disasm.writeChunk(page.arena, &text.writer, id, &inspected_chunk, symbols, options);

        var lines = std.mem.splitScalar(u8, text.written(), '\n');
        while (lines.next()) |line| {
            if (line.len == 0 and lines.peek() == null) break;
            const plain = base.terminal_text.stripAnsiInPlace(try page.arena.dupe(u8, line));
            const target = disasmTarget(plain);
            const action: RowAction = if (target == .none and disasmOffset(&inspected_chunk, plain) != null) .instruction else target;
            const location = self.disasmLocation(id, &inspected_chunk, plain);
            try page.lineAt(line, action, location);
        }
    }

    fn valueRowAction(self: *const Tui, value: runtime.value.Value) RowAction {
        return switch (self.ev.valueRef(value).target) {
            .object => |id| .{ .object = id },
            .chunk => |id| .{ .chunk = id },
            .intern => |id| .{ .store_record = .{ .view = .intern, .id = id } },
            .builtin => |id| .{ .store_record = .{ .view = .builtin, .id = id } },
            else => .none,
        };
    }

    fn rowTargetsValue(self: *const Tui, action: RowAction, value: runtime.value.Value) bool {
        return switch (self.ev.valueRef(value).target) {
            .object => |id| switch (action) {
                .object => |row_id| row_id == id,
                else => false,
            },
            .chunk => |id| switch (action) {
                .chunk => |row_id| row_id == id,
                else => false,
            },
            .intern => |id| switch (action) {
                .store_record => |record| record.view == .intern and record.id == id,
                else => false,
            },
            .builtin => |id| switch (action) {
                .store_record => |record| record.view == .builtin and record.id == id,
                else => false,
            },
            else => false,
        };
    }

    /// Put a navigable pause result under the inspector cursor. The inline
    /// result remains part of the source document, and Enter follows it using
    /// the same object/chunk action as any other rendered value.
    fn focusValueRow(self: *Tui, value: runtime.value.Value) void {
        for (self.page.actions, 0..) |action, i| {
            if (!self.rowTargetsValue(action, value)) continue;
            self.navigation.detail_selection = i;
            self.ensureDetailVisible();
            return;
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
            .structural => |peer| std.fmt.bufPrint(buffer, " · identical chunk[0x{x}]", .{peer}) catch "",
            .code => |peer| std.fmt.bufPrint(buffer, " · same code chunk[0x{x}]", .{peer}) catch "",
        };
    }

    fn appendChunkEquivalence(self: *Tui, page: *PageBuilder, id: ChunkId) !void {
        const relation = self.chunkEquivalence(id) orelse return;
        switch (relation) {
            .structural => |peer| try page.line(
                try std.fmt.allocPrint(page.arena, "structurally identical to chunk[0x{x}]", .{peer}),
                .{ .chunk = peer },
            ),
            .code => |peer| try page.line(
                try std.fmt.allocPrint(page.arena, "same bytecode as chunk[0x{x}]; constants, source data, or metadata differ", .{peer}),
                .{ .chunk = peer },
            ),
        }
        try page.line("", .none);
    }

    fn disasmLocation(self: *Tui, id: ChunkId, chunk: *const bytecode.Chunk, plain: []const u8) ?BreakpointLocation {
        const offset = disasmOffset(chunk, plain) orelse return null;
        const span = bytecode.inspect.bestSpan(chunk, offset);
        const file: []const u8 = if (span) |s|
            if (s.file orelse bytecode.inspect.chunkPrimaryFile(chunk, id, self.ev.chunkRegistry())) |f| self.ev.internTable().get(f) else ""
        else
            "";
        return .{
            .chunk_id = id,
            .offset = @intCast(offset),
            .file = file,
            .line = if (span) |s| s.line else 0,
        };
    }

    fn appendReferences(self: *Tui, page: *PageBuilder, subject: vm_refs.Node) !void {
        // A standalone debugger pause has no background job loop. Build the
        // cold index only when a reference-bearing page is actually opened.
        if (self.references.graph == null and self.debug_session != null and !self.references.failed) {
            const graph = vm_refs.Graph.build(self.allocator, self.ev) catch {
                self.references.failed = true;
                return;
            };
            self.references.graph = graph;
        }

        const graph = self.references.graph orelse {
            // Preserve the immediately-useful chunk-to-chunk projection while
            // a full heap/chunk graph is being built in a normal :vm session.
            switch (subject) {
                .object => return,
                .chunk => |id| {
                    var outgoing: std.ArrayListUnmanaged(ChunkId) = .empty;
                    const chunk = self.ev.getChunk(id) orelse return;
                    try bytecode.inspect.collectRefs(page.arena, chunk, &outgoing);
                    try page.heading(try std.fmt.allocPrint(page.arena, "OUTGOING · {d}", .{outgoing.items.len}));
                    for (outgoing.items) |target| try self.appendChunkLabel(page, "  →", target);
                    return;
                },
            }
        };

        const outgoing = graph.outgoing(subject);
        try page.heading(try std.fmt.allocPrint(page.arena, "OUTGOING · {d}", .{outgoing.len}));
        for (outgoing) |edge| try self.appendReferenceLabel(page, "  →", vm_refs.node(edge.target));
        try page.line("", .none);
        const incoming = graph.incoming(subject);
        try page.heading(try std.fmt.allocPrint(page.arena, "INCOMING · {d}", .{incoming.len}));
        for (incoming) |edge| try self.appendReferenceLabel(page, "  ←", vm_refs.node(edge.target));
    }

    fn appendReferenceLabel(self: *Tui, page: *PageBuilder, marker: []const u8, reference: vm_refs.Node) !void {
        switch (reference) {
            .chunk => |id| try self.appendChunkLabel(page, marker, id),
            .object => |id| {
                if (self.heap_index.objects == null)
                    self.heap_index.objects = self.ev.heapObjectSnapshot(self.allocator) catch null;
                const prefix = try std.fmt.allocPrint(page.arena, "{s} ", .{marker});
                const width = self.lineRemainderWidth(prefix);
                const summary = try self.objectSummary(
                    page.arena,
                    id,
                    self.storePreviewBudget("objects", id, width),
                );
                try page.line(try std.fmt.allocPrint(page.arena, "{s}{s}", .{
                    prefix,
                    try self.canonicalStoreRef(page.arena, .objects, id, summary, true),
                }), .{ .object = id });
            },
        }
    }

    fn appendChunkLabel(self: *Tui, page: *PageBuilder, marker: []const u8, id: ChunkId) !void {
        var text: std.Io.Writer.Allocating = .init(page.arena);
        try text.writer.print("{s} chunk[0x{x}]", .{ marker, id });
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

    fn appendSourceDocument(
        self: *Tui,
        document: *PageBuilder,
        id: ChunkId,
        chunk: *const bytecode.Chunk,
        focused_span: ?bytecode.Chunk.SourceSpan,
    ) !void {
        const selecting_span = self.source_session == id;
        const span = if (selecting_span)
            focused_span orelse firstSourceSpan(chunk) orelse chunk.body_span
        else
            chunk.body_span orelse firstSourceSpan(chunk);
        const shown_span = span orelse {
            try document.heading("SOURCE");
            try document.line("(no source information)", .none);
            return;
        };

        const label, const source = if (shown_span.file) |file| blk: {
            const path = self.ev.internTable().get(file);
            break :blk .{ path, self.ev.readSourceFile(path) catch null };
        } else blk: {
            const direct = if (self.session_host) |host| host.directSource(id) else null;
            break :blk .{ "<repl expression>", direct };
        };

        try self.appendSourceHeading(document, id, chunk, shown_span);
        try document.line(try std.fmt.allocPrint(document.arena, "{s}:{d}:{d}", .{ label, shown_span.line, shown_span.column }), .none);
        const bytes = source orelse {
            try document.line("(source text is unavailable)", .none);
            return;
        };
        try self.appendSourceExcerpt(
            document,
            bytes,
            shown_span,
            id,
            sourceLocation(id, chunk, shown_span),
            selecting_span,
            false,
            null,
        );
    }

    fn appendSourceDocumentWithText(
        self: *Tui,
        document: *PageBuilder,
        id: ChunkId,
        chunk: *const bytecode.Chunk,
        source: []const u8,
        suggested_span: bytecode.Chunk.SourceSpan,
        returned_value: ?runtime.value.Value,
    ) !void {
        const span = if (sourceLocation(id, chunk, suggested_span) != null)
            suggested_span
        else
            firstSourceSpan(chunk) orelse suggested_span;
        try self.appendSourceHeading(document, id, chunk, span);
        try document.line(try std.fmt.allocPrint(document.arena, "{s}:{d}:{d}", .{
            if (span.file) |file| self.ev.internTable().get(file) else "<repl expression>",
            span.line,
            span.column,
        }), .none);
        try self.appendSourceExcerpt(
            document,
            source,
            span,
            id,
            sourceLocation(id, chunk, span),
            true,
            self.source_session != id,
            returned_value,
        );
    }

    fn appendSourceHeading(
        self: *const Tui,
        document: *PageBuilder,
        id: ChunkId,
        chunk: *const bytecode.Chunk,
        span: bytecode.Chunk.SourceSpan,
    ) !void {
        const stats = sourceSpanStats(chunk, span);
        if (stats.total == 0) {
            try document.heading("SOURCE");
        } else if (self.source_session == id) {
            try document.line(
                try std.fmt.allocPrint(document.arena, "SOURCE · {d}/{d} subexpressions", .{ stats.index, stats.total }),
                .{ .source = id },
            );
        } else {
            try document.line(
                try std.fmt.allocPrint(document.arena, "SOURCE · {d} subexpressions", .{stats.total}),
                .{ .source = id },
            );
        }
    }

    fn focusedSourceSpan(self: *const Tui, chunk_id: ChunkId) ?bytecode.Chunk.SourceSpan {
        const focus = self.source_focus orelse return null;
        return if (focus.chunk_id == chunk_id) focus.span else null;
    }

    /// Apply a newly selected source span by rebuilding the unified document.
    /// Afterwards, find the same source row by location so the cursor does not
    /// jump when the excerpt's line count changes.
    fn selectedSourceChanged(self: *Tui) !void {
        const source_session = self.source_session orelse return;
        const selected = self.selectedSourceLocation() orelse return;
        if (selected.chunk_id != source_session) return;
        self.source_focus = .{ .chunk_id = selected.chunk_id, .span = selected.span.? };

        const source_document = switch (self.currentKind()) {
            .debug_frame, .chunk => true,
            else => false,
        };
        if (!source_document) return;

        const kind = self.currentKind();
        try self.refreshPage(kind);
        for (self.page.locations, 0..) |candidate, i| {
            const location = candidate orelse continue;
            const span = location.span orelse continue;
            if (location.chunk_id == selected.chunk_id and
                location.offset == selected.offset and
                span.offset == selected.span.?.offset and
                span.len == selected.span.?.len)
            {
                self.navigation.detail_selection = i;
                self.ensureDetailVisible();
                break;
            }
        }
    }

    fn selectedSourceLocation(self: *const Tui) ?BreakpointLocation {
        if (self.navigation.detail_selection >= self.page.locations.len) return null;
        const location = self.page.locations[self.navigation.detail_selection] orelse return null;
        return if (location.span != null) location else null;
    }

    fn appendSourceExcerpt(
        self: *Tui,
        document: *PageBuilder,
        source: []const u8,
        span: bytecode.Chunk.SourceSpan,
        chunk_id: ?ChunkId,
        location: ?BreakpointLocation,
        focus_active: bool,
        show_instruction_pointer: bool,
        returned_value: ?runtime.value.Value,
    ) !void {
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
            if (active and show_instruction_pointer) {
                if (self.color_depth.enabled()) {
                    try base.terminal_color.foreground(&rendered.writer, self.color_depth, base.terminal_color.hueColor(3), true);
                } else {
                    try rendered.writer.writeAll("\x1b[1m");
                }
                try rendered.writer.writeAll("▶");
                try rendered.writer.writeAll("\x1b[0m");
            } else {
                try rendered.writer.writeByte(' ');
            }
            try rendered.writer.print(" {d:>5} │ ", .{line_number});
            const shown_end = @min(line_end, cursor +| 4096);
            const selected: ?source_render.Range = if (focus_active and active) blk: {
                const selected_start = @max(cursor, focus_start);
                const selected_end = @min(shown_end, @max(focus_end, focus_start +| 1));
                if (selected_start >= selected_end) break :blk null;
                break :blk .{ .start = selected_start - cursor, .end = selected_end - cursor };
            } else null;
            const breakpoints = if (chunk_id) |target|
                try self.sourceBreakpointRanges(document.arena, target, cursor, shown_end)
            else
                &.{};
            try source_render.writeLine(&rendered.writer, source[cursor..shown_end], .{
                .color_depth = self.color_depth,
                .focus = selected,
                .breakpoints = breakpoints,
            });
            if (line_end > cursor +| 4096) try rendered.writer.writeAll(" …");
            var wrapped_result: ?[]const u8 = null;
            const result_here = active and returned_value != null and focus_end <= line_end;
            if (result_here) {
                var annotation: std.Io.Writer.Allocating = .init(document.arena);
                try self.writeReturnAnnotation(
                    document.arena,
                    &annotation.writer,
                    returned_value.?,
                    self.layout().main_width -| 14,
                );
                if (tui.displayWidth(rendered.written(), width_mod.cpWidth) +
                    tui.displayWidth(annotation.written(), width_mod.cpWidth) <= self.layout().main_width -| 2)
                {
                    try rendered.writer.writeAll(annotation.written());
                } else {
                    wrapped_result = try std.fmt.allocPrint(document.arena, "        │ {s}", .{annotation.written()[2..]});
                }
            }
            var row_action: RowAction = if (active and location != null and self.source_session == location.?.chunk_id)
                .instruction
            else
                .none;
            if (result_here and wrapped_result == null) {
                const result_action = self.valueRowAction(returned_value.?);
                if (result_action != .none) row_action = result_action;
            }
            if (active and location != null) {
                try document.lineAt(rendered.written(), row_action, location.?);
            } else {
                try document.line(rendered.written(), row_action);
            }
            if (wrapped_result) |result|
                try document.line(result, self.valueRowAction(returned_value.?));
            line_number += 1;
            if (newline >= end or newline == source.len) break;
            cursor = newline + 1;
        }
    }

    /// A return result is a single styled badge. Value digests deliberately
    /// render without their own SGR resets here so the background remains
    /// continuous across the whole result.
    fn writeReturnAnnotation(
        self: *Tui,
        arena: std.mem.Allocator,
        writer: *std.Io.Writer,
        value: runtime.value.Value,
        max_cells: usize,
    ) !void {
        try writer.writeAll("  ");
        if (self.color_depth.enabled()) {
            if (self.return_flash) {
                try base.terminal_color.background(writer, self.color_depth, base.terminal_color.hueColor(3));
                try base.terminal_color.foreground(writer, self.color_depth, .{ 15, 23, 30 }, true);
            } else {
                try base.terminal_color.background(writer, self.color_depth, .{ 78, 62, 112 });
                try base.terminal_color.foreground(writer, self.color_depth, .{ 246, 248, 250 }, true);
            }
        } else {
            try writer.writeAll(if (self.return_flash) "\x1b[1;7m" else "\x1b[1;4m");
        }
        try writer.writeAll("⇒ ");
        const rendered = try self.renderValue(arena, value, max_cells, false);
        try writer.writeAll(rendered.text);
        try writer.writeAll("\x1b[0m");
    }

    fn sourceBreakpointRanges(
        self: *const Tui,
        arena: std.mem.Allocator,
        chunk_id: ChunkId,
        line_start: usize,
        line_end: usize,
    ) ![]const source_render.Range {
        var ranges: std.ArrayListUnmanaged(source_render.Range) = .empty;
        for (self.ev.listBreakpoints()) |request| {
            if (request.span_chunk != chunk_id) continue;
            const span = request.span orelse continue;
            const start = @max(line_start, @as(usize, span.offset));
            const end = @min(line_end, @as(usize, span.offset) +| @as(usize, span.len));
            if (start >= end) continue;
            try ranges.append(arena, .{
                .start = start - line_start,
                .end = end - line_start,
            });
        }
        return ranges.items;
    }

    /// Resolve the source text a chunk was compiled from (its file, or the
    /// remembered `:vm` repl expression), for source-span breakpoint snippets.
    fn chunkSourceText(self: *Tui, id: ChunkId, chunk: *const bytecode.Chunk) ?[]const u8 {
        for (chunk.source_map) |entry| if (entry.span.file) |file|
            return self.ev.readSourceFile(self.ev.internTable().get(file)) catch null;
        if (chunk.body_span) |span| if (span.file) |file|
            return self.ev.readSourceFile(self.ev.internTable().get(file)) catch null;
        if (self.session_host) |host| return host.directSource(id);
        return null;
    }

    fn sameSourceSpan(a: bytecode.Chunk.SourceSpan, b: bytecode.Chunk.SourceSpan) bool {
        return a.file == b.file and a.offset == b.offset and a.len == b.len;
    }

    fn sourceSpanLess(a: bytecode.Chunk.SourceSpan, b: bytecode.Chunk.SourceSpan) bool {
        if (a.offset != b.offset) return a.offset < b.offset;
        if (a.len != b.len) return a.len < b.len;
        if (a.line != b.line) return a.line < b.line;
        return a.column < b.column;
    }

    fn firstSourceSpan(chunk: *const bytecode.Chunk) ?bytecode.Chunk.SourceSpan {
        var first: ?bytecode.Chunk.SourceSpan = null;
        for (chunk.source_map) |entry| {
            if (first == null or sourceSpanLess(entry.span, first.?)) first = entry.span;
        }
        return first;
    }

    const SourceSpanStats = struct { index: usize, total: usize };

    fn sourceSpanStats(chunk: *const bytecode.Chunk, current: bytecode.Chunk.SourceSpan) SourceSpanStats {
        var total: usize = 0;
        var before: usize = 0;
        for (chunk.source_map, 0..) |entry, i| {
            var duplicate = false;
            for (chunk.source_map[0..i]) |previous| {
                if (sameSourceSpan(previous.span, entry.span)) {
                    duplicate = true;
                    break;
                }
            }
            if (duplicate) continue;
            total += 1;
            if (sourceSpanLess(entry.span, current)) before += 1;
        }
        return .{ .index = @min(before + 1, total), .total = total };
    }

    fn adjacentSourceSpan(
        chunk: *const bytecode.Chunk,
        current: bytecode.Chunk.SourceSpan,
        forward: bool,
    ) ?bytecode.Chunk.SourceSpan {
        var candidate: ?bytecode.Chunk.SourceSpan = null;
        for (chunk.source_map) |entry| {
            const span = entry.span;
            if (sameSourceSpan(span, current)) continue;
            const follows = sourceSpanLess(current, span);
            const precedes = sourceSpanLess(span, current);
            if ((forward and !follows) or (!forward and !precedes)) continue;
            if (candidate == null or
                (forward and sourceSpanLess(span, candidate.?)) or
                (!forward and sourceSpanLess(candidate.?, span)))
            {
                candidate = span;
            }
        }
        return candidate;
    }

    fn sourceLocation(
        id: ChunkId,
        chunk: *const bytecode.Chunk,
        span: bytecode.Chunk.SourceSpan,
    ) ?BreakpointLocation {
        var start: ?u32 = null;
        for (chunk.source_map) |entry| {
            if (!sameSourceSpan(entry.span, span)) continue;
            if (start == null or entry.start < start.?) start = entry.start;
        }
        return .{
            .chunk_id = id,
            .offset = start orelse return null,
            .line = span.line,
            .span = span,
        };
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

    fn layout(self: *const Tui) Layout {
        const cols = @max(@as(usize, 1), self.viewport.cols);
        const body_rows = self.viewport.rows;
        const split = cols >= 96;
        const sidebar_width = if (split) @max(cols * 3 / 10, 28) else 0;
        const inspector_width = if (split) cols - sidebar_width - 1 else cols;
        const main_col = if (split) sidebar_width + 2 else 1;
        return .{
            .cols = cols,
            .rows = body_rows + 2,
            .body_rows = body_rows,
            .split = split,
            .sidebar_width = sidebar_width,
            .main_col = main_col,
            .main_width = inspector_width,
        };
    }

    /// The chunk/object referenced by the selected detail row (for the
    /// right-hand preview), or null when there's nothing to peek into.
    fn detailPreviewAction(self: *const Tui) ?RowAction {
        if (self.navigation.focus != .subject) return null;
        const kind = self.currentKind();
        const is_value_subject = switch (kind) {
            .object, .store_record, .debug_value, .debug_frame => true,
            else => false,
        };
        if (!is_value_subject) return null;
        const idx = self.navigation.detail_selection;
        if (idx >= self.page.actions.len) return null;
        return switch (self.page.actions[idx]) {
            .object, .chunk, .store_record => self.page.actions[idx],
            else => null,
        };
    }

    fn currentKind(self: *const Tui) Visit.Kind {
        return self.navigation.back.items[self.navigation.back.items.len - 1].kind;
    }

    fn currentChunk(self: *const Tui) ?ChunkId {
        return switch (self.currentKind()) {
            .chunk => |id| id,
            .heap, .object, .store_record, .debug_frame, .debug_value, .help => null,
        };
    }

    /// The paused stack frame currently open in the inspector, if any.
    fn currentDebugFrame(self: *const Tui) ?usize {
        return switch (self.currentKind()) {
            .debug_frame => |i| i,
            else => null,
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

    const StoreRecord = struct { view: HeapView, id: u32 };

    fn currentStoreRecord(self: *const Tui) ?StoreRecord {
        return switch (self.currentKind()) {
            .store_record => |r| .{ .view = r.view, .id = r.id },
            else => null,
        };
    }

    fn liveObjectCount(stats: runtime.ObjectHeap.Stats) u32 {
        var total: u32 = 0;
        for (stats.variant_counts) |count| total += count;
        return total;
    }

    fn storeCount(self: *const Tui, view: HeapView) u32 {
        const c = self.ev.heapCounts();
        return switch (view) {
            .overview, .objects => c.objects,
            .values => c.values,
            .attrs => c.attrs,
            .attr_positions => c.attr_positions,
            .intern => self.ev.internTable().stats().entries,
            .builtin => @intCast(@typeInfo(runtime.builtins.BuiltinId).@"enum".fields.len),
        };
    }

    /// The number of LIVE records in a store (via its snapshot), falling back to
    /// the raw reserved count if the snapshot can't be built.
    fn liveStoreCount(self: *Tui, view: HeapView) u32 {
        if (view == .intern or view == .builtin) return self.storeCount(view);
        if (view == .objects or view == .overview)
            return if (self.heap_index.objects) |*s| s.live_count else if (self.heap_index.stats) |stats| liveObjectCount(stats) else 0;
        return if (self.ensureStoreSnapshot(view)) |s| s.live_count else self.storeCount(view);
    }

    /// The live-slot snapshot for a store, (re)built lazily when its slot count
    /// changes so browsing shows only real records, not reserved capacity.
    fn ensureStoreSnapshot(self: *Tui, view: HeapView) ?*const runtime.ObjectHeap.ObjectSnapshot {
        const slot: *?runtime.ObjectHeap.ObjectSnapshot, const cnt: *u32 = switch (view) {
            .values => .{ &self.heap_index.values, &self.heap_index.values_count },
            .attrs => .{ &self.heap_index.attrs, &self.heap_index.attrs_count },
            .attr_positions => .{ &self.heap_index.attr_positions, &self.heap_index.attr_positions_count },
            .overview, .objects, .intern, .builtin => return null,
        };
        const current = self.storeCount(view);
        if (slot.* == null or cnt.* != current) {
            if (slot.*) |*s| s.deinit();
            slot.* = (switch (view) {
                .values => self.ev.heapValueSnapshot(self.allocator),
                .attrs => self.ev.heapAttrSnapshot(self.allocator),
                .attr_positions => self.ev.heapAttrPosSnapshot(self.allocator),
                else => unreachable,
            }) catch {
                slot.* = null;
                return null;
            };
            cnt.* = current;
        }
        return if (slot.*) |*s| s else null;
    }

    fn rebuildTreeForCurrent(self: *Tui) !void {
        try self.rebuildTree(self.tree.projected_chunk orelse std.math.maxInt(ChunkId));
    }

    fn expandFocusedPath(self: *Tui, chunk_id: ChunkId) !void {
        self.tree.projected_chunk = chunk_id;
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
        // Remember the selected row's identity so the cursor stays put across a
        // rebuild (async index landing, an evaluation, a distant expand) instead
        // of snapping to whatever is open in the inspector. TreeRow is a value
        // type, so this copy survives clearRetainingCapacity.
        const prev: ?TreeRow = if (self.navigation.tree_selection < self.tree.rows.items.len)
            self.tree.rows.items[self.navigation.tree_selection]
        else
            null;
        self.tree.rows.clearRetainingCapacity();
        // The paused stack sits at the top of the tree while a debug session is
        // live, and vanishes the instant it ends.
        if (self.debug_session) |session| {
            try self.tree.rows.append(self.allocator, .{ .debug_root = .{ .depth = 0 } });
            var i = session.frameCount();
            while (i > 0) {
                i -= 1;
                try self.tree.rows.append(self.allocator, .{ .debug_frame = .{ .index = @intCast(i), .depth = 1 } });
            }
            if (session.reason == .break_builtin or session.reason == .eval_error) {
                try self.tree.rows.append(self.allocator, .{ .debug_value = .{ .depth = 1 } });
            }
        }
        try self.tree.rows.append(self.allocator, .{ .category = .{ .kind = .heap, .depth = 0 } });
        const heap_open = self.tree.categories[@intFromEnum(Category.heap)];
        const record_view = self.currentStoreRecord();
        if (heap_open or self.currentObject() != null or record_view != null) {
            for (std.meta.tags(HeapView)) |view| {
                // The aggregate census is not a browsable folder (it hijacked the
                // inspector with a cursorless page). It lives in the HEAP-row
                // preview and the `:vm heap` command instead.
                if (view == .overview) continue;
                // Keep a collapsed category showing just the store that owns the
                // currently-open record/object, projected in.
                const projected_view = (self.currentObject() != null and view == .objects) or
                    (record_view != null and record_view.?.view == view);
                if (!heap_open and !projected_view) continue;
                try self.tree.rows.append(self.allocator, .{ .heap = .{ .view = view, .depth = 1 } });
                const expanded = self.tree.heap_views[@intFromEnum(view)] or projected_view;
                if (!expanded) continue;
                const projected_only = !heap_open or !self.tree.heap_views[@intFromEnum(view)];
                if (view == .intern or view == .builtin) {
                    try self.appendDenseStoreRange(view, 0, self.storeCount(view), 2, projected_only);
                } else {
                    const snapshot = if (view == .objects)
                        (if (self.heap_index.objects) |*s| s else null)
                    else
                        self.ensureStoreSnapshot(view);
                    if (snapshot) |snap| {
                        try self.appendLiveRange(view, snap, 0, snap.liveExtent(), 2, projected_only);
                    }
                }
            }
        }
        try self.tree.rows.append(self.allocator, .{ .category = .{ .kind = .bytecode, .depth = 0 } });
        if (self.filterActive()) {
            try self.computeFilterKeep();
            try self.appendFilteredNameRows(vm_tree.root_node_id, 1);
        } else if (self.tree.categories[@intFromEnum(Category.bytecode)]) {
            try self.appendNameRows(vm_tree.root_node_id, 1, focused_chunk);
        } else if (self.currentChunk() != null) {
            try self.appendFocusedNameRows(vm_tree.root_node_id, 1, focused_chunk);
        }
        self.navigation.tree_selection = 0;
        // 1) Keep the cursor on the same row it was on, if it still exists.
        if (prev) |p| {
            for (self.tree.rows.items, 0..) |row, i| if (treeRowsEqual(row, p)) {
                self.navigation.tree_selection = i;
                return;
            };
        }
        // 2) Otherwise land on whatever the inspector currently shows.
        for (self.tree.rows.items, 0..) |row, i| switch (row) {
            .debug_frame => |entry| if (self.currentDebugFrame() == entry.index) {
                self.navigation.tree_selection = i;
                break;
            },
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

    fn filterActive(self: *const Tui) bool {
        return self.tree.filter_query.items.len > 0;
    }

    fn nodeMatchesFilter(self: *const Tui, node_id: u32) bool {
        const node = self.tree_index.node(node_id) orelse return false;
        return asciiContainsIgnoreCase(node.label, self.tree.filter_query.items);
    }

    /// Populate `filter_keep` with every name node on a path to a filter match.
    fn computeFilterKeep(self: *Tui) std.mem.Allocator.Error!void {
        self.tree.filter_keep.clearRetainingCapacity();
        if (!self.filterActive()) return;
        _ = try self.markFilterKeep(vm_tree.root_node_id);
        try self.tree.filter_keep.put(self.allocator, vm_tree.root_node_id, {});
    }

    fn markFilterKeep(self: *Tui, node_id: u32) std.mem.Allocator.Error!bool {
        var keep = self.nodeMatchesFilter(node_id);
        for (self.tree_index.childrenOf(node_id)) |child| {
            if (try self.markFilterKeep(child)) keep = true;
        }
        if (keep) try self.tree.filter_keep.put(self.allocator, node_id, {});
        return keep;
    }

    /// The filtered bytecode tree: fully expanded along kept paths, showing a
    /// matched node's own chunks. A node kept only because a descendant matched
    /// stays visible (an ancestor breadcrumb) without dumping its chunks.
    fn appendFilteredNameRows(self: *Tui, name: u32, depth: u16) std.mem.Allocator.Error!void {
        if (!self.tree.filter_keep.contains(name)) return;
        const children = self.tree_index.childrenOf(name);
        const chunks = self.tree_index.chunksOf(name);
        if (name != vm_tree.root_node_id and children.len == 0 and chunks.len == 1 and self.nodeMatchesFilter(name)) {
            try self.tree.rows.append(self.allocator, .{ .chunk = .{ .id = chunks[0], .depth = depth, .label = name } });
            return;
        }
        try self.tree.rows.append(self.allocator, .{ .name = .{ .id = name, .depth = depth } });
        const next_depth = depth +| 1;
        for (children) |child| {
            if (self.tree.filter_keep.contains(child)) try self.appendFilteredNameRows(child, next_depth);
        }
        if (self.nodeMatchesFilter(name)) {
            for (chunks) |id| try self.tree.rows.append(self.allocator, .{ .chunk = .{ .id = id, .depth = next_depth } });
        }
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

    fn storeRangeKind(view: HeapView) RangeKind {
        return switch (view) {
            .values => .values,
            .attrs => .attrs,
            .attr_positions => .attr_positions,
            .intern => .intern,
            .builtin => .builtin,
            .overview, .objects => .objects,
        };
    }

    fn liveRow(view: HeapView, id: u32, depth: u16) TreeRow {
        return if (view == .objects)
            .{ .object = .{ .id = id, .depth = depth } }
        else
            .{ .store_record = .{ .view = view, .id = id, .depth = depth } };
    }

    /// Dense stores have no reservation holes: every id below `count` is a
    /// real record. They still use the same bounded range fan-out and canonical
    /// store rows as sparse heap stores.
    fn appendDenseStoreRange(
        self: *Tui,
        view: HeapView,
        start: u32,
        len: u32,
        depth: u16,
        projected_only: bool,
    ) std.mem.Allocator.Error!void {
        if (len == 0) return;
        const focused = if (self.currentStoreRecord()) |r| (if (r.view == view) r.id else null) else null;
        const end = start + len;
        if (len <= range_leaf) {
            if (projected_only) {
                if (focused) |id| if (id >= start and id < end)
                    try self.tree.rows.append(self.allocator, liveRow(view, id, depth));
                return;
            }
            var id = start;
            while (id < end) : (id += 1)
                try self.tree.rows.append(self.allocator, liveRow(view, id, depth));
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
            const range: Range = .{
                .kind = storeRangeKind(view),
                .parent = 0,
                .start = child_start,
                .len = child_len,
                .live = child_len,
                .depth = depth,
            };
            try self.tree.rows.append(self.allocator, .{ .range = range });
            if (self.tree.expanded_ranges.contains(range.key())) {
                try self.appendDenseStoreRange(view, child_start, child_len, depth +| 1, false);
            } else if (contains_focus) {
                try self.appendDenseStoreRange(view, child_start, child_len, depth +| 1, true);
            }
        }
    }

    /// Bounded, liveness-filtered fan-out over any heap store (objects or the
    /// value/attr/attr-position range stores). Only slots that are actually live
    /// per `snapshot` are shown — reserved backing capacity (GC-freed ranges,
    /// unfilled TLAB tails) is skipped entirely, so browsing never surfaces dead
    /// slots as records.
    fn appendLiveRange(
        self: *Tui,
        view: HeapView,
        snapshot: *const runtime.ObjectHeap.ObjectSnapshot,
        start: u32,
        len: u32,
        depth: u16,
        projected_only: bool,
    ) std.mem.Allocator.Error!void {
        if (len == 0) return;
        const end = start + len;
        const focused: ?u32 = if (view == .objects)
            self.currentObject()
        else if (self.currentStoreRecord()) |r| (if (r.view == view) r.id else null) else null;
        if (len <= range_leaf) {
            if (projected_only) {
                if (focused) |id| if (id >= start and id < end and snapshot.isLive(id)) {
                    try self.tree.rows.append(self.allocator, liveRow(view, id, depth));
                };
                return;
            }
            var next = snapshot.nextLive(start);
            while (next) |id| : (next = snapshot.nextLive(id + 1)) {
                if (id >= end) break;
                try self.tree.rows.append(self.allocator, liveRow(view, id, depth));
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
            var live: u32 = 0;
            var next: ?u32 = first_live;
            while (next) |id| : (next = snapshot.nextLive(id + 1)) {
                if (id >= child_end) break;
                live += 1;
            }
            const range: Range = .{
                .kind = storeRangeKind(view),
                .parent = 0,
                .start = child_start,
                .len = child_len,
                .live = live,
                .depth = depth,
            };
            try self.tree.rows.append(self.allocator, .{ .range = range });
            if (self.tree.expanded_ranges.contains(range.key())) {
                try self.appendLiveRange(view, snapshot, child_start, child_len, depth +| 1, false);
            } else if (contains_focus) {
                try self.appendLiveRange(view, snapshot, child_start, child_len, depth +| 1, true);
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
                .live = @min(span, len - offset),
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
                .live = @min(span, len - offset),
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
        self.preview.reset();
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
            // Browsing the tree replaces the current view rather than pushing a
            // history entry (only followed reference links do that).
            .chunk => |entry| try self.openMode(.{ .chunk = entry.id }, .replace),
            .heap => |entry| {
                // The overview is the only heap folder that opens a page (the
                // aggregate census). Every store folder just expands into its
                // records in place — expanding a folder shouldn't hijack the
                // inspector with an unhelpful, cursorless store page.
                if (entry.view == .overview) {
                    try self.openMode(.{ .heap = entry.view }, .replace);
                    return;
                }
                const opening = !self.tree.heap_views[@intFromEnum(entry.view)];
                if (opening and entry.view == .objects and self.heap_index.objects == null) {
                    self.heap_index.objects = self.ev.heapObjectSnapshot(self.allocator) catch null;
                    if (self.heap_index.objects == null) self.status_msg = "(object index failed)";
                }
                self.tree.heap_views[@intFromEnum(entry.view)] = opening;
                try self.rebuildTreeForCurrent();
                for (self.tree.rows.items, 0..) |row, i| switch (row) {
                    .heap => |candidate| if (candidate.view == entry.view) {
                        self.navigation.tree_selection = i;
                        break;
                    },
                    else => {},
                };
            },
            .object => |entry| try self.openMode(.{ .object = entry.id }, .replace),
            .store_record => |entry| try self.openMode(.{ .store_record = .{ .view = entry.view, .id = entry.id } }, .replace),
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
            .debug_frame => |entry| try self.openMode(.{ .debug_frame = entry.index }, .replace),
            .debug_value => try self.openMode(.debug_value, .replace),
            .debug_root => {},
        }
    }

    fn collapseTreeRow(self: *Tui) !void {
        if (self.navigation.tree_selection >= self.tree.rows.items.len) return;
        const selected = self.tree.rows.items[self.navigation.tree_selection];
        const collapsed = switch (selected) {
            .category => |entry| blk: {
                const index = @intFromEnum(entry.kind);
                if (!self.tree.categories[index]) break :blk false;
                self.tree.categories[index] = false;
                break :blk true;
            },
            .name => |entry| self.tree.expanded_names.remove(entry.id),
            .range => |entry| self.tree.expanded_ranges.remove(entry.key()),
            .heap => |entry| blk: {
                if (entry.view == .overview or !self.tree.heap_views[@intFromEnum(entry.view)])
                    break :blk false;
                self.tree.heap_views[@intFromEnum(entry.view)] = false;
                break :blk true;
            },
            else => false,
        };
        if (collapsed) {
            try self.rebuildTreeForCurrent();
            for (self.tree.rows.items, 0..) |row, i| if (treeRowsEqual(row, selected)) {
                self.navigation.tree_selection = i;
                return;
            };
            return;
        }

        // Rows are preorder-flattened. The nearest preceding shallower row is
        // therefore the parent for every node kind: chunk, object, store value,
        // synthetic range, heap folder, name, and paused frame alike.
        const selected_depth = treeRowDepth(selected);
        var cursor = self.navigation.tree_selection;
        while (cursor > 0) {
            cursor -= 1;
            if (treeRowDepth(self.tree.rows.items[cursor]) < selected_depth) {
                self.navigation.tree_selection = cursor;
                return;
            }
        }
    }

    fn selectCurrentTreeSubject(self: *Tui) void {
        for (self.tree.rows.items, 0..) |row, i| {
            const matches = switch (row) {
                .chunk => |entry| if (self.currentChunk()) |id| entry.id == id else false,
                .object => |entry| if (self.currentObject()) |id| entry.id == id else false,
                .store_record => |entry| if (self.currentStoreRecord()) |record|
                    entry.view == record.view and entry.id == record.id
                else
                    false,
                .heap => |entry| if (self.currentHeap()) |view| entry.view == view else false,
                .debug_frame => |entry| if (self.currentDebugFrame()) |index| entry.index == index else false,
                .debug_value => self.currentKind() == .debug_value,
                else => false,
            };
            if (matches) {
                self.navigation.tree_selection = i;
                return;
            }
        }
    }

    fn selectedTreeRowIsCurrentSubject(self: *const Tui) bool {
        if (self.navigation.tree_selection >= self.tree.rows.items.len) return false;
        return switch (self.tree.rows.items[self.navigation.tree_selection]) {
            .chunk => |entry| self.currentChunk() == entry.id,
            .object => |entry| self.currentObject() == entry.id,
            .store_record => |entry| if (self.currentStoreRecord()) |record|
                record.view == entry.view and record.id == entry.id
            else
                false,
            .heap => |entry| self.currentHeap() == entry.view,
            .debug_frame => |entry| self.currentDebugFrame() == entry.index,
            .debug_value => self.currentKind() == .debug_value,
            else => false,
        };
    }

    fn treeSelectionCanMoveUp(self: *const Tui) bool {
        if (self.navigation.tree_selection >= self.tree.rows.items.len) return false;
        const row = self.tree.rows.items[self.navigation.tree_selection];
        if (treeRowDepth(row) > 0) return true;
        return switch (row) {
            .category => |entry| self.tree.categories[@intFromEnum(entry.kind)],
            .name => |entry| self.tree.expanded_names.contains(entry.id),
            .range => |entry| self.tree.expanded_ranges.contains(entry.key()),
            .heap => |entry| entry.view != .overview and self.tree.heap_views[@intFromEnum(entry.view)],
            else => false,
        };
    }

    /// Escape unwinds one interaction layer. It leaves an in-place source
    /// session first, then the inspector, then nested/expanded tree rows. Only
    /// an Escape at the tree root asks the caller to leave the explorer.
    fn escapeLayer(self: *Tui) !bool {
        switch (vm_navigation.escapeAction(.{
            .source_active = self.source_session != null,
            .focus = self.navigation.focus,
            .filter_active = self.filterActive(),
            .tree_can_move_up = self.treeSelectionCanMoveUp(),
        })) {
            .leave_source => {
                try self.leaveSourceSession(self.source_session.?);
                self.status_msg = "";
                return true;
            },
            .focus_tree => {
                self.navigation.focus = .tree;
                self.preview.reset();
                self.selectCurrentTreeSubject();
                return true;
            },
            .clear_filter => {
                self.tree.filter_query.clearRetainingCapacity();
                try self.rebuildTreeForCurrent();
                self.status_msg = "(filter cleared)";
                return true;
            },
            .tree_up => {
                try self.collapseTreeRow();
                self.preview.reset();
                return true;
            },
            .exit => return false,
        }
    }

    /// `.push` records a back/forward history entry (following a reference link,
    /// or entering a debug pause). `.replace` swaps the current view in place so
    /// ordinary tree browsing doesn't accumulate a noisy history trail.
    const OpenMode = enum { push, replace };

    fn open(self: *Tui, kind: Visit.Kind) !void {
        return self.openMode(kind, .push);
    }

    fn openMode(self: *Tui, kind: Visit.Kind, mode: OpenMode) !void {
        // Save current position into the top-of-stack visit.
        if (self.navigation.back.items.len > 0) {
            const top = &self.navigation.back.items[self.navigation.back.items.len - 1];
            top.scroll = self.navigation.scroll;
            top.tree_selection = self.navigation.tree_selection;
            top.detail_selection = self.navigation.detail_selection;
            top.x_scroll = self.navigation.x_scroll;
        }
        if (mode == .replace and self.navigation.back.items.len > 0) {
            self.navigation.back.items[self.navigation.back.items.len - 1] = .{ .kind = kind };
        } else {
            try self.navigation.back.append(self.allocator, .{ .kind = kind });
        }
        self.navigation.forward.clearRetainingCapacity();
        self.source_focus = null;
        self.source_session = null;
        self.preview.reset();
        try self.refreshPage(kind);
        self.navigation.scroll = 0;
        self.navigation.detail_selection = self.firstActionableRow() orelse 0;
        try self.selectedSourceChanged();
        // A tree row is already visible, so opening it must not rebuild or
        // re-project the tree. Only subjects reached from outside the tree
        // reveal their path/store.
        if (mode == .push) switch (kind) {
            .chunk => |id| {
                try self.expandFocusedPath(id);
                try self.rebuildTree(id);
            },
            .object => {
                self.tree.categories[@intFromEnum(Category.heap)] = true;
                try self.rebuildTreeForCurrent();
            },
            .heap, .store_record => {
                self.tree.categories[@intFromEnum(Category.heap)] = true;
                try self.rebuildTreeForCurrent();
            },
            .debug_frame, .debug_value => try self.rebuildTreeForCurrent(),
            .help => {},
        };
        self.navigation.x_scroll = 0;
        // Replacing the subject is tree browsing: keep the cursor in the tree.
        // Pushed visits originate outside it (detail links, debugger entry,
        // commands) and may choose the inspector as their natural destination.
        if (mode == .push) switch (kind) {
            .help => self.navigation.focus = .subject,
            .heap, .object, .store_record, .debug_frame, .debug_value => self.navigation.focus = .subject,
            .chunk => {},
        };
        self.status_msg = "";
    }

    fn back(self: *Tui) !void {
        if (self.navigation.back.items.len < 2) {
            self.status_msg = "(bottom of history)";
            return;
        }
        try self.navigation.forward.append(self.allocator, self.navigation.back.pop().?);
        const visit = self.navigation.back.items[self.navigation.back.items.len - 1];
        self.source_focus = null;
        self.source_session = null;
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
        try self.selectedSourceChanged();
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
        self.source_focus = null;
        self.source_session = null;
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
        try self.selectedSourceChanged();
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
        return switch (self.page.actions[index]) {
            .chunk, .object, .store_record, .source, .instruction => true,
            .none, .section => false,
        };
    }

    fn firstActionableRow(self: *const Tui) ?usize {
        for (self.page.actions, 0..) |action, i| switch (action) {
            .chunk, .object, .store_record, .source, .instruction => return i,
            .none, .section => {},
        };
        return null;
    }

    fn toggleSelectedBreakpoint(self: *Tui) !void {
        if (self.navigation.focus != .subject) {
            self.status_msg = "(focus the code pane first)";
            return;
        }
        if (self.navigation.detail_selection < self.page.actions.len and
            self.page.actions[self.navigation.detail_selection] == .source)
        {
            self.status_msg = "(Enter SOURCE to select a subexpression)";
            return;
        }
        if (self.navigation.detail_selection >= self.page.locations.len) {
            self.status_msg = "(select an instruction with source)";
            return;
        }
        const location = self.page.locations[self.navigation.detail_selection] orelse {
            self.status_msg = "(selected row has no instruction)";
            return;
        };
        if (self.hasBreakpoint(location)) {
            if (location.span) |span|
                _ = self.ev.deleteBreakpointSpan(location.chunk_id, span)
            else
                _ = self.ev.deleteBreakpointAt(location.chunk_id, location.offset);
            self.status_msg = if (location.span) |span|
                std.fmt.bufPrint(&self.status_buf, "cleared breakpoint · chunk[0x{x}] L{d}:{d}", .{
                    location.chunk_id,
                    span.line,
                    span.column,
                }) catch "cleared breakpoint"
            else
                std.fmt.bufPrint(&self.status_buf, "cleared breakpoint · chunk[0x{x}] @0x{x}", .{
                    location.chunk_id,
                    location.offset,
                }) catch "cleared breakpoint";
            return;
        }
        const result = (if (location.span) |span|
            self.ev.setBreakpointSpan(location.chunk_id, span)
        else
            self.ev.setBreakpointAt(location.chunk_id, location.offset)) catch |err| {
            self.status_msg = std.fmt.bufPrint(&self.status_buf, "breakpoint failed: {s}", .{@errorName(err)}) catch "breakpoint failed";
            return;
        };
        if (result.sites == 0) {
            self.status_msg = if (location.span != null)
                "(span has no distinct execution site)"
            else
                "(not an instruction boundary)";
            return;
        }
        self.status_msg = if (location.span) |span|
            std.fmt.bufPrint(&self.status_buf, "breakpoint · chunk[0x{x}] L{d}:{d}", .{
                location.chunk_id,
                span.line,
                span.column,
            }) catch "breakpoint set"
        else
            std.fmt.bufPrint(&self.status_buf, "breakpoint · chunk[0x{x}] @0x{x}", .{
                location.chunk_id,
                location.offset,
            }) catch "breakpoint set";
    }

    fn moveDetail(self: *Tui, forward: bool) void {
        if (self.page.actions.len == 0) return;
        self.preview.reset();
        if (self.selectedSourceLocation()) |location| {
            if (self.source_session == location.chunk_id) if (self.ev.getChunk(location.chunk_id)) |chunk| {
                if (adjacentSourceSpan(chunk, location.span.?, forward)) |span| {
                    self.source_focus = .{ .chunk_id = location.chunk_id, .span = span };
                    const kind = self.currentKind();
                    self.refreshPage(kind) catch {
                        self.status_msg = "(source preview unavailable)";
                        return;
                    };
                    for (self.page.locations, 0..) |candidate, i| {
                        const next = candidate orelse continue;
                        const next_span = next.span orelse continue;
                        if (next.chunk_id == location.chunk_id and sameSourceSpan(next_span, span)) {
                            self.navigation.detail_selection = i;
                            self.ensureDetailVisible();
                            break;
                        }
                    }
                    return;
                }
            };
        }
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
                self.selectedSourceChanged() catch {
                    self.status_msg = "(source preview unavailable)";
                };
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

    fn activateDetailRow(self: *Tui) !void {
        if (self.navigation.detail_selection >= self.page.actions.len) return;
        switch (self.page.actions[self.navigation.detail_selection]) {
            .chunk => |id| try self.open(.{ .chunk = id }),
            .object => |id| try self.open(.{ .object = id }),
            .store_record => |record| try self.open(.{ .store_record = .{ .view = record.view, .id = record.id } }),
            .source => |id| try self.enterSourceSession(id),
            .instruction, .none, .section => {},
        }
    }

    fn enterSourceSession(self: *Tui, chunk_id: ChunkId) !void {
        const chunk = self.ev.getChunk(chunk_id) orelse return;
        var span = self.focusedSourceSpan(chunk_id);
        if (span == null) span = firstSourceSpan(chunk);
        if (span == null) for (self.page.locations) |candidate| {
            const location = candidate orelse continue;
            if (location.chunk_id == chunk_id and location.span != null) {
                span = location.span;
                break;
            }
        };
        const selected_span = span orelse return;
        self.source_focus = .{ .chunk_id = chunk_id, .span = selected_span };
        self.source_session = chunk_id;
        try self.refreshPage(self.currentKind());
        for (self.page.locations, 0..) |candidate, i| {
            const location = candidate orelse continue;
            const candidate_span = location.span orelse continue;
            if (location.chunk_id == chunk_id and sameSourceSpan(candidate_span, selected_span)) {
                self.navigation.detail_selection = i;
                self.ensureDetailVisible();
                return;
            }
        }
    }

    fn leaveSourceSession(self: *Tui, chunk_id: ChunkId) !void {
        self.source_session = null;
        try self.refreshPage(self.currentKind());
        for (self.page.actions, 0..) |action, i| switch (action) {
            .source => |id| if (id == chunk_id) {
                self.navigation.detail_selection = i;
                self.ensureDetailVisible();
                return;
            },
            else => {},
        };
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
        if (key.alt) switch (key.code) {
            .cp => |cp| switch (cp) {
                'j' => {
                    self.preview.move(1);
                    return true;
                },
                'k' => {
                    self.preview.move(-1);
                    return true;
                },
                else => {},
            },
            .down => {
                self.preview.move(1);
                return true;
            },
            .up => {
                self.preview.move(-1);
                return true;
            },
            else => {},
        };
        switch (key.code) {
            .cp => |cp| switch (cp) {
                'q' => return false,
                'j' => {
                    if (self.navigation.focus == .tree) {
                        self.moveTree(true);
                    } else {
                        self.moveDetail(true);
                    }
                },
                'k' => {
                    if (self.navigation.focus == .tree) {
                        self.moveTree(false);
                    } else {
                        self.moveDetail(false);
                    }
                },
                'd' => {
                    if (self.navigation.focus == .subject) self.navigation.scroll = @min(self.navigation.scroll + self.contentRows() / 2, self.maxScroll());
                },
                'u' => {
                    if (self.navigation.focus == .subject) self.navigation.scroll -|= self.contentRows() / 2;
                },
                'g' => {
                    if (self.navigation.focus == .tree) {
                        self.navigation.tree_selection = 0;
                    } else {
                        self.navigation.detail_selection = self.firstActionableRow() orelse 0;
                        self.ensureDetailVisible();
                        try self.selectedSourceChanged();
                    }
                },
                'G' => {
                    if (self.navigation.focus == .tree) {
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
                        try self.selectedSourceChanged();
                    }
                },
                'h' => {
                    if (self.navigation.focus == .subject) self.navigation.x_scroll -|= 4;
                },
                'l' => {
                    if (self.navigation.focus == .subject) self.navigation.x_scroll = @min(self.navigation.x_scroll + 4, self.maxXScroll());
                },
                'b' => try self.back(),
                'f' => try self.goForward(),
                'p' => try self.toggleSelectedBreakpoint(),
                'F' => try self.filterPrompt(),
                '?' => try self.toggleHelp(),
                '/' => {
                    if (self.navigation.focus == .subject) try self.searchPrompt();
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
                if (self.navigation.focus == .tree) self.moveTree(false) else self.moveDetail(false);
            },
            .down => {
                if (self.navigation.focus == .tree) {
                    self.moveTree(true);
                } else {
                    self.moveDetail(true);
                }
            },
            .left => {
                if (self.navigation.focus == .tree) try self.collapseTreeRow() else self.navigation.x_scroll -|= 4;
            },
            .right => {
                if (self.navigation.focus == .tree) {
                    try self.activateTreeRow();
                } else {
                    self.navigation.x_scroll = @min(self.navigation.x_scroll + 4, self.maxXScroll());
                }
            },
            .page_up => {
                if (self.navigation.focus == .subject) self.navigation.scroll -|= self.contentRows();
            },
            .page_down => {
                if (self.navigation.focus == .subject) self.navigation.scroll = @min(self.navigation.scroll + self.contentRows(), self.maxScroll());
            },
            .home => {
                if (self.navigation.focus == .tree) self.navigation.tree_selection = 0 else {
                    self.navigation.detail_selection = self.firstActionableRow() orelse 0;
                    self.ensureDetailVisible();
                    try self.selectedSourceChanged();
                }
            },
            .end => {
                if (self.navigation.focus == .tree) self.navigation.tree_selection = self.tree.rows.items.len -| 1 else self.navigation.scroll = self.maxScroll();
            },
            .tab, .backtab => {
                if (self.navigation.focus == .tree) {
                    self.navigation.focus = .subject;
                } else {
                    self.navigation.focus = .tree;
                }
            },
            .enter => {
                if (self.navigation.focus == .tree) try self.activateTreeRow() else try self.activateDetailRow();
            },
            .escape => return true,
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

    /// Modal filter input on the status row. Enter applies the substring filter
    /// to the bytecode name tree; Esc clears it. An empty query means no filter.
    fn filterPrompt(self: *Tui) !void {
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
            var line_buf: [1024]u8 = undefined;
            const line = std.fmt.bufPrint(&line_buf, "filter (name): {s}", .{self.tree.filter_query.items}) catch "filter:";
            try frame.text(line, 0, size.cols, .section);
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
                        try self.rebuildTreeForCurrent();
                        self.status_msg = if (self.filterActive()) "(filter applied)" else "(filter cleared)";
                        return;
                    },
                    .escape => {
                        self.tree.filter_query.clearRetainingCapacity();
                        try self.rebuildTreeForCurrent();
                        self.status_msg = "(filter cleared)";
                        return;
                    },
                    .backspace => {
                        if (self.tree.filter_query.items.len > 0) _ = self.tree.filter_query.pop();
                    },
                    .cp => |cp| {
                        if (key.isCtrl('g') or key.isCtrl('c')) {
                            self.tree.filter_query.clearRetainingCapacity();
                            try self.rebuildTreeForCurrent();
                            return;
                        }
                        if (cp >= 0x20 and cp != 0x7F) {
                            var utf8: [4]u8 = undefined;
                            const n = std.unicode.utf8Encode(cp, &utf8) catch continue;
                            try self.tree.filter_query.appendSlice(self.allocator, utf8[0..n]);
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
        // The explorer stays visible even while the prompt is active: the prompt
        // claims only its own rows at the very bottom, so entering `:`/`i` no
        // longer blows the tree/inspector away.
        if (upper_rows >= 7) {
            transcript_rows = @min(@max(@as(usize, 2), upper_rows / 5), 5);
            explorer_rows = upper_rows - transcript_rows - 1;
        }

        if (explorer_rows > 0 and (self.viewport.cols != cols or self.viewport.rows != explorer_rows)) {
            self.viewport.cols = cols;
            self.viewport.rows = explorer_rows;
            try self.refreshPage(self.currentKind());
        }

        const mode: []const u8 = if (prompt_active) "repl" else if (self.navigation.focus == .tree) "tree" else "inspector";
        var header_buf: [512]u8 = undefined;
        const header = if (self.debug_session) |session|
            std.fmt.bufPrint(&header_buf, " fix vm  ·  ◆ paused/{s}  ·  frame {?d}  ·  {s} ", .{
                reasonName(session.reason),
                self.currentDebugFrame(),
                mode,
            }) catch " fix vm  ·  paused "
        else if (self.currentChunk()) |id|
            std.fmt.bufPrint(&header_buf, " fix vm  ·  chunk[0x{x}]  ·  {s} ", .{
                id,
                if (prompt_active) "repl" else if (self.navigation.focus == .tree) "tree" else "inspector",
            }) catch " fix repl "
        else if (self.currentHeap()) |view|
            std.fmt.bufPrint(&header_buf, " fix vm  ·  heap/{s}  ·  {s} ", .{
                @tagName(view),
                if (prompt_active) "repl" else if (self.navigation.focus == .tree) "tree" else "inspector",
            }) catch " fix vm "
        else if (self.currentObject()) |id|
            std.fmt.bufPrint(&header_buf, " fix vm  ·  objects[0x{x}]  ·  {s} ", .{
                id,
                if (prompt_active) "repl" else if (self.navigation.focus == .tree) "tree" else "inspector",
            }) catch " fix vm "
        else if (self.currentStoreRecord()) |record|
            std.fmt.bufPrint(&header_buf, " fix vm  ·  {s}[0x{x}]  ·  {s} ", .{
                @tagName(record.view),
                record.id,
                if (prompt_active) "repl" else if (self.navigation.focus == .tree) "tree" else "inspector",
            }) catch " fix vm "
        else
            std.fmt.bufPrint(&header_buf, " fix vm  ·  help  ·  {s} ", .{
                if (prompt_active) "repl" else if (self.navigation.focus == .tree) "tree" else "inspector",
            }) catch " fix vm ";
        try frame.bar(1, header, cols, .header);

        if (explorer_rows > 0) {
            try self.drawExplorerBody(arena, &frame, 2, explorer_rows, cols);
            const separator_row = 2 + explorer_rows;
            try frame.clearRow(separator_row);
            const separator = " ─ transcript ";
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
        else if (self.debug_session != null)
            " s step · n next · f finish · c continue · p break · ↵ inspect · i expr · q abort "
        else if (self.filterActive())
            std.fmt.bufPrint(&footer_buf, " filter '{s}' · F edit · Esc up/clear · q exit · Tab pane · ↵ inspect ", .{self.tree.filter_query.items}) catch " filtered "
        else
            " Esc up · q exit · i expr · : cmd · Tab pane · p break · F filter · ↵ inspect ";
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
                const inspector_focused = self.navigation.focus == .subject;
                try self.drawFocusDivider(frame, screen_row, layout_now.sidebar_width + 1, inspector_focused);
                try frame.at(screen_row, layout_now.main_col);
                try self.drawDisasmRow(frame, row, layout_now.main_width);
            } else if (self.navigation.focus == .tree) {
                try frame.at(screen_row, 1);
                try self.drawChunkRow(arena, frame, row, cols, rows);
            } else {
                try frame.at(screen_row, 1);
                try self.drawDisasmRow(frame, row, layout_now.main_width);
            }
        }

        // Peeks are overlays, not columns: moving the selection no longer
        // changes either pane's width or reflows the inspector.
        const popup_width = self.hoverMaxOuterWidth(cols, layout_now) -| 2;
        const popup = if (self.navigation.focus == .tree and !self.selectedTreeRowIsCurrentSubject())
            try self.previewLines(arena, popup_width)
        else if (self.detailPreviewAction() != null)
            try self.detailPreviewLines(arena, popup_width)
        else
            &.{};
        if (popup.len > 1 and cols >= 40 and rows >= 6)
            try self.drawHoverPopup(arena, frame, first_row, rows, cols, layout_now, popup);
    }

    fn previewRole(self: *const Tui) tui.Role {
        if (self.navigation.focus == .subject) return switch (self.detailPreviewAction() orelse return .section) {
            .chunk => .chunk,
            .object, .store_record => .object,
            else => .section,
        };
        if (self.navigation.tree_selection >= self.tree.rows.items.len) return .section;
        return switch (self.tree.rows.items[self.navigation.tree_selection]) {
            .chunk => .chunk,
            .object, .store_record, .heap => .object,
            .range => .range,
            .name => .name,
            else => .section,
        };
    }

    fn hoverMaxOuterWidth(self: *const Tui, cols: usize, layout_now: Layout) usize {
        const available = if (self.navigation.focus == .tree)
            (if (layout_now.split) cols -| layout_now.sidebar_width -| 2 else cols * 2 / 3)
        else
            cols * 2 / 3;
        return @min(@as(usize, 76), available);
    }

    fn drawHoverPopup(
        self: *Tui,
        arena: std.mem.Allocator,
        frame: *tui.Frame,
        first_row: usize,
        rows: usize,
        cols: usize,
        layout_now: Layout,
        lines: []const []const u8,
    ) !void {
        const max_outer = self.hoverMaxOuterWidth(cols, layout_now);
        if (max_outer < 4) return;
        var desired: usize = @min(@as(usize, 28), max_outer);
        for (lines) |line| desired = @max(desired, tui.displayWidth(line, width_mod.cpWidth) + 2);
        const outer_width = @min(max_outer, desired);
        const content_width = outer_width - 2;
        const body_total = lines.len - 1;
        const body_visible = @min(body_total, rows - 3);
        const body_start = self.preview.window(body_total, body_visible);
        const visible = body_visible + 1;
        const outer_height = visible + 2;
        const preview_heading = if (body_total > body_visible)
            try std.fmt.allocPrint(arena, "{s} · Alt-j/k · {d}-{d}/{d}", .{
                lines[0],
                body_start + 1,
                body_start + body_visible,
                body_total,
            })
        else
            lines[0];

        const anchor_row = if (self.navigation.focus == .tree)
            self.treeSelectionSlot(if (layout_now.split) layout_now.sidebar_width else cols, rows) orelse 0
        else
            self.navigation.detail_selection -| self.navigation.scroll;
        // Put the first content row level with the selected row whenever there
        // is room: the popup reads as attached to the cursor instead of as a
        // remote panel.
        const top = first_row + @min(anchor_row -| 1, rows - outer_height);
        const left = if (self.navigation.focus == .tree)
            if (layout_now.split)
                layout_now.main_col
            else
                @min(cols / 3 + 1, cols - outer_width + 1)
        else
            cols - outer_width + 1;
        const role = self.previewRole();
        const fill = try arena.alloc(u8, content_width);
        @memset(fill, ' ');
        var horizontal: std.Io.Writer.Allocating = .init(arena);
        for (0..content_width) |_| try horizontal.writer.writeAll("─");

        try frame.at(top, left);
        try frame.text("╭", 0, 1, role);
        try frame.text(horizontal.written(), 0, content_width, role);
        try frame.text("╮", 0, 1, role);

        for (0..visible) |i| {
            const line_index = if (i == 0) 0 else 1 + body_start + i - 1;
            const display_line = if (i == 0) preview_heading else lines[line_index];
            const screen_row = top + 1 + i;
            try frame.at(screen_row, left);
            try frame.text("│", 0, 1, role);
            try frame.at(screen_row, left + 1);
            try frame.text(fill, 0, content_width, .plain);
            try frame.at(screen_row, left + 1);
            const line_width = tui.displayWidth(display_line, width_mod.cpWidth);
            if (line_width > content_width and content_width > 0) {
                try frame.text(display_line, 0, content_width -| 1, if (i == 0) role else .plain);
                try frame.at(screen_row, left + outer_width - 2);
                try frame.text("…", 0, 1, if (i == 0) role else .plain);
            } else {
                try frame.text(display_line, 0, content_width, if (i == 0) role else .plain);
            }
            try frame.at(screen_row, left + outer_width - 1);
            try frame.text("│", 0, 1, role);
        }

        const bottom = top + outer_height - 1;
        try frame.at(bottom, left);
        try frame.text("╰", 0, 1, role);
        try frame.text(horizontal.written(), 0, content_width, role);
        try frame.text("╯", 0, 1, role);
    }

    /// A compact preview of the highlighted tree row for the right-hand pane.
    /// This reflects the cursor, not the open inspector, so you can look ahead
    /// while browsing without leaving the current subject.
    fn previewLines(self: *Tui, arena: std.mem.Allocator, content_width: usize) ![]const []const u8 {
        var lines: std.ArrayListUnmanaged([]const u8) = .empty;
        try lines.append(arena, " PREVIEW");
        if (self.navigation.tree_selection >= self.tree.rows.items.len) return lines.items;
        switch (self.tree.rows.items[self.navigation.tree_selection]) {
            .chunk => |entry| {
                try lines.append(arena, try std.fmt.allocPrint(arena, " chunk[0x{x}]", .{entry.id}));
                if (self.ev.chunkRegistry().hasQualifiedName(entry.id)) {
                    var name: std.Io.Writer.Allocating = .init(arena);
                    self.ev.chunkRegistry().writeQualifiedName(&name.writer, entry.id, self.ev.internTable()) catch {};
                    if (name.written().len > 0) try lines.append(arena, try std.fmt.allocPrint(arena, " {s}", .{name.written()}));
                }
                if (self.ev.getChunk(entry.id)) |chunk| {
                    try lines.append(arena, try std.fmt.allocPrint(arena, " {d} bytes · {d} consts", .{ chunk.code.len, chunk.constants.len }));
                    try lines.append(arena, try std.fmt.allocPrint(arena, " arity {d} · {d} spans", .{ chunk.arity, chunk.source_map.len }));
                    if (chunk.source_map.len > 0) {
                        try lines.append(arena, "");
                        const src = self.chunkSourceText(entry.id, chunk);
                        for (chunk.source_map, 0..) |sm, i| {
                            if (i >= 6) break;
                            const snip = spanSnippet(arena, src, sm.span, content_width -| 1) catch "";
                            if (snip.len > 0) try lines.append(arena, try std.fmt.allocPrint(arena, " {s}", .{snip}));
                        }
                    }
                    try self.appendChunkCodePreview(&lines, arena, entry.id, chunk, preview_line_cap);
                }
            },
            .name => |entry| {
                const label = if (entry.id == vm_tree.root_node_id) "<root>" else if (self.tree_index.node(entry.id)) |n| n.label else "?";
                try lines.append(arena, try std.fmt.allocPrint(arena, " {s}", .{label}));
                try lines.append(arena, try std.fmt.allocPrint(arena, " {d} chunks in subtree", .{self.tree_index.statsOf(entry.id).chunks}));
            },
            .object => |entry| {
                const ref_width = content_width -| 1;
                const summary = try self.objectSummary(
                    arena,
                    entry.id,
                    self.storePreviewBudget("objects", entry.id, ref_width),
                );
                try lines.append(arena, try std.fmt.allocPrint(arena, " {s}", .{
                    try self.canonicalStoreRef(arena, .objects, entry.id, summary, true),
                }));
                try self.appendObjectPreview(&lines, arena, entry.id, content_width);
            },
            .heap => |entry| {
                try lines.append(arena, try std.fmt.allocPrint(arena, " heap/{s}", .{@tagName(entry.view)}));
                try lines.append(arena, try std.fmt.allocPrint(arena, " {d} live · {d} reserved", .{ self.liveStoreCount(entry.view), self.storeCount(entry.view) }));
            },
            .debug_frame => |entry| if (self.debug_session) |session| if (entry.index < session.frameCount()) {
                const info = session.frame(entry.index);
                try lines.append(arena, try std.fmt.allocPrint(arena, " frame #{d}", .{entry.index}));
                try lines.append(arena, try std.fmt.allocPrint(arena, " {s}:{d}", .{ if (info.file) |f| std.fs.path.basename(f) else "<repl>", info.line }));
            },
            .store_record => |entry| {
                const summary = try self.storeRecordSummary(
                    arena,
                    entry.view,
                    entry.id,
                    self.storePreviewBudget(@tagName(entry.view), entry.id, content_width -| 1),
                );
                try lines.append(arena, try std.fmt.allocPrint(arena, " {s}", .{
                    try self.canonicalStoreRef(arena, entry.view, entry.id, summary, true),
                }));
            },
            .category => |entry| {
                try lines.append(arena, try std.fmt.allocPrint(arena, " {s} section", .{@tagName(entry.kind)}));
                if (entry.kind == .heap) {
                    // The heap census lives here (it's no longer a browsable folder).
                    const c = self.ev.heapCounts();
                    try lines.append(arena, "");
                    try lines.append(arena, try std.fmt.allocPrint(arena, " objects  {d} live", .{self.liveStoreCount(.objects)}));
                    try lines.append(arena, try std.fmt.allocPrint(arena, " values   {d} live · {d} slots", .{ self.liveStoreCount(.values), c.values }));
                    try lines.append(arena, try std.fmt.allocPrint(arena, " attrs    {d} live · {d} slots", .{ self.liveStoreCount(.attrs), c.attrs }));
                    try lines.append(arena, try std.fmt.allocPrint(arena, " attrpos  {d} live · {d} slots", .{ self.liveStoreCount(.attr_positions), c.attr_positions }));
                    try lines.append(arena, try std.fmt.allocPrint(arena, " intern   {d}", .{self.liveStoreCount(.intern)}));
                    try lines.append(arena, try std.fmt.allocPrint(arena, " builtin  {d}", .{self.liveStoreCount(.builtin)}));
                    if (self.heap_index.stats) |stats| {
                        try lines.append(arena, "");
                        try lines.append(arena, " object types");
                        for (stats.variant_counts, 0..) |count, i| {
                            try lines.append(arena, try std.fmt.allocPrint(arena, "  {s:<20} {d}", .{
                                runtime.ObjectHeap.Stats.variantName(i),
                                count,
                            }));
                        }
                    }
                }
            },
            .range, .debug_root, .debug_value => {},
        }
        return lines.items;
    }

    /// The right-hand preview when inspecting a value subject: a peek at the
    /// object/chunk that the selected reference row points to, so you can see a
    /// member's contents without leaving the current subject.
    fn detailPreviewLines(self: *Tui, arena: std.mem.Allocator, content_width: usize) ![]const []const u8 {
        var lines: std.ArrayListUnmanaged([]const u8) = .empty;
        try lines.append(arena, " PREVIEW");
        const action = self.detailPreviewAction() orelse return lines.items;
        switch (action) {
            .object => |id| {
                const ref_width = content_width -| 1;
                try lines.append(arena, try std.fmt.allocPrint(arena, " {s}", .{
                    try self.canonicalStoreRef(
                        arena,
                        .objects,
                        id,
                        try self.objectSummary(arena, id, self.storePreviewBudget("objects", id, ref_width)),
                        true,
                    ),
                }));
                try self.appendObjectPreview(&lines, arena, id, content_width);
            },
            .chunk => |id| {
                try lines.append(arena, try std.fmt.allocPrint(arena, " chunk[0x{x}]", .{id}));
                if (self.ev.getChunk(id)) |chunk| {
                    try lines.append(arena, try std.fmt.allocPrint(arena, " {d} bytes · {d} consts", .{ chunk.code.len, chunk.constants.len }));
                    if (chunk.source_map.len > 0) {
                        const snip = spanSnippet(
                            arena,
                            self.chunkSourceText(id, chunk),
                            chunk.source_map[0].span,
                            content_width -| 1,
                        ) catch "";
                        if (snip.len > 0) try lines.append(arena, try std.fmt.allocPrint(arena, " {s}", .{snip}));
                    }
                    try self.appendChunkCodePreview(&lines, arena, id, chunk, preview_line_cap);
                }
            },
            .store_record => |record| {
                const summary = try self.storeRecordSummary(
                    arena,
                    record.view,
                    record.id,
                    self.storePreviewBudget(@tagName(record.view), record.id, content_width -| 1),
                );
                try lines.append(arena, try std.fmt.allocPrint(arena, " {s}", .{
                    try self.canonicalStoreRef(arena, record.view, record.id, summary, true),
                }));
            },
            else => {},
        }
        return lines.items;
    }

    /// Add a bounded canonical disassembly to a preview. This deliberately uses
    /// the same formatter as the full code view, including builtin resolution
    /// and syntax/source annotations, but excludes cold tables.
    fn appendChunkCodePreview(
        self: *Tui,
        lines: *std.ArrayListUnmanaged([]const u8),
        arena: std.mem.Allocator,
        id: ChunkId,
        chunk: *const bytecode.Chunk,
        limit: usize,
    ) !void {
        // A preview must stay cheap even when the highlighted chunk is huge.
        // The formatter may hit the fixed writer's limit; the complete rows it
        // produced before that point are still a useful bounded preview.
        var text: std.Io.Writer = .fixed(try arena.alloc(u8, 16 * 1024));
        const symbols: disasm.Symbols = .{ .intern = self.ev.internTable(), .registry = self.ev.chunkRegistry() };
        var options = disasm_options;
        options.show_header = false;
        options.show_constants = false;
        options.show_code = true;
        options.show_bytes = false;
        options.color_depth = self.color_depth;
        options.line_width = 0;
        disasm.writeChunk(arena, &text, id, chunk, symbols, options) catch {};

        try lines.append(arena, "");
        try lines.append(arena, " CODE");
        var it = std.mem.splitScalar(u8, text.buffered(), '\n');
        var shown: usize = 0;
        while (it.next()) |line| {
            if (line.len == 0 or std.mem.startsWith(u8, base.terminal_text.stripAnsiInPlace(try arena.dupe(u8, line)), "chunk[")) continue;
            try lines.append(arena, try std.fmt.allocPrint(arena, " {s}", .{line}));
            shown += 1;
            if (shown == limit) {
                if (it.peek() != null) try lines.append(arena, " …");
                break;
            }
        }
    }

    /// Enrich heap-object previews where metadata alone is least useful. In
    /// particular, bytecode thunks show their body and its first instructions.
    fn appendObjectPreview(
        self: *Tui,
        lines: *std.ArrayListUnmanaged([]const u8),
        arena: std.mem.Allocator,
        id: runtime.types.ObjectId,
        content_width: usize,
    ) !void {
        // A standalone debugger pause does not run the asynchronous heap-index
        // jobs. Build its live-object bitmap once, synchronously while the VM is
        // paused, so stack thunks can still expose their bodies in previews.
        if (self.heap_index.objects == null and self.debug_session != null)
            self.heap_index.objects = self.ev.heapObjectSnapshot(self.allocator) catch null;
        const snapshot = if (self.heap_index.objects) |*snap| snap else return;
        const info = self.ev.inspectHeapObject(snapshot, id) catch return;
        switch (info) {
            .attrs => if (self.ev.heapAttrsOf(id)) |attrs| {
                try lines.append(arena, try std.fmt.allocPrint(arena, " attrs · {d} members", .{attrs.len}));
                for (attrs[0..@min(attrs.len, preview_line_cap)]) |entry| {
                    const name = self.ev.internTable().get(entry.name);
                    const value_width = content_width -| width_mod.strWidth(name) -| 4;
                    const detail = try self.shallowValueSummary(arena, entry.value, value_width);
                    try lines.append(arena, try std.fmt.allocPrint(arena, "  {s} = {s}", .{ name, detail }));
                }
                if (attrs.len > preview_line_cap) try lines.append(arena, try std.fmt.allocPrint(
                    arena,
                    "  … {d} more",
                    .{attrs.len - preview_line_cap},
                ));
            } else |_| {},
            .list => if (self.ev.heapListOf(id)) |items| {
                try lines.append(arena, try std.fmt.allocPrint(arena, " list · {d} items", .{items.len}));
                for (items[0..@min(items.len, preview_line_cap)], 0..) |item, i| {
                    var prefix_buf: [32]u8 = undefined;
                    const prefix = std.fmt.bufPrint(&prefix_buf, "  [{d}] ", .{i}) catch "  ";
                    const detail = try self.shallowValueSummary(
                        arena,
                        item,
                        content_width -| width_mod.strWidth(prefix),
                    );
                    try lines.append(arena, try std.fmt.allocPrint(arena, "{s}{s}", .{ prefix, detail }));
                }
                if (items.len > preview_line_cap) try lines.append(arena, try std.fmt.allocPrint(
                    arena,
                    "  … {d} more",
                    .{items.len - preview_line_cap},
                ));
            } else |_| {},
            .thunk => |thunk| {
                try lines.append(arena, try std.fmt.allocPrint(arena, " state {s} · demanded {s}", .{
                    @tagName(thunk.state),
                    if (thunk.demanded) "yes" else "no",
                }));
                switch (thunk.body) {
                    .target => |target| switch (target) {
                        .bytecode => |body| {
                            try lines.append(arena, try std.fmt.allocPrint(arena, " chunk[0x{x}] · {d} captures", .{ body.chunk, body.captures }));
                            if (self.ev.getChunk(body.chunk)) |chunk|
                                try self.appendChunkCodePreview(lines, arena, body.chunk, chunk, preview_line_cap);
                        },
                        .closure => |value| {
                            const rendered = try self.renderValueRef(arena, value, content_width -| 9, true);
                            try lines.append(arena, try std.fmt.allocPrint(arena, " closure {s}", .{rendered.text}));
                        },
                        .pass_through => |value| {
                            const rendered = try self.renderValueRef(arena, value, content_width -| 7, true);
                            try lines.append(arena, try std.fmt.allocPrint(arena, " value {s}", .{rendered.text}));
                        },
                        .attr_access => |access| try lines.append(arena, try std.fmt.allocPrint(arena, " attribute intern[0x{x}]", .{access.name})),
                        .deferred => |body| try lines.append(arena, try std.fmt.allocPrint(arena, " deferred[0x{x}] · {d} captures", .{ body.id, body.captures })),
                    },
                    .result => |value| {
                        const rendered = try self.renderValueRef(arena, value, content_width -| 8, true);
                        try lines.append(arena, try std.fmt.allocPrint(arena, " result {s}", .{rendered.text}));
                    },
                    .error_name => |name| try lines.append(arena, try std.fmt.allocPrint(arena, " error {s}", .{name})),
                }
            },
            .builtin_closure => |closure| {
                try lines.append(arena, try std.fmt.allocPrint(arena, " {s}", .{
                    try self.locatedValue(
                        arena,
                        "builtin",
                        closure.builtin,
                        .builtin,
                        disasm.builtinName(closure.builtin),
                        content_width -| 1,
                        true,
                    ),
                }));
                try lines.append(arena, try std.fmt.allocPrint(arena, " {d} arguments", .{closure.args}));
            },
            .closure => |closure| if (self.ev.getChunk(closure.chunk)) |chunk|
                try self.appendChunkCodePreview(lines, arena, closure.chunk, chunk, preview_line_cap),
            else => {},
        }
    }

    fn identityForStore(view: HeapView) disasm.Identity {
        return switch (view) {
            .overview, .objects => .object,
            .values => .value,
            .attrs => .attr,
            .attr_positions => .attr_position,
            .intern => .intern,
            .builtin => .builtin,
        };
    }

    fn canonicalStoreRef(
        self: *Tui,
        arena: std.mem.Allocator,
        view: HeapView,
        id: u32,
        preview: ?[]const u8,
        colored: bool,
    ) ![]const u8 {
        var rendered: std.Io.Writer.Allocating = .init(arena);
        try disasm.writeStoreRef(
            &rendered.writer,
            @tagName(view),
            id,
            identityForStore(view),
            preview,
            if (colored) self.color_depth else .none,
        );
        return rendered.written();
    }

    fn storeRecordSummary(
        self: *Tui,
        arena: std.mem.Allocator,
        view: HeapView,
        id: u32,
        max_cells: usize,
    ) ![]const u8 {
        const raw: []const u8 = switch (view) {
            .values => if (self.ev.heapValueAt(id)) |value|
                try self.valueSummary(arena, value.*, max_cells)
            else
                "",
            .attrs => if (self.ev.heapAttrAt(id)) |attr|
                try std.fmt.allocPrint(arena, "{s} = {s}", .{
                    self.ev.internTable().get(attr.name),
                    try self.valueSummary(arena, attr.value, max_cells),
                })
            else
                "",
            .attr_positions => if (self.ev.heapAttrPosAt(id)) |position|
                try std.fmt.allocPrint(arena, "{s} @ {s}:{d}:{d}", .{
                    self.ev.internTable().get(position.name),
                    std.fs.path.basename(self.ev.internTable().get(position.pos.file)),
                    position.pos.line,
                    position.pos.column,
                })
            else
                "",
            .intern => if (id < self.storeCount(.intern))
                try escapedQuoted(arena, "text ", self.ev.internTable().get(id), max_cells)
            else
                "",
            .builtin => disasm.builtinName(id) orelse "",
            .overview, .objects => "",
        };
        return width_mod.endEllipsis(arena, raw, max_cells);
    }

    fn storePreviewBudget(self: *Tui, store: []const u8, id: u64, max_cells: usize) usize {
        _ = self;
        var location_buf: [64]u8 = undefined;
        const location = std.fmt.bufPrint(&location_buf, "{s}[0x{x}] → ", .{ store, id }) catch return max_cells;
        return max_cells -| width_mod.strWidth(location);
    }

    /// Render a store-backed value in canonical address-first order. The
    /// preview is bounded before color escapes are introduced, so truncation
    /// remains terminal-cell-aware.
    fn locatedValue(
        self: *Tui,
        arena: std.mem.Allocator,
        store: []const u8,
        id: u64,
        identity: disasm.Identity,
        preview: ?[]const u8,
        max_cells: usize,
        colored: bool,
    ) ![]const u8 {
        const bounded = if (preview) |text|
            try width_mod.endEllipsis(arena, text, self.storePreviewBudget(store, id, max_cells))
        else
            null;
        var rendered: std.Io.Writer.Allocating = .init(arena);
        try disasm.writeStoreRef(
            &rendered.writer,
            store,
            id,
            identity,
            bounded,
            if (colored) self.color_depth else .none,
        );
        return rendered.written();
    }

    fn canonicalStoreRange(
        self: *Tui,
        arena: std.mem.Allocator,
        view: HeapView,
        start: u32,
        end: u32,
        live: u32,
        colored: bool,
    ) ![]const u8 {
        var rendered: std.Io.Writer.Allocating = .init(arena);
        try disasm.writeStoreRange(
            &rendered.writer,
            @tagName(view),
            start,
            end,
            live,
            identityForStore(view),
            if (colored) self.color_depth else .none,
        );
        return rendered.written();
    }

    fn escapedQuoted(
        arena: std.mem.Allocator,
        prefix: []const u8,
        text: []const u8,
        max_cells: usize,
    ) ![]const u8 {
        var escaped: std.Io.Writer.Allocating = .init(arena);
        for (text) |c| switch (c) {
            '\\' => try escaped.writer.writeAll("\\\\"),
            '"' => try escaped.writer.writeAll("\\\""),
            '\n' => try escaped.writer.writeAll("\\n"),
            '\r' => try escaped.writer.writeAll("\\r"),
            '\t' => try escaped.writer.writeAll("\\t"),
            else => try escaped.writer.writeByte(c),
        };
        const inner_width = max_cells -| width_mod.strWidth(prefix) -| 2;
        const short = try width_mod.endEllipsis(arena, escaped.written(), inner_width);
        return std.fmt.allocPrint(arena, "{s}\"{s}\"", .{ prefix, short });
    }

    fn floatSummary(arena: std.mem.Allocator, value: f64) ![]const u8 {
        const short = try std.fmt.allocPrint(arena, "{d:.3}", .{value});
        if (!std.math.isFinite(value)) return std.fmt.allocPrint(arena, "float {s}", .{short});
        const parsed = std.fmt.parseFloat(f64, short) catch value;
        return std.fmt.allocPrint(arena, "float {s}{s}", .{
            if (parsed == value) "" else "~",
            short,
        });
    }

    /// A bounded, non-forcing digest using the same address-first grammar as
    /// locals, stack slots, return values, and disassembly.
    fn valueSummary(self: *Tui, arena: std.mem.Allocator, value: runtime.value.Value, max_cells: usize) ![]const u8 {
        return (try self.renderValue(arena, value, max_cells, false)).text;
    }

    fn scalarValueSummary(self: *Tui, arena: std.mem.Allocator, value: runtime.value.Value, max_cells: usize) ![]const u8 {
        _ = self;
        const raw: []const u8 = switch (value.kind()) {
            .null => "null",
            .bool_false => "bool false",
            .bool_true => "bool true",
            .int => try std.fmt.allocPrint(arena, "int {d}", .{value.asInt()}),
            .float => try floatSummary(arena, value.asFloat()),
            .string,
            .path,
            .builtin,
            .list,
            .attrs,
            .closure,
            .thunk,
            .builtin_closure,
            .string_context,
            .boxed_int,
            .partial_app,
            => unreachable,
        };
        return width_mod.endEllipsis(arena, raw, max_cells);
    }

    fn objectSummary(self: *Tui, arena: std.mem.Allocator, id: runtime.types.ObjectId, max_cells: usize) ![]const u8 {
        if (self.heap_index.objects) |*snapshot| {
            if (self.ev.inspectHeapObject(snapshot, id)) |info| {
                const text: []const u8 = switch (info) {
                    .list => if (self.ev.heapListOf(id)) |items|
                        try std.fmt.allocPrint(arena, "list ({d})", .{items.len})
                    else |_|
                        "list",
                    .attrs => if (self.ev.heapAttrsOf(id)) |attrs|
                        try std.fmt.allocPrint(arena, "attrs ({d})", .{attrs.len})
                    else |_|
                        "attrs",
                    .merge_attrs => |merge| try std.fmt.allocPrint(arena, "attrs merge · depth {d}", .{merge.depth}),
                    .closure => |closure| try std.fmt.allocPrint(arena, "closure → chunk[0x{x}] · {d} upvalues", .{ closure.chunk, closure.upvalues }),
                    .builtin_closure => |closure| try std.fmt.allocPrint(arena, "builtin closure → {s} · {d} args", .{
                        try self.locatedValue(
                            arena,
                            "builtin",
                            closure.builtin,
                            .builtin,
                            disasm.builtinName(closure.builtin),
                            max_cells -| 20,
                            false,
                        ),
                        closure.args,
                    }),
                    .thunk => |thunk| try std.fmt.allocPrint(arena, "thunk · {s}{s}", .{
                        @tagName(thunk.state),
                        if (thunk.demanded) " · demanded" else "",
                    }),
                    .context_string => |string| try std.fmt.allocPrint(arena, "context string · {d} entries", .{string.context}),
                    .boxed_int => |value| try std.fmt.allocPrint(arena, "int {d}", .{value}),
                    .partial_app => |partial| try std.fmt.allocPrint(arena, "partial application · {d} args", .{partial.args}),
                };
                return width_mod.endEllipsis(arena, text, max_cells);
            } else |_| {}
        }
        return "?";
    }

    /// A useful, non-forcing description for an `objects[0xN]` value. Known
    /// list/attribute membership can be summarized safely; thunks are never
    /// forced and lazy attributes are never demanded.
    fn objectTargetSummary(
        self: *Tui,
        arena: std.mem.Allocator,
        kind: runtime.value.ValueType,
        id: runtime.types.ObjectId,
        max_cells: usize,
    ) !?[]const u8 {
        switch (kind) {
            .list => if (self.ev.heapListOf(id)) |items| {
                var out: std.Io.Writer.Allocating = .init(arena);
                try out.writer.print("list ({d})", .{items.len});
                if (items.len > 0) {
                    try out.writer.writeAll(" [");
                    for (items[0..@min(items.len, 3)], 0..) |item, i| {
                        if (i != 0) try out.writer.writeAll(", ");
                        try out.writer.writeAll(try self.shallowValueSummary(
                            arena,
                            item,
                            @max(@as(usize, 8), max_cells / 3),
                        ));
                    }
                    if (items.len > 3) try out.writer.writeAll(", …");
                    try out.writer.writeByte(']');
                }
                return try width_mod.endEllipsis(arena, out.written(), max_cells);
            } else |_| {},
            .attrs => if (self.ev.heapAttrsOf(id)) |attrs| {
                var out: std.Io.Writer.Allocating = .init(arena);
                try out.writer.print("attrs ({d})", .{attrs.len});
                if (attrs.len > 0) {
                    try out.writer.writeAll(" {");
                    for (attrs[0..@min(attrs.len, 2)], 0..) |attr, i| {
                        if (i != 0) try out.writer.writeAll(", ");
                        try out.writer.writeAll(self.ev.internTable().get(attr.name));
                        if (try self.scalarText(arena, attr.value, @max(@as(usize, 8), max_cells / 2))) |scalar|
                            try out.writer.print(" = {s}", .{scalar});
                    }
                    if (attrs.len > 2) try out.writer.writeAll(", …");
                    try out.writer.writeByte('}');
                }
                return try width_mod.endEllipsis(arena, out.written(), max_cells);
            } else |_| {},
            else => {},
        }

        const summary = try self.objectSummary(arena, id, max_cells);
        return if (std.mem.eql(u8, summary, "?")) disasm.valueKindLabel(kind) else summary;
    }

    /// The rendered scalar for an inline `Value` (null/bool/int/float/string/
    /// path), or null for heap-backed kinds. Safe on a raw store slot — inline
    /// scalars carry their data in the `Value` bits with no heap deref.
    fn scalarText(
        self: *Tui,
        arena: std.mem.Allocator,
        value: runtime.value.Value,
        max_cells: usize,
    ) !?[]const u8 {
        return switch (value.kind()) {
            .null,
            .bool_false,
            .bool_true,
            .int,
            .float,
            => try self.scalarValueSummary(arena, value, max_cells),
            .string, .path => blk: {
                const id = value.asInternId();
                const preview = try escapedQuoted(
                    arena,
                    try std.fmt.allocPrint(arena, "{s} ", .{disasm.valueKindLabel(value.kind())}),
                    self.ev.internTable().get(id),
                    self.storePreviewBudget("intern", id, max_cells),
                );
                break :blk try self.locatedValue(arena, "intern", id, .intern, preview, max_cells, false);
            },
            .builtin => blk: {
                const id = value.asBuiltinId();
                break :blk try self.locatedValue(arena, "builtin", id, .builtin, disasm.builtinName(id), max_cells, false);
            },
            else => null,
        };
    }

    /// Render a nested member without following it into another container.
    /// This preserves its identity and type while keeping list/attrs previews
    /// bounded and cycle-safe.
    fn shallowValueSummary(
        self: *Tui,
        arena: std.mem.Allocator,
        value: runtime.value.Value,
        max_cells: usize,
    ) ![]const u8 {
        if (try self.scalarText(arena, value, max_cells)) |scalar|
            return width_mod.endEllipsis(arena, scalar, max_cells);
        if (value.kind() == .closure and value.isFunction())
            return self.locatedValue(arena, "chunk", value.asFunctionChunkId(), .chunk, "function", max_cells, false);
        return self.locatedValue(
            arena,
            "objects",
            value.asObjectId(),
            .object,
            disasm.valueKindLabel(value.kind()),
            max_cells,
            false,
        );
    }

    fn drawFocusDivider(self: *Tui, frame: *tui.Frame, row: usize, col: usize, focused: bool) !void {
        _ = self;
        try frame.at(row, col);
        try frame.text(if (focused) "┃" else "│", 0, 1, if (focused) .section else .border);
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
            const selected = idx == self.navigation.detail_selection and self.navigation.focus == .subject and self.rowActionable(idx);
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
        if (location.span) |span| return self.ev.breakpointSpan(location.chunk_id, span);
        return self.ev.breakpointAt(location.chunk_id, location.offset);
    }

    fn detailRole(self: *const Tui, index: usize) tui.Role {
        if (index < self.page.actions.len) switch (self.page.actions[index]) {
            .section, .source => return .section,
            .chunk => return .chunk,
            .object, .store_record => return .object,
            .none, .instruction => {},
        };
        return .plain;
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
            .store_record => |entry| entry.depth,
            .debug_root => |entry| entry.depth,
            .debug_frame => |entry| entry.depth,
            .debug_value => |entry| entry.depth,
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

    fn treeSelectionSlot(self: *const Tui, width: usize, slots: usize) ?usize {
        for (0..slots) |slot| {
            const cell = self.treeCell(slot, width, slots) orelse continue;
            if (cell.index == self.navigation.tree_selection and cell.segment == 0)
                return slot;
        }
        return null;
    }

    fn treeDisplayHeight(self: *const Tui, index: usize, width: usize, slots: usize, pinned: bool) usize {
        if (index >= self.tree.rows.items.len or width < 8) return 1;
        const selected = index == self.navigation.tree_selection and self.navigation.focus == .tree;
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
                const suffix = std.fmt.bufPrint(&suffix_buf, "  chunk[0x{x}] · {Bi}{s}", .{ entry.id, chunk.code.len, relation }) catch "";
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
                const line = if (self.filterActive())
                    std.fmt.bufPrint(&line_buf, " VM STATE · filter '{s}' · F edit · Esc clear", .{self.tree.filter_query.items}) catch " VM STATE · filtered"
                else
                    std.fmt.bufPrint(&line_buf, " VM STATE · {d} chunks · {d} object slots", .{ root_stats.chunks, heap_counts.objects }) catch " VM STATE";
                try frame.text(line, 0, width, if (self.filterActive()) .source_focus else .section);
            },
            1 => {
                const id = self.currentChunk() orelse {
                    if (self.currentObject()) |object_id| {
                        const line = std.fmt.bufPrint(&line_buf, " ● objects[0x{x}]", .{object_id}) catch " object";
                        try frame.text(line, 0, width, .object);
                    } else if (self.currentHeap()) |view| {
                        const line = std.fmt.bufPrint(&line_buf, " ● heap/{s}", .{@tagName(view)}) catch " heap";
                        try frame.text(line, 0, width, .section);
                    } else if (self.currentStoreRecord()) |record| {
                        const line = std.fmt.bufPrint(&line_buf, " ● {s}[0x{x}]", .{
                            @tagName(record.view),
                            record.id,
                        }) catch " store record";
                        try frame.text(line, 0, width, .object);
                    } else if (self.debug_session) |session| {
                        const line = std.fmt.bufPrint(&line_buf, " ◆ paused/{s}", .{reasonName(session.reason)}) catch " paused";
                        try frame.text(line, 0, width, .current);
                    } else {
                        try frame.text(" help", 0, width, .muted);
                    }
                    return true;
                };
                var relation_buf: [96]u8 = undefined;
                const relation = self.chunkEquivalenceSuffix(&relation_buf, id);
                const line = if (self.ev.getChunk(id)) |chunk|
                    std.fmt.bufPrint(&line_buf, " ● chunk[0x{x}]  {d}b · {d}c · a{d}{s}", .{ id, chunk.code.len, chunk.constants.len, chunk.arity, relation }) catch " current chunk"
                else
                    std.fmt.bufPrint(&line_buf, " ● chunk[0x{x}]  missing", .{id}) catch " current chunk";
                try frame.text(line, 0, width, .chunk_current);
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
                        break :blk2 std.fmt.bufPrint(&line_buf, " {s} HEAP - {d} slots", .{ if (is_open) "▾" else if (projected) "›" else "▸", counts.objects }) catch " heap";
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
                        try std.fmt.allocPrint(arena, " {s}{s} {s}  chunk[0x{x}] · {Bi}{s}", .{
                            indent[0..indent_len],
                            if (self.currentChunk() == entry.id) "●" else "·",
                            label,
                            entry.id,
                            ch.code.len,
                            relation,
                        })
                    else
                        std.fmt.bufPrint(&line_buf, " {s}{s} chunk[0x{x}]  {Bi}{s}", .{
                            indent[0..indent_len],
                            if (self.currentChunk() == entry.id) "●" else "·",
                            entry.id,
                            ch.code.len,
                            relation,
                        }) catch " chunk"
                else
                    std.fmt.bufPrint(&line_buf, " {s}! chunk[0x{x}] missing", .{ indent[0..indent_len], entry.id }) catch " missing";
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
                        break :blk2 std.fmt.bufPrint(&line_buf, " {s}{s} chunks[0x{x}:0x{x}] ({d})", .{
                            indent[0..indent_len],
                            if (is_open) "▾" else "▸",
                            first,
                            last + 1,
                            entry.live,
                        }) catch " chunk range";
                    },
                    .objects => blk2: {
                        const reference = try self.canonicalStoreRange(
                            arena,
                            .objects,
                            entry.start,
                            entry.start + entry.len,
                            entry.live,
                            !(selected and self.navigation.focus == .tree),
                        );
                        break :blk2 try std.fmt.allocPrint(arena, " {s}{s} {s}", .{
                            indent[0..indent_len],
                            if (is_open) "▾" else if (self.currentObject()) |id| (if (id >= entry.start and id < entry.start + entry.len) "›" else "▸") else "▸",
                            reference,
                        });
                    },
                    .values, .attrs, .attr_positions, .intern, .builtin => blk2: {
                        const view: HeapView = switch (entry.kind) {
                            .values => .values,
                            .attrs => .attrs,
                            .attr_positions => .attr_positions,
                            .intern => .intern,
                            .builtin => .builtin,
                            else => unreachable,
                        };
                        const reference = try self.canonicalStoreRange(
                            arena,
                            view,
                            entry.start,
                            entry.start + entry.len,
                            entry.live,
                            !(selected and self.navigation.focus == .tree),
                        );
                        break :blk2 try std.fmt.allocPrint(arena, " {s}{s} {s}", .{
                            indent[0..indent_len],
                            if (is_open) "▾" else "▸",
                            reference,
                        });
                    },
                };
            },
            .heap => |entry| blk: {
                var indent: [64]u8 = undefined;
                const indent_len = @min(@as(usize, entry.depth) * 2, indent.len);
                @memset(indent[0..indent_len], ' ');
                const projected = (entry.view == .objects and self.currentObject() != null) or
                    (if (self.currentStoreRecord()) |r| r.view == entry.view else false);
                const marker = if (entry.view == .overview)
                    "·"
                else if (self.tree.heap_views[@intFromEnum(entry.view)])
                    "▾"
                else if (projected)
                    "›"
                else
                    "▸";
                const snapshot = if (entry.view == .objects)
                    (if (self.heap_index.objects) |*s| s else null)
                else
                    self.ensureStoreSnapshot(entry.view);
                if (entry.view == .objects and snapshot == null) {
                    break :blk if (self.heap_index.stats) |stats|
                        try std.fmt.allocPrint(arena, " {s}{s} objects · {d} live", .{
                            indent[0..indent_len],
                            marker,
                            liveObjectCount(stats),
                        })
                    else
                        try std.fmt.allocPrint(arena, " {s}{s} objects", .{
                            indent[0..indent_len],
                            marker,
                        });
                }
                const extent = if (snapshot) |s| s.liveExtent() else self.storeCount(entry.view);
                const live = if (snapshot) |s| s.live_count else self.storeCount(entry.view);
                const reference = try self.canonicalStoreRange(
                    arena,
                    entry.view,
                    0,
                    extent,
                    live,
                    !(selected and self.navigation.focus == .tree),
                );
                break :blk try std.fmt.allocPrint(arena, " {s}{s} {s}", .{
                    indent[0..indent_len],
                    marker,
                    reference,
                });
            },
            .object => |entry| blk: {
                var indent: [64]u8 = undefined;
                const indent_len = @min(@as(usize, entry.depth) * 2, indent.len);
                @memset(indent[0..indent_len], ' ');
                const ref_width = width -| indent_len -| 4;
                const preview = try self.objectSummary(
                    arena,
                    entry.id,
                    self.storePreviewBudget("objects", entry.id, ref_width),
                );
                const reference = try self.canonicalStoreRef(
                    arena,
                    .objects,
                    entry.id,
                    preview,
                    !(selected and self.navigation.focus == .tree),
                );
                break :blk try std.fmt.allocPrint(arena, " {s}{s} {s}", .{
                    indent[0..indent_len],
                    if (self.currentObject() == entry.id) "●" else "·",
                    reference,
                });
            },
            .store_record => |entry| blk: {
                var indent: [64]u8 = undefined;
                const indent_len = @min(@as(usize, entry.depth) * 2, indent.len);
                @memset(indent[0..indent_len], ' ');
                const current = if (self.currentStoreRecord()) |r| (r.view == entry.view and r.id == entry.id) else false;
                const ref_width = width -| indent_len -| 4;
                const detail = try self.storeRecordSummary(
                    arena,
                    entry.view,
                    entry.id,
                    self.storePreviewBudget(@tagName(entry.view), entry.id, ref_width),
                );
                const reference = try self.canonicalStoreRef(
                    arena,
                    entry.view,
                    entry.id,
                    detail,
                    !(selected and self.navigation.focus == .tree),
                );
                break :blk try std.fmt.allocPrint(arena, " {s}{s} {s}", .{
                    indent[0..indent_len],
                    if (current) "●" else "·",
                    reference,
                });
            },
            .debug_root => blk: {
                const reason = if (self.debug_session) |s| reasonName(s.reason) else "paused";
                break :blk std.fmt.bufPrint(&line_buf, " ◆ PAUSE · {s}", .{reason}) catch " ◆ PAUSE";
            },
            .debug_frame => |entry| blk: {
                const session = self.debug_session orelse break :blk " (frame)";
                if (entry.index >= session.frameCount()) break :blk " (frame gone)";
                const info = session.frame(entry.index);
                var name: std.Io.Writer.Allocating = .init(arena);
                if (session.hasFrameName(entry.index)) session.writeFrameName(&name.writer, entry.index) catch {};
                var indent: [64]u8 = undefined;
                const indent_len = @min(@as(usize, entry.depth) * 2, indent.len);
                @memset(indent[0..indent_len], ' ');
                break :blk try std.fmt.allocPrint(arena, " {s}{s} #{d} {s}:{d} {s}", .{
                    indent[0..indent_len],
                    if (self.currentDebugFrame() == entry.index) "●" else "·",
                    entry.index,
                    if (info.file) |f| std.fs.path.basename(f) else "<repl>",
                    info.line,
                    name.written(),
                });
            },
            .debug_value => blk: {
                const session = self.debug_session orelse break :blk " value";
                const v = session.value;
                const label = returnValueHeading(session.reason);
                const detail = try self.valueSummary(arena, v, width -| 24);
                break :blk try std.fmt.allocPrint(arena, " ↳ {s}: {s}", .{ label, detail });
            },
        };
        const role: tui.Role = if (selected and self.navigation.focus == .tree)
            .selection
        else if (pinned)
            .muted
        else switch (self.tree.rows.items[index]) {
            .category => .section,
            .name => .name,
            // Chunks keep their own hue whether or not they're the open one; the
            // `●` marker (not a color change) signals which is current.
            .chunk => |entry| if (self.currentChunk() == entry.id) .chunk_current else .chunk,
            .range => .range,
            .object => |entry| if (self.currentObject() == entry.id) .chunk_current else .object,
            .store_record => |entry| if (self.currentStoreRecord()) |r| (if (r.view == entry.view and r.id == entry.id) .chunk_current else .object) else .object,
            .heap => |entry| switch (self.currentKind()) {
                .heap => |view| if (view == entry.view) .section else .name,
                else => .name,
            },
            .debug_root => .section,
            // A live paused frame is genuine current execution — green stays apt.
            .debug_frame => |entry| if (self.currentDebugFrame() == entry.index) .current else .name,
            // The pause's return/break/error value stands out (gold, bold).
            .debug_value => .source_focus,
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
            const ansi_identity = switch (self.tree.rows.items[index]) {
                .object, .store_record, .heap => !(selected and self.navigation.focus == .tree),
                .range => |entry| switch (entry.kind) {
                    .objects, .values, .attrs, .attr_positions, .intern, .builtin => !(selected and self.navigation.focus == .tree),
                    else => false,
                },
                else => false,
            };
            if (ansi_identity) {
                const line_width = tui.displayWidth(line, width_mod.cpWidth);
                try frame.text(line, 0, width -| @intFromBool(line_width > width), role);
                if (line_width > width and width > 0) {
                    try frame.text("…", 0, 1, role);
                }
            } else {
                const shown = try width_mod.middleEllipsis(arena, line, width);
                try frame.text(shown, 0, width, role);
            }
        }
    }

    // -- debug pause ------------------------------------------------------------

    const DebugOutcome = enum { running, resume_keep, resume_close, abort };
    /// Whether the caller should keep the (owned) alternate screen up after this
    /// pause returns. A step keeps it (another pause is imminent); continue/eof
    /// closes it. `VmDebugger` owns the screen so it survives across steps.
    pub const DebugCloseIntent = enum { keep, close };

    /// The `DebugUi` upcall body: run a nested interactive loop over the paused
    /// VM, reusing the explorer's tree + inspector. The alternate screen and raw
    /// mode are already active (owned by `VmDebugger`, or borrowed from a live
    /// `:vm` session), so this only draws. Returns `debugger.AbortError` on abort.
    fn debugRun(self: *Tui, session: *DebugSession, history: *history_mod.History) !DebugCloseIntent {
        var out_buf: [64 * 1024]u8 = undefined;
        var out = std.Io.File.stdout().writerStreaming(self.io, &out_buf);
        const w = &out.interface;

        self.debug_session = session;
        self.return_flash = session.reason == .return_step;
        // A previous pause may have indexed the heap before the VM resumed.
        // Every new pause is a new immutable inspection boundary.
        self.clearHeapSnapshots();
        self.clearReferenceGraph();
        session.clearStep();
        self.debug_nav_mark = self.navigation.back.items.len;
        defer {
            self.return_flash = false;
            self.exitDebugView();
        }
        try self.open(.{ .debug_frame = session.frameCount() -| 1 });
        if (session.reason == .return_step) self.focusValueRow(session.value);
        // `open` focuses frame details. Keep that focus across step pauses so
        // the next/current frame is immediately usable instead of bouncing the
        // user back to the stack tree after every instruction.

        var editor = editor_mod.Editor.init(self.allocator, history, .none(), .always());
        defer editor.deinit();
        var capture = transcript_mod.Capture.init(self.allocator, 256 * 1024);
        defer capture.deinit();
        try self.rebuildTranscriptLines(capture.written());

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
            var prompt_view = try self.sessionPromptView(&editor, frame_arena.allocator());
            const size = term_mod.size();
            prompt_renderer.setWidth(size.cols);
            prompt_view.max_rows = size.rows -| 2;
            const prompt_rows = if (prompt_active) try prompt_renderer.measure(prompt_view) else 0;
            try self.drawSession(frame_arena.allocator(), w, &prompt_renderer, prompt_view, prompt_rows, &capture, prompt_active);
            try w.flush();

            const flash_drawn = self.return_flash;
            const result = term_mod.readInput(&read_buf, if (decoder.wantsMore()) 40 else if (flash_drawn) 180 else -1);
            if (flash_drawn) {
                self.return_flash = false;
                try self.refreshPage(self.currentKind());
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
                    try self.debugPromptKey(session, &editor, &capture, &prompt_active, w, &prompt_renderer, key)
                else
                    try self.debugKey(session, &editor, &prompt_active, key);
                switch (outcome) {
                    .running => {},
                    .resume_keep => return .keep,
                    .resume_close => return .close,
                    .abort => return debugger.AbortError,
                }
            }
        }
    }

    fn debugKey(self: *Tui, session: *DebugSession, editor: *editor_mod.Editor, prompt_active: *bool, key: keys_mod.Key) !DebugOutcome {
        self.status_msg = "";
        switch (key.code) {
            .escape => return if (try self.escapeLayer()) .running else .resume_close,
            .cp => |cp| {
                if (key.ctrl) {
                    if (cp == 'd') return .abort;
                    _ = try self.handleKey(key);
                    return .running;
                }
                switch (cp) {
                    's' => return self.debugStep(session, .into),
                    'n' => return self.debugStep(session, .over),
                    'f' => return self.debugStep(session, .out),
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
                        _ = try self.handleKey(key);
                        return .running;
                    },
                }
            },
            else => {
                _ = try self.handleKey(key);
                return .running;
            },
        }
    }

    fn debugStep(self: *Tui, session: *DebugSession, kind: DebugSession.StepKind) DebugOutcome {
        session.step(kind) catch |err| {
            self.status_msg = std.fmt.bufPrint(&self.status_buf, "step failed: {s}", .{@errorName(err)}) catch "step failed";
            return .running;
        };
        return .resume_keep;
    }

    fn debugPromptKey(
        self: *Tui,
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
                return self.debugExecute(session, capture, std.mem.trim(u8, input, " \t\r\n"));
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

    fn debugExecute(self: *Tui, session: *DebugSession, capture: *transcript_mod.Capture, input: []const u8) !DebugOutcome {
        if (input.len == 0) return .running;
        switch (command_mod.parse(input)) {
            .none => {},
            .proceed => return .resume_close,
            .abort => return .abort,
            .step => |kind| return self.debugStep(session, switch (kind) {
                .over => .over,
                .into => .into,
                .out => .out,
            }),
            .help => try self.debugSetCapture(capture, debug_help_text),
            .backtrace, .locals => try self.debugSetCapture(capture, "The tree shows the paused stack; select a frame to inspect its source, locals, and code."),
            .value => try self.debugRenderValue(session, capture, session.value),
            .eval => |source| {
                const scope = session.scopeAttrs() catch session.bindValueScope("it") catch null;
                const value = session.eval(source, scope) catch |err| {
                    try self.debugSetCaptureFmt(capture, "error: {s}", .{@errorName(err)});
                    return .running;
                };
                // Debugger evaluation may allocate or resolve objects without
                // leaving the pause, so discard its old read-only indexes.
                self.clearHeapSnapshots();
                self.clearReferenceGraph();
                try self.debugRenderValue(session, capture, value);
                try self.refreshPage(self.currentKind());
            },
            .breakpoint => |arg| try self.debugAddBreakpoint(session, capture, arg),
            .breakpoints => try self.debugListBreakpoints(session, capture),
            .delete => |arg| try self.debugDeleteBreakpoint(session, capture, arg),
        }
        try self.rebuildTranscriptLines(capture.written());
        return .running;
    }

    fn debugSetCapture(self: *Tui, capture: *transcript_mod.Capture, text: []const u8) !void {
        _ = self;
        try capture.writer.writeAll(text);
        if (text.len == 0 or text[text.len - 1] != '\n') try capture.writer.writeByte('\n');
    }

    fn debugSetCaptureFmt(self: *Tui, capture: *transcript_mod.Capture, comptime fmt: []const u8, args: anytype) !void {
        _ = self;
        try capture.writer.print(fmt, args);
        try capture.writer.writeByte('\n');
    }

    fn debugRenderValue(self: *Tui, session: *DebugSession, capture: *transcript_mod.Capture, value: runtime.Value) !void {
        _ = self;
        session.writeValue(&capture.writer, value) catch |err| {
            try capture.writer.print("error: {s}", .{@errorName(err)});
        };
        try capture.writer.writeByte('\n');
    }

    fn debugAddBreakpoint(self: *Tui, session: *DebugSession, capture: *transcript_mod.Capture, arg: []const u8) !void {
        const colon = std.mem.lastIndexOfScalar(u8, arg, ':') orelse return self.debugSetCapture(capture, "usage: break FILE:LINE");
        const file = std.mem.trim(u8, arg[0..colon], " \t");
        const line = std.fmt.parseInt(u32, std.mem.trim(u8, arg[colon + 1 ..], " \t"), 10) catch
            return self.debugSetCapture(capture, "usage: break FILE:LINE (LINE must be a number)");
        if (file.len == 0) return self.debugSetCapture(capture, "usage: break FILE:LINE");
        const result = session.setBreakpoint(file, line) catch |err|
            return self.debugSetCaptureFmt(capture, "error: {s}", .{@errorName(err)});
        try self.debugSetCaptureFmt(capture, "breakpoint {d} {s}at {s}:{d} — {d} site(s)", .{
            result.id,
            if (result.pending) "pending " else "",
            file,
            result.line,
            result.sites,
        });
    }

    fn debugListBreakpoints(self: *Tui, session: *DebugSession, capture: *transcript_mod.Capture) !void {
        _ = self;
        const items = session.listBreakpoints();
        if (items.len == 0) {
            try capture.writer.writeAll("(no breakpoints)\n");
            return;
        }
        for (items) |bp| {
            if (bp.span) |span| {
                try capture.writer.print("{d}  chunk[0x{x}] L{d}:{d} (source span)\n", .{
                    bp.id,
                    bp.span_chunk.?,
                    span.line,
                    span.column,
                });
            } else if (bp.site_only) {
                try capture.writer.print("{d}  (per-instruction site)\n", .{bp.id});
            } else {
                try capture.writer.print("{d}  {s}:{d}{s}\n", .{ bp.id, bp.file, bp.line, if (bp.pending) " (pending)" else "" });
            }
        }
    }

    fn debugDeleteBreakpoint(self: *Tui, session: *DebugSession, capture: *transcript_mod.Capture, arg: []const u8) !void {
        const id = std.fmt.parseInt(u32, std.mem.trim(u8, arg, " \t"), 10) catch
            return self.debugSetCapture(capture, "usage: delete N");
        if (session.deleteBreakpoint(id))
            try self.debugSetCaptureFmt(capture, "deleted breakpoint {d}", .{id})
        else
            try self.debugSetCaptureFmt(capture, "no breakpoint {d}", .{id});
    }

    /// Tear down the debug view on resume: null the session, restore the outer
    /// explorer's navigation exactly as the pause found it (essential in the
    /// borrowed case, where this loop mutated the same `Tui`).
    fn exitDebugView(self: *Tui) void {
        self.debug_session = null;
        if (self.navigation.back.items.len > self.debug_nav_mark)
            self.navigation.back.shrinkRetainingCapacity(self.debug_nav_mark);
        self.navigation.forward.clearRetainingCapacity();
        if (self.navigation.back.items.len == 0) return;
        const visit = self.navigation.back.items[self.navigation.back.items.len - 1];
        self.rebuildTreeForCurrent() catch {};
        self.refreshPage(visit.kind) catch {};
        self.navigation.scroll = visit.scroll;
        self.navigation.tree_selection = visit.tree_selection;
        self.navigation.detail_selection = visit.detail_selection;
        self.navigation.x_scroll = visit.x_scroll;
    }
};

const debug_help_text =
    \\Debug pause
    \\
    \\  s / n / f      step into / next / finish
    \\  c              continue (resume evaluation)
    \\  q / Ctrl-D     abort evaluation
    \\  p              toggle a breakpoint on the selected instruction/span
    \\  ↑/↓ j/k        select a tree row (frames, chunks, heap)
    \\  Enter          open the selected frame / follow a reference
    \\  i / :          evaluate an expression / run a command
    \\  break F:L      set a source-line breakpoint
;

fn debugPageOf(arena: std.mem.Allocator, page: *PageBuilder, title: []const u8) !Page {
    return .{
        .title = try arena.dupe(u8, title),
        .lines = page.lines.items,
        .actions = page.actions.items,
        .locations = page.locations.items,
    };
}

/// A one-line, length-capped snippet of a source span for the span list.
fn spanSnippet(arena: std.mem.Allocator, source: ?[]const u8, target: anytype, max_cells: usize) ![]const u8 {
    const text = source orelse return "";
    const start = @min(@as(usize, target.offset), text.len);
    const end = @min(start +| @as(usize, target.len), text.len);
    if (start >= end) return "";
    const raw = text[start..end];
    const out = try arena.dupe(u8, raw);
    for (out) |*b| if (b.* == '\n' or b.* == '\r' or b.* == '\t') {
        b.* = ' ';
    };
    return width_mod.endEllipsis(arena, out, max_cells);
}

fn asciiContainsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    outer: while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) continue :outer;
        }
        return true;
    }
    return false;
}

/// Two tree rows denote the same node (ignoring depth), for cursor preservation.
fn treeRowsEqual(a: TreeRow, b: TreeRow) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .category => |x| b.category.kind == x.kind,
        .name => |x| b.name.id == x.id,
        .chunk => |x| b.chunk.id == x.id,
        .range => |x| b.range.key() == x.key(),
        .heap => |x| b.heap.view == x.view,
        .object => |x| b.object.id == x.id,
        .store_record => |x| b.store_record.view == x.view and b.store_record.id == x.id,
        .debug_root => true,
        .debug_frame => |x| b.debug_frame.index == x.index,
        .debug_value => true,
    };
}

fn returnValueHeading(reason: engine.BreakReason) []const u8 {
    return switch (reason) {
        .return_step => "RETURN VALUE",
        .eval_error => "ERROR VALUE",
        else => "BREAK VALUE",
    };
}

fn reasonName(reason: engine.BreakReason) []const u8 {
    return switch (reason) {
        .entry => "entry",
        .break_builtin => "break",
        .line_breakpoint => "breakpoint",
        .step => "step",
        .return_step => "return",
        .eval_error => "error",
    };
}

fn disasmTarget(line: []const u8) RowAction {
    if (storeRefId(line, "chunk[0x")) |id| {
        return .{ .chunk = @intCast(id) };
    }
    if (storeRefId(line, "objects[0x")) |id| {
        return .{ .object = @intCast(id) };
    }
    if (storeRefId(line, "intern[0x")) |id| {
        return .{ .store_record = .{ .view = .intern, .id = @intCast(id) } };
    }
    if (storeRefId(line, "builtin[0x")) |id| {
        return .{ .store_record = .{ .view = .builtin, .id = @intCast(id) } };
    }
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
    try std.testing.expectEqual(@as(ChunkId, 0x2a), disasmTarget("chunk[0x2a] → function").chunk);
    try std.testing.expectEqual(@as(runtime.types.ObjectId, 0x31), disasmTarget("objects[0x31] → thunk").object);
    const intern = disasmTarget("intern[0x1] → string \"x\"").store_record;
    try std.testing.expectEqual(HeapView.intern, intern.view);
    try std.testing.expectEqual(@as(u32, 1), intern.id);
    const builtin = disasmTarget("builtin[0x20] → import").store_record;
    try std.testing.expectEqual(HeapView.builtin, builtin.view);
    try std.testing.expectEqual(@as(u32, 0x20), builtin.id);
}

test "source snippets honor their container width" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source = "alpha βeta gamma delta";
    const snippet = try spanSnippet(arena.allocator(), source, .{
        .offset = 0,
        .len = source.len,
    }, 9);
    try std.testing.expect(width_mod.strWidth(snippet) <= 9);
    try std.testing.expect(std.mem.endsWith(u8, snippet, "…"));
}
