//! `fix thunks diff` — find divergent thunk resolutions across two
//! `--thunks-log` outputs.
//!
//! Use case: a multi-worker eval produces a wrong answer that a
//! single-worker eval doesn't. Both runs recorded a thunks-log. We
//! want to identify the first thunks that resolved differently —
//! keyed by the *creator* source location, since chunk and thunk ids
//! aren't stable across runs but `(file, line, col)` is.
//!
//! Algorithm (two streaming passes per log):
//!   1. Pass 1: read every `kind=create` event, build
//!      `thunk_id → creator (file, line, col)` map.
//!   2. Pass 2: read every `kind=resolve|errored|reset` event, look
//!      up the creator location via the map, accumulate outcomes
//!      per location into a histogram.
//!
//! Output: list locations whose outcome multisets differ between
//! the two logs, sorted by the earliest seq number observed at the
//! location in either log (so the report flows causally).

const std = @import("std");
const presentation = @import("presentation.zig");

const usage =
    \\usage: fix thunks <subcommand> [args]
    \\
    \\subcommands:
    \\  diff A B   compare two thunks-logs and report locations
    \\             where the multiset of resolve/errored/reset
    \\             outcomes differs.
    \\
    \\to record a log:
    \\  fix eval --thunks-log=PATH -e EXPR
    \\
    \\options for diff:
    \\  --asymmetric          show only locations where one side has
    \\                        an outcome the other side never produced
    \\                        (smoking-gun for speculation races).
    \\  --novel-in a|b        like --asymmetric but only the direction
    \\                        where the named side has the novel
    \\                        outcome. `--novel-in b` is the canonical
    \\                        filter for "B forced something A never
    \\                        reached".
    \\  --by-kind             compare outcomes by kind+discriminant
    \\                        only, ignoring value contents. Reduces
    \\                        false positives from non-deterministic
    \\                        iteration orders.
    \\  --max-divergences N   cap on divergent locations to print
    \\                        (default 30).
    \\  --max-outcomes N      per-location outcome examples to show
    \\                        (default 5).
    \\
;

pub fn run(allocator: std.mem.Allocator, init: std.process.Init, args_iter: *std.process.Args.Iterator) !u8 {
    _ = allocator;
    const sub = args_iter.next() orelse {
        std.debug.print("{s}", .{usage});
        return 2;
    };
    if (std.mem.eql(u8, sub, "diff")) return runDiff(init, args_iter);
    if (presentation.isHelpFlag(sub)) {
        presentation.printHelp(init.io, usage);
        return 0;
    }
    std.debug.print("error: unknown subcommand '{s}'\n\n{s}", .{ sub, usage });
    return 2;
}

const SideFilter = enum { both, novel_in_a, novel_in_b };

const DiffOptions = struct {
    max_divergences: usize = 30,
    max_outcomes: usize = 5,
    path_a: []const u8,
    path_b: []const u8,
    /// Show only locations where one side has outcomes the other
    /// doesn't. Surfaces the "this thunk was forced in B but never in
    /// A" pattern that races in the speculation system produce.
    asymmetric_only: bool = false,
    /// When `asymmetric_only` is on, optionally restrict to one
    /// direction. `--novel-in b` is the canonical filter for
    /// "speculation in B produced a thunk resolution that the
    /// reference (A) never reached".
    side: SideFilter = .both,
    /// Compare outcomes by *kind* only (resolve/errored/reset +
    /// discriminant), ignoring concrete values. Reduces noise from
    /// non-deterministic iteration orders (same attrset rendered
    /// with attributes in different order) so only structural
    /// divergences — e.g. a thunk that errored in one run but
    /// resolved in the other — remain.
    by_kind: bool = false,
};

