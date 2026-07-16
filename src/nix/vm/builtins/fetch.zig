//! Nix fetcher and flake builtins: fetchGit/fetchurl/fetchTarball/
//! fetchMercurial/fetchTree, getFlake and flake-ref parsing/serialization,
//! plus the impure getEnv/toPath/toFile/filterSource builtins.

const std = @import("std");
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const InternId = types.InternId;
const ObjectId = types.ObjectId;
const heap_mod = @import("runtime").heap;
const file_cache = @import("host").file_cache;
const fetch_cache = @import("host").fetch_cache;
const derivation = @import("derivation");
const nar = @import("host").nar;
const path_ops = @import("runtime").paths;
const source_paths = @import("derivation").source_path;
const eval_progress = @import("observ").progress;
const flake_registry = @import("flake_registry.zig");
const shared = @import("shared.zig");
const attrsets = @import("attrsets.zig");
const strings = @import("strings.zig");
const string_context = @import("string_context.zig");
const vm_force = @import("../force.zig");
const vm_closures = @import("../closures.zig");
const vm_trace = @import("../trace.zig");

const attrEntryNameIndex = attrsets.attrEntryNameIndex;
const coerceStringContextValue = strings.coerceStringContextValue;
const contextEntriesForValue = string_context.contextEntriesForValue;
const contextStringWithPath = string_context.contextStringWithPath;
const isPlainString = strings.isPlainString;
const isStringLike = strings.isStringLike;
const pathArg = strings.pathArg;
const sourcePathStringValue = strings.sourcePathStringValue;
const stringArg = strings.stringArg;
const stringTextInternId = strings.stringTextInternId;

pub fn builtinGetEnv(self: anytype, name_arg: Value) !Value {
    const name = try stringArg(self, name_arg);
    const host = self.import_host orelse return Value.string(try self.intern.intern(""));
    const value = try host.get_env(host.context, name);
    return Value.string(try self.intern.intern(value));
}

pub fn builtinToPath(self: anytype, arg: Value) !Value {
    const value = try vm_force.forceValue(self, arg);
    const text_id: InternId = switch (value.kind()) {
        .path, .string, .string_context => try stringTextInternId(self, value),
        else => return error.TypeError,
    };
    if (!std.fs.path.isAbsolute(self.intern.get(text_id))) return error.RelativePath;
    if (value.isContextString()) return value;
    return Value.string(text_id);
}

pub fn builtinToFile(self: anytype, name_arg: Value, contents_arg: Value) !Value {
    const name_value = try vm_force.forceValue(self, name_arg);
    if (!isStringLike(name_value)) return error.TypeError;

    const name_id = try stringTextInternId(self, name_value);
    try validateStorePathName(self.intern.get(name_id));

    const contents_value = try coerceStringContextValue(self, contents_arg);
    const contents_id = try stringTextInternId(self, contents_value);
    var ref_ids: std.ArrayListUnmanaged(InternId) = .empty;
    defer ref_ids.deinit(self.allocator);
    for (try contextEntriesForValue(self, contents_value)) |entry| {
        const ref = self.intern.get(entry.name);
        if (std.mem.endsWith(u8, ref, ".drv")) return error.DerivationReferenceInToFile;
        try ref_ids.append(self.allocator, entry.name);
    }

    const refs = try self.allocator.alloc([]const u8, ref_ids.items.len);
    defer self.allocator.free(refs);
    for (ref_ids.items, refs) |ref_id, *ref| ref.* = self.intern.get(ref_id);

    const name = self.intern.get(name_id);
    const contents = try self.derivations.allocator.dupe(u8, self.intern.get(contents_id));
    const path = derivation.textPath(self.allocator, self.derivations.store_dir, name, contents, refs) catch |err| {
        self.derivations.allocator.free(contents);
        return err;
    };
    defer self.allocator.free(path);
    self.derivations.noteProducerPayloadForTest(path, contents) catch |err| {
        self.derivations.allocator.free(contents);
        return err;
    };
    // recordOwnedTextRecipe consumes contents on success and error.
    try self.derivations.recordOwnedTextRecipe(path, contents, refs);
    return contextStringWithPath(self, try self.intern.intern(path));
}

fn validateStorePathName(name: []const u8) !void {
    if (!derivation.store_name.isValid(name)) return error.InvalidStorePathName;
}

/// The source-memo identity of a `filter`/`filterSource` predicate. Only a
/// heap-object predicate (closure, builtin-closure, partial application) has a
/// stable ObjectId to key on; a bare primop has no GC identity, so it returns
/// `null` and its filtered ingest is never memoized (recomputed each time). The
/// GC token pins the id against post-collection reuse (see `FilterKey`).
pub fn filterKeyOf(self: anytype, pred: Value) ?source_paths.FilterKey {
    if (pred.isClosure() or pred.isBuiltinClosure() or pred.isPartialApp()) {
        return .{ .object_id = pred.asObjectId(), .token = self.heap.token };
    }
    return null;
}

pub fn builtinFilterSource(self: anytype, pred_arg: Value, path_arg: Value) !Value {
    const pred = try vm_force.forceValue(self, pred_arg);
    const root_arg = try pathArg(self, path_arg);
    const root = try self.allocator.dupe(u8, root_arg);
    defer self.allocator.free(root);

    const Context = struct {
        vm: @TypeOf(self),
        pred: Value,

        fn accept(context: *anyopaque, path: []const u8, kind: file_cache.FileCache.FileKind) anyerror!bool {
            const ctx: *@This() = @ptrCast(@alignCast(context));
            return filterSourceAccepts(ctx.vm, ctx.pred, path, kind);
        }
    };
    var context: Context = .{ .vm = self, .pred = pred };

    var unsupported: nar.Unsupported = .{};
    defer unsupported.deinit(self.allocator);
    const store_path = source_paths.storePathForFilteredSourceReport(self.allocator, self.derivations, self.files, root, path_ops.baseName(root), .{
        .context = &context,
        .accept = Context.accept,
    }, filterKeyOf(self, pred), &unsupported) catch |err| return reportUnsupportedType(self, &unsupported, err);
    defer self.allocator.free(store_path);
    return contextStringWithPath(self, try self.intern.intern(store_path));
}

/// On `error.UnsupportedPathType` from NAR ingestion, attach the Nix-style
/// `file '<path>' has an unsupported type` message (using the path the
/// serializer recorded) before re-raising. Shared by the `path`/`filterSource`
/// copy-to-store builtins.
pub fn reportUnsupportedType(self: anytype, unsupported: *const nar.Unsupported, err: anyerror) anyerror {
    if (err == error.UnsupportedPathType) {
        if (unsupported.path) |p| {
            const msg = std.fmt.allocPrint(self.allocator, "file '{s}' has an unsupported type", .{p}) catch return err;
            defer self.allocator.free(msg);
            vm_trace.setErrorMessage(self, msg) catch {};
        }
    }
    return err;
}

const FetchGitSpec = struct {
    url: []u8,
    name: []u8,
    rev: ?[]u8,
    ref: ?[]u8,
    submodules: bool,

    fn deinit(self: FetchGitSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        allocator.free(self.name);
        if (self.rev) |rev| allocator.free(rev);
        if (self.ref) |ref| allocator.free(ref);
    }

    fn borrowed(self: FetchGitSpec) fetch_cache.FetchCache.GitSpec {
        return .{
            .url = self.url,
            .name = self.name,
            .rev = self.rev,
            .ref = self.ref,
            .submodules = self.submodules,
        };
    }
};

/// A fetched tree's realized `outPath` and `narHash`. When store writes are
/// enabled (`fix instantiate`/`build`) the tree is NAR-added to the real store
/// and these are the store path + real SRI NAR hash; otherwise (plain `eval`)
/// they are the local download-cache path + synthetic hash (offline-friendly,
/// matching the pre-store behaviour).
const FetchedOut = struct {
    out_path: []u8,
    nar_hash: []u8,

    fn deinit(self: FetchedOut, allocator: std.mem.Allocator) void {
        allocator.free(self.out_path);
        allocator.free(self.nar_hash);
    }
};

fn ingestFetchedTree(self: anytype, cache_path: []const u8, name: []const u8, rev: []const u8, filter: ?nar.Filter) !FetchedOut {
    _ = rev;
    if (self.derivations.store_writes_enabled) {
        // Fetched trees carry no user-lambda filter identity, so they are never
        // filter-memoized (pass null); a null `filter` is unfiltered-memoized.
        const ingested = try source_paths.ingest(self.allocator, self.derivations, self.files, cache_path, name, filter, null);
        return .{ .out_path = ingested.store_path, .nar_hash = ingested.nar_hash };
    }
    // Plain eval: keep the on-disk cache path (readable) and defer the NAR hash
    // (empty sentinel -> `treeNarHashValue` makes it a lazy thunk), so we match
    // Nix's real narHash without eagerly hashing trees that aren't inspected.
    return .{
        .out_path = try self.allocator.dupe(u8, cache_path),
        .nar_hash = try self.allocator.dupe(u8, ""),
    };
}

/// A fetched `outPath` string value. When the tree was materialized to the
/// store it carries string context referencing that store path, so using it as
/// a derivation `src` records it in `inputSrcs` (like Nix). Off-store (plain
/// eval) it is a bare string of the download-cache path.
fn fetchedPathValue(self: anytype, path: []const u8) !Value {
    const id = try self.intern.intern(path);
    return if (self.derivations.store_writes_enabled)
        contextStringWithPath(self, id)
    else
        Value.string(id);
}

/// NAR filter that drops any `.git` entry, so a git checkout ingests as the
/// tree Nix stores (working tree at the rev, minus the repository metadata).
fn gitFilterAccept(_: *anyopaque, path: []const u8, _: file_cache.FileCache.FileKind) anyerror!bool {
    return !std.mem.eql(u8, path_ops.baseName(path), ".git");
}
var git_filter_ctx: u8 = 0;
const git_filter = nar.Filter{ .context = &git_filter_ctx, .accept = gitFilterAccept };

