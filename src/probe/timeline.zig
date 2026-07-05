//! `-Dtimeline`: a wall-clock event timeline of the evaluator's serial
//! path, emitted as a Perfetto / Chrome-trace JSON (one track per worker).
//!
//! Motivation: at `--workers=N` the wall-time floor is the *serial
//! critical path* — what worker 0 does between process start and the
//! result being ready (see the `critical_path_floor` memo). Aggregate
//! profilers (`-Dprof-main`) tell you how much total time each phase
//! costs but not *when* it happens or how it interleaves with imports
//! and helper work. This module answers "what is each worker doing,
//! when" so you can see the serial path directly: where it parses files,
//! where it stalls idle (park), and where work branches onto helpers.
//!
//! Design — nesting is correct by construction. Fibers multiplex on a
//! worker thread (a fiber yields on a `.busy` thunk and the worker picks
//! up another), so naive per-thread begin/end spans would not nest and
//! Perfetto would reject them. We only open spans at boundaries that
//! cannot straddle a yield:
//!   * a fiber-run *quantum* — one `inner.resume_()`, which by
//!     definition returns when the fiber yields or finishes;
//!   * a *park* — the worker is blocked, no fiber running;
//!   * *parse* / *compile* — synchronous (no thunk force → no yield),
//!     so they nest cleanly inside the quantum that ran the import.
//! Anything that *does* span a yield (render, import evaluation) is
//! recorded as an instantaneous marker instead of a span.
//!
//! A per-worker stack pairs begin/end and computes each span's duration;
//! `end` asserts the popped label matches, so if a span ever straddles a
//! yield the imbalance trips the assertion at its source.
//!
//! Runtime-gated (`FIX_TIMELINE` env or `--timeline[=path]`): always compiled
//! in, `init()` flips `active` on. When off, each entry point is one
//! predictable branch on `active`; the hot instrumentation sits at
//! fiber-quantum / park granularity (not per-op), so it is effectively free.

const std = @import("std");
const builtin = @import("builtin");
const worker_id_mod = @import("runtime").worker_id;

/// Always compiled in — timeline is now RUNTIME-gated (`FIX_TIMELINE` env or
/// `--timeline[=path]`): `init()` flips `active` on. When off, every entry
/// point is one predictable-not-taken branch on `active`; the hot
/// instrumentation is at fiber-quantum / park granularity (not per-op), so it
/// is effectively free. Kept as a `pub const true` so existing
/// `if (comptime timeline.enabled)` sites fold to the taken branch — the real
/// switch is the runtime `active` flag, read via `on()`.
pub const enabled = true;

/// Runtime switch: true between `init()` and `dump()`. THE gate — a plain
/// global load, predictable when off. Gate expensive arg prep (formatting,
/// /proc reads) behind this so it's skipped when tracing is off.
pub inline fn on() bool {
    return active;
}

/// Static span/marker categories. Keeping these as an enum (rather than
/// a copied string) means the hot per-quantum path stores no bytes in
/// the name arena — only dynamic subjects (file paths) are copied.
pub const Label = enum(u8) {
    run,
    park,
    parse,
    compile,
    render,
    evaluate,
    import,
    /// GC work (subject = phase: "mark"/"sweep"/"minor"/"init-stw"/
    /// "conc-mark"/"final-stw"). Synchronous at a safepoint → nests cleanly
    /// inside the running quantum. `arg` carries a phase-specific count.
    gc,
    /// A worker stopped at a GC safepoint waiting for the collector (the STW
    /// pause as seen by a peer — distinct from a plain no-work `park`).
    gc_wait,
    /// A builtin on the critical path (subject = builtin name). Instant marker
    /// — many builtins force args and thus straddle a yield.
    builtin,

    fn text(self: Label) []const u8 {
        return switch (self) {
            .run => "run",
            .park => "park",
            .parse => "parse",
            .compile => "compile",
            .render => "render",
            .evaluate => "evaluate",
            .import => "import",
            .gc => "gc",
            .gc_wait => "gc-wait",
            .builtin => "builtin",
        };
    }
};

const MAX_DEPTH = 64;

const StackEntry = struct {
    ts_ns: u64,
    label: Label,
    subj_off: u32,
    subj_len: u32,
    arg: u64,
    args_off: u32,
    args_len: u32,
};

const Kind = enum(u8) { span, instant, counter };

