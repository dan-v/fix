//! Evaluator — the top-level orchestration layer.
//!
//! Manages the shared state (chunk registry, intern table, scheduler) and runs
//! the worker threads that execute bytecode.

const std = @import("std");
const builtin = @import("builtin");
const runtime = @import("runtime");
const host = @import("host.zig");
const types = @import("runtime").types;
const bytecode = @import("bytecode.zig");
const InternTable = @import("runtime").intern.InternTable;
const ChunkRegistry = bytecode.ChunkRegistry;
const ChunkBuilder = bytecode.ChunkBuilder;
const ChunkId = types.ChunkId;
const Scheduler = @import("scheduler.zig").Scheduler;
const vm_mod = @import("vm.zig");
const VM = vm_mod.VM;
const LanguagePolicy = @import("policy.zig").LanguagePolicy;
const vm_force = @import("vm.zig").force;
const vm_builtins = @import("vm.zig").builtins;
const ObjectHeap = @import("runtime").heap.ObjectHeap;
const heap_gc = @import("runtime").heap.heap_gc;
const FileCache = host.FileCache;
const FetchCache = host.FetchCache;
const regex_mod = @import("base").regex;
const block_cache_mod = @import("base").block_cache;
const vma_mod = @import("runtime").mem_tag.vma;
const realization = @import("realization.zig");
const DerivationStore = realization.DerivationStore;
const derivation = @import("derivation.zig");
const Value = @import("runtime").value.Value;
const builtins = @import("runtime").builtins;
const parser_mod = @import("syntax").parser;
const diagnostic = @import("syntax").diagnostic;
const eval_trace = @import("observ.zig").trace;
const eval_progress = @import("observ.zig").progress;
const timeline = @import("probe.zig").timeline;
const ast_mod = @import("syntax").ast;
const deferred_mod = @import("compiler.zig").deferred_table;
const Run = @import("eval/run.zig").Run;
const path_ops = @import("runtime").paths;
const eval_print = @import("eval/print.zig");
const search_path_mod = @import("eval/search_path.zig");
const imports_mod = @import("eval/imports.zig");
const mem_report = @import("eval/mem_report.zig");
const tuning = @import("eval/tuning.zig");

const worker_mod = @import("vm.zig").worker;
const io_offload = @import("vm.zig").io_offload;
const daemon_runtime_mod = host.daemon_runtime;
const eval_gc = @import("eval/gc.zig");
const fiber_mod = @import("base").fiber;
const prof = @import("probe.zig").prof;
const compiler_mod = @import("compiler.zig");
const VmTrace = @import("vm.zig").trace_log.VmTrace;
const ThunkTrace = @import("probe.zig").thunk_trace.ThunkTrace;
const SpinMutex = @import("base").sync.SpinMutex;
const gc = @import("runtime").gc;
const thunk_mod = @import("runtime").thunk;
const worker_id_mod = @import("base").worker_id;

pub const Diagnostic = diagnostic.Diagnostic;
pub const EvalTrace = eval_trace.Trace;

/// Why the debugger was entered (re-exported from the VM layer so the CLI can
/// switch on it without reaching into `vm`).
pub const BreakReason = vm_mod.BreakReason;

/// The CLI-supplied debugger console. `run` drives one interactive pause.
pub const DebugUi = struct {
    ctx: *anyopaque,
    run: *const fn (*anyopaque, *DebugSession) anyerror!void,
};

/// One rendered backtrace frame: the running chunk and its source anchor.
/// `line`/`column` are 1-based; `file`/all fields are 0 when unavailable.
pub const DebugFrame = struct {
    chunk_id: ChunkId,
    /// Source file path, or null when the chunk carries no file.
    file: ?[]const u8,
    line: u32,
    column: u32,
    /// The best (narrowest) source span covering the frame's live ip, if any.
    span: ?bytecode.chunk.Chunk.SourceSpan,
};

/// A live handle to a paused evaluation, handed to the debugger UI. It exposes
/// only facade-level operations (backtrace, scope inspection, evaluate-in-place,
/// value rendering) so the `cli` layer never touches raw VM types. All methods
/// run on the paused demand fiber; `eval` re-enters the evaluator, which is
/// safe because forcing already nests VM frames (`runIsolatedFrame`).
pub const DebugSession = struct {
    ev: *Evaluator,
    vm: *VM,
    /// The value passed to `builtins.break` (may be an unforced thunk), or the
    /// value under evaluation at an error. Inspect via `writeValue`/`force`.
    value: Value,
    reason: BreakReason,

    /// Number of active call frames (top of stack last).
    pub fn frameCount(self: *const DebugSession) usize {
        return self.vm.frames_len;
    }

    /// Frame `i` (0 = outermost, `frameCount()-1` = innermost/current).
    pub fn frame(self: *const DebugSession, i: usize) DebugFrame {
        const f = &self.vm.frames[i];
        const symbols: bytecode.disasm.Symbols = .{ .intern = &self.ev.intern, .registry = &self.ev.registry };
        // `frameSpan` (inclusive end + body_span fallback) so a caller frame,
        // whose ip sits past the call it's suspended on, still resolves to a
        // source location instead of showing nothing.
        const span = bytecode.inspect.frameSpan(f.chunk_ptr, f.ip);
        const file_id = if (span) |s| s.file else bytecode.inspect.chunkPrimaryFile(f.chunk_ptr, f.chunk_id, symbols.registry);
        return .{
            .chunk_id = f.chunk_id,
            .file = if (file_id) |fid| self.ev.intern.get(fid) else null,
            .line = if (span) |s| s.line else 0,
            .column = if (span) |s| s.column else 0,
            .span = span,
        };
    }

    /// The current (innermost) frame, or null if the stack is empty.
    pub fn currentFrame(self: *const DebugSession) ?DebugFrame {
        if (self.vm.frames_len == 0) return null;
        return self.frame(self.vm.frames_len - 1);
    }

    /// The source text for frame `i` — the file it runs (from the FileCache),
    /// or the entry `-e` source. Null if neither is available. The frame's span
    /// (`frame(i).span`) offsets into this text. Used to show a code snippet at
    /// the pause.
    pub fn frameSourceText(self: *DebugSession, i: usize) ?[]const u8 {
        const f = &self.vm.frames[i];
        const span = bytecode.inspect.frameSpan(f.chunk_ptr, f.ip) orelse return self.ev.debug_source;
        if (span.file) |fid| {
            return self.ev.files.readFile(self.ev.intern.get(fid)) catch self.ev.debug_source;
        }
        return self.ev.debug_source;
    }

    /// Local slots of frame `i` (the values in `vm.stack[base..base+count]`).
    /// Names are not tracked per local, so callers index by slot.
    pub fn localCount(self: *const DebugSession, i: usize) usize {
        return self.vm.frames[i].local_count;
    }

    pub fn localValue(self: *const DebugSession, i: usize, slot: usize) Value {
        const f = &self.vm.frames[i];
        return self.vm.stack[f.frame_base + slot];
    }

    /// Write frame `i`'s always-on qualified name (`pkgs.hello`) to `w`, or
    /// nothing if anonymous. Available in every run — no `capture_names` flag.
    pub fn writeFrameName(self: *const DebugSession, w: *std.Io.Writer, i: usize) !void {
        try self.ev.registry.writeQualifiedName(w, self.vm.frames[i].chunk_id, &self.ev.intern);
    }

    pub fn hasFrameName(self: *const DebugSession, i: usize) bool {
        return self.ev.registry.hasQualifiedName(self.vm.frames[i].chunk_id);
    }

    /// The source name of local `slot` in frame `i`, if the compiler recorded
    /// one (requires chunk-name capture, which `--debugger` enables). Internal
    /// (`\x00`-prefixed) names are hidden.
    pub fn localName(self: *const DebugSession, i: usize, slot: usize) ?[]const u8 {
        const names = self.ev.registry.localNamesOf(self.vm.frames[i].chunk_id) orelse return null;
        if (slot >= names.len) return null;
        return displayName(self.ev.intern.get(names[slot]));
    }

    /// The source name of upvalue `idx` in frame `i`, if recorded.
    pub fn upvalueName(self: *const DebugSession, i: usize, idx: usize) ?[]const u8 {
        const names = self.ev.registry.upvalueNamesOf(self.vm.frames[i].chunk_id) orelse return null;
        if (idx >= names.len) return null;
        return displayName(self.ev.intern.get(names[idx]));
    }

    pub fn upvalueCount(self: *const DebugSession, i: usize) usize {
        return if (self.vm.frames[i].upvalues) |ups| ups.len else 0;
    }

    pub fn upvalueValue(self: *const DebugSession, i: usize, idx: usize) Value {
        return self.vm.frames[i].upvalues.?[idx];
    }

    /// Force `v` (shallow) on the paused fiber and return the result.
    pub fn force(self: *DebugSession, v: Value) !Value {
        return vm_force.forceValue(self.vm, v);
    }

    /// Render `v` for display (forces thunks as needed), same formatting as the
    /// repl. Runs on the paused fiber's VM.
    pub fn writeValue(self: *DebugSession, writer: *std.Io.Writer, v: Value) !void {
        return eval_print.writeValue(self.ev, writer, v);
    }

    /// Look up interned text (e.g. a source file id).
    pub fn internText(self: *const DebugSession, id: types.InternId) []const u8 {
        return self.ev.intern.get(id);
    }

    /// Compile and evaluate `source` against `scope` (an ambient attrset whose
    /// members resolve as free identifiers, like the repl's bindings), reusing
    /// the paused evaluator. Returns the resulting (unforced) value.
    pub fn eval(self: *DebugSession, source: []const u8, scope: ?Value) !Value {
        return self.ev.debugEvalScoped(self.vm, source, scope);
    }

    /// Set a source-line breakpoint at `file:line`. Resolves to the nearest
    /// line carrying code; returns null if nothing matches. Applies to already
    /// compiled chunks and any that compile later.
    pub fn setBreakpoint(self: *DebugSession, file: []const u8, line: u32) !?bytecode.BreakpointTable.SetResult {
        if (self.ev.breakpoints) |*bp| return bp.set(&self.ev.registry, file, line);
        return null;
    }

    /// All active breakpoint requests (for a `:breakpoints` listing).
    pub fn listBreakpoints(self: *const DebugSession) []const bytecode.BreakpointTable.Request {
        if (self.ev.breakpoints) |*bp| return bp.list();
        return &.{};
    }

    /// Remove a breakpoint by id; true if it existed.
    pub fn deleteBreakpoint(self: *DebugSession, id: u32) bool {
        if (self.ev.breakpoints) |*bp| return bp.remove(&self.ev.registry, id);
        return false;
    }

    pub const StepKind = enum {
        /// Stop at the next line in this frame, or when it returns.
        over,
        /// Like `over`, but also stop on entry to a function it calls.
        into,
        /// Run until the current frame returns.
        out,
    };

    /// Arm a single step. It takes effect once the console resumes; the next
    /// pause is the step's landing point. See `clearStep`.
    pub fn step(self: *DebugSession, kind: StepKind) !void {
        if (self.ev.breakpoints == null) return;
        const depth = self.vm.frames_len;
        if (depth == 0) return;
        const cur = &self.vm.frames[depth - 1];

        var sites: std.ArrayListUnmanaged(bytecode.BreakpointTable.Site) = .empty;
        defer sites.deinit(self.ev.allocator);

        const max_depth: u32 = switch (kind) {
            .out => if (depth >= 1) depth - 1 else 0,
            .over => depth,
            .into => std.math.maxInt(u32),
        };

        // Next-line sites in the current chunk (not for a pure step-out).
        if (kind != .out) {
            const cur_line: u32 = if (bytecode.inspect.frameSpan(cur.chunk_ptr, cur.ip)) |s| s.line else 0;
            for (cur.chunk_ptr.source_map) |entry| {
                if (entry.span.line == cur_line) continue;
                try sites.append(self.ev.allocator, .{ .chunk_id = cur.chunk_id, .offset = entry.start });
            }
        }
        // The frame's return point (the caller's resume ip): catches "step past
        // the last line" and realizes step-out.
        if (depth >= 2) {
            const caller = &self.vm.frames[depth - 2];
            try sites.append(self.ev.allocator, .{ .chunk_id = caller.chunk_id, .offset = @intCast(caller.ip) });
        }
        // Step-into also arms the entry of every chunk this one may call/force,
        // so entering one stops at its first line. Over-arms (all potential
        // callees) — cleaned up on the next pause.
        if (kind == .into) {
            var refs: std.ArrayListUnmanaged(ChunkId) = .empty;
            defer refs.deinit(self.ev.allocator);
            bytecode.inspect.collectRefs(self.ev.allocator, cur.chunk_ptr, &refs) catch {};
            for (refs.items) |rid| {
                const rc = self.ev.registry.get(rid) orelse continue;
                if (firstMappedOffset(rc)) |off| {
                    try sites.append(self.ev.allocator, .{ .chunk_id = rid, .offset = off });
                }
            }
        }

        if (self.ev.breakpoints) |*bp| try bp.armStep(&self.ev.registry, sites.items, max_depth);
    }

    /// Disarm any in-progress step (called at each pause before prompting).
    pub fn clearStep(self: *DebugSession) void {
        if (self.ev.breakpoints) |*bp| bp.clearStep(&self.ev.registry);
    }

    /// Build a one-entry scope attrset binding `name` to `self.value` — handy
    /// for the console to expose the break value as an identifier.
    pub fn bindValueScope(self: *DebugSession, name: []const u8) !Value {
        const entries = [_]runtime.heap.AttrEntry{.{
            .name = try self.ev.intern.intern(name),
            .value = self.value,
        }};
        return Value.attrs(try self.ev.heap.addAttrs(&entries));
    }

    /// The lexical scope at the pause: an ambient attrset of the current frame's
    /// named locals and upvalues (locals shadow upvalues), plus `it` = the break
    /// value. Console expressions compile against this, so `let`/`param`
    /// bindings visible at the breakpoint resolve as free identifiers. Requires
    /// recorded names (`--debugger` turns capture on); with no frame or no names
    /// it degrades to just `it`.
    pub fn scopeAttrs(self: *DebugSession) !Value {
        if (self.vm.frames_len == 0) return self.bindValueScope("it");

        var map: std.AutoArrayHashMapUnmanaged(types.InternId, Value) = .empty;
        defer map.deinit(self.ev.allocator);

        // Walk the frame stack outermost→innermost so nearer frames shadow
        // farther ones. A break often lands in a small argument thunk whose own
        // frame has no locals — the enclosing frame carries the `let`/param
        // bindings the user means, so all frames contribute.
        var fi: usize = 0;
        // Pass 1: `with`-scope attrsets (lowest precedence — lexical bindings
        // shadow `with`). Merged first so pass 2 overrides them.
        while (fi < self.vm.frames_len) : (fi += 1) {
            self.collectWithScopes(&map, fi) catch {};
        }
        // Pass 2: named locals + upvalues (override `with`).
        fi = 0;
        while (fi < self.vm.frames_len) : (fi += 1) {
            try self.collectFrameBindings(&map, fi);
        }
        // `it` = the break value, overriding any same-named binding.
        try map.put(self.ev.allocator, try self.ev.intern.intern("it"), self.value);

        var entries: std.ArrayListUnmanaged(runtime.heap.AttrEntry) = .empty;
        defer entries.deinit(self.ev.allocator);
        var mit = map.iterator();
        while (mit.next()) |e| try entries.append(self.ev.allocator, .{ .name = e.key_ptr.*, .value = e.value_ptr.* });
        return Value.attrs(try self.ev.heap.addAttrs(entries.items));
    }

    /// Merge frame `i`'s in-effect `with` attrsets into `map` (each attr's
    /// name→value), lowest precedence. A `with` subject is a local slot with an
    /// empty name (declared by `with`) or an upvalue named `"\x00with"` (a
    /// `with` captured from an enclosing chunk). Best-effort: a subject that
    /// errors on force or isn't an attrset is skipped.
    fn collectWithScopes(self: *DebugSession, map: *std.AutoArrayHashMapUnmanaged(types.InternId, Value), i: usize) !void {
        const f = &self.vm.frames[i];
        // Captured `with`s from enclosing chunks (outer) first, then this
        // chunk's own `with`s (inner) so inner shadows outer.
        if (self.ev.registry.upvalueNamesOf(f.chunk_id)) |names| {
            if (f.upvalues) |ups| {
                for (names, 0..) |nid, idx| {
                    if (idx >= ups.len) break;
                    if (std.mem.eql(u8, self.ev.intern.get(nid), compiler_mod.with_capture_name)) {
                        try self.mergeWithAttrs(map, ups[idx]);
                    }
                }
            }
        }
        if (self.ev.registry.localNamesOf(f.chunk_id)) |names| {
            for (names, 0..) |nid, slot| {
                if (slot >= f.local_count) break;
                if (self.ev.intern.get(nid).len == 0) {
                    try self.mergeWithAttrs(map, self.vm.stack[f.frame_base + slot]);
                }
            }
        }
    }

    fn mergeWithAttrs(self: *DebugSession, map: *std.AutoArrayHashMapUnmanaged(types.InternId, Value), subject: Value) !void {
        const forced = vm_force.forceValue(self.vm, subject) catch return;
        if (!forced.isAttrs()) return;
        const entries = self.ev.heap.getAttrs(forced.asObjectId()) catch return;
        for (entries) |e| try map.put(self.ev.allocator, e.name, e.value);
    }

    /// Add frame `i`'s named upvalues then locals (locals shadow upvalues) into
    /// `map`. Later frames overwrite earlier — call outermost→innermost.
    fn collectFrameBindings(self: *DebugSession, map: *std.AutoArrayHashMapUnmanaged(types.InternId, Value), i: usize) !void {
        const f = &self.vm.frames[i];
        if (self.ev.registry.upvalueNamesOf(f.chunk_id)) |names| {
            if (f.upvalues) |ups| {
                for (names, 0..) |nid, idx| {
                    if (idx >= ups.len) break;
                    if (displayName(self.ev.intern.get(nid)) != null) try map.put(self.ev.allocator, nid, ups[idx]);
                }
            }
        }
        if (self.ev.registry.localNamesOf(f.chunk_id)) |names| {
            for (names, 0..) |nid, slot| {
                if (slot >= f.local_count) break;
                if (displayName(self.ev.intern.get(nid)) != null) {
                    try map.put(self.ev.allocator, nid, self.vm.stack[f.frame_base + slot]);
                }
            }
        }
    }
};

