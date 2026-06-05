//! Evaluator — the top-level orchestration layer.
//!
//! Manages the shared state (chunk registry, intern table, scheduler) and runs
//! the worker threads that execute bytecode.

const std = @import("std");
const types = @import("types.zig");
const InternTable = @import("intern.zig").InternTable;
const ChunkRegistry = @import("chunk.zig").ChunkRegistry;
const ChunkBuilder = @import("chunk.zig").ChunkBuilder;
const Scheduler = @import("scheduler.zig").Scheduler;
const VM = @import("vm.zig").VM;
const ObjectHeap = @import("heap.zig").ObjectHeap;
const FileCache = @import("file_cache.zig").FileCache;
const FetchCache = @import("fetch_cache.zig").FetchCache;
const DerivationStore = @import("derivation.zig").DerivationStore;
const derivation = @import("derivation.zig");
const Value = @import("value.zig").Value;
const ThunkState = @import("thunk.zig").ThunkState;
const builtins = @import("builtins.zig");
const parser_mod = @import("parser.zig");
const diagnostic = @import("diagnostic.zig");
const eval_trace = @import("eval_trace.zig");
const eval_progress = @import("eval_progress.zig");
const path_ops = @import("runtime/paths.zig");

pub const Diagnostic = diagnostic.Diagnostic;
pub const EvalTrace = eval_trace.Trace;

pub const Evaluator = struct {
    allocator: std.mem.Allocator,
    intern: InternTable,
    registry: ChunkRegistry,
    scheduler: Scheduler,
    heap: ObjectHeap,
    files: FileCache,
    fetchers: FetchCache,
    derivations: DerivationStore,
    imports: std.StringHashMapUnmanaged(Value),
    imports_in_progress: std.StringHashMapUnmanaged(void),
    search_paths: []SearchPathEntry,
    runtime_arena: std.heap.ArenaAllocator,
    builtins_value: ?Value,
    base_path: ?[:0]u8,
    env_map: ?*const std.process.Environ.Map,
    progress: ?eval_progress.Sink,
    worker_count: u8,
    diagnostics: std.ArrayListUnmanaged(Diagnostic),
    trace: EvalTrace,

    pub fn init(allocator: std.mem.Allocator, worker_count: u8) !Evaluator {
        var scheduler = try Scheduler.init(allocator, worker_count);
        errdefer scheduler.deinit();

        var intern = try InternTable.init(allocator);
        errdefer intern.deinit();

        var registry = try ChunkRegistry.init(allocator);
        errdefer registry.deinit();

        return .{
            .allocator = allocator,
            .intern = intern,
            .registry = registry,
            .scheduler = scheduler,
            .heap = ObjectHeap.init(allocator),
            .files = FileCache.init(allocator),
            .fetchers = FetchCache.init(allocator),
            .derivations = DerivationStore.init(allocator),
            .imports = .empty,
            .imports_in_progress = .empty,
            .search_paths = &.{},
            .runtime_arena = std.heap.ArenaAllocator.init(allocator),
            .builtins_value = null,
            .base_path = null,
            .env_map = null,
            .progress = null,
            .worker_count = worker_count,
            .diagnostics = .empty,
            .trace = EvalTrace.init(allocator),
        };
    }

    pub fn deinit(self: *Evaluator) void {
        if (self.base_path) |path| self.allocator.free(path);
        self.trace.deinit();
        self.diagnostics.deinit(self.allocator);
        var imports_iter = self.imports.iterator();
        while (imports_iter.next()) |kv| self.allocator.free(kv.key_ptr.*);
        self.imports.deinit(self.allocator);
        var progress_iter = self.imports_in_progress.iterator();
        while (progress_iter.next()) |kv| self.allocator.free(kv.key_ptr.*);
        self.imports_in_progress.deinit(self.allocator);
        self.freeSearchPaths();
        self.fetchers.deinit();
        self.derivations.deinit();
        self.files.deinit();
        self.heap.deinit();
        self.runtime_arena.deinit();
        self.scheduler.deinit();
        self.registry.deinit();
        self.intern.deinit();
    }

    pub fn getDiagnostics(self: *const Evaluator) []const Diagnostic {
        return self.diagnostics.items;
    }

    pub fn getTrace(self: *const Evaluator) *const EvalTrace {
        return &self.trace;
    }

    pub fn setDerivationDebug(self: *Evaluator, enabled: bool) void {
        self.derivations.setDebugEnabled(enabled);
    }

    pub fn derivationDebugRecords(self: *const Evaluator) []const derivation.DebugRecord {
        return self.derivations.debugRecords();
    }

    pub fn setBasePathFromCurrentPath(self: *Evaluator, io: std.Io) !void {
        self.files.setIo(io);
        self.fetchers.setIo(io);
        if (self.base_path) |path| self.allocator.free(path);
        self.base_path = try std.process.currentPathAlloc(io, self.allocator);
    }

    pub fn setFileIo(self: *Evaluator, io: std.Io) void {
        self.files.setIo(io);
        self.fetchers.setIo(io);
    }

    pub fn setEnvironment(self: *Evaluator, env_map: *const std.process.Environ.Map) void {
        self.env_map = env_map;
    }

    pub fn setProgressSink(self: *Evaluator, progress: ?eval_progress.Sink) void {
        self.progress = progress;
    }

    pub fn setNixPath(self: *Evaluator, nix_path: []const u8) !void {
        self.freeSearchPaths();

        var entries: std.ArrayListUnmanaged(SearchPathEntry) = .empty;
        errdefer {
            for (entries.items) |entry| entry.deinit(self.allocator);
            entries.deinit(self.allocator);
        }

        var parts = std.mem.splitScalar(u8, nix_path, ':');
        while (parts.next()) |part| {
            if (part.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, part, '=');
            const prefix = if (eq) |i| part[0..i] else "";
            const raw_path = if (eq) |i| part[i + 1 ..] else part;
            if (raw_path.len == 0) continue;

            const resolved = self.resolveHostPath(raw_path) catch |err| switch (err) {
                error.RelativePath => continue,
                else => return err,
            };
            defer if (resolved.owned) self.allocator.free(resolved.text);

            try entries.append(self.allocator, .{
                .prefix = try self.allocator.dupe(u8, prefix),
                .path = try self.allocator.dupe(u8, resolved.text),
            });
        }

        self.search_paths = try entries.toOwnedSlice(self.allocator);
    }

    pub fn readSourceFile(self: *Evaluator, path: []const u8) ![]const u8 {
        const resolved = try self.resolveHostPath(path);
        defer if (resolved.owned) self.allocator.free(resolved.text);
        return self.files.readFile(resolved.text);
    }

    fn clearDiagnostics(self: *Evaluator) void {
        self.diagnostics.clearRetainingCapacity();
        self.trace.clear();
    }

    fn copyDiagnostics(self: *Evaluator, diagnostics: []const Diagnostic) !void {
        self.clearDiagnostics();
        try self.diagnostics.appendSlice(self.allocator, diagnostics);
    }

    /// Compile source text into bytecode and evaluate it.
    /// This is the main public API.
    pub fn evaluate(self: *Evaluator, source: []const u8) !Value {
        self.clearDiagnostics();
        self.derivations.clearDebugRecords();
        return self.evaluateSource(source, self.base_path, null, null);
    }

    fn evaluateSource(
        self: *Evaluator,
        source: []const u8,
        base_path: ?[]const u8,
        source_path: ?[]const u8,
        scope: ?Value,
    ) !Value {
        const subject = source_path orelse "expression";

        // 1. Parse into AST.
        var arena = @import("ast.zig").AstArena.init(self.allocator);
        defer arena.deinit();

        var parser = parser_mod.Parser.init(self.allocator, &arena, source);
        defer parser.deinit();

        const ast_node = blk: {
            self.progressBegin(.parse, subject);
            defer self.progressEnd(.parse, subject);
            break :blk parser.parse() catch {
                try self.copyDiagnostics(parser.diagnostics.items);
                return error.ParseError;
            };
        };

        // 2. Compile AST to bytecode.
        var builder = try ChunkBuilder.init(self.allocator);
        defer builder.deinit(self.allocator);

        var compiler = @import("compiler.zig").Compiler.init(
            self.allocator,
            &builder,
            &self.registry,
            source,
            &self.intern,
        );
        compiler.base_path = base_path;
        compiler.source_path = source_path;
        defer compiler.deinit();

        {
            self.progressBegin(.compile, subject);
            defer self.progressEnd(.compile, subject);
            compiler.compileWithScope(ast_node, scope) catch |err| {
                try self.copyDiagnostics(compiler.diagnostics.items);
                if (preserveCompileError(err)) return err;
                return error.CompileError;
            };
        }

        // Add return + halt.
        try builder.writeOp(self.allocator, .ret);
        try builder.writeOp(self.allocator, .halt);

        const chunk = try builder.finish(self.allocator, compiler.slot_count);
        const chunk_id = try self.registry.register(chunk);

        // 3. Evaluate via a VM.
        var vm = try self.initVm(0);
        defer vm.deinit();

        self.progressBegin(.evaluate, subject);
        defer self.progressEnd(.evaluate, subject);
        return vm.eval(chunk_id);
    }

    fn initVm(self: *Evaluator, worker_id: u8) !VM {
        return VM.init(
            self.runtime_arena.allocator(),
            &self.registry,
            &self.intern,
            &self.heap,
            &self.files,
            &self.fetchers,
            &self.derivations,
            &self.scheduler,
            &self.trace,
            self.progress,
            .{ .context = self, .import_value = importValue, .scoped_import = scopedImportValue, .find_file = findFile, .get_env = getEnv },
            try self.ensureBuiltins(),
            worker_id,
        );
    }

    pub fn writeJsonValue(self: *Evaluator, writer: *std.Io.Writer, value: Value) !void {
        self.progressBegin(.render, "result");
        defer self.progressEnd(.render, "result");
        self.trace.clear();
        var vm = try self.initVm(0);
        defer vm.deinit();

        try vm.writeJsonValue(writer, value);
    }

    pub fn writeXmlValue(self: *Evaluator, writer: *std.Io.Writer, value: Value) !void {
        self.progressBegin(.render, "result");
        defer self.progressEnd(.render, "result");
        self.trace.clear();
        var vm = try self.initVm(0);
        defer vm.deinit();

        try vm.writeXmlValue(writer, value);
    }

    fn forceValue(self: *Evaluator, value: Value) !Value {
        self.trace.clear();
        var vm = try self.initVm(0);
        defer vm.deinit();

        return vm.forceValue(value);
    }

    pub fn forceDeep(self: *Evaluator, value: Value) !void {
        self.progressBegin(.render, "strict result");
        defer self.progressEnd(.render, "strict result");
        self.trace.clear();
        var vm = try self.initVm(0);
        defer vm.deinit();

        try vm.forceDeep(value);
    }

    fn importValue(context: *anyopaque, path: []const u8) anyerror!Value {
        const self: *Evaluator = @ptrCast(@alignCast(context));
        return self.importPath(path);
    }

    fn scopedImportValue(context: *anyopaque, scope: Value, path: []const u8) anyerror!Value {
        const self: *Evaluator = @ptrCast(@alignCast(context));
        return self.scopedImportPath(scope, path);
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
        if (std.mem.eql(u8, name, "nix/fetchurl.nix")) {
            return Value.path(try self.intern.intern("/__corepkgs__/fetchurl.nix"));
        }

        for (self.search_paths) |entry| {
            if (try self.searchPathCandidate(entry.path, entry.prefix, name)) |candidate| {
                defer self.allocator.free(candidate);
                return Value.path(try self.intern.intern(candidate));
            }
        }
        return error.FileNotFound;
    }

    fn searchPathCandidate(self: *Evaluator, base: []const u8, prefix: []const u8, name: []const u8) !?[]u8 {
        const suffix = path_ops.searchPathSuffix(prefix, name) orelse return null;
        const candidate = try std.fs.path.resolve(self.allocator, &.{ base, suffix });
        errdefer self.allocator.free(candidate);
        if (try self.files.pathExists(candidate)) return candidate;
        self.allocator.free(candidate);
        return null;
    }

    fn importPath(self: *Evaluator, path: []const u8) !Value {
        const resolved = try self.resolveHostPath(path);
        defer if (resolved.owned) self.allocator.free(resolved.text);
        return self.importResolvedPath(resolved.text);
    }

    fn importResolvedPath(self: *Evaluator, path: []const u8) anyerror!Value {
        const stable_path = try self.allocator.dupe(u8, path);
        defer self.allocator.free(stable_path);

        if (self.imports.get(stable_path)) |value| return value;
        self.progressBegin(.import, stable_path);
        defer self.progressEnd(.import, stable_path);

        const progress_key = try self.beginImport(stable_path);
        defer self.endImport(progress_key);

        const source = if (corepkgsSource(stable_path)) |core_source|
            core_source
        else
            self.files.readFile(stable_path) catch |err| switch (err) {
                error.IsDir => return self.importDirectory(stable_path),
                else => return err,
            };
        const source_base = std.fs.path.dirname(stable_path) orelse "/";
        const value = try self.evaluateSource(source, source_base, stable_path, null);
        try self.cacheImportValue(stable_path, value);
        return value;
    }

    fn scopedImportPath(self: *Evaluator, scope: Value, path: []const u8) !Value {
        const resolved = try self.resolveHostPath(path);
        defer if (resolved.owned) self.allocator.free(resolved.text);
        return self.scopedImportResolvedPath(scope, resolved.text);
    }

    fn scopedImportResolvedPath(self: *Evaluator, scope: Value, path: []const u8) anyerror!Value {
        const stable_path = try self.allocator.dupe(u8, path);
        defer self.allocator.free(stable_path);

        self.progressBegin(.import, stable_path);
        defer self.progressEnd(.import, stable_path);

        const progress_key = try self.beginImport(stable_path);
        defer self.endImport(progress_key);

        const source = if (corepkgsSource(stable_path)) |core_source|
            core_source
        else
            self.files.readFile(stable_path) catch |err| switch (err) {
                error.IsDir => return self.scopedImportDirectory(scope, stable_path),
                else => return err,
            };
        const source_base = std.fs.path.dirname(stable_path) orelse "/";
        return self.evaluateSource(source, source_base, stable_path, scope);
    }

    fn corepkgsSource(path: []const u8) ?[]const u8 {
        if (!std.mem.eql(u8, path, "/__corepkgs__/fetchurl.nix")) return null;
        return
        \\{
        \\  name ? baseNameOf url,
        \\  url,
        \\  hash ? "",
        \\  sha256 ? "",
        \\  executable ? false,
        \\  ...
        \\}:
        \\let
        \\  outputHash = if hash != "" then hash else sha256;
        \\in
        \\derivation {
        \\  inherit name url executable;
        \\  urls = [ url ];
        \\  builder = "builtin:fetchurl";
        \\  system = "builtin";
        \\  inherit outputHash;
        \\  outputHashAlgo = if hash != "" then null else "sha256";
        \\  outputHashMode = if executable then "recursive" else "flat";
        \\  preferLocalBuild = true;
        \\  impureEnvVars = [ "http_proxy" "https_proxy" "ftp_proxy" "all_proxy" "no_proxy" ];
        \\  unpack = false;
        \\}
        ;
    }

    fn importDirectory(self: *Evaluator, path: []const u8) anyerror!Value {
        const default_path = try std.fs.path.resolve(self.allocator, &.{ path, "default.nix" });
        defer self.allocator.free(default_path);

        const value = try self.importResolvedPath(default_path);
        try self.cacheImportValue(path, value);
        return value;
    }

    fn scopedImportDirectory(self: *Evaluator, scope: Value, path: []const u8) anyerror!Value {
        const default_path = try std.fs.path.resolve(self.allocator, &.{ path, "default.nix" });
        defer self.allocator.free(default_path);
        return self.scopedImportResolvedPath(scope, default_path);
    }

    fn cacheImportValue(self: *Evaluator, path: []const u8, value: Value) !void {
        if (self.imports.contains(path)) return;

        const key = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(key);
        try self.imports.put(self.allocator, key, value);
    }

    fn beginImport(self: *Evaluator, path: []const u8) ![]u8 {
        if (self.imports_in_progress.contains(path)) return error.ImportCycle;

        const key = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(key);
        try self.imports_in_progress.put(self.allocator, key, {});
        return key;
    }

    fn endImport(self: *Evaluator, key: []u8) void {
        _ = self.imports_in_progress.remove(key);
        self.allocator.free(key);
    }

    fn ensureBuiltins(self: *Evaluator) !Value {
        if (self.builtins_value) |value| return value;
        const nix_path = try self.allocator.alloc(builtins.NixPathEntry, self.search_paths.len);
        defer self.allocator.free(nix_path);
        for (self.search_paths, nix_path) |entry, *out| {
            out.* = .{ .prefix = entry.prefix, .path = entry.path };
        }

        const value = try builtins.buildAttrSet(&self.intern, &self.heap, nix_path);
        self.builtins_value = value;
        return value;
    }

    fn preserveCompileError(err: anyerror) bool {
        return switch (err) {
            error.DuplicateAttribute,
            error.DuplicateBinding,
            error.UndefinedVariable,
            => true,
            else => false,
        };
    }

    const ResolvedHostPath = struct {
        text: []const u8,
        owned: bool,
    };

    const SearchPathEntry = struct {
        prefix: []u8,
        path: []u8,

        fn deinit(self: SearchPathEntry, allocator: std.mem.Allocator) void {
            allocator.free(self.prefix);
            allocator.free(self.path);
        }
    };

    fn freeSearchPaths(self: *Evaluator) void {
        for (self.search_paths) |entry| entry.deinit(self.allocator);
        self.allocator.free(self.search_paths);
        self.search_paths = &.{};
    }

    fn resolveHostPath(self: *Evaluator, path: []const u8) !ResolvedHostPath {
        if (std.fs.path.isAbsolute(path)) return .{ .text = path, .owned = false };

        const base_path = self.base_path orelse return error.RelativePath;
        return .{
            .text = try std.fs.path.resolve(self.allocator, &.{ base_path, path }),
            .owned = true,
        };
    }

    pub fn writeValue(self: *Evaluator, writer: *std.Io.Writer, value: Value) !void {
        self.progressBegin(.render, "result");
        defer self.progressEnd(.render, "result");

        var printer = ValuePrinter{
            .ev = self,
            .writer = writer,
            .seen = .empty,
        };
        defer printer.seen.deinit(self.allocator);

        try printer.write(value);
    }

    fn writeQuotedString(self: *Evaluator, writer: *std.Io.Writer, s: []const u8) !void {
        _ = self;
        try writer.writeByte('"');
        for (s) |c| {
            switch (c) {
                '\\' => try writer.writeAll("\\\\"),
                '"' => try writer.writeAll("\\\""),
                '\n' => try writer.writeAll("\\n"),
                '\r' => try writer.writeAll("\\r"),
                '\t' => try writer.writeAll("\\t"),
                else => try writer.writeByte(c),
            }
        }
        try writer.writeByte('"');
    }

    fn progressBegin(self: *Evaluator, stage: eval_progress.Stage, subject: []const u8) void {
        if (self.progress) |progress| progress.begin(stage, subject);
    }

    fn progressEnd(self: *Evaluator, stage: eval_progress.Stage, subject: []const u8) void {
        if (self.progress) |progress| progress.end(stage, subject);
    }

    pub fn progressInstant(self: *Evaluator, stage: eval_progress.Stage, subject: []const u8) void {
        if (self.progress) |progress| progress.instant(stage, subject);
    }
};

