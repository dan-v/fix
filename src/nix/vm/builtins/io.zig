//! Nix filesystem and import builtins: pathExists, readFile, readFileType,
//! readDir, findFile, import, and scopedImport.
//! readDir speculatively fans child-directory listings out to helper fibers
//! to warm the FileCache ahead of the demand walk (cache-only, demand-invisible).

const std = @import("std");
const Value = @import("runtime").value.Value;
const heap_mod = @import("runtime").heap;
const path_ops = @import("runtime").paths;
const FileCache = @import("runtime").file_cache.FileCache;
const strings = @import("strings.zig");
const vm_force = @import("../force.zig");
const vm_strings = @import("../strings.zig");
const vm_trace = @import("../trace.zig");

const pathArg = strings.pathArg;
const stringTextInternId = strings.stringTextInternId;
const isPlainString = strings.isPlainString;

pub fn builtinPathExists(self: anytype, arg: Value) !Value {
    return Value.boolVal(try self.files.pathExists(try demandPathArg(self, arg)));
}

pub fn builtinReadFile(self: anytype, arg: Value) !Value {
    const contents = try self.files.readFile(try demandPathArg(self, arg));
    return Value.string(try self.intern.intern(contents));
}

pub fn builtinReadFileType(self: anytype, arg: Value) !Value {
    const kind = try self.files.fileType(try demandPathArg(self, arg));
    return Value.string(try self.intern.intern(kind.nixTypeName()));
}

const DemandContext = struct {
    drv_path: []const u8,
    outputs: []const []const u8,

    fn deinit(self: DemandContext, allocator: std.mem.Allocator) void {
        allocator.free(self.outputs);
    }
};

/// Coerce a path argument while preserving its rooted string context. Present
/// paths return after one uncached filesystem probe and never touch realization
/// state. A missing derivation output is reconstructed solely from the store's
/// owned recipes and the output descriptor in the context string.
pub fn demandPathArg(self: anytype, arg: Value) ![]const u8 {
    const gc_roots = vm_force.rootsBegin(self);
    defer vm_force.rootsEnd(self, gc_roots);
    vm_force.rootKeep(self, arg);
    const forced = try vm_force.forceValue(self, arg);
    vm_force.rootKeep(self, forced);
    const value = try vm_strings.stringLikeValue(self, forced);
    vm_force.rootKeep(self, value);
    const path = self.intern.get(try vm_strings.stringTextInternId(self, value));

    if (!isStorePath(path, self.derivations.store_dir)) return path;
    // Deliberately uncached: recording a pre-build false in FileCache would
    // make pathExists contradict the successful realization below.
    if (try self.files.existsUncached(path)) return path;

    const context = (try demandContext(self, value)) orelse return path;
    defer context.deinit(self.allocator);
    if (std.mem.eql(u8, path, context.drv_path)) {
        try self.derivations.ensureClosure(context.drv_path);
    } else {
        // realizeOutput includes dependency-first closure realization; the
        // whole operation is one existing daemon-I/O offload job so concurrent
        // fibers park rather than blocking every compute worker on claim waits.
        try self.derivations.realizeOutput(context.drv_path, context.outputs);
    }
    return path;
}

fn isStorePath(path: []const u8, store_dir: []const u8) bool {
    return std.mem.startsWith(u8, path, store_dir) and
        path.len > store_dir.len and path[store_dir.len] == '/';
}