fn runDiff(init: std.process.Init, args_iter: *std.process.Args.Iterator) !u8 {
    var path_a: ?[]const u8 = null;
    var path_b: ?[]const u8 = null;
    var max_divergences: usize = 30;
    var max_outcomes: usize = 5;
    var asymmetric_only: bool = false;
    var side: SideFilter = .both;
    var by_kind: bool = false;

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--asymmetric")) {
            asymmetric_only = true;
        } else if (std.mem.eql(u8, arg, "--by-kind")) {
            by_kind = true;
        } else if (std.mem.eql(u8, arg, "--novel-in")) {
            asymmetric_only = true;
            const v = args_iter.next() orelse {
                std.debug.print("error: --novel-in requires 'a' or 'b'\n", .{});
                return 2;
            };
            if (std.mem.eql(u8, v, "a")) {
                side = .novel_in_a;
            } else if (std.mem.eql(u8, v, "b")) {
                side = .novel_in_b;
            } else {
                std.debug.print("error: --novel-in expects 'a' or 'b'\n", .{});
                return 2;
            }
        } else if (std.mem.eql(u8, arg, "--max-divergences")) {
            const v = args_iter.next() orelse {
                std.debug.print("error: --max-divergences requires a value\n", .{});
                return 2;
            };
            max_divergences = std.fmt.parseInt(usize, v, 10) catch {
                std.debug.print("error: invalid --max-divergences\n", .{});
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "--max-outcomes")) {
            const v = args_iter.next() orelse {
                std.debug.print("error: --max-outcomes requires a value\n", .{});
                return 2;
            };
            max_outcomes = std.fmt.parseInt(usize, v, 10) catch {
                std.debug.print("error: invalid --max-outcomes\n", .{});
                return 2;
            };
        } else if (path_a == null) {
            path_a = arg;
        } else if (path_b == null) {
            path_b = arg;
        } else {
            std.debug.print("error: unexpected argument '{s}'\n\n{s}", .{ arg, usage });
            return 2;
        }
    }
    if (path_a == null or path_b == null) {
        std.debug.print("error: diff needs two log paths\n\n{s}", .{usage});
        return 2;
    }

    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Both logs share one path intern table so location keys are
    // comparable as `(file_id, line, col)` u96 triples without string
    // compares.
    var intern = try PathIntern.init(arena);

    var stdout_buf: [4 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);
    const writer = &stdout.interface;

    try writer.print("reading {s} ... ", .{path_a.?});
    try writer.flush();
    var log_a = try loadLog(arena, &intern, init.io, path_a.?, by_kind);
    try writer.print("{d} events, {d} resolve-or-errored sites\n", .{ log_a.event_count, log_a.locations.count() });
    try writer.print("reading {s} ... ", .{path_b.?});
    try writer.flush();
    var log_b = try loadLog(arena, &intern, init.io, path_b.?, by_kind);
    try writer.print("{d} events, {d} resolve-or-errored sites\n\n", .{ log_b.event_count, log_b.locations.count() });

    try reportDiff(writer, arena, &intern, &log_a, &log_b, .{
        .path_a = path_a.?,
        .path_b = path_b.?,
        .max_divergences = max_divergences,
        .max_outcomes = max_outcomes,
        .asymmetric_only = asymmetric_only,
        .side = side,
        .by_kind = by_kind,
    });
    try writer.flush();
    return 0;
}

// ---- intern table for file paths ----

const PathIntern = struct {
    arena: std.mem.Allocator,
    strings: std.ArrayListUnmanaged([]const u8) = .empty,
    by_string: std.StringHashMapUnmanaged(u32) = .empty,

    fn init(arena: std.mem.Allocator) !PathIntern {
        var self: PathIntern = .{ .arena = arena };
        // Reserve id 0 for "no file" so callers can pass 0 as a sentinel
        // and still pretty-print it as an empty string.
        _ = try self.intern("");
        return self;
    }

    fn intern(self: *PathIntern, s: []const u8) !u32 {
        if (self.by_string.get(s)) |id| return id;
        const owned = try self.arena.dupe(u8, s);
        const id: u32 = @intCast(self.strings.items.len);
        try self.strings.append(self.arena, owned);
        try self.by_string.put(self.arena, owned, id);
        return id;
    }

    fn get(self: PathIntern, id: u32) []const u8 {
        return self.strings.items[id];
    }
};

// ---- location + outcome model ----

/// Joint (creator, target_at) tuple. Either alone is too coarse:
/// `creator` is the outer chunk's source span (often the file-level
/// `1:1` lambda), and many distinct let-bindings share it; `target_at`
/// alone collides at synthetic `?:0:0` spans for compiler-generated
/// thunks. Joint they're unique per thunk-creation site.
const LocationKey = extern struct {
    creator_file: u32,
    creator_line: u32,
    creator_col: u32,
    target_file: u32,
    target_line: u32,
    target_col: u32,
};