const ValuePrinter = struct {
    ev: *Evaluator,
    writer: *std.Io.Writer,
    seen: std.ArrayListUnmanaged(SeenObject),

    const SeenKind = enum { list, attrs, thunk, cell };

    const SeenObject = struct {
        kind: SeenKind,
        id: types.ObjectId,
    };

    fn write(self: *ValuePrinter, value: Value) anyerror!void {
        switch (value.discriminant) {
            .null => try self.writer.writeAll("null"),
            .bool_false => try self.writer.writeAll("false"),
            .bool_true => try self.writer.writeAll("true"),
            .int => try self.writer.print("{}", .{value.asInt()}),
            .float => try self.writer.print("{d}", .{value.asFloat()}),
            .string => try self.ev.writeQuotedString(self.writer, self.ev.intern.get(value.asInternId())),
            .path => try self.writer.writeAll(self.ev.intern.get(value.asInternId())),
            .string_context => {
                const string = try self.ev.heap.getContextString(value.asObjectId());
                try self.ev.writeQuotedString(self.writer, self.ev.intern.get(string.text));
            },
            .list => try self.writeList(value.asObjectId()),
            .attrs => try self.writeAttrs(value.asObjectId()),
            .closure => try self.writer.writeAll("<closure>"),
            .thunk => try self.writeThunk(value.asObjectId()),
            .cell => try self.writeCell(value.asObjectId()),
            .builtin => try self.writer.writeAll("<builtin>"),
            .builtin_closure => try self.writer.writeAll("<builtin-closure>"),
        }
    }

    fn writeList(self: *ValuePrinter, id: types.ObjectId) !void {
        if (!try self.enter(.list, id)) {
            try self.writer.writeAll("...");
            return;
        }
        defer self.leave();

        const items = try self.ev.heap.getList(id);
        if (items.len == 0) {
            try self.writer.writeAll("[ ]");
            return;
        }

        try self.writer.writeAll("[ ");
        for (items, 0..) |item, i| {
            if (i > 0) try self.writer.writeByte(' ');
            try self.write(item);
        }
        try self.writer.writeAll(" ]");
    }

    fn writeAttrs(self: *ValuePrinter, id: types.ObjectId) !void {
        if (try self.derivationDrvPath(id)) |path| {
            try self.writer.writeAll(path);
            return;
        }

        if (!try self.enter(.attrs, id)) {
            try self.writer.writeAll("...");
            return;
        }
        defer self.leave();

        const entries = try self.ev.heap.getAttrs(id);
        if (entries.len == 0) {
            try self.writer.writeAll("{ }");
            return;
        }

        try self.writer.writeAll("{ ");
        for (entries) |entry| {
            try self.writeAttrName(self.ev.intern.get(entry.name));
            try self.writer.writeAll(" = ");
            try self.write(entry.value);
            try self.writer.writeAll("; ");
        }
        try self.writer.writeByte('}');
    }

    fn derivationDrvPath(self: *ValuePrinter, id: types.ObjectId) !?[]const u8 {
        const type_id = try self.ev.intern.intern("type");
        const type_value = self.ev.heap.getAttrValue(id, type_id) catch |err| switch (err) {
            error.MissingAttribute => return null,
            else => return err,
        };
        const forced_type = try self.ev.forceValue(type_value);
        if (forced_type.discriminant != .string) return null;
        if (!std.mem.eql(u8, self.ev.intern.get(forced_type.asInternId()), "derivation")) return null;

        const drv_path_id = try self.ev.intern.intern("drvPath");
        const drv_path = self.ev.heap.getAttrValue(id, drv_path_id) catch |err| switch (err) {
            error.MissingAttribute => return null,
            else => return err,
        };
        return try self.stringText(try self.ev.forceValue(drv_path));
    }

    fn stringText(self: *ValuePrinter, value: Value) ![]const u8 {
        return switch (value.discriminant) {
            .string, .path => self.ev.intern.get(value.asInternId()),
            .string_context => blk: {
                const string = try self.ev.heap.getContextString(value.asObjectId());
                break :blk self.ev.intern.get(string.text);
            },
            else => error.TypeError,
        };
    }

    fn writeThunk(self: *ValuePrinter, id: types.ObjectId) !void {
        if (!try self.enter(.thunk, id)) {
            try self.writer.writeAll("...");
            return;
        }
        defer self.leave();

        const thunk = try self.ev.heap.getThunk(id);
        const state: ThunkState = @enumFromInt(thunk.state.load(.acquire));
        if (state != .resolved) {
            try self.writer.writeAll("...");
            return;
        }

        try self.write(thunk.result);
    }

    fn writeCell(self: *ValuePrinter, id: types.ObjectId) !void {
        if (!try self.enter(.cell, id)) {
            try self.writer.writeAll("...");
            return;
        }
        defer self.leave();

        try self.write(try self.ev.heap.getCellValue(id));
    }

    fn writeAttrName(self: *ValuePrinter, name: []const u8) !void {
        if (isBareAttrName(name)) {
            try self.writer.writeAll(name);
        } else {
            try self.ev.writeQuotedString(self.writer, name);
        }
    }

    fn enter(self: *ValuePrinter, kind: SeenKind, id: types.ObjectId) !bool {
        for (self.seen.items) |seen| {
            if (seen.kind == kind and seen.id == id) return false;
        }
        try self.seen.append(self.ev.allocator, .{ .kind = kind, .id = id });
        return true;
    }

    fn leave(self: *ValuePrinter) void {
        _ = self.seen.pop();
    }

    fn isBareAttrName(name: []const u8) bool {
        if (name.len == 0) return false;
        if (!isAttrNameStart(name[0])) return false;
        for (name[1..]) |c| {
            if (!isAttrNameContinue(c)) return false;
        }
        return true;
    }

    fn isAttrNameStart(c: u8) bool {
        return std.ascii.isAlphabetic(c) or c == '_';
    }

    fn isAttrNameContinue(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '\'';
    }
};

fn renderForTest(source: []const u8) ![]u8 {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    const result = try ev.evaluate(source);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try ev.writeValue(&out.writer, result);
    return out.toOwnedSlice();
}

fn renderStrictForTest(source: []const u8) ![]u8 {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    const result = try ev.evaluate(source);
    try ev.forceDeep(result);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try ev.writeValue(&out.writer, result);
    return out.toOwnedSlice();
}

fn renderForTestFromCurrentPath(source: []const u8) ![]u8 {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    try ev.setBasePathFromCurrentPath(std.testing.io);

    const result = try ev.evaluate(source);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try ev.writeValue(&out.writer, result);
    return out.toOwnedSlice();
}

fn renderXmlForTest(source: []const u8) ![]u8 {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    const result = try ev.evaluate(source);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try ev.writeXmlValue(&out.writer, result);
    return out.toOwnedSlice();
}

