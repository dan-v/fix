//! Structured tree fetches and flake graph evaluation.

const std = @import("std");
const VM = @import("../context.zig").VM;
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const ObjectId = types.ObjectId;
const heap_mod = @import("runtime").heap;
const FetchService = @import("fetchers").FetchService;
const derivation = @import("store").derivation;
const path_ops = @import("runtime").paths;
const flake_registry = @import("flake_registry.zig");
const shared = @import("shared.zig");
const purity = @import("purity.zig");
const attrsets = @import("attrsets.zig");
const strings = @import("strings.zig");
const vm_force = @import("../force.zig");
const vm_closures = @import("../closures.zig");
const vm_trace = @import("../trace.zig");
const fetch = @import("fetch.zig");
const arguments = @import("arguments.zig");

const attrEntryNameIndex = attrsets.attrEntryNameIndex;
const stringArg = strings.stringArg;
const appendStringAttr = arguments.appendStringAttr;
const dupPathAttr = arguments.dupPathAttr;
const optionalStringAttr = arguments.optionalStringAttr;
const requiredStringAttr = arguments.requiredStringAttr;
const optionalBoolAttr = arguments.optionalBoolAttr;
const optionalIntAttr = arguments.optionalIntAttr;

const ingestFetchedTree = fetch.ingestFetchedTree;
const pathTreeValue = fetch.pathTreeValue;
const fileTreeValue = fetch.fileTreeValue;
const fetchUrlSpecFromAttrs = fetch.fetchUrlSpecFromAttrs;
const offloadFetch = fetch.offloadFetch;
const flatFetchOutPath = fetch.flatFetchOutPath;
const fetchGitSpecFromAttrs = fetch.fetchGitSpecFromAttrs;
const gitResultValue = fetch.gitResultValue;
const forgeTreeSpec = fetch.forgeTreeSpec;
const githubTreeValue = fetch.githubTreeValue;
const fetchMercurialSpecFromAttrs = fetch.fetchMercurialSpecFromAttrs;
const mercurialResultValue = fetch.mercurialResultValue;

/// Dispatch entry for a direct `builtins.fetchTree` call. Gated on the
/// `fetch-tree` experimental feature (Nix parity). `getFlake` bypasses this by
/// calling `builtinFetchTree` directly, matching Nix where flake fetching does
/// not additionally require the user to enable `fetch-tree`.
pub fn builtinFetchTreeEntry(self: *VM, arg: Value) !Value {
    if (!self.policy.fetch_tree_enabled) {
        // A hard eval error, like Nix: not catchable by `builtins.tryEval`
        // (which only intercepts NixThrow/NixAbort/AssertionFailed/FileNotFound).
        try vm_trace.setErrorMessage(self, "builtins.fetchTree is disabled; pass --extra-experimental-features fetch-tree to enable it");
        return error.MissingExperimentalFeature;
    }
    // Pure eval requires user-facing fetches to be content-locked. (getFlake's
    // own input fetches go through `builtinFetchTree` directly, bypassing this;
    // they are pinned by the lock's narHash instead.)
    if (purity.pure(self)) {
        const forced = try vm_force.forceValue(self, arg);
        // Parse only explicit-scheme strings (`github:…`, `git+…`); a bare
        // indirect id (`nixpkgs`) is inherently unlocked, so don't hit the
        // registry just to reject it.
        const ref_attrs: Value = if (forced.isString() and std.mem.indexOfScalar(u8, self.intern.get(forced.asInternId()), ':') != null)
            try builtinParseFlakeRef(self, forced)
        else
            forced;
        try purity.enforceFetchLocked(self, purity.attrsHaveLock(self, ref_attrs));
    }
    return builtinFetchTree(self, arg);
}

pub fn builtinFetchTree(self: *VM, arg: Value) !Value {
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
        const result = try offloadFetch(self, .url, spec.borrowed());
        defer result.deinit(self.fetchers.allocator);
        const path = try flatFetchOutPath(self, result.path, result.hash, spec.name);
        defer self.allocator.free(path);
        return fileTreeValue(self, path, result.hash);
    }

    if (std.mem.eql(u8, type_value, "tarball")) {
        const spec = try fetchUrlSpecFromAttrs(self, attrs_id, "source");
        defer spec.deinit(self.allocator);
        const result = try offloadFetch(self, .tarball, FetchService.TarballSpec{ .url = spec.url, .name = spec.name });
        defer result.deinit(self.fetchers.allocator);
        const out = try ingestFetchedTree(self, result.path, spec.name, "", null);
        defer out.deinit(self.allocator);
        return pathTreeValue(self, out.out_path, out.nar_hash);
    }

    if (std.mem.eql(u8, type_value, "git")) {
        const spec = try fetchGitSpecFromAttrs(self, attrs_id);
        defer spec.deinit(self.allocator);
        const result = try offloadFetch(self, .git, spec.borrowed());
        defer result.deinit(self.fetchers.allocator);
        return gitResultValue(self, spec.name, result);
    }

    if (std.mem.eql(u8, type_value, "github") or std.mem.eql(u8, type_value, "gitlab") or std.mem.eql(u8, type_value, "sourcehut")) {
        const spec = try forgeTreeSpec(self, attrs_id, type_value);
        defer spec.deinit(self.allocator);
        // Tag the fetch with the forge so `access-tokens` are applied with the
        // right per-forge auth header (as in Nix); other fetches get no token.
        const forge: FetchService.Forge = if (std.mem.eql(u8, type_value, "github"))
            .github
        else if (std.mem.eql(u8, type_value, "gitlab"))
            .gitlab
        else
            .sourcehut;
        const result = try offloadFetch(self, .tarball, FetchService.TarballSpec{
            .url = spec.url,
            .name = spec.name,
            .forge = forge,
            .metadata_url = spec.metadata_url,
            .metadata_ref = spec.metadata_ref,
            .metadata_head_url = spec.metadata_head_url,
            .resolved_rev = spec.rev,
            .resolved_url_template = spec.resolved_url_template,
        });
        defer result.deinit(self.fetchers.allocator);
        const out = try ingestFetchedTree(self, result.path, spec.name, spec.rev orelse "", null);
        defer out.deinit(self.allocator);
        return githubTreeValue(self, out.out_path, out.nar_hash, spec.rev, result.forge_metadata);
    }

    if (std.mem.eql(u8, type_value, "mercurial")) {
        const spec = try fetchMercurialSpecFromAttrs(self, attrs_id);
        defer spec.deinit(self.allocator);
        const result = try offloadFetch(self, .mercurial, spec.borrowed());
        defer result.deinit(self.fetchers.allocator);
        return mercurialResultValue(self, spec.name, result);
    }

    return error.InvalidFlakeRef;
}