const LocationAgg = struct {
    /// First seq observed for this location (create OR resolve/error).
    first_seq: u64 = std.math.maxInt(u64),
    /// outcome string → count. Outcome strings are short fingerprints
    /// like `"resolve:int:42"` or `"errored:TypeError"`. Allocated in
    /// the shared arena.
    outcomes: std.StringHashMapUnmanaged(u32) = .empty,
};

const Log = struct {
    event_count: u64 = 0,
    locations: std.AutoHashMapUnmanaged(LocationKey, LocationAgg) = .empty,
};

// ---- streaming parser ----

const Event = struct {
    seq: u64,
    kind: Kind,
    thunk: u32,
    // create-only:
    creator_file: []const u8,
    creator_line: u32,
    creator_col: u32,
    target_file: []const u8,
    target_line: u32,
    target_col: u32,
    // resolve/errored/reset-only:
    disc: []const u8,
    value: []const u8,
    err: []const u8,
    message: []const u8,

    const Kind = enum { create, resolve, errored, reset, claim, blackhole, other };
};

fn parseEvent(line: []const u8) ?Event {
    var ev: Event = .{
        .seq = 0,
        .kind = .other,
        .thunk = 0,
        .creator_file = "",
        .creator_line = 0,
        .creator_col = 0,
        .target_file = "",
        .target_line = 0,
        .target_col = 0,
        .disc = "",
        .value = "",
        .err = "",
        .message = "",
    };

    // seq, kind, thunk are always the first three fields and contain
    // no spaces in their values; parse them positionally.
    var rest = line;
    rest = consumePrefix(rest, "seq=") orelse return null;
    ev.seq = parseUntilSpace(u64, &rest) orelse return null;
    rest = skipSpace(rest);
    rest = consumePrefix(rest, "kind=") orelse return null;
    const kind_str = takeUntilSpace(&rest);
    ev.kind = if (std.mem.eql(u8, kind_str, "create"))
        .create
    else if (std.mem.eql(u8, kind_str, "resolve"))
        .resolve
    else if (std.mem.eql(u8, kind_str, "errored"))
        .errored
    else if (std.mem.eql(u8, kind_str, "reset"))
        .reset
    else if (std.mem.eql(u8, kind_str, "claim"))
        .claim
    else if (std.mem.eql(u8, kind_str, "blackhole"))
        .blackhole
    else
        .other;
    rest = skipSpace(rest);
    rest = consumePrefix(rest, "thunk=") orelse return null;
    ev.thunk = parseUntilSpace(u32, &rest) orelse return null;

    // Remaining fields can contain spaces (notably `value=` for
    // attrset/list summaries that render as `<thunk N>` with a literal
    // space) — extract each by name with a terminator suited to its
    // shape.
    switch (ev.kind) {
        .create => {
            if (findFieldValue(line, " creator=")) |v| parseLocation(v, &ev.creator_file, &ev.creator_line, &ev.creator_col);
            if (findFieldValue(line, " target_at=")) |v| parseLocation(v, &ev.target_file, &ev.target_line, &ev.target_col);
        },
        .resolve => {
            if (findFieldRaw(line, " disc=")) |v| ev.disc = trimToSpace(v);
            // `value=` extends to end of line.
            if (std.mem.indexOf(u8, line, " value=")) |idx| {
                ev.value = line[idx + " value=".len ..];
            }
        },
        .errored => {
            if (findFieldRaw(line, " err=")) |v| ev.err = takeQuoted(v);
            if (findFieldRaw(line, " message=")) |v| ev.message = takeQuoted(v);
        },
        .reset => {
            if (findFieldRaw(line, " err=")) |v| ev.err = takeQuoted(v);
        },
        .claim, .blackhole, .other => {},
    }
    return ev;
}

/// Find ` key=` in line and return the slice starting right after the
/// `=`. Used as the first step for any field that needs further parsing.
fn findFieldRaw(line: []const u8, key_with_prefix: []const u8) ?[]const u8 {
    const idx = std.mem.indexOf(u8, line, key_with_prefix) orelse return null;
    return line[idx + key_with_prefix.len ..];
}

/// For fields whose value is itself a structured `"file":L:C` form,
/// return the full token (terminating at the next space).
fn findFieldValue(line: []const u8, key_with_prefix: []const u8) ?[]const u8 {
    const s = findFieldRaw(line, key_with_prefix) orelse return null;
    return trimToSpace(s);
}

fn trimToSpace(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and s[i] != ' ' and s[i] != '\t') : (i += 1) {}
    return s[0..i];
}