/// Hide compiler-internal binding names (`\x00`-prefixed sentinels like the
/// `with`-capture marker) from debugger scope/locals views.
fn displayName(text: []const u8) ?[]const u8 {
    if (text.len == 0 or text[0] == 0) return null;
    return text;
}

/// The earliest source-mapped code offset in a chunk — a callee's "first line"
/// entry point for step-into. Null if the chunk carries no source map.
fn firstMappedOffset(chunk: *const bytecode.chunk.Chunk) ?u32 {
    var best: ?u32 = null;
    for (chunk.source_map) |entry| {
        if (best == null or entry.start < best.?) best = entry.start;
    }
    return best;
}

/// Store/daemon ownership that remains valid after the language runtime has
/// been released. Keeping this state in one object makes the terminal build
/// phase independent of the evaluator heap, scheduler, bytecode, and intern
/// table by construction.
pub const StoreState = struct {
    allocator: std.mem.Allocator,
    derivations: DerivationStore,
    daemon_runtime: *daemon_runtime_mod.DaemonRuntime,

    fn init(allocator: std.mem.Allocator) !StoreState {
        const runtime_ptr = try allocator.create(daemon_runtime_mod.DaemonRuntime);
        errdefer allocator.destroy(runtime_ptr);
        runtime_ptr.* = daemon_runtime_mod.DaemonRuntime.init();
        errdefer runtime_ptr.deinit();

        var derivations = DerivationStore.init(allocator);
        derivations.setOffload(runtime_ptr, io_offload.runOnPool, io_offload.fiberPark);
        return .{ .allocator = allocator, .derivations = derivations, .daemon_runtime = runtime_ptr };
    }

    fn deinit(self: *StoreState) void {
        self.derivations.clearOffload();
        self.daemon_runtime.deinit();
        self.allocator.destroy(self.daemon_runtime);
        self.derivations.deinit();
    }

    pub fn buildPaths(self: *StoreState, paths: []const []const u8, sink: ?host.store.BuildSink, mode: host.store.BuildMode) !void {
        return self.derivations.buildPaths(paths, sink, mode);
    }

    pub fn lastError(self: *StoreState) ?[]const u8 {
        return self.derivations.lastStoreError();
    }

    pub fn addIndirectRoot(self: *StoreState, link_path: []const u8) !void {
        return self.derivations.addIndirectRoot(link_path);
    }
};

/// Handle for the terminal build phase. Creating it starts language teardown;
/// thereafter build callers need only this store-side object. `deinit` joins
/// teardown before the owning Evaluator itself can be destroyed.
pub const BuildSession = struct {
    store: *StoreState,
    release_thread: ?std.Thread,

    pub fn deinit(self: *BuildSession) void {
        if (self.release_thread) |thread| thread.join();
        self.release_thread = null;
    }

    pub fn buildPaths(self: *BuildSession, paths: []const []const u8, sink: ?host.store.BuildSink, mode: host.store.BuildMode) !void {
        return self.store.buildPaths(paths, sink, mode);
    }

    pub fn lastStoreError(self: *BuildSession) ?[]const u8 {
        return self.store.lastError();
    }
};