/// Gate for the flake builtins on the `flakes` experimental feature (Nix
/// parity). A hard eval error, like the `fetch-tree` gate: not catchable by
/// `builtins.tryEval`. `getFlake`/`parseFlakeRef` call each other and the
/// fetcher via their un-suffixed impls, so those internal calls bypass this.
fn requireFlakes(self: *VM) !void {
    if (!self.policy.flakes_enabled) {
        try vm_trace.setErrorMessage(self, "flakes are disabled; pass --extra-experimental-features flakes to enable them");
        return error.MissingExperimentalFeature;
    }
}

pub fn builtinGetFlakeEntry(self: *VM, arg: Value) !Value {
    try requireFlakes(self);
    return builtinGetFlake(self, arg);
}

pub fn builtinParseFlakeRefEntry(self: *VM, arg: Value) !Value {
    try requireFlakes(self);
    return builtinParseFlakeRef(self, arg);
}

pub fn builtinFlakeRefToStringEntry(self: *VM, arg: Value) !Value {
    try requireFlakes(self);
    return builtinFlakeRefToString(self, arg);
}

pub fn builtinGetFlake(self: *VM, arg: Value) !Value {
    const ref = try stringArg(self, arg);
    // A relative path ref (`.`, `./x`, `../x`) resolves against the process CWD,
    // as Nix does for an impure relative flakeref. Absolute paths and scheme
    // refs pass through unchanged.
    const abs_ref: ?[]u8 = if (isRelativePathRef(ref)) try resolveCwdRelative(self, ref) else null;
    defer if (abs_ref) |r| self.allocator.free(r);
    const ref_value = Value.string(try self.intern.intern(abs_ref orelse ref));
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
    try ensureFlakeSourceOnDisk(self, out_path);
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
        // No lock: compute one (fetch + pin inputs), write it back when the
        // flake tree is writable, and resolve inputs from it. `flake update`
        // removes any existing lock first so this path re-pins to latest.
        _ = try generateAndUseLock(self, flake_value, out_path, dir, &input_entries);
    }
    // `self` is the flake's own fixpoint: outputs may read `self.packages`,
    // `self.lib`, etc. Bind it through a placeholder cell (as recursive
    // `let`/`rec` do), then publish the assembled result once outputs return.
    const self_cell = try vm_force.makeBindingCell(self);
    vm_force.rootKeep(self, self_cell);
    try input_entries.append(self.allocator, .{ .name = try self.intern.intern("self"), .value = self_cell });

    const inputs = Value.attrs(try self.heap.addAttrs(input_entries.items));
    vm_force.rootKeep(self, inputs);
    const outputs = try vm_force.forceValue(self, try vm_closures.callValue(self, outputs_func, inputs));
    if (!outputs.isAttrs()) return error.TypeError;

    const result = try flakeResultValue(self, source_info, inputs, outputs);
    publishSelfCell(self, self_cell, result);
    return result;
}

fn isRelativePathRef(ref: []const u8) bool {
    return std.mem.eql(u8, ref, ".") or std.mem.startsWith(u8, ref, "./") or std.mem.startsWith(u8, ref, "../");
}

/// Resolve a relative path ref to an absolute one against the process CWD.
fn resolveCwdRelative(self: *VM, ref: []const u8) ![]u8 {
    const io = self.files.io orelse return error.FileIoUnavailable;
    const cwd = try std.process.currentPathAlloc(io, self.allocator);
    defer self.allocator.free(cwd);
    return std.fs.path.resolve(self.allocator, &.{ cwd, ref });
}

/// Under store writes, a fetched flake's `outPath` is a store path whose NAR is
/// only *recorded* (writes are demand-driven), so it isn't on disk yet. Reading
/// `flake.nix`/`flake.lock` from it — or resolving inputs — needs it
/// materialized first; force the write here (a source path has no dependencies,
/// so this is just its own NAR). No-op in plain eval, where `outPath` is the
/// readable cache path.
fn ensureFlakeSourceOnDisk(self: *VM, out_path: []const u8) !void {
    if (!self.realization.storeWritesEnabled()) return;
    const store_dir = self.realization.store_dir;
    if (!std.mem.startsWith(u8, out_path, store_dir)) return;
    try self.realization.ensureClosure(out_path);
}

/// Import + force the flake.nix attrset at `<out_path>[/dir]`.
fn importFlakeValue(self: *VM, out_path: []const u8, dir: ?[]const u8) !Value {
    const flake_path = if (dir) |d|
        try std.fs.path.join(self.allocator, &.{ out_path, d, "flake.nix" })
    else
        try std.fs.path.join(self.allocator, &.{ out_path, "flake.nix" });
    defer self.allocator.free(flake_path);
    const host = self.import_host orelse return error.ImportUnavailable;
    const flake_value = try vm_force.forceValue(self, try host.import_value(host.context, self, flake_path, self.native_depth));
    if (!flake_value.isAttrs()) return error.TypeError;
    return flake_value;
}

/// The (forced) `outputs` function of an imported flake attrset.
fn flakeOutputs(self: *VM, flake_value: Value) !Value {
    const outputs_id = try self.intern.intern("outputs");
    const outputs = (try self.heap.getAttrValueOpt(flake_value.asObjectId(), outputs_id)) orelse {
        try vm_trace.setErrorMessage(self, "flake has no 'outputs' attribute (flake.nix must define `outputs`)");
        return error.InvalidFlake;
    };
    return vm_force.forceValue(self, outputs);
}

/// Import the flake.nix at `<out_path>[/dir]` and return its (forced) `outputs`.
fn flakeOutputsFunc(self: *VM, out_path: []const u8, dir: ?[]const u8) !Value {
    return flakeOutputs(self, try importFlakeValue(self, out_path, dir));
}

/// Parse `<out_path>[/dir]/flake.lock` and resolve the root flake's declared
/// inputs into `out_entries` (each a fetched, evaluated input flake). Returns
/// false (leaving `out_entries` untouched) when there is no lock file, so the
/// caller can fall back to the flake.nix `inputs` declarations.
fn resolveRootInputs(self: *VM, out_path: []const u8, dir: ?[]const u8, out_entries: *std.ArrayListUnmanaged(heap_mod.AttrEntry)) !bool {
    const lock_path = if (dir) |d|
        try std.fs.path.join(self.allocator, &.{ out_path, d, "flake.lock" })
    else
        try std.fs.path.join(self.allocator, &.{ out_path, "flake.lock" });
    defer self.allocator.free(lock_path);
    const lock_data = self.files.readFile(lock_path) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    try resolveInputsFromLockData(self, lock_data, out_entries);
    return true;
}