test "writeValue prints lazy containers without forcing contents" {
    const list_output = try renderForTest("[ 1 (1 / 0) \"x\" ]");
    defer std.testing.allocator.free(list_output);
    try std.testing.expectEqualStrings("[ 1 ... \"x\" ]", list_output);

    const attrs_output = try renderForTest("{ a = 1; b = 1 / 0; c = \"x\"; }");
    defer std.testing.allocator.free(attrs_output);
    try std.testing.expectEqualStrings("{ a = 1; b = ...; c = \"x\"; }", attrs_output);
}

test "forceDeep recursively evaluates lazy containers" {
    const output = try renderStrictForTest("{ a = 1; b = [ 2 ]; c = \"x\"; }");
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("{ a = 1; b = [ 2 ]; c = \"x\"; }", output);

    try std.testing.expectError(error.DivisionByZero, renderStrictForTest("{ a = 1; b = 1 / 0; }"));
}

test "forceDeep handles recursive containers without hiding recursive thunks" {
    const repeated = try renderStrictForTest("let x = rec { a = x; }; in x");
    defer std.testing.allocator.free(repeated);
    try std.testing.expectEqualStrings("{ a = ...; }", repeated);

    try std.testing.expectError(error.RecursiveThunk, renderStrictForTest("rec { a = a; b = 1; }"));
}

test "writeValue prints recursive attrsets without looping" {
    const output = try renderForTest("rec { a = a; b = 1; }");
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("{ a = ...; b = 1; }", output);
}

test "writeValue prints derivations as drv paths" {
    const output = try renderForTest("builtins.derivation { name = \"pkg\"; system = \"x86_64-linux\"; builder = \"/bin/sh\"; }");
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("/nix/store/s8l8ca4j8fb6d94205514xd6wf9b57ng-pkg.drv", output);
}

test "writeXmlValue prints lazy containers without forcing contents" {
    const attrs_output = try renderXmlForTest("{ a = 1; b = 1 / 0; c = \"x\"; d = []; e = [ 1 ]; f = { x = 1; }; }");
    defer std.testing.allocator.free(attrs_output);
    try std.testing.expect(std.mem.indexOf(u8, attrs_output, "<attr name=\"a\">\n      <int value=\"1\" />") != null);
    try std.testing.expect(std.mem.indexOf(u8, attrs_output, "<attr name=\"b\">\n      <unevaluated />") != null);
    try std.testing.expect(std.mem.indexOf(u8, attrs_output, "<attr name=\"c\">\n      <string value=\"x\" />") != null);
    try std.testing.expect(std.mem.indexOf(u8, attrs_output, "<attr name=\"d\">\n      <list>") != null);
    try std.testing.expect(std.mem.indexOf(u8, attrs_output, "<attr name=\"e\">\n      <unevaluated />") != null);
    try std.testing.expect(std.mem.indexOf(u8, attrs_output, "<attr name=\"f\">\n      <unevaluated />") != null);
}

test "writeXmlValue prints resolved lazy children" {
    const output = try renderXmlForTest("let xs = [ 1 (1 / 0) ]; in builtins.seq (builtins.elemAt xs 0) xs");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "<int value=\"1\" />") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<unevaluated />") != null);
}

test "evaluate recursive dynamic attrsets" {
    const dynamic = try renderForTest("rec { a = 1; ${\"x\"} = a + 1; }.x");
    defer std.testing.allocator.free(dynamic);
    try std.testing.expectEqualStrings("2", dynamic);

    const dynamic_or_missing_prefix = try renderForTest("let switch = { kindFallback = \"ignore\"; }; kind = \"broken\"; in switch.kindSpecific.${kind} or switch.kindFallback");
    defer std.testing.allocator.free(dynamic_or_missing_prefix);
    try std.testing.expectEqualStrings("\"ignore\"", dynamic_or_missing_prefix);
}

test "evaluate matches Nix toString bool and null semantics" {
    const true_output = try renderForTest("builtins.toString true");
    defer std.testing.allocator.free(true_output);
    try std.testing.expectEqualStrings("\"1\"", true_output);

    const false_output = try renderForTest("builtins.toString false");
    defer std.testing.allocator.free(false_output);
    try std.testing.expectEqualStrings("\"\"", false_output);

    const null_output = try renderForTest("builtins.toString null");
    defer std.testing.allocator.free(null_output);
    try std.testing.expectEqualStrings("\"\"", null_output);
}

test "evaluate decodes common string escapes" {
    const output = try renderForTest("\"a\\nb\\t\\\"c\"");
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("\"a\\nb\\t\\\"c\"", output);
}

test "evaluate compares strings lexically" {
    const output = try renderForTest("let b = \"b\"; a = \"a\"; in b > a");
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("true", output);
}

test "evaluate checks attribute paths without forcing final value" {
    const present = try renderForTest("({ a.b = 1 / 0; } ? a.b)");
    defer std.testing.allocator.free(present);
    try std.testing.expectEqualStrings("true", present);

    const missing = try renderForTest("({ a = {}; } ? a.b)");
    defer std.testing.allocator.free(missing);
    try std.testing.expectEqualStrings("false", missing);
}

test "evaluate simple attrset function parameters" {
    const output = try renderForTest("({ x, y }: x + y) { x = 1; y = 2; }");
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("3", output);

    const lazy = try renderForTest("({ x }: 1) { x = 1 / 0; }");
    defer std.testing.allocator.free(lazy);
    try std.testing.expectEqualStrings("1", lazy);
}

test "evaluate attrset function defaults ellipsis and binding" {
    const defaulted = try renderForTest("({ x ? 2 }: x) { }");
    defer std.testing.allocator.free(defaulted);
    try std.testing.expectEqualStrings("2", defaulted);

    const extra = try renderForTest("({ x, ... }: x) { x = 1; y = 2; }");
    defer std.testing.allocator.free(extra);
    try std.testing.expectEqualStrings("1", extra);

    const bound_before = try renderForTest("(args@{ x }: args.x) { x = 3; }");
    defer std.testing.allocator.free(bound_before);
    try std.testing.expectEqualStrings("3", bound_before);

    const bound_after = try renderForTest("({ x }@args: args.x) { x = 4; }");
    defer std.testing.allocator.free(bound_after);
    try std.testing.expectEqualStrings("4", bound_after);

    const default_uses_bound_args = try renderForTest("({ a ? args.b or 1, ... }@args: a) { }");
    defer std.testing.allocator.free(default_uses_bound_args);
    try std.testing.expectEqualStrings("1", default_uses_bound_args);

    const trailing_comma = try renderForTest("({ a, b, }: a + b) { a = 1; b = 2; }");
    defer std.testing.allocator.free(trailing_comma);
    try std.testing.expectEqualStrings("3", trailing_comma);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    try std.testing.expectError(error.UnexpectedAttribute, ev.evaluate("({ x }: x) { x = 1; y = 2; }"));
}

test "evaluate small unary builtins" {
    const is_float = try renderForTest("builtins.isFloat 1.5");
    defer std.testing.allocator.free(is_float);
    try std.testing.expectEqualStrings("true", is_float);

    const is_function = try renderForTest("builtins.isFunction (x: x)");
    defer std.testing.allocator.free(is_function);
    try std.testing.expectEqualStrings("true", is_function);

    const is_path = try renderForTest("builtins.isPath ./foo");
    defer std.testing.allocator.free(is_path);
    try std.testing.expectEqualStrings("true", is_path);

    const length = try renderForTest("builtins.length [ 1 (1 / 0) 3 ]");
    defer std.testing.allocator.free(length);
    try std.testing.expectEqualStrings("3", length);

    const head = try renderForTest("builtins.head [ 4 5 ]");
    defer std.testing.allocator.free(head);
    try std.testing.expectEqualStrings("4", head);

    const names = try renderForTest("builtins.attrNames { b = 2; a = 1; }");
    defer std.testing.allocator.free(names);
    try std.testing.expectEqualStrings("[ \"a\" \"b\" ]", names);

    const values = try renderForTest("builtins.attrValues { b = 2; a = 1; }");
    defer std.testing.allocator.free(values);
    try std.testing.expectEqualStrings("[ 1 2 ]", values);
}

test "evaluate curried binary builtins" {
    const has_attr = try renderForTest("builtins.hasAttr \"a\" { a = 1; }");
    defer std.testing.allocator.free(has_attr);
    try std.testing.expectEqualStrings("true", has_attr);

    const missing_attr = try renderForTest("builtins.hasAttr \"b\" { a = 1; }");
    defer std.testing.allocator.free(missing_attr);
    try std.testing.expectEqualStrings("false", missing_attr);

    const get_attr = try renderForTest("builtins.getAttr \"a\" { a = 3; }");
    defer std.testing.allocator.free(get_attr);
    try std.testing.expectEqualStrings("3", get_attr);

    const elem_at = try renderForTest("builtins.elemAt [ 1 2 3 ] 1");
    defer std.testing.allocator.free(elem_at);
    try std.testing.expectEqualStrings("2", elem_at);

    const partial_is_function = try renderForTest("builtins.isFunction (builtins.elemAt [ 1 ])");
    defer std.testing.allocator.free(partial_is_function);
    try std.testing.expectEqualStrings("true", partial_is_function);
}

test "evaluate primitive arithmetic and bit builtins" {
    const add = try renderForTest("builtins.add 1 2.5");
    defer std.testing.allocator.free(add);
    try std.testing.expectEqualStrings("3.5", add);

    const div = try renderForTest("builtins.div (-7) 2");
    defer std.testing.allocator.free(div);
    try std.testing.expectEqualStrings("-3", div);

    const less_than = try renderForTest("builtins.lessThan \"a\" \"b\"");
    defer std.testing.allocator.free(less_than);
    try std.testing.expectEqualStrings("true", less_than);

    const bit_and = try renderForTest("builtins.bitAnd 6 3");
    defer std.testing.allocator.free(bit_and);
    try std.testing.expectEqualStrings("2", bit_and);

    const bit_or = try renderForTest("builtins.bitOr 4 1");
    defer std.testing.allocator.free(bit_or);
    try std.testing.expectEqualStrings("5", bit_or);

    const bit_xor = try renderForTest("builtins.bitXor 6 3");
    defer std.testing.allocator.free(bit_xor);
    try std.testing.expectEqualStrings("5", bit_xor);

    const floor = try renderForTest("builtins.floor (-1.2)");
    defer std.testing.allocator.free(floor);
    try std.testing.expectEqualStrings("-2", floor);

    const ceil = try renderForTest("builtins.ceil (-1.8)");
    defer std.testing.allocator.free(ceil);
    try std.testing.expectEqualStrings("-1", ceil);
}

test "evaluate primitive path and metadata builtins" {
    const interpolated_path = try renderForTest("builtins.toString (let name = \"root.zig\"; in ./src/${name})");
    defer std.testing.allocator.free(interpolated_path);
    try std.testing.expect(std.mem.endsWith(u8, interpolated_path, "/src/root.zig\""));

    const base = try renderForTest("builtins.baseNameOf /foo/bar");
    defer std.testing.allocator.free(base);
    try std.testing.expectEqualStrings("\"bar\"", base);

    const string_dir = try renderForTest("builtins.dirOf \"foo/bar\"");
    defer std.testing.allocator.free(string_dir);
    try std.testing.expectEqualStrings("\"foo\"", string_dir);

    const to_path_type = try renderForTest("builtins.typeOf (builtins.toPath /foo/bar)");
    defer std.testing.allocator.free(to_path_type);
    try std.testing.expectEqualStrings("\"string\"", to_path_type);

    const to_path_is_path = try renderForTest("builtins.isPath (builtins.toPath /foo/bar)");
    defer std.testing.allocator.free(to_path_is_path);
    try std.testing.expectEqualStrings("false", to_path_is_path);

    const path_dir = try renderForTest("builtins.dirOf /foo/bar");
    defer std.testing.allocator.free(path_dir);
    try std.testing.expectEqualStrings("/foo", path_dir);

    const true_value = try renderForTest("builtins.true");
    defer std.testing.allocator.free(true_value);
    try std.testing.expectEqualStrings("true", true_value);

    const false_value = try renderForTest("builtins.false");
    defer std.testing.allocator.free(false_value);
    try std.testing.expectEqualStrings("false", false_value);

    const null_value = try renderForTest("builtins.null");
    defer std.testing.allocator.free(null_value);
    try std.testing.expectEqualStrings("null", null_value);

    const lang_version = try renderForTest("builtins.langVersion");
    defer std.testing.allocator.free(lang_version);
    try std.testing.expectEqualStrings("6", lang_version);

    const store_dir = try renderForTest("builtins.storeDir");
    defer std.testing.allocator.free(store_dir);
    try std.testing.expectEqualStrings("\"/nix/store\"", store_dir);

    const nested_builtins = try renderForTest("builtins.builtins.storeDir");
    defer std.testing.allocator.free(nested_builtins);
    try std.testing.expectEqualStrings("\"/nix/store\"", nested_builtins);
}

test "evaluate builtins.typeOf" {
    const int_type = try renderForTest("builtins.typeOf 1");
    defer std.testing.allocator.free(int_type);
    try std.testing.expectEqualStrings("\"int\"", int_type);

    const set_type = try renderForTest("builtins.typeOf { }");
    defer std.testing.allocator.free(set_type);
    try std.testing.expectEqualStrings("\"set\"", set_type);

    const fn_type = try renderForTest("builtins.typeOf (x: x)");
    defer std.testing.allocator.free(fn_type);
    try std.testing.expectEqualStrings("\"lambda\"", fn_type);
}