/// NAR filter that drops any `.hg` entry (the Mercurial repository metadata).
fn hgFilterAccept(_: *anyopaque, path: []const u8, _: file_cache.FileCache.FileKind) anyerror!bool {
    return !std.mem.eql(u8, path_ops.baseName(path), ".hg");
}
var hg_filter_ctx: u8 = 0;
const hg_filter = nar.Filter{ .context = &hg_filter_ctx, .accept = hgFilterAccept };

fn mercurialResultValue(self: anytype, name: []const u8, result: fetch_cache.FetchCache.MercurialResult) !Value {
    const out = try ingestFetchedTree(self, result.out_path, name, result.rev, hg_filter);
    defer out.deinit(self.allocator);
    const entries = [_]heap_mod.AttrEntry{
        .{ .name = try self.intern.intern("narHash"), .value = try treeNarHashValue(self, out.out_path, out.nar_hash, ".hg") },
        .{ .name = try self.intern.intern("outPath"), .value = try fetchedPathValue(self, out.out_path) },
        .{ .name = try self.intern.intern("rev"), .value = Value.string(try self.intern.intern(result.rev)) },
        .{ .name = try self.intern.intern("shortRev"), .value = Value.string(try self.intern.intern(result.short_rev)) },
    };
    return Value.attrs(try self.heap.addAttrs(&entries));
}

/// Open a concurrent "fetching <subject>" progress span. Fetches run on
/// whatever fiber forces them (often off the demand path), so this uses the
/// thread-safe concurrent-span channel — its node is independent of the demand
/// LIFO stage stack. Null (and a no-op `end`) when progress isn't drawn.
fn fetchSpanBegin(self: anytype, subject: []const u8) ?eval_progress.Span {
    const spans = self.progress_spans orelse return null;
    return spans.beginSpan(.fetch, subject);
}

fn fetchSpanEnd(self: anytype, span: ?eval_progress.Span) void {
    if (span) |sp| if (self.progress_spans) |spans| spans.endSpan(sp);
}

const io_offload = @import("../io_offload.zig");
const FetchCache = fetch_cache.FetchCache;
const FileCache = file_cache.FileCache;

/// Wraps a fetch progress span so the runtime download loop can report bytes
/// (`downloaded`/`total`) without knowing the progress types. Lives on the
/// `offloadFetch` frame, which stays parked for the whole fetch.
const FetchReport = struct {
    sink: eval_progress.SpanSink,
    span: eval_progress.Span,

    fn report(ctx: *anyopaque, downloaded: u64, total: u64) void {
        const self: *FetchReport = @ptrCast(@alignCast(ctx));
        self.sink.updateSpan(self.span, downloaded, total);
    }
};

/// Run a blocking `FetchCache` fetch on a dedicated fetch thread (bounded by
/// `http-connections`) while the calling fiber parks — so the compute worker is
/// free to run other fibers instead of blocking on network/subprocess I/O. The
/// fetch's borrowed args stay valid because the fiber stays parked for the whole
/// call. `call` is a `FetchCache` method, e.g. `FetchCache.fetchUrl`; `span` is
/// this fetch's progress span (download bytes are reported onto it).
fn offloadFetch(self: anytype, comptime call: anytype, spec: anytype, span: ?eval_progress.Span) anyerror!@typeInfo(@typeInfo(@TypeOf(call)).@"fn".return_type.?).error_union.payload {
    const Res = @typeInfo(@typeInfo(@TypeOf(call)).@"fn".return_type.?).error_union.payload;
    const Cell = struct {
        fetchers: *FetchCache,
        files: *FileCache,
        spec: @TypeOf(spec),
        reporter: ?FetchCache.Reporter,
        res: Res = undefined,
        err: ?anyerror = null,

        fn run(p: *anyopaque) void {
            const c: *@This() = @ptrCast(@alignCast(p));
            c.res = call(c.fetchers, c.files, c.spec, c.reporter) catch |e| {
                c.err = e;
                return;
            };
        }
    };
    var report_store: FetchReport = undefined;
    const reporter: ?FetchCache.Reporter = reporter: {
        const sink = self.progress_spans orelse break :reporter null;
        const sp = span orelse break :reporter null;
        report_store = .{ .sink = sink, .span = sp };
        break :reporter .{ .ctx = &report_store, .report = FetchReport.report };
    };
    var cell: Cell = .{ .fetchers = self.fetchers, .files = self.files, .spec = spec, .reporter = reporter };
    io_offload.runFetch(self.fetchers.connSem(), Cell.run, &cell);
    if (cell.err) |e| return e;
    return cell.res;
}

pub fn builtinFetchGit(self: anytype, arg: Value) !Value {
    const spec = try fetchGitSpec(self, arg);
    defer spec.deinit(self.allocator);

    const span = fetchSpanBegin(self, spec.url);
    defer fetchSpanEnd(self, span);
    const result = try offloadFetch(self, FetchCache.fetchGit, spec.borrowed(), span);
    defer result.deinit(self.fetchers.allocator);
    return gitResultValue(self, spec.name, result);
}

fn gitResultValue(self: anytype, name: []const u8, result: fetch_cache.FetchCache.GitResult) !Value {
    const out = try ingestFetchedTree(self, result.out_path, name, result.rev, git_filter);
    defer out.deinit(self.allocator);
    const entries = [_]heap_mod.AttrEntry{
        .{ .name = try self.intern.intern("lastModified"), .value = Value.int(result.last_modified) },
        .{ .name = try self.intern.intern("lastModifiedDate"), .value = Value.string(try self.intern.intern(result.last_modified_date)) },
        .{ .name = try self.intern.intern("narHash"), .value = try treeNarHashValue(self, out.out_path, out.nar_hash, ".git") },
        .{ .name = try self.intern.intern("outPath"), .value = try fetchedPathValue(self, out.out_path) },
        .{ .name = try self.intern.intern("rev"), .value = Value.string(try self.intern.intern(result.rev)) },
        .{ .name = try self.intern.intern("revCount"), .value = Value.int(result.rev_count) },
        .{ .name = try self.intern.intern("shortRev"), .value = Value.string(try self.intern.intern(result.short_rev)) },
        .{ .name = try self.intern.intern("submodules"), .value = Value.boolVal(result.submodules) },
    };
    return Value.attrs(try self.heap.addAttrs(&entries));
}

/// The `narHash` value for a fetched tree: an eager SRI string when we already
/// have it (store writes, where ingest computed it), or — when `nar_hash` is
/// empty (plain eval) — a thunk that computes the real NAR hash of `path` only
/// if it's accessed, matching Nix (which never hashes a tree eagerly here).
/// `exclude` is a basename dropped from the NAR (".git"/".hg" for VCS checkouts,
/// "" otherwise) so the lazy hash matches what `ingestFetchedTree` serialized.
fn treeNarHashValue(self: anytype, path: []const u8, nar_hash: []const u8, exclude: []const u8) !Value {
    if (nar_hash.len != 0) return Value.string(try self.intern.intern(nar_hash));
    return shared.makeBuiltinThunk(self, .compute_nar_hash, &.{
        Value.string(try self.intern.intern(path)),
        Value.string(try self.intern.intern(exclude)),
    });
}

const ExcludeCtx = struct { name: []const u8 };
fn excludeAccept(context: *anyopaque, path: []const u8, _: file_cache.FileCache.FileKind) anyerror!bool {
    const ctx: *ExcludeCtx = @ptrCast(@alignCast(context));
    return !std.mem.eql(u8, path_ops.baseName(path), ctx.name);
}

/// Compute a fetched tree's NAR hash in Nix SRI form (`sha256-<base64>`),
/// optionally excluding a basename (e.g. ".git"). Backs the lazy `narHash`
/// thunk (see `treeNarHashValue`).
pub fn computeNarHash(self: anytype, path_value: Value, exclude_value: Value) !Value {
    const path = self.intern.get(path_value.asInternId());
    const exclude = self.intern.get(exclude_value.asInternId());
    var ctx = ExcludeCtx{ .name = exclude };
    const filter: ?nar.Filter = if (exclude.len == 0) null else .{ .context = &ctx, .accept = excludeAccept };
    const nar_bytes = try nar.serialize(self.allocator, self.files, path, filter);
    defer self.allocator.free(nar_bytes);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(nar_bytes, &digest, .{});
    const enc = std.base64.standard.Encoder;
    var buf: [7 + 44]u8 = undefined;
    @memcpy(buf[0..7], "sha256-");
    const encoded = enc.encode(buf[7..], &digest);
    return Value.string(try self.intern.intern(buf[0 .. 7 + encoded.len]));
}

fn pathTreeValue(self: anytype, path: []const u8, nar_hash: []const u8) !Value {
    const entries = [_]heap_mod.AttrEntry{
        .{ .name = try self.intern.intern("lastModified"), .value = Value.int(0) },
        .{ .name = try self.intern.intern("lastModifiedDate"), .value = Value.string(try self.intern.intern("19700101000000")) },
        .{ .name = try self.intern.intern("narHash"), .value = try treeNarHashValue(self, path, nar_hash, "") },
        .{ .name = try self.intern.intern("outPath"), .value = try fetchedPathValue(self, path) },
    };
    return Value.attrs(try self.heap.addAttrs(&entries));
}

fn fileTreeValue(self: anytype, path: []const u8, nar_hash: []const u8) !Value {
    const entries = [_]heap_mod.AttrEntry{
        .{ .name = try self.intern.intern("narHash"), .value = Value.string(try self.intern.intern(nar_hash)) },
        .{ .name = try self.intern.intern("outPath"), .value = try fetchedPathValue(self, path) },
    };
    return Value.attrs(try self.heap.addAttrs(&entries));
}