/// Read a `"..."`-quoted string, returning the unquoted contents. If
/// `s` doesn't start with `"`, falls back to the first space-delimited
/// token.
fn takeQuoted(s: []const u8) []const u8 {
    if (s.len == 0 or s[0] != '"') return trimToSpace(s);
    var i: usize = 1;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 1;
            continue;
        }
        if (s[i] == '"') return s[1..i];
    }
    return s[1..];
}

fn consumePrefix(s: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, s, prefix)) return null;
    return s[prefix.len..];
}

fn skipSpace(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) : (i += 1) {}
    return s[i..];
}

fn takeUntilSpace(s: *[]const u8) []const u8 {
    var i: usize = 0;
    while (i < s.*.len and s.*[i] != ' ' and s.*[i] != '\t') : (i += 1) {}
    const out = s.*[0..i];
    s.* = s.*[i..];
    return out;
}

fn parseUntilSpace(comptime T: type, s: *[]const u8) ?T {
    const tok = takeUntilSpace(s);
    return std.fmt.parseInt(T, tok, 10) catch null;
}

/// Take the value portion of a `key=value` pair starting at `s`. Values
/// may be:
///   - bare tokens terminated by space
///   - quoted strings starting with `"` and ending at the matching `"`
///     (no escape handling — escapes inside the log are `\\` and `\"`
///     which we keep as-is for fingerprinting purposes)
///   - structured `"file":line:col` where the quoted portion is the file
fn takeValue(s: *[]const u8) []const u8 {
    if (s.*.len == 0) return "";
    if (s.*[0] == '"') {
        // Find matching unescaped `"` then optionally consume `:N:N` suffix.
        var i: usize = 1;
        while (i < s.*.len) {
            if (s.*[i] == '\\' and i + 1 < s.*.len) {
                i += 2;
                continue;
            }
            if (s.*[i] == '"') {
                i += 1;
                break;
            }
            i += 1;
        }
        // Continue past `:line:col` (and possibly more) until space.
        while (i < s.*.len and s.*[i] != ' ' and s.*[i] != '\t') : (i += 1) {}
        const out = s.*[0..i];
        s.* = s.*[i..];
        return out;
    }
    return takeUntilSpace(s);
}

fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') return s[1 .. s.len - 1];
    return s;
}

/// Parse `"file":line:col`. Tolerates the unknown-source sentinel
/// `"?":L:C`. Writes back into the provided pointers; sets file to ""
/// and line/col to 0 on parse failure.
fn parseLocation(s: []const u8, file_out: *[]const u8, line_out: *u32, col_out: *u32) void {
    if (s.len < 3 or s[0] != '"') return;
    var end_quote: usize = 1;
    while (end_quote < s.len and s[end_quote] != '"') : (end_quote += 1) {}
    if (end_quote >= s.len) return;
    file_out.* = s[1..end_quote];
    var rest = s[end_quote + 1 ..];
    if (rest.len == 0 or rest[0] != ':') return;
    rest = rest[1..];
    const colon2 = std.mem.indexOfScalar(u8, rest, ':') orelse return;
    line_out.* = std.fmt.parseInt(u32, rest[0..colon2], 10) catch return;
    col_out.* = std.fmt.parseInt(u32, rest[colon2 + 1 ..], 10) catch 0;
}

// ---- log loading ----

fn loadLog(arena: std.mem.Allocator, intern: *PathIntern, io: std.Io, path: []const u8, by_kind: bool) !Log {
    var log: Log = .{};

    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    // Two passes: first builds thunk_id → creator location; second
    // looks up the location for each resolve/errored/reset and folds
    // the outcome into the per-location aggregate. We do both in one
    // pass over the file by keeping a thunk_id→loc HashMap. That eats
    // RAM (~16B/entry × millions of thunks) but the file is too big to
    // hold in memory and reading it twice doubles disk IO.
    var thunk_to_loc: std.AutoHashMapUnmanaged(u32, LocationKey) = .empty;

    var read_buf: [256 * 1024]u8 = undefined;
    var reader = file.readerStreaming(io, &read_buf);

    while (true) {
        const maybe_line = reader.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => continue, // shouldn't happen; trace lines are bounded
            else => return err,
        };
        const line = maybe_line orelse break;
        const ev = parseEvent(line) orelse continue;
        log.event_count += 1;

        switch (ev.kind) {
            .create => {
                if (ev.creator_file.len == 0 and ev.target_file.len == 0) continue;
                const cfid: u32 = if (ev.creator_file.len == 0) 0 else try intern.intern(ev.creator_file);
                const tfid: u32 = if (ev.target_file.len == 0) 0 else try intern.intern(ev.target_file);
                const key: LocationKey = .{
                    .creator_file = cfid,
                    .creator_line = ev.creator_line,
                    .creator_col = ev.creator_col,
                    .target_file = tfid,
                    .target_line = ev.target_line,
                    .target_col = ev.target_col,
                };
                try thunk_to_loc.put(arena, ev.thunk, key);
                try recordLocationFirstSeq(arena, &log.locations, key, ev.seq);
            },
            .resolve, .errored, .reset => {
                const key = thunk_to_loc.get(ev.thunk) orelse continue;
                const outcome = if (by_kind)
                    try fingerprintKindOnly(arena, ev)
                else
                    try fingerprintOutcome(arena, ev);
                try recordOutcome(arena, &log.locations, key, ev.seq, outcome);
            },
            .claim, .blackhole, .other => {},
        }
    }
    return log;
}

