//! `fix eval-jobs` — walk an attrset of derivations and stream one JSON object
//! per derivation to stdout, in the wire format `nix-eval-jobs` emits.
//!
//! CI systems consume that JSONL to decide what to build: each line carries the
//! attribute path, the `.drv` path, and its outputs, and a failing attribute
//! becomes an `error` record instead of aborting the run. This command exists so
//! such a pipeline can swap `nix-eval-jobs` for `fix` without changing the
//! consumer.
//!
//! Recursion follows nixpkgs' convention: descend into an attrset only when it
//! is marked `recurseForDerivations` (the top level is always descended), which
//! is what keeps the walk from diving into every package's `passthru`.

const std = @import("std");
const builtin = @import("builtin");
const engine = @import("expr");
const runtime_gc = @import("runtime").gc;
const args = @import("../args.zig");
const setup = @import("../setup.zig");
const config_discovery = @import("../config_discovery.zig");
const eval_support = @import("../eval_support.zig");
const realize = @import("../realize.zig");
const derivation_parse = @import("store").derivation.parse;
const stats = @import("../stats.zig");
const progress_ui = @import("../progress.zig");

const Engine = engine.Engine;
const Value = @import("runtime").value.Value;

pub const synopsis =
    \\usage: fix eval-jobs [options] [paths... | -E <expr>... | --flake <installable>...]
    \\
    \\evaluate an attrset of derivations and print one JSON object per derivation
    \\(nix-eval-jobs wire format) to stdout, one per line.
    \\
    \\  --check-cache-status   query the daemon and report isCached, cacheStatus,
    \\                         neededBuilds and neededSubstitutes
    \\  --force-recurse        descend into every attrset, ignoring
    \\                         recurseForDerivations
    \\  --gc-roots-dir DIR     register a GC root in DIR for every emitted .drv
    \\  --meta                 serialize each derivation's meta attrset into
    \\                         the record
    \\  --max-depth N          how deep to recurse (default: unlimited)
    \\  --max-memory-size MiB  recycle the evaluator when its heap exceeds this
    \\                         budget and resume after the last emitted job
    \\                         (0 = unlimited); process RSS peaks above the
    \\                         budget by the non-heap baseline
    \\
    \\an attribute that fails to evaluate yields an `error` record and does not
    \\stop the walk (exit stays 0, as consumers expect); only failing to
    \\evaluate the input at all exits nonzero.
;

/// Whether `s` needs no quoting inside a dotted attr path — a plain Nix
/// identifier: `[a-zA-Z_][a-zA-Z0-9_'-]*`.
fn isNixIdentifier(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s, 0..) |ch, i| {
        const ok = switch (ch) {
            'a'...'z', 'A'...'Z', '_' => true,
            '0'...'9', '\'', '-' => i != 0,
            else => false,
        };
        if (!ok) return false;
    }
    return true;
}

/// The dotted `attr` string, quoting non-identifier components exactly as
/// nix-eval-jobs does (`linuxKernel.packages."6.6"`), escaping `\` and `"`,
/// so a consumer can feed it back to `-A`/`--attr` unambiguously.
fn joinAttrPath(allocator: std.mem.Allocator, components: []const []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    for (components, 0..) |component, i| {
        if (i > 0) try out.append(allocator, '.');
        if (isNixIdentifier(component)) {
            try out.appendSlice(allocator, component);
        } else {
            try out.append(allocator, '"');
            for (component) |ch| {
                if (ch == '"' or ch == '\\') try out.append(allocator, '\\');
                try out.append(allocator, ch);
            }
            try out.append(allocator, '"');
        }
    }
    return out.toOwnedSlice(allocator);
}

test "attr paths quote non-identifier components" {
    const cases = [_]struct { in: []const []const u8, want: []const u8 }{
        .{ .in = &.{ "a", "b" }, .want = "a.b" },
        .{ .in = &.{ "linuxKernel", "packages", "6.6" }, .want = "linuxKernel.packages.\"6.6\"" },
        .{ .in = &.{"with\"quote"}, .want = "\"with\\\"quote\"" },
        .{ .in = &.{""}, .want = "\"\"" },
        .{ .in = &.{"x86_64-linux"}, .want = "x86_64-linux" },
    };
    for (cases) |case| {
        const got = try joinAttrPath(std.testing.allocator, case.in);
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings(case.want, got);
    }
}

/// A `("path",["out",...])` entry from a Derive ATerm's inputDrvs field.
/// Slices borrow from the ATerm text.
const InputDrvEntry = struct { path: []const u8, outputs: []const []const u8 };

/// Extract the inputDrvs field — the SECOND top-level list of a
/// `Derive([outputs],[inputDrvs],...)` ATerm. Store-path and output-name
/// strings never contain escapes in practice, but the scanner still skips
/// backslash escapes so a hostile ATerm cannot desynchronize it.
fn parseInputDrvs(allocator: std.mem.Allocator, aterm: []const u8) ![]InputDrvEntry {
    var entries: std.ArrayListUnmanaged(InputDrvEntry) = .empty;
    errdefer {
        for (entries.items) |entry| allocator.free(entry.outputs);
        entries.deinit(allocator);
    }
    const prefix = "Derive(";
    if (!std.mem.startsWith(u8, aterm, prefix)) return error.InvalidDrvAterm;
    var i: usize = prefix.len;

    const Scan = struct {
        fn string(text: []const u8, at: *usize) ![]const u8 {
            if (at.* >= text.len or text[at.*] != '"') return error.InvalidDrvAterm;
            at.* += 1;
            const start = at.*;
            while (at.* < text.len) : (at.* += 1) {
                switch (text[at.*]) {
                    '\\' => at.* += 1,
                    '"' => {
                        const s = text[start..at.*];
                        at.* += 1;
                        return s;
                    },
                    else => {},
                }
            }
            return error.InvalidDrvAterm;
        }
        fn skipBalanced(text: []const u8, at: *usize) !void {
            // Skip one balanced [...] or (...) group, strings included.
            var depth: usize = 0;
            while (at.* < text.len) : (at.* += 1) {
                switch (text[at.*]) {
                    '"' => {
                        _ = try string(text, at);
                        at.* -= 1; // loop increment rebalances
                    },
                    '[', '(' => depth += 1,
                    ']', ')' => {
                        depth -= 1;
                        if (depth == 0) {
                            at.* += 1;
                            return;
                        }
                    },
                    else => {},
                }
            }
            return error.InvalidDrvAterm;
        }
    };

    try Scan.skipBalanced(aterm, &i); // the outputs list
    if (i >= aterm.len or aterm[i] != ',') return error.InvalidDrvAterm;
    i += 1;
    if (i >= aterm.len or aterm[i] != '[') return error.InvalidDrvAterm;
    i += 1;
    while (i < aterm.len and aterm[i] != ']') {
        if (aterm[i] == ',') {
            i += 1;
            continue;
        }
        if (aterm[i] != '(') return error.InvalidDrvAterm;
        i += 1;
        const path = try Scan.string(aterm, &i);
        if (i >= aterm.len or aterm[i] != ',') return error.InvalidDrvAterm;
        i += 1;
        if (i >= aterm.len or aterm[i] != '[') return error.InvalidDrvAterm;
        i += 1;
        var outputs: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer outputs.deinit(allocator);
        while (i < aterm.len and aterm[i] != ']') {
            if (aterm[i] == ',') {
                i += 1;
                continue;
            }
            try outputs.append(allocator, try Scan.string(aterm, &i));
        }
        if (i >= aterm.len) return error.InvalidDrvAterm;
        i += 1; // ]
        if (i >= aterm.len or aterm[i] != ')') return error.InvalidDrvAterm;
        i += 1;
        try entries.append(allocator, .{ .path = path, .outputs = try outputs.toOwnedSlice(allocator) });
    }
    return entries.toOwnedSlice(allocator);
}

test "inputDrvs parse from a Derive aterm" {
    const aterm = "Derive([(\"out\",\"/nix/store/x-o\",\"\",\"\")],[(\"/nix/store/a.drv\",[\"out\"]),(\"/nix/store/b.drv\",[\"dev\",\"out\"])],[],\"s\",\"b\",[],[])";
    const parsed = try parseInputDrvs(std.testing.allocator, aterm);
    defer {
        for (parsed) |entry| std.testing.allocator.free(entry.outputs);
        std.testing.allocator.free(parsed);
    }
    try std.testing.expectEqual(@as(usize, 2), parsed.len);
    try std.testing.expectEqualStrings("/nix/store/a.drv", parsed[0].path);
    try std.testing.expectEqualStrings("dev", parsed[1].outputs[0]);
}

/// One JSONL record. Names match nix-eval-jobs (consumers parse by key, so
/// field order is free). `constituents`/`namedConstituents`/`globConstituents`
/// are the non-aggregate constants until Hydra aggregate support lands.
const Job = struct {
    attr: []const u8,
    attrPath: []const []const u8,
    name: ?[]const u8 = null,
    system: ?[]const u8 = null,
    drvPath: ?[]const u8 = null,
    outputs: ?std.json.ArrayHashMap([]const u8) = null,
    storeDir: ?[]const u8 = null,
    requiredSystemFeatures: ?[]const []const u8 = null,
    constituents: ?[]const []const u8 = null,
    namedConstituents: ?[]const []const u8 = null,
    globConstituents: ?bool = null,
    isCached: ?bool = null,
    cacheStatus: ?[]const u8 = null,
    neededBuilds: ?[]const []const u8 = null,
    neededSubstitutes: ?[]const []const u8 = null,
    @"error": ?[]const u8 = null,
    fatal: ?bool = null,
    meta: ?std.json.Value = null,
    extraValue: ?std.json.Value = null,
    inputDrvs: ?std.json.ArrayHashMap([]const []const u8) = null,
};