fn fetchGitSpec(self: anytype, arg: Value) !FetchGitSpec {
    const value = try vm_force.forceValue(self, arg);
    if (!value.isAttrs()) {
        const url = try self.allocator.dupe(u8, try pathArg(self, value));
        errdefer self.allocator.free(url);
        return .{
            .url = url,
            .name = try self.allocator.dupe(u8, "source"),
            .rev = null,
            .ref = null,
            .submodules = false,
        };
    }

    return fetchGitSpecFromAttrs(self, value.asObjectId());
}

fn fetchGitSpecFromAttrs(self: anytype, attrs_id: ObjectId) !FetchGitSpec {
    const url = try dupPathAttr(self, attrs_id, "url");
    errdefer self.allocator.free(url);
    const name = try optionalStringAttr(self, attrs_id, "name") orelse try self.allocator.dupe(u8, "source");
    errdefer self.allocator.free(name);
    const rev = try optionalStringAttr(self, attrs_id, "rev");
    errdefer if (rev) |owned| self.allocator.free(owned);
    const ref = try optionalStringAttr(self, attrs_id, "ref");
    errdefer if (ref) |owned| self.allocator.free(owned);
    const submodules = try optionalBoolAttr(self, attrs_id, "submodules") orelse false;

    return .{
        .url = url,
        .name = name,
        .rev = rev,
        .ref = ref,
        .submodules = submodules,
    };
}

const FetchUrlSpec = struct {
    url: []u8,
    name: []u8,

    fn deinit(self: FetchUrlSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        allocator.free(self.name);
    }

    fn borrowed(self: FetchUrlSpec) fetch_cache.FetchCache.UrlSpec {
        return .{ .url = self.url, .name = self.name };
    }
};

pub fn builtinFetchurl(self: anytype, arg: Value) !Value {
    const spec = try fetchUrlSpec(self, arg);
    defer spec.deinit(self.allocator);
    const expected_hash = try expectedFetchSha256Hex(self, arg);
    defer if (expected_hash) |hash| self.allocator.free(hash);

    // Plain eval with a known hash: the flat fixed-output path is fully
    // determined by (name, sha256), so return it without fetching. The download
    // is deferred (registered as a pending fetch) and runs only if the path's
    // content is later demanded — offline for path-only use, still correct for
    // import-from-derivation. Store writes keep the eager fetch+materialize path.
    if (expected_hash) |expected| {
        if (!self.derivations.store_writes_enabled) {
            const store_path = try derivation.fixedOutputPath(self.allocator, self.derivations.store_dir, spec.name, "out", "sha256", expected);
            defer self.allocator.free(store_path);
            try self.derivations.recordPendingFetch(store_path, spec.url, spec.name, false, expected);
            return contextStringWithPath(self, try self.intern.intern(store_path));
        }
    }

    const span = fetchSpanBegin(self, spec.url);
    defer fetchSpanEnd(self, span);
    const result = try offloadFetch(self, FetchCache.fetchUrl, spec.borrowed(), span);
    defer result.deinit(self.fetchers.allocator);
    try validateFetchedSha256(self, "file", spec.url, expected_hash, result.hash);
    const path = try flatFetchOutPath(self, result.path, result.hash, spec.name);
    defer self.allocator.free(path);
    // The flat fixed-output store path is fully determined by the fetched
    // content's hash, so return it (with context) even in plain eval — matching
    // Nix, whose `fetchurl` always yields the store path with `{ path = true }`.
    return contextStringWithPath(self, try self.intern.intern(path));
}

fn expectedFetchSha256Hex(self: anytype, arg: Value) !?[]u8 {
    const value = try vm_force.forceValue(self, arg);
    if (!value.isAttrs()) return null;
    const expected = (try optionalStringAttr(self, value.asObjectId(), "sha256")) orelse return null;
    defer self.allocator.free(expected);
    return derivation.hashToBase16(self.allocator, "sha256", expected) catch {
        const message = try std.fmt.allocPrint(self.allocator, "invalid sha256 hash '{s}'", .{expected});
        defer self.allocator.free(message);
        try vm_trace.setErrorMessage(self, message);
        return error.InvalidHash;
    };
}

fn validateFetchedSha256(self: anytype, noun: []const u8, url: []const u8, expected_hex: ?[]const u8, actual_hex: []const u8) !void {
    const expected = expected_hex orelse return;
    if (std.ascii.eqlIgnoreCase(expected, actual_hex)) return;
    const message = try std.fmt.allocPrint(
        self.allocator,
        "hash mismatch in {s} downloaded from '{s}': expected sha256 '{s}', got '{s}'",
        .{ noun, url, expected, actual_hex },
    );
    defer self.allocator.free(message);
    try vm_trace.setErrorMessage(self, message);
    return error.HashMismatch;
}

/// Realize a fetched single file to its flat (`fixed:sha256`) fixed-output
/// store path — like Nix's fetchurl. Under store writes the bytes are added to
/// the real store; in plain eval the store path is still returned, with the
/// fetched content seeded into the file cache so reads of it succeed.
/// Returns the store path (owned by `self.allocator`).
fn flatFetchOutPath(self: anytype, cache_path: []const u8, hash_hex: []const u8, name: []const u8) ![]u8 {
    // The flat store path is determined by the content hash regardless of store
    // writes; only the store instantiation is gated on them.
    const store_path = try derivation.fixedOutputPath(self.allocator, self.derivations.store_dir, name, "out", "sha256", hash_hex);
    errdefer self.allocator.free(store_path);
    var contents = try self.files.retainFile(cache_path);
    defer contents.release();
    if (!self.derivations.store_writes_enabled) {
        // Plain eval has no store to materialize the file; seed the cache so
        // `readFile`/`import` on the returned store path stays zero-copy.
        try self.files.provideRegular(store_path, contents);
    }
    // A fetched flat file reports under `.fetch` (at download), not `.source`.
    try self.derivations.recordFlatRecipe(store_path, contents, null);
    return store_path;
}

/// Reject any attr not in `allowed`, matching Nix's argument validation for
/// the simple fetchers.
fn rejectUnknownFetchAttrs(self: anytype, attrs_id: ObjectId, comptime allowed: []const []const u8) !void {
    const entries = try self.heap.getAttrs(attrs_id);
    outer: for (entries) |entry| {
        const name = self.intern.get(entry.name);
        inline for (allowed) |a| {
            if (std.mem.eql(u8, name, a)) continue :outer;
        }
        const msg = try std.fmt.allocPrint(self.allocator, "unexpected argument '{s}'", .{name});
        defer self.allocator.free(msg);
        try vm_trace.setErrorMessage(self, msg);
        return error.UnexpectedArgument;
    }
}

fn fetchUrlSpec(self: anytype, arg: Value) !FetchUrlSpec {
    const value = try vm_force.forceValue(self, arg);
    if (!value.isAttrs()) {
        // fetchurl/fetchTarball take a string URL (or an attrset); a path is a
        // type error.
        const url = try self.allocator.dupe(u8, try stringArg(self, value));
        errdefer self.allocator.free(url);
        return .{
            .url = url,
            .name = try defaultFetchName(self, url),
        };
    }

    // Direct fetchurl/fetchTarball accept only url / sha256 / name; anything
    // else (e.g. `hash`) errors. (fetchTree's file/tarball reuse the spec below
    // but carry an extra `type` attr, so they don't go through this check.)
    try rejectUnknownFetchAttrs(self, value.asObjectId(), &.{ "url", "sha256", "name" });
    return fetchUrlSpecFromAttrs(self, value.asObjectId(), null);
}

fn fetchUrlSpecFromAttrs(self: anytype, attrs_id: ObjectId, default_name: ?[]const u8) !FetchUrlSpec {
    const url = try dupPathAttr(self, attrs_id, "url");
    errdefer self.allocator.free(url);
    const name = try optionalStringAttr(self, attrs_id, "name") orelse if (default_name) |name|
        try self.allocator.dupe(u8, name)
    else
        try defaultFetchName(self, url);
    return .{ .url = url, .name = name };
}

pub fn builtinFetchTarball(self: anytype, arg: Value) !Value {
    const tree_name = try tarballTreeName(self, arg);
    defer self.allocator.free(tree_name);
    const spec = try fetchUrlSpec(self, arg);
    defer spec.deinit(self.allocator);
    const expected_hash = try expectedFetchSha256Hex(self, arg);
    defer if (expected_hash) |hash| self.allocator.free(hash);

    // Plain eval with a known hash: the recursive fixed-output path is fully
    // determined by (name, sha256), so return it without fetching (deferred like
    // fetchurl above). Content demand (readFile into the tree, import) triggers
    // the fetch+unpack lazily. Store writes keep the eager ingest path.
    if (expected_hash) |expected| {
        if (!self.derivations.store_writes_enabled) {
            const store_path = try derivation.sourcePath(self.allocator, self.derivations.store_dir, tree_name, expected);
            defer self.allocator.free(store_path);
            try self.derivations.recordPendingFetch(store_path, spec.url, tree_name, true, expected);
            return contextStringWithPath(self, try self.intern.intern(store_path));
        }
    }

    const span = fetchSpanBegin(self, spec.url);
    defer fetchSpanEnd(self, span);
    const result = try offloadFetch(self, FetchCache.fetchTarball, FetchCache.TarballSpec{
        .url = spec.url,
        .name = spec.name,
        .serialize_nar = expected_hash != null,
    }, span);
    defer result.deinit(self.fetchers.allocator);

    if (expected_hash) |expected| {
        const payload = result.nar_payload orelse unreachable;
        const actual_hash = std.fmt.bytesToHex(payload.digest, .lower);
        try validateFetchedSha256(self, "tarball", spec.url, expected, &actual_hash);
        if (self.derivations.store_writes_enabled) {
            const ingested = try source_paths.ingestSerializedNar(
                self.allocator,
                self.derivations,
                tree_name,
                payload.bytes,
                &payload.digest,
            );
            defer ingested.deinit(self.allocator);
            return contextStringWithPath(self, try self.intern.intern(ingested.store_path));
        }
        // Plain eval: the value text is the readable download-cache path, but
        // its context references the real recursive fixed-output store path, so
        // `builtins.getContext` matches Nix without a store to materialize it.
        const nar_hex = std.fmt.bytesToHex(payload.digest, .lower);
        const store_path = try derivation.sourcePath(self.allocator, self.derivations.store_dir, tree_name, &nar_hex);
        defer self.allocator.free(store_path);
        return string_context.contextStringTextWithPath(self, try self.intern.intern(result.path), try self.intern.intern(store_path));
    }

    // The unpacked tree is named "source" by default (Nix), independent of the
    // archive's URL basename which named the download (`tree_name`, above).
    const out = try ingestFetchedTree(self, result.path, tree_name, "", null);
    defer out.deinit(self.allocator);
    return fetchedPathValue(self, out.out_path);
}