/// Parse a `flake.lock` (from disk or freshly generated) and resolve the root
/// flake's declared inputs into `out_entries`.
fn resolveInputsFromLockData(self: *VM, lock_data: []const u8, out_entries: *std.ArrayListUnmanaged(heap_mod.AttrEntry)) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, lock_data, .{}) catch return error.InvalidFlakeLock;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidFlakeLock;
    // Nix errors on an unknown lock version; it reads formats 5–7. Our node
    // parser (`locked`/`inputs`/`follows`) is common to all three.
    const version_v = parsed.value.object.get("version") orelse return error.InvalidFlakeLock;
    if (version_v != .integer or version_v.integer < 5 or version_v.integer > 7) return error.UnsupportedFlakeLockVersion;
    const nodes_v = parsed.value.object.get("nodes") orelse return error.InvalidFlakeLock;
    const root_name_v = parsed.value.object.get("root") orelse return error.InvalidFlakeLock;
    if (nodes_v != .object or root_name_v != .string) return error.InvalidFlakeLock;
    const nodes = nodes_v.object;
    const root_name = root_name_v.string;

    const root_node = nodes.get(root_name) orelse return error.InvalidFlakeLock;
    if (root_node != .object) return error.InvalidFlakeLock;
    const root_inputs = root_node.object.get("inputs") orelse return; // lock exists, flake has no inputs
    if (root_inputs != .object) return error.InvalidFlakeLock;

    var memo: std.StringHashMapUnmanaged(Value) = .empty;
    defer memo.deinit(self.allocator);

    var it = root_inputs.object.iterator();
    while (it.next()) |entry| {
        const target_node = try followInput(nodes, root_name, entry.value_ptr.*);
        const thunk = try buildNodeThunk(self, nodes, target_node, root_name, &memo, 0);
        try out_entries.append(self.allocator, .{ .name = try self.intern.intern(entry.key_ptr.*), .value = thunk });
    }
}

/// Lockless: build a lazy thunk for each of a flake's flake.nix `inputs`
/// declarations. Each input is a flakeref string, `{ url = …; }`, or an inline
/// ref attrset; `flake = false` yields the bare source. `sub_inputs` is passed
/// as null so `resolveFlakeNode`, on force, builds the input flake's own
/// sub-inputs from its flake.nix (recursively, also lazily). Because each input
/// is a thunk, an input an output never touches is never fetched.
fn buildFlakeNixInputThunks(self: *VM, flake_value: Value, out_entries: *std.ArrayListUnmanaged(heap_mod.AttrEntry)) !void {
    const inputs_id = try self.intern.intern("inputs");
    const inputs_v = (self.heap.getAttrValueOpt(flake_value.asObjectId(), inputs_id) catch return) orelse return;
    const inputs = try vm_force.forceValue(self, inputs_v);
    if (!inputs.isAttrs()) return;

    // Two passes: build the concrete inputs first (recording name → thunk), then
    // resolve `inputs.<name>.follows = "<sibling>"` aliases against them. Without
    // this a `follows` decl (which carries no `url`/`type`) would be handed to
    // the fetcher as a ref and hard-error.
    const follows_id = try self.intern.intern("follows");
    var built: std.StringHashMapUnmanaged(Value) = .empty;
    defer built.deinit(self.allocator);
    const Follow = struct { name: @TypeOf(inputs_id), target: []const u8 };
    var follows: std.ArrayListUnmanaged(Follow) = .empty;
    defer follows.deinit(self.allocator);

    for (try self.heap.materializeAttrs(inputs.asObjectId())) |entry| {
        const decl = try vm_force.forceValue(self, entry.value);
        if (decl.isAttrs()) {
            if (try self.heap.getAttrValueOpt(decl.asObjectId(), follows_id)) |f| {
                const fv = try vm_force.forceValue(self, f);
                if (!fv.isString()) return error.InvalidFlakeRef;
                try follows.append(self.allocator, .{ .name = entry.name, .target = self.intern.get(fv.asInternId()) });
                continue;
            }
        }
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
        try built.put(self.allocator, self.intern.get(entry.name), thunk);
    }

    for (follows.items) |fe| {
        // A flake.nix `follows` is a `/`-separated input path. The single-segment
        // case (`inputs.a.follows = "b"`) aliases a sibling; deeper paths
        // (`"b/c"` → b's own input c) need the sibling's resolved input graph and
        // are deferred (they need the same machinery as lockfile follows).
        var segs = std.mem.splitScalar(u8, fe.target, '/');
        const first = segs.next() orelse continue;
        const sibling = built.get(first) orelse return error.InvalidFlakeFollows;
        if (segs.next() != null) return error.UnsupportedFlakeFollows;
        try out_entries.append(self.allocator, .{ .name = fe.name, .value = sibling });
    }
}

// ---- flake.lock generation ------------------------------------------------
//
// When a flake has inputs but no `flake.lock`, compute one: fetch each input to
// pin its `locked` ref (rev/narHash/lastModified), recurse into its own inputs
// (honoring `follows` and `inputs.x.inputs.y` overrides declared in the parent),
// deduplicate identical nodes, and serialize the Nix version-7 graph. The
// result is written back next to `flake.nix` when that directory is writable,
// and is fed to the normal lock reader so evaluation uses the pinned graph.

/// A minimal, insertion-ordered JSON value for emitting a lock (std.json's
/// ObjectMap doesn't preserve order and its API varies across Zig versions).
const JField = struct { key: []const u8, val: JVal };
const JVal = union(enum) {
    string: []const u8,
    integer: i64,
    boolean: bool,
    array: []const JVal,
    object: []const JField,
};

const LockEdge = struct {
    name: []const u8,
    node_key: ?[]const u8 = null, // a concrete node…
    follows: ?[]const []const u8 = null, // …or a root-relative follows path
};

const LockNode = struct {
    key: []const u8,
    locked: JVal,
    original: JVal,
    is_flake: bool,
    inputs: []const LockEdge = &.{},
};

const LockGen = struct {
    vm: *VM,
    arena: std.mem.Allocator,
    nodes: std.ArrayListUnmanaged(LockNode) = .empty,
    by_locked: std.StringHashMapUnmanaged([]const u8) = .empty, // serialized locked → node key
    names: std.StringHashMapUnmanaged(u32) = .empty, // base name → next disambiguator

    // Merge context (`flake update`/`lock`): an existing lock whose untouched
    // root inputs are copied forward rather than re-fetched. Null → pin all.
    existing_nodes: ?std.json.ObjectMap = null,
    existing_root: []const u8 = "root",
    update_all: bool = true, // re-pin every root input
    update_names: []const []const u8 = &.{}, // …or only these
    imported: std.StringHashMapUnmanaged([]const u8) = .empty, // existing node name → new key

    /// A node key that is unique in the graph: the input name, or `name_N`.
    fn uniqueKey(self: *LockGen, name: []const u8) ![]const u8 {
        const gop = try self.names.getOrPut(self.arena, name);
        if (!gop.found_existing) {
            gop.value_ptr.* = 2;
            return name;
        }
        const n = gop.value_ptr.*;
        gop.value_ptr.* = n + 1;
        return std.fmt.allocPrint(self.arena, "{s}_{d}", .{ name, n });
    }

    /// The existing lock's root-node `inputs` map, or null when there is no
    /// reusable lock.
    fn existingRootInputs(self: *LockGen) ?std.json.ObjectMap {
        const nodes = self.existing_nodes orelse return null;
        const root = nodes.get(self.existing_root) orelse return null;
        if (root != .object) return null;
        const inputs = root.object.get("inputs") orelse return null;
        return if (inputs == .object) inputs.object else null;
    }

    /// Whether root input `name` must be re-fetched (vs. copied from the existing
    /// lock): when there's no lock, `update` was asked for it, or it's new.
    fn shouldRepin(self: *LockGen, name: []const u8) bool {
        if (self.update_all) return true;
        for (self.update_names) |n| if (std.mem.eql(u8, n, name)) return true;
        const root_inputs = self.existingRootInputs() orelse return true;
        return root_inputs.get(name) == null; // a newly-declared input has no pin yet
    }
};