fn recordLocationFirstSeq(
    arena: std.mem.Allocator,
    locations: *std.AutoHashMapUnmanaged(LocationKey, LocationAgg),
    key: LocationKey,
    seq: u64,
) !void {
    const gop = try locations.getOrPut(arena, key);
    if (!gop.found_existing) gop.value_ptr.* = .{};
    if (seq < gop.value_ptr.first_seq) gop.value_ptr.first_seq = seq;
}

fn recordOutcome(
    arena: std.mem.Allocator,
    locations: *std.AutoHashMapUnmanaged(LocationKey, LocationAgg),
    key: LocationKey,
    seq: u64,
    outcome: []const u8,
) !void {
    const gop = try locations.getOrPut(arena, key);
    if (!gop.found_existing) gop.value_ptr.* = .{};
    if (seq < gop.value_ptr.first_seq) gop.value_ptr.first_seq = seq;
    const ogop = try gop.value_ptr.outcomes.getOrPut(arena, outcome);
    if (!ogop.found_existing) ogop.value_ptr.* = 0;
    ogop.value_ptr.* += 1;
}

const max_value_summary = 120;
const max_message_summary = 120;

fn fingerprintOutcome(arena: std.mem.Allocator, ev: Event) ![]const u8 {
    return switch (ev.kind) {
        .resolve => blk: {
            const v = if (ev.value.len > max_value_summary) ev.value[0..max_value_summary] else ev.value;
            const normalized = try normalizeValueSummary(arena, v);
            const ellipsis: []const u8 = if (ev.value.len > max_value_summary) "…" else "";
            break :blk try std.fmt.allocPrint(arena, "resolve:{s}:{s}{s}", .{ ev.disc, normalized, ellipsis });
        },
        .errored => blk: {
            if (ev.message.len == 0) break :blk try std.fmt.allocPrint(arena, "errored:{s}", .{ev.err});
            const m = if (ev.message.len > max_message_summary) ev.message[0..max_message_summary] else ev.message;
            const ellipsis: []const u8 = if (ev.message.len > max_message_summary) "…" else "";
            break :blk try std.fmt.allocPrint(arena, "errored:{s}:{s}{s}", .{ ev.err, m, ellipsis });
        },
        .reset => try std.fmt.allocPrint(arena, "reset:{s}", .{ev.err}),
        else => unreachable,
    };
}

/// Coarsest possible fingerprint: just the event kind and discriminant
/// or error name. Used by `--by-kind` for the "did this thunk resolve
/// vs error" comparison without noise from value contents that may
/// legitimately differ across runs due to iteration order.
fn fingerprintKindOnly(arena: std.mem.Allocator, ev: Event) ![]const u8 {
    return switch (ev.kind) {
        .resolve => try std.fmt.allocPrint(arena, "resolve:{s}", .{ev.disc}),
        .errored => try std.fmt.allocPrint(arena, "errored:{s}", .{ev.err}),
        .reset => try std.fmt.allocPrint(arena, "reset:{s}", .{ev.err}),
        else => unreachable,
    };
}