/// Materialize a deferred `fetchurl`/`fetchTarball` when its content is demanded
/// (readFile/import). `demanded_path` is the store path being read, or a
/// `store_path/sub` inside a fetched tree. Runs the download now, validates it
/// against the recorded hash, and seeds the file cache so the read succeeds.
/// Returns true iff a pending fetch was found and materialized. Called from the
/// path-demand seam so path-only uses never reach here (and never fetch).
pub fn materializePendingFetch(self: anytype, demanded_path: []const u8) !bool {
    const store_root = storeRootOf(demanded_path, self.derivations.store_dir) orelse return false;
    // `peekPendingFetch` clones with the store's allocator; free with the same.
    var pending = (try self.derivations.peekPendingFetch(store_root)) orelse return false;
    defer pending.deinit(self.derivations.allocator);

    const span = fetchSpanBegin(self, pending.url);
    defer fetchSpanEnd(self, span);

    if (pending.recursive) {
        const result = try offloadFetch(self, FetchCache.fetchTarball, FetchCache.TarballSpec{
            .url = pending.url,
            .name = pending.name,
            .serialize_nar = true,
        }, span);
        defer result.deinit(self.fetchers.allocator);
        const payload = result.nar_payload orelse unreachable;
        const actual_hash = std.fmt.bytesToHex(payload.digest, .lower);
        try validateFetchedSha256(self, "tarball", pending.url, pending.hash_hex, &actual_hash);
        // Seed the specific file demanded from the unpacked tree; the entry
        // stays registered so sibling reads materialize too (the fetch cache
        // memoizes the download + unpack, so repeats are cheap).
        const rel_raw = demanded_path[store_root.len..];
        const rel = if (rel_raw.len > 0 and rel_raw[0] == '/') rel_raw[1..] else rel_raw;
        const src = try std.fs.path.join(self.allocator, &.{ result.path, rel });
        defer self.allocator.free(src);
        var contents = try self.files.retainFile(src);
        defer contents.release();
        try self.files.provideRegular(demanded_path, contents);
        return true;
    }

    const result = try offloadFetch(self, FetchCache.fetchUrl, FetchCache.UrlSpec{
        .url = pending.url,
        .name = pending.name,
    }, span);
    defer result.deinit(self.fetchers.allocator);
    try validateFetchedSha256(self, "file", pending.url, pending.hash_hex, result.hash);
    var contents = try self.files.retainFile(result.path);
    defer contents.release();
    try self.files.provideRegular(store_root, contents);
    self.derivations.removePendingFetch(store_root);
    return true;
}

/// The `/nix/store/<name>` root of a store path (stripping any `/sub…`), or null
/// if `path` isn't under the store directory.
fn storeRootOf(path: []const u8, store_dir: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, path, store_dir)) return null;
    if (path.len <= store_dir.len or path[store_dir.len] != '/') return null;
    const after = store_dir.len + 1;
    const rel_end = std.mem.indexOfScalarPos(u8, path, after, '/') orelse return path;
    return path[0..rel_end];
}

/// The store name for a `fetchTarball` unpacked tree: an explicit `name` attr,
/// else "source" (matching Nix — not the archive's URL basename).
fn tarballTreeName(self: anytype, arg: Value) ![]u8 {
    const value = try vm_force.forceValue(self, arg);
    if (value.isAttrs()) {
        if (try optionalStringAttr(self, value.asObjectId(), "name")) |name| return name;
    }
    return self.allocator.dupe(u8, "source");
}

const FetchMercurialSpec = struct {
    url: []u8,
    name: []u8,
    rev: ?[]u8,

    fn deinit(self: FetchMercurialSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        allocator.free(self.name);
        if (self.rev) |rev| allocator.free(rev);
    }

    fn borrowed(self: FetchMercurialSpec) fetch_cache.FetchCache.MercurialSpec {
        return .{ .url = self.url, .name = self.name, .rev = self.rev };
    }
};

pub fn builtinFetchMercurial(self: anytype, arg: Value) !Value {
    const spec = try fetchMercurialSpec(self, arg);
    defer spec.deinit(self.allocator);

    const span = fetchSpanBegin(self, spec.url);
    defer fetchSpanEnd(self, span);
    const result = try offloadFetch(self, FetchCache.fetchMercurial, spec.borrowed(), span);
    defer result.deinit(self.fetchers.allocator);
    return mercurialResultValue(self, spec.name, result);
}

fn fetchMercurialSpec(self: anytype, arg: Value) !FetchMercurialSpec {
    const value = try vm_force.forceValue(self, arg);
    if (!value.isAttrs()) {
        const url = try self.allocator.dupe(u8, try pathArg(self, value));
        errdefer self.allocator.free(url);
        return .{
            .url = url,
            .name = try self.allocator.dupe(u8, "source"),
            .rev = null,
        };
    }

    return fetchMercurialSpecFromAttrs(self, value.asObjectId());
}

fn fetchMercurialSpecFromAttrs(self: anytype, attrs_id: ObjectId) !FetchMercurialSpec {
    const url = try dupPathAttr(self, attrs_id, "url");
    errdefer self.allocator.free(url);
    const name = try optionalStringAttr(self, attrs_id, "name") orelse try self.allocator.dupe(u8, "source");
    errdefer self.allocator.free(name);
    const rev = try optionalStringAttr(self, attrs_id, "rev");
    errdefer if (rev) |owned| self.allocator.free(owned);

    return .{ .url = url, .name = name, .rev = rev };
}

const GithubTreeSpec = struct {
    url: []u8,
    name: []u8,
    rev: ?[]u8,

    fn deinit(self: GithubTreeSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        allocator.free(self.name);
        if (self.rev) |rev| allocator.free(rev);
    }
};

/// Build the codeload archive URL for github/gitlab/sourcehut, honoring a
/// `host` override (self-hosted forges) and pinning `rev`/`ref` (else HEAD).
fn forgeTreeSpec(self: anytype, attrs_id: ObjectId, forge: []const u8) !GithubTreeSpec {
    const owner = try requiredStringAttr(self, attrs_id, "owner");
    defer self.allocator.free(owner);
    const repo = try requiredStringAttr(self, attrs_id, "repo");
    defer self.allocator.free(repo);
    const rev_attr = try optionalStringAttr(self, attrs_id, "rev");
    errdefer if (rev_attr) |owned| self.allocator.free(owned);
    const ref_attr = try optionalStringAttr(self, attrs_id, "ref");
    errdefer if (ref_attr) |owned| self.allocator.free(owned);
    // A forge ref (github/gitlab/sourcehut) cannot pin both a branch/tag and a
    // revision (Nix/Lix reject this, lix#1133).
    if (rev_attr != null and ref_attr != null) {
        try vm_trace.setErrorMessage(self, "fetchTree: 'ref' and 'rev' cannot both be specified for a forge source");
        return error.UnexpectedArgument;
    }
    const rev = rev_attr orelse ref_attr;
    const host = try optionalStringAttr(self, attrs_id, "host");
    defer if (host) |h| self.allocator.free(h);
    const archive_ref = rev orelse "HEAD";
    const url = if (std.mem.eql(u8, forge, "gitlab"))
        try std.fmt.allocPrint(self.allocator, "https://{s}/{s}/{s}/-/archive/{s}/{s}-{s}.tar.gz", .{ host orelse "gitlab.com", owner, repo, archive_ref, repo, archive_ref })
    else if (std.mem.eql(u8, forge, "sourcehut"))
        try std.fmt.allocPrint(self.allocator, "https://{s}/{s}/{s}/archive/{s}.tar.gz", .{ host orelse "git.sr.ht", owner, repo, archive_ref })
    else
        try std.fmt.allocPrint(self.allocator, "https://{s}/{s}/{s}/archive/{s}.tar.gz", .{ host orelse "github.com", owner, repo, archive_ref });
    errdefer self.allocator.free(url);
    const name = try optionalStringAttr(self, attrs_id, "name") orelse try self.allocator.dupe(u8, "source");
    return .{ .url = url, .name = name, .rev = rev };
}