/// `std.fmt` into an unmanaged byte list (which has no `print` of its own).
fn appendFmt(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(alloc, fmt, args);
    try out.appendSlice(alloc, s);
}

/// Serialize a `JVal` into `out`.
fn writeLockJson(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, v: JVal) !void {
    switch (v) {
        .string => |s| {
            try out.append(alloc, '"');
            for (s) |c| switch (c) {
                '"' => try out.appendSlice(alloc, "\\\""),
                '\\' => try out.appendSlice(alloc, "\\\\"),
                '\n' => try out.appendSlice(alloc, "\\n"),
                '\t' => try out.appendSlice(alloc, "\\t"),
                else => try out.append(alloc, c),
            };
            try out.append(alloc, '"');
        },
        .integer => |n| try appendFmt(out, alloc, "{d}", .{n}),
        .boolean => |b| try out.appendSlice(alloc, if (b) "true" else "false"),
        .array => |arr| {
            try out.append(alloc, '[');
            for (arr, 0..) |item, i| {
                if (i != 0) try out.append(alloc, ',');
                try writeLockJson(out, alloc, item);
            }
            try out.append(alloc, ']');
        },
        .object => |fields| {
            try out.append(alloc, '{');
            for (fields, 0..) |f, i| {
                if (i != 0) try out.append(alloc, ',');
                try writeLockJson(out, alloc, .{ .string = f.key });
                try out.append(alloc, ':');
                try writeLockJson(out, alloc, f.val);
            }
            try out.append(alloc, '}');
        },
    }
}

/// A forced ref attrset's scalar fields as a JSON object (arena-owned, in attr
/// order).
fn refAttrsToFields(gen: *LockGen, ref_attrs: Value) !std.ArrayListUnmanaged(JField) {
    var fields: std.ArrayListUnmanaged(JField) = .empty;
    if (ref_attrs.isAttrs()) {
        for (try gen.vm.heap.materializeAttrs(ref_attrs.asObjectId())) |e| {
            const name = try gen.arena.dupe(u8, gen.vm.intern.get(e.name));
            const val = try vm_force.forceValue(gen.vm, e.value);
            const jv: JVal = if (val.isString())
                .{ .string = try gen.arena.dupe(u8, gen.vm.intern.get(val.asInternId())) }
            else if (val.isInt())
                .{ .integer = val.asInt() }
            else if (val.isBool())
                .{ .boolean = val.asBool() }
            else
                continue;
            try fields.append(gen.arena, .{ .key = name, .val = jv });
        }
    }
    return fields;
}

fn refAttrsToJson(gen: *LockGen, ref_attrs: Value) !JVal {
    return .{ .object = (try refAttrsToFields(gen, ref_attrs)).items };
}

fn hasField(fields: []const JField, key: []const u8) bool {
    for (fields) |f| if (std.mem.eql(u8, f.key, key)) return true;
    return false;
}

/// The `locked` node: the ref's identity fields plus the fetched pin
/// (rev/narHash/lastModified/revCount). `ref` is dropped once a `rev` pins it.
fn lockedJson(gen: *LockGen, ref_attrs: Value, src_info: Value) !JVal {
    var fields = try refAttrsToFields(gen, ref_attrs);
    for ([_][]const u8{ "narHash", "rev", "shortRev" }) |field| {
        if (try optionalStringAttr(gen.vm, src_info.asObjectId(), field)) |s| {
            defer gen.vm.allocator.free(s);
            if (!hasField(fields.items, field))
                try fields.append(gen.arena, .{ .key = field, .val = .{ .string = try gen.arena.dupe(u8, s) } });
        }
    }
    for ([_][]const u8{ "lastModified", "revCount" }) |field| {
        if (try optionalIntAttr(gen.vm, src_info.asObjectId(), field)) |n| {
            if (!hasField(fields.items, field))
                try fields.append(gen.arena, .{ .key = field, .val = .{ .integer = n } });
        }
    }
    // A resolved `rev` supersedes the `ref` branch in the locked node (Nix).
    if (hasField(fields.items, "rev")) {
        var filtered: std.ArrayListUnmanaged(JField) = .empty;
        for (fields.items) |f| if (!std.mem.eql(u8, f.key, "ref")) try filtered.append(gen.arena, f);
        fields = filtered;
    }
    return .{ .object = fields.items };
}