pub const Evaluator = struct {
    allocator: std.mem.Allocator,
    intern: InternTable,
    registry: ChunkRegistry,
    scheduler: Scheduler,
    heap: ObjectHeap,
    files: FileCache,
    fetchers: FetchCache,
    /// Store and daemon state that deliberately outlives language teardown.
    store: StoreState,
    /// Compiled-regex cache shared by every VM (`builtins.match`/`split`).
    regexes: regex_mod.PatternCache,
    imports: imports_mod.Registry,
    search_paths: search_path_mod.Paths,
    /// Shared pool of VM stack/frames buffers (see vm.zig BufferPool):
    /// nested import VMs churn ~2.6K times per NixOS eval; reuse bounds
    /// their RSS at the concurrent-VM high-water instead of leaking a
    /// dirty half-MB into the worker arena per import.
    vm_buffers: vm_mod.BufferPool,
    builtins_value: ?Value,
    /// Whether the final render observes lazy shells (only lazy-XML).
    /// Propagated to every VM via `initVm`; gates `thunk_shell`.
    /// Default false — the CLI sets it true only for `--xml`.
    lazy_shells_visible: bool = false,
    /// Feature gates and deprecated compatibility behavior shared unchanged by
    /// parsing, every nested compiler, and every VM.
    policy: LanguagePolicy = .{},
    /// Interactive debugger UI, installed by the CLI (`--debugger`). Null (the
    /// default) means no debugger: `builtins.break` is a plain identity and the
    /// break sink is never installed on VMs. See `DebugSession`.
    debug_ui: ?DebugUi = null,
    /// Re-entrancy guard: true while the console is running. A `break`/throw in
    /// a console expression must not open a nested debugger — the console's own
    /// error handling deals with it.
    debug_in_session: bool = false,
    /// Source-line breakpoints (patched bytecode). Created by `setDebugUi`;
    /// null with no debugger. Its address is stable (the Evaluator is used by
    /// pointer), so the registry sink and each VM point at it directly.
    breakpoints: ?bytecode.BreakpointTable = null,
    /// Colorize `writeValue` output (strings/numbers/keywords/attr names). Set
    /// by the CLI from its terminal-color decision; default off (plain text for
    /// pipes, tests, JSON/XML paths). See `eval/print.zig`.
    value_color: bool = false,
    /// The entry source text, for the debugger to show a snippet at a pause in
    /// a `-e` expression (files come from the FileCache). Set by the CLI.
    debug_source: ?[]const u8 = null,
    base_path: ?[:0]u8,
    env_map: ?*const std.process.Environ.Map,
    progress: ?eval_progress.Sink,
    /// Progress sampler state (active only while `progress != null`). A thread
    /// pushes a counter snapshot to the sink every ~100ms — decoupled from
    /// fiber quanta so `--workers=1` (which can run the whole eval in one
    /// non-yielding quantum) still updates. `progress_wait` is the shared
    /// demand-block subject the sampler surfaces. All three are inert (unset)
    /// in non-interactive runs, so they add nothing to the hot path.
    progress_wait: eval_progress.ProgressWait = .{},
    progress_thread: ?std.Thread = null,
    progress_stop: std.atomic.Value(bool) = .init(false),
    vm_trace: ?*VmTrace,
    thunk_trace: if (vm_mod.thunks_log_enabled) ?*ThunkTrace else void,
    worker_count: u8,
    /// Persistent worker for worker_id 0 (the main / calling thread).
    /// Lazily created on first `runWithVm`, kept alive for the
    /// evaluator's lifetime, and deinit'd *after* the scheduler is
    /// torn down — that ordering guarantees no helper is still running
    /// a stolen main-fiber when its stack gets freed. See [F1.4].
    main_worker: ?*worker_mod.Worker,
    /// Per-evaluation state (diagnostics + trace + string arena). Cleared
    /// at the start of each `evaluate()`; helpers writing diagnostics from
    /// import error paths serialize on `run.mu`.
    run: Run,
    /// Lazy per-attr compilation: deferred attrset value bodies, compiled
    /// on first force. See `compiler/deferred_table.zig`.
    deferred_table: deferred_mod.Table,
    /// AST arenas kept alive because a deferred body retains nodes into
    /// them (force-time compile re-walks the node). Files that defer
    /// nothing free their arena immediately (the common case). Appended
    /// concurrently by helper-thread import compiles, hence the mutex.
    retained_arenas: std.ArrayListUnmanaged(ast_mod.AstArena),
    retained_arenas_mu: SpinMutex,
    /// Reusable live-set marker driven at collection safepoints.
    gc_tracer: gc.Tracer,
    /// Fresh VMs for in-flight imports/scoped-imports. These
    /// run on transient stack-local VMs NOT in a worker's `fibers` list, so
    /// the collector must scan them explicitly or their live values are
    /// missed. Guarded by `gc_import_vms_mu` — imports run concurrently at
    /// --workers>1.
    gc_import_vms: std.ArrayListUnmanaged(*VM),
    gc_import_vms_mu: SpinMutex,
    /// Every live `Worker` by id (0 = main, 1.. = helpers).
    /// The collector walks each worker's fibers for roots. A worker
    /// registers itself before it can allocate user objects and unregisters
    /// after it's quiesced, and during a stop-the-world all live workers are
    /// parked — so the collector reads a stable set.
    gc_workers: []std.atomic.Value(?*worker_mod.Worker),
    /// Chunk-constant root scan is INCREMENTAL across minors. A
    /// chunk constant's referent is promoted to old at the first minor that
    /// scans it and stays old (a later young reference it gains is caught by
    /// the remembered-set barrier, not the constant). So each minor scans only
    /// chunks `[gc_chunks_scanned, registry.count())`; re-scanning all of them
    /// every minor was ~77% of the serial root-scan. A future MAJOR resets this
    /// to 0 (a full mark re-scans every constant).
    gc_chunks_scanned: ChunkId = 0,
    /// `--max-memory` override for the collector's memory
    /// budget, in bytes (0 = never collect). `null` = resolve the default
    /// (otherwise half of MemAvailable) — see `eval/gc.zig:memoryBudget`.
    /// Set by the CLI before evaluation.
    max_memory_bytes: ?u64 = null,
    /// Optional teardown memory report (`"dump"` also lists registered VMAs).
    mem_report_mode: ?[]const u8 = null,
    /// Print the collector summary during teardown.
    gc_report_on: bool = false,
    /// Caller-held root values (the repl's scope bindings and
    /// last results live outside any VM between evaluations). Marked by
    /// `markRoots`; replaced wholesale via `gcSetExternalRoots`.
    gc_extra_roots: std.ArrayListUnmanaged(Value) = .empty,
    /// Speculative import prefetch state (`FIX_IMPORT_PREFETCH`).
    prefetch: Prefetch = .{},
    /// Whether `releaseEvalState` already ran (the build-phase memory
    /// release). Makes the release idempotent so `deinit` can share it.
    eval_released: bool = false,

    /// Speculative import prefetch (`FIX_IMPORT_PREFETCH`): `.nix` path
    /// constants discovered by `ChunkRegistry.register` are submitted as
    /// `import_prefetch` tasks ahead of demand.
    pub const Prefetch = struct {
        /// Dedup so each path is prefetched at most once per eval. Guarded
        /// by `mu` (compiles run on every worker).
        seen: std.AutoHashMapUnmanaged(types.InternId, void) = .empty,
        mu: SpinMutex = .{},
        /// Remaining submission budget — bounds the junk volume.
        budget: u32 = 0,
    };

    pub fn init(allocator: std.mem.Allocator, requested_worker_count: u8) !Evaluator {
        // Always run at least one worker — the main evaluator thread itself
        // owns worker id 0 even when no scheduler helpers are requested.
        const worker_count: u8 = @max(requested_worker_count, 1);

        var scheduler = try Scheduler.init(allocator, worker_count);
        errdefer scheduler.deinit();

        var intern = try InternTable.init(allocator);
        errdefer intern.deinit();

        var registry = try ChunkRegistry.init(allocator);
        errdefer registry.deinit();

        // Single-worker mode: the evaluator owns these tables and no helper
        // thread will ever exist, so their internal locking (intern shard
        // mutexes, chunk-dedup shard mutexes, the registration CAS) is pure
        // tax — mark them solo before anything runs. See InternTable.solo /
        // ChunkRegistry.solo for the contract.
        if (worker_count == 1) {
            intern.solo = true;
            registry.solo = true;
        }

        const gc_workers = try allocator.alloc(std.atomic.Value(?*worker_mod.Worker), worker_count);
        for (gc_workers) |*w| w.* = .init(null);
        errdefer allocator.free(gc_workers);

        var store = try StoreState.init(allocator);
        errdefer store.deinit();

        const ev: Evaluator = .{
            .allocator = allocator,
            .intern = intern,
            .registry = registry,
            .scheduler = scheduler,
            .heap = try ObjectHeap.init(allocator, worker_count),
            .files = FileCache.init(allocator),
            .fetchers = FetchCache.init(allocator),
            .store = store,
            .regexes = regex_mod.PatternCache.init(allocator),
            .imports = .{},
            .search_paths = .{},
            .vm_buffers = vm_mod.BufferPool.init(allocator),
            .builtins_value = null,
            .base_path = null,
            .env_map = null,
            .progress = null,
            .vm_trace = null,
            .thunk_trace = if (vm_mod.thunks_log_enabled) null else {},
            .worker_count = worker_count,
            .main_worker = null,
            .run = Run.init(allocator),
            .deferred_table = deferred_mod.Table.init(allocator),
            .retained_arenas = .empty,
            .retained_arenas_mu = .{},
            .gc_tracer = gc.Tracer.init(allocator),
            .gc_import_vms = .empty,
            .gc_import_vms_mu = .{},
            .gc_workers = gc_workers,
        };
        return ev;
    }

    pub fn deinit(self: *Evaluator) void {
        if (self.breakpoints) |*bp| bp.deinit();
        self.releaseEvalState();
        if (self.base_path) |path| self.allocator.free(path);
        // Language workers are joined by releaseEvalState, so no fiber remains
        // parked on the store's fast IO lane when it is shut down here.
        self.store.deinit();
    }

    /// Free the language-evaluation half of the evaluator — workers and
    /// their fiber stacks, the object heap (flat store + segment stores),
    /// file/fetch caches, retained AST, bytecode registry, and the intern
    /// table — while keeping the store half (daemon connection + IO thread,
    /// progress session) alive. The build-phase memory release: once `fix
    /// build`/`run`/`shell` has copied the drv/out paths out of the intern
    /// table, the ~2 GB evaluator heap has no further reader, but the
    /// daemon build can run for minutes. Also flushes the process block
    /// cache, whose free stacks would otherwise retain the dead segment
    /// blocks for the build's duration.
    ///
    /// Idempotent; `deinit` runs it too. After this only store-side entry
    /// points are valid (`StoreState`/`BuildSession` and the progress-session
    /// calls) — no evaluation, value
    /// access, or diagnostics rendering.
    pub fn releaseEvalState(self: *Evaluator) void {
        if (self.eval_released) return;
        self.eval_released = true;
        // The sampler reads the heap + scheduler; callers stop it before the
        // build phase already, but be structural about it.
        self.stopProgressSampler();
        mem_report.report(&self.heap, &self.intern, &self.registry, self.retained_arenas.items, self.mem_report_mode);
        // No compilation may notify this Evaluator once registry teardown
        // begins. The hook is instance-owned, so other evaluators are untouched.
        self.registry.path_const_sink = null;
        self.prefetch.seen.deinit(self.allocator);
        gc.recordFinalTotal(self.heap.totalReservedBytes());
        if (self.gc_report_on) gc.report();
        // Shut helpers down (which joins on `defer vm.deinit()` inside
        // helperLoop) before tearing down state their VMs borrow.
        self.scheduler.deinit();
        // Now that helpers are guaranteed quiescent, tear down the main
        // worker. Doing this before scheduler shutdown could race with
        // a helper still resuming a stolen main fiber.
        if (self.main_worker) |w| w.deinit();
        self.main_worker = null;
        // Every VM (helper fibers, main worker, imports) is dead now —
        // all pooled stack/frames buffers are back on the free list.
        self.vm_buffers.deinit();
        // GC bookkeeping is freed only AFTER the workers above are joined:
        // a helper can still be finishing a speculative import when the
        // main thread enters deinit, and its `evaluateSource` appends the
        // nested VM into `gc_import_vms` (and its registered chunks come
        // from the same allocator pools). Freeing the list before the join
        // leaves a dangling `items.ptr`; the late append then writes a
        // fiber-stack `*VM` into whatever recycled the freed buffer — the
        // observed victim was a freshly registered Chunk whose stomped
        // `code.ptr` detonated at `registry.deinit` (teardown SIGSEGV).
        self.gc_tracer.deinit();
        self.gc_import_vms.deinit(self.allocator);
        self.gc_extra_roots.deinit(self.allocator);
        self.allocator.free(self.gc_workers);
        self.run.deinit();
        self.imports.deinit(self.allocator);
        self.search_paths.deinit(self.allocator);
        self.fetchers.deinit();
        self.regexes.deinit();
        self.store.derivations.releaseRecipePayloads();
        self.files.deinit();
        self.heap.deinit();
        // Free deferred-compile state after the heap (whose thunks
        // referenced entries) and workers (no force-compile can be in
        // flight) are gone. The retained arenas own the AST nodes the
        // entries point at; the registered chunks are self-contained
        // bytecode and don't reference them, so order vs registry is free.
        self.deferred_table.deinit();
        for (self.retained_arenas.items) |*arena| arena.deinit();
        self.retained_arenas.deinit(self.allocator);
        self.registry.deinit();
        self.intern.deinit();
        // Dangling Value into the freed heap; never read again, but don't
        // keep it findable.
        self.builtins_value = null;
        // The teardown above just flooded the block cache's free stacks
        // with the dead segment blocks — return them (and everything else
        // parked) to the OS instead of retaining ~200 MB for the build.
        block_cache_mod.trimGlobal();
    }

    pub fn getDiagnostics(self: *const Evaluator) []const Diagnostic {
        return self.run.diagnosticsView();
    }

    pub fn getTrace(self: *const Evaluator) *const EvalTrace {
        return self.run.traceView();
    }

    pub fn setDerivationDebug(self: *Evaluator, enabled: bool) void {
        self.store.derivations.setDebugEnabled(enabled);
    }

    /// Cap concurrent fetches (`http-connections`; 0 = unlimited).
    pub fn setFetchConnections(self: *Evaluator, n: u32) void {
        self.fetchers.setMaxConnections(n);
    }

    /// `download-attempts`: total tries per download before failing.
    pub fn setDownloadAttempts(self: *Evaluator, n: u32) void {
        self.fetchers.setDownloadAttempts(n);
    }

    /// Set the fetcher's `access-tokens` (a raw `nix.conf` value), used to
    /// authenticate downloads to matching hosts. See `setup.configure`.
    pub fn setAccessTokens(self: *Evaluator, raw: []const u8) !void {
        try self.fetchers.setAccessTokens(raw);
    }

    /// Set the fetcher's `netrc` credentials (raw file content) for HTTP
    /// basic-auth on plain downloads. See `setup.configure`.
    pub fn setNetrc(self: *Evaluator, content: []const u8) !void {
        try self.fetchers.setNetrc(content);
    }

    pub fn derivationDebugRecords(self: *const Evaluator) []const derivation.DebugRecord {
        return self.store.derivations.debugRecords();
    }

    pub fn setBasePathFromCurrentPath(self: *Evaluator, io: std.Io) !void {
        self.files.setIo(io);
        self.fetchers.setIo(io);
        self.store.derivations.setIo(io);
        if (self.base_path) |path| self.allocator.free(path);
        self.base_path = try std.process.currentPathAlloc(io, self.allocator);
    }

    pub fn setFileIo(self: *Evaluator, io: std.Io) void {
        self.files.setIo(io);
        self.fetchers.setIo(io);
        self.store.derivations.setIo(io);
    }

    /// Point the base path (used to resolve relative path literals like `./x`)
    /// at the directory containing `file_path`, resolved against the current
    /// base path. This makes a file's relative paths resolve relative to the
    /// file, as Nix does — not the process cwd.
    pub fn setBasePathToFileDir(self: *Evaluator, file_path: []const u8) !void {
        const base = self.base_path orelse ".";
        const abs = try std.fs.path.resolve(self.allocator, &.{ base, file_path });
        defer self.allocator.free(abs);
        const dir = std.fs.path.dirname(abs) orelse abs;
        const owned = try self.allocator.dupeZ(u8, dir);
        if (self.base_path) |old| self.allocator.free(old);
        self.base_path = owned;
    }

    pub fn setEnvironment(self: *Evaluator, env_map: *const std.process.Environ.Map) void {
        self.env_map = env_map;
        self.fetchers.setEnvironment(env_map);
        // Point the fetch download-cache at `$XDG_CACHE_HOME/fix` (default
        // `~/.cache/fix`), mirroring Nix's `~/.cache/nix`. Best-effort; without
        // HOME/XDG the FetchCache keeps its `./.zig-cache/fix` fallback.
        self.setFetchCacheRoot() catch {};
    }

    pub fn environment(self: *const Evaluator) ?*const std.process.Environ.Map {
        return self.env_map;
    }

    fn setFetchCacheRoot(self: *Evaluator) !void {
        const env = self.env_map orelse return;
        const base: []const u8, const sub: []const []const u8 = blk: {
            if (env.get("XDG_CACHE_HOME")) |xdg| {
                if (xdg.len != 0) break :blk .{ xdg, &.{"fix"} };
            }
            if (env.get("HOME")) |home| {
                if (home.len != 0) break :blk .{ home, &.{ ".cache", "fix" } };
            }
            return;
        };
        var parts: std.ArrayListUnmanaged([]const u8) = .empty;
        defer parts.deinit(self.allocator);
        try parts.append(self.allocator, base);
        try parts.appendSlice(self.allocator, sub);
        const root = try std.fs.path.join(self.allocator, parts.items);
        defer self.allocator.free(root);
        try self.fetchers.setCacheRoot(root);
    }

    pub fn setVmTrace(self: *Evaluator, vm_trace: ?*VmTrace) void {
        self.vm_trace = vm_trace;
    }

    pub fn setThunkTrace(self: *Evaluator, thunk_trace: ?*ThunkTrace) void {
        // No-op when the trace is compiled out; callers don't need to
        // comptime-gate. `--thunks-log` users get a heads-up at the CLI
        // layer.
        if (comptime !vm_mod.thunks_log_enabled) return;
        self.thunk_trace = thunk_trace;
    }

    pub fn setProgressSink(self: *Evaluator, progress: ?eval_progress.Sink) void {
        self.progress = progress;
        // The derivation store does its real store work (`.drv` writes, source
        // serializes) off the demand fiber, so it reports via the thread-safe span
        // sink. It must not import observ (same module layer), so hand it opaque
        // hooks bound to this evaluator; they map its groups onto the live sink's
        // and read the spans half. A null ctx clears them.
        self.store.derivations.setSpanHooks(
            if (progress != null) self else null,
            drvSpanBegin,
            drvSpanEnd,
        );
        // Nothing to sync on the worker: the demand-only handles are passed
        // per top-level entry (`runWithVm` → `runTopLevel`), so a sink
        // (re)set between runs — e.g. across REPL inputs — takes effect on
        // the next entry automatically.
    }

    /// Adapters bridging the derivation store's opaque span hooks to this
    /// evaluator's live `SpanSink` (the store can't name observ types), mapping the
    /// store's local `SpanGroup` onto the observ group. `ctx` is the `*Evaluator`;
    /// both no-op if the sink was cleared mid-run.
    fn drvSpanBegin(ctx: *anyopaque, group: realization.SpanGroup, label: []const u8) usize {
        const self: *Evaluator = @ptrCast(@alignCast(ctx));
        const spans = (self.progress orelse return 0).spans;
        const observ_group: eval_progress.SpanGroup = switch (group) {
            .store => .store,
            .source => .source,
        };
        return spans.beginSpan(observ_group, label).token;
    }

    fn drvSpanEnd(ctx: *anyopaque, token: usize) void {
        const self: *Evaluator = @ptrCast(@alignCast(ctx));
        const spans = (self.progress orelse return).spans;
        spans.endSpan(.{ .token = token });
    }

    pub fn setNixPath(self: *Evaluator, nix_path: []const u8) !void {
        try self.search_paths.set(self.allocator, nix_path, self, resolveHostPath);
    }

    pub fn readSourceFile(self: *Evaluator, path: []const u8) ![]const u8 {
        const resolved = try self.resolveHostPath(path);
        defer if (resolved.owned) self.allocator.free(resolved.text);
        return self.files.readFile(resolved.text);
    }

    fn clearDiagnostics(self: *Evaluator) void {
        self.run.clear();
    }

    fn copyDiagnostics(self: *Evaluator, diagnostics: []const Diagnostic, source: []const u8, source_path: ?[]const u8) !void {
        try self.run.replaceDiagnostics(diagnostics, source, source_path);
    }

    /// Parse and compile source text into a registered chunk id. Used by
    /// debugging tools that want to inspect bytecode without running it.
    pub fn compileSource(
        self: *Evaluator,
        source: []const u8,
        source_path: ?[]const u8,
    ) !ChunkId {
        return self.parseAndCompile(source, self.base_path, source_path, null);
    }

    /// `compileSource` with an ambient scope attrset (see
    /// `evaluateWithScope`). The repl's `:disasm` compiles expressions that
    /// reference repl bindings through this.
    pub fn compileSourceScoped(self: *Evaluator, source: []const u8, scope: ?Value) !ChunkId {
        return self.parseAndCompile(source, self.base_path, null, scope);
    }

    /// Parse + compile + register, returning the compiled chunk id.
    /// Shared by `compileSource` (public, no eval) and `evaluateSource`
    /// (the internal eval entrypoint that runs the chunk afterwards).
    fn parseAndCompile(
        self: *Evaluator,
        source: []const u8,
        base_path: ?[]const u8,
        source_path: ?[]const u8,
        scope: ?Value,
    ) !ChunkId {
        const subject = source_path orelse "expression";

        var arena = ast_mod.AstArena.init(self.allocator);
        // Freed here unless a deferred attr body retains nodes into it
        // (then the arena is moved into `retained_arenas`, below).
        var retain_arena = false;
        defer if (!retain_arena) arena.deinit();

        var parser = parser_mod.Parser.init(self.allocator, &arena, source);
        defer parser.deinit();
        // Body-span elision: skip PARSING large attrset value bodies that
        // lazy per-attr compilation would defer anyway; the compiler
        // sub-parses them on demand (`literals.materializeElided`). File
        // compiles only, mirroring the deferral gate (`shouldDeferSet`).
        parser.elide_bodies = source_path != null;

        const ast_node = blk: {
            self.progressBegin(.parse, subject);
            defer self.progressEnd(.parse, subject);
            timeline.begin(.parse, subject, 0);
            defer timeline.end(.parse);
            const pt = prof.start(.parse);
            defer prof.end(.parse, pt);
            // RSS attribution: blocks the parse grows (AST arena chunks,
            // parser scratch) belong to the "ast-arena" bucket — the
            // retained ones live as long as the evaluator.
            const prev_tag = vma_mod.setAllocTag(.ast_arena);
            defer _ = vma_mod.setAllocTag(prev_tag);
            break :blk parser.parse() catch {
                try self.copyDiagnostics(parser.diagnostics.items, source, source_path);
                return error.ParseError;
            };
        };

        // Compile-time feature gate. Pipe operators always parse (into tagged
        // apply nodes); enabling them is required to compile. Like Nix, we
        // reject on *presence* — the parser records whether any `|>`/`<|`
        // was seen, so a pipe anywhere in the file (even an unused/deferred
        // attr body) fails here, before any compilation runs.
        if (parser.used_pipe_operators and !self.policy.pipe_operators_enabled) {
            const tok = parser.first_pipe_token.?;
            try self.copyDiagnostics(&.{.{
                .severity = .err,
                .kind = .compile,
                .line = parser_mod.Parser.tokenLine(source, tok),
                .column = diagnostic.columnForOffset(source, tok.offset),
                .offset = tok.offset,
                .len = tok.len,
                .token_type = tok.type,
                .message = "pipe operators are disabled; pass --extra-experimental-features pipe-operators to enable them",
            }}, source, source_path);
            return error.PipeOperatorsDisabled;
        }

        // Lix deprecated CR/CRLF line endings: rejected by default, re-permitted
        // by `cr-line-endings`. The scanner records the first structural CR; the
        // parse still succeeds (CR is treated as a line ending) so enabling the
        // feature Just Works.
        if (parser.first_cr_offset) |cr_off| {
            if (!self.policy.allow_cr_line_endings) {
                try self.copyDiagnostics(&.{.{
                    .severity = .err,
                    .kind = .compile,
                    .line = diagnostic.lineForOffset(source, cr_off),
                    .column = diagnostic.columnForOffset(source, cr_off),
                    .offset = cr_off,
                    .len = 1,
                    .token_type = null,
                    .message = "CR (`\\r`) and CRLF (`\\r\\n`) line endings are not supported. Please inspect the file and normalize it to use LF (`\\n`) line endings instead. Use --extra-deprecated-features cr-line-endings to silence this warning.",
                }}, source, source_path);
                return error.CrLineEndingsDisabled;
            }
        }

        // Lix deprecated `tokens-no-whitespace`: a value token stuck to the next
        // token without whitespace is rejected by default. The tokenization
        // still succeeds, so enabling the feature Just Works.
        if (parser.first_tokens_no_ws_offset) |off| {
            if (!self.policy.allow_tokens_no_whitespace) {
                try self.copyDiagnostics(&.{.{
                    .severity = .err,
                    .kind = .compile,
                    .line = diagnostic.lineForOffset(source, off),
                    .column = diagnostic.columnForOffset(source, off),
                    .offset = off,
                    .len = 1,
                    .token_type = null,
                    .message = "whitespace between tokens is required here. Use --extra-deprecated-features tokens-no-whitespace to disable this error.",
                }}, source, source_path);
                return error.TokensNoWhitespaceDisabled;
            }
        }

        // Per-compilation-unit scratch arena: all of the compiler's
        // transient structures (builder buffers, locals/captures, strictness
        // and name-resolution maps, diagnostics) allocate here and are freed
        // wholesale when this returns. Only the emitted chunk is duped onto
        // the long-lived allocator (at `builder.finish`). The AST arena above
        // is separate — it may be retained for deferred bodies; this one never
        // is, since nothing persistent points into it.
        var scratch = @import("base").arena.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const scratch_alloc = scratch.allocator();

        var builder = try ChunkBuilder.init(scratch_alloc);
        defer builder.deinit(scratch_alloc);

        var compiler = compiler_mod.Compiler.init(
            scratch_alloc,
            self.allocator,
            &builder,
            &self.registry,
            source,
            &self.intern,
            &self.heap,
        );
        compiler.base_path = base_path;
        compiler.source_path = source_path;
        compiler.home_dir = if (self.env_map) |env| env.get("HOME") else null;
        compiler.policy = self.policy;
        // Set eagerly (not lazily on first position record, see sourceFileId):
        // chunks registered before any position record would otherwise miss
        // their file in the disasm sidecar.
        if (self.registry.capture_names) {
            if (source_path) |p| compiler.source_file_id = try self.intern.intern(p);
        }
        // A scoped import (`builtins.scopedImport`) supplies BOTH an ambient
        // scope and a source path; that attrset replaces the base env, so free
        // identifiers — even ones that name builtins — must bind to it first. A
        // repl/debug overlay also carries a scope but no source_path, and must
        // keep builtins visible; hence the source_path conjunct.
        compiler.scoped_base = scope != null and source_path != null;
        compiler.deferred_table = &self.deferred_table;
        // Elided bodies materialize into the file's AST arena (retained
        // below alongside deferred bodies); this compile is single-threaded,
        // so in-place node replacement is safe and keeps every later
        // consumer's view identical to an eager parse.
        compiler.ast_arena = &arena;
        compiler.elide_mutable = true;
        defer compiler.deinit();

        {
            self.progressBegin(.compile, subject);
            defer self.progressEnd(.compile, subject);
            timeline.begin(.compile, subject, 0);
            defer timeline.end(.compile);
            const ct = prof.start(.compile);
            defer prof.end(.compile, ct);
            compiler.compileAndFinish(ast_node, scope) catch |err| {
                try self.copyDiagnostics(compiler.diagnostics.items, source, source_path);
                return err;
            };
        }

        const chunk = try builder.finish(self.allocator, compiler.slot_count);
        // The top-level chunk registers outside `registerChunk`; name it after
        // the file (a useful `while evaluating 'configuration.nix'`). A bare
        // `-e` expression stays anonymous so its trace reads plain. disasm adds
        // its own `(top)` tag for pathless chunks.
        const top_name: bytecode.NameId = if (source_path) |p|
            (self.registry.childName(bytecode.NAME_ROOT, try self.intern.intern(std.fs.path.basename(p)), false) catch bytecode.NAME_ROOT)
        else if (self.registry.capture_names)
            (self.registry.childName(bytecode.NAME_ROOT, try self.intern.intern("(top)"), true) catch bytecode.NAME_ROOT)
        else
            bytecode.NAME_ROOT;
        const chunk_id = try self.registry.registerNamed(chunk, top_name);
        if (compiler.source_file_id) |f| try self.registry.recordFile(chunk_id, f);
        // Local binding names for the top chunk (child chunks get theirs in
        // `registerChunk`); lets the debugger and disasm name top-level locals.
        if (self.registry.capture_names) try self.registry.recordLocalNames(chunk_id, compiler.local_names.items);
        // `chunk` now owns persistent copies of its bytecode; `scratch`
        // (incl. `builder`'s buffers) is freed by the defers above.

        // If any attr body in this file was deferred, its AST nodes are
        // referenced by `deferred_table` entries and must outlive the
        // compile — keep the arena alive for the evaluator's lifetime.
        if (compiler.deferred_count > 0) {
            retain_arena = true; // nodes are referenced; never free here
            self.retained_arenas_mu.lock();
            defer self.retained_arenas_mu.unlock();
            // Best-effort: on OOM we intentionally leak (don't free AST a
            // deferred entry still points at) rather than risk a dangling node.
            self.retained_arenas.append(self.allocator, arena) catch {};
        }
        return chunk_id;
    }

    /// Read-only access to compiled chunks for tools.
    pub fn getChunk(self: *const Evaluator, id: ChunkId) ?*const bytecode.Chunk {
        return self.registry.get(id);
    }

    /// Read-only access to the intern table for tools.
    pub fn internTable(self: *const Evaluator) *const InternTable {
        return &self.intern;
    }

    /// The `builtins` attrset, built on first use. Single-threaded callers
    /// only (the repl's completer wants it before the first evaluation).
    pub fn builtinsValue(self: *Evaluator) !Value {
        return self.ensureBuiltins();
    }

    /// Read-only access to the chunk registry for tools.
    pub fn chunkRegistry(self: *const Evaluator) *const ChunkRegistry {
        return &self.registry;
    }

    /// Enable best-effort chunk naming: the compiler records the attr/let
    /// binding name behind each lambda/thunk chunk into a registry sidecar, for
    /// `fix disasm` to display. Off by default (hot compiles pay nothing); only
    /// safe to enable for a single-threaded compile. Set before compiling.
    pub fn setCaptureChunkNames(self: *Evaluator, on: bool) void {
        self.registry.capture_names = on;
    }

    /// Install (or clear) the interactive debugger. `run` is called on the
    /// demand fiber each time evaluation pauses (a `builtins.break`, or — with
    /// `enterDebuggerOnError` — an evaluation error); it drives the console and
    /// returns to resume. `ctx` is the UI's opaque self-pointer. The CLI owns
    /// the UI implementation (terminal I/O lives in `cli`); the engine only
    /// upcalls through this seam, so the layering stays down-only.
    pub fn setDebugUi(self: *Evaluator, ctx: *anyopaque, run: *const fn (*anyopaque, *DebugSession) anyerror!void) void {
        self.debug_ui = .{ .ctx = ctx, .run = run };
        if (self.breakpoints == null) {
            self.breakpoints = bytecode.BreakpointTable.init(self.allocator, &self.intern);
            // Newly (often lazily) compiled chunks get pending breakpoints too.
            self.registry.breakpoint_sink = self.breakpoints.?.sink();
        }
    }

    /// `vm_mod.BreakSink.fire` trampoline: build a `DebugSession` over the
    /// paused VM and hand it to the installed UI. Runs synchronously on the
    /// current demand fiber, so the console can re-enter the evaluator.
    fn fireBreak(ctx: *anyopaque, vm: *VM, value: Value, reason: vm_mod.BreakReason) anyerror!void {
        const self: *Evaluator = @ptrCast(@alignCast(ctx));
        // A break/throw raised while the console is evaluating an expression
        // must not recurse into a nested debugger.
        if (self.debug_in_session) return;
        const ui = self.debug_ui orelse return;
        self.debug_in_session = true;
        defer self.debug_in_session = false;
        var session: DebugSession = .{ .ev = self, .vm = vm, .value = value, .reason = reason };
        try ui.run(ui.ctx, &session);
    }

    /// Console-expression evaluation from a debug pause: compile `source` in an
    /// ambient `scope` and run it on a fresh nested VM (sharing the registry,
    /// heap, and intern table). The nested VM leaves the paused VM's stack and
    /// frames untouched, so inspecting a value can't corrupt the pause point.
    fn debugEvalScoped(self: *Evaluator, _: *VM, source: []const u8, scope: ?Value) !Value {
        const chunk_id = try self.compileSourceScoped(source, scope);
        return self.runWithVm(debugRunBody, .{chunk_id});
    }

    fn debugRunBody(vm: *VM, chunk_id: ChunkId) !Value {
        return vm.eval(chunk_id);
    }

    pub fn heapStats(self: *const Evaluator) ObjectHeap.Stats {
        return self.heap.stats();
    }

    pub fn internStats(self: *const Evaluator) InternTable.Stats {
        return self.intern.stats();
    }

    pub fn chunkStats(self: *const Evaluator) ChunkRegistry.Stats {
        return self.registry.stats();
    }

    pub fn schedulerStats(self: *const Evaluator) Scheduler.Stats {
        return self.scheduler.stats();
    }

    pub fn workerCount(self: *const Evaluator) u8 {
        return self.scheduler.worker_count;
    }

    pub fn setParallelismToggles(self: *Evaluator, disable_speculation: bool, disable_fanout: bool) void {
        var config = self.scheduler.configuration();
        config.disable_speculation = disable_speculation;
        config.disable_fanout = disable_fanout;
        self.scheduler.configure(config);
    }

    /// Compile source text into bytecode and evaluate it.
    /// This is the main public API.
    pub fn evaluate(self: *Evaluator, source: []const u8) !Value {
        return self.evaluateTop(source, null, null);
    }

    /// `evaluate`, attributing the top-level source to `source_path` — source
    /// spans and the disasm file sidecar then carry the entry file's name, the
    /// same way imported files do. Used by `fix disasm --eval`.
    pub fn evaluatePath(self: *Evaluator, source: []const u8, source_path: ?[]const u8) !Value {
        return self.evaluateTop(source, source_path, null);
    }

    /// Like `evaluate`, but compiles the source inside an ambient scope
    /// attrset (identifiers not otherwise bound resolve from `scope`, the
    /// same mechanism as `builtins.scopedImport`). The repl uses this to
    /// make its bindings visible. `scope` is baked into the compiled
    /// chunk's constants, which are GC roots.
    pub fn evaluateWithScope(self: *Evaluator, source: []const u8, scope: ?Value) !Value {
        return self.evaluateTop(source, null, scope);
    }

    fn evaluateTop(self: *Evaluator, source: []const u8, source_path: ?[]const u8, scope: ?Value) !Value {
        // Build the builtins attrset on the main thread before any helpers
        // can race on it. `buildAttrSet` predicts the next ObjectId for
        // the self-reference `builtins.builtins`; that prediction is only
        // safe when no other thread is allocating objects.
        _ = try self.ensureBuiltins();
        if (!self.scheduler.isStarted()) {
            self.scheduler.configure(tuning.resolve(self.scheduler.configuration(), self.env_map, self.worker_count));
        }
        // Speculative import prefetch: `.nix` path constants of freshly
        // compiled chunks are parse+compile+evaluated ahead of demand on
        // the spec lane (the braid-window perf decomposition measured
        // ~25-50ms of import parse+compile sitting ON the critical chain
        // at w=8 while every helper parked). The import registry dedups
        // and coordinates, so a prefetch is exactly the import the demand
        // fiber would have run — started earlier. Default ON whenever
        // helpers exist. (The old 2..16 gate mirrored the novel lane's:
        // at w=32 extra spec-lane volume chased junk. Re-measured
        // 2026-07-11 with the bulk-spec drain cap containing that
        // volume — prefetch-on measured -5% median at w=32, so the
        // gate is gone.) FIX_IMPORT_PREFETCH=0/1 overrides,
        // FIX_IMPORT_PREFETCH_MAX bounds submissions per eval.
        {
            var on = self.worker_count >= 2;
            var max: u32 = 8192;
            if (self.env_map) |em| {
                if (em.get("FIX_IMPORT_PREFETCH")) |s| on = !std.mem.eql(u8, s, "0");
                if (em.get("FIX_IMPORT_PREFETCH_MAX")) |s| {
                    if (std.fmt.parseInt(u32, s, 10)) |n| max = n else |_| {}
                }
            }
            if (on and self.worker_count > 1) {
                self.prefetch.budget = max;
                self.registry.path_const_sink = .{ .ctx = self, .call = prefetchPathConst };
            } else {
                self.prefetch.budget = 0;
                self.registry.path_const_sink = null;
            }
        }
        // Speculative readDir-children prefetch: a cold builtins.readDir
        // whose listing is a directory-of-directories fans the children out
        // to helpers, who warm the FileCache ahead of the demand fiber's
        // serial child-readDir walk (pkgs/by-name: 756 shard listings
        // back-to-back on the critical chain, ~19ms at w=8). Same default
        // gate as import prefetch (ON whenever helpers exist; the old
        // w<=16 bound fell with the bulk-spec drain cap, same evidence);
        // FIX_READDIR_PREFETCH=0/1 overrides, FIX_READDIR_PREFETCH_MIN
        // tunes the directory-children threshold,
        // FIX_READDIR_PREFETCH_MAX bounds total child listings per eval.
        {
            var on = self.worker_count >= 2;
            var min: u32 = 32;
            var max: u32 = 16384;
            if (self.env_map) |em| {
                if (em.get("FIX_READDIR_PREFETCH")) |s| on = !std.mem.eql(u8, s, "0");
                if (em.get("FIX_READDIR_PREFETCH_MIN")) |s| {
                    if (std.fmt.parseInt(u32, s, 10)) |n| min = n else |_| {}
                }
                if (em.get("FIX_READDIR_PREFETCH_MAX")) |s| {
                    if (std.fmt.parseInt(u32, s, 10)) |n| max = n else |_| {}
                }
            }
            if (on and self.worker_count > 1)
                self.scheduler.setReadDirPrefetch(min, max)
            else
                self.scheduler.setReadDirPrefetch(0, 0);
        }
        try self.scheduler.start(helperLoop, self);
        self.clearDiagnostics();
        self.store.derivations.clearDebugRecords();
        // Not routed through `evaluateSource`: its top-level detection is
        // `source_path == null`, so passing the path there would send the
        // top-level eval down the nested-import path (wrong fiber). Attribute
        // the source at compile time (and bake `scope` into the chunk's
        // constants, the repl's ambient-scope mechanism), then run on the
        // main worker as usual.
        const chunk_id = try self.parseAndCompile(source, self.base_path, source_path, scope);
        const subject = source_path orelse "expression";
        self.progressBegin(.evaluate, subject);
        defer self.progressEnd(.evaluate, subject);
        timeline.instant(.evaluate, subject);
        return self.runChunkOnMainWorker(chunk_id);
    }

    pub fn evaluateSource(
        self: *Evaluator,
        source: []const u8,
        base_path: ?[]const u8,
        source_path: ?[]const u8,
        scope: ?Value,
        /// The calling VM's `native_depth` (the `import` builtin already +1'd
        /// it). The nested import VM inherits `parent_depth - 1` so imports are
        /// GC-safepoint-transparent (a top-level import collects at depth 0; a
        /// nested one stays gated at the caller's depth). 0 for the top level.
        parent_depth: u32,
    ) !Value {
        const chunk_id = try self.parseAndCompile(source, base_path, source_path, scope);
        const subject = source_path orelse "expression";
        self.progressBegin(.evaluate, subject);
        defer self.progressEnd(.evaluate, subject);
        timeline.instant(.evaluate, subject);
        // Only a top-level eval (no source_path — a plain or repl-scoped
        // entry) goes through a main-thread fiber so the main thread can
        // yield on a `.busy` thunk; nested invocations (imports, scoped
        // imports — which always carry the imported file's path) run
        // synchronously on the existing fiber's stack — they share the
        // surrounding fiber's execution identity via the ctx pointer
        // `initVm` copies.
        if (source_path == null) {
            return self.runChunkOnMainWorker(chunk_id);
        }
        // Per-import scratch arena: the nested VM's run-path allocations
        // (drv hashing, builtin temp buffers) are freed wholesale when the
        // import returns instead of accreting for the evaluator's lifetime.
        var scratch = @import("base").arena.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        var vm = try self.initVm(0, scratch.allocator());
        defer vm.deinit();
        // Depth-transparent import: the fresh nested VM inherits the caller's
        // depth minus 1 (dropping the `import` builtin's own +1), so a
        // top-level import evaluates at depth 0 (collects) while a nested one
        // stays gated at the enclosing builtin's depth. native_depth lives on
        // the VM (fiber-local), so no threadlocal dance is needed.
        vm.native_depth = parent_depth -| 1;
        // This VM isn't in a Worker's fiber list; make its roots visible to GC.
        eval_gc.registerVm(self, &vm);
        defer eval_gc.unregisterVm(self, &vm);
        return vm.eval(chunk_id);
    }

    fn runChunkOnMainWorker(self: *Evaluator, chunk_id: ChunkId) !Value {
        return self.runWithVm(VM.eval, .{chunk_id});
    }

    /// `scratch` is the VM's allocation arena — per-fiber (reset when the
    /// fiber is recycled) or per-import (freed when the import returns).
    /// It MUST be an arena: VM run paths lean on arena semantics — frees
    /// are best-effort, error/suspend paths may abandon allocations, and
    /// the sweep happens wholesale at reset/deinit. It must NOT live for
    /// the whole evaluator: that retained ~240 MB (w=1) / ~380 MB (w=8)
    /// of dead interleaved scratch pages on a NixOS eval (~490 MB of
    /// transient traffic per run never reclaimed by a never-reset arena).
    fn initVm(self: *Evaluator, worker_id: u8, scratch: std.mem.Allocator) !VM {
        // RSS attribution: the VM's own allocations (gc lists; the
        // stack/frames go through the shared pool) get the worker bucket.
        const prev_tag = vma_mod.setAllocTag(.worker_arena);
        defer _ = vma_mod.setAllocTag(prev_tag);
        var vm = try VM.init(.{
            .allocator = scratch,
            .buffer_pool = &self.vm_buffers,
            .registry = &self.registry,
            .intern = &self.intern,
            .heap = &self.heap,
            .files = &self.files,
            .fetchers = &self.fetchers,
            .derivations = &self.store.derivations,
            .scheduler = &self.scheduler,
            // Helpers (worker_id != 0) don't write to the shared trace —
            // it's a side effect of *real* evaluation, so speculative force
            // stays invisible to it.
            .trace_sink = if (worker_id == 0) &self.run.trace else null,
            // All workers get the *concurrent span* half of the progress
            // protocol (`beginSpan`/`endSpan` — store writes, fetches), whose
            // std.Progress nodes are independent and lock-free-safe from any
            // thread. The single-writer LIFO stage stack stays
            // demand-fiber-only structurally: its `StageSink` handle lives on
            // the demand fiber's ExecutionContext (installed by
            // `Worker.runTopLevel`; nested VMs share the ctx pointer, see
            // below), so a helper has no way to touch `active[]`.
            .progress_spans = if (self.progress) |p| p.spans else null,
            .vm_trace = if (worker_id == 0) self.vm_trace else null,
            // The thunk trace IS shared across workers — diagnosing
            // concurrency-shaped wrong-result bugs needs to see every
            // helper's resolves, not just main's. The trace handles
            // its own locking.
            .thunk_trace = self.thunk_trace,
            .import_host = .{ .context = self, .import_value = importValue, .scoped_import = scopedImportValue, .find_file = findFile, .get_env = getEnv },
            .builtins_value = try self.ensureBuiltins(),
            .deferred_table = &self.deferred_table,
            .regexes = &self.regexes,
            .break_sink = if (self.debug_ui != null) .{ .ctx = self, .fire = fireBreak } else null,
            .breakpoints = if (self.breakpoints != null) &self.breakpoints.? else null,
            .policy = self.policy,
            .lazy_shells_visible = self.lazy_shells_visible,
        });
        // A nested VM runs on the surrounding fiber, so it borrows that
        // fiber's execution identity wholesale: claim id (any thunk it
        // claims is attributed to the fiber, not to a default that would
        // collide with pool fiber #0 and cause spurious blackholes),
        // demand flag, and the demand-only progress handles (stage stack,
        // "waiting on" record). One pointer copy — nested VMs (imports,
        // render/force bodies) CANNOT diverge from their fiber, so
        // stage/count/wait emission stays alive across them on the demand
        // fiber while a helper fiber's nested VMs stay structurally silent.
        // No current fiber (pool-VM construction on the worker thread,
        // single-threaded setup) keeps the neutral static default; the
        // Worker then binds pool VMs to their own fiber's ctx.
        if (fiber_mod.currentFiber()) |inner| {
            const wf: *worker_mod.WorkerFiber = @fieldParentPtr("inner", inner);
            vm.ctx = &wf.ctx;
        }
        return vm;
    }

    pub fn writeJsonValue(self: *Evaluator, writer: *std.Io.Writer, value: Value) !void {
        self.progressBegin(.render, "result");
        timeline.instant(.render, "result");
        defer self.progressEnd(.render, "result");
        self.run.trace.clear();
        return self.runWithVm(vm_builtins.writeJsonValue, .{ writer, value });
    }

    pub fn writeXmlValue(self: *Evaluator, writer: *std.Io.Writer, value: Value) !void {
        self.progressBegin(.render, "result");
        timeline.instant(.render, "result");
        defer self.progressEnd(.render, "result");
        self.run.trace.clear();
        return self.runWithVm(vm_builtins.writeLazyXmlValue, .{ writer, value });
    }

    pub fn forceValue(self: *Evaluator, value: Value) !Value {
        self.run.trace.clear();
        return self.runWithVm(vm_force.forceValue, .{value});
    }

    /// Enable writing forced derivations + their sources to the store as they
    /// are forced (`fix instantiate`/`build`). The daemon connects lazily on
    /// first use; plain eval leaves this off and never touches the store.
    pub fn enableStoreWrites(self: *Evaluator) void {
        self.store.derivations.enableStoreWrites();
    }

    /// The last daemon error message, for surfacing `error.DaemonError`.
    pub fn lastStoreError(self: *Evaluator) ?[]const u8 {
        return self.store.derivations.lastStoreError();
    }

    /// If `value` is a derivation (an attrset with a `drvPath`), force it — which
    /// also instantiates its closure when a daemon is attached — and return the
    /// drv path (borrowed from the intern table). Returns null if `value` is not
    /// a derivation-shaped attrset.
    pub fn derivationDrvPath(self: *Evaluator, value: Value) !?[]const u8 {
        return self.derivationAttrPath(value, "drvPath");
    }

    /// The default output path (`outPath`) of a derivation `value`, or null if
    /// it is not a derivation-shaped attrset.
    pub fn derivationOutPath(self: *Evaluator, value: Value) !?[]const u8 {
        return self.derivationAttrPath(value, "outPath");
    }

    fn derivationAttrPath(self: *Evaluator, value: Value, attr_name: []const u8) !?[]const u8 {
        const forced = try self.forceValue(value);
        if (!forced.isAttrs()) return null;
        return self.forcedStringAttr(forced.asObjectId(), attr_name);
    }

    /// The name of the program `fix run` should exec from a derivation's output:
    /// `meta.mainProgram`, else `pname`, else `name`. Borrowed from intern.
    pub fn derivationProgram(self: *Evaluator, value: Value) !?[]const u8 {
        const forced = try self.forceValue(value);
        if (!forced.isAttrs()) return null;
        const id = forced.asObjectId();
        if (try self.heap.getAttrValueOpt(id, try self.intern.intern("meta"))) |meta| {
            const meta_forced = try self.forceValue(meta);
            if (meta_forced.isAttrs()) {
                if (try self.forcedStringAttr(meta_forced.asObjectId(), "mainProgram")) |main| return main;
            }
        }
        if (try self.forcedStringAttr(id, "pname")) |pname| return pname;
        return self.forcedStringAttr(id, "name");
    }

    /// Force attribute `name` of `id` and return its text (string/path/context),
    /// or null if absent or non-string. Borrowed from the intern table.
    fn forcedStringAttr(self: *Evaluator, id: types.ObjectId, name: []const u8) !?[]const u8 {
        const name_id = try self.intern.intern(name);
        const attr = (try self.heap.getAttrValueOpt(id, name_id)) orelse return null;
        const forced = try self.forceValue(attr);
        const text_id = switch (forced.kind()) {
            .string, .path => forced.asInternId(),
            .string_context => (try self.heap.getContextString(forced.asObjectId())).text,
            else => return null,
        };
        return self.intern.get(text_id);
    }

    /// Write `drv_path`'s `.drv` closure to the store on demand (deps-first via
    /// the recipe graph). Since forcing only records recipes, this is how a `.drv`
    /// is materialized — for `instantiate`, and before a build. Must run before
    /// eval state is released (it reads the recipe graph).
    pub fn ensureDerivationClosure(self: *Evaluator, drv_path: []const u8) !void {
        return self.store.derivations.ensureClosure(drv_path);
    }

    /// Finish evaluation and return the only state needed by the build phase.
    /// Language teardown overlaps daemon work once the returned session starts
    /// a build; callers must keep the session alive until that work completes.
    pub fn beginBuildPhase(self: *Evaluator, derived_paths: []const []const u8) !BuildSession {
        // Writes are demand-driven: materialize each target's `.drv` closure now,
        // BEFORE releasing eval state — `ensureClosure` walks the recipe graph,
        // which `releaseEvalState` frees. (Cheap, and inherently sequential: the
        // daemon can't build a `.drv` whose closure isn't on disk yet.)
        for (derived_paths) |derived| {
            const drv = derived[0..(std.mem.indexOfScalar(u8, derived, '!') orelse derived.len)];
            try self.store.derivations.ensureClosure(drv);
        }
        // Now release on a helper thread so the build launches immediately and
        // the ~2 GB heap teardown overlaps it. If the thread can't spawn, fall
        // back to serial release-then-build.
        const releaser = std.Thread.spawn(.{}, releaseEvalState, .{self}) catch blk: {
            self.releaseEvalState();
            break :blk null;
        };
        return .{ .store = &self.store, .release_thread = releaser };
    }

    /// Set the per-connection daemon settings (`--cores`/`--max-jobs`/… via
    /// `set_options`) applied when the store connects. See `setup.configure`.
    pub fn setDaemonBuildSettings(self: *Evaluator, settings: host.store.BuildSettings) !void {
        return self.store.derivations.setBuildSettings(settings);
    }

    /// Override the nix-daemon socket path (`$NIX_DAEMON_SOCKET_PATH`).
    pub fn setDaemonSocket(self: *Evaluator, path: []const u8) !void {
        return self.store.derivations.setDaemonSocket(path);
    }

    /// Navigate a dotted attr path (e.g. `python3Packages.requests`) from `value`,
    /// forcing each step. Returns null if any component is missing or non-attrs.
    pub fn attrPathValue(self: *Evaluator, value: Value, path: []const u8) !?Value {
        var current = try self.forceValue(value);
        var it = std.mem.splitScalar(u8, path, '.');
        while (it.next()) |component| {
            if (!current.isAttrs()) return null;
            const name_id = try self.intern.intern(component);
            const attr = (try self.heap.getAttrValueOpt(current.asObjectId(), name_id)) orelse return null;
            current = try self.forceValue(attr);
        }
        return current;
    }

    pub fn forceDeep(self: *Evaluator, value: Value) !void {
        self.progressBegin(.render, "strict result");
        defer self.progressEnd(.render, "strict result");
        timeline.instant(.render, "strict result");
        self.run.trace.clear();
        return self.runWithVm(vm_force.forceDeepCounted, .{value});
    }

    /// Run `body(vm, args...)` on this Evaluator's main worker. If we're
    /// already inside a fiber (nested call from inside an evaluation),
    /// reuse the surrounding fiber's claim identity via a fresh VM. If
    /// we're on a bare OS thread, spin up a one-shot main Worker so the
    /// body's `.busy` thunks yield through the standard fiber machinery
    /// instead of blocking the thread. The body's payload type is
    /// inferred from its return signature; void payloads work too.
    fn runWithVm(self: *Evaluator, comptime body: anytype, args: anytype) !ReturnPayload(@TypeOf(body)) {
        if (fiber_mod.currentFiber() != null) {
            var scratch = @import("base").arena.ArenaAllocator.init(self.allocator);
            defer scratch.deinit();
            var vm = try self.initVm(0, scratch.allocator());
            defer vm.deinit();
            eval_gc.registerVm(self, &vm);
            defer eval_gc.unregisterVm(self, &vm);
            return @call(.auto, body, .{&vm} ++ args);
        }
        const Args = @TypeOf(args);
        const Ret = ReturnPayload(@TypeOf(body));
        const Ctx = struct {
            ev: *Evaluator,
            body_args: Args,
            result: Ret = undefined,
            err: ?anyerror = null,

            fn entry(arg: *anyopaque) void {
                const ctx: *@This() = @ptrCast(@alignCast(arg));
                var scratch = @import("base").arena.ArenaAllocator.init(ctx.ev.allocator);
                defer scratch.deinit();
                var vm = ctx.ev.initVm(0, scratch.allocator()) catch |e| {
                    ctx.err = e;
                    return;
                };
                defer vm.deinit();
                eval_gc.registerVm(ctx.ev, &vm);
                defer eval_gc.unregisterVm(ctx.ev, &vm);
                const result = @call(.auto, body, .{&vm} ++ ctx.body_args) catch |e| {
                    ctx.err = e;
                    return;
                };
                ctx.result = result;
            }
        };
        var ctx: Ctx = .{ .ev = self, .body_args = args };
        const worker = try self.ensureMainWorker();
        // Demand-role handles for the top fiber's execution context, read
        // fresh per entry (a progress sink (re)installed between runs — the
        // repl — is picked up here with no worker-side bookkeeping). Both
        // stay null when progress isn't drawn, so the demand fiber's
        // stage/wait writes remain structurally free in benchmark/piped runs.
        try worker.runTopLevel(Ctx.entry, @ptrCast(&ctx), .{
            .progress_stage = if (self.progress) |p| p.stage else null,
            .progress_wait = if (self.progress != null) &self.progress_wait else null,
        });
        if (ctx.err) |e| return e;
        return ctx.result;
    }

    fn ensureMainWorker(self: *Evaluator) !*worker_mod.Worker {
        if (self.main_worker) |w| return w;
        const w = try worker_mod.Worker.init(
            self.allocator,
            &self.scheduler,
            0,
            self,
            initVmForWorkerSlot,
        );
        self.main_worker = w;
        // Register the collect callback now that `self` is at
        // its final address (init returns by value), and enable reclaim. The
        // collect runs at the forceThunk safepoint when allocation crosses
        // the byte threshold; at --workers>1 it stops the world (all workers
        // park at safepoints) before marking. Register worker 0 so the
        // collector can walk its fibers for roots.
        self.gc_workers[0].store(w, .release);
        self.heap.setGcHook(.{ .ctx = self, .sample = gcCollectThunk });
        // Parallel STW mark (--workers>1): parked peers call this to help
        // drain the graph. Inert at --workers=1 (no peer ever parks).
        self.scheduler.gcSetMarkHook(.{ .ctx = self, .help = gcHelpMarkThunk });
        if (self.env_map) |em|
            if (em.get("FIX_GC_NOREUSE") != null) ObjectHeap.gcSetDisableReuse(true);
        if (self.env_map) |em|
            if (em.get("FIX_GC_PAR_CAP")) |s| {
                if (std.fmt.parseInt(u32, s, 10)) |c| {
                    if (c >= 1) eval_gc.gc_par_cap = c;
                } else |_| {}
            };
        // FIX_GC_STEP_MB (validation): collect every N MB of fresh
        // allocation so the detector exercises every builtin loop.
        var step_bytes: u64 = 0;
        if (self.env_map) |em| {
            if (em.get("FIX_GC_STEP_MB")) |s| {
                if (std.fmt.parseInt(u64, s, 10)) |mb| step_bytes = mb << 20 else |_| {}
            }
        }
        // Collection line: no collection runs until heap-reserved bytes
        // cross it (automatic `clamp(½·MemTotal, 256MB, 8GB)`, overridable
        // via `--max-memory`; see `eval_gc.memoryBudget`).
        // On a roomy machine that line dwarfs the eval → never fires: zero
        // pauses AND zero tracking (lazy arming at line/2, see
        // `heap_gc.enableBudget`); on a tight machine it fires before the
        // eval OOMs. Override 0 = never collect (bump-only). FIX_GC_STEP_MB
        // keeps the eager validation path (tracking from the start).
        const budget = eval_gc.memoryBudget(self);
        if (step_bytes > 0)
            heap_gc.enableCollect(&self.heap, budget, step_bytes)
        else if (budget > 0)
            heap_gc.enableBudget(&self.heap, budget, eval_gc.constrainedMode(self, budget));
        return w;
    }

    /// Type-erased trampoline for the heap's collect callback. Kept here
    /// (next to `setGcHook`) so the `*const fn(*anyopaque, u8) void` ABI
    /// stays exact; the body lives in `eval/gc.zig`. `collector_id` is the
    /// worker that won the collection (its parallel-mark slot).
    fn gcCollectThunk(ctx: *anyopaque, collector_id: u8) void {
        const self: *Evaluator = @ptrCast(@alignCast(ctx));
        eval_gc.collect(self, collector_id);
    }

    /// Replace the caller-held external root set (see
    /// `gc_extra_roots`). The repl passes its scope attrset + loose values
    /// here whenever they change; they stay rooted until replaced.
    pub fn gcSetExternalRoots(self: *Evaluator, roots: []const Value) !void {
        self.gc_extra_roots.clearRetainingCapacity();
        try self.gc_extra_roots.appendSlice(self.allocator, roots);
    }

    pub const CollectNowResult = struct {
        /// False when collection is disabled by policy (`--max-memory=0`)
        /// or nothing has run yet.
        ran: bool,
        reserved_before: u64,
        reserved_after: u64,
    };

    /// GC: run a stop-the-world collection right now, from outside
    /// any evaluation — the repl's between-inputs reclaim. Drives the same
    /// barrier + hook sequence as the in-eval safepoint (vm/force.zig): win
    /// the collector race, park every worker, collect, release. The first
    /// call arms reclaim tracking (`armLazy` — everything already allocated
    /// becomes the untracked old floor); later calls run real minors.
    ///
    /// Callable only between evaluations (no fiber may be mid-flight on the
    /// calling thread); helpers park at their safepoints as in any STW.
    pub fn collectNow(self: *Evaluator) CollectNowResult {
        var result: CollectNowResult = .{
            .ran = false,
            .reserved_before = self.heap.totalReservedBytes(),
            .reserved_after = self.heap.totalReservedBytes(),
        };
        // No hook yet (nothing evaluated) or reclaim disabled by policy
        // (threshold never armed): nothing to do.
        if (self.main_worker == null) return result;
        if (self.heap.gc_threshold_bytes == std.math.maxInt(u64)) return result;
        if (!self.scheduler.gcTryBeginCollection()) return result;
        self.scheduler.gcWaitAllParked(0);
        // Invalidate the token-keyed thread-local caches (thunk memo, attr
        // IC) BEFORE marking: they root the previous evaluation's hottest
        // values (markRoots must treat current-token entries as live), but
        // between evaluations they are semantically dead — without this the
        // last input's whole result graph gets promoted instead of freed.
        // Safe here: the world is stopped. In-eval collections instead bump
        // the token after the sweep (`afterCollect`).
        self.heap.token = runtime.heap.next_heap_token.fetchAdd(1, .monotonic);
        heap_gc.runCollect(&self.heap, 0);
        self.scheduler.gcEndCollection(0);
        result.ran = true;
        result.reserved_after = self.heap.totalReservedBytes();
        return result;
    }

    /// Like `collectNow`, but runs a MAJOR (full) collection — reclaims the
    /// tenured old-generation garbage a minor leaves behind. Used by the repl
    /// between inputs so a heavy input's whole result graph is reclaimed (a
    /// minor only reclaims the young survivors, so under parallel workers, where
    /// more objects tenure, repl memory would otherwise ratchet up). Same STW
    /// dance + cache-invalidating token bump as `collectNow`.
    pub fn collectMajorNow(self: *Evaluator) CollectNowResult {
        var result: CollectNowResult = .{
            .ran = false,
            .reserved_before = self.heap.totalReservedBytes(),
            .reserved_after = self.heap.totalReservedBytes(),
        };
        if (self.main_worker == null) return result;
        if (self.heap.gc_threshold_bytes == std.math.maxInt(u64)) return result;
        if (!self.scheduler.gcTryBeginCollection()) return result;
        self.scheduler.gcWaitAllParked(0);
        self.heap.token = runtime.heap.next_heap_token.fetchAdd(1, .monotonic);
        eval_gc.collectMajor(self, 0);
        self.scheduler.gcEndCollection(0);
        result.ran = true;
        result.reserved_after = self.heap.totalReservedBytes();
        return result;
    }

    /// Type-erased trampoline for the scheduler's parallel-mark hook: a parked
    /// peer helps drain marker slot `worker_id` to termination. Kept here for
    /// the exact fn-pointer ABI; the body lives in `eval/gc.zig`.
    fn gcHelpMarkThunk(ctx: *anyopaque, worker_id: u8) void {
        const self: *Evaluator = @ptrCast(@alignCast(ctx));
        eval_gc.helpMark(self, worker_id);
    }

    fn importValue(context: *anyopaque, path: []const u8, parent_depth: u32) anyerror!Value {
        const self: *Evaluator = @ptrCast(@alignCast(context));
        return imports_mod.importPath(self, path, parent_depth);
    }

    /// This Evaluator's `ChunkRegistry.path_const_sink` target
    /// (`FIX_IMPORT_PREFETCH`):
    /// called for every `.path` constant of every freshly compiled chunk,
    /// from whichever worker ran the compile. Filters to `.nix` files
    /// (directory references — the bulk of e.g. all-packages.nix's ~1.7K
    /// path constants — are mostly never imported in a given eval and
    /// would be junk), dedups per intern id, spends the submission
    /// budget, and hands the path to the spec lane.
    fn prefetchPathConst(context: *anyopaque, path_id: types.InternId) void {
        const self: *Evaluator = @ptrCast(@alignCast(context));
        const text = self.intern.get(path_id);
        if (!std.mem.endsWith(u8, text, ".nix")) return;
        {
            self.prefetch.mu.lock();
            defer self.prefetch.mu.unlock();
            if (self.prefetch.budget == 0) return;
            const gop = self.prefetch.seen.getOrPut(self.allocator, path_id) catch return;
            if (gop.found_existing) return;
            self.prefetch.budget -= 1;
        }
        _ = self.scheduler.submit(.{ .import_prefetch = path_id }, worker_id_mod.current);
    }

    fn scopedImportValue(context: *anyopaque, scope: Value, path: []const u8, parent_depth: u32) anyerror!Value {
        const self: *Evaluator = @ptrCast(@alignCast(context));
        return imports_mod.scopedImportPath(self, scope, path, parent_depth);
    }

    fn findFile(context: *anyopaque, name: []const u8) anyerror!Value {
        const self: *Evaluator = @ptrCast(@alignCast(context));
        return self.findFileInDefaultSearchPath(name);
    }

    fn getEnv(context: *anyopaque, name: []const u8) anyerror![]const u8 {
        const self: *Evaluator = @ptrCast(@alignCast(context));
        const env_map = self.env_map orelse return "";
        return env_map.get(name) orelse "";
    }

    fn findFileInDefaultSearchPath(self: *Evaluator, name: []const u8) !Value {
        return self.search_paths.findFile(self.allocator, &self.files, &self.intern, name);
    }

    fn ensureBuiltins(self: *Evaluator) !Value {
        if (self.builtins_value) |value| return value;
        const nix_path = try self.search_paths.toNixPath(self.allocator);
        defer self.allocator.free(nix_path);
        const value = try builtins.buildAttrSet(&self.intern, &self.heap, nix_path);
        self.builtins_value = value;
        return value;
    }

    pub fn resolveHostPath(self: *Evaluator, path: []const u8) !search_path_mod.ResolvedPath {
        if (std.fs.path.isAbsolute(path)) return .{ .text = path, .owned = false };

        const base_path = self.base_path orelse return error.RelativePath;
        return .{
            .text = try std.fs.path.resolve(self.allocator, &.{ base_path, path }),
            .owned = true,
        };
    }

    pub fn writeValue(self: *Evaluator, writer: *std.Io.Writer, value: Value) !void {
        self.progressBegin(.render, "result");
        timeline.instant(.render, "result");
        defer self.progressEnd(.render, "result");
        return self.runWithVm(writeValueBody, .{ self, writer, value });
    }

    /// Progress stage events are a single-threaded UI concern that must be
    /// driven only by the demand path. Imports/compiles triggered off a
    /// speculative or fan-out force — OR off a background `import_prefetch`
    /// task — run on arbitrary worker fibers and would reentrantly interleave
    /// begin/end pairs into the one std `Progress` tree (whose `active[]`
    /// stack is not thread-safe) → the `Progress.Node.init` "slot reuse"
    /// assert / a torn stack. So the stage handle is structural, not a flag
    /// check: only the demand fiber's ExecutionContext carries a
    /// `progress_stage` (exactly one fiber, emitting sequentially even across
    /// a steal — see `Worker.runTopLevel`); every other fiber's ctx holds
    /// null and this returns null. NB: `!in_speculation` would NOT be a
    /// sufficient gate — a
    /// prefetch task fiber has `in_speculation == false` yet must stay
    /// silent. begin and end share this gate (the handle is stable across a
    /// fiber's life), so pairs stay balanced. No current fiber =
    /// single-threaded setup on the main thread (parse/compile before the
    /// run enters a fiber) — allowed, the demand fiber doesn't exist yet.
    fn stageSink(self: *Evaluator) ?eval_progress.StageSink {
        const progress = self.progress orelse return null;
        const inner = fiber_mod.currentFiber() orelse return progress.stage;
        const wf: *worker_mod.WorkerFiber = @fieldParentPtr("inner", inner);
        return wf.ctx.progress_stage;
    }

    pub fn progressBegin(self: *Evaluator, stage: eval_progress.Stage, subject: []const u8) void {
        if (self.stageSink()) |sink| sink.begin(stage, subject);
    }

    pub fn progressEnd(self: *Evaluator, stage: eval_progress.Stage, subject: []const u8) void {
        if (self.stageSink()) |sink| sink.end(stage, subject);
    }

    pub fn progressInstant(self: *Evaluator, stage: eval_progress.Stage, subject: []const u8) void {
        if (self.stageSink()) |sink| sink.instant(stage, subject);
    }

    /// Build a live counter snapshot for the progress indicator. Cheap — a
    /// handful of plain/atomic loads plus one /proc RSS read. Runs on the
    /// sampler thread; every read here is advisory, so no locking.
    fn readMetrics(self: *Evaluator) eval_progress.Metrics {
        const st = self.scheduler.stats();
        const g = gc.liveReport();
        var m: eval_progress.Metrics = .{
            .objects = self.heap.objects.count(),
            .values = self.heap.values.count(),
            .attrs = self.heap.attrs.count(),
            .reserved_bytes = self.heap.totalReservedBytes(),
            // Footprint, not raw RSS: hugetlb-backed heap bytes are invisible
            // to statm (see base/hugetlb.zig) and would make the live memory
            // counter read near-zero on a --hugetlb run.
            .rss_bytes = gc.currentFootprintBytes(),
            .pending = self.scheduler.pending_tasks.v.load(.monotonic),
            .forced = st.pops,
            .steals = st.steals,
            .spec_submitted = st.speculative_submitted,
            .spec_rejected = st.speculative_rejected,
            .gc_collections = g.collections,
            .gc_live_bytes = g.live_bytes,
            .gc_freed_objects = g.freed_objects,
        };
        m.wait_len = @intCast(self.progress_wait.read(&m.wait_buf));
        return m;
    }

    fn progressSample(self: *Evaluator) void {
        if (self.progress) |p| p.stage.metrics(self.readMetrics());
    }

    /// Live-counter sample period. Paired with the render refresh in
    /// `cli.EvalProgress.init` — sampling faster than the redraw is invisible,
    /// so bump both together. 50ms (20 Hz) keeps the counters feeling live
    /// while staying "reasonable sampling": the cost is a handful of atomic
    /// loads + one /proc read on a background thread that only exists while
    /// progress is drawn — never the eval path. (Deliberately a timer thread,
    /// NOT a per-fiber-quantum hook: quantum emission was tried and starved
    /// `--workers=1` — one long non-yielding quantum → ~2 samples per eval —
    /// and cost a branch per quantum even with progress off.)
    const sample_period_ms = 50;
    /// Stop-flag poll granularity within a sample period (bounds
    /// `stopProgressSampler`'s join latency).
    const stop_check_ms = 10;

    /// Sampler thread body: push a snapshot, then sleep out the sample period
    /// (waking to observe the stop flag). Decoupled from fiber quanta so the
    /// display advances even during a single long `--workers=1` quantum.
    fn progressSampleLoop(self: *Evaluator) void {
        while (!self.progress_stop.load(.acquire)) {
            self.progressSample();
            var slept: u32 = 0;
            while (slept < sample_period_ms and !self.progress_stop.load(.acquire)) : (slept += stop_check_ms) {
                @import("base").sync.sleepNs(stop_check_ms * std.time.ns_per_ms);
            }
        }
    }

    /// Start the background progress sampler. No-op unless progress is drawn,
    /// so it never spins up in benchmark / piped runs.
    pub fn startProgressSampler(self: *Evaluator) void {
        if (self.progress == null) return;
        self.progress_stop.store(false, .release);
        self.progress_thread = std.Thread.spawn(.{}, progressSampleLoop, .{self}) catch null;
    }

    /// Stop and join the sampler, then push one final snapshot so the last
    /// numbers (final heap / GC tally) land before the bar is torn down.
    pub fn stopProgressSampler(self: *Evaluator) void {
        if (self.progress_thread) |t| {
            self.progress_stop.store(true, .release);
            t.join();
            self.progress_thread = null;
        }
        self.progressSample();
    }

    /// Writer-side `[i/N]` item count. `progressCountBegin` sets the render
    /// node's total (once, per top-level collection) and returns whether
    /// counting is live; `progressStep` advances it per element (cheap — no
    /// per-element eligibility recheck). Demand path only.
    pub fn progressCountBegin(self: *Evaluator, total: usize) bool {
        const sink = self.stageSink() orelse return false;
        sink.count(0, total);
        return true;
    }

    pub fn progressStep(self: *Evaluator, completed: usize, total: usize) void {
        if (self.progress) |p| p.stage.count(completed, total);
    }

    pub fn progressSessionBegin(self: *Evaluator, label: []const u8) void {
        if (self.progress) |p| p.stage.sessionBegin(label);
    }

    pub fn progressSessionEnd(self: *Evaluator) void {
        self.progress_wait.clear();
        if (self.progress) |p| p.stage.sessionEnd();
    }
};