const Event = struct {
    ts_ns: u64,
    dur_ns: u64,
    tid: u16,
    kind: Kind,
    label: Label,
    subj_off: u32,
    subj_len: u32,
    arg: u64,
    /// A pre-formatted JSON object *body* (no braces), stored in the name
    /// arena — e.g. `"chunk":123,"depth":7`. Rendered as the event's `args`.
    args_off: u32 = 0,
    args_len: u32 = 0,
    /// For counters: the counter track name, stored in the name arena.
    ctr_off: u32 = 0,
    ctr_len: u32 = 0,
};

const WorkerStack = struct {
    items: [MAX_DEPTH]StackEntry = undefined,
    len: u8 = 0,
};

var gpa: std.mem.Allocator = undefined;
var start_ns: u64 = 0;

var events: []Event = &.{};
var events_cap: usize = 0;
var events_len: std.atomic.Value(usize) = .init(0);
var dropped_events: std.atomic.Value(u64) = .init(0);

var names: []u8 = &.{};
var names_cap: usize = 0;
var names_len: std.atomic.Value(usize) = .init(0);
var dropped_names: std.atomic.Value(u64) = .init(0);

/// One stack per worker thread. Indexed by `worker_id_mod.current`; each
/// slot is only ever touched by its own worker thread, so no locking.
var stacks: []WorkerStack = &.{};

var active: bool = false;

