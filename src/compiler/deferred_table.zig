//! Lazy per-attr compilation: the side table of deferred attrset value
//! bodies.
//!
//! A large generated attrset (e.g. nixpkgs `hackage-packages.nix`,
//! ~thousands of entries) compiles its value bodies *lazily* — each body
//! is registered here as an `Entry` (AST node + a snapshot of the
//! enclosing lexical scope) and emitted as a `.deferred` thunk
//! (`runtime/thunk.zig`). The body's bytecode is produced only when that
//! attr is first forced, so never-forced entries are never compiled. The
//! resulting `ChunkId` is cached on the entry (`compiled`) and shared
//! across all runtime instantiations.
//!
//! The table mirrors `ChunkRegistry`: `StableSegments` gives lock-free
//! `get` (the force path) and internally-serialized `append` (compile
//! time, possibly concurrent across workers compiling different files).

const std = @import("std");
const ast = @import("syntax").ast;
const types = @import("runtime").types;
const Capture = @import("types.zig").Capture;
const stable = @import("runtime").stable_segments;
const diagnostic = @import("syntax").diagnostic;

const InternId = types.InternId;

/// Gate tunables for lazy per-attr compilation (see `compiler/attrs.zig`).
///
/// `MIN_ENTRIES`: coarse pre-filter — only consider deferring in attrsets
/// with at least this many entries (skips the snapshot machinery for
/// small sets entirely).
pub const MIN_ENTRIES: usize = 64;

/// `MIN_BODY_BYTES`: the real lever. Defer a value body only if its
/// source span is at least this large. Body source-span size is a cheap
/// proxy for compile cost: deferral pays off only for EXPENSIVE bodies
/// (measured — 98% of deferred bodies are never forced, so the win is
/// skipping their compile; for cheap bodies the deferral overhead —
/// scope snapshot, env, table entry, arena retention — exceeds the
/// compile saved). This separates hackage-packages.nix's huge inline
/// `callPackage ({...}: mkDerivation {...}) {}` bodies (hundreds–thousands
/// of bytes, rarely forced) from all-packages.nix's tiny
/// `callPackage ../path {}` bodies (mostly forced). Tunable by measurement.
pub const MIN_BODY_BYTES: usize = 100;

/// `MAX_SCOPE`: cap on the enclosing-scope snapshot size. Keeps the env
/// gather cheap and bounds the runtime stack buffer. The hotspot needs 4.
pub const MAX_SCOPE: usize = 8;

/// One deferred value body. Structurally immutable after registration
/// except for `compiled`, the publish-once compile cache.
pub const Entry = struct {
    /// The value body's AST node (lives in an arena retained by the
    /// Evaluator for its lifetime — see `eval.zig` arena retention).
    node: *const ast.Node,
    /// Snapshot of the enclosing lexical scope, in declaration order:
    /// each `Capture` says how to fetch one visible binding's value from
    /// the *creating* frame (`.local` slot / `.upvalue` index). The
    /// `.deferred` thunk gathers these into its `env` at creation; the
    /// force-time compile presents them as the body's upvalues 0..k in
    /// this same order (see `compiler/deferred.zig`).
    scope: []const Capture,
    /// Source text for offset resolution. Retained for the evaluator
    /// lifetime (FileCache for imports; static for corepkgs).
    source: []const u8,
    /// Duped into the table's allocator: the originals are slices into
    /// the import's transient `stable_path`, freed when the import
    /// returns, but the force-time compile needs them later (e.g. relative
    /// path-literal resolution uses `base_path`).
    base_path: ?[]const u8,
    source_path: ?[]const u8,
    source_file_id: ?InternId,
    /// Compile cache: 0 = not yet compiled, else `ChunkId + 1`. Published
    /// once via CAS on the force path; concurrent racers converge on one
    /// canonical ChunkId (the loser's chunk is orphaned-but-correct).
    compiled: std.atomic.Value(u32) = .init(0),
};