/// Helper worker loop. Owns an on-demand fiber pool (no fixed size);
/// each fiber has its own VM and can be parked mid-evaluation when it
/// hits a `.busy` thunk. The Worker drives the fiber drain loop — see
/// `worker.zig`. Errors during speculation are swallowed inside the
/// fiber's entry; the thunk's own `reset()` on failure surfaces the
/// error to a future genuine caller.
fn helperLoop(worker_id: u8, sched: *Scheduler, ev: *Evaluator) void {
    const worker = worker_mod.Worker.init(
        ev.allocator,
        sched,
        worker_id,
        ev,
        initVmForWorkerSlot,
    ) catch {
        // Still pass the quiescence barrier so peers don't wait forever.
        sched.awaitHelpersQuiescent();
        return;
    };
    // GC: register this helper so the collector can walk its fibers
    // for roots. Registration happens before `run()` (before any user-object
    // allocation), and the collector only reads the registry at a stop-the-
    // world where this worker is parked.
    ev.gc_workers[worker_id].store(worker, .release);
    worker.run();
    // Wait until ALL helpers have stopped forcing before destroying any
    // fibers — a still-running helper could resolve a thunk and wake a
    // just-freed enrolled fiber (shutdown UAF). See awaitHelpersQuiescent.
    sched.awaitHelpersQuiescent();
    // Unregister before deinit so a late collection never scans freed fibers.
    // (After awaitHelpersQuiescent no helper is still forcing, so no
    // collection can be triggered past this point, but keep the invariant.)
    ev.gc_workers[worker_id].store(null, .release);
    worker.deinit();
}

fn initVmForWorkerSlot(ctx: *anyopaque, worker_id: u8, _: u32, scratch: std.mem.Allocator) anyerror!VM {
    const ev: *Evaluator = @ptrCast(@alignCast(ctx));
    return ev.initVm(worker_id, scratch);
}

fn ReturnPayload(comptime F: type) type {
    const ret = @typeInfo(F).@"fn".return_type.?;
    return switch (@typeInfo(ret)) {
        .error_union => |eu| eu.payload,
        else => ret,
    };
}

/// Shim that lets `Evaluator.writeValue` reuse the same `runWithVm`
/// machinery as the VM-bodied entries. The output formatter walks
/// values via `Evaluator.forceValue` for nested thunks; the surrounding
/// fiber's identity threads through via initVm, so we don't need a
/// fresh VM here ourselves.
fn writeValueBody(_: *VM, ev: *Evaluator, writer: *std.Io.Writer, value: Value) !void {
    return eval_print.writeValue(ev, writer, value);
}

test {
    _ = @import("eval/tests.zig");
}