fn demandContext(self: anytype, value: Value) !?DemandContext {
    if (!value.isContextString()) return null;
    const context_entries = (try self.heap.getContextString(value.asObjectId())).context;
    var drv_name: ?@import("runtime").types.InternId = null;
    var descriptor: Value = undefined;
    for (context_entries) |entry| {
        if (!std.mem.endsWith(u8, self.intern.get(entry.name), ".drv")) continue;
        drv_name = entry.name;
        descriptor = entry.value;
        break;
    }
    const name = drv_name orelse return null;
    vm_force.rootKeep(self, descriptor);
    const marker = try vm_force.forceValue(self, descriptor);
    vm_force.rootKeep(self, marker);
    if (!marker.isAttrs()) return error.TypeError;

    const outputs_id = try self.intern.intern("outputs");
    if (try self.heap.getAttrValueOpt(marker.asObjectId(), outputs_id)) |outputs_value| {
        const list = try vm_force.forceValue(self, outputs_value);
        vm_force.rootKeep(self, list);
        if (!list.isList()) return error.TypeError;
        const list_id = list.asObjectId();
        const count = try self.heap.getListLen(list_id);
        const outputs = try self.allocator.alloc([]const u8, count);
        errdefer self.allocator.free(outputs);
        for (outputs, 0..) |*output, index| {
            const item = try vm_force.forceValue(self, try self.heap.getListItem(list_id, index));
            if (!isPlainString(item)) return error.TypeError;
            output.* = self.intern.get(try stringTextInternId(self, item));
        }
        return .{ .drv_path = self.intern.get(name), .outputs = outputs };
    }

    const all_id = try self.intern.intern("allOutputs");
    if (try self.heap.getAttrValueOpt(marker.asObjectId(), all_id)) |all_value| {
        const all = try vm_force.forceValue(self, all_value);
        if (!all.isBool()) return error.TypeError;
        if (all.asBool()) {
            const known = self.derivations.outputNames(self.intern.get(name)) orelse &.{};
            const outputs = try self.allocator.alloc([]const u8, known.len);
            @memcpy(outputs, known);
            return .{ .drv_path = self.intern.get(name), .outputs = outputs };
        }
    }

    return .{ .drv_path = self.intern.get(name), .outputs = try self.allocator.alloc([]const u8, 0) };
}

pub fn builtinImport(self: anytype, arg: Value) !Value {
    const host = self.import_host orelse return error.ImportUnavailable;
    // `import drv` is import-from-derivation: realize the output first so the
    // file to import exists on disk.
    const path = try demandPathArg(self, arg);
    return host.import_value(host.context, path, self.native_depth);
}

pub fn builtinScopedImport(self: anytype, scope_arg: Value, path_arg: Value) !Value {
    const scope = try vm_force.forceValue(self, scope_arg);
    if (!scope.isAttrs()) return vm_trace.typeErrorExpected(self, "attrs", scope);
    const host = self.import_host orelse return error.ImportUnavailable;
    const path = try demandPathArg(self, path_arg);
    return host.scoped_import(host.context, scope, path, self.native_depth);
}

pub fn builtinReadDir(self: anytype, arg: Value) !Value {
    const dir_path = try demandPathArg(self, arg);
    var cold = false;
    const dir_entries = try self.files.readDirCold(dir_path, &cold);
    // Speculative readDir-children prefetch (FIX_READDIR_PREFETCH): a
    // cold listing that is a directory-of-directories (pkgs/by-name:
    // 756 shard dirs) strongly predicts the demand fiber readDirs each
    // child next — serially, on the critical chain (~19ms measured in
    // the w=8 braid). Fan the child index space out to helpers, who
    // warm the FileCache ahead of that walk. Cache-only, error-
    // swallowing, deduped by coldness — demand-invisible.
    if (cold) maybePrefetchChildDirs(self, dir_path, dir_entries);
    var attrs: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer attrs.deinit(self.allocator);
    try attrs.ensureTotalCapacity(self.allocator, dir_entries.len);

    // The kind strings take one of four values — intern each once per call,
    // not once per entry (pkgs/by-name enumeration alone is ~20K entries,
    // and the redundant hash+shard-lock interning showed up on the
    // critical chain in the braid-window perf decomposition).
    var kind_values: [FileKindCount]?Value = @splat(null);
    for (dir_entries) |dir_entry| {
        const ki = @intFromEnum(dir_entry.kind);
        const kv = kind_values[ki] orelse blk: {
            const v = Value.string(try self.intern.intern(dir_entry.kind.nixTypeName()));
            kind_values[ki] = v;
            break :blk v;
        };
        attrs.appendAssumeCapacity(.{
            .name = try self.intern.intern(dir_entry.name),
            .value = kv,
        });
    }

    return Value.attrs(try self.heap.addAttrs(attrs.items));
}

const FileKindCount = @typeInfo(@import("runtime").file_cache.FileCache.FileKind).@"enum".fields.len;

/// Children per `readdir_prefetch` task: coarse enough to amortise the
/// queue+wake cost (a child listing is ~20-30µs of getdents), fine
/// enough that 756 by-name shards split across every idle helper.
const readdir_prefetch_batch = 32;