/// One reference inside an aggregate's `constituents` list: a job named by
/// its dotted attr path, or a derivation value referenced directly (already
/// resolved to its drvPath at walk time). Strings owned by the run allocator.
const ConstituentRef = union(enum) {
    name: []u8,
    direct: []u8,

    fn deinit(self: ConstituentRef, allocator: std.mem.Allocator) void {
        switch (self) {
            .name => |v| allocator.free(v),
            .direct => |v| allocator.free(v),
        }
    }
};

/// An `_hydraAggregate` job buffered during the walk. Everything the final
/// record needs is captured here (owned by the run allocator) because
/// resolution happens after the walk — possibly after engine recycles.
const PendingAggregate = struct {
    attr: []u8, // quoted, for the record
    plain_attr: []u8, // dotted, for name resolution
    attr_path: [][]u8,
    name: ?[]u8,
    system: ?[]u8,
    drv_path: []u8, // original; replaced on rewrite
    outputs: [][2][]u8, // original {name, path} pairs
    refs: []ConstituentRef,
    glob: bool,
    meta_json: ?[]u8,
    features: [][]u8,
    /// The aggregate's own ATerm, captured at walk time so the rewrite
    /// survives --max-memory-size engine recycling (the walking engine's
    /// in-memory recipe graph dies with its epoch). Null when the capture
    /// failed; the rewrite then consults the final engine's graph.
    recipe: ?[]u8 = null,

    fn deinit(self: *PendingAggregate, allocator: std.mem.Allocator) void {
        allocator.free(self.attr);
        allocator.free(self.plain_attr);
        for (self.attr_path) |c| allocator.free(c);
        allocator.free(self.attr_path);
        if (self.name) |v| allocator.free(v);
        if (self.system) |v| allocator.free(v);
        allocator.free(self.drv_path);
        for (self.outputs) |o| {
            allocator.free(o[0]);
            allocator.free(o[1]);
        }
        allocator.free(self.outputs);
        for (self.refs) |r| r.deinit(allocator);
        allocator.free(self.refs);
        if (self.meta_json) |v| allocator.free(v);
        if (self.recipe) |v| allocator.free(v);
        for (self.features) |f| allocator.free(f);
        allocator.free(self.features);
    }
};

/// --constituents run state: survives engine recycles (owned by run()).
const AggregateState = struct {
    /// dotted attr -> drvPath of every streamed (non-aggregate) job.
    resolved: std.StringHashMapUnmanaged([]u8) = .empty,
    aggregates: std.ArrayListUnmanaged(PendingAggregate) = .empty,

    fn deinit(self: *AggregateState, allocator: std.mem.Allocator) void {
        var it = self.resolved.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            allocator.free(e.value_ptr.*);
        }
        self.resolved.deinit(allocator);
        for (self.aggregates.items) |*agg| agg.deinit(allocator);
        self.aggregates.deinit(allocator);
    }
};

/// One buffered --check-cache-status record: the serialized JSON minus the
/// cache fields (spliced in at flush) plus the drv the query attributes to.
const BufferedRecord = struct {
    text: []u8,
    drv_path: []u8,

    fn deinit(self: BufferedRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        allocator.free(self.drv_path);
    }
};

/// A derivation's direct facts for closure walks, parsed once per drv.
const DrvDirect = struct {
    inputs: []InputRef,
    outputs: []OutputRef,

    /// One `inputDrvs` edge: the input's path and WHICH of its outputs this
    /// derivation consumes — what a per-job realization plan descends with.
    const InputRef = struct {
        path: []u8,
        wanted: [][]u8,
    };
    const OutputRef = struct {
        name: []u8,
        path: []u8,
    };

    fn deinit(self: DrvDirect, allocator: std.mem.Allocator) void {
        for (self.inputs) |input| {
            allocator.free(input.path);
            for (input.wanted) |w| allocator.free(w);
            allocator.free(input.wanted);
        }
        allocator.free(self.inputs);
        for (self.outputs) |output| {
            allocator.free(output.name);
            allocator.free(output.path);
        }
        allocator.free(self.outputs);
    }
};

const default_cache_chunk_size = 512;

/// `--check-cache-status` batch size; `FIX_CCS_CHUNK` overrides for
/// experiments, clamped to [1, 1024]. Measured on an 11k-job cold-network
/// walk: 512 → 87s; 4096 → the per-chunk realization plan covers so much
/// of the closure that attribution work and memory explode (73 min, then
/// OOM-killed, 202 records) — large chunks are pathological, not faster.
fn cacheChunkSize() usize {
    const raw = std.c.getenv("FIX_CCS_CHUNK") orelse return default_cache_chunk_size;
    const parsed = std.fmt.parseInt(usize, std.mem.span(raw), 10) catch return default_cache_chunk_size;
    return std.math.clamp(parsed, 1, 1024);
}