test "evaluate concatLists and listToAttrs builtins" {
    const concat = try renderForTest("builtins.concatLists [ [ 1 ] [ (1 / 0) ] [ 3 ] ]");
    defer std.testing.allocator.free(concat);
    try std.testing.expectEqualStrings("[ 1 ... 3 ]", concat);

    const first_duplicate_wins = try renderForTest("(builtins.listToAttrs [ { name = \"a\"; value = 1; } { name = \"a\"; value = 2; } ]).a");
    defer std.testing.allocator.free(first_duplicate_wins);
    try std.testing.expectEqualStrings("1", first_duplicate_wins);

    const lazy_value = try renderForTest("(builtins.listToAttrs [ { name = \"a\"; value = 1 / 0; } ]) ? a");
    defer std.testing.allocator.free(lazy_value);
    try std.testing.expectEqualStrings("true", lazy_value);
}

test "evaluate removeAttrs and intersectAttrs builtins" {
    const removed = try renderForTest("(builtins.removeAttrs { a = 1; b = 2; } [ \"a\" ]).b");
    defer std.testing.allocator.free(removed);
    try std.testing.expectEqualStrings("2", removed);

    const removed_missing = try renderForTest("(builtins.removeAttrs { a = 1; b = 2; } [ \"a\" ]) ? a");
    defer std.testing.allocator.free(removed_missing);
    try std.testing.expectEqualStrings("false", removed_missing);

    const remove_lazy = try renderForTest("(builtins.removeAttrs { a = 1 / 0; b = 2; } [ \"b\" ]) ? a");
    defer std.testing.allocator.free(remove_lazy);
    try std.testing.expectEqualStrings("true", remove_lazy);

    const intersect = try renderForTest("(builtins.intersectAttrs { a = 1; } { a = 2; b = 3; }).a");
    defer std.testing.allocator.free(intersect);
    try std.testing.expectEqualStrings("2", intersect);

    const intersect_lazy = try renderForTest("(builtins.intersectAttrs { a = 1; } { a = 1 / 0; b = 2; }) ? a");
    defer std.testing.allocator.free(intersect_lazy);
    try std.testing.expectEqualStrings("true", intersect_lazy);
}

test "evaluate elem builtin" {
    const present = try renderForTest("builtins.elem 2 [ 1 2 3 ]");
    defer std.testing.allocator.free(present);
    try std.testing.expectEqualStrings("true", present);

    const missing = try renderForTest("builtins.elem 4 [ 1 2 3 ]");
    defer std.testing.allocator.free(missing);
    try std.testing.expectEqualStrings("false", missing);

    const short_circuit = try renderForTest("builtins.elem 1 [ 1 (1 / 0) ]");
    defer std.testing.allocator.free(short_circuit);
    try std.testing.expectEqualStrings("true", short_circuit);
}

test "evaluate seq builtin" {
    const value = try renderForTest("builtins.seq 1 2");
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("2", value);

    const list_whnf = try renderForTest("builtins.seq [ (1 / 0) ] 2");
    defer std.testing.allocator.free(list_whnf);
    try std.testing.expectEqualStrings("2", list_whnf);

    const unused = try renderForTest("let x = builtins.seq (1 / 0) 2; in 3");
    defer std.testing.allocator.free(unused);
    try std.testing.expectEqualStrings("3", unused);
}

test "evaluate deepSeq builtin" {
    const attrs = try renderForTest("builtins.deepSeq { a = 1; b = [ 2 ]; } 3");
    defer std.testing.allocator.free(attrs);
    try std.testing.expectEqualStrings("3", attrs);

    const unused = try renderForTest("let x = builtins.deepSeq [ (1 / 0) ] 2; in 3");
    defer std.testing.allocator.free(unused);
    try std.testing.expectEqualStrings("3", unused);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    try std.testing.expectError(error.DivisionByZero, ev.evaluate("builtins.deepSeq [ (1 / 0) ] 2"));
}

test "evaluate pathExists and readFile builtins through file cache" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "input.txt", .data = "abc\n" });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const file_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "input.txt",
    });
    defer std.testing.allocator.free(file_path);

    const exists_source = try std.fmt.allocPrint(std.testing.allocator, "builtins.pathExists \"{s}\"", .{file_path});
    defer std.testing.allocator.free(exists_source);
    const read_source = try std.fmt.allocPrint(std.testing.allocator, "builtins.readFile \"{s}\"", .{file_path});
    defer std.testing.allocator.free(read_source);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    const exists = try ev.evaluate(exists_source);
    try std.testing.expect(exists.asBool());

    const contents = try ev.evaluate(read_source);
    try std.testing.expectEqualStrings("abc\n", ev.intern.get(contents.asInternId()));

    const reread = try ev.evaluate(read_source);
    try std.testing.expectEqual(contents.asInternId(), reread.asInternId());
}

test "read source files through evaluator file cache" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "source.nix", .data = "1 + 2\n" });

    const relative_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/source.nix", .{tmp.sub_path});
    defer std.testing.allocator.free(relative_path);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    try ev.setBasePathFromCurrentPath(std.testing.io);

    const source = try ev.readSourceFile(relative_path);
    try std.testing.expectEqualStrings("1 + 2\n", source);

    const cached_source = try ev.readSourceFile(relative_path);
    try std.testing.expectEqual(@intFromPtr(source.ptr), @intFromPtr(cached_source.ptr));
}

test "evaluate readDir builtin through file cache" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "file.txt", .data = "x" });
    try tmp.dir.createDir(std.testing.io, "sub", .default_dir);

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const dir_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
    });
    defer std.testing.allocator.free(dir_path);

    const file_source = try std.fmt.allocPrint(std.testing.allocator, "builtins.getAttr \"file.txt\" (builtins.readDir {s})", .{dir_path});
    defer std.testing.allocator.free(file_source);
    const dir_source = try std.fmt.allocPrint(std.testing.allocator, "(builtins.readDir {s}).sub", .{dir_path});
    defer std.testing.allocator.free(dir_source);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    const file_kind = try ev.evaluate(file_source);
    try std.testing.expectEqualStrings("regular", ev.intern.get(file_kind.asInternId()));

    const dir_kind = try ev.evaluate(dir_source);
    try std.testing.expectEqualStrings("directory", ev.intern.get(dir_kind.asInternId()));
}

test "evaluate readFileType builtin through file cache" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "file.txt", .data = "x" });
    try tmp.dir.createDir(std.testing.io, "sub", .default_dir);

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const base_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
    });
    defer std.testing.allocator.free(base_path);

    const file_path = try std.fs.path.resolve(std.testing.allocator, &.{ base_path, "file.txt" });
    defer std.testing.allocator.free(file_path);
    const dir_path = try std.fs.path.resolve(std.testing.allocator, &.{ base_path, "sub" });
    defer std.testing.allocator.free(dir_path);

    const file_source = try std.fmt.allocPrint(std.testing.allocator, "builtins.readFileType {s}", .{file_path});
    defer std.testing.allocator.free(file_source);
    const dir_source = try std.fmt.allocPrint(std.testing.allocator, "builtins.readFileType {s}", .{dir_path});
    defer std.testing.allocator.free(dir_source);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    const file_kind = try ev.evaluate(file_source);
    try std.testing.expectEqualStrings("regular", ev.intern.get(file_kind.asInternId()));

    const dir_kind = try ev.evaluate(dir_source);
    try std.testing.expectEqualStrings("directory", ev.intern.get(dir_kind.asInternId()));
}

test "evaluate filterSource builtin through file cache" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "keep.txt", .data = "x" });
    try tmp.dir.createDir(std.testing.io, "keepdir", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "keepdir/nested.txt", .data = "x" });
    try tmp.dir.createDir(std.testing.io, "skip", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "skip/boom.txt", .data = "x" });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const dir_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
    });
    defer std.testing.allocator.free(dir_path);

    const source = try std.fmt.allocPrint(
        std.testing.allocator,
        \\builtins.filterSource
        \\  (path: type:
        \\    if builtins.baseNameOf path == "boom.txt"
        \\    then builtins.throw "descended into rejected directory"
        \\    else builtins.baseNameOf path != "skip")
        \\  {s}
    ,
        .{dir_path},
    );
    defer std.testing.allocator.free(source);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    const filtered = try ev.evaluate(source);
    try std.testing.expectEqual(.string, filtered.discriminant);
    try std.testing.expect(std.mem.startsWith(u8, ev.intern.get(filtered.asInternId()), "/nix/store/"));
    try std.testing.expect(std.mem.endsWith(u8, ev.intern.get(filtered.asInternId()), &tmp.sub_path));

    const called_source = try std.fmt.allocPrint(
        std.testing.allocator,
        \\builtins.filterSource
        \\  (path: type:
        \\    if builtins.baseNameOf path == "keep.txt"
        \\    then builtins.throw "predicate called"
        \\    else true)
        \\  {s}
    ,
        .{dir_path},
    );
    defer std.testing.allocator.free(called_source);
    try std.testing.expectError(error.NixThrow, ev.evaluate(called_source));
}

test "evaluate fetchGit builtin for local repository" {
    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);

    const out_path_source = try std.fmt.allocPrint(std.testing.allocator, "(builtins.fetchGit {{ url = \"{s}\"; }}).outPath", .{cwd});
    defer std.testing.allocator.free(out_path_source);
    const short_rev_source = try std.fmt.allocPrint(std.testing.allocator, "builtins.stringLength (builtins.fetchGit {{ url = \"{s}\"; }}).shortRev", .{cwd});
    defer std.testing.allocator.free(short_rev_source);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    const out_path = try ev.evaluate(out_path_source);
    try std.testing.expectEqualStrings(cwd, ev.intern.get(out_path.asInternId()));

    const short_rev_len = try ev.evaluate(short_rev_source);
    try std.testing.expectEqual(@as(i64, 7), short_rev_len.asInt());
}

test "evaluate fetchurl builtin through fetch cache" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "payload.txt", .data = "payload" });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const file_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "payload.txt",
    });
    defer std.testing.allocator.free(file_path);

    const source = try std.fmt.allocPrint(std.testing.allocator, "builtins.readFile (builtins.fetchurl {{ url = \"file://{s}\"; name = \"payload.txt\"; }})", .{file_path});
    defer std.testing.allocator.free(source);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    const contents = try ev.evaluate(source);
    try std.testing.expectEqualStrings("payload", ev.intern.get(contents.asInternId()));
}

test "evaluate fetchTarball builtin through fetch cache" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "archive-root", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "archive-root/file.txt", .data = "payload" });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const base_path = try std.fs.path.resolve(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(base_path);
    const archive_path = try std.fs.path.resolve(std.testing.allocator, &.{ base_path, "archive.tar.gz" });
    defer std.testing.allocator.free(archive_path);

    const tar = try std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ "tar", "-czf", archive_path, "-C", base_path, "archive-root" },
    });
    defer std.testing.allocator.free(tar.stdout);
    defer std.testing.allocator.free(tar.stderr);
    switch (tar.term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedTarFailure,
    }

    const source = try std.fmt.allocPrint(std.testing.allocator, "builtins.readFile ((builtins.fetchTarball {{ url = \"file://{s}\"; name = \"src\"; }}) + \"/file.txt\")", .{archive_path});
    defer std.testing.allocator.free(source);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    const contents = try ev.evaluate(source);
    try std.testing.expectEqualStrings("payload", ev.intern.get(contents.asInternId()));
}

test "evaluate fetchTree builtin through fetch cache" {
    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "payload.txt", .data = "payload" });

    const file_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "payload.txt",
    });
    defer std.testing.allocator.free(file_path);

    const path_source = try std.fmt.allocPrint(std.testing.allocator, "(builtins.fetchTree {{ type = \"path\"; path = \"{s}\"; }}).outPath", .{cwd});
    defer std.testing.allocator.free(path_source);
    const file_source = try std.fmt.allocPrint(std.testing.allocator, "builtins.readFile (builtins.fetchTree {{ type = \"file\"; url = \"file://{s}\"; }}).outPath", .{file_path});
    defer std.testing.allocator.free(file_source);
    const git_source = try std.fmt.allocPrint(std.testing.allocator, "builtins.stringLength (builtins.fetchTree {{ type = \"git\"; url = \"{s}\"; }}).shortRev", .{cwd});
    defer std.testing.allocator.free(git_source);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    const out_path = try ev.evaluate(path_source);
    try std.testing.expectEqualStrings(cwd, ev.intern.get(out_path.asInternId()));

    const contents = try ev.evaluate(file_source);
    try std.testing.expectEqualStrings("payload", ev.intern.get(contents.asInternId()));

    const short_rev_len = try ev.evaluate(git_source);
    try std.testing.expectEqual(@as(i64, 7), short_rev_len.asInt());
}