/// Resolve one declared input (with an optional parent `override` decl) into an
/// edge, creating/deduplicating its node and recursing into transitive inputs.
fn lockInput(gen: *LockGen, name: []const u8, decl: Value, override: ?Value, depth: u32) anyerror!LockEdge {
    if (depth > 64) return error.InvalidFlakeLock;
    const self = gen.vm;

    // A `follows` (on the declaration or a parent override) is a link, not a node.
    const follows_src = override orelse decl;
    if (follows_src.isAttrs()) {
        if (try self.heap.getAttrValueOpt(follows_src.asObjectId(), try self.intern.intern("follows"))) |f| {
            const fv = try vm_force.forceValue(self, f);
            if (fv.isString()) {
                var segs: std.ArrayListUnmanaged([]const u8) = .empty;
                var it = std.mem.splitScalar(u8, self.intern.get(fv.asInternId()), '/');
                while (it.next()) |seg| try segs.append(gen.arena, try gen.arena.dupe(u8, seg));
                return .{ .name = name, .follows = segs.items };
            }
        }
    }

    // The effective ref: a parent override with a url/type wins over the child's
    // own declaration (an input pin). Otherwise use the declaration.
    const eff = if (override != null and refLike(self, override.?)) override.? else decl;
    const ref_attrs = try parseInputRef(self, eff);
    vm_force.rootKeep(self, ref_attrs);
    const is_flake = if (eff.isAttrs()) (try optionalBoolAttr(self, eff.asObjectId(), "flake")) orelse true else true;

    const src_info = try builtinFetchTree(self, ref_attrs);
    vm_force.rootKeep(self, src_info);

    const locked = try lockedJson(gen, ref_attrs, src_info);
    var key_buf: std.ArrayListUnmanaged(u8) = .empty;
    try writeLockJson(&key_buf, gen.arena, locked);
    if (gen.by_locked.get(key_buf.items)) |existing| return .{ .name = name, .node_key = existing };

    const key = try gen.uniqueKey(name);
    try gen.by_locked.put(gen.arena, key_buf.items, key);
    // Reserve the node slot before recursing (a diamond may point back at it).
    const node_index = gen.nodes.items.len;
    try gen.nodes.append(gen.arena, .{
        .key = key,
        .locked = locked,
        .original = try refAttrsToJson(gen, ref_attrs),
        .is_flake = is_flake,
    });

    // Recurse into the input flake's own inputs, threading this input's overrides.
    if (is_flake) {
        const out_path = try requiredStringAttr(self, src_info.asObjectId(), "outPath");
        defer self.allocator.free(out_path);
        try ensureFlakeSourceOnDisk(self, out_path);
        const sub_dir = try optionalStringAttr(self, ref_attrs.asObjectId(), "dir");
        defer if (sub_dir) |d| self.allocator.free(d);
        if (importFlakeValue(self, out_path, sub_dir)) |child_flake| {
            vm_force.rootKeep(self, child_flake);
            // Overrides for the child's inputs are declared in THIS input's own
            // `inputs.<name>` map (`inputs.dep.inputs.sub.follows = "sub"`). The
            // `inputs` attr is lazy, so force it before probing it as an attrset.
            const co_lazy = if (eff.isAttrs()) try self.heap.getAttrValueOpt(eff.asObjectId(), try self.intern.intern("inputs")) else null;
            const child_overrides = if (co_lazy) |c| try vm_force.forceValue(self, c) else null;
            const edges = try lockFlakeInputs(gen, child_flake, child_overrides, depth + 1);
            gen.nodes.items[node_index].inputs = edges;
        } else |_| {}
    }
    return .{ .name = name, .node_key = key };
}

/// Convert a parsed lock JSON value into a `JVal`, preserving object key order.
fn jsonToJVal(gen: *LockGen, v: std.json.Value) anyerror!JVal {
    return switch (v) {
        .string => |s| .{ .string = try gen.arena.dupe(u8, s) },
        .integer => |n| .{ .integer = n },
        .float => |f| .{ .integer = @intFromFloat(f) },
        .bool => |b| .{ .boolean = b },
        .array => |arr| blk: {
            var items: std.ArrayListUnmanaged(JVal) = .empty;
            for (arr.items) |item| try items.append(gen.arena, try jsonToJVal(gen, item));
            break :blk .{ .array = items.items };
        },
        .object => |obj| blk: {
            var fields: std.ArrayListUnmanaged(JField) = .empty;
            var it = obj.iterator();
            while (it.next()) |e| try fields.append(gen.arena, .{ .key = try gen.arena.dupe(u8, e.key_ptr.*), .val = try jsonToJVal(gen, e.value_ptr.*) });
            break :blk .{ .object = fields.items };
        },
        else => .{ .string = "" }, // null / number_string don't appear in a lock node
    };
}

/// Copy an existing-lock input edge (a node-name string, or a follows path) into
/// the new graph, importing the referenced node subtree.
fn importExistingEdge(gen: *LockGen, name: []const u8, edge: std.json.Value) anyerror!LockEdge {
    switch (edge) {
        .string => |node_name| return .{ .name = name, .node_key = try importExistingNode(gen, node_name) },
        .array => |arr| {
            var segs: std.ArrayListUnmanaged([]const u8) = .empty;
            for (arr.items) |seg| if (seg == .string) try segs.append(gen.arena, try gen.arena.dupe(u8, seg.string));
            return .{ .name = name, .follows = segs.items };
        },
        else => return error.InvalidFlakeLock,
    }
}

/// Import an existing-lock node (and its subtree) into the new graph, keeping
/// its pin. Deduplicates against already-present nodes by locked identity.
fn importExistingNode(gen: *LockGen, node_name: []const u8) anyerror![]const u8 {
    if (gen.imported.get(node_name)) |k| return k;
    const nodes = gen.existing_nodes orelse return error.InvalidFlakeLock;
    const node_v = nodes.get(node_name) orelse return error.InvalidFlakeLock;
    if (node_v != .object) return error.InvalidFlakeLock;
    const node = node_v.object;
    const locked = try jsonToJVal(gen, node.get("locked") orelse return error.InvalidFlakeLock);

    var key_buf: std.ArrayListUnmanaged(u8) = .empty;
    try writeLockJson(&key_buf, gen.arena, locked);
    if (gen.by_locked.get(key_buf.items)) |k| {
        try gen.imported.put(gen.arena, try gen.arena.dupe(u8, node_name), k);
        return k;
    }

    const key = try gen.uniqueKey(node_name);
    try gen.by_locked.put(gen.arena, key_buf.items, key);
    try gen.imported.put(gen.arena, try gen.arena.dupe(u8, node_name), key);
    const node_index = gen.nodes.items.len;
    const is_flake = switch (node.get("flake") orelse std.json.Value{ .bool = true }) {
        .bool => |b| b,
        else => true,
    };
    try gen.nodes.append(gen.arena, .{
        .key = key,
        .locked = locked,
        .original = if (node.get("original")) |o| try jsonToJVal(gen, o) else locked,
        .is_flake = is_flake,
    });
    if (node.get("inputs")) |ins| if (ins == .object) {
        var edges: std.ArrayListUnmanaged(LockEdge) = .empty;
        var it = ins.object.iterator();
        while (it.next()) |e| try edges.append(gen.arena, try importExistingEdge(gen, try gen.arena.dupe(u8, e.key_ptr.*), e.value_ptr.*));
        gen.nodes.items[node_index].inputs = edges.items;
    };
    return key;
}

/// Whether `v` looks like a concrete input ref (a string/path, or an attrset
/// with `url`/`type`) as opposed to a bare `{ follows = …; }` / overrides map.
fn refLike(self: *VM, v: Value) bool {
    if (v.isString() or v.isPath()) return true;
    if (!v.isAttrs()) return false;
    const has_url = (self.heap.getAttrValueOpt(v.asObjectId(), self.intern.intern("url") catch return false) catch null) != null;
    const has_type = (self.heap.getAttrValueOpt(v.asObjectId(), self.intern.intern("type") catch return false) catch null) != null;
    return has_url or has_type;
}

/// Parse an input declaration (`"github:…"` / `{ url = …; }` / inline ref) into
/// ref attrs — the eager analogue of the dispatch in `buildFlakeNixInputThunks`.
fn parseInputRef(self: *VM, decl: Value) !Value {
    if (decl.isString() or decl.isPath()) return builtinParseFlakeRef(self, decl);
    if (decl.isAttrs()) {
        if (try self.heap.getAttrValueOpt(decl.asObjectId(), try self.intern.intern("url"))) |u|
            return builtinParseFlakeRef(self, try vm_force.forceValue(self, u));
        return decl; // inline { type = …; }
    }
    return error.InvalidFlakeRef;
}