/// Replace `<thunk N>` with `<thunk *>`. Thunk ids aren't stable across
/// runs — different eval orderings allocate them differently — so the
/// raw value summary contains noise that defeats outcome-multiset
/// comparison. Strip the id and keep just the shape.
fn normalizeValueSummary(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, s, "<thunk ") == null) return s;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.ensureTotalCapacity(arena, s.len);
    var i: usize = 0;
    while (i < s.len) {
        if (i + 7 <= s.len and std.mem.eql(u8, s[i .. i + 7], "<thunk ")) {
            try out.appendSlice(arena, "<thunk *");
            i += 7;
            while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {}
            continue;
        }
        try out.append(arena, s[i]);
        i += 1;
    }
    return out.items;
}

// ---- diff reporting ----

const Divergence = struct {
    key: LocationKey,
    /// `min(first_seq_a, first_seq_b)` so we can sort divergences in
    /// rough causal order.
    sort_seq: u64,
};

fn reportDiff(
    writer: *std.Io.Writer,
    arena: std.mem.Allocator,
    intern: *PathIntern,
    log_a: *Log,
    log_b: *Log,
    opts: DiffOptions,
) !void {
    var divergences: std.ArrayListUnmanaged(Divergence) = .empty;
    defer divergences.deinit(arena);

    // Locations in either log are candidates.
    var seen_keys: std.AutoHashMapUnmanaged(LocationKey, void) = .empty;
    defer seen_keys.deinit(arena);

    var it_a = log_a.locations.iterator();
    while (it_a.next()) |entry| try seen_keys.put(arena, entry.key_ptr.*, {});
    var it_b = log_b.locations.iterator();
    while (it_b.next()) |entry| try seen_keys.put(arena, entry.key_ptr.*, {});

    var seen_it = seen_keys.iterator();
    while (seen_it.next()) |entry| {
        const key = entry.key_ptr.*;
        const a_agg = log_a.locations.getPtr(key);
        const b_agg = log_b.locations.getPtr(key);
        if (!outcomesDiffer(a_agg, b_agg)) continue;
        if (opts.asymmetric_only) {
            const ok = switch (opts.side) {
                .both => outcomesAsymmetric(a_agg, b_agg),
                .novel_in_a => hasNovelOutcome(a_agg, b_agg),
                .novel_in_b => hasNovelOutcome(b_agg, a_agg),
            };
            if (!ok) continue;
        }
        const sort_seq = blk: {
            const aseq = if (a_agg) |a| a.first_seq else std.math.maxInt(u64);
            const bseq = if (b_agg) |b| b.first_seq else std.math.maxInt(u64);
            break :blk @min(aseq, bseq);
        };
        try divergences.append(arena, .{ .key = key, .sort_seq = sort_seq });
    }

    std.mem.sort(Divergence, divergences.items, {}, struct {
        fn lt(_: void, a: Divergence, b: Divergence) bool {
            return a.sort_seq < b.sort_seq;
        }
    }.lt);

    try writer.print(
        "found {d} divergent location(s); showing first {d} by earliest seq\n\n",
        .{ divergences.items.len, @min(divergences.items.len, opts.max_divergences) },
    );

    var shown: usize = 0;
    for (divergences.items) |div| {
        if (shown >= opts.max_divergences) break;
        shown += 1;
        try writer.print("#{d} target {s}:{d}:{d}  (creator {s}:{d}:{d})\n", .{
            shown,
            intern.get(div.key.target_file),
            div.key.target_line,
            div.key.target_col,
            intern.get(div.key.creator_file),
            div.key.creator_line,
            div.key.creator_col,
        });
        try writer.print("    first seq: a={d} b={d}\n", .{
            if (log_a.locations.getPtr(div.key)) |a| a.first_seq else std.math.maxInt(u64),
            if (log_b.locations.getPtr(div.key)) |b| b.first_seq else std.math.maxInt(u64),
        });
        try writer.writeAll("    A outcomes:\n");
        try printOutcomes(writer, log_a.locations.getPtr(div.key), opts.max_outcomes);
        try writer.writeAll("    B outcomes:\n");
        try printOutcomes(writer, log_b.locations.getPtr(div.key), opts.max_outcomes);
        try writer.writeByte('\n');
    }
}

fn outcomesDiffer(a: ?*LocationAgg, b: ?*LocationAgg) bool {
    const a_outcomes = if (a) |aa| aa.outcomes.count() else 0;
    const b_outcomes = if (b) |bb| bb.outcomes.count() else 0;
    if (a_outcomes != b_outcomes) return true;
    if (a_outcomes == 0) return false;

    var it = a.?.outcomes.iterator();
    while (it.next()) |entry| {
        const a_count = entry.value_ptr.*;
        const b_count = b.?.outcomes.get(entry.key_ptr.*) orelse return true;
        if (a_count != b_count) return true;
    }
    return false;
}