test "evaluate flake ref builtins" {
    const github = try renderForTest("builtins.toJSON (builtins.parseFlakeRef \"github:NixOS/nixpkgs/nixos-unstable\")");
    defer std.testing.allocator.free(github);
    try std.testing.expectEqualStrings("\"{\\\"owner\\\":\\\"NixOS\\\",\\\"ref\\\":\\\"nixos-unstable\\\",\\\"repo\\\":\\\"nixpkgs\\\",\\\"type\\\":\\\"github\\\"}\"", github);

    const path = try renderForTest("builtins.toJSON (builtins.parseFlakeRef \"path:/tmp/source?rev=abc&narHash=sha256-test\")");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("\"{\\\"narHash\\\":\\\"sha256-test\\\",\\\"path\\\":\\\"/tmp/source\\\",\\\"rev\\\":\\\"abc\\\",\\\"type\\\":\\\"path\\\"}\"", path);

    const stringified = try renderForTest("builtins.flakeRefToString { type = \"github\"; owner = \"NixOS\"; repo = \"nixpkgs\"; ref = \"nixos-unstable\"; }");
    defer std.testing.allocator.free(stringified);
    try std.testing.expectEqualStrings("\"github:NixOS/nixpkgs/nixos-unstable\"", stringified);
}

test "evaluate getFlake builtin for local path ref" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "flake.nix",
        .data =
        \\{
        \\  outputs = inputs: {
        \\    value = 7;
        \\    source = inputs.self.outPath;
        \\  };
        \\}
        ,
    });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const flake_dir = try std.fs.path.resolve(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(flake_dir);

    const value_source = try std.fmt.allocPrint(std.testing.allocator, "(builtins.getFlake \"path:{s}\").value", .{flake_dir});
    defer std.testing.allocator.free(value_source);
    const output_source = try std.fmt.allocPrint(std.testing.allocator, "(builtins.getFlake \"path:{s}\").outputs.value", .{flake_dir});
    defer std.testing.allocator.free(output_source);
    const self_source = try std.fmt.allocPrint(std.testing.allocator, "(builtins.getFlake \"path:{s}\").source", .{flake_dir});
    defer std.testing.allocator.free(self_source);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    try std.testing.expectEqual(@as(i64, 7), (try ev.evaluate(value_source)).asInt());
    try std.testing.expectEqual(@as(i64, 7), (try ev.evaluate(output_source)).asInt());
    const self_path = try ev.evaluate(self_source);
    try std.testing.expectEqualStrings(flake_dir, ev.intern.get(self_path.asInternId()));
}

test "evaluate findFile builtin through explicit search path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "target.nix", .data = "1" });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const base_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
    });
    defer std.testing.allocator.free(base_path);
    const expected_path = try std.fs.path.resolve(std.testing.allocator, &.{ base_path, "target.nix" });
    defer std.testing.allocator.free(expected_path);

    const source = try std.fmt.allocPrint(std.testing.allocator, "builtins.findFile [ {{ prefix = \"pkg\"; path = {s}; }} ] \"pkg/target.nix\"", .{base_path});
    defer std.testing.allocator.free(source);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    const found = try ev.evaluate(source);
    try std.testing.expectEqualStrings(expected_path, ev.intern.get(found.asInternId()));
}

test "evaluate angle search path literals through cached nix path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "target.nix", .data = "{ value = 5; }" });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const base_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
    });
    defer std.testing.allocator.free(base_path);

    const nix_path = try std.fmt.allocPrint(std.testing.allocator, "pkg={s}", .{base_path});
    defer std.testing.allocator.free(nix_path);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    ev.setFileIo(std.testing.io);
    try ev.setNixPath(nix_path);

    const imported = try ev.evaluate("(import <pkg/target.nix>).value");
    try std.testing.expectEqual(@as(i64, 5), imported.asInt());
}

test "evaluate import through evaluator file cache" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "imported.nix", .data = "{ value = 42; }\n" });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const file_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "imported.nix",
    });
    defer std.testing.allocator.free(file_path);

    const source = try std.fmt.allocPrint(std.testing.allocator, "let a = import {s}; b = import {s}; in a.value + b.value", .{ file_path, file_path });
    defer std.testing.allocator.free(source);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    const imported = try ev.evaluate(source);
    try std.testing.expectEqual(@as(i64, 84), imported.asInt());
    try std.testing.expectEqual(@as(u32, 1), ev.imports.count());
}

test "evaluate path builtins coerce outPath attrsets" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "imported.nix", .data = "{ value = 21; }\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "payload.txt", .data = "payload" });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const imported_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "imported.nix",
    });
    defer std.testing.allocator.free(imported_path);
    const payload_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "payload.txt",
    });
    defer std.testing.allocator.free(payload_path);

    const source = try std.fmt.allocPrint(std.testing.allocator,
        \\let
        \\  imported = (import {{ outPath = "{s}"; }}).value;
        \\  contents = builtins.readFile {{ outPath = "{s}"; }};
        \\in imported + builtins.stringLength contents
    , .{ imported_path, payload_path });
    defer std.testing.allocator.free(source);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    const result = try ev.evaluate(source);
    try std.testing.expectEqual(@as(i64, 28), result.asInt());
}

test "evaluate directory import through default nix" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "pkg", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "pkg/default.nix", .data = "{ value = 9; }\n" });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const dir_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "pkg",
    });
    defer std.testing.allocator.free(dir_path);

    const source = try std.fmt.allocPrint(std.testing.allocator, "(import {s}).value", .{dir_path});
    defer std.testing.allocator.free(source);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    const imported = try ev.evaluate(source);
    try std.testing.expectEqual(@as(i64, 9), imported.asInt());
}

test "evaluate scopedImport through ambient scope" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "scope.nix", .data = "x + y\n" });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const file_path = try std.fs.path.resolve(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "scope.nix" });
    defer std.testing.allocator.free(file_path);

    const source = try std.fmt.allocPrint(std.testing.allocator, "builtins.scopedImport {{ x = 1; y = 2; }} {s}", .{file_path});
    defer std.testing.allocator.free(source);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    const imported = try ev.evaluate(source);
    try std.testing.expectEqual(@as(i64, 3), imported.asInt());
}

test "detect recursive imports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "cycle.nix", .data = "import ./cycle.nix\n" });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const file_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "cycle.nix",
    });
    defer std.testing.allocator.free(file_path);

    const source = try std.fmt.allocPrint(std.testing.allocator, "import {s}", .{file_path});
    defer std.testing.allocator.free(source);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    try std.testing.expectError(error.ImportCycle, ev.evaluate(source));
}

test "evaluate all and any builtins" {
    const all_true = try renderForTest("builtins.all (x: x < 3) [ 1 2 ]");
    defer std.testing.allocator.free(all_true);
    try std.testing.expectEqualStrings("true", all_true);

    const all_short_circuit = try renderForTest("builtins.all (x: x < 3) [ 1 4 (1 / 0) ]");
    defer std.testing.allocator.free(all_short_circuit);
    try std.testing.expectEqualStrings("false", all_short_circuit);

    const any_short_circuit = try renderForTest("builtins.any (x: x == 2) [ 1 2 (1 / 0) ]");
    defer std.testing.allocator.free(any_short_circuit);
    try std.testing.expectEqualStrings("true", any_short_circuit);

    const any_false = try renderForTest("builtins.any (x: x == 2) [ 1 3 ]");
    defer std.testing.allocator.free(any_false);
    try std.testing.expectEqualStrings("false", any_false);
}

test "evaluate filter builtin" {
    const filtered = try renderForTest("builtins.filter (x: x < 3) [ 1 4 2 ]");
    defer std.testing.allocator.free(filtered);
    try std.testing.expectEqualStrings("[ 1 2 ]", filtered);

    const length_lazy = try renderForTest("builtins.length (builtins.filter (x: true) [ (1 / 0) ])");
    defer std.testing.allocator.free(length_lazy);
    try std.testing.expectEqualStrings("1", length_lazy);

    const reject_lazy = try renderForTest("builtins.filter (x: false) [ (1 / 0) ]");
    defer std.testing.allocator.free(reject_lazy);
    try std.testing.expectEqualStrings("[ ]", reject_lazy);
}

test "evaluate map concatMap mapAttrs and genList builtins" {
    const mapped = try renderForTest("builtins.toJSON (builtins.map (x: x + 1) [ 1 2 3 ])");
    defer std.testing.allocator.free(mapped);
    try std.testing.expectEqualStrings("\"[2,3,4]\"", mapped);

    const map_lazy_length = try renderForTest("builtins.length (builtins.map (x: builtins.throw \"bad\") [ 1 ])");
    defer std.testing.allocator.free(map_lazy_length);
    try std.testing.expectEqualStrings("1", map_lazy_length);

    const concat_mapped = try renderForTest("builtins.elemAt (builtins.concatMap (x: [ x (x + 10) ]) [ 1 2 ]) 1");
    defer std.testing.allocator.free(concat_mapped);
    try std.testing.expectEqualStrings("11", concat_mapped);

    const mapped_attrs = try renderForTest("(builtins.mapAttrs (name: value: value + 1) { a = 1; b = 2; }).b");
    defer std.testing.allocator.free(mapped_attrs);
    try std.testing.expectEqualStrings("3", mapped_attrs);

    const map_attrs_lazy_select = try renderForTest("(builtins.mapAttrs (name: value: if name == \"a\" then value else builtins.throw \"bad\") { a = 1; b = 2; }).a");
    defer std.testing.allocator.free(map_attrs_lazy_select);
    try std.testing.expectEqualStrings("1", map_attrs_lazy_select);

    const map_attrs_lazy_has_attr = try renderForTest("(builtins.mapAttrs (name: value: builtins.throw \"bad\") { a = 1; }) ? a");
    defer std.testing.allocator.free(map_attrs_lazy_has_attr);
    try std.testing.expectEqualStrings("true", map_attrs_lazy_has_attr);

    const map_attrs_fixed_point = try renderForTest("let fix = f: let x = f x; in x; in builtins.attrNames (fix (self: let y = builtins.mapAttrs self.f { a = 1; }; in { f = n: v: v; } // y))");
    defer std.testing.allocator.free(map_attrs_fixed_point);
    try std.testing.expectEqualStrings("[ \"a\" \"f\" ]", map_attrs_fixed_point);

    const generated = try renderForTest("builtins.genList (x: x + 1) 3");
    defer std.testing.allocator.free(generated);
    try std.testing.expectEqualStrings("[ ... ... ... ]", generated);

    const generated_forced = try renderForTest("builtins.elemAt (builtins.genList (x: x + 1) 3) 2");
    defer std.testing.allocator.free(generated_forced);
    try std.testing.expectEqualStrings("3", generated_forced);
}

test "evaluate string builtins" {
    const length = try renderForTest("builtins.stringLength \"abcd\"");
    defer std.testing.allocator.free(length);
    try std.testing.expectEqualStrings("4", length);

    const out_path_length = try renderForTest("builtins.stringLength { outPath = \"/x\"; }");
    defer std.testing.allocator.free(out_path_length);
    try std.testing.expectEqualStrings("2", out_path_length);

    try std.testing.expectError(error.TypeError, renderForTest("builtins.stringLength 1"));

    const joined = try renderForTest("builtins.concatStringsSep \",\" [ \"a\" \"b\" \"c\" ]");
    defer std.testing.allocator.free(joined);
    try std.testing.expectEqualStrings("\"a,b,c\"", joined);

    const joined_path = try renderForTest("builtins.concatStringsSep \",\" [ ./src/root.zig { outPath = \"/nix/store/example\"; } ]");
    defer std.testing.allocator.free(joined_path);
    try std.testing.expect(std.mem.indexOf(u8, joined_path, "/nix/store/example") != null);

    try std.testing.expectError(error.TypeError, renderForTest("builtins.concatStringsSep \",\" [ 1 ]"));

    const substring = try renderForTest("builtins.substring 1 2 \"abcd\"");
    defer std.testing.allocator.free(substring);
    try std.testing.expectEqualStrings("\"bc\"", substring);

    const substring_to_end = try renderForTest("builtins.substring 1 (-1) \"abcd\"");
    defer std.testing.allocator.free(substring_to_end);
    try std.testing.expectEqualStrings("\"bcd\"", substring_to_end);

    try std.testing.expectError(error.TypeError, renderForTest("builtins.substring (-1) 2 \"abcd\""));

    const out_path_substring = try renderForTest("builtins.substring 0 1 { outPath = \"/x\"; }");
    defer std.testing.allocator.free(out_path_substring);
    try std.testing.expectEqualStrings("\"/\"", out_path_substring);

    const replaced = try renderForTest("builtins.replaceStrings [ \"ab\" \"d\" ] [ \"X\" \"Y\" ] \"abcd\"");
    defer std.testing.allocator.free(replaced);
    try std.testing.expectEqualStrings("\"XcY\"", replaced);

    const to_file = try renderForTest("builtins.toFile \"x\" \"hello\"");
    defer std.testing.allocator.free(to_file);
    try std.testing.expectEqualStrings("\"/nix/store/4g4g9i669dl63abpww0djbl2jxl6bwiz-x\"", to_file);

    try std.testing.expectError(error.InvalidStorePathName, renderForTest("builtins.toFile \"x y\" \"hello\""));
    try std.testing.expectError(
        error.DerivationReferenceInToFile,
        renderForTest(
            \\let d = builtins.derivation { name = "dep"; system = "x86_64-linux"; builder = "/bin/sh"; };
            \\in builtins.toFile "x" "${d}"
        ),
    );
}

