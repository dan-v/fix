//! Nix fetcher and flake builtins: fetchGit/fetchurl/fetchTarball/
//! fetchMercurial/fetchTree, getFlake and flake-ref parsing/serialization,
//! plus the impure getEnv/toPath/toFile/filterSource builtins.

const std = @import("std");
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const InternId = types.InternId;
const ObjectId = types.ObjectId;
const heap_mod = @import("runtime").heap;
const file_cache = @import("runtime").file_cache;
const fetch_cache = @import("runtime").fetch_cache;
const derivation = @import("derivation");
const nar = @import("runtime").nar;
const path_ops = @import("runtime").paths;
const source_paths = @import("derivation").source_path;
const eval_progress = @import("observ").progress;
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
    const contents = self.intern.get(contents_id);
    const path = try derivation.textPath(self.allocator, self.derivations.store_dir, name, contents, refs);
    defer self.allocator.free(path);
    // When a daemon is attached, populate the text object in the real store.
    try self.derivations.instantiateText(path, contents, refs);
    return contextStringWithPath(self, try self.intern.intern(path));
}

fn validateStorePathName(name: []const u8) !void {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidStorePathName;
    for (name) |char| {
        if (std.ascii.isAlphanumeric(char)) continue;
        switch (char) {
            '+', '-', '.', '_', '?', '=' => continue,
            else => return error.InvalidStorePathName,
        }
    }
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

    const src_span = self.storeCopySpanBegin(path_ops.baseName(root));
    defer self.storeCopySpanEnd(src_span);
    const store_path = try source_paths.storePathForFilteredSource(self.allocator, self.derivations, self.files, root, path_ops.baseName(root), .{
        .context = &context,
        .accept = Context.accept,
    });
    defer self.allocator.free(store_path);
    return contextStringWithPath(self, try self.intern.intern(store_path));
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
    if (self.derivations.store_writes_enabled) {
        const ingested = try source_paths.ingest(self.allocator, self.derivations, self.files, cache_path, name, filter);
        return .{ .out_path = ingested.store_path, .nar_hash = ingested.nar_hash };
    }
    const synthetic = try self.fetchers.sourceHash(cache_path, rev);
    defer self.fetchers.allocator.free(synthetic);
    return .{
        .out_path = try self.allocator.dupe(u8, cache_path),
        .nar_hash = try self.allocator.dupe(u8, synthetic),
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
        .{ .name = try self.intern.intern("narHash"), .value = Value.string(try self.intern.intern(out.nar_hash)) },
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
    const progress = self.progress orelse return null;
    return progress.beginSpan(.fetch, subject);
}

fn fetchSpanEnd(self: anytype, span: ?eval_progress.Span) void {
    if (span) |sp| if (self.progress) |progress| progress.endSpan(sp);
}

pub fn builtinFetchGit(self: anytype, arg: Value) !Value {
    const spec = try fetchGitSpec(self, arg);
    defer spec.deinit(self.allocator);

    const span = fetchSpanBegin(self, spec.url);
    defer fetchSpanEnd(self, span);
    const result = try self.fetchers.fetchGit(self.files, spec.borrowed());
    defer result.deinit(self.fetchers.allocator);
    return gitResultValue(self, spec.name, result);
}

fn gitResultValue(self: anytype, name: []const u8, result: fetch_cache.FetchCache.GitResult) !Value {
    const out = try ingestFetchedTree(self, result.out_path, name, result.rev, git_filter);
    defer out.deinit(self.allocator);
    const entries = [_]heap_mod.AttrEntry{
        .{ .name = try self.intern.intern("lastModified"), .value = Value.int(result.last_modified) },
        .{ .name = try self.intern.intern("lastModifiedDate"), .value = Value.string(try self.intern.intern(result.last_modified_date)) },
        .{ .name = try self.intern.intern("narHash"), .value = Value.string(try self.intern.intern(out.nar_hash)) },
        .{ .name = try self.intern.intern("outPath"), .value = try fetchedPathValue(self, out.out_path) },
        .{ .name = try self.intern.intern("rev"), .value = Value.string(try self.intern.intern(result.rev)) },
        .{ .name = try self.intern.intern("revCount"), .value = Value.int(result.rev_count) },
        .{ .name = try self.intern.intern("shortRev"), .value = Value.string(try self.intern.intern(result.short_rev)) },
        .{ .name = try self.intern.intern("submodules"), .value = Value.boolVal(result.submodules) },
    };
    return Value.attrs(try self.heap.addAttrs(&entries));
}

fn pathTreeValue(self: anytype, path: []const u8, nar_hash: []const u8) !Value {
    const entries = [_]heap_mod.AttrEntry{
        .{ .name = try self.intern.intern("lastModified"), .value = Value.int(0) },
        .{ .name = try self.intern.intern("lastModifiedDate"), .value = Value.string(try self.intern.intern("19700101000000")) },
        .{ .name = try self.intern.intern("narHash"), .value = Value.string(try self.intern.intern(nar_hash)) },
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

    const span = fetchSpanBegin(self, spec.url);
    defer fetchSpanEnd(self, span);
    const result = try self.fetchers.fetchUrl(self.files, spec.borrowed());
    defer result.deinit(self.fetchers.allocator);
    const path = try flatFetchOutPath(self, result.path, result.hash, spec.name);
    defer self.allocator.free(path);
    return fetchedPathValue(self, path);
}

/// Realize a fetched single file: flat (`fixed:sha256`) ingestion — like Nix's
/// fetchurl — when store writes are enabled, else the download-cache path.
/// Returns the resulting path (owned by `self.allocator`).
fn flatFetchOutPath(self: anytype, cache_path: []const u8, hash_hex: []const u8, name: []const u8) ![]u8 {
    if (!self.derivations.store_writes_enabled) return self.allocator.dupe(u8, cache_path);
    const store_path = try derivation.fixedOutputPath(self.allocator, self.derivations.store_dir, name, "out", "sha256", hash_hex);
    errdefer self.allocator.free(store_path);
    try self.derivations.instantiateFlat(store_path, try self.files.readFile(cache_path));
    return store_path;
}

fn fetchUrlSpec(self: anytype, arg: Value) !FetchUrlSpec {
    const value = try vm_force.forceValue(self, arg);
    if (!value.isAttrs()) {
        const url = try self.allocator.dupe(u8, try pathArg(self, value));
        errdefer self.allocator.free(url);
        return .{
            .url = url,
            .name = try defaultFetchName(self, url),
        };
    }

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
    const spec = try fetchUrlSpec(self, arg);
    defer spec.deinit(self.allocator);

    const span = fetchSpanBegin(self, spec.url);
    defer fetchSpanEnd(self, span);
    const path = try self.fetchers.fetchTarball(self.files, .{ .url = spec.url, .name = spec.name });
    defer self.fetchers.allocator.free(path);
    // The unpacked tree is named "source" by default (Nix), independent of the
    // archive's URL basename which named the download.
    const tree_name = try tarballTreeName(self, arg);
    defer self.allocator.free(tree_name);
    const out = try ingestFetchedTree(self, path, tree_name, "", null);
    defer out.deinit(self.allocator);
    return fetchedPathValue(self, out.out_path);
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
    const result = try self.fetchers.fetchMercurial(self.files, spec.borrowed());
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

fn githubTreeSpec(self: anytype, attrs_id: ObjectId) !GithubTreeSpec {
    const owner = try requiredStringAttr(self, attrs_id, "owner");
    defer self.allocator.free(owner);
    const repo = try requiredStringAttr(self, attrs_id, "repo");
    defer self.allocator.free(repo);
    const rev = try optionalStringAttr(self, attrs_id, "rev") orelse try optionalStringAttr(self, attrs_id, "ref");
    errdefer if (rev) |owned| self.allocator.free(owned);
    const archive_ref = rev orelse "HEAD";
    const url = try std.fmt.allocPrint(self.allocator, "https://github.com/{s}/{s}/archive/{s}.tar.gz", .{ owner, repo, archive_ref });
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
        .{ .name = try self.intern.intern("narHash"), .value = Value.string(try self.intern.intern(nar_hash)) },
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
        const result = try self.fetchers.fetchUrl(self.files, spec.borrowed());
        defer result.deinit(self.fetchers.allocator);
        const path = try flatFetchOutPath(self, result.path, result.hash, spec.name);
        defer self.allocator.free(path);
        return fileTreeValue(self, path, result.hash);
    }

    if (std.mem.eql(u8, type_value, "tarball")) {
        const spec = try fetchUrlSpecFromAttrs(self, attrs_id, "source");
        defer spec.deinit(self.allocator);
        const path = try self.fetchers.fetchTarball(self.files, .{ .url = spec.url, .name = spec.name });
        defer self.fetchers.allocator.free(path);
        const out = try ingestFetchedTree(self, path, spec.name, "", null);
        defer out.deinit(self.allocator);
        return pathTreeValue(self, out.out_path, out.nar_hash);
    }

    if (std.mem.eql(u8, type_value, "git")) {
        const spec = try fetchGitSpecFromAttrs(self, attrs_id);
        defer spec.deinit(self.allocator);
        const result = try self.fetchers.fetchGit(self.files, spec.borrowed());
        defer result.deinit(self.fetchers.allocator);
        return gitResultValue(self, spec.name, result);
    }

    if (std.mem.eql(u8, type_value, "github")) {
        const spec = try githubTreeSpec(self, attrs_id);
        defer spec.deinit(self.allocator);
        const path = try self.fetchers.fetchTarball(self.files, .{ .url = spec.url, .name = spec.name });
        defer self.fetchers.allocator.free(path);
        const out = try ingestFetchedTree(self, path, spec.name, spec.rev orelse "", null);
        defer out.deinit(self.allocator);
        return githubTreeValue(self, out.out_path, out.nar_hash, spec.rev);
    }

    if (std.mem.eql(u8, type_value, "mercurial")) {
        const spec = try fetchMercurialSpecFromAttrs(self, attrs_id);
        defer spec.deinit(self.allocator);
        const result = try self.fetchers.fetchMercurial(self.files, spec.borrowed());
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
    const source_info = try builtinFetchTree(self, try builtinParseFlakeRef(self, ref_value));
    // GC: `source_info` is a freshly built attrset (not the auto-rooted arg)
    // held across the import/force/call sequence below, up to the final
    // `flakeResultValue`. The later intermediates (`outputs_func`, `inputs`,
    // `outputs`) are each only live across a call/force where they are the
    // direct callee/arg (rooted by that call) or across non-forcing calls.
    const gc_roots = vm_force.rootsBegin(self);
    defer vm_force.rootsEnd(self, gc_roots);
    vm_force.rootKeep(self, source_info);
    const out_path = try requiredStringAttr(self, source_info.asObjectId(), "outPath");
    defer self.allocator.free(out_path);

    const flake_path = try std.fs.path.join(self.allocator, &.{ out_path, "flake.nix" });
    defer self.allocator.free(flake_path);

    const host = self.import_host orelse return error.ImportUnavailable;
    const flake_value = try vm_force.forceValue(self, try host.import_value(host.context, flake_path, self.native_depth));
    if (!flake_value.isAttrs()) return error.TypeError;

    const outputs_id = try self.intern.intern("outputs");
    const outputs_func = try vm_force.forceValue(self, try self.heap.getAttrValue(flake_value.asObjectId(), outputs_id));
    const self_input = try flakeSelfInput(self, source_info);
    const inputs_entries = [_]heap_mod.AttrEntry{
        .{ .name = try self.intern.intern("self"), .value = self_input },
    };
    const inputs = Value.attrs(try self.heap.addAttrs(&inputs_entries));
    const outputs = try vm_force.forceValue(self, try vm_closures.callValue(self, outputs_func, inputs));
    if (!outputs.isAttrs()) return error.TypeError;

    return flakeResultValue(self, source_info, inputs, outputs);
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

pub fn builtinParseFlakeRef(self: anytype, arg: Value) !Value {
    const ref = try stringArg(self, arg);
    var entries: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer entries.deinit(self.allocator);

    if (std.mem.startsWith(u8, ref, "github:")) {
        try appendStringAttr(self, &entries, "type", "github");
        var parts = std.mem.splitScalar(u8, ref["github:".len..], '/');
        const owner = parts.next() orelse return error.InvalidFlakeRef;
        const repo = parts.next() orelse return error.InvalidFlakeRef;
        try appendStringAttr(self, &entries, "owner", owner);
        try appendStringAttr(self, &entries, "repo", repo);
        if (parts.next()) |branch| {
            if (branch.len != 0) try appendStringAttr(self, &entries, "ref", branch);
        }
        return Value.attrs(try self.heap.addAttrs(entries.items));
    }

    if (std.mem.startsWith(u8, ref, "path:")) {
        try appendStringAttr(self, &entries, "type", "path");
        const rest = ref["path:".len..];
        const query_start = std.mem.indexOfScalar(u8, rest, '?');
        const path = if (query_start) |i| rest[0..i] else rest;
        try appendStringAttr(self, &entries, "path", path);
        if (query_start) |i| try appendFlakeQueryAttrs(self, &entries, rest[i + 1 ..]);
        return Value.attrs(try self.heap.addAttrs(entries.items));
    }

    if (std.fs.path.isAbsolute(ref)) {
        try appendStringAttr(self, &entries, "type", "path");
        try appendStringAttr(self, &entries, "path", ref);
        return Value.attrs(try self.heap.addAttrs(entries.items));
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
        const text = if (ref) |branch|
            try std.fmt.allocPrint(self.allocator, "github:{s}/{s}/{s}", .{ owner, repo, branch })
        else
            try std.fmt.allocPrint(self.allocator, "github:{s}/{s}", .{ owner, repo });
        defer self.allocator.free(text);
        return Value.string(try self.intern.intern(text));
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
        if (std.mem.eql(u8, key, "ref") or std.mem.eql(u8, key, "rev") or std.mem.eql(u8, key, "narHash")) {
            try appendStringAttr(self, entries, key, value);
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
