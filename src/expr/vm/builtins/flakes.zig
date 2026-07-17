//! Structured tree fetches and flake graph evaluation.

const std = @import("std");
const VM = @import("../context.zig").VM;
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const ObjectId = types.ObjectId;
const heap_mod = @import("runtime").heap;
const fetch_cache = @import("fetchers").fetch_cache;
const derivation = @import("store").derivation;
const path_ops = @import("runtime").paths;
const flake_registry = @import("flake_registry.zig");
const shared = @import("shared.zig");
const attrsets = @import("attrsets.zig");
const strings = @import("strings.zig");
const vm_force = @import("../force.zig");
const vm_closures = @import("../closures.zig");
const vm_trace = @import("../trace.zig");
const fetch = @import("fetch.zig");
const arguments = @import("arguments.zig");

const FetchCache = fetch_cache.FetchCache;
const attrEntryNameIndex = attrsets.attrEntryNameIndex;
const stringArg = strings.stringArg;
const appendStringAttr = arguments.appendStringAttr;
const dupPathAttr = arguments.dupPathAttr;
const optionalStringAttr = arguments.optionalStringAttr;
const requiredStringAttr = arguments.requiredStringAttr;
const optionalBoolAttr = arguments.optionalBoolAttr;

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
const fetchSpanBegin = fetch.fetchSpanBegin;
const fetchSpanEnd = fetch.fetchSpanEnd;

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
        const result = try offloadFetch(self, FetchCache.fetchTarball, FetchCache.TarballSpec{
            .url = spec.url,
            .name = spec.name,
            .forge = forge,
            .metadata_url = spec.metadata_url,
            .metadata_ref = spec.metadata_ref,
            .metadata_head_url = spec.metadata_head_url,
            .resolved_rev = spec.rev,
            .resolved_url_template = spec.resolved_url_template,
        }, span);
        defer result.deinit(self.fetchers.allocator);
        const out = try ingestFetchedTree(self, result.path, spec.name, spec.rev orelse "", null);
        defer out.deinit(self.allocator);
        return githubTreeValue(self, out.out_path, out.nar_hash, spec.rev, result.forge_metadata);
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
fn importFlakeValue(self: *VM, out_path: []const u8, dir: ?[]const u8) !Value {
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
fn flakeOutputs(self: *VM, flake_value: Value) !Value {
    const outputs_id = try self.intern.intern("outputs");
    return vm_force.forceValue(self, try self.heap.getAttrValue(flake_value.asObjectId(), outputs_id));
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
fn buildFlakeNixInputThunks(self: *VM, flake_value: Value, out_entries: *std.ArrayListUnmanaged(heap_mod.AttrEntry)) !void {
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
            else => continue, // skip bools/null/nested — fetch specs only read strings/ints
        };
        try entries.append(self.allocator, .{ .name = try self.intern.intern(e.key_ptr.*), .value = v });
    }
    return Value.attrs(try self.heap.addAttrs(entries.items));
}

fn flakeSelfInput(self: *VM, source_info: Value) !Value {
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

fn flakeResultValue(self: *VM, source_info: Value, inputs: Value, outputs: Value) !Value {
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

fn appendExistingAttr(self: *VM, entries: *std.ArrayListUnmanaged(heap_mod.AttrEntry), attrs_id: ObjectId, name: []const u8) !void {
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

pub fn builtinParseFlakeRef(self: *VM, arg: Value) !Value {
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

pub fn builtinFlakeRefToString(self: *VM, arg: Value) !Value {
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

fn appendFlakeQueryAttrs(self: *VM, entries: *std.ArrayListUnmanaged(heap_mod.AttrEntry), query: []const u8) !void {
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

fn appendFlakeQueryString(self: *VM, attrs_id: ObjectId, name: []const u8, out: *std.ArrayListUnmanaged(u8), first: *bool) !void {
    const value = try optionalStringAttr(self, attrs_id, name) orelse return;
    defer self.allocator.free(value);
    try out.append(self.allocator, if (first.*) '?' else '&');
    first.* = false;
    try out.appendSlice(self.allocator, name);
    try out.append(self.allocator, '=');
    try out.appendSlice(self.allocator, value);
}