test "evaluate hash builtins" {
    const hash_string = try renderForTest("builtins.hashString \"sha256\" \"abc\"");
    defer std.testing.allocator.free(hash_string);
    try std.testing.expectEqualStrings("\"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\"", hash_string);

    const placeholder_out = try renderForTest("builtins.placeholder \"out\"");
    defer std.testing.allocator.free(placeholder_out);
    try std.testing.expectEqualStrings("\"/1rz4g4znpzjwh1xymhjpm42vipw92pr73vdgl6xs1hycac8kf2n9\"", placeholder_out);

    const placeholder_dev = try renderForTest("builtins.placeholder \"dev\"");
    defer std.testing.allocator.free(placeholder_dev);
    try std.testing.expectEqualStrings("\"/02qcpld1y6xhs5gz9bchpxaw0xdhmsp5dv88lh25r2ss44kh8dxz\"", placeholder_dev);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "input.txt", .data = "abc" });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const file_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "input.txt",
    });
    defer std.testing.allocator.free(file_path);

    const source = try std.fmt.allocPrint(std.testing.allocator, "builtins.hashFile \"sha1\" {s}", .{file_path});
    defer std.testing.allocator.free(source);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    const hash_file = try ev.evaluate(source);
    try std.testing.expectEqualStrings("a9993e364706816aba3e25717850c26c9cd0d89d", ev.intern.get(hash_file.asInternId()));
}

test "evaluate JSON builtins" {
    const json = try renderForTest("builtins.toJSON { b = [ 2 false ]; a = \"x\"; }");
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings("\"{\\\"a\\\":\\\"x\\\",\\\"b\\\":[2,false]}\"", json);

    const json_forces_values = try renderForTest("builtins.toJSON { a = 1; }");
    defer std.testing.allocator.free(json_forces_values);
    try std.testing.expectEqualStrings("\"{\\\"a\\\":1}\"", json_forces_values);

    const parsed_attr = try renderForTest("(builtins.fromJSON \"{\\\"b\\\":2,\\\"a\\\":[1,true,null]}\").a");
    defer std.testing.allocator.free(parsed_attr);
    try std.testing.expectEqualStrings("[ 1 true null ]", parsed_attr);

    const parsed_float_type = try renderForTest("builtins.typeOf (builtins.fromJSON \"1.5\")");
    defer std.testing.allocator.free(parsed_float_type);
    try std.testing.expectEqualStrings("\"float\"", parsed_float_type);

    const out_path_json = try renderForTest("builtins.toJSON { outPath = \"/nix/store/example\"; a = 1; }");
    defer std.testing.allocator.free(out_path_json);
    try std.testing.expectEqualStrings("\"\\\"/nix/store/example\\\"\"", out_path_json);

    const to_string_json = try renderForTest("builtins.toJSON { __toString = self: self.name; name = \"pkg\"; }");
    defer std.testing.allocator.free(to_string_json);
    try std.testing.expectEqualStrings("\"\\\"pkg\\\"\"", to_string_json);
}

test "evaluate XML builtin" {
    const xml = try renderForTest("builtins.toXML { b = [ true \"x\" null ]; a = 1; }");
    defer std.testing.allocator.free(xml);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<?xml version='1.0' encoding='utf-8'?>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<attr name=\\\"a\\\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<bool value=\\\"true\\\" />") != null);

    const escaped = try renderForTest("builtins.toXML \"a<&\\\"b\"");
    defer std.testing.allocator.free(escaped);
    try std.testing.expect(std.mem.indexOf(u8, escaped, "a&lt;&amp;&quot;b") != null);
}

test "evaluate TOML builtin" {
    const parsed = try renderForTest(
        \\builtins.toJSON (let value = builtins.fromTOML ''
        \\  title = "demo"
        \\  enabled = true
        \\  count = 0x10
        \\  ratio = 1.5
        \\  tags = [ "a", "b" ]
        \\  [package]
        \\  name = "pkg"
        \\  meta.license = { text = "MIT" }
        \\''; in [ value.title value.enabled value.count value.ratio value.tags value.package.name value.package.meta.license.text ])
    );
    defer std.testing.allocator.free(parsed);
    try std.testing.expectEqualStrings("\"[\\\"demo\\\",true,16,1.5,[\\\"a\\\",\\\"b\\\"],\\\"pkg\\\",\\\"MIT\\\"]\"", parsed);

    const array_table = try renderForTest(
        \\let value = builtins.fromTOML ''
        \\  [[products]]
        \\  name = "hammer"
        \\  [[products]]
        \\  name = "nail"
        \\''; in builtins.toJSON (builtins.map (p: p.name) value.products)
    );
    defer std.testing.allocator.free(array_table);
    try std.testing.expectEqualStrings("\"[\\\"hammer\\\",\\\"nail\\\"]\"", array_table);
}

test "evaluate version parsing builtins" {
    const split = try renderForTest("builtins.splitVersion \"1.0-beta2\"");
    defer std.testing.allocator.free(split);
    try std.testing.expectEqualStrings("[ \"1\" \"0\" \"beta\" \"2\" ]", split);

    const equal = try renderForTest("builtins.compareVersions \"1.02\" \"1.2\"");
    defer std.testing.allocator.free(equal);
    try std.testing.expectEqualStrings("0", equal);

    const pre = try renderForTest("builtins.compareVersions \"1.0pre\" \"1.0\"");
    defer std.testing.allocator.free(pre);
    try std.testing.expectEqualStrings("-1", pre);

    const drv = try renderForTest("(builtins.parseDrvName \"foo-bar-1.2pre3\").version");
    defer std.testing.allocator.free(drv);
    try std.testing.expectEqualStrings("\"1.2pre3\"", drv);
}

test "evaluate regex builtins" {
    const matched = try renderForTest("builtins.match \"(.*)e?abi.*\" \"gnueabihf\"");
    defer std.testing.allocator.free(matched);
    try std.testing.expectEqualStrings("[ \"gnue\" ]", matched);

    const unmatched = try renderForTest("builtins.match \"[[:digit:]]+\" \"abc\"");
    defer std.testing.allocator.free(unmatched);
    try std.testing.expectEqualStrings("null", unmatched);

    const split = try renderForTest("builtins.split \"[^[:alnum:]+._?=-]+\" \"abc///def\"");
    defer std.testing.allocator.free(split);
    try std.testing.expectEqualStrings("[ \"abc\" [ ] \"def\" ]", split);
}

test "evaluate control and error builtins" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    try std.testing.expectError(error.NixThrow, ev.evaluate("builtins.throw \"nope\""));
    try std.testing.expectError(error.NixAbort, ev.evaluate("builtins.abort \"nope\""));

    const try_success = try renderForTest("(builtins.tryEval (1 + 2)).success");
    defer std.testing.allocator.free(try_success);
    try std.testing.expectEqualStrings("true", try_success);

    const try_value = try renderForTest("(builtins.tryEval (builtins.throw \"nope\")).value");
    defer std.testing.allocator.free(try_value);
    try std.testing.expectEqualStrings("false", try_value);

    const try_attr_select = try renderForTest("(builtins.tryEval ((builtins.throw \"nope\").a)).success");
    defer std.testing.allocator.free(try_attr_select);
    try std.testing.expectEqualStrings("false", try_attr_select);

    const try_attr_or = try renderForTest("(builtins.tryEval ((builtins.throw \"nope\").a or false)).success");
    defer std.testing.allocator.free(try_attr_or);
    try std.testing.expectEqualStrings("false", try_attr_or);

    const try_after_failed_call = try renderForTest("let f = x: builtins.throw \"nope\"; in builtins.toJSON (builtins.tryEval (f 1))");
    defer std.testing.allocator.free(try_after_failed_call);
    try std.testing.expectEqualStrings("\"{\\\"success\\\":false,\\\"value\\\":false}\"", try_after_failed_call);

    const traced = try renderForTest("builtins.trace \"message\" 42");
    defer std.testing.allocator.free(traced);
    try std.testing.expectEqualStrings("42", traced);

    const broken = try renderForTest("builtins.break 42");
    defer std.testing.allocator.free(broken);
    try std.testing.expectEqualStrings("42", broken);
}

test "evaluate string context builtins" {
    const drv_context = try renderForTest(
        \\let d = builtins.derivation { name = "pkg"; system = "x86_64-linux"; builder = "/bin/sh"; };
        \\in builtins.hasContext (builtins.toString d)
    );
    defer std.testing.allocator.free(drv_context);
    try std.testing.expectEqualStrings("true", drv_context);

    const interpolated = try renderForTest(
        \\let d = builtins.derivation { name = "pkg"; system = "x86_64-linux"; builder = "/bin/sh"; };
        \\in builtins.hasContext "${d}"
    );
    defer std.testing.allocator.free(interpolated);
    try std.testing.expectEqualStrings("true", interpolated);

    const discarded = try renderForTest(
        \\let d = builtins.derivation { name = "pkg"; system = "x86_64-linux"; builder = "/bin/sh"; };
        \\in builtins.getContext (builtins.unsafeDiscardOutputDependency d.drvPath)
    );
    defer std.testing.allocator.free(discarded);
    try std.testing.expect(std.mem.indexOf(u8, discarded, "path = true") != null);

    const appended = try renderForTest(
        \\builtins.hasContext (builtins.appendContext "x" {
        \\  "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-a.drv" = { outputs = [ "out" ]; };
        \\})
    );
    defer std.testing.allocator.free(appended);
    try std.testing.expectEqualStrings("true", appended);

    const merged_outputs = try renderForTest(
        \\let
        \\  dep = builtins.derivation { name = "dep"; outputs = [ "out" "bin" ]; system = "x86_64-linux"; builder = "/bin/sh"; };
        \\  ctx = builtins.getContext "${dep.bin}${dep.out}";
        \\in builtins.concatStringsSep "," ((builtins.getAttr (builtins.unsafeDiscardStringContext dep.drvPath) ctx).outputs)
    );
    defer std.testing.allocator.free(merged_outputs);
    try std.testing.expectEqualStrings("\"bin,out\"", merged_outputs);

    const merged_output_drv_path = try renderForTest(
        \\let
        \\  dep = builtins.derivation { name = "dep"; outputs = [ "out" "bin" ]; system = "x86_64-linux"; builder = "/bin/sh"; };
        \\  pkg = builtins.derivation { name = "pkg"; system = "x86_64-linux"; builder = "/bin/sh"; text = "${dep.bin}${dep.out}"; };
        \\in pkg.drvPath
    );
    defer std.testing.allocator.free(merged_output_drv_path);
    try std.testing.expectEqualStrings("\"/nix/store/8yjj0xh9r8937p4mv51iwnrl62jjx08p-pkg.drv\"", merged_output_drv_path);
}