fn maybePrefetchChildDirs(
    self: anytype,
    dir_path: []const u8,
    dir_entries: []const FileCache.DirEntry,
) void {
    const min = self.scheduler.readdir_prefetch_min;
    if (min == 0) return; // off (w=1 / FIX_READDIR_PREFETCH=0)
    var ndirs: u32 = 0;
    for (dir_entries) |e| {
        if (e.kind == .directory) ndirs += 1;
    }
    if (ndirs < min) return;
    const granted = self.scheduler.readDirPrefetchTake(ndirs);
    if (granted == 0) return;
    // The task carries (parent intern id, child index range); the helper
    // re-reads the parent listing — a warm FileCache hit — and joins the
    // names itself, so the submitter pays one intern lookup, not one
    // allocation per child. Ranges cover the raw index space (non-dirs
    // are skipped helper-side): the mapping stays trivially stable.
    const dir_id = self.intern.intern(dir_path) catch return;
    var covered: u32 = 0; // directory-kind children covered so far
    var offset: u32 = 0;
    while (offset < dir_entries.len and covered < granted) {
        const len: u16 = @intCast(@min(dir_entries.len - offset, readdir_prefetch_batch));
        var dirs_in_batch: u32 = 0;
        for (dir_entries[offset..][0..len]) |e| {
            if (e.kind == .directory) dirs_in_batch += 1;
        }
        if (dirs_in_batch != 0) {
            // Urgent lane: this is demand-adjacent fan-out (the walk
            // starts within the same quantum), not a long-odds bet —
            // and the spec lane is typically deep in import-prefetch
            // backlog exactly when this fires. Rejection = queue full;
            // just stop, demand pays the old serial cost.
            if (!self.scheduler.submitUrgent(.{ .readdir_prefetch = .{
                .dir = dir_id,
                .offset = offset,
                .len = len,
            } }, self.workerId())) break;
            covered += dirs_in_batch;
        }
        offset += len;
    }
}

pub fn builtinFindFile(self: anytype, search_path_arg: Value, name_arg: Value) !Value {
    const search_path = try vm_force.forceValue(self, search_path_arg);
    if (!search_path.isList()) return error.TypeError;
    const name = try pathArg(self, name_arg);

    // `<nix/fetchurl.nix>` resolves to fix's synthetic corepkgs file rather
    // than any real search-path entry (mirrors `search_path.Paths.findFile`);
    // `builtins.fetchurl` and the corepkgs feature rely on it.
    if (std.mem.eql(u8, name, "nix/fetchurl.nix")) {
        return Value.path(try self.intern.intern("/__corepkgs__/fetchurl.nix"));
    }

    const path_id = try self.intern.intern("path");
    const prefix_id = try self.intern.intern("prefix");
    // gc: re-fetch — range may move across the force
    const list_id = search_path.asObjectId();
    const n = try self.heap.getListLen(list_id);
    var idx: usize = 0;
    while (idx < n) : (idx += 1) {
        const item = try self.heap.getListItem(list_id, idx);
        const entry = try vm_force.forceValue(self, item);
        if (!entry.isAttrs()) return error.TypeError;

        const base_value = try vm_force.forceValue(self, try self.heap.getAttrValue(entry.asObjectId(), path_id));
        const base = switch (base_value.kind()) {
            .path, .string, .string_context => self.intern.get(try stringTextInternId(self, base_value)),
            else => return error.TypeError,
        };

        const prefix_value = self.heap.getAttrValue(entry.asObjectId(), prefix_id) catch |err| switch (err) {
            error.MissingAttribute => Value.string(try self.intern.intern("")),
            else => return err,
        };
        const prefix_forced = try vm_force.forceValue(self, prefix_value);
        if (!isPlainString(prefix_forced)) return error.TypeError;
        const prefix = self.intern.get(try stringTextInternId(self, prefix_forced));

        if (try findFileCandidate(self, base, prefix, name)) |candidate| {
            defer self.allocator.free(candidate);
            return Value.path(try self.intern.intern(candidate));
        }
    }
    return error.FileNotFound;
}

pub fn findFileCandidate(self: anytype, base: []const u8, prefix: []const u8, name: []const u8) !?[]u8 {
    const suffix = path_ops.searchPathSuffix(prefix, name) orelse return null;
    const candidate = try std.fs.path.resolve(self.allocator, &.{ base, suffix });
    errdefer self.allocator.free(candidate);
    if (try self.files.pathExists(candidate)) return candidate;
    self.allocator.free(candidate);
    return null;
}
