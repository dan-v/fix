//! Network fetch builtins and fetched-source realization.

const std = @import("std");
const VM = @import("../context.zig").VM;
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const InternId = types.InternId;
const ObjectId = types.ObjectId;
const heap_mod = @import("runtime").heap;
const file_cache = @import("../../host.zig").file_cache;
const fetch_cache = @import("../../host.zig").fetch_cache;
const derivation = @import("../../derivation.zig");
const nar = @import("../../host.zig").nar;
const path_ops = @import("runtime").paths;
const source_paths = @import("../../realization.zig").source_path;
const eval_progress = @import("../../observ.zig").progress;
const shared = @import("shared.zig");
const strings = @import("strings.zig");
const string_context = @import("string_context.zig");
const arguments = @import("arguments.zig");
const vm_force = @import("../force.zig");
const vm_trace = @import("../trace.zig");

const contextStringWithPath = string_context.contextStringWithPath;
const pathArg = strings.pathArg;
const sourcePathStringValue = strings.sourcePathStringValue;
const stringArg = strings.stringArg;
const appendStringAttr = arguments.appendStringAttr;
const dupPathAttr = arguments.dupPathAttr;
const optionalStringAttr = arguments.optionalStringAttr;
const requiredStringAttr = arguments.requiredStringAttr;
const optionalBoolAttr = arguments.optionalBoolAttr;