test "evaluate minimal derivation builtins" {
    const derivation_type = try renderForTest("(builtins.derivation { name = \"pkg\"; system = \"x86_64-linux\"; builder = \"/bin/sh\"; }).type");
    defer std.testing.allocator.free(derivation_type);
    try std.testing.expectEqualStrings("\"derivation\"", derivation_type);

    const strict_attrs = try renderForTest("builtins.attrNames (builtins.derivationStrict { name = \"pkg\"; system = \"x86_64-linux\"; builder = \"/bin/sh\"; })");
    defer std.testing.allocator.free(strict_attrs);
    try std.testing.expectEqualStrings("[ \"drvPath\" \"out\" ]", strict_attrs);

    const named_output = try renderForTest("(builtins.derivation { name = \"pkg\"; outputs = [ \"out\" \"dev\" ]; system = \"x86_64-linux\"; builder = \"/bin/sh\"; }).dev.outputName");
    defer std.testing.allocator.free(named_output);
    try std.testing.expectEqualStrings("\"dev\"", named_output);

    const named_output_attrs = try renderForTest("builtins.attrNames (builtins.derivation { name = \"pkg\"; outputs = [ \"out\" \"dev\" ]; system = \"x86_64-linux\"; builder = \"/bin/sh\"; }).dev");
    defer std.testing.allocator.free(named_output_attrs);
    try std.testing.expectEqualStrings("[ \"all\" \"builder\" \"dev\" \"drvAttrs\" \"drvPath\" \"name\" \"out\" \"outPath\" \"outputName\" \"outputs\" \"system\" \"type\" ]", named_output_attrs);

    const implicit_outputs = try renderForTest("(builtins.derivation { name = \"pkg\"; system = \"x86_64-linux\"; builder = \"/bin/sh\"; }) ? outputs");
    defer std.testing.allocator.free(implicit_outputs);
    try std.testing.expectEqualStrings("false", implicit_outputs);

    const derivation_laziness = try renderForTest(
        \\builtins.toJSON {
        \\  lazy = (builtins.tryEval (builtins.derivation {
        \\    name = builtins.throw "x";
        \\    system = "x86_64-linux";
        \\    builder = "/bin/sh";
        \\  })).success;
        \\  lazyOutPath = (builtins.tryEval (builtins.derivation {
        \\    name = builtins.throw "x";
        \\    system = "x86_64-linux";
        \\    builder = "/bin/sh";
        \\  }).outPath).success;
        \\  strict = (builtins.tryEval (builtins.derivationStrict {
        \\    name = builtins.throw "x";
        \\    system = "x86_64-linux";
        \\    builder = "/bin/sh";
        \\  })).success;
        \\}
    );
    defer std.testing.allocator.free(derivation_laziness);
    try std.testing.expectEqualStrings("\"{\\\"lazy\\\":true,\\\"lazyOutPath\\\":false,\\\"strict\\\":false}\"", derivation_laziness);

    const all_len = try renderForTest("builtins.length (builtins.derivation { name = \"pkg\"; outputs = [ \"out\" \"dev\" ]; system = \"x86_64-linux\"; builder = \"/bin/sh\"; }).all");
    defer std.testing.allocator.free(all_len);
    try std.testing.expectEqualStrings("2", all_len);

    const input_sensitive_paths = try renderForTest(
        \\let
        \\  mkBuilder = builder: builtins.derivation { name = "pkg"; system = "x86_64-linux"; inherit builder; };
        \\  mkHash = hash: builtins.derivation {
        \\    name = "pkg";
        \\    system = "x86_64-linux";
        \\    builder = "/bin/sh";
        \\    outputHash = hash;
        \\    outputHashAlgo = "sha256";
        \\    outputHashMode = "flat";
        \\  };
        \\in builtins.toJSON {
        \\  builderOutSame = (mkBuilder "/bin/sh").outPath == (mkBuilder "/bin/bash").outPath;
        \\  builderDrvSame = (mkBuilder "/bin/sh").drvPath == (mkBuilder "/bin/bash").drvPath;
        \\  hashOutSame = (mkHash "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=").outPath == (mkHash "sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=").outPath;
        \\  hashDrvSame = (mkHash "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=").drvPath == (mkHash "sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=").drvPath;
        \\}
    );
    defer std.testing.allocator.free(input_sensitive_paths);
    try std.testing.expectEqualStrings("\"{\\\"builderDrvSame\\\":false,\\\"builderOutSame\\\":false,\\\"hashDrvSame\\\":false,\\\"hashOutSame\\\":false}\"", input_sensitive_paths);

    const exact_derivation_paths = try renderForTest(
        \\let
        \\  zero = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
        \\  minimal = builtins.derivation { name = "pkg"; system = "x86_64-linux"; builder = "/bin/sh"; };
        \\  multi = builtins.derivation { name = "pkg"; outputs = [ "out" "dev" ]; system = "x86_64-linux"; builder = "/bin/sh"; };
        \\  fixed = builtins.derivation {
        \\    name = "pkg";
        \\    system = "x86_64-linux";
        \\    builder = "/bin/sh";
        \\    outputHash = zero;
        \\    outputHashAlgo = "sha256";
        \\    outputHashMode = "flat";
        \\  };
        \\  a = builtins.derivation { name = "a"; system = "x86_64-linux"; builder = "/bin/sh"; };
        \\  b = builtins.derivation { name = "b"; system = "x86_64-linux"; builder = "/bin/sh"; src = a; };
        \\  structured = builtins.derivation {
        \\    name = "pkg-structured";
        \\    system = "x86_64-linux";
        \\    builder = "/bin/sh";
        \\    __structuredAttrs = true;
        \\    env = { A = 1; };
        \\  };
        \\  allOutA = builtins.derivation { name = "a"; outputs = [ "out" "dev" ]; system = "x86_64-linux"; builder = "/bin/sh"; };
        \\  allOutB = builtins.derivation { name = "b"; system = "x86_64-linux"; builder = "/bin/sh"; src = allOutA.drvPath; };
        \\in builtins.toJSON [
        \\  minimal.drvPath minimal.outPath
        \\  multi.drvPath multi.outPath multi.dev.outPath
        \\  fixed.drvPath fixed.outPath
        \\  b.drvPath b.outPath
        \\  structured.drvPath structured.outPath
        \\  allOutB.drvPath allOutB.outPath
        \\]
    );
    defer std.testing.allocator.free(exact_derivation_paths);
    try std.testing.expectEqualStrings("\"[\\\"/nix/store/s8l8ca4j8fb6d94205514xd6wf9b57ng-pkg.drv\\\",\\\"/nix/store/8w6a3g1mvf8qkz788dysw8k4hmq91cc8-pkg\\\",\\\"/nix/store/n9r8k4kqcj2019llzmc59f5258a33dip-pkg.drv\\\",\\\"/nix/store/92ysms3lcbywv6148gql79ab6zkfwcin-pkg\\\",\\\"/nix/store/16898da86iz5v475hj6bcy0r0c36zxq8-pkg-dev\\\",\\\"/nix/store/rbh6cczsi8jvv5bvdwy39j5p4xmn8z34-pkg.drv\\\",\\\"/nix/store/nrakis94lbi82m0f5n8fbkx78l568y4l-pkg\\\",\\\"/nix/store/n2gl5gv2n8980c52hly1c5d95jxyjs3h-b.drv\\\",\\\"/nix/store/4bcpp52bhq3g1l44b927m0s8rnxzgwvl-b\\\",\\\"/nix/store/bmwfaizv61s5jq8ba6n3xzlz3c7znln4-pkg-structured.drv\\\",\\\"/nix/store/8gn7x4yg0pdiklpk9giczxlb4i4gjkk3-pkg-structured\\\",\\\"/nix/store/dy56prsjy94iy9dxqkjg57k0hi5wj3qq-b.drv\\\",\\\"/nix/store/1mxidf53h5j44ypw18jqq3gc2yzcag4c-b\\\"]\"", exact_derivation_paths);

    const fixed_null_hash_algo = try renderForTest(
        \\let
        \\  flat = builtins.derivation {
        \\    name = "src";
        \\    system = "x86_64-linux";
        \\    builder = "/bin/sh";
        \\    outputHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
        \\    outputHashAlgo = null;
        \\    outputHashMode = "flat";
        \\  };
        \\  recursive = builtins.derivation {
        \\    name = "src";
        \\    system = "x86_64-linux";
        \\    builder = "/bin/sh";
        \\    outputHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
        \\    outputHashAlgo = null;
        \\    outputHashMode = "recursive";
        \\  };
        \\in builtins.toJSON [ flat.outPath recursive.outPath ]
    );
    defer std.testing.allocator.free(fixed_null_hash_algo);
    try std.testing.expectEqualStrings("\"[\\\"/nix/store/v7fhk503far527r9d9sk8dh2w6c7h695-src\\\",\\\"/nix/store/v1bh6bzphg5c2dc9ck7wdd3g1p6g19vd-src\\\"]\"", fixed_null_hash_algo);

    const core_fetchurl_hash_precedence = try renderForTest(
        \\(import <nix/fetchurl.nix> {
        \\  name = "bash-5.3.tar.gz";
        \\  url = "https://ftpmirror.gnu.org/bash/bash-5.3.tar.gz";
        \\  hash = "sha256-DVzYaWX4aaJs9k9Lcb57lvkKO6iz104n6OnZ1VUPMbo=";
        \\  sha256 = "";
        \\}).outPath
    );
    defer std.testing.allocator.free(core_fetchurl_hash_precedence);
    try std.testing.expectEqualStrings("\"/nix/store/kwm524zjlnnq4yfhhmb5r14f2wxf8a2j-bash-5.3.tar.gz\"", core_fetchurl_hash_precedence);

    var missing_hash_algo_ev = try Evaluator.init(std.testing.allocator, 0);
    defer missing_hash_algo_ev.deinit();
    try std.testing.expectError(
        error.InvalidHashAlgorithm,
        missing_hash_algo_ev.evaluate(
            \\(builtins.derivation {
            \\  name = "src";
            \\  system = "x86_64-linux";
            \\  builder = "/bin/sh";
            \\  outputHash = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
            \\  outputHashAlgo = null;
            \\  outputHashMode = "flat";
            \\}).outPath
        ),
    );

    const stable_context_inputs = try renderForTest(
        \\let
        \\  dep = builtins.derivation { name = "dep"; system = "x86_64-linux"; builder = "/bin/sh"; };
        \\  churn = builtins.concatStringsSep "" (builtins.genList (n: "long-derivation-input-context-${builtins.toString n}") 4096);
        \\  pkg = builtins.derivation {
        \\    name = "pkg";
        \\    system = "x86_64-linux";
        \\    builder = "/bin/sh";
        \\    args = [ dep.outPath churn dep.outPath ];
        \\  };
        \\in builtins.isString pkg.outPath
    );
    defer std.testing.allocator.free(stable_context_inputs);
    try std.testing.expectEqualStrings("true", stable_context_inputs);

    const structured_derivation_input = try renderForTest(
        \\let
        \\  dep = builtins.derivation { name = "dep"; system = "x86_64-linux"; builder = "/bin/sh"; };
        \\  pkg = builtins.derivation {
        \\    name = "pkg";
        \\    system = "x86_64-linux";
        \\    builder = "/bin/sh";
        \\    __structuredAttrs = true;
        \\    env = {
        \\      dep = dep;
        \\      nested = { also = dep; };
        \\    };
        \\  };
        \\in builtins.isString pkg.outPath
    );
    defer std.testing.allocator.free(structured_derivation_input);
    try std.testing.expectEqualStrings("true", structured_derivation_input);

    const structured_explicit_outputs = try renderForTest(
        \\let
        \\  pkg = builtins.derivation {
        \\    name = "pkg-structured";
        \\    outputs = [ "out" "debug" ];
        \\    system = "x86_64-linux";
        \\    builder = "/bin/sh";
        \\    __structuredAttrs = true;
        \\    env = { A = 1; };
        \\  };
        \\in builtins.toJSON [ pkg.drvPath pkg.outPath pkg.debug.outPath ]
    );
    defer std.testing.allocator.free(structured_explicit_outputs);
    try std.testing.expectEqualStrings("\"[\\\"/nix/store/5nkc970vb573fs2ppl4vflsymcrri8dn-pkg-structured.drv\\\",\\\"/nix/store/j9jfd9axp7wyhrx9mg088db3iw19dkyw-pkg-structured\\\",\\\"/nix/store/470amnhnd10jpqrh3im85xr0bicjb8rm-pkg-structured-debug\\\"]\"", structured_explicit_outputs);

    var recursive_structured_ev = try Evaluator.init(std.testing.allocator, 0);
    defer recursive_structured_ev.deinit();
    try std.testing.expectError(
        error.RecursiveThunk,
        recursive_structured_ev.evaluate(
            \\let
            \\  loop = rec { self = loop; };
            \\in (builtins.derivation {
            \\  name = "pkg";
            \\  system = "x86_64-linux";
            \\  builder = "/bin/sh";
            \\  __structuredAttrs = true;
            \\  env = loop;
            \\}).outPath
        ),
    );

    const semantic_paths = try renderForTest(
        \\let
        \\  mk = value: builtins.derivation { name = "pkg"; system = "x86_64-linux"; builder = "/bin/sh"; inherit value; };
        \\  mkMeta = meta: builtins.derivation { name = "pkg"; system = "x86_64-linux"; builder = "/bin/sh"; inherit meta; };
        \\  mkStructured = value: builtins.derivation {
        \\    name = "pkg";
        \\    system = "x86_64-linux";
        \\    builder = "/bin/sh";
        \\    __structuredAttrs = true;
        \\    env = { A = value; };
        \\  };
        \\in builtins.toJSON {
        \\  drvPathLength = builtins.stringLength (mk "x").drvPath;
        \\  listStringSame = (mk [ 1 true null ]).outPath == (mk "1  ").outPath;
        \\  metaSame = (mkMeta 1).outPath == (mkMeta 2).outPath;
        \\  structuredIntStringSame = (mkStructured 1).outPath == (mkStructured "1").outPath;
        \\  unstructuredIntStringSame = (mk 1).outPath == (mk "1").outPath;
        \\}
    );
    defer std.testing.allocator.free(semantic_paths);
    try std.testing.expectEqualStrings("\"{\\\"drvPathLength\\\":51,\\\"listStringSame\\\":false,\\\"metaSame\\\":false,\\\"structuredIntStringSame\\\":false,\\\"unstructuredIntStringSame\\\":true}\"", semantic_paths);

    const structured_ignore_nulls_reintern = try renderForTest(
        \\let
        \\  churn = builtins.concatStringsSep "" (builtins.genList (n: builtins.toString n) 4096);
        \\  pkg = builtins.derivation {
        \\    name = "pkg";
        \\    system = "x86_64-linux";
        \\    builder = "/bin/sh";
        \\    __structuredAttrs = true;
        \\    __ignoreNulls = true;
        \\    keep = "value";
        \\    skip = builtins.seq churn null;
        \\  };
        \\in builtins.stringLength pkg.drvPath == 51
    );
    defer std.testing.allocator.free(structured_ignore_nulls_reintern);
    try std.testing.expectEqualStrings("true", structured_ignore_nulls_reintern);

    const drv_attrs = try renderForTest("(builtins.derivation { name = \"pkg\"; system = \"x86_64-linux\"; builder = \"/bin/sh\"; args = [ 1 true null ]; __structuredAttrs = true; env = { A = 1; }; }).drvAttrs.env.A");
    defer std.testing.allocator.free(drv_attrs);
    try std.testing.expectEqualStrings("1", drv_attrs);

    const preserved_int = try renderForTest("(builtins.derivation { name = \"pkg\"; system = \"x86_64-linux\"; builder = \"/bin/sh\"; version = 1; }).version");
    defer std.testing.allocator.free(preserved_int);
    try std.testing.expectEqualStrings("1", preserved_int);

    const preserved_args = try renderForTest("builtins.head (builtins.derivation { name = \"pkg\"; system = \"x86_64-linux\"; builder = \"/bin/sh\"; args = [ 1 ./foo ]; }).args");
    defer std.testing.allocator.free(preserved_args);
    try std.testing.expectEqualStrings("1", preserved_args);
}