/// Build the edges for every declared input of `flake_value`, applying parent
/// `overrides` (a `{ <name> = { follows|url|inputs … }; }` map) where present.
fn lockFlakeInputs(gen: *LockGen, flake_value: Value, overrides: ?Value, depth: u32) anyerror![]LockEdge {
    const self = gen.vm;
    var edges: std.ArrayListUnmanaged(LockEdge) = .empty;
    const inputs_v = (self.heap.getAttrValueOpt(flake_value.asObjectId(), try self.intern.intern("inputs")) catch return edges.items) orelse return edges.items;
    const inputs = try vm_force.forceValue(self, inputs_v);
    if (!inputs.isAttrs()) return edges.items;

    for (try self.heap.materializeAttrs(inputs.asObjectId())) |entry| {
        const name = self.intern.get(entry.name);
        // At the root, an input the user didn't ask to update keeps its existing
        // pin: copy the old node subtree instead of re-fetching.
        if (depth == 0 and !gen.shouldRepin(name)) {
            if (gen.existingRootInputs()) |root_inputs| {
                if (root_inputs.get(name)) |edge| {
                    try edges.append(gen.arena, try importExistingEdge(gen, try gen.arena.dupe(u8, name), edge));
                    continue;
                }
            }
        }
        const decl = try vm_force.forceValue(self, entry.value);
        const override = if (overrides) |o| (if (o.isAttrs()) try self.heap.getAttrValueOpt(o.asObjectId(), entry.name) else null) else null;
        const forced_override = if (override) |ov| try vm_force.forceValue(self, ov) else null;
        try edges.append(gen.arena, try lockInput(gen, try gen.arena.dupe(u8, name), decl, forced_override, depth));
    }
    return edges.items;
}

/// Serialize the resolved graph as a Nix version-7 `flake.lock` (arena-owned).
fn serializeLock(gen: *LockGen, root_edges: []const LockEdge) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    const a = gen.arena;
    try out.appendSlice(a, "{\n  \"nodes\": {\n    \"root\": {");
    try writeEdges(gen, &out, root_edges, "      ", false);
    try out.appendSlice(a, "\n    }");
    for (gen.nodes.items) |node| {
        try out.appendSlice(a, ",\n    ");
        try writeLockJson(&out, a, .{ .string = node.key });
        try out.appendSlice(a, ": {\n      \"locked\": ");
        try writeLockJson(&out, a, node.locked);
        try out.appendSlice(a, ",\n      \"original\": ");
        try writeLockJson(&out, a, node.original);
        if (!node.is_flake) try out.appendSlice(a, ",\n      \"flake\": false");
        try writeEdges(gen, &out, node.inputs, "      ", true);
        try out.appendSlice(a, "\n    }");
    }
    try out.appendSlice(a, "\n  },\n  \"root\": \"root\",\n  \"version\": 7\n}\n");
    return out.items;
}

fn writeEdges(gen: *LockGen, out: *std.ArrayListUnmanaged(u8), edges: []const LockEdge, indent: []const u8, leading_comma: bool) !void {
    if (edges.len == 0) return;
    const a = gen.arena;
    if (leading_comma) try out.append(a, ',');
    try appendFmt(out, a, "\n{s}\"inputs\": {{", .{indent});
    for (edges, 0..) |edge, i| {
        if (i != 0) try out.append(a, ',');
        try appendFmt(out, a, "\n{s}  ", .{indent});
        try writeLockJson(out, a, .{ .string = edge.name });
        try out.appendSlice(a, ": ");
        if (edge.follows) |path| {
            var arr: std.ArrayListUnmanaged(JVal) = .empty;
            for (path) |seg| try arr.append(a, .{ .string = seg });
            try writeLockJson(out, a, .{ .array = arr.items });
        } else {
            try writeLockJson(out, a, .{ .string = edge.node_key.? });
        }
    }
    try appendFmt(out, a, "\n{s}}}", .{indent});
}

/// `<out_path>[/dir]/flake.lock`, owned by `self.allocator`.
fn flakeLockPath(self: *VM, out_path: []const u8, dir: ?[]const u8) ![]u8 {
    return if (dir) |d|
        std.fs.path.join(self.allocator, &.{ out_path, d, "flake.lock" })
    else
        std.fs.path.join(self.allocator, &.{ out_path, "flake.lock" });
}

/// The forced `inputs` attrset of a flake, or null when it declares none.
fn flakeInputsAttrs(self: *VM, flake_value: Value) !?Value {
    const inputs_v = (self.heap.getAttrValueOpt(flake_value.asObjectId(), try self.intern.intern("inputs")) catch return null) orelse return null;
    const inputs = try vm_force.forceValue(self, inputs_v);
    if (!inputs.isAttrs() or (try self.heap.materializeAttrs(inputs.asObjectId())).len == 0) return null;
    return inputs;
}

/// getFlake's no-lock branch: compute a lock (pin every input), write it when
/// the tree is writable, and resolve the root inputs from it. Returns false when
/// the flake declares no inputs. This is the "generate all" caller of the same
/// lock machinery `computeFlakeLock` (flake update/lock) uses.
fn generateAndUseLock(self: *VM, flake_value: Value, out_path: []const u8, dir: ?[]const u8, out_entries: *std.ArrayListUnmanaged(heap_mod.AttrEntry)) !bool {
    if ((try flakeInputsAttrs(self, flake_value)) == null) return false;

    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    var gen = LockGen{ .vm = self, .arena = arena_state.allocator() };
    const lock_json = try serializeLock(&gen, try lockFlakeInputs(&gen, flake_value, null, 0));

    // Persist next to flake.nix when writable (a store path / read-only tree is
    // left alone — the in-memory lock is still used for this evaluation).
    const lock_path = try flakeLockPath(self, out_path, dir);
    defer self.allocator.free(lock_path);
    self.files.writeFile(lock_path, lock_json) catch {};

    try resolveInputsFromLockData(self, lock_json, out_entries);
    return true;
}