pub const Table = struct {
    const Store = stable.StableSegments(*Entry, .{ .first_segment_size = 64 });

    allocator: std.mem.Allocator,
    entries: Store = .empty,
    /// Per-source line-index cache (keyed by source pointer). Force-time
    /// compiles of bodies from the same file share one line index instead
    /// of each rebuilding it over the whole (16MB+) source.
    line_indexes: std.AutoHashMapUnmanaged(usize, *diagnostic.LineIndex) = .{},
    line_index_mu: stable.SpinMutex = .{},

    pub fn init(allocator: std.mem.Allocator) Table {
        return .{ .allocator = allocator, .entries = .empty };
    }

    pub fn deinit(self: *Table) void {
        var id: u32 = 0;
        const total = self.entries.count();
        while (id < total) : (id += 1) {
            const e = self.entries.get(id).*;
            for (e.scope) |cap| self.allocator.free(cap.name);
            self.allocator.free(e.scope);
            if (e.base_path) |p| self.allocator.free(p);
            if (e.source_path) |p| self.allocator.free(p);
            self.allocator.destroy(e);
        }
        self.entries.deinit(self.allocator);
        var it = self.line_indexes.valueIterator();
        while (it.next()) |idx| {
            idx.*.deinit(self.allocator);
            self.allocator.destroy(idx.*);
        }
        self.line_indexes.deinit(self.allocator);
    }

    /// Get (building once, caching) the line index for `source`. Shared by
    /// all force-time compiles of bodies from the same file.
    pub fn lineIndexFor(self: *Table, source: []const u8) !*diagnostic.LineIndex {
        const key = @intFromPtr(source.ptr);
        self.line_index_mu.lock();
        defer self.line_index_mu.unlock();
        if (self.line_indexes.get(key)) |idx| return idx;
        const idx = try self.allocator.create(diagnostic.LineIndex);
        errdefer self.allocator.destroy(idx);
        idx.* = try diagnostic.LineIndex.init(self.allocator, source);
        try self.line_indexes.put(self.allocator, key, idx);
        return idx;
    }

    /// Register a deferred body and return its id (the operand the
    /// `defer_attr_value` op carries). `entry.scope` (and each `Capture`'s
    /// `name` bytes) is duped into the table's allocator; the caller may
    /// pass a temporary slice. The names must be owned here, not borrowed
    /// from `source`: some come from `attrSegmentNameAlloc` (a fresh
    /// allocation in the originating compile's scratch arena, e.g. parsed
    /// `"a b" = ...` keys or `rec` attr names), which is freed when that
    /// compile unit finishes. The force-time compile needs them later.
    pub fn register(self: *Table, entry: Entry) !u32 {
        const stored = try self.allocator.create(Entry);
        errdefer self.allocator.destroy(stored);
        stored.* = entry;
        const scope_copy = try self.allocator.dupe(Capture, entry.scope);
        errdefer self.allocator.free(scope_copy);
        var named: usize = 0;
        errdefer for (scope_copy[0..named]) |cap| self.allocator.free(cap.name);
        for (scope_copy) |*cap| {
            cap.name = try self.allocator.dupe(u8, cap.name);
            named += 1;
        }
        stored.scope = scope_copy;
        // base_path / source_path are transient (freed with the import's
        // stable_path) — dupe so the force-time compile can use them.
        stored.base_path = if (entry.base_path) |p| try self.allocator.dupe(u8, p) else null;
        errdefer if (stored.base_path) |p| self.allocator.free(p);
        stored.source_path = if (entry.source_path) |p| try self.allocator.dupe(u8, p) else null;
        errdefer if (stored.source_path) |p| self.allocator.free(p);
        return self.entries.append(self.allocator, stored);
    }

    pub fn get(self: *const Table, id: u32) *Entry {
        return self.entries.get(id).*;
    }

    /// Diagnostic: how many bodies were registered (deferred) vs actually
    /// compiled (forced). A low compiled/registered ratio is where lazy
    /// compilation pays off.
    pub fn stats(self: *const Table) struct { registered: u32, compiled: u32 } {
        var compiled: u32 = 0;
        var id: u32 = 0;
        const total = self.entries.count();
        while (id < total) : (id += 1) {
            if (self.entries.get(id).*.compiled.load(.monotonic) != 0) compiled += 1;
        }
        return .{ .registered = total, .compiled = compiled };
    }
};

const test_node: ast.Node = .{ .tag = .null, .data = .{ .atom = .{ .offset = 0, .len = 0 } }, .span = null };

test "register stores an entry retrievable by its returned id" {
    var table = Table.init(std.testing.allocator);
    defer table.deinit();

    const id = try table.register(.{
        .node = &test_node,
        .scope = &.{},
        .source = "irrelevant",
        .base_path = null,
        .source_path = null,
        .source_file_id = null,
    });

    const entry = table.get(id);
    try std.testing.expectEqual(&test_node, entry.node);
    try std.testing.expectEqual(@as(usize, 0), entry.scope.len);
}

test "register dupes scope capture names so the caller's buffer can be freed" {
    var table = Table.init(std.testing.allocator);
    defer table.deinit();

    var name_buf: [3]u8 = "foo".*;
    const caps = [_]Capture{.{ .name = &name_buf, .name_id = 7, .kind = .local, .index = 0 }};
    const id = try table.register(.{
        .node = &test_node,
        .scope = &caps,
        .source = "irrelevant",
        .base_path = null,
        .source_path = null,
        .source_file_id = null,
    });

    // Mutate the caller's buffer after registering: the table must hold
    // its own copy, not a borrowed slice into `name_buf`.
    @memset(&name_buf, 'x');

    const entry = table.get(id);
    try std.testing.expectEqualStrings("foo", entry.scope[0].name);
}

test "stats reports registered bodies as not-yet-compiled" {
    var table = Table.init(std.testing.allocator);
    defer table.deinit();

    _ = try table.register(.{
        .node = &test_node,
        .scope = &.{},
        .source = "irrelevant",
        .base_path = null,
        .source_path = null,
        .source_file_id = null,
    });
    _ = try table.register(.{
        .node = &test_node,
        .scope = &.{},
        .source = "irrelevant",
        .base_path = null,
        .source_path = null,
        .source_file_id = null,
    });

    const stats = table.stats();
    try std.testing.expectEqual(@as(u32, 2), stats.registered);
    try std.testing.expectEqual(@as(u32, 0), stats.compiled);
}

test "lineIndexFor caches the index for the same source pointer" {
    var table = Table.init(std.testing.allocator);
    defer table.deinit();

    const source = "a\nb\nc";
    const first = try table.lineIndexFor(source);
    const second = try table.lineIndexFor(source);
    try std.testing.expectEqual(first, second);
}