fn githubTreeValue(self: anytype, path: []const u8, nar_hash: []const u8, rev: ?[]const u8) !Value {
    var entries: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer entries.deinit(self.allocator);
    try entries.appendSlice(self.allocator, &.{
        .{ .name = try self.intern.intern("lastModified"), .value = Value.int(0) },
        .{ .name = try self.intern.intern("lastModifiedDate"), .value = Value.string(try self.intern.intern("19700101000000")) },
        .{ .name = try self.intern.intern("narHash"), .value = try treeNarHashValue(self, path, nar_hash, "") },
        .{ .name = try self.intern.intern("outPath"), .value = try fetchedPathValue(self, path) },
    });
    if (rev) |value| {
        try appendStringAttr(self, &entries, "rev", value);
        try appendStringAttr(self, &entries, "shortRev", value[0..@min(value.len, 7)]);
    }
    return Value.attrs(try self.heap.addAttrs(entries.items));
}

/// Dispatch entry for a direct `builtins.fetchTree` call. Gated on the
/// `fetch-tree` experimental feature (Nix parity). `getFlake` bypasses this by
/// calling `builtinFetchTree` directly, matching Nix where flake fetching does
/// not additionally require the user to enable `fetch-tree`.
pub fn builtinFetchTreeEntry(self: anytype, arg: Value) !Value {
    if (!self.fetch_tree_enabled) {
        // A hard eval error, like Nix: not catchable by `builtins.tryEval`
        // (which only intercepts NixThrow/NixAbort/AssertionFailed/FileNotFound).
        try vm_trace.setErrorMessage(self, "builtins.fetchTree is disabled; pass --extra-experimental-features fetch-tree to enable it");
        return error.MissingExperimentalFeature;
    }
    return builtinFetchTree(self, arg);
}

pub fn builtinFetchTree(self: anytype, arg: Value) !Value {
    const attrs = try vm_force.forceValue(self, arg);
    if (attrs.isPath()) {
        const path = self.intern.get(attrs.asInternId());
        const out = try ingestFetchedTree(self, path, path_ops.baseName(path), "", null);
        defer out.deinit(self.allocator);
        return pathTreeValue(self, out.out_path, out.nar_hash);
    }
    if (attrs.isString()) {
        const parsed = try builtinParseFlakeRef(self, attrs);
        return builtinFetchTree(self, parsed);
    }
    if (!attrs.isAttrs()) return error.TypeError;

    // GC: `attrs` is held (via `attrs_id`) across the force-walking spec
    // helpers below. On the recursive path (`builtinParseFlakeRef` result) it
    // is a freshly built attrset that isn't the auto-rooted builtin argument.
    const gc_roots = vm_force.rootsBegin(self);
    defer vm_force.rootsEnd(self, gc_roots);
    vm_force.rootKeep(self, attrs);
    const attrs_id = attrs.asObjectId();
    const type_value = try requiredStringAttr(self, attrs_id, "type");
    defer self.allocator.free(type_value);

    // One span for the whole tree fetch (the network branches below); the
    // local `path` branch is fast, so a brief span there is harmless.
    const span = fetchSpanBegin(self, type_value);
    defer fetchSpanEnd(self, span);

    if (std.mem.eql(u8, type_value, "path")) {
        const path = try dupPathAttr(self, attrs_id, "path");
        defer self.allocator.free(path);
        const out = try ingestFetchedTree(self, path, path_ops.baseName(path), "", null);
        defer out.deinit(self.allocator);
        return pathTreeValue(self, out.out_path, out.nar_hash);
    }

    if (std.mem.eql(u8, type_value, "file")) {
        const spec = try fetchUrlSpecFromAttrs(self, attrs_id, null);
        defer spec.deinit(self.allocator);
        const result = try offloadFetch(self, FetchCache.fetchUrl, spec.borrowed(), span);
        defer result.deinit(self.fetchers.allocator);
        const path = try flatFetchOutPath(self, result.path, result.hash, spec.name);
        defer self.allocator.free(path);
        return fileTreeValue(self, path, result.hash);
    }

    if (std.mem.eql(u8, type_value, "tarball")) {
        const spec = try fetchUrlSpecFromAttrs(self, attrs_id, "source");
        defer spec.deinit(self.allocator);
        const result = try offloadFetch(self, FetchCache.fetchTarball, FetchCache.TarballSpec{ .url = spec.url, .name = spec.name }, span);
        defer result.deinit(self.fetchers.allocator);
        const out = try ingestFetchedTree(self, result.path, spec.name, "", null);
        defer out.deinit(self.allocator);
        return pathTreeValue(self, out.out_path, out.nar_hash);
    }

    if (std.mem.eql(u8, type_value, "git")) {
        const spec = try fetchGitSpecFromAttrs(self, attrs_id);
        defer spec.deinit(self.allocator);
        const result = try offloadFetch(self, FetchCache.fetchGit, spec.borrowed(), span);
        defer result.deinit(self.fetchers.allocator);
        return gitResultValue(self, spec.name, result);
    }

    if (std.mem.eql(u8, type_value, "github") or std.mem.eql(u8, type_value, "gitlab") or std.mem.eql(u8, type_value, "sourcehut")) {
        const spec = try forgeTreeSpec(self, attrs_id, type_value);
        defer spec.deinit(self.allocator);
        // Tag the fetch with the forge so `access-tokens` are applied with the
        // right per-forge auth header (as in Nix); other fetches get no token.
        const forge: FetchCache.Forge = if (std.mem.eql(u8, type_value, "github"))
            .github
        else if (std.mem.eql(u8, type_value, "gitlab"))
            .gitlab
        else
            .sourcehut;
        const result = try offloadFetch(self, FetchCache.fetchTarball, FetchCache.TarballSpec{ .url = spec.url, .name = spec.name, .forge = forge }, span);
        defer result.deinit(self.fetchers.allocator);
        const out = try ingestFetchedTree(self, result.path, spec.name, spec.rev orelse "", null);
        defer out.deinit(self.allocator);
        return githubTreeValue(self, out.out_path, out.nar_hash, spec.rev);
    }

    if (std.mem.eql(u8, type_value, "mercurial")) {
        const spec = try fetchMercurialSpecFromAttrs(self, attrs_id);
        defer spec.deinit(self.allocator);
        const result = try offloadFetch(self, FetchCache.fetchMercurial, spec.borrowed(), span);
        defer result.deinit(self.fetchers.allocator);
        return mercurialResultValue(self, spec.name, result);
    }

    return error.InvalidFlakeRef;
}

/// Gate for the flake builtins on the `flakes` experimental feature (Nix
/// parity). A hard eval error, like the `fetch-tree` gate: not catchable by
/// `builtins.tryEval`. `getFlake`/`parseFlakeRef` call each other and the
/// fetcher via their un-suffixed impls, so those internal calls bypass this.
fn requireFlakes(self: anytype) !void {
    if (!self.flakes_enabled) {
        try vm_trace.setErrorMessage(self, "flakes are disabled; pass --extra-experimental-features flakes to enable them");
        return error.MissingExperimentalFeature;
    }
}

pub fn builtinGetFlakeEntry(self: anytype, arg: Value) !Value {
    try requireFlakes(self);
    return builtinGetFlake(self, arg);
}

pub fn builtinParseFlakeRefEntry(self: anytype, arg: Value) !Value {
    try requireFlakes(self);
    return builtinParseFlakeRef(self, arg);
}

pub fn builtinFlakeRefToStringEntry(self: anytype, arg: Value) !Value {
    try requireFlakes(self);
    return builtinFlakeRefToString(self, arg);
}

pub fn builtinGetFlake(self: anytype, arg: Value) !Value {
    const ref = try stringArg(self, arg);
    const ref_value = Value.string(try self.intern.intern(ref));
    // GC: many intermediate flake values are held live across fetches / output
    // forces that can collect. Root everything created here until we return.
    const gc_roots = vm_force.rootsBegin(self);
    defer vm_force.rootsEnd(self, gc_roots);
    const parsed = try builtinParseFlakeRef(self, ref_value);
    vm_force.rootKeep(self, parsed);
    const source_info = try builtinFetchTree(self, parsed);
    vm_force.rootKeep(self, source_info);
    const out_path = try requiredStringAttr(self, source_info.asObjectId(), "outPath");
    defer self.allocator.free(out_path);
    // Subflake: `?dir=sub` puts flake.nix (and flake.lock) in a subdirectory.
    const dir = try optionalStringAttr(self, parsed.asObjectId(), "dir");
    defer if (dir) |d| self.allocator.free(d);

    const flake_value = try importFlakeValue(self, out_path, dir);
    vm_force.rootKeep(self, flake_value);
    const outputs_func = try flakeOutputs(self, flake_value);
    vm_force.rootKeep(self, outputs_func);

    // Inputs: from flake.lock (transitive, honoring `follows`) when present;
    // otherwise from the flake.nix `inputs` declarations (fetched unlocked).
    // Then add `self`.
    var input_entries: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer input_entries.deinit(self.allocator);
    if (!try resolveRootInputs(self, out_path, dir, &input_entries)) {
        try buildFlakeNixInputThunks(self, flake_value, &input_entries);
    }
    try input_entries.append(self.allocator, .{ .name = try self.intern.intern("self"), .value = try flakeSelfInput(self, source_info) });

    const inputs = Value.attrs(try self.heap.addAttrs(input_entries.items));
    vm_force.rootKeep(self, inputs);
    const outputs = try vm_force.forceValue(self, try vm_closures.callValue(self, outputs_func, inputs));
    if (!outputs.isAttrs()) return error.TypeError;

    return flakeResultValue(self, source_info, inputs, outputs);
}

/// Import + force the flake.nix attrset at `<out_path>[/dir]`.
fn importFlakeValue(self: anytype, out_path: []const u8, dir: ?[]const u8) !Value {
    const flake_path = if (dir) |d|
        try std.fs.path.join(self.allocator, &.{ out_path, d, "flake.nix" })
    else
        try std.fs.path.join(self.allocator, &.{ out_path, "flake.nix" });
    defer self.allocator.free(flake_path);
    const host = self.import_host orelse return error.ImportUnavailable;
    const flake_value = try vm_force.forceValue(self, try host.import_value(host.context, flake_path, self.native_depth));
    if (!flake_value.isAttrs()) return error.TypeError;
    return flake_value;
}