const Walker = struct {
    ev: *Engine,
    allocator: std.mem.Allocator,
    out: *std.Io.Writer,
    max_depth: usize,
    check_cache: bool,
    /// Resolved once at construction (`cacheChunkSize()` reads the env);
    /// consulted per emitted record on the hot path.
    cache_chunk_limit: usize = default_cache_chunk_size,
    force_recurse: bool = false,
    include_meta: bool = false,
    /// --no-instantiate: no GC roots, and requiredSystemFeatures is absent
    /// (nix-eval-jobs reads it from the written .drv, which doesn't exist).
    no_instantiate: bool = false,
    /// --apply: a function Value applied to each derivation; the result is
    /// serialized into the record's `extraValue`.
    apply_fn: ?Value = null,
    show_input_drvs: bool = false,
    /// --constituents: run-owned aggregate state; null when off.
    agg: ?*AggregateState = null,
    gc_roots_dir: ?[]const u8 = null,
    io: ?std.Io = null,
    state_dir: []const u8 = "",
    link_buf: [std.fs.max_path_bytes]u8 = undefined,
    /// Evaluator-heap budget in bytes; 0 = unlimited. Exceeding it (even
    /// after a full collection) aborts the walk with `error.MemoryBudget`
    /// and `cursor_out` set, so the caller can recycle the engine and
    /// resume after the last processed attribute.
    budget_bytes: u64 = 0,
    /// Process RSS at epoch start (Linux); growth beyond the budget trips
    /// the ceiling. See budgetExceeded.
    epoch_rss_base: u64 = 0,
    /// Resume-after attribute path from a previous engine epoch. While
    /// active, already-processed attributes are skipped without forcing.
    cursor: ?[]const []u8 = null,
    cursor_active: bool = false,
    /// Set when `error.MemoryBudget` is returned: the path of the last
    /// fully processed attribute (owned by the walker's allocator).
    cursor_out: ?[][]u8 = null,
    failures: usize = 0,
    emitted: usize = 0,
    cache_warned: bool = false,
    /// --check-cache-status: records buffer here (rendered WITHOUT the cache
    /// fields) and flush per chunk through ONE batched daemon query — the
    /// per-job round trip was ~55ms x jobs (>10 minutes on an 11k walk).
    cache_chunk: std.ArrayListUnmanaged(BufferedRecord) = .empty,
    /// drv -> direct inputs + own output paths, parsed once from the
    /// recorded ATerm and shared by every job's closure walk.
    drv_memo: std.StringHashMapUnmanaged(DrvDirect) = .empty,

    /// Descend `value`, emitting a record per derivation found. `path` is the
    /// attribute path walked so far. Errors from a single attribute are caught
    /// and reported as records, mirroring nix-eval-jobs' per-attribute isolation.
    fn walk(self: *Walker, value: Value, path: *std.ArrayListUnmanaged([]const u8), depth: usize) !void {
        var forced = self.ev.forceValue(value) catch |err| return self.emitError(path, err);
        // nix-eval-jobs auto-calls functions met during the walk — plain
        // formals lambdas AND functor attrsets (__functor unwraps to the
        // underlying lambda): all-default formals evaluate and the result is
        // walked, a defaultless formal is an error job, everything else
        // (plain lambdas, builtins, ordinary attrsets) passes through.
        switch (self.ev.walkFunctionCall(forced) catch |err| return self.emitError(path, err)) {
            .called => |result| forced = result,
            .missing_argument => |name| {
                const message = try std.fmt.allocPrint(self.allocator, "cannot evaluate a function that has an argument without a value ('{s}')", .{name});
                defer self.allocator.free(message);
                return self.emitErrorMessage(path, message);
            },
            .not_function => {},
        }
        if (!forced.isAttrs()) {
            // A non-attrset root is a usage error, not an empty universe.
            // nix-eval-jobs reports it as an error record for the root job.
            if (depth == 0) return self.emitErrorMessage(path, "top-level value is not an attribute set of derivations");
            return;
        }

        if (try self.isDerivation(forced)) return self.emitDerivation(forced, path);
        if (depth >= self.max_depth) return;
        // Only `recurseForDerivations` sets are walked (the root always is), so
        // a package's own attributes are not mistaken for more jobs.
        if (depth > 0 and !self.force_recurse and !(try self.recurses(forced))) return;
        // The root is always descended — EXCEPT when it explicitly opts out
        // with `recurseForDerivations = false`, which nix-eval-jobs honors
        // even at the top level (nixpkgs scopes like python3Packages carry
        // it). --force-recurse overrides, as it does everywhere.
        if (depth == 0 and !self.force_recurse and try self.recursesExplicitlyFalse(forced)) return;

        const names = (try self.ev.attrNames(self.allocator, forced)) orelse return;
        defer self.allocator.free(names);
        // The loop below forces each child to completion — including any source
        // fetch — before touching the next, so on a set of packages whose srcs
        // are separate repositories the fetches serialize behind the walk. Hand
        // the whole level to the helpers first: every child is about to be
        // walked, so this is guaranteed work, and their I/O now overlaps.
        // While resuming, the level's prefix is already done — accelerating
        // it would re-force emitted subtrees for nothing. Siblings after the
        // resume point lose this level's overlap; the next level regains it.
        if (!self.cursor_active) self.accelerateLevel(forced, names);
        for (names) |name| {
            if (self.cursor_active) {
                const cur = self.cursor.?;
                if (depth >= cur.len) {
                    self.cursor_active = false;
                } else switch (std.mem.order(u8, name, cur[depth])) {
                    // Before the resume point: already processed last epoch.
                    .lt => continue,
                    .eq => if (depth + 1 == cur.len) {
                        // The resume-after leaf itself — done last epoch.
                        self.cursor_active = false;
                        continue;
                    },
                    // The cursor names a child this level no longer has;
                    // process everything from here on normally.
                    .gt => self.cursor_active = false,
                }
            }
            // Everything this child roots across the native boundary is
            // released once its records are written; the values stay live
            // through the walk root, so this only bounds the root array.
            const mark = self.ev.gcExternalRootsMark();
            defer self.ev.gcReleaseExternalRootsTo(mark);
            const child = self.ev.getAttr(forced, name) catch |err| {
                try path.append(self.allocator, name);
                defer _ = path.pop();
                try self.emitError(path, err);
                continue;
            } orelse continue;
            try path.append(self.allocator, name);
            defer _ = path.pop();
            try self.walk(child, path, depth + 1);
            if (self.overBudget()) {
                self.cursor_out = try dupePathOwned(self.allocator, path.items);
                return error.MemoryBudget;
            }
        }
    }

    /// Start this level's work on the helpers before walking it sequentially.
    /// One `force_drv_child` task per child carries it from WHNF through its
    /// `type`/`drvPath` reads entirely on a helper — the expensive part
    /// (instantiation pulls sources into the store) never lands on the walk
    /// thread, which previously pre-forced every child serially just to find
    /// the derivations. Best-effort: a failure here only costs the overlap,
    /// since the walk forces everything itself anyway.
    fn accelerateLevel(self: *Walker, forced: Value, names: []const []const u8) void {
        _ = names;
        self.ev.accelerateJobLevel(forced) catch return;
    }

    fn isDerivation(self: *Walker, forced: Value) !bool {
        const ty = (try self.ev.stringAttr(forced, "type")) orelse return false;
        return std.mem.eql(u8, ty, "derivation");
    }

    /// True when the budget is still exceeded after a full collection —
    /// time to recycle the engine.
    fn overBudget(self: *Walker) bool {
        if (self.budget_bytes == 0) return false;
        if (!self.budgetExceeded()) return false;
        _ = self.ev.collectNow();
        return self.budgetExceeded();
    }

    /// The ceiling holds when EITHER metric exceeds it: reserved evaluator-
    /// heap bytes (portable, always current), or — Linux only — the RSS
    /// GROWTH since this epoch began, which also sees what the heap counter
    /// cannot (interned strings, bytecode, native buffers). Absolute RSS is
    /// the wrong signal twice over: darwin only exposes the high-water mark,
    /// and even Linux's current reading ratchets across epochs because the
    /// allocator retains freed pages — measured as a 10,655-recycle storm.
    /// Growth-since-epoch-start is immune: reused retained pages do not
    /// grow RSS, so only genuinely new memory counts.
    fn budgetExceeded(self: *Walker) bool {
        if (self.ev.heapReservedBytes() > self.budget_bytes) return true;
        if (comptime builtin.os.tag == .linux) {
            const rss = runtime_gc.currentRssBytes();
            if (rss > self.epoch_rss_base and rss - self.epoch_rss_base > self.budget_bytes) return true;
        }
        return false;
    }

    fn recursesExplicitlyFalse(self: *Walker, forced: Value) !bool {
        const attr = (self.ev.getAttr(forced, "recurseForDerivations") catch return false) orelse return false;
        const v = self.ev.forceValue(attr) catch return false;
        return v.isBool() and !v.asBool();
    }

    fn recurses(self: *Walker, forced: Value) !bool {
        const attr = (self.ev.getAttr(forced, "recurseForDerivations") catch return false) orelse return false;
        const v = self.ev.forceValue(attr) catch return false;
        return v.isBool() and v.asBool();
    }

    /// The derivation's `requiredSystemFeatures` as a string list (owned
    /// outer slice, borrowed strings), or null when absent/not a list.
    fn requiredSystemFeatures(self: *Walker, forced: Value) !?[]const []const u8 {
        const attr = (try self.ev.getAttr(forced, "requiredSystemFeatures")) orelse return null;
        const items = (try self.ev.listItems(self.allocator, attr)) orelse return null;
        defer self.allocator.free(items);
        var features: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer features.deinit(self.allocator);
        for (items) |item| {
            if (self.ev.stringValue(item) catch null) |text| try features.append(self.allocator, text);
        }
        return try features.toOwnedSlice(self.allocator);
    }

    /// The `meta` attrset rendered through the evaluator's JSON writer and
    /// re-parsed so the record embeds it as structured JSON. Null when
    /// absent or when any member fails to evaluate.
    /// `meta` serialized ATTRIBUTE BY ATTRIBUTE, as nix-eval-jobs does.
    /// Rendering the attrset wholesale would hit Nix's toJSON coercion rule —
    /// any attrset containing `outPath` collapses to that string — so a
    /// `meta.outPath` (nixpkgs sets it via placeholder) would swallow every
    /// other meta field. A member that fails to render is skipped.
    fn renderedMeta(self: *Walker, forced: Value) ?std.json.Parsed(std.json.Value) {
        const meta_attr = (self.ev.getAttr(forced, "meta") catch return null) orelse return null;
        const meta = self.ev.forceValue(meta_attr) catch return null;
        if (!meta.isAttrs()) return null;
        const names = (self.ev.attrNames(self.allocator, meta) catch return null) orelse return null;
        defer self.allocator.free(names);

        var text: std.Io.Writer.Allocating = .init(self.allocator);
        defer text.deinit();
        text.writer.writeByte('{') catch return null;
        var first = true;
        for (names) |name| {
            const value = (self.ev.getAttr(meta, name) catch continue) orelse continue;
            var rendered: std.Io.Writer.Allocating = .init(self.allocator);
            defer rendered.deinit();
            self.ev.writeJsonValue(&rendered.writer, value) catch continue;
            if (!first) text.writer.writeByte(',') catch return null;
            first = false;
            std.json.Stringify.value(name, .{}, &text.writer) catch return null;
            text.writer.writeByte(':') catch return null;
            text.writer.writeAll(rendered.written()) catch return null;
        }
        text.writer.writeByte('}') catch return null;
        return std.json.parseFromSlice(std.json.Value, self.allocator, text.written(), .{}) catch null;
    }

    /// `value` rendered through the evaluator's JSON writer and re-parsed so
    /// the record embeds it as structured JSON. Null on any render failure.
    fn renderedJson(self: *Walker, value: Value) ?std.json.Parsed(std.json.Value) {
        var rendered: std.Io.Writer.Allocating = .init(self.allocator);
        defer rendered.deinit();
        self.ev.writeJsonValue(&rendered.writer, value) catch return null;
        return std.json.parseFromSlice(std.json.Value, self.allocator, rendered.written(), .{}) catch null;
    }

    fn emitDerivation(self: *Walker, forced: Value, path: *std.ArrayListUnmanaged([]const u8)) !void {
        const drv_path = self.ev.derivationDrvPath(forced) catch |err| return self.emitError(path, err);
        if (drv_path == null) return self.emitError(path, error.NotADerivation);

        // A job whose `name` or `system` cannot be evaluated is an error
        // record, as in nix-eval-jobs — silently omitting the field would
        // leave a consumer routing the build with no system.
        const name = self.ev.stringAttr(forced, "name") catch |err| return self.emitError(path, err);
        const system = self.derivationSystem(forced) catch |err| return self.emitError(path, err);

        // `outputs` lists the derivation's output names; each maps to its store
        // path. A derivation without the attr still has `out`.
        var outputs: std.json.ArrayHashMap([]const u8) = .{};
        defer outputs.map.deinit(self.allocator);
        if (try self.ev.getAttr(forced, "outputs")) |outs| {
            if (try self.outputNames(outs)) |names| {
                defer self.allocator.free(names);
                for (names) |output_name| {
                    const out_attr = (self.ev.getAttr(forced, output_name) catch continue) orelse continue;
                    const store_path = (self.ev.stringAttr(out_attr, "outPath") catch continue) orelse continue;
                    try outputs.map.put(self.allocator, output_name, store_path);
                }
            }
        }
        if (outputs.map.count() == 0) {
            if (self.ev.derivationOutPath(forced) catch null) |out_path| {
                try outputs.map.put(self.allocator, "out", out_path);
            }
        }

        // --constituents: an `_hydraAggregate` job is buffered for the
        // post-walk resolution pass instead of being emitted; every other
        // job is recorded in the name-resolution map as it streams.
        if (self.agg) |agg| {
            const is_aggregate = blk: {
                const attr = (self.ev.getAttr(forced, "_hydraAggregate") catch null) orelse break :blk false;
                const v = self.ev.forceValue(attr) catch break :blk false;
                break :blk v.isBool() and v.asBool();
            };
            if (is_aggregate) {
                self.bufferAggregate(agg, forced, path, drv_path.?, &outputs) catch |err| return self.emitError(path, err);
                return;
            }
            const plain = try std.mem.join(self.allocator, ".", path.items);
            errdefer self.allocator.free(plain);
            const entry = try agg.resolved.getOrPut(self.allocator, plain);
            if (entry.found_existing) {
                self.allocator.free(plain);
            } else {
                entry.value_ptr.* = try self.allocator.dupe(u8, drv_path.?);
            }
        }

        // Emitted whether or not the attr is set (as []) since nix-eval-jobs
        // v2.32.1, so schedulers don't need --meta to route builds.
        const features = if (self.no_instantiate) null else self.requiredSystemFeatures(forced) catch null;
        defer if (features) |v| self.allocator.free(v);

        // --meta: the meta attrset rendered to JSON. Strict rendering can hit
        // a broken meta member (a throwing license, say); the record then
        // omits `meta` rather than becoming an error, since the build itself
        // is unaffected.
        var meta_parsed: ?std.json.Parsed(std.json.Value) = null;
        defer if (meta_parsed) |*parsed| parsed.deinit();
        if (self.include_meta) meta_parsed = self.renderedMeta(forced);

        // --apply: call the user's function on the derivation value and
        // embed the rendered result. An apply error is the job's error.
        var extra_parsed: ?std.json.Parsed(std.json.Value) = null;
        defer if (extra_parsed) |*parsed| parsed.deinit();
        if (self.apply_fn) |apply_fn| {
            const applied = self.ev.callFunction(apply_fn, forced) catch |err| return self.emitError(path, err);
            extra_parsed = self.renderedJson(applied);
        }

        // --show-input-drvs: the direct input derivations, from the recorded
        // ATerm of the drv this record names. Omitted when unavailable.
        var input_drvs: ?std.json.ArrayHashMap([]const []const u8) = null;
        var input_aterm: ?[]u8 = null;
        var input_entries: []InputDrvEntry = &.{};
        defer {
            if (input_drvs) |*map| map.map.deinit(self.allocator);
            for (input_entries) |entry| self.allocator.free(entry.outputs);
            if (input_entries.len > 0) self.allocator.free(input_entries);
            if (input_aterm) |bytes| self.allocator.free(bytes);
        }
        if (self.show_input_drvs) {
            if (self.ev.drvRecipeText(self.allocator, drv_path.?) catch null) |aterm| {
                input_aterm = aterm;
                if (parseInputDrvs(self.allocator, aterm)) |parsed| {
                    input_entries = parsed;
                    var map: std.json.ArrayHashMap([]const []const u8) = .{};
                    for (parsed) |entry| try map.map.put(self.allocator, entry.path, entry.outputs);
                    input_drvs = map;
                } else |_| {}
            }
        }

        const job = Job{
            .attr = try joinAttrPath(self.allocator, path.items),
            .attrPath = path.items,
            .name = name,
            .system = system,
            .drvPath = drv_path,
            .outputs = outputs,
            .storeDir = self.ev.storeDir(),
            .requiredSystemFeatures = if (self.no_instantiate) null else features orelse &.{},
            .constituents = &.{},
            .namedConstituents = &.{},
            .globConstituents = false,
            .meta = if (meta_parsed) |parsed| parsed.value else null,
            .extraValue = if (extra_parsed) |parsed| parsed.value else null,
            .inputDrvs = input_drvs,
        };
        defer self.allocator.free(job.attr);

        if (self.check_cache) {
            try self.bufferForCacheStatus(job, drv_path.?);
            if (self.cache_chunk.items.len >= self.cache_chunk_limit) try self.flushCacheChunk();
        } else {
            try self.write(job);
        }
        self.emitted += 1;
        if (!self.no_instantiate) {
            if (self.gc_roots_dir) |dir| self.registerGcRoot(dir, drv_path.?);
        }
    }

    /// Capture everything an aggregate's record will need once its
    /// constituents resolve after the walk. Owned by the run allocator so it
    /// survives engine recycles.
    fn bufferAggregate(self: *Walker, agg: *AggregateState, forced: Value, path: *std.ArrayListUnmanaged([]const u8), drv_path: []const u8, outputs: *std.json.ArrayHashMap([]const u8)) !void {
        const gpa = self.allocator;
        var refs: std.ArrayListUnmanaged(ConstituentRef) = .empty;
        errdefer {
            for (refs.items) |r| r.deinit(gpa);
            refs.deinit(gpa);
        }
        if (try self.ev.getAttr(forced, "constituents")) |list_attr| {
            if (try self.ev.listItems(gpa, list_attr)) |items| {
                defer gpa.free(items);
                for (items) |item| {
                    const v = try self.ev.forceValue(item);
                    if (self.ev.stringValue(v) catch null) |text| {
                        // A derivation value string-coerces to its outPath —
                        // but a direct reference arrives as an attrset below,
                        // so a plain string here is a job NAME.
                        try refs.append(gpa, .{ .name = try gpa.dupe(u8, text) });
                    } else if (v.isAttrs()) {
                        const c_drv = (self.ev.derivationDrvPath(v) catch null) orelse return error.InvalidConstituent;
                        try refs.append(gpa, .{ .direct = try gpa.dupe(u8, c_drv) });
                    } else return error.InvalidConstituent;
                }
            }
        }
        const glob = blk: {
            const attr = (self.ev.getAttr(forced, "_hydraGlobConstituents") catch null) orelse break :blk false;
            const v = self.ev.forceValue(attr) catch break :blk false;
            break :blk v.isBool() and v.asBool();
        };

        var out_pairs: std.ArrayListUnmanaged([2][]u8) = .empty;
        errdefer {
            for (out_pairs.items) |o| {
                gpa.free(o[0]);
                gpa.free(o[1]);
            }
            out_pairs.deinit(gpa);
        }
        var out_it = outputs.map.iterator();
        while (out_it.next()) |e| {
            try out_pairs.append(gpa, .{ try gpa.dupe(u8, e.key_ptr.*), try gpa.dupe(u8, e.value_ptr.*) });
        }

        var attr_path: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer {
            for (attr_path.items) |c| gpa.free(c);
            attr_path.deinit(gpa);
        }
        for (path.items) |c| try attr_path.append(gpa, try gpa.dupe(u8, c));

        const meta_json: ?[]u8 = if (self.include_meta) meta: {
            var parsed = self.renderedMeta(forced) orelse break :meta null;
            defer parsed.deinit();
            var text: std.Io.Writer.Allocating = .init(gpa);
            errdefer text.deinit();
            std.json.Stringify.value(parsed.value, .{}, &text.writer) catch {
                text.deinit();
                break :meta null;
            };
            break :meta try text.toOwnedSlice();
        } else null;

        const features_src = (if (self.no_instantiate) null else self.requiredSystemFeatures(forced) catch null) orelse &[_][]const u8{};
        defer if (features_src.len > 0) gpa.free(@constCast(features_src));
        var features: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer {
            for (features.items) |f| gpa.free(f);
            features.deinit(gpa);
        }
        for (features_src) |f| try features.append(gpa, try gpa.dupe(u8, f));

        const name = self.ev.stringAttr(forced, "name") catch null;
        const system = self.derivationSystem(forced) catch null;
        // Capture the aggregate's ATerm NOW: the recipe lives in THIS
        // engine's in-memory graph, and under --max-memory-size recycling
        // this engine is gone by the time emitAggregates rewrites against
        // the final epoch's engine. Best-effort — on null the rewrite falls
        // back to the final engine's graph (correct in single-epoch runs).
        const recipe = self.ev.drvRecipeText(gpa, drv_path) catch null;
        try agg.aggregates.append(gpa, .{
            .attr = try joinAttrPath(gpa, path.items),
            .plain_attr = try std.mem.join(gpa, ".", path.items),
            .attr_path = try attr_path.toOwnedSlice(gpa),
            .name = if (name) |v| try gpa.dupe(u8, v) else null,
            .system = if (system) |v| try gpa.dupe(u8, v) else null,
            .drv_path = try gpa.dupe(u8, drv_path),
            .outputs = try out_pairs.toOwnedSlice(gpa),
            .refs = try refs.toOwnedSlice(gpa),
            .glob = glob,
            .meta_json = meta_json,
            .features = try features.toOwnedSlice(gpa),
            .recipe = recipe,
        });
    }

    /// `--gc-roots-dir`: an indirect GC root per emitted `.drv`, named after
    /// its basename (as nix-eval-jobs' addPermRoot does), so a store GC
    /// between evaluation and build cannot delete the derivations. An
    /// existing link is left alone — re-runs skip the daemon round trip.
    fn registerGcRoot(self: *Walker, dir: []const u8, drv_path: []const u8) void {
        const io = self.io orelse return;
        const link = std.fs.path.join(self.allocator, &.{ dir, std.fs.path.basename(drv_path) }) catch return;
        defer self.allocator.free(link);
        if (std.Io.Dir.cwd().readLink(io, link, &self.link_buf)) |_| return else |_| {}
        realize.linkRoot(io, false, self.allocator, self.ev, self.state_dir, link, drv_path, true);
    }

    /// nix-eval-jobs' `isCached` means "nothing has to be built" — a path the
    /// daemon can substitute counts as cached. Ask the daemon what realizing the
    /// derivation would require; anything in `will_build` means a real build.
    ///
    /// `neededBuilds`/`neededSubstitutes` report what this query returned for
    /// the derivation's own outputs plus its `.drv` closure. nix-eval-jobs
    /// reports the whole transitive build closure there, so its lists are a
    /// superset of these; `isCached` and `cacheStatus` agree either way, and
    /// those are the fields a build pipeline branches on.
    fn bufferForCacheStatus(self: *Walker, job: Job, drv_path: []const u8) !void {
        var text: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer text.deinit();
        try std.json.Stringify.value(job, .{ .emit_null_optional_fields = false }, &text.writer);
        try self.cache_chunk.append(self.allocator, .{
            .text = try text.toOwnedSlice(),
            .drv_path = try self.allocator.dupe(u8, drv_path),
        });
    }

    /// One daemon query for the whole chunk (`drv!*` + bare drv per record,
    /// as the per-job query sent), then per-job attribution: a job needs a
    /// build iff any drv in ITS OWN closure is in the merged will-build set —
    /// exactly what its individual query would have reported. Closures come
    /// from the recorded ATerms, natively.
    pub fn flushCacheChunk(self: *Walker) !void {
        if (self.cache_chunk.items.len == 0) return;
        const gpa = self.allocator;
        defer {
            for (self.cache_chunk.items) |rec| rec.deinit(gpa);
            self.cache_chunk.clearRetainingCapacity();
        }

        var specs: std.ArrayListUnmanaged([]const u8) = .empty;
        defer {
            for (specs.items) |spec| gpa.free(spec);
            specs.deinit(gpa);
        }
        for (self.cache_chunk.items) |rec| {
            // `!` selects outputs in the worker protocol (the CLI's `^` is an
            // illegal path character to the daemon); the bare .drv carries
            // the inputSrcs that nix-eval-jobs also reports.
            try specs.append(gpa, try std.fmt.allocPrint(gpa, "{s}!*", .{rec.drv_path}));
            try specs.append(gpa, try gpa.dupe(u8, rec.drv_path));
        }

        const debug_ccs = std.c.getenv("FIX_CCS_DEBUG") != null;
        var plan = self.ev.queryMissing(specs.items) catch |err| {
            if (!self.cache_warned) {
                self.cache_warned = true;
                std.debug.print("warning: --check-cache-status: daemon query failed ({s}: {s}); cache fields omitted\n", .{ @errorName(err), self.ev.lastStoreError() orelse "no detail" });
            }
            for (self.cache_chunk.items) |rec| {
                try self.out.writeAll(rec.text);
                try self.out.writeByte('\n');
            }
            try self.out.flush();
            return;
        };
        defer plan.deinit();

        var will_build: std.StringHashMapUnmanaged(void) = .empty;
        defer will_build.deinit(gpa);
        for (plan.will_build) |path| try will_build.put(gpa, path, {});
        var will_substitute: std.StringHashMapUnmanaged(void) = .empty;
        defer will_substitute.deinit(gpa);
        for (plan.will_substitute) |path| try will_substitute.put(gpa, path, {});
        var unknown: std.StringHashMapUnmanaged(void) = .empty;
        defer unknown.deinit(gpa);
        for (plan.unknown) |path| try unknown.put(gpa, path, {});

        if (debug_ccs) std.debug.print("ccs: chunk={d} specs={d} will_build={d} will_substitute={d} unknown={d}\n", .{ self.cache_chunk.items.len, specs.items.len, plan.will_build.len, plan.will_substitute.len, plan.unknown.len });

        const Work = struct {
            drv: []const u8,
            /// Output NAMES the consumer wants; null = all (the record root's
            /// own spec was `drv!*`).
            wanted: ?[]const []const u8,
        };
        var stack: std.ArrayListUnmanaged(Work) = .empty;
        defer stack.deinit(gpa);
        var visited: std.StringHashMapUnmanaged(void) = .empty;
        defer visited.deinit(gpa);

        for (self.cache_chunk.items) |rec| {
            stack.clearRetainingCapacity();
            visited.clearRetainingCapacity();

            // Emulate the realization plan the per-job query would produce.
            // Substitution truncates the graph: when every output the
            // CONSUMER wants from a node is substitutable, that node's
            // inputs are never needed — even if the node sits in the merged
            // plan's will_build because some OTHER job's wanted-output union
            // forced it. (Descending through merged will_build regardless
            // both over-attributed neededBuilds vs the per-job semantics
            // and made per-chunk cost superlinear in chunk size — the
            // chunk=4096 OOM.)
            var needed_builds: std.ArrayListUnmanaged([]const u8) = .empty;
            defer needed_builds.deinit(gpa);
            var needed_subs: std.ArrayListUnmanaged([]const u8) = .empty;
            defer needed_subs.deinit(gpa);
            var has_unknown = false;
            try stack.append(gpa, .{ .drv = rec.drv_path, .wanted = null });
            while (stack.pop()) |item| {
                const entry = try visited.getOrPut(gpa, item.drv);
                if (entry.found_existing) continue;
                if (unknown.contains(item.drv)) has_unknown = true;
                const direct = try self.drvDirect(item.drv) orelse {
                    // No recipe to consult — fall back to merged-plan
                    // membership alone.
                    if (will_build.contains(item.drv)) try needed_builds.append(gpa, item.drv);
                    continue;
                };
                // Resolve the wanted output names to paths; `null` = all.
                var all_substitutable = true;
                var any_wanted = false;
                for (direct.outputs) |output| {
                    const is_wanted = item.wanted == null or blk: {
                        for (item.wanted.?) |w| {
                            if (std.mem.eql(u8, w, output.name)) break :blk true;
                        }
                        break :blk false;
                    };
                    if (!is_wanted) continue;
                    any_wanted = true;
                    // The daemon's `unknown` list holds OUTPUT paths whose
                    // validity it could not determine (no substituters /
                    // read-only) — nix-eval-jobs reports such jobs notBuilt.
                    if (unknown.contains(output.path)) has_unknown = true;
                    if (!will_substitute.contains(output.path)) all_substitutable = false;
                }
                if (any_wanted and all_substitutable) {
                    // Substitution boundary for THIS consumer: report the
                    // fetched outputs, never descend.
                    for (direct.outputs) |output| {
                        const is_wanted = item.wanted == null or blk: {
                            for (item.wanted.?) |w| {
                                if (std.mem.eql(u8, w, output.name)) break :blk true;
                            }
                            break :blk false;
                        };
                        if (is_wanted) try needed_subs.append(gpa, output.path);
                    }
                    continue;
                }
                if (will_build.contains(item.drv)) {
                    try needed_builds.append(gpa, item.drv);
                    for (direct.inputs) |input| {
                        try stack.append(gpa, .{ .drv = input.path, .wanted = @ptrCast(input.wanted) });
                    }
                }
                // Neither substitutable-for-us nor building: locally valid
                // boundary — nothing needed.
            }

            if (debug_ccs) std.debug.print("ccs: {s} visited={d} builds={d} subs={d}\n", .{ rec.drv_path, visited.count(), needed_builds.items.len, needed_subs.items.len });
            const must_build = needed_builds.items.len != 0 or has_unknown;
            const status: []const u8 = if (must_build) "notBuilt" else if (needed_subs.items.len != 0) "cached" else "local";
            // Splice the cache fields into the buffered record, before the
            // closing brace (a record always has at least one field).
            try self.out.writeAll(rec.text[0 .. rec.text.len - 1]);
            try self.out.writeAll(if (must_build) ",\"isCached\":false" else ",\"isCached\":true");
            try self.out.print(",\"cacheStatus\":\"{s}\"", .{status});
            try self.out.writeAll(",\"neededBuilds\":");
            try std.json.Stringify.value(@as([]const []const u8, needed_builds.items), .{}, self.out);
            try self.out.writeAll(",\"neededSubstitutes\":");
            try std.json.Stringify.value(@as([]const []const u8, needed_subs.items), .{}, self.out);
            try self.out.writeAll("}\n");
        }
        try self.out.flush();
    }

    /// Parse (once) a drv's recorded ATerm into its direct inputs + outputs.
    fn drvDirect(self: *Walker, drv_path: []const u8) !?DrvDirect {
        if (self.drv_memo.get(drv_path)) |direct| return direct;
        const aterm = (self.ev.drvRecipeText(self.allocator, drv_path) catch null) orelse return null;
        defer self.allocator.free(aterm);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const parsed = derivation_parse.parseDrv(arena.allocator(), aterm) catch return null;
        var inputs: std.ArrayListUnmanaged(DrvDirect.InputRef) = .empty;
        for (parsed.input_drvs) |input| {
            var wanted: std.ArrayListUnmanaged([]u8) = .empty;
            for (input.outputs) |name| try wanted.append(self.allocator, try self.allocator.dupe(u8, name));
            try inputs.append(self.allocator, .{
                .path = try self.allocator.dupe(u8, input.path),
                .wanted = try wanted.toOwnedSlice(self.allocator),
            });
        }
        var outputs: std.ArrayListUnmanaged(DrvDirect.OutputRef) = .empty;
        for (parsed.outputs) |output| try outputs.append(self.allocator, .{
            .name = try self.allocator.dupe(u8, output.name),
            .path = try self.allocator.dupe(u8, output.path),
        });
        const direct = DrvDirect{
            .inputs = try inputs.toOwnedSlice(self.allocator),
            .outputs = try outputs.toOwnedSlice(self.allocator),
        };
        try self.drv_memo.put(self.allocator, try self.allocator.dupe(u8, drv_path), direct);
        return direct;
    }

    fn deinitCacheState(self: *Walker) void {
        for (self.cache_chunk.items) |rec| rec.deinit(self.allocator);
        self.cache_chunk.deinit(self.allocator);
        var it = self.drv_memo.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.drv_memo.deinit(self.allocator);
    }

    /// Copy the plan's path strings out before `plan.deinit()` frees them, and
    /// as `[]const u8` — `std.json` only renders a byte slice as a string when
    /// its element type is const, so mutable slices serialize as number arrays.
    fn dupePaths(allocator: std.mem.Allocator, paths: [][]u8) ![]const []const u8 {
        const out = try allocator.alloc([]const u8, paths.len);
        errdefer allocator.free(out);
        for (paths, 0..) |p, i| out[i] = try allocator.dupe(u8, p);
        return out;
    }

    fn freePaths(allocator: std.mem.Allocator, paths: []const []const u8) void {
        for (paths) |p| allocator.free(p);
        allocator.free(paths);
    }

    /// The system the derivation will be BUILT for, which is what nix-eval-jobs
    /// reports. `drvAttrs.system` is the value that went into the derivation; the
    /// top-level `.system` attribute is the package set's own idea of its system
    /// and differs for a cross stdenv (`aarch64-none` vs the `x86_64-linux` the
    /// .drv is actually built on). A build pipeline routes work by this field.
    /// Eval errors propagate (the caller makes them error records); a merely
    /// absent attribute stays null.
    fn derivationSystem(self: *Walker, forced: Value) !?[]const u8 {
        if (try self.ev.getAttr(forced, "drvAttrs")) |drv_attrs| {
            if (try self.ev.stringAttr(drv_attrs, "system")) |system| return system;
        }
        return try self.ev.stringAttr(forced, "system");
    }

    fn outputNames(self: *Walker, outs: Value) !?[][]const u8 {
        const forced = self.ev.forceValue(outs) catch return null;
        if (!forced.isList()) return null;
        const items = try self.ev.listItems(self.allocator, forced) orelse return null;
        defer self.allocator.free(items);
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer names.deinit(self.allocator);
        for (items) |item| {
            if (self.ev.stringValue(item) catch null) |name| try names.append(self.allocator, name);
        }
        return try names.toOwnedSlice(self.allocator);
    }

    fn emitError(self: *Walker, path: *std.ArrayListUnmanaged([]const u8), err: anyerror) anyerror!void {
        switch (err) {
            // Infrastructure failures poison the whole run: converting them
            // into per-job error records would keep walking a compromised
            // substrate and fabricate thousands of bogus records. Rethrow.
            error.OutOfMemory, error.WriteFailed => return err,
            // CLI-synthesized errors have no engine trace behind them — a
            // stale `lastErrorMessage` from an earlier attribute's failure
            // must not attach to this record.
            error.NotADerivation => return self.emitErrorMessage(path, "attribute is not a derivation"),
            error.InvalidConstituent => return self.emitErrorMessage(path, "constituent is not a derivation or job name"),
            else => {},
        }
        // A stack overflow is FATAL, as in nix-eval-jobs (whose worker dies
        // on it): the record carries fatal:true and the run exits 1 — the
        // walk stops rather than pretending the rest is trustworthy.
        if (err == error.StackOverflow or err == error.FrameOverflow) {
            try self.emitErrorRecord(path, self.ev.lastErrorMessage() orelse "stack overflow; max-call-depth exceeded", true);
            return error.FatalJob;
        }
        // Prefer the evaluator's rendered message; fall back to the error name.
        return self.emitErrorMessage(path, self.ev.lastErrorMessage() orelse @errorName(err));
    }

    fn emitErrorMessage(self: *Walker, path: *std.ArrayListUnmanaged([]const u8), message: []const u8) !void {
        return self.emitErrorRecord(path, message, false);
    }

    fn emitErrorRecord(self: *Walker, path: *std.ArrayListUnmanaged([]const u8), message: []const u8, fatal: bool) !void {
        self.failures += 1;
        const attr = try joinAttrPath(self.allocator, path.items);
        defer self.allocator.free(attr);
        try self.write(.{
            .attr = attr,
            .attrPath = path.items,
            .@"error" = message,
            .fatal = fatal,
        });
    }

    /// One compact JSON object per line, flushed immediately so a consumer can
    /// stream (and so a crash mid-walk does not lose completed records).
    fn write(self: *Walker, job: Job) !void {
        return writeJob(self.out, job);
    }
};