test "evaluate path construction builtins" {
    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const file_path = try std.fs.path.join(std.testing.allocator, &.{ cwd, "test/fuzz-corpus/imported.nix" });
    defer std.testing.allocator.free(file_path);

    const store_source = try std.fmt.allocPrint(std.testing.allocator, "builtins.isString (builtins.storePath \"{s}\")", .{cwd});
    defer std.testing.allocator.free(store_source);
    const path_source = try std.fmt.allocPrint(std.testing.allocator, "builtins.isString (builtins.path {{ path = \"{s}\"; name = \"imported\"; }})", .{file_path});
    defer std.testing.allocator.free(path_source);
    const path_value_source = try std.fmt.allocPrint(std.testing.allocator, "builtins.unsafeDiscardStringContext (builtins.path {{ path = \"{s}\"; name = \"imported\"; }})", .{file_path});
    defer std.testing.allocator.free(path_value_source);
    const path_prefix_source = try std.fmt.allocPrint(std.testing.allocator, "builtins.toJSON (builtins.substring 0 11 (builtins.path {{ path = \"{s}\"; name = \"imported\"; }}))", .{file_path});
    defer std.testing.allocator.free(path_prefix_source);
    const path_append_store_context_source = try std.fmt.allocPrint(std.testing.allocator, "/foo + builtins.substring 0 11 (builtins.path {{ path = \"{s}\"; name = \"imported\"; }})", .{file_path});
    defer std.testing.allocator.free(path_append_store_context_source);
    const literal_path_source =
        \\let p = ./build.zig; in builtins.toJSON {
        \\  raw = builtins.toString p;
        \\  interp = "${p}";
        \\  concat = builtins.concatStringsSep "" [ p ];
        \\  json = builtins.toJSON p;
        \\}
    ;

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    ev.setFileIo(std.testing.io);
    try ev.setBasePathFromCurrentPath(std.testing.io);

    const store_path = try ev.evaluate(store_source);
    try std.testing.expect(store_path.asBool());

    const path = try ev.evaluate(path_source);
    try std.testing.expect(path.asBool());

    const path_value = try ev.evaluate(path_value_source);
    try std.testing.expectEqualStrings("/nix/store/375nsbsr3gvzlfpmnviljghr7racpq67-imported", ev.intern.get(path_value.asInternId()));

    const path_prefix = try ev.evaluate(path_prefix_source);
    try std.testing.expectEqualStrings("\"/nix/store/\"", ev.intern.get(path_prefix.asInternId()));

    const literal_paths = try ev.evaluate(literal_path_source);
    const literal_paths_text = ev.intern.get(literal_paths.asInternId());
    try std.testing.expect(std.mem.indexOf(u8, literal_paths_text, cwd) != null);
    try std.testing.expect(std.mem.indexOf(u8, literal_paths_text, "/nix/store/") != null);
    try std.testing.expect(std.mem.indexOf(u8, literal_paths_text, "-build.zig") != null);

    try std.testing.expectError(error.InvalidPathConcatenation, ev.evaluate(path_append_store_context_source));
}

test "evaluate nixpkgs-heavy collection builtins" {
    const sorted = try renderForTest("builtins.sort (a: b: a < b) [ 3 1 2 ]");
    defer std.testing.allocator.free(sorted);
    try std.testing.expectEqualStrings("[ 1 2 3 ]", sorted);

    const partitioned = try renderForTest("(builtins.partition (x: x < 3) [ 1 3 2 ]).right");
    defer std.testing.allocator.free(partitioned);
    try std.testing.expectEqualStrings("[ 1 2 ]", partitioned);

    const grouped = try renderForTest("(builtins.groupBy (x: if x < 3 then \"small\" else \"big\") [ 1 3 2 ]).small");
    defer std.testing.allocator.free(grouped);
    try std.testing.expectEqualStrings("[ 1 2 ]", grouped);

    const closure_len = try renderForTest("builtins.length (builtins.genericClosure { startSet = [ { key = 1; } ]; operator = item: if item.key < 3 then [ { key = item.key + 1; } ] else [ ]; })");
    defer std.testing.allocator.free(closure_len);
    try std.testing.expectEqualStrings("3", closure_len);

    const cat_attrs = try renderForTest("builtins.elemAt (builtins.catAttrs \"a\" [ { a = 1; } { b = 2; } { a = 3; } ]) 1");
    defer std.testing.allocator.free(cat_attrs);
    try std.testing.expectEqualStrings("3", cat_attrs);

    const cat_attrs_lazy = try renderForTest("builtins.length (builtins.catAttrs \"a\" [ { a = 1 / 0; } ])");
    defer std.testing.allocator.free(cat_attrs_lazy);
    try std.testing.expectEqualStrings("1", cat_attrs_lazy);

    const zipped_len = try renderForTest("(builtins.zipAttrsWith (name: values: builtins.length values) [ { a = 1; } { a = 2; b = 3; } ]).a");
    defer std.testing.allocator.free(zipped_len);
    try std.testing.expectEqualStrings("2", zipped_len);

    const zipped_first = try renderForTest("(builtins.zipAttrsWith (name: values: builtins.head values) [ { a = 1; } { a = 2; } ]).a");
    defer std.testing.allocator.free(zipped_first);
    try std.testing.expectEqualStrings("1", zipped_first);

    const zipped_lazy_select = try renderForTest("(builtins.zipAttrsWith (name: values: if name == \"a\" then 1 else builtins.throw \"bad\") [ { a = 1; b = 2; } ]).a");
    defer std.testing.allocator.free(zipped_lazy_select);
    try std.testing.expectEqualStrings("1", zipped_lazy_select);

    const zipped_lazy_has_attr = try renderForTest("(builtins.zipAttrsWith (name: values: builtins.throw \"bad\") [ { a = 1; } ]) ? a");
    defer std.testing.allocator.free(zipped_lazy_has_attr);
    try std.testing.expectEqualStrings("true", zipped_lazy_has_attr);
}

test "evaluate function metadata builtins" {
    const args = try renderForTest("(builtins.functionArgs ({ a, b ? 1 }: a)).b");
    defer std.testing.allocator.free(args);
    try std.testing.expectEqualStrings("true", args);

    const pos = try renderForTest("builtins.unsafeGetAttrPos \"a\" { a = 1; }");
    defer std.testing.allocator.free(pos);
    try std.testing.expectEqualStrings("null", pos);

    const imported_pos = try renderForTestFromCurrentPath("builtins.toJSON (builtins.unsafeGetAttrPos \"value\" (import ./test/fuzz-corpus/imported.nix))");
    defer std.testing.allocator.free(imported_pos);

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const expected_imported_pos = try std.fmt.allocPrint(
        std.testing.allocator,
        "\"{{\\\"column\\\":3,\\\"file\\\":\\\"{s}/test/fuzz-corpus/imported.nix\\\",\\\"line\\\":1}}\"",
        .{cwd},
    );
    defer std.testing.allocator.free(expected_imported_pos);
    try std.testing.expectEqualStrings(expected_imported_pos, imported_pos);
}

test "evaluate foldl' builtin" {
    const sum = try renderForTest("builtins.foldl' (a: b: a + b) 0 [ 1 2 3 ]");
    defer std.testing.allocator.free(sum);
    try std.testing.expectEqualStrings("6", sum);

    const ignores_item = try renderForTest("builtins.foldl' (a: b: a) 1 [ (1 / 0) ]");
    defer std.testing.allocator.free(ignores_item);
    try std.testing.expectEqualStrings("1", ignores_item);

    const returns_item = try renderForTest("builtins.foldl' (a: b: b) 0 [ 1 2 ]");
    defer std.testing.allocator.free(returns_item);
    try std.testing.expectEqualStrings("2", returns_item);
}

test "evaluate exposes parse diagnostics without printing" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    try std.testing.expectError(error.ParseError, ev.evaluate("$ $ 1"));
    const diagnostics = ev.getDiagnostics();
    try std.testing.expectEqual(@as(usize, 2), diagnostics.len);
    try std.testing.expectEqualStrings("Invalid token.", diagnostics[0].message);
    try std.testing.expectEqual(@as(u32, 0), diagnostics[0].offset);
    try std.testing.expectEqual(@as(u32, 1), diagnostics[0].column);
    try std.testing.expectEqualStrings("Invalid token.", diagnostics[1].message);
    try std.testing.expectEqual(@as(u32, 2), diagnostics[1].offset);
    try std.testing.expectEqual(@as(u32, 3), diagnostics[1].column);
}

test "evaluate exposes duplicate binding diagnostics" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    try std.testing.expectError(error.DuplicateBinding, ev.evaluate("let x = 1; x = 2; in x"));
    const diagnostics = ev.getDiagnostics();
    try std.testing.expectEqual(@as(usize, 2), diagnostics.len);
    try std.testing.expectEqual(Diagnostic.Severity.err, diagnostics[0].severity);
    try std.testing.expectEqual(Diagnostic.Kind.compile, diagnostics[0].kind);
    try std.testing.expectEqualStrings("duplicate let binding", diagnostics[0].message);
    try std.testing.expectEqual(@as(u32, 11), diagnostics[0].offset);
    try std.testing.expectEqual(Diagnostic.Severity.note, diagnostics[1].severity);
    try std.testing.expectEqualStrings("first binding defined here", diagnostics[1].message);
    try std.testing.expectEqual(@as(u32, 4), diagnostics[1].offset);
}

test "evaluate exposes duplicate attribute diagnostics" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    try std.testing.expectError(error.DuplicateAttribute, ev.evaluate("{ a = 1; a = 2; }"));
    const diagnostics = ev.getDiagnostics();
    try std.testing.expectEqual(@as(usize, 2), diagnostics.len);
    try std.testing.expectEqual(Diagnostic.Severity.err, diagnostics[0].severity);
    try std.testing.expectEqual(Diagnostic.Kind.compile, diagnostics[0].kind);
    try std.testing.expectEqualStrings("duplicate attribute", diagnostics[0].message);
    try std.testing.expectEqual(@as(u32, 9), diagnostics[0].offset);
    try std.testing.expectEqual(Diagnostic.Severity.note, diagnostics[1].severity);
    try std.testing.expectEqualStrings("first attribute defined here", diagnostics[1].message);
    try std.testing.expectEqual(@as(u32, 2), diagnostics[1].offset);
}

test "evaluate exposes undefined variable diagnostics" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    try std.testing.expectError(error.UndefinedVariable, ev.evaluate("let y = x; in y"));
    const diagnostics = ev.getDiagnostics();
    try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
    try std.testing.expectEqual(Diagnostic.Severity.err, diagnostics[0].severity);
    try std.testing.expectEqual(Diagnostic.Kind.compile, diagnostics[0].kind);
    try std.testing.expectEqualStrings("undefined variable", diagnostics[0].message);
    try std.testing.expectEqual(@as(u32, 8), diagnostics[0].offset);
    try std.testing.expectEqual(@as(u32, 9), diagnostics[0].column);
}

test "evaluate records runtime error message and expression trace" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    try std.testing.expectError(error.TypeError, ev.evaluate("let y = 1 + \"x\"; in y"));

    const trace = ev.getTrace();
    try std.testing.expect(trace.message != null);
    try std.testing.expectEqualStrings("expected string or path, got int", trace.message.?);
    try std.testing.expect(trace.frames.items.len >= 2);
    try std.testing.expect(trace.frames.items[0].diagnostic != null);
    try std.testing.expect(trace.frames.items[0].source_path == null);
    try std.testing.expectEqualStrings("while evaluating", trace.frames.items[0].message);
    try std.testing.expectEqual(@as(u32, 1), trace.frames.items[0].diagnostic.?.line);
    try std.testing.expectEqual(@as(u32, 9), trace.frames.items[0].diagnostic.?.column);
}

test "evaluate records imported file source trace" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "boom.nix", .data = "let y = 1 + \"x\"; in y\n" });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const file_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "boom.nix",
    });
    defer std.testing.allocator.free(file_path);

    const source = try std.fmt.allocPrint(std.testing.allocator, "import {s}", .{file_path});
    defer std.testing.allocator.free(source);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    try std.testing.expectError(error.TypeError, ev.evaluate(source));

    const trace = ev.getTrace();
    try std.testing.expect(trace.message != null);
    try std.testing.expectEqualStrings("expected string or path, got int", trace.message.?);
    try std.testing.expect(trace.frames.items.len >= 1);
    try std.testing.expect(trace.frames.items[0].diagnostic != null);
    try std.testing.expect(trace.frames.items[0].source_path != null);
    try std.testing.expectEqualStrings(file_path, trace.frames.items[0].source_path.?);
    try std.testing.expectEqual(@as(u32, 1), trace.frames.items[0].diagnostic.?.line);
    try std.testing.expectEqual(@as(u32, 9), trace.frames.items[0].diagnostic.?.column);
}