/// The (forced) `outputs` function of an imported flake attrset.
fn flakeOutputs(self: anytype, flake_value: Value) !Value {
    const outputs_id = try self.intern.intern("outputs");
    return vm_force.forceValue(self, try self.heap.getAttrValue(flake_value.asObjectId(), outputs_id));
}

/// Import the flake.nix at `<out_path>[/dir]` and return its (forced) `outputs`.
fn flakeOutputsFunc(self: anytype, out_path: []const u8, dir: ?[]const u8) !Value {
    return flakeOutputs(self, try importFlakeValue(self, out_path, dir));
}

/// Parse `<out_path>[/dir]/flake.lock` and resolve the root flake's declared
/// inputs into `out_entries` (each a fetched, evaluated input flake). Returns
/// false (leaving `out_entries` untouched) when there is no lock file, so the
/// caller can fall back to the flake.nix `inputs` declarations.
fn resolveRootInputs(self: anytype, out_path: []const u8, dir: ?[]const u8, out_entries: *std.ArrayListUnmanaged(heap_mod.AttrEntry)) !bool {
    const lock_path = if (dir) |d|
        try std.fs.path.join(self.allocator, &.{ out_path, d, "flake.lock" })
    else
        try std.fs.path.join(self.allocator, &.{ out_path, "flake.lock" });
    defer self.allocator.free(lock_path);
    const lock_data = self.files.readFile(lock_path) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };

    var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, lock_data, .{}) catch return error.InvalidFlakeLock;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidFlakeLock;
    const nodes_v = parsed.value.object.get("nodes") orelse return error.InvalidFlakeLock;
    const root_name_v = parsed.value.object.get("root") orelse return error.InvalidFlakeLock;
    if (nodes_v != .object or root_name_v != .string) return error.InvalidFlakeLock;
    const nodes = nodes_v.object;
    const root_name = root_name_v.string;

    const root_node = nodes.get(root_name) orelse return error.InvalidFlakeLock;
    if (root_node != .object) return error.InvalidFlakeLock;
    const root_inputs = root_node.object.get("inputs") orelse return true; // lock exists, flake has no inputs
    if (root_inputs != .object) return error.InvalidFlakeLock;

    var memo: std.StringHashMapUnmanaged(Value) = .empty;
    defer memo.deinit(self.allocator);

    var it = root_inputs.object.iterator();
    while (it.next()) |entry| {
        const target_node = try followInput(nodes, root_name, entry.value_ptr.*);
        const thunk = try buildNodeThunk(self, nodes, target_node, root_name, &memo, 0);
        try out_entries.append(self.allocator, .{ .name = try self.intern.intern(entry.key_ptr.*), .value = thunk });
    }
    return true;
}

/// Lockless: build a lazy thunk for each of a flake's flake.nix `inputs`
/// declarations. Each input is a flakeref string, `{ url = …; }`, or an inline
/// ref attrset; `flake = false` yields the bare source. `sub_inputs` is passed
/// as null so `resolveFlakeNode`, on force, builds the input flake's own
/// sub-inputs from its flake.nix (recursively, also lazily). Because each input
/// is a thunk, an input an output never touches is never fetched.
fn buildFlakeNixInputThunks(self: anytype, flake_value: Value, out_entries: *std.ArrayListUnmanaged(heap_mod.AttrEntry)) !void {
    const inputs_id = try self.intern.intern("inputs");
    const inputs_v = (self.heap.getAttrValueOpt(flake_value.asObjectId(), inputs_id) catch return) orelse return;
    const inputs = try vm_force.forceValue(self, inputs_v);
    if (!inputs.isAttrs()) return;

    for (try self.heap.getAttrs(inputs.asObjectId())) |entry| {
        const decl = try vm_force.forceValue(self, entry.value);
        const as_flake = if (decl.isAttrs())
            (try optionalBoolAttr(self, decl.asObjectId(), "flake")) orelse true
        else
            true;
        const ref_attrs: Value = if (decl.isString() or decl.isPath())
            try builtinParseFlakeRef(self, decl)
        else if (decl.isAttrs()) blk: {
            if (try self.heap.getAttrValueOpt(decl.asObjectId(), try self.intern.intern("url"))) |u| {
                break :blk try builtinParseFlakeRef(self, try vm_force.forceValue(self, u));
            }
            break :blk decl; // already a {type=…} ref attrset
        } else return error.InvalidFlakeRef;
        vm_force.rootKeep(self, ref_attrs);
        const thunk = try shared.makeBuiltinThunk(self, .resolve_flake_node, &.{ ref_attrs, Value.null_val, Value.boolVal(as_flake) });
        vm_force.rootKeep(self, thunk);
        try out_entries.append(self.allocator, .{ .name = entry.name, .value = thunk });
    }
}

/// Internal builtin backing a lazy flake input (`inputs.<name>`): forced only
/// when the input is used, so unused inputs are never fetched. Fetches
/// `ref_attrs` and, if it's a flake, evaluates its outputs. `sub_inputs` is the
/// pre-built input thunks from the lock, or null — in which case the input
/// flake's own sub-inputs are built (lazily) from its fetched flake.nix.
pub fn resolveFlakeNode(self: anytype, ref_attrs: Value, sub_inputs: Value, is_flake: Value) anyerror!Value {
    const gc_roots = vm_force.rootsBegin(self);
    defer vm_force.rootsEnd(self, gc_roots);
    vm_force.rootKeep(self, ref_attrs);
    vm_force.rootKeep(self, sub_inputs);

    // Skip the download+ingest when the locked narHash's store path is already
    // valid (Nix pins inputs by narHash; a valid CA path IS the content).
    const src_info = (try flakeInputFromStore(self, ref_attrs)) orelse try builtinFetchTree(self, ref_attrs);
    vm_force.rootKeep(self, src_info);
    try verifyLockedNarHash(self, ref_attrs, src_info);
    if (!is_flake.asBool()) return src_info; // `flake = false`

    const src_out = try requiredStringAttr(self, src_info.asObjectId(), "outPath");
    defer self.allocator.free(src_out);
    const dir = try optionalStringAttr(self, ref_attrs.asObjectId(), "dir");
    defer if (dir) |d| self.allocator.free(d);
    const fnix_path = if (dir) |d|
        try std.fs.path.join(self.allocator, &.{ src_out, d, "flake.nix" })
    else
        try std.fs.path.join(self.allocator, &.{ src_out, "flake.nix" });
    defer self.allocator.free(fnix_path);
    if (!(self.files.pathExists(fnix_path) catch false)) return src_info; // non-flake source

    const flake_value = try importFlakeValue(self, src_out, dir);
    vm_force.rootKeep(self, flake_value);
    const outputs_func = try flakeOutputs(self, flake_value);
    vm_force.rootKeep(self, outputs_func);

    var entries: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer entries.deinit(self.allocator);
    if (sub_inputs.isAttrs()) {
        for (try self.heap.getAttrs(sub_inputs.asObjectId())) |e| try entries.append(self.allocator, e);
    } else {
        try buildFlakeNixInputThunks(self, flake_value, &entries);
    }
    try entries.append(self.allocator, .{ .name = try self.intern.intern("self"), .value = try flakeSelfInput(self, src_info) });
    const inputs = Value.attrs(try self.heap.addAttrs(entries.items));
    vm_force.rootKeep(self, inputs);
    const outputs = try vm_force.forceValue(self, try vm_closures.callValue(self, outputs_func, inputs));
    if (!outputs.isAttrs()) return error.TypeError;
    return flakeResultValue(self, src_info, inputs, outputs);
}

/// Resolve `input_target` (a node name string, or a `follows` path array from
/// the root) to a concrete node name.
fn followInput(nodes: std.json.ObjectMap, root_name: []const u8, input_target: std.json.Value) error{InvalidFlakeLock}![]const u8 {
    switch (input_target) {
        .string => |s| return s,
        .array => |arr| {
            var cur = root_name;
            for (arr.items) |elem| {
                if (elem != .string) return error.InvalidFlakeLock;
                const node = nodes.get(cur) orelse return error.InvalidFlakeLock;
                if (node != .object) return error.InvalidFlakeLock;
                const ins = node.object.get("inputs") orelse return error.InvalidFlakeLock;
                if (ins != .object) return error.InvalidFlakeLock;
                const next = ins.object.get(elem.string) orelse return error.InvalidFlakeLock;
                cur = try followInput(nodes, root_name, next);
            }
            return cur;
        },
        else => return error.InvalidFlakeLock,
    }
}