pub fn run(process: @import("../process_context.zig").ProcessContext, init: std.process.Init, args_iter: *std.process.Args.Iterator) !u8 {
    const allocator = process.allocator;
    var diag: args.Diag = .{};
    var options = args.parse(allocator, args_iter, null, .eval_jobs, &diag) catch |err| switch (err) {
        error.Help => {
            args.writeHelp(init.io, synopsis, .eval_jobs);
            return 0;
        },
        else => {
            std.debug.print("error: {s}\n\n{s}\n", .{ args.errorMessage(err), synopsis });
            return 2;
        },
    };
    defer options.deinit(allocator);

    const worker_count = try setup.workerCount(&options);
    const memory_backing = setup.applyMemoryBacking(process, options.hugetlb);
    var settings = try config_discovery.loadLocal(allocator, init, &options);
    config_discovery.fetchFlakeSettings(allocator, init, &options, &settings);
    defer settings.deinit();
    const budget_bytes: u64 = @as(u64, options.max_memory_size) << 20;

    const input_plan = eval_support.InputPlan.init(&options, init.io);
    const input_count = try input_plan.count();

    var stdout_buf: [64 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);

    // Two failure classes with different exit consequences, mirroring
    // nix-eval-jobs: a job that errors becomes an `error` record and the
    // process still exits 0 (consumers scan the records — buildbot-nix and
    // Hydra both do); only failing to evaluate at all (unreadable input,
    // unparseable source) is a process failure.
    var fatal_failures: usize = 0;
    var job_failures: usize = 0;

    // Memory ceiling by engine recycling: when the heap budget is exceeded,
    // the whole engine is torn down (full reclamation — the walked tree is
    // reachable from its root by design, so no in-place collection can drop
    // it) and a fresh one resumes AFTER the last emitted job via `cursor`.
    // Unlike nix-eval-jobs' worker restarts, warm fetch caches and the store
    // fast paths make the replayed prefix cheap, records are never
    // re-emitted, and each recycle amortizes over many jobs.
    var cursor: ?[][]u8 = null;
    defer freeCursor(allocator, &cursor);
    var agg_state: ?AggregateState = if (options.constituents) .{} else null;
    defer if (agg_state) |*aggs| aggs.deinit(allocator);
    // Hash-modulo records carried across engine recycles (--constituents
    // only — that's the consumer of cross-epoch drv references).
    var carried_records: ?[]Engine.ExportedDrvRecord = null;
    defer freeCarriedRecords(allocator, &carried_records);
    var validated = false;
    var index: usize = 0;
    epoch: while (index < input_count) {
        var ev = try Engine.init(allocator, setup.engineConfig(init, worker_count, memory_backing, &options));
        var session = setup.Session.init(&ev);
        defer session.deinit(.full);
        const term = try session.configure(init, &options, &settings);
        if (carried_records) |records| ev.seedDrvRecords(records) catch {};
        // eval-jobs walks fan demand out over thousands of independent attrs,
        // which saturates the workers on its own; the speculative lanes only
        // duplicate that work (measured: ~25% extra CPU and slower walls at
        // every worker count on a nixpkgs-scale walk). Run demand-only —
        // import/readDir prefetch stays on, and `FIX_SPEC=1` re-enables the
        // speculative lanes for experiments.
        ev.setParallelismToggles(true, options.disable_fanout);
        if (!validated) {
            input_plan.validate(&ev) catch |err| {
                std.debug.print("error: {s}\n\n{s}\n", .{ args.errorMessage(err), synopsis });
                return 2;
            };
            validated = true;
        }
        var progress = try progress_ui.Session.init(
            allocator,
            init.io,
            &ev,
            term,
            &options,
            if (input_count == 1) eval_support.sourceLabel(input_plan.selected(0).source_arg) else "multiple inputs",
        );
        var epoch_ok = false;
        defer progress.deinit(epoch_ok);
        progress.install();

        // Writing `.drv` files is what makes the emitted drvPaths realizable,
        // and is what nix-eval-jobs does; --check-cache-status additionally
        // needs the daemon to answer path-validity queries. --no-instantiate
        // skips the writes (drvPaths are still computed), as nix-eval-jobs'
        // read-only mode does.
        if (!options.no_instantiate) ev.enableStoreWrites();

        while (index < input_count) {
            var input = input_plan.loadAutoCall(&ev, index) catch |err| {
                eval_support.reportInputReadError(init.io, term.use_color, input_count, index, err);
                fatal_failures += 1;
                index += 1;
                continue;
            };
            defer input.deinit(&ev);
            const source = input.source;
            var root = ev.evaluatePathAt(source.slice(), source.base_path, source.abs_path) catch |err| {
                _ = try eval_support.storeOrEvalFailure(init.io, term.use_color, options.show_trace, &ev, source.slice(), err);
                fatal_failures += 1;
                index += 1;
                continue;
            };
            // --select: the walked root is the user's function applied to the
            // evaluated root. A select failure is fatal — nothing was walked.
            if (options.select_expr) |expr| {
                root = selectRoot(&ev, expr, root) catch |err| {
                    _ = try eval_support.storeOrEvalFailure(init.io, term.use_color, options.show_trace, &ev, expr, err);
                    fatal_failures += 1;
                    index += 1;
                    continue;
                };
            }
            const apply_fn: ?Value = if (options.apply_expr) |expr|
                evalFunctionExpr(&ev, expr) catch |err| {
                    _ = try eval_support.storeOrEvalFailure(init.io, term.use_color, options.show_trace, &ev, expr, err);
                    fatal_failures += 1;
                    index += 1;
                    continue;
                }
            else
                null;

            var walker = Walker{
                .ev = &ev,
                .allocator = allocator,
                .out = &stdout.interface,
                .max_depth = options.max_depth,
                .check_cache = options.check_cache_status,
                .cache_chunk_limit = cacheChunkSize(),
                .force_recurse = options.force_recurse,
                .include_meta = options.meta,
                .no_instantiate = options.no_instantiate,
                .apply_fn = apply_fn,
                .show_input_drvs = options.show_input_drvs,
                .agg = if (agg_state) |*aggs| aggs else null,
                .gc_roots_dir = options.gc_roots_dir,
                .io = init.io,
                .state_dir = setup.stateDir(init),
                .budget_bytes = budget_bytes,
                .epoch_rss_base = if (builtin.os.tag == .linux) runtime_gc.currentRssBytes() else 0,
                .cursor = if (cursor) |c| c else null,
                .cursor_active = cursor != null,
            };
            var fatal_job = false;
            const completed = complete: {
                var path: std.ArrayListUnmanaged([]const u8) = .empty;
                defer path.deinit(allocator);
                walker.walk(root, &path, 0) catch |err| switch (err) {
                    error.MemoryBudget => break :complete false,
                    error.FatalJob => {
                        fatal_job = true;
                        break :complete true;
                    },
                    else => return err,
                };
                break :complete true;
            };
            // Flush any buffered --check-cache-status chunk while THIS
            // engine is still alive (its recipe graph feeds the closure
            // attribution) — also on the memory-budget and fatal paths.
            walker.flushCacheChunk() catch |err| switch (err) {
                else => {
                    walker.deinitCacheState();
                    return err;
                },
            };
            walker.deinitCacheState();
            job_failures += walker.failures;
            if (fatal_job) fatal_failures += 1;
            if (!completed) {
                freeCursor(allocator, &cursor);
                cursor = walker.cursor_out;
                walker.cursor_out = null;
                // Hash-modulo records are pure content facts; carry them so
                // cross-epoch drv references (aggregate rewrites resolving a
                // constituent emitted in an earlier epoch) still resolve
                // after this engine's in-memory graph is torn down.
                if (agg_state != null) {
                    const exported = ev.exportDrvRecords(allocator) catch null;
                    if (exported) |records| {
                        freeCarriedRecords(allocator, &carried_records);
                        carried_records = records;
                    }
                }
                std.debug.print("note: --max-memory-size reached; recycling the evaluator\n", .{});
                epoch_ok = true;
                continue :epoch;
            }
            freeCursor(allocator, &cursor);
            index += 1;
        }
        // Aggregates resolve once the whole walk is done — names may point
        // forward, and rewrites need every constituent's recorded drv.
        if (agg_state) |*aggs| {
            job_failures += try emitAggregates(allocator, &ev, &stdout.interface, aggs, options.gc_roots_dir, init.io, setup.stateDir(init));
        }
        try stdout.interface.flush();
        if (options.stats) stats.report(&ev);
        epoch_ok = fatal_failures == 0 and job_failures == 0;
        break;
    }
    try stdout.interface.flush();
    if (std.c.getenv("FIX_IO_STATS") != null) {
        var buf: [512]u8 = undefined;
        var err_writer = std.Io.File.stderr().writerStreaming(init.io, &buf);
        @import("store").file_cache.io_stats.dump(&err_writer.interface);
        err_writer.interface.flush() catch {};
    }
    return if (fatal_failures == 0) 0 else 1;
}