fn nowNs() u64 {
    if (builtin.os.tag != .linux) return 0;
    var ts: std.os.linux.timespec = undefined;
    if (std.os.linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    const sec: u64 = if (ts.sec > 0) @intCast(ts.sec) else 0;
    const nsec: u64 = if (ts.nsec > 0) @intCast(ts.nsec) else 0;
    return sec * std.time.ns_per_s + nsec;
}

/// Allocate the event/name buffers and per-worker stacks. Call once,
/// before evaluation, on the main thread. `event_cap` bounds how many
/// spans+markers are retained; overflow is counted and reported (never
/// silently truncated).
pub fn init(allocator: std.mem.Allocator, n_workers: usize, event_cap: usize) void {
    if (!enabled) return;
    gpa = allocator;
    events = allocator.alloc(Event, event_cap) catch &.{};
    events_cap = events.len;
    names = allocator.alloc(u8, 8 << 20) catch &.{};
    names_cap = names.len;
    // +1 guard slot so a stray worker id never indexes out of bounds.
    stacks = allocator.alloc(WorkerStack, n_workers + 1) catch &.{};
    for (stacks) |*s| s.* = .{};
    events_len.store(0, .monotonic);
    names_len.store(0, .monotonic);
    dropped_events.store(0, .monotonic);
    dropped_names.store(0, .monotonic);
    start_ns = nowNs();
    active = true;
}

fn storeName(s: []const u8) struct { off: u32, len: u32 } {
    if (s.len == 0) return .{ .off = 0, .len = 0 };
    const off = names_len.fetchAdd(s.len, .monotonic);
    if (off + s.len > names_cap) {
        _ = dropped_names.fetchAdd(1, .monotonic);
        return .{ .off = 0, .len = 0 };
    }
    @memcpy(names[off..][0..s.len], s);
    return .{ .off = @intCast(off), .len = @intCast(s.len) };
}

fn appendEvent(e: Event) void {
    const idx = events_len.fetchAdd(1, .monotonic);
    if (idx >= events_cap) {
        _ = dropped_events.fetchAdd(1, .monotonic);
        return;
    }
    events[idx] = e;
}

/// Open a span on the current worker's stack. `subject` (e.g. a file
/// path) is copied; pass "" when there's nothing dynamic to record.
/// `arg` is a free numeric annotation (used for the fiber id on quanta).
pub inline fn begin(label: Label, subject: []const u8, arg: u64) void {
    if (!enabled) return;
    beginImpl(label, subject, arg, "");
}

/// Like `begin`, plus a pre-formatted JSON object body (no braces) shown in
/// Perfetto's detail panel — e.g. `"chunk":123,"builtin":"map"`.
pub inline fn beginArgs(label: Label, subject: []const u8, arg: u64, args: []const u8) void {
    if (!enabled) return;
    beginImpl(label, subject, arg, args);
}

fn beginImpl(label: Label, subject: []const u8, arg: u64, args: []const u8) void {
    if (!active) return;
    const wid = worker_id_mod.current;
    if (wid >= stacks.len) return;
    const st = &stacks[wid];
    if (st.len >= MAX_DEPTH) return;
    const nm = storeName(subject);
    const ar = storeName(args);
    st.items[st.len] = .{
        .ts_ns = nowNs(),
        .label = label,
        .subj_off = nm.off,
        .subj_len = nm.len,
        .arg = arg,
        .args_off = ar.off,
        .args_len = ar.len,
    };
    st.len += 1;
}

/// Close the most recent span on the current worker's stack. The
/// `label` must match the open span — the assert is the nesting
/// invariant: a span that straddled a fiber yield would trip it here.
pub inline fn end(label: Label) void {
    if (!enabled) return;
    endImpl(label);
}

fn endImpl(label: Label) void {
    if (!active) return;
    const now = nowNs();
    const wid = worker_id_mod.current;
    if (wid >= stacks.len) return;
    const st = &stacks[wid];
    if (st.len == 0) return;
    st.len -= 1;
    const e = st.items[st.len];
    std.debug.assert(e.label == label);
    appendEvent(.{
        .ts_ns = e.ts_ns,
        .dur_ns = if (now > e.ts_ns) now - e.ts_ns else 0,
        .tid = @intCast(wid),
        .kind = .span,
        .label = e.label,
        .subj_off = e.subj_off,
        .subj_len = e.subj_len,
        .arg = e.arg,
        .args_off = e.args_off,
        .args_len = e.args_len,
    });
}

/// Record an instantaneous marker on the current worker's track. Use
/// for moments that bracket yielding work (render start, etc.).
pub inline fn instant(label: Label, subject: []const u8) void {
    if (!enabled) return;
    instantImpl(label, subject, "");
}

/// Like `instant`, plus a JSON args body (no braces).
pub inline fn instantArgs(label: Label, subject: []const u8, args: []const u8) void {
    if (!enabled) return;
    instantImpl(label, subject, args);
}

fn instantImpl(label: Label, subject: []const u8, args: []const u8) void {
    if (!active) return;
    const wid = worker_id_mod.current;
    const nm = storeName(subject);
    const ar = storeName(args);
    appendEvent(.{
        .ts_ns = nowNs(),
        .dur_ns = 0,
        .tid = wid,
        .kind = .instant,
        .label = label,
        .subj_off = nm.off,
        .subj_len = nm.len,
        .arg = 0,
        .args_off = ar.off,
        .args_len = ar.len,
    });
}

/// Emit a counter sample (`ph:"C"`) — a time-series track named `name` whose
/// series/values are the `args` JSON body, e.g. `"objects":1000,"attrs":500`.
/// Perfetto draws one stacked graph per counter name. Cheap: no syscalls here,
/// the caller supplies the already-read values. Emitted on any worker.
pub inline fn counter(name: []const u8, args: []const u8) void {
    if (!enabled) return;
    if (!active) return;
    const nm = storeName(name);
    const ar = storeName(args);
    appendEvent(.{
        .ts_ns = nowNs(),
        .dur_ns = 0,
        .tid = worker_id_mod.current,
        .kind = .counter,
        .label = .run,
        .subj_off = 0,
        .subj_len = 0,
        .arg = 0,
        .args_off = ar.off,
        .args_len = ar.len,
        .ctr_off = nm.off,
        .ctr_len = nm.len,
    });
}

/// Throttle helper for periodic sampling: returns true at most once per
/// `min_gap_ns` (per calling worker is fine — counters merge by name/ts).
var last_sample_ns: std.atomic.Value(u64) = .init(0);
pub fn shouldSample(min_gap_ns: u64) bool {
    if (!enabled or !active) return false;
    const now = nowNs();
    const last = last_sample_ns.load(.monotonic);
    if (now < last + min_gap_ns) return false;
    return last_sample_ns.cmpxchgStrong(last, now, .monotonic, .monotonic) == null;
}

fn subjectOf(e: Event) []const u8 {
    if (e.subj_len == 0) return "";
    const off: usize = e.subj_off;
    return names[off..][0..e.subj_len];
}
fn argsBodyOf(e: Event) []const u8 {
    if (e.args_len == 0) return "";
    const off: usize = e.args_off;
    return names[off..][0..e.args_len];
}
fn counterNameOf(e: Event) []const u8 {
    if (e.ctr_len == 0) return "counter";
    const off: usize = e.ctr_off;
    return names[off..][0..e.ctr_len];
}

fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => if (c < 0x20) {
                try w.print("\\u{x:0>4}", .{c});
            } else {
                try w.writeByte(c);
            },
        }
    }
    try w.writeByte('"');
}