/// True iff one side has at least one outcome variant the other side
/// never produced. This is the smoking-gun pattern for speculation
/// races: a thunk forced (and resolved or errored) in one run that was
/// never reached in the other.
fn outcomesAsymmetric(a: ?*LocationAgg, b: ?*LocationAgg) bool {
    if (hasNovelOutcome(a, b)) return true;
    if (hasNovelOutcome(b, a)) return true;
    return false;
}

fn hasNovelOutcome(side: ?*LocationAgg, other: ?*LocationAgg) bool {
    const s = side orelse return false;
    if (s.outcomes.count() == 0) return false;
    var it = s.outcomes.iterator();
    while (it.next()) |entry| {
        const present_in_other = if (other) |o| o.outcomes.contains(entry.key_ptr.*) else false;
        if (!present_in_other) return true;
    }
    return false;
}

fn printOutcomes(writer: *std.Io.Writer, agg: ?*LocationAgg, max: usize) !void {
    if (agg == null or agg.?.outcomes.count() == 0) {
        try writer.writeAll("      (none)\n");
        return;
    }
    var shown: usize = 0;
    var it = agg.?.outcomes.iterator();
    while (it.next()) |entry| {
        if (shown >= max) break;
        shown += 1;
        try writer.print("      ×{d}  {s}\n", .{ entry.value_ptr.*, entry.key_ptr.* });
    }
    if (agg.?.outcomes.count() > max) {
        try writer.print("      ... ({d} more outcome variants)\n", .{agg.?.outcomes.count() - max});
    }
}

// ---- self-tests ----

test "parseLocation: standard form" {
    var file: []const u8 = "";
    var line: u32 = 0;
    var col: u32 = 0;
    parseLocation("\"/a/b.nix\":42:7", &file, &line, &col);
    try std.testing.expectEqualStrings("/a/b.nix", file);
    try std.testing.expectEqual(@as(u32, 42), line);
    try std.testing.expectEqual(@as(u32, 7), col);
}

test "parseLocation: unknown-source sentinel" {
    var file: []const u8 = "";
    var line: u32 = 0;
    var col: u32 = 0;
    parseLocation("\"?\":0:0", &file, &line, &col);
    try std.testing.expectEqualStrings("?", file);
    try std.testing.expectEqual(@as(u32, 0), line);
}

test "parseEvent: create" {
    const line = "seq=42 kind=create thunk=99 worker=1 fiber=2 target=bytecode creator=\"/x.nix\":3:4 target_at=\"/x.nix\":5:6";
    const ev = parseEvent(line).?;
    try std.testing.expectEqual(@as(u64, 42), ev.seq);
    try std.testing.expectEqual(Event.Kind.create, ev.kind);
    try std.testing.expectEqual(@as(u32, 99), ev.thunk);
    try std.testing.expectEqualStrings("/x.nix", ev.creator_file);
    try std.testing.expectEqual(@as(u32, 3), ev.creator_line);
    try std.testing.expectEqual(@as(u32, 4), ev.creator_col);
}

test "parseEvent: resolve" {
    const line = "seq=43 kind=resolve thunk=99 worker=1 fiber=2 disc=int value=42";
    const ev = parseEvent(line).?;
    try std.testing.expectEqual(Event.Kind.resolve, ev.kind);
    try std.testing.expectEqual(@as(u32, 99), ev.thunk);
    try std.testing.expectEqualStrings("int", ev.disc);
    try std.testing.expectEqualStrings("42", ev.value);
}

test "normalizeValueSummary: thunk ids are stripped" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const out = try normalizeValueSummary(arena, "[<thunk 12345>,<thunk 67890>,42]");
    try std.testing.expectEqualStrings("[<thunk *>,<thunk *>,42]", out);
}

test "parseEvent: errored with message" {
    const line = "seq=44 kind=errored thunk=99 worker=1 fiber=2 err=\"TypeError\" message=\"expected string or path, got null\"";
    const ev = parseEvent(line).?;
    try std.testing.expectEqual(Event.Kind.errored, ev.kind);
    try std.testing.expectEqualStrings("TypeError", ev.err);
    try std.testing.expectEqualStrings("expected string or path, got null", ev.message);
}