/// Evaluate `expr` (parenthesized) to a function value for --apply/--select.
fn evalFunctionExpr(ev: *Engine, expr: []const u8) !Value {
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(ev.hostAllocator());
    try text.append(ev.hostAllocator(), '(');
    try text.appendSlice(ev.hostAllocator(), expr);
    try text.appendSlice(ev.hostAllocator(), "\n)");
    return ev.forceValue(try ev.evaluate(text.items));
}

fn selectRoot(ev: *Engine, expr: []const u8, root: Value) !Value {
    return ev.callFunction(try evalFunctionExpr(ev, expr), root);
}

fn writeJob(out: *std.Io.Writer, job: Job) !void {
    try std.json.Stringify.value(job, .{ .emit_null_optional_fields = false }, out);
    try out.writeByte('\n');
    try out.flush();
}

fn freeCarriedRecords(gpa: std.mem.Allocator, carried: *?[]Engine.ExportedDrvRecord) void {
    const records = carried.* orelse return;
    for (records) |r| r.deinit(gpa);
    gpa.free(records);
    carried.* = null;
}

fn appendFmt(list: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator, comptime fmt: []const u8, fmt_args: anytype) !void {
    const msg = try std.fmt.allocPrint(gpa, fmt, fmt_args);
    defer gpa.free(msg);
    try list.appendSlice(gpa, msg);
}