pub const FetchGitSpec = struct {
    url: []u8,
    name: []u8,
    rev: ?[]u8,
    ref: ?[]u8,
    submodules: bool,

    pub fn deinit(self: FetchGitSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        allocator.free(self.name);
        if (self.rev) |rev| allocator.free(rev);
        if (self.ref) |ref| allocator.free(ref);
    }

    pub fn borrowed(self: FetchGitSpec) fetch_cache.FetchCache.GitSpec {
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
pub const FetchedOut = struct {
    out_path: []u8,
    nar_hash: []u8,

    pub fn deinit(self: FetchedOut, allocator: std.mem.Allocator) void {
        allocator.free(self.out_path);
        allocator.free(self.nar_hash);
    }
};

pub fn ingestFetchedTree(self: *VM, cache_path: []const u8, name: []const u8, rev: []const u8, filter: ?nar.Filter) !FetchedOut {
    _ = rev;
    if (self.realization.storeWritesEnabled()) {
        // Fetched trees carry no user-lambda filter identity, so they are never
        // filter-memoized (pass null); a null `filter` is unfiltered-memoized.
        const ingested = try source_paths.ingest(self.allocator, self.realization, self.files, cache_path, name, filter, null);
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
fn fetchedPathValue(self: *VM, path: []const u8) !Value {
    const id = try self.intern.intern(path);
    return if (self.realization.storeWritesEnabled())
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

pub fn mercurialResultValue(self: *VM, name: []const u8, result: fetch_cache.FetchCache.MercurialResult) !Value {
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
pub fn fetchSpanBegin(self: *VM, subject: []const u8) ?eval_progress.Span {
    const spans = self.progress_spans orelse return null;
    return spans.beginSpan(.fetch, subject);
}

pub fn fetchSpanEnd(self: *VM, span: ?eval_progress.Span) void {
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
pub fn offloadFetch(self: *VM, comptime call: anytype, spec: anytype, span: ?eval_progress.Span) anyerror!@typeInfo(@typeInfo(@TypeOf(call)).@"fn".return_type.?).error_union.payload {
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

pub fn builtinFetchGit(self: *VM, arg: Value) !Value {
    const spec = try fetchGitSpec(self, arg);
    defer spec.deinit(self.allocator);

    const span = fetchSpanBegin(self, spec.url);
    defer fetchSpanEnd(self, span);
    const result = try offloadFetch(self, FetchCache.fetchGit, spec.borrowed(), span);
    defer result.deinit(self.fetchers.allocator);
    return gitResultValue(self, spec.name, result);
}

pub fn gitResultValue(self: *VM, name: []const u8, result: fetch_cache.FetchCache.GitResult) !Value {
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
fn treeNarHashValue(self: *VM, path: []const u8, nar_hash: []const u8, exclude: []const u8) !Value {
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
pub fn computeNarHash(self: *VM, path_value: Value, exclude_value: Value) !Value {
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

pub fn pathTreeValue(self: *VM, path: []const u8, nar_hash: []const u8) !Value {
    const entries = [_]heap_mod.AttrEntry{
        .{ .name = try self.intern.intern("lastModified"), .value = Value.int(0) },
        .{ .name = try self.intern.intern("lastModifiedDate"), .value = Value.string(try self.intern.intern("19700101000000")) },
        .{ .name = try self.intern.intern("narHash"), .value = try treeNarHashValue(self, path, nar_hash, "") },
        .{ .name = try self.intern.intern("outPath"), .value = try fetchedPathValue(self, path) },
    };
    return Value.attrs(try self.heap.addAttrs(&entries));
}

pub fn fileTreeValue(self: *VM, path: []const u8, nar_hash: []const u8) !Value {
    const entries = [_]heap_mod.AttrEntry{
        .{ .name = try self.intern.intern("narHash"), .value = Value.string(try self.intern.intern(nar_hash)) },
        .{ .name = try self.intern.intern("outPath"), .value = try fetchedPathValue(self, path) },
    };
    return Value.attrs(try self.heap.addAttrs(&entries));
}

fn fetchGitSpec(self: *VM, arg: Value) !FetchGitSpec {
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

pub fn fetchGitSpecFromAttrs(self: *VM, attrs_id: ObjectId) !FetchGitSpec {
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

pub const FetchUrlSpec = struct {
    url: []u8,
    name: []u8,

    pub fn deinit(self: FetchUrlSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        allocator.free(self.name);
    }

    pub fn borrowed(self: FetchUrlSpec) fetch_cache.FetchCache.UrlSpec {
        return .{ .url = self.url, .name = self.name };
    }
};

pub fn builtinFetchurl(self: *VM, arg: Value) !Value {
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
        if (!self.realization.storeWritesEnabled()) {
            const store_path = try derivation.fixedOutputPath(self.allocator, self.realization.store_dir, spec.name, "out", "sha256", expected);
            defer self.allocator.free(store_path);
            try self.realization.recordPendingFetch(store_path, spec.url, spec.name, false, expected);
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

fn expectedFetchSha256Hex(self: *VM, arg: Value) !?[]u8 {
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

fn validateFetchedSha256(self: *VM, noun: []const u8, url: []const u8, expected_hex: ?[]const u8, actual_hex: []const u8) !void {
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
pub fn flatFetchOutPath(self: *VM, cache_path: []const u8, hash_hex: []const u8, name: []const u8) ![]u8 {
    // The flat store path is determined by the content hash regardless of store
    // writes; only the store instantiation is gated on them.
    const store_path = try derivation.fixedOutputPath(self.allocator, self.realization.store_dir, name, "out", "sha256", hash_hex);
    errdefer self.allocator.free(store_path);
    var contents = try self.files.retainFile(cache_path);
    defer contents.release();
    if (!self.realization.storeWritesEnabled()) {
        // Plain eval has no store to materialize the file; seed the cache so
        // `readFile`/`import` on the returned store path stays zero-copy.
        try self.files.provideRegular(store_path, contents);
    }
    // A fetched flat file reports under `.fetch` (at download), not `.source`.
    try self.realization.recordFlatRecipe(store_path, contents, null);
    return store_path;
}

/// Reject any attr not in `allowed`, matching Nix's argument validation for
/// the simple fetchers.
fn rejectUnknownFetchAttrs(self: *VM, attrs_id: ObjectId, comptime allowed: []const []const u8) !void {
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

fn fetchUrlSpec(self: *VM, arg: Value) !FetchUrlSpec {
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

pub fn fetchUrlSpecFromAttrs(self: *VM, attrs_id: ObjectId, default_name: ?[]const u8) !FetchUrlSpec {
    const url = try dupPathAttr(self, attrs_id, "url");
    errdefer self.allocator.free(url);
    const name = try optionalStringAttr(self, attrs_id, "name") orelse if (default_name) |name|
        try self.allocator.dupe(u8, name)
    else
        try defaultFetchName(self, url);
    return .{ .url = url, .name = name };
}

pub fn builtinFetchTarball(self: *VM, arg: Value) !Value {
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
        if (!self.realization.storeWritesEnabled()) {
            const store_path = try derivation.sourcePath(self.allocator, self.realization.store_dir, tree_name, expected);
            defer self.allocator.free(store_path);
            try self.realization.recordPendingFetch(store_path, spec.url, tree_name, true, expected);
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
        if (self.realization.storeWritesEnabled()) {
            const ingested = try source_paths.ingestSerializedNar(
                self.allocator,
                self.realization,
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
        const store_path = try derivation.sourcePath(self.allocator, self.realization.store_dir, tree_name, &nar_hex);
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
pub fn materializePendingFetch(self: *VM, demanded_path: []const u8) !bool {
    const store_root = storeRootOf(demanded_path, self.realization.store_dir) orelse return false;
    // `peekPendingFetch` clones with the store's allocator; free with the same.
    var pending = (try self.realization.peekPendingFetch(store_root)) orelse return false;
    defer pending.deinit(self.realization.allocator);

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
    self.realization.removePendingFetch(store_root);
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
fn tarballTreeName(self: *VM, arg: Value) ![]u8 {
    const value = try vm_force.forceValue(self, arg);
    if (value.isAttrs()) {
        if (try optionalStringAttr(self, value.asObjectId(), "name")) |name| return name;
    }
    return self.allocator.dupe(u8, "source");
}

pub const FetchMercurialSpec = struct {
    url: []u8,
    name: []u8,
    rev: ?[]u8,

    pub fn deinit(self: FetchMercurialSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        allocator.free(self.name);
        if (self.rev) |rev| allocator.free(rev);
    }

    pub fn borrowed(self: FetchMercurialSpec) fetch_cache.FetchCache.MercurialSpec {
        return .{ .url = self.url, .name = self.name, .rev = self.rev };
    }
};

pub fn builtinFetchMercurial(self: *VM, arg: Value) !Value {
    const spec = try fetchMercurialSpec(self, arg);
    defer spec.deinit(self.allocator);

    const span = fetchSpanBegin(self, spec.url);
    defer fetchSpanEnd(self, span);
    const result = try offloadFetch(self, FetchCache.fetchMercurial, spec.borrowed(), span);
    defer result.deinit(self.fetchers.allocator);
    return mercurialResultValue(self, spec.name, result);
}

fn fetchMercurialSpec(self: *VM, arg: Value) !FetchMercurialSpec {
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

pub fn fetchMercurialSpecFromAttrs(self: *VM, attrs_id: ObjectId) !FetchMercurialSpec {
    const url = try dupPathAttr(self, attrs_id, "url");
    errdefer self.allocator.free(url);
    const name = try optionalStringAttr(self, attrs_id, "name") orelse try self.allocator.dupe(u8, "source");
    errdefer self.allocator.free(name);
    const rev = try optionalStringAttr(self, attrs_id, "rev");
    errdefer if (rev) |owned| self.allocator.free(owned);

    return .{ .url = url, .name = name, .rev = rev };
}

pub const GithubTreeSpec = struct {
    url: []u8,
    name: []u8,
    rev: ?[]u8,

    pub fn deinit(self: GithubTreeSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        allocator.free(self.name);
        if (self.rev) |rev| allocator.free(rev);
    }
};

/// Build the codeload archive URL for github/gitlab/sourcehut, honoring a
/// `host` override (self-hosted forges) and pinning `rev`/`ref` (else HEAD).
pub fn forgeTreeSpec(self: *VM, attrs_id: ObjectId, forge: []const u8) !GithubTreeSpec {
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

pub fn githubTreeValue(self: *VM, path: []const u8, nar_hash: []const u8, rev: ?[]const u8) !Value {
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

fn defaultFetchName(self: *VM, url: []const u8) ![]u8 {
    const basename = path_ops.baseName(url);
    if (basename.len != 0) return self.allocator.dupe(u8, basename);
    return self.allocator.dupe(u8, "source");
}