/// Compute and write `flake.lock` as a standalone operation — `fix flake
/// update`/`lock`. Fetches the flake and its inputs and pins them, but does NOT
/// evaluate `outputs`. `update_all` re-pins every input; otherwise only the
/// inputs named in `update_names` (and any newly-declared ones) are re-fetched,
/// with the rest copied forward from the current lock.
pub fn computeFlakeLock(self: *VM, ref: []const u8, update_all: bool, update_names: []const []const u8) !void {
    const gc_roots = vm_force.rootsBegin(self);
    defer vm_force.rootsEnd(self, gc_roots);

    const parsed_ref = try builtinParseFlakeRef(self, Value.string(try self.intern.intern(ref)));
    vm_force.rootKeep(self, parsed_ref);
    const src_info = try builtinFetchTree(self, parsed_ref);
    vm_force.rootKeep(self, src_info);
    const out_path = try requiredStringAttr(self, src_info.asObjectId(), "outPath");
    defer self.allocator.free(out_path);
    try ensureFlakeSourceOnDisk(self, out_path);
    const dir = try optionalStringAttr(self, parsed_ref.asObjectId(), "dir");
    defer if (dir) |d| self.allocator.free(d);
    const flake_value = try importFlakeValue(self, out_path, dir);
    vm_force.rootKeep(self, flake_value);
    if ((try flakeInputsAttrs(self, flake_value)) == null) return; // nothing to lock

    const lock_path = try flakeLockPath(self, out_path, dir);
    defer self.allocator.free(lock_path);

    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();

    // The existing lock (if any) is the merge base; its parse tree must outlive
    // the generator, which references its node objects for untouched inputs.
    var parsed_lock: ?std.json.Parsed(std.json.Value) = null;
    defer if (parsed_lock) |p| p.deinit();
    var gen = LockGen{ .vm = self, .arena = arena_state.allocator(), .update_all = update_all, .update_names = update_names };
    if (self.files.readFile(lock_path)) |data| {
        if (std.json.parseFromSlice(std.json.Value, self.allocator, data, .{})) |p| {
            parsed_lock = p;
            if (p.value == .object) {
                if (p.value.object.get("nodes")) |n| {
                    if (n == .object) gen.existing_nodes = n.object;
                }
                if (p.value.object.get("root")) |r| {
                    if (r == .string) gen.existing_root = r.string;
                }
            }
        } else |_| {}
    } else |_| {}

    const lock_json = try serializeLock(&gen, try lockFlakeInputs(&gen, flake_value, null, 0));
    try self.files.writeFile(lock_path, lock_json);
}