/// Fetch + evaluate one locked node into an input value: a flake value when the
/// input has a flake.nix (and isn't `flake = false`), else the bare fetched
/// source. Memoized per node so shared inputs (diamonds) resolve once.
/// Build a lazy thunk for one locked node (fetched + evaluated only on force).
/// Its own inputs are pre-built as thunks — cheap, no fetching — and handed to
/// `resolveFlakeNode`, so the whole lock graph is lazy. Memoized by node name so
/// a shared node (a diamond) is a single thunk, forced at most once.
fn buildNodeThunk(self: anytype, nodes: std.json.ObjectMap, node_name: []const u8, root_name: []const u8, memo: *std.StringHashMapUnmanaged(Value), depth: u32) !Value {
    if (memo.get(node_name)) |t| return t;
    if (depth > 256) return error.InvalidFlakeLock; // runaway / cyclic lock guard

    const node_v = nodes.get(node_name) orelse return error.InvalidFlakeLock;
    if (node_v != .object) return error.InvalidFlakeLock;
    const node = node_v.object;

    const locked_v = node.get("locked") orelse return error.InvalidFlakeLock;
    if (locked_v != .object) return error.InvalidFlakeLock;
    const ref_attrs = try jsonObjectToAttrs(self, locked_v.object);
    vm_force.rootKeep(self, ref_attrs);

    const is_flake = switch (node.get("flake") orelse std.json.Value{ .bool = true }) {
        .bool => |b| b,
        else => true,
    };

    // Pre-build this node's input thunks from the lock graph (no fetching).
    var sub_entries: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer sub_entries.deinit(self.allocator);
    if (node.get("inputs")) |ins| if (ins == .object) {
        var it = ins.object.iterator();
        while (it.next()) |e| {
            const tnode = try followInput(nodes, root_name, e.value_ptr.*);
            const sub_thunk = try buildNodeThunk(self, nodes, tnode, root_name, memo, depth + 1);
            try sub_entries.append(self.allocator, .{ .name = try self.intern.intern(e.key_ptr.*), .value = sub_thunk });
        }
    };
    const sub_inputs = Value.attrs(try self.heap.addAttrs(sub_entries.items));
    vm_force.rootKeep(self, sub_inputs);

    const thunk = try shared.makeBuiltinThunk(self, .resolve_flake_node, &.{ ref_attrs, sub_inputs, Value.boolVal(is_flake) });
    vm_force.rootKeep(self, thunk);
    try memo.put(self.allocator, node_name, thunk);
    return thunk;
}

/// Verify a fetched input's NAR hash against the lock, as Nix does — a mismatch
/// means the locked content changed under the pin (corruption / tampering).
/// Only under store writes, where fix computes the real NAR hash (plain eval
/// uses an offline synthetic), and only for the tree types whose NAR hash is
/// confirmed to match Nix (forges/tarball/path); git/mercurial/file are skipped.
fn verifyLockedNarHash(self: anytype, ref_attrs: Value, src_info: Value) !void {
    if (!self.derivations.store_writes_enabled) return;
    if (!ref_attrs.isAttrs()) return;
    const ty = (try optionalStringAttr(self, ref_attrs.asObjectId(), "type")) orelse return;
    defer self.allocator.free(ty);
    const verifiable = std.mem.eql(u8, ty, "github") or std.mem.eql(u8, ty, "gitlab") or
        std.mem.eql(u8, ty, "sourcehut") or std.mem.eql(u8, ty, "tarball") or
        std.mem.eql(u8, ty, "path") or std.mem.eql(u8, ty, "git");
    if (!verifiable) return;
    const locked = (try optionalStringAttr(self, ref_attrs.asObjectId(), "narHash")) orelse return;
    defer self.allocator.free(locked);
    const got = (try optionalStringAttr(self, src_info.asObjectId(), "narHash")) orelse return;
    defer self.allocator.free(got);
    if (!std.mem.eql(u8, locked, got)) {
        try vm_trace.setErrorMessage(self, "flake input NAR hash mismatch: lock does not match fetched content");
        return error.FlakeNarHashMismatch;
    }
}

/// If store writes are enabled and this ref's narHash names a store path that is
/// already valid, return the equivalent tree value directly — skipping the
/// download + ingest. Fail-open: any miss (no narHash, unsupported type,
/// unparseable hash, path not valid) returns null and the caller fetches.
/// Reuses the same store-path scheme (`sourcePath`) and value constructors the
/// real fetch would, so a skipped fetch is indistinguishable from a real one.
fn flakeInputFromStore(self: anytype, attrs: Value) !?Value {
    if (!self.derivations.store_writes_enabled) return null;
    if (!attrs.isAttrs()) return null;
    const id = attrs.asObjectId();
    const nar_hash = (try optionalStringAttr(self, id, "narHash")) orelse return null;
    defer self.allocator.free(nar_hash);
    const ty = (try optionalStringAttr(self, id, "type")) orelse return null;
    defer self.allocator.free(ty);

    // Recursive-NAR (sourcePath) inputs only: forges/tarball/path. git/mercurial
    // ingest differently and are left to fetch; file is flat, not a tree.
    const is_forge = std.mem.eql(u8, ty, "github") or std.mem.eql(u8, ty, "gitlab") or std.mem.eql(u8, ty, "sourcehut");
    const is_tarball = std.mem.eql(u8, ty, "tarball");
    const is_path = std.mem.eql(u8, ty, "path");
    if (!is_forge and !is_tarball and !is_path) return null;

    // The store-path name must match what the fetch would use (see builtinFetchTree).
    const path_attr = if (is_path) (try optionalStringAttr(self, id, "path")) else null;
    defer if (path_attr) |p| self.allocator.free(p);
    const name_attr = if (!is_path) (try optionalStringAttr(self, id, "name")) else null;
    defer if (name_attr) |n| self.allocator.free(n);
    const name = if (is_path)
        (if (path_attr) |p| path_ops.baseName(p) else return null)
    else
        (name_attr orelse "source");

    const hex = derivation.hashToBase16(self.allocator, "sha256", nar_hash) catch return null;
    defer self.allocator.free(hex);
    const store_path = try derivation.sourcePath(self.allocator, self.derivations.store_dir, name, hex);
    defer self.allocator.free(store_path);
    if (!try self.derivations.pathIsValid(store_path)) return null;

    if (is_forge) {
        const rev = try optionalStringAttr(self, id, "rev");
        defer if (rev) |r| self.allocator.free(r);
        return try githubTreeValue(self, store_path, nar_hash, rev);
    }
    return try pathTreeValue(self, store_path, nar_hash);
}

/// Build a Nix attrset from a flake.lock `locked` node's JSON (string + integer
/// fields — type/owner/repo/rev/url/path/narHash/lastModified/...), suitable as
/// input to `builtinFetchTree`.
fn jsonObjectToAttrs(self: anytype, obj: std.json.ObjectMap) !Value {
    var entries: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer entries.deinit(self.allocator);
    var it = obj.iterator();
    while (it.next()) |e| {
        const v: Value = switch (e.value_ptr.*) {
            .string => |s| Value.string(try self.intern.intern(s)),
            .integer => |n| Value.int(n),
            else => continue, // skip bools/null/nested — fetch specs only read strings/ints
        };
        try entries.append(self.allocator, .{ .name = try self.intern.intern(e.key_ptr.*), .value = v });
    }
    return Value.attrs(try self.heap.addAttrs(entries.items));
}

fn flakeSelfInput(self: anytype, source_info: Value) !Value {
    var entries: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer entries.deinit(self.allocator);
    try entries.append(self.allocator, .{ .name = try self.intern.intern("_type"), .value = Value.string(try self.intern.intern("flake")) });
    try entries.append(self.allocator, .{ .name = try self.intern.intern("sourceInfo"), .value = source_info });
    // Promote the sourceInfo fields onto `self`, as Nix does — flakes (nixpkgs
    // among them) read `self.lastModified`, `self.rev`, etc. directly.
    const source_id = source_info.asObjectId();
    for ([_][]const u8{ "outPath", "narHash", "lastModified", "lastModifiedDate", "rev", "revCount", "shortRev" }) |field| {
        try appendExistingAttr(self, &entries, source_id, field);
    }
    return Value.attrs(try self.heap.addAttrs(entries.items));
}

fn flakeResultValue(self: anytype, source_info: Value, inputs: Value, outputs: Value) !Value {
    var entries: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer entries.deinit(self.allocator);

    try entries.append(self.allocator, .{ .name = try self.intern.intern("_type"), .value = Value.string(try self.intern.intern("flake")) });
    try entries.append(self.allocator, .{ .name = try self.intern.intern("inputs"), .value = inputs });
    try entries.append(self.allocator, .{ .name = try self.intern.intern("outputs"), .value = outputs });
    try entries.append(self.allocator, .{ .name = try self.intern.intern("sourceInfo"), .value = source_info });

    const source_attrs_id = source_info.asObjectId();
    try appendExistingAttr(self, &entries, source_attrs_id, "lastModified");
    try appendExistingAttr(self, &entries, source_attrs_id, "lastModifiedDate");
    try appendExistingAttr(self, &entries, source_attrs_id, "narHash");
    try appendExistingAttr(self, &entries, source_attrs_id, "outPath");
    try appendExistingAttr(self, &entries, source_attrs_id, "rev");
    try appendExistingAttr(self, &entries, source_attrs_id, "shortRev");

    for (try self.heap.getAttrs(outputs.asObjectId())) |entry| {
        if (attrEntryNameIndex(entries.items, entry.name) == null) {
            try entries.append(self.allocator, entry);
        }
    }
    return Value.attrs(try self.heap.addAttrs(entries.items));
}

fn appendExistingAttr(self: anytype, entries: *std.ArrayListUnmanaged(heap_mod.AttrEntry), attrs_id: ObjectId, name: []const u8) !void {
    const name_id = try self.intern.intern(name);
    const value = self.heap.getAttrValue(attrs_id, name_id) catch |err| switch (err) {
        error.MissingAttribute => return,
        else => return err,
    };
    try entries.append(self.allocator, .{ .name = name_id, .value = value });
}

/// A 40-char lowercase-hex git revision (as opposed to a branch/tag `ref`).
fn looksLikeGitRev(s: []const u8) bool {
    if (s.len != 40) return false;
    for (s) |c| if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) return false;
    return true;
}