/// Glob match with `*` and `?` (the subset Hydra constituent patterns use).
/// Iterative single-backtrack form, O(pattern × text) worst case — the naive
/// recursion is exponential on patterns like `a*a*a*a*b`, and patterns come
/// from jobset-controlled Nix code run against every streamed job name.
fn globMatch(pattern: []const u8, text: []const u8) bool {
    var p: usize = 0;
    var t: usize = 0;
    var star: ?usize = null;
    var star_t: usize = 0;
    while (t < text.len) {
        if (p < pattern.len and (pattern[p] == '?' or pattern[p] == text[t])) {
            p += 1;
            t += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            star = p;
            star_t = t;
            p += 1;
        } else if (star) |s| {
            p = s + 1;
            star_t += 1;
            t = star_t;
        } else return false;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

test "globMatch: literals, ?, *, backtracking, adversarial" {
    try std.testing.expect(globMatch("abc", "abc"));
    try std.testing.expect(!globMatch("abc", "abd"));
    try std.testing.expect(globMatch("a?c", "abc"));
    try std.testing.expect(globMatch("*", ""));
    try std.testing.expect(globMatch("*", "anything"));
    try std.testing.expect(globMatch("a*b", "ab"));
    try std.testing.expect(globMatch("a*b", "axxxb"));
    try std.testing.expect(!globMatch("a*b", "axxxc"));
    try std.testing.expect(globMatch("*.x86_64-linux", "jobs.foo.x86_64-linux"));
    try std.testing.expect(globMatch("a*a*a*a*b", "a" ** 40 ++ "b"));
    try std.testing.expect(!globMatch("a*a*a*a*b", "a" ** 40));
}

fn isGlobPattern(pattern: []const u8) bool {
    return std.mem.indexOfAny(u8, pattern, "*?") != null;
}

/// Resolve and emit the buffered `_hydraAggregate` jobs, in buffer (walk)
/// order: exact names against streamed jobs and other aggregates (whose
/// REWRITTEN drvPaths are used — resolution recurses in dependency order),
/// glob patterns when `_hydraGlobConstituents`, a two-party cycle as the
/// same error on both members, and missing names appended to the record's
/// error (which also skips the rewrite). Returns the number of aggregates
/// that errored.
fn emitAggregates(
    gpa: std.mem.Allocator,
    ev: *Engine,
    out: *std.Io.Writer,
    state: *AggregateState,
    gc_roots_dir: ?[]const u8,
    io: std.Io,
    state_dir: []const u8,
) !usize {
    const n = state.aggregates.items.len;
    if (n == 0) return 0;

    var index_of: std.StringHashMapUnmanaged(usize) = .empty;
    defer index_of.deinit(gpa);
    for (state.aggregates.items, 0..) |agg, i| try index_of.put(gpa, agg.plain_attr, i);

    const Status = enum { pending, resolving, done };
    const status = try gpa.alloc(Status, n);
    defer gpa.free(status);
    @memset(status, .pending);
    const errors = try gpa.alloc(std.ArrayListUnmanaged(u8), n);
    defer {
        for (errors) |*e| e.deinit(gpa);
        gpa.free(errors);
    }
    @memset(errors, .empty);
    const resolved = try gpa.alloc(std.ArrayListUnmanaged([]const u8), n);
    defer {
        for (resolved) |*r| r.deinit(gpa);
        gpa.free(resolved);
    }
    @memset(resolved, .empty);

    const Ctx = struct {
        gpa: std.mem.Allocator,
        ev: *Engine,
        state: *AggregateState,
        index_of: *std.StringHashMapUnmanaged(usize),
        status: []Status,
        errors: []std.ArrayListUnmanaged(u8),
        resolved: []std.ArrayListUnmanaged([]const u8),

        fn resolve(ctx: *@This(), i: usize) anyerror!void {
            switch (ctx.status[i]) {
                .done => return,
                .resolving => return, // cycle: handled by the caller that saw it
                .pending => {},
            }
            ctx.status[i] = .resolving;
            defer ctx.status[i] = .done;
            const agg = &ctx.state.aggregates.items[i];
            defer ctx.rewrite(i) catch {};

            // Direct references first, then resolved names — the order
            // nix-eval-jobs produces (directs enter the drv during eval,
            // named ones only after resolution).
            for (agg.refs) |ref| switch (ref) {
                .direct => |path| try ctx.resolved[i].append(ctx.gpa, path),
                .name => {},
            };
            for (agg.refs) |ref| switch (ref) {
                .direct => {},
                .name => |pattern| {
                    if (agg.glob and isGlobPattern(pattern)) {
                        var matches: std.ArrayListUnmanaged([]const u8) = .empty;
                        defer matches.deinit(ctx.gpa);
                        var it = ctx.state.resolved.keyIterator();
                        while (it.next()) |key| {
                            if (globMatch(pattern, key.*)) try matches.append(ctx.gpa, key.*);
                        }
                        for (ctx.state.aggregates.items, 0..) |other, j| {
                            if (j != i and globMatch(pattern, other.plain_attr))
                                try matches.append(ctx.gpa, other.plain_attr);
                        }
                        if (matches.items.len == 0) {
                            try appendFmt(&ctx.errors[i], ctx.gpa, "{s}: constituent glob pattern had no matches\n", .{pattern});
                            continue;
                        }
                        std.mem.sort([]const u8, matches.items, {}, struct {
                            fn lt(_: void, a: []const u8, b: []const u8) bool {
                                return std.mem.lessThan(u8, a, b);
                            }
                        }.lt);
                        for (matches.items) |m| try ctx.appendNamed(i, m);
                    } else {
                        if (ctx.state.resolved.get(pattern) == null and ctx.index_of.get(pattern) == null) {
                            try appendFmt(&ctx.errors[i], ctx.gpa, "{s}: does not exist\n", .{pattern});
                            continue;
                        }
                        try ctx.appendNamed(i, pattern);
                    }
                },
            };
        }

        /// Rewrite `i`'s drv once its refs resolved cleanly. Runs at the end
        /// of resolve() so any dependent that captures this aggregate's
        /// drvPath afterwards sees the REWRITTEN identity.
        fn rewrite(ctx: *@This(), i: usize) !void {
            if (ctx.errors[i].items.len != 0) return;
            const agg = &ctx.state.aggregates.items[i];
            const rewritten = (blk: {
                // Prefer the walk-time ATerm capture — the walking engine's
                // recipe graph is gone after a --max-memory-size recycle.
                if (agg.recipe) |text| break :blk @as(?Engine.RewrittenAggregate, ctx.ev.rewriteAggregateDrvFromText(ctx.gpa, text, ctx.resolved[i].items) catch |err| {
                    try appendFmt(&ctx.errors[i], ctx.gpa, "could not rewrite aggregate: {s}\n", .{@errorName(err)});
                    return;
                });
                break :blk ctx.ev.rewriteAggregateDrv(ctx.gpa, agg.drv_path, ctx.resolved[i].items) catch |err| {
                    try appendFmt(&ctx.errors[i], ctx.gpa, "could not rewrite aggregate: {s}\n", .{@errorName(err)});
                    return;
                };
            }) orelse {
                try appendFmt(&ctx.errors[i], ctx.gpa, "could not rewrite aggregate: no recorded derivation\n", .{});
                return;
            };
            // Allocate the replacement BEFORE freeing the old outputs: an OOM
            // after the frees would leave `agg.outputs` dangling — the caller
            // swallows rewrite errors, then the emit loop iterates it and
            // deinit frees it again (use-after-free + double free).
            const pairs = try ctx.gpa.alloc([2][]u8, rewritten.outputs.len);
            for (rewritten.outputs, 0..) |o, k| pairs[k] = .{ o.name, o.path };
            ctx.gpa.free(rewritten.outputs);
            ctx.gpa.free(agg.drv_path);
            agg.drv_path = rewritten.drv_path;
            for (agg.outputs) |o| {
                ctx.gpa.free(o[0]);
                ctx.gpa.free(o[1]);
            }
            ctx.gpa.free(agg.outputs);
            agg.outputs = pairs;
        }

        fn appendNamed(ctx: *@This(), i: usize, name: []const u8) !void {
            if (ctx.state.resolved.get(name)) |path| {
                try ctx.resolved[i].append(ctx.gpa, path);
                return;
            }
            const j = ctx.index_of.get(name) orelse unreachable;
            if (ctx.status[j] == .resolving) {
                // A dependency cycle: the same diagnostic on both members,
                // parties in name order, and neither is rewritten.
                const a = ctx.state.aggregates.items[i].plain_attr;
                const b = ctx.state.aggregates.items[j].plain_attr;
                const first = if (std.mem.lessThan(u8, a, b)) a else b;
                const second = if (std.mem.lessThan(u8, a, b)) b else a;
                for ([_]usize{ i, j }) |k| {
                    ctx.errors[k].clearRetainingCapacity();
                    try appendFmt(&ctx.errors[k], ctx.gpa, "Dependency cycle: {s} <-> {s}", .{ first, second });
                }
                return;
            }
            try ctx.resolve(j);
            // A cycle discovered inside that resolution may have written this
            // aggregate's own error; nothing more to record then.
            if (ctx.errors[i].items.len != 0) return;
            if (ctx.errors[j].items.len != 0) {
                try appendFmt(&ctx.errors[i], ctx.gpa, "{s}: does not exist\n", .{name});
                return;
            }
            try ctx.resolved[i].append(ctx.gpa, ctx.state.aggregates.items[j].drv_path);
        }
    };
    var ctx = Ctx{ .gpa = gpa, .ev = ev, .state = state, .index_of = &index_of, .status = status, .errors = errors, .resolved = resolved };

    // Resolve in buffer order; each aggregate rewrites at the end of its own
    // resolution, so dependents always capture post-rewrite identities.
    for (0..n) |i| try ctx.resolve(i);

    // Emission, buffer order.
    var failures: usize = 0;
    for (state.aggregates.items, 0..) |*agg, i| {
        var outputs: std.json.ArrayHashMap([]const u8) = .{};
        defer outputs.map.deinit(gpa);
        for (agg.outputs) |o| try outputs.map.put(gpa, o[0], o[1]);
        var meta_parsed: ?std.json.Parsed(std.json.Value) = null;
        defer if (meta_parsed) |*parsed| parsed.deinit();
        if (agg.meta_json) |text| meta_parsed = std.json.parseFromSlice(std.json.Value, gpa, text, .{}) catch null;

        const attr_path_const: []const []const u8 = @ptrCast(agg.attr_path);
        const features_const: []const []const u8 = @ptrCast(agg.features);
        const failed = errors[i].items.len != 0;
        if (failed) failures += 1;
        try writeJob(out, .{
            .attr = agg.attr,
            .attrPath = attr_path_const,
            .name = agg.name,
            .system = agg.system,
            .drvPath = agg.drv_path,
            .outputs = outputs,
            .storeDir = ev.storeDir(),
            .requiredSystemFeatures = features_const,
            .constituents = resolved[i].items,
            .globConstituents = agg.glob,
            .meta = if (meta_parsed) |parsed| parsed.value else null,
            .@"error" = if (failed) errors[i].items else null,
        });
        if (!failed) {
            if (gc_roots_dir) |dir| {
                const link = std.fs.path.join(gpa, &.{ dir, std.fs.path.basename(agg.drv_path) }) catch continue;
                defer gpa.free(link);
                var buf: [std.fs.max_path_bytes]u8 = undefined;
                if (std.Io.Dir.cwd().readLink(io, link, &buf)) |_| continue else |_| {}
                realize.linkRoot(io, false, gpa, ev, state_dir, link, agg.drv_path, true);
            }
        }
    }
    return failures;
}

fn freeCursor(allocator: std.mem.Allocator, cursor: *?[][]u8) void {
    if (cursor.*) |components| {
        for (components) |component| allocator.free(component);
        allocator.free(components);
        cursor.* = null;
    }
}

fn dupePathOwned(allocator: std.mem.Allocator, components: []const []const u8) ![][]u8 {
    const out = try allocator.alloc([]u8, components.len);
    errdefer allocator.free(out);
    var done: usize = 0;
    errdefer for (out[0..done]) |component| allocator.free(component);
    for (components, 0..) |component, i| {
        out[i] = try allocator.dupe(u8, component);
        done += 1;
    }
    return out;
}