/// Internal builtin backing a lazy flake input (`inputs.<name>`): forced only
/// when the input is used, so unused inputs are never fetched. Fetches
/// `ref_attrs` and, if it's a flake, evaluates its outputs. `sub_inputs` is the
/// pre-built input thunks from the lock, or null — in which case the input
/// flake's own sub-inputs are built (lazily) from its fetched flake.nix.
pub fn resolveFlakeNode(self: *VM, ref_attrs: Value, sub_inputs: Value, is_flake: Value) anyerror!Value {
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
    try ensureFlakeSourceOnDisk(self, src_out);
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
        for (try self.heap.materializeAttrs(sub_inputs.asObjectId())) |e| try entries.append(self.allocator, e);
    } else {
        try buildFlakeNixInputThunks(self, flake_value, &entries);
    }
    const self_cell = try vm_force.makeBindingCell(self);
    vm_force.rootKeep(self, self_cell);
    try entries.append(self.allocator, .{ .name = try self.intern.intern("self"), .value = self_cell });
    const inputs = Value.attrs(try self.heap.addAttrs(entries.items));
    vm_force.rootKeep(self, inputs);
    const outputs = try vm_force.forceValue(self, try vm_closures.callValue(self, outputs_func, inputs));
    if (!outputs.isAttrs()) return error.TypeError;
    const result = try flakeResultValue(self, src_info, inputs, outputs);
    publishSelfCell(self, self_cell, result);
    return result;
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
fn buildNodeThunk(self: *VM, nodes: std.json.ObjectMap, node_name: []const u8, root_name: []const u8, memo: *std.StringHashMapUnmanaged(Value), depth: u32) !Value {
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
fn verifyLockedNarHash(self: *VM, ref_attrs: Value, src_info: Value) !void {
    if (!self.realization.storeWritesEnabled()) return;
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
fn flakeInputFromStore(self: *VM, attrs: Value) !?Value {
    if (!self.realization.storeWritesEnabled()) return null;
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
    const store_path = try derivation.sourcePath(self.allocator, self.realization.store_dir, name, hex);
    defer self.allocator.free(store_path);
    if (!try self.realization.pathIsValid(store_path)) return null;

    if (is_forge) {
        const rev = try optionalStringAttr(self, id, "rev");
        defer if (rev) |r| self.allocator.free(r);
        return try githubTreeValue(self, store_path, nar_hash, rev, null);
    }
    return try pathTreeValue(self, store_path, nar_hash);
}

/// Build a Nix attrset from a flake.lock `locked` node's JSON (string + integer
/// fields — type/owner/repo/rev/url/path/narHash/lastModified/...), suitable as
/// input to `builtinFetchTree`.
fn jsonObjectToAttrs(self: *VM, obj: std.json.ObjectMap) !Value {
    var entries: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer entries.deinit(self.allocator);
    var it = obj.iterator();
    while (it.next()) |e| {
        const v: Value = switch (e.value_ptr.*) {
            .string => |s| Value.string(try self.intern.intern(s)),
            .integer => |n| Value.int(n),
            .bool => |b| Value.boolVal(b), // e.g. locked `submodules`/`shallow`
            else => continue, // skip null/nested — fetch specs only read scalars
        };
        try entries.append(self.allocator, .{ .name = try self.intern.intern(e.key_ptr.*), .value = v });
    }
    return Value.attrs(try self.heap.addAttrs(entries.items));
}

/// Publish the fully-assembled flake result into the `self` binding cell, so
/// the outputs function's `self` argument resolves to its own fixpoint (the
/// same value `getFlake` returns — `_type`, `sourceInfo`, the promoted
/// source-info fields, and the merged outputs). Mirrors the `cell_set` op that
/// recursive `let`/`rec` use to publish into a pre-captured binding cell.
fn publishSelfCell(self: *VM, self_cell: Value, result: Value) void {
    const cell_thunk = self.heap.getThunkAssumeValid(self_cell.asObjectId());
    if (self.solo) cell_thunk.publishCellBindingSolo(result) else cell_thunk.publishCellBinding(result);
    self.heap.gcRecordEdge(self_cell.asObjectId(), result);
}

fn flakeResultValue(self: *VM, source_info: Value, inputs: Value, outputs: Value) !Value {
    var entries: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer entries.deinit(self.allocator);

    // Nix: `result = outputs // sourceInfo // { inputs; outputs; sourceInfo;
    // _type; }`. The explicit fields win over sourceInfo, which wins over
    // outputs — so we append explicit first, then the whole sourceInfo, then
    // outputs, each deduped against what's already present.
    try entries.append(self.allocator, .{ .name = try self.intern.intern("_type"), .value = Value.string(try self.intern.intern("flake")) });
    try entries.append(self.allocator, .{ .name = try self.intern.intern("inputs"), .value = inputs });
    try entries.append(self.allocator, .{ .name = try self.intern.intern("outputs"), .value = outputs });
    try entries.append(self.allocator, .{ .name = try self.intern.intern("sourceInfo"), .value = source_info });

    // Promote every sourceInfo field (outPath, narHash, rev, revCount,
    // shortRev, lastModified, submodules, …) — not a fixed subset — so `self`
    // and the returned flake carry whatever the fetcher produced, as Nix does.
    for (try self.heap.materializeAttrs(source_info.asObjectId())) |entry| {
        if (attrEntryNameIndex(entries.items, entry.name) == null) {
            try entries.append(self.allocator, entry);
        }
    }

    for (try self.heap.materializeAttrs(outputs.asObjectId())) |entry| {
        if (attrEntryNameIndex(entries.items, entry.name) == null) {
            try entries.append(self.allocator, entry);
        }
    }
    return Value.attrs(try self.heap.addAttrs(entries.items));
}

/// A 40-char lowercase-hex git revision (as opposed to a branch/tag `ref`).
fn looksLikeGitRev(s: []const u8) bool {
    if (s.len != 40) return false;
    for (s) |c| if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) return false;
    return true;
}

pub fn builtinParseFlakeRef(self: *VM, arg: Value) !Value {
    const ref = try stringArg(self, arg);
    var entries: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer entries.deinit(self.allocator);

    // Query string (`?dir=…&rev=…`) applies to every scheme; split it off first
    // so it never leaks into a path/repo/url segment.
    const q_idx = std.mem.indexOfScalar(u8, ref, '?');
    const base = if (q_idx) |i| ref[0..i] else ref;
    const query = if (q_idx) |i| ref[i + 1 ..] else "";

    // Explicit indirect scheme `flake:<id>` — the same thing as a bare id, just
    // spelled out. Strip the prefix and re-parse (re-attaching the query) so it
    // reaches the registry resolution below.
    if (std.mem.startsWith(u8, base, "flake:")) {
        const rest = base["flake:".len..];
        const full = if (q_idx != null)
            try std.fmt.allocPrint(self.allocator, "{s}?{s}", .{ rest, query })
        else
            try self.allocator.dupe(u8, rest);
        defer self.allocator.free(full);
        return builtinParseFlakeRef(self, Value.string(try self.intern.intern(full)));
    }

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

pub fn builtinFlakeRefToString(self: *VM, arg: Value) !Value {
    const attrs = try vm_force.forceValue(self, arg);
    if (!attrs.isAttrs()) return error.TypeError;
    const id = attrs.asObjectId();

    const type_value = try requiredStringAttr(self, id, "type");
    defer self.allocator.free(type_value);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(self.allocator);

    if (std.mem.eql(u8, type_value, "github") or std.mem.eql(u8, type_value, "gitlab") or std.mem.eql(u8, type_value, "sourcehut")) {
        const owner = try requiredStringAttr(self, id, "owner");
        defer self.allocator.free(owner);
        const repo = try requiredStringAttr(self, id, "repo");
        defer self.allocator.free(repo);
        // A pinned `rev` (or else a `ref`) goes in the path segment, as Nix does.
        const pin = (try optionalStringAttr(self, id, "rev")) orelse (try optionalStringAttr(self, id, "ref"));
        defer if (pin) |seg| self.allocator.free(seg);
        const head = if (pin) |seg|
            try std.fmt.allocPrint(self.allocator, "{s}:{s}/{s}/{s}", .{ type_value, owner, repo, seg })
        else
            try std.fmt.allocPrint(self.allocator, "{s}:{s}/{s}", .{ type_value, owner, repo });
        defer self.allocator.free(head);
        try out.appendSlice(self.allocator, head);
        var first = true;
        try appendFlakeQueryStrings(self, id, &.{ "host", "dir", "narHash", "submodules" }, &out, &first);
        return Value.string(try self.intern.intern(out.items));
    }

    if (std.mem.eql(u8, type_value, "path")) {
        const path = try requiredStringAttr(self, id, "path");
        defer self.allocator.free(path);
        try out.appendSlice(self.allocator, "path:");
        try out.appendSlice(self.allocator, path);
        var first = true;
        try appendFlakeQueryStrings(self, id, &.{ "ref", "rev", "narHash", "dir" }, &out, &first);
        return Value.string(try self.intern.intern(out.items));
    }

    // URL-backed types serialize as `<prefix><url>` + query. `tarball` uses a
    // bare http(s) URL (Nix infers tarball from the scheme) and only prefixes
    // when the scheme wouldn't round-trip.
    const url_type: ?struct { prefix: []const u8, bare_http: bool } =
        if (std.mem.eql(u8, type_value, "git")) .{ .prefix = "git+", .bare_http = false } else if (std.mem.eql(u8, type_value, "mercurial")) .{ .prefix = "hg+", .bare_http = false } else if (std.mem.eql(u8, type_value, "file")) .{ .prefix = "file+", .bare_http = false } else if (std.mem.eql(u8, type_value, "tarball")) .{ .prefix = "tarball+", .bare_http = true } else null;
    if (url_type) |ut| {
        const url = try requiredStringAttr(self, id, "url");
        defer self.allocator.free(url);
        const http = std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://");
        if (!(ut.bare_http and http)) try out.appendSlice(self.allocator, ut.prefix);
        try out.appendSlice(self.allocator, url);
        var first = true;
        try appendFlakeQueryStrings(self, id, &.{ "ref", "rev", "narHash", "dir", "host", "submodules", "shallow" }, &out, &first);
        return Value.string(try self.intern.intern(out.items));
    }

    return error.InvalidFlakeRef;
}

fn appendFlakeQueryAttrs(self: *VM, entries: *std.ArrayListUnmanaged(heap_mod.AttrEntry), query: []const u8) !void {
    var parts = std.mem.splitScalar(u8, query, '&');
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse continue;
        const key = part[0..eq];
        const value = part[eq + 1 ..];
        inline for (.{ "ref", "rev", "narHash", "dir", "host", "submodules", "shallow", "lastModified", "revCount" }) |known| {
            if (std.mem.eql(u8, key, known)) {
                try appendStringAttr(self, entries, key, value);
                break;
            }
        }
    }
}

/// Append `?k1=v1&k2=v2` for each of `names` present on `attrs_id`, in order.
fn appendFlakeQueryStrings(self: *VM, attrs_id: ObjectId, names: []const []const u8, out: *std.ArrayListUnmanaged(u8), first: *bool) !void {
    for (names) |name| try appendFlakeQueryString(self, attrs_id, name, out, first);
}

fn appendFlakeQueryString(self: *VM, attrs_id: ObjectId, name: []const u8, out: *std.ArrayListUnmanaged(u8), first: *bool) !void {
    const value = try optionalStringAttr(self, attrs_id, name) orelse return;
    defer self.allocator.free(value);
    try out.append(self.allocator, if (first.*) '?' else '&');
    first.* = false;
    try out.appendSlice(self.allocator, name);
    try out.append(self.allocator, '=');
    try out.appendSlice(self.allocator, value);
}