pub fn builtinParseFlakeRef(self: anytype, arg: Value) !Value {
    const ref = try stringArg(self, arg);
    var entries: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer entries.deinit(self.allocator);

    // Query string (`?dir=…&rev=…`) applies to every scheme; split it off first
    // so it never leaks into a path/repo/url segment.
    const q_idx = std.mem.indexOfScalar(u8, ref, '?');
    const base = if (q_idx) |i| ref[0..i] else ref;
    const query = if (q_idx) |i| ref[i + 1 ..] else "";

    // Shorthand forge refs: github:/gitlab:/sourcehut: owner/repo[/refOrRev].
    inline for (.{ "github", "gitlab", "sourcehut" }) |forge| {
        if (std.mem.startsWith(u8, base, forge ++ ":")) {
            try appendStringAttr(self, &entries, "type", forge);
            var parts = std.mem.splitScalar(u8, base[forge.len + 1 ..], '/');
            const owner = parts.next() orelse return error.InvalidFlakeRef;
            const repo = parts.next() orelse return error.InvalidFlakeRef;
            try appendStringAttr(self, &entries, "owner", owner);
            try appendStringAttr(self, &entries, "repo", repo);
            if (parts.next()) |seg| if (seg.len != 0) {
                try appendStringAttr(self, &entries, if (looksLikeGitRev(seg)) "rev" else "ref", seg);
            };
            try appendFlakeQueryAttrs(self, &entries, query);
            return Value.attrs(try self.heap.addAttrs(entries.items));
        }
    }

    // git+<transport> / bare git:/ssh: → a git flake; the URL is what git clones.
    if (std.mem.startsWith(u8, base, "git+")) {
        try appendStringAttr(self, &entries, "type", "git");
        try appendStringAttr(self, &entries, "url", base["git+".len..]);
        try appendFlakeQueryAttrs(self, &entries, query);
        return Value.attrs(try self.heap.addAttrs(entries.items));
    }
    if (std.mem.startsWith(u8, base, "git://") or std.mem.startsWith(u8, base, "ssh://")) {
        try appendStringAttr(self, &entries, "type", "git");
        try appendStringAttr(self, &entries, "url", base);
        try appendFlakeQueryAttrs(self, &entries, query);
        return Value.attrs(try self.heap.addAttrs(entries.items));
    }

    // tarball+<url>, or a bare http(s) URL (Nix treats bare http(s) as a tarball).
    if (std.mem.startsWith(u8, base, "tarball+")) {
        try appendStringAttr(self, &entries, "type", "tarball");
        try appendStringAttr(self, &entries, "url", base["tarball+".len..]);
        try appendFlakeQueryAttrs(self, &entries, query);
        return Value.attrs(try self.heap.addAttrs(entries.items));
    }
    if (std.mem.startsWith(u8, base, "http://") or std.mem.startsWith(u8, base, "https://")) {
        try appendStringAttr(self, &entries, "type", "tarball");
        try appendStringAttr(self, &entries, "url", base);
        try appendFlakeQueryAttrs(self, &entries, query);
        return Value.attrs(try self.heap.addAttrs(entries.items));
    }

    // path: / bare absolute path.
    if (std.mem.startsWith(u8, base, "path:")) {
        try appendStringAttr(self, &entries, "type", "path");
        try appendStringAttr(self, &entries, "path", base["path:".len..]);
        try appendFlakeQueryAttrs(self, &entries, query);
        return Value.attrs(try self.heap.addAttrs(entries.items));
    }
    if (std.fs.path.isAbsolute(base)) {
        try appendStringAttr(self, &entries, "type", "path");
        try appendStringAttr(self, &entries, "path", base);
        try appendFlakeQueryAttrs(self, &entries, query);
        return Value.attrs(try self.heap.addAttrs(entries.items));
    }

    // Bare indirect id (`nixpkgs`, `nixpkgs/nixos-24.05`): resolve through the
    // flake registry to a concrete ref, re-attach the query, and re-parse.
    if (try flake_registry.resolve(self, base)) |concrete| {
        defer self.allocator.free(concrete);
        const full = if (q_idx != null)
            try std.fmt.allocPrint(self.allocator, "{s}?{s}", .{ concrete, query })
        else
            try self.allocator.dupe(u8, concrete);
        defer self.allocator.free(full);
        return builtinParseFlakeRef(self, Value.string(try self.intern.intern(full)));
    }
    return error.InvalidFlakeRef;
}

pub fn builtinFlakeRefToString(self: anytype, arg: Value) !Value {
    const attrs = try vm_force.forceValue(self, arg);
    if (!attrs.isAttrs()) return error.TypeError;

    const type_value = try requiredStringAttr(self, attrs.asObjectId(), "type");
    defer self.allocator.free(type_value);
    if (std.mem.eql(u8, type_value, "github")) {
        const owner = try requiredStringAttr(self, attrs.asObjectId(), "owner");
        defer self.allocator.free(owner);
        const repo = try requiredStringAttr(self, attrs.asObjectId(), "repo");
        defer self.allocator.free(repo);
        const ref = try optionalStringAttr(self, attrs.asObjectId(), "ref");
        defer if (ref) |owned| self.allocator.free(owned);
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(self.allocator);
        const base = if (ref) |branch|
            try std.fmt.allocPrint(self.allocator, "github:{s}/{s}/{s}", .{ owner, repo, branch })
        else
            try std.fmt.allocPrint(self.allocator, "github:{s}/{s}", .{ owner, repo });
        defer self.allocator.free(base);
        try out.appendSlice(self.allocator, base);
        // Query params (Nix appends `dir` / `host` as `?key=val`).
        var first_query = true;
        try appendFlakeQueryString(self, attrs.asObjectId(), "host", &out, &first_query);
        try appendFlakeQueryString(self, attrs.asObjectId(), "dir", &out, &first_query);
        return Value.string(try self.intern.intern(out.items));
    }

    if (std.mem.eql(u8, type_value, "path")) {
        const path = try requiredStringAttr(self, attrs.asObjectId(), "path");
        defer self.allocator.free(path);
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(self.allocator);
        try out.appendSlice(self.allocator, "path:");
        try out.appendSlice(self.allocator, path);
        var first_query = true;
        try appendFlakeQueryString(self, attrs.asObjectId(), "ref", &out, &first_query);
        try appendFlakeQueryString(self, attrs.asObjectId(), "rev", &out, &first_query);
        try appendFlakeQueryString(self, attrs.asObjectId(), "narHash", &out, &first_query);
        return Value.string(try self.intern.intern(out.items));
    }

    return error.InvalidFlakeRef;
}

fn appendFlakeQueryAttrs(self: anytype, entries: *std.ArrayListUnmanaged(heap_mod.AttrEntry), query: []const u8) !void {
    var parts = std.mem.splitScalar(u8, query, '&');
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse continue;
        const key = part[0..eq];
        const value = part[eq + 1 ..];
        inline for (.{ "ref", "rev", "narHash", "dir", "host", "submodules" }) |known| {
            if (std.mem.eql(u8, key, known)) {
                try appendStringAttr(self, entries, key, value);
                break;
            }
        }
    }
}

fn appendFlakeQueryString(self: anytype, attrs_id: ObjectId, name: []const u8, out: *std.ArrayListUnmanaged(u8), first: *bool) !void {
    const value = try optionalStringAttr(self, attrs_id, name) orelse return;
    defer self.allocator.free(value);
    try out.append(self.allocator, if (first.*) '?' else '&');
    first.* = false;
    try out.appendSlice(self.allocator, name);
    try out.append(self.allocator, '=');
    try out.appendSlice(self.allocator, value);
}

fn appendStringAttr(self: anytype, entries: *std.ArrayListUnmanaged(heap_mod.AttrEntry), name: []const u8, value: []const u8) !void {
    try entries.append(self.allocator, .{
        .name = try self.intern.intern(name),
        .value = Value.string(try self.intern.intern(value)),
    });
}

fn defaultFetchName(self: anytype, url: []const u8) ![]u8 {
    const basename = path_ops.baseName(url);
    if (basename.len != 0) return self.allocator.dupe(u8, basename);
    return self.allocator.dupe(u8, "source");
}

fn dupPathAttr(self: anytype, attrs_id: ObjectId, name: []const u8) ![]u8 {
    const name_id = try self.intern.intern(name);
    const value = try vm_force.forceValue(self, try self.heap.getAttrValue(attrs_id, name_id));
    return switch (value.kind()) {
        .path, .string, .string_context => self.allocator.dupe(u8, self.intern.get(try stringTextInternId(self, value))),
        else => error.TypeError,
    };
}

fn optionalStringAttr(self: anytype, attrs_id: ObjectId, name: []const u8) !?[]u8 {
    const name_id = try self.intern.intern(name);
    const value = self.heap.getAttrValue(attrs_id, name_id) catch |err| switch (err) {
        error.MissingAttribute => return null,
        else => return err,
    };
    const forced = try vm_force.forceValue(self, value);
    if (!isPlainString(forced)) return error.TypeError;
    return try self.allocator.dupe(u8, self.intern.get(try stringTextInternId(self, forced)));
}

fn requiredStringAttr(self: anytype, attrs_id: ObjectId, name: []const u8) ![]u8 {
    return try optionalStringAttr(self, attrs_id, name) orelse error.MissingAttribute;
}

fn optionalBoolAttr(self: anytype, attrs_id: ObjectId, name: []const u8) !?bool {
    const name_id = try self.intern.intern(name);
    const value = self.heap.getAttrValue(attrs_id, name_id) catch |err| switch (err) {
        error.MissingAttribute => return null,
        else => return err,
    };
    const forced = try vm_force.forceValue(self, value);
    if (!forced.isBool()) return error.TypeError;
    return forced.asBool();
}

pub fn filterSourceAccepts(self: anytype, pred: Value, path: []const u8, kind: file_cache.FileCache.FileKind) !bool {
    const path_value = Value.string(try self.intern.intern(path));
    const kind_value = Value.string(try self.intern.intern(kind.nixTypeName()));
    const partial = try vm_closures.callValue(self, pred, path_value);
    const result = try vm_force.forceValue(self, try vm_closures.callValue(self, partial, kind_value));
    if (!result.isBool()) return error.TypeError;
    return result.asBool();
}