fn usFromNs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1000.0;
}

/// Write the recorded events as a Perfetto / Chrome-trace JSON array to
/// `path`, then print a one-line summary to stderr. Must run before the
/// evaluator (and the file paths the events borrow) is torn down.
pub fn dump(io: std.Io, path: []const u8, n_workers: usize) void {
    if (!enabled) return;
    if (!active) return;
    active = false;
    // Names are borrowed by the events until `dumpImpl` writes them, so
    // free only after it returns (success or error).
    defer {
        gpa.free(events);
        gpa.free(names);
        gpa.free(stacks);
        events = &.{};
        names = &.{};
        stacks = &.{};
    }
    dumpImpl(io, path, n_workers) catch |err| {
        std.debug.print("timeline: failed to write {s}: {s}\n", .{ path, @errorName(err) });
    };
}

fn dumpImpl(io: std.Io, path: []const u8, n_workers: usize) !void {
    const count = @min(events_len.load(.monotonic), events_cap);

    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var fw = file.writerStreaming(io, &buf);
    const w = &fw.interface;

    try w.writeAll("[\n");

    // Thread-name metadata so each track is labelled in the viewer.
    var t: usize = 0;
    while (t <= n_workers) : (t += 1) {
        const main = t == 0;
        try w.print(
            "{{\"ph\":\"M\",\"pid\":1,\"tid\":{d},\"name\":\"thread_name\",\"args\":{{\"name\":\"",
            .{t},
        );
        if (main) {
            try w.writeAll("worker 0 (main / serial path)");
        } else {
            try w.print("worker {d}", .{t});
        }
        try w.writeAll("\"}},\n");
    }

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const e = events[i];
        const rel_ns = if (e.ts_ns > start_ns) e.ts_ns - start_ns else 0;
        const subj = subjectOf(e);
        const body = argsBodyOf(e);
        // Counter: a time-series track named `ctr`, values = the args body.
        if (e.kind == .counter) {
            try w.print(
                "{{\"ph\":\"C\",\"pid\":1,\"tid\":{d},\"ts\":{d:.3},\"name\":",
                .{ e.tid, usFromNs(rel_ns) },
            );
            try writeJsonString(w, counterNameOf(e));
            try w.print(",\"args\":{{{s}}}", .{body});
            try w.writeAll(if (i + 1 < count) "},\n" else "}\n");
            continue;
        }
        if (e.kind == .instant) {
            try w.print(
                "{{\"ph\":\"i\",\"pid\":1,\"tid\":{d},\"ts\":{d:.3},\"s\":\"t\",\"name\":",
                .{ e.tid, usFromNs(rel_ns) },
            );
        } else {
            try w.print(
                "{{\"ph\":\"X\",\"pid\":1,\"tid\":{d},\"ts\":{d:.3},\"dur\":{d:.3},\"name\":",
                .{ e.tid, usFromNs(rel_ns), usFromNs(e.dur_ns) },
            );
        }
        // name = label, optionally suffixed with ": <subject>".
        if (subj.len == 0) {
            try writeJsonString(w, e.label.text());
        } else {
            var namebuf: [512]u8 = undefined;
            const full = std.fmt.bufPrint(&namebuf, "{s}: {s}", .{ e.label.text(), subj }) catch e.label.text();
            try writeJsonString(w, full);
        }
        // args = {fiber, <body>} — fiber id (quanta) plus any rich fields.
        if (e.arg != 0 or body.len != 0) {
            try w.writeAll(",\"args\":{");
            if (e.arg != 0) {
                try w.print("\"fiber\":{d}", .{e.arg});
                if (body.len != 0) try w.writeByte(',');
            }
            if (body.len != 0) try w.writeAll(body);
            try w.writeByte('}');
        }
        try w.writeAll(if (i + 1 < count) "},\n" else "}\n");
    }

    try w.writeAll("]\n");
    try w.flush();

    const dropped_e = dropped_events.load(.monotonic);
    const dropped_n = dropped_names.load(.monotonic);
    std.debug.print(
        "timeline: wrote {d} events to {s} (open in https://ui.perfetto.dev)\n",
        .{ count, path },
    );
    if (dropped_e != 0 or dropped_n != 0) {
        std.debug.print(
            "timeline: DROPPED {d} events (cap {d}) and {d} names (buffer full) — raise the cap for full coverage\n",
            .{ dropped_e, events_cap, dropped_n },
        );
    }
}
