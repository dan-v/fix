//! `fix inspect` — print evaluator stats (heap, intern, chunks).
//!
//! Runs the evaluator end-to-end on the input expression (so heap stats
//! reflect a realistic workload) and dumps aggregated stats to stdout.
//! Use `--no-eval` to inspect what compilation alone produces.

const std = @import("std");
const engine = @import("expr");
const presentation = @import("../presentation.zig");
const cli_args = @import("../args.zig");
const fileish = @import("../fileish.zig");
const setup = @import("../setup.zig");
const bytecode = engine.bytecode;
const builtin = @import("builtin");

const Evaluator = engine.Evaluator;
const SchedulerStats = engine.workers.Scheduler.Stats;

const usage =
    \\usage: fix inspect [options] (-E <expression> | --file <path>)
    \\
    \\options:
    \\  -E, --expr EXPR    expression to evaluate
    \\  -f, --file PATH    read expression from PATH
    \\  --strict           recursively force values before reporting
    \\  --no-eval          only compile, skip evaluation (faster but less heap info)
    \\  --top N            show top-N interned strings by length (default 0)
    \\  -h, --help         show this help
    \\
;

const SourceArg = cli_args.SourceArg;

const Options = struct {
    source: ?SourceArg = null,
    strict: bool = false,
    no_eval: bool = false,
    top: u32 = 0,
    workers: ?u8 = null,
};

pub fn run(process: @import("../process_context.zig").ProcessContext, init: std.process.Init, args_iter: *std.process.Args.Iterator) !u8 {
    const allocator = process.allocator;
    const options = parseOptions(args_iter) catch |err| switch (err) {
        error.Help => {
            presentation.printHelp(init.io, usage);
            return 0;
        },
        else => {
            std.debug.print("error: {s}\n\n{s}", .{ optionErrorMessage(err), usage });
            return 2;
        },
    };
    const source_arg = options.source orelse {
        std.debug.print("{s}", .{usage});
        return 2;
    };

    const worker_count: u8 = if (builtin.single_threaded)
        1
    else
        options.workers orelse @intCast(@min(@as(u32, 8), @as(u32, @intCast(try std.Thread.getCpuCount()))));

    // No `--hugetlb` in this command's parser; use automatic selection.
    setup.applyMemoryBacking(null);
    var ev = try Evaluator.init(allocator, worker_count);
    defer ev.deinit();
    var shared_options: cli_args.Options = .{};
    defer shared_options.deinit(allocator);
    _ = try setup.configure(&ev, init, shared_options);

    const loaded: fileish.Source = switch (source_arg) {
        .expr => |text| .{ .text = text },
        .file => |path| try fileish.load(&ev, init.io, path),
        .flake => {
            std.debug.print("error: --flake is not supported by this subcommand\n", .{});
            return 1;
        },
    };
    defer loaded.deinit(allocator);
    const source = loaded.text;

    if (options.no_eval) {
        _ = ev.compileSourceAt(source, loaded.base_path, loaded.abs_path) catch |err| {
            std.debug.print("error: compilation failed: {s}\n", .{@errorName(err)});
            return 1;
        };
    } else {
        const value = ev.evaluatePathAt(source, loaded.base_path, loaded.abs_path) catch |err| {
            std.debug.print("error: evaluation failed: {s}\n", .{@errorName(err)});
            return 1;
        };
        if (options.strict) ev.forceDeep(value) catch |err| {
            std.debug.print("error: strict force failed: {s}\n", .{@errorName(err)});
            return 1;
        };
    }

    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const writer = &stdout.interface;
    try writeReport(writer, &ev, options.top);
    try writer.flush();
    return 0;
}

fn writeReport(writer: *std.Io.Writer, ev: *Evaluator, top_n: u32) !void {
    const heap_stats = ev.heapStats();
    const intern_stats = ev.internStats();
    const reg_stats = ev.chunkStats();
    const sched_stats = ev.schedulerStats();
    const workers = ev.workerCount();

    try writer.writeAll("heap\n");
    try writer.print("  objects:          {d}\n", .{heap_stats.objects});
    for (heap_stats.variant_counts, 0..) |count, i| {
        if (count == 0) continue;
        try writer.print("    {s:<16}{d}\n", .{ @TypeOf(heap_stats).variantName(i), count });
    }
    try writer.print("  values:           {d}\n", .{heap_stats.values});
    try writer.print("  attrs:            {d}\n", .{heap_stats.attrs});
    try writer.print("  attr_positions:   {d}\n", .{heap_stats.attr_positions});
    if (heap_stats.thunk_states[0] + heap_stats.thunk_states[1] + heap_stats.thunk_states[2] + heap_stats.thunk_states[3] + heap_stats.thunk_states[4] > 0) {
        try writer.writeAll("  thunk states:\n");
        for (heap_stats.thunk_states, 0..) |count, i| {
            if (count == 0) continue;
            try writer.print("    {s:<16}{d}\n", .{ @TypeOf(heap_stats).thunkStateName(i), count });
        }
    }
    const int_total = heap_stats.intTotal();
    if (int_total > 0) {
        const overflow = heap_stats.intOverflowsI48();
        try writer.print("  inline ints:      {d}\n", .{int_total});
        try writer.writeAll("  int magnitude (NaN-box would need to box bucket 4):\n");
        for (heap_stats.int_buckets, 0..) |count, i| {
            try writer.print("    {s:<8}{d:>10}  ({d:.2}%)\n", .{
                @TypeOf(heap_stats).intBucketLabel(i),
                count,
                percent(@intCast(count), @intCast(int_total)),
            });
        }
        try writer.print("    overflows i48: {d}  ({d:.4}% of all ints)\n", .{
            overflow,
            percent(@intCast(overflow), @intCast(int_total)),
        });
    }

    try writer.writeAll("\nintern\n");
    try writer.print("  entries:          {d}\n", .{intern_stats.entries});
    try writer.print("  data bytes:       {d}\n", .{intern_stats.data_bytes});
    try writer.print("  shard imbalance:  {d:.2}x  (1.00 = perfectly balanced)\n", .{intern_stats.shardImbalance()});
    try writer.writeAll("  shards:\n");
    const max_shard = max32(&intern_stats.shard_counts);
    for (intern_stats.shard_counts, 0..) |c, i| {
        try writer.print("    [{d:0>2}] {d:>5}  ", .{ i, c });
        try writeBar(writer, c, max_shard, 24);
        try writer.writeByte('\n');
    }

    try writer.writeAll("\nchunks\n");
    try writer.print("  count:            {d}\n", .{reg_stats.chunks});
    try writer.print("  code bytes:       {d}\n", .{reg_stats.code_bytes});
    try writer.print("  constants:        {d}\n", .{reg_stats.const_count});
    try writer.print("  source spans:     {d}\n", .{reg_stats.source_map_entries});
    try writer.print("  max code bytes:   {d}\n", .{reg_stats.max_code_bytes});
    try writer.writeAll("  size distribution:\n");
    const max_bucket = max32(&reg_stats.size_buckets);
    for (reg_stats.size_buckets, 0..) |c, i| {
        try writer.print("    {s:<10}{d:>6}  ", .{ @TypeOf(reg_stats).bucketLabel(i), c });
        try writeBar(writer, c, max_bucket, 24);
        try writer.writeByte('\n');
    }
    try writer.print("  with strictness:  {d}  ({d:.1}% of all chunks)\n", .{
        reg_stats.with_strictness,
        percent(reg_stats.with_strictness, reg_stats.chunks),
    });
    try writer.print("  speculatable:     {d}  ({d:.1}% of all chunks)\n", .{
        reg_stats.speculatable,
        percent(reg_stats.speculatable, reg_stats.chunks),
    });
    try writer.print("  spec + strict:    {d}  ({d:.1}% of speculatable)\n", .{
        reg_stats.speculatable_with_strictness,
        percent(reg_stats.speculatable_with_strictness, reg_stats.speculatable),
    });
    try writeCodeDedupCensus(writer, ev.hostAllocator(), ev.chunkRegistry());

    try writeSchedulerStats(writer, workers, sched_stats);

    if (top_n > 0) try writeTopInterned(writer, ev, top_n);
}

/// Header/body-split census: among the currently-registered chunks (already
/// deduped on full content INCLUDING source positions), how many share the same
/// *code* identity? Those are position-variant clones a header/body split would
/// collapse onto one shared body. Reports two fingerprints: code+constants (what
/// a naive split shares) and code-only (the upper bound if constants were also
/// interned).
fn writeCodeDedupCensus(writer: *std.Io.Writer, allocator: std.mem.Allocator, reg: *const bytecode.chunk.ChunkRegistry) !void {
    const census = try bytecode.inspect.CodeDedupCensus.build(allocator, reg);
    const captures = census.captures;

    try writer.writeAll("  header/body split potential:\n");
    try writer.print("    distinct bodies (code+consts): {d}  → {d} clones collapse ({d:.1}%)\n", .{
        census.distinct_full, census.dup_full, percent(census.dup_full, census.total),
    });
    try writer.print("    code bytes reclaimable:        {d}  of {d} ({d:.1}%)\n", .{
        census.dup_full_bytes, census.total_code, percentUsize(census.dup_full_bytes, census.total_code),
    });
    try writer.print("    distinct code (consts ignored): {d}  → {d} clones ({d:.1}%, upper bound)\n", .{
        census.distinct_code, census.dup_code, percent(census.dup_code, census.total),
    });

    try writer.writeAll("  capture-list interning potential:\n");
    try writer.print("    capture-list bytes:            {d}  over {d} ops ({d:.1}% of code)\n", .{
        captures.total, captures.ops, percentUsize(captures.total, census.total_code),
    });
    try writer.print("    duplicated within chunks:      {d}  ({d:.1}% of capture bytes, {d:.1}% of code)\n", .{
        captures.duplicated, percentUsize(captures.duplicated, captures.total), percentUsize(captures.duplicated, census.total_code),
    });
    try writer.print("    dup by op: thunk_defer {d} ({d:.0}%), thunk {d} ({d:.0}%), closure {d} ({d:.0}%)\n", .{
        captures.dup_defer,   percentUsize(captures.dup_defer, captures.duplicated),
        captures.dup_thunk,   percentUsize(captures.dup_thunk, captures.duplicated),
        captures.dup_closure, percentUsize(captures.dup_closure, captures.duplicated),
    });
    // Dual-op (ref for M>=2, keep single-capture inline) recoverable code: the
    // M>=2 inline bytes minus the 6-byte refs that replace them.
    const ref_bytes = captures.ops_ge2 * 6;
    const recoverable = if (captures.total_ge2 > ref_bytes) captures.total_ge2 - ref_bytes else 0;
    try writer.print("    M>=2 lists: {d} ops, {d} bytes; dual-op ref saves ~{d} code ({d:.1}% of code), dup among them {d}\n", .{
        captures.ops_ge2, captures.total_ge2, recoverable, percentUsize(recoverable, census.total_code), captures.dup_ge2,
    });
}

fn percentUsize(part: usize, whole: usize) f64 {
    if (whole == 0) return 0;
    return @as(f64, @floatFromInt(part)) * 100.0 / @as(f64, @floatFromInt(whole));
}

fn writeSchedulerStats(writer: *std.Io.Writer, workers: u8, s: SchedulerStats) !void {
    try writer.writeAll("\nscheduler\n");
    try writer.print("  workers:          {d}\n", .{workers});
    if (workers <= 1) {
        try writer.writeAll("  (single-threaded — no parallel submissions to count)\n");
        return;
    }
    try writer.writeAll("  submissions:\n");
    const spec_total = s.speculative_submitted + s.speculative_rejected;
    try writer.print("    speculative ok:    {d:>8}\n", .{s.speculative_submitted});
    try writer.print("    speculative rej:   {d:>8}  ({d:.1}% of attempted)\n", .{
        s.speculative_rejected,
        percent(s.speculative_rejected, spec_total),
    });
    const urgent_total = s.urgent_submitted + s.urgent_rejected;
    try writer.print("    urgent ok:         {d:>8}\n", .{s.urgent_submitted});
    try writer.print("    urgent rej:        {d:>8}  ({d:.1}% of attempted)\n", .{
        s.urgent_rejected,
        percent(s.urgent_rejected, urgent_total),
    });
    try writer.print("  pops:              {d:>8}  (helper popped own queue)\n", .{s.pops});
    try writer.print("  steals:            {d:>8}\n", .{s.steals});
    try writer.print("  cont pushes:       {d:>8}\n", .{s.cont_pushes});
    try writer.print("  cont steals:       {d:>8}\n", .{s.cont_steals});
    try writer.print("  parks:             {d:>8}\n", .{s.parks});
    try writer.print("  max VM sp:         {d:>8}        (peak value-stack depth)\n", .{s.max_vm_sp});
    try writer.writeAll("  worker time (summed across all workers including main):\n");
    try writer.print("    busy:            {d:>8.3} s   (inside fiber.resume)\n", .{
        @as(f64, @floatFromInt(s.busy_ns)) / 1.0e9,
    });
    try writer.print("    idle:            {d:>8.3} s   (parked on wake futex)\n", .{
        @as(f64, @floatFromInt(s.idle_ns)) / 1.0e9,
    });
    const accounted = s.busy_ns + s.idle_ns;
    try writer.print("    busy / total:    {d:>8.1}%\n", .{percent(s.busy_ns, accounted)});
}

fn percent(part: u64, total: u64) f64 {
    if (total == 0) return 0.0;
    return @as(f64, @floatFromInt(part)) * 100.0 / @as(f64, @floatFromInt(total));
}

fn writeTopInterned(writer: *std.Io.Writer, ev: *Evaluator, top_n: u32) !void {
    const allocator = ev.hostAllocator();
    const stats = ev.internStats();
    const Pair = struct { id: u32, len: u32 };
    var pairs = try allocator.alloc(Pair, stats.entries);
    defer allocator.free(pairs);
    var i: u32 = 0;
    while (i < stats.entries) : (i += 1) {
        pairs[i] = .{ .id = i, .len = @intCast(ev.internTable().get(i).len) };
    }
    std.mem.sort(Pair, pairs, {}, struct {
        fn lt(_: void, a: Pair, b: Pair) bool {
            return a.len > b.len;
        }
    }.lt);
    try writer.writeAll("\ntop interned strings (by length)\n");
    const n = @min(top_n, stats.entries);
    for (pairs[0..n]) |p| {
        const text = ev.internTable().get(p.id);
        const snippet_len = @min(text.len, 60);
        try writer.print("  #{d:<8} {d:>6} bytes  \"", .{ p.id, text.len });
        for (text[0..snippet_len]) |c| {
            switch (c) {
                '\\' => try writer.writeAll("\\\\"),
                '"' => try writer.writeAll("\\\""),
                '\n' => try writer.writeAll("\\n"),
                '\r' => try writer.writeAll("\\r"),
                '\t' => try writer.writeAll("\\t"),
                else => try writer.writeByte(c),
            }
        }
        if (text.len > snippet_len) try writer.writeAll("...");
        try writer.writeAll("\"\n");
    }
}

fn max32(items: []const u32) u32 {
    var m: u32 = 0;
    for (items) |x| m = @max(m, x);
    return m;
}

fn writeBar(writer: *std.Io.Writer, count: u32, max: u32, width: u32) !void {
    if (max == 0) return;
    const filled = (@as(u64, count) * @as(u64, width) + max / 2) / max;
    var i: u64 = 0;
    while (i < filled) : (i += 1) try writer.writeAll("\u{2588}");
    while (i < width) : (i += 1) try writer.writeByte(' ');
}

fn parseOptions(args_iter: *std.process.Args.Iterator) !Options {
    var options: Options = .{};
    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            return error.Help;
        } else if (std.mem.eql(u8, arg, "-E") or std.mem.eql(u8, arg, "--expr")) {
            const text = args_iter.next() orelse return error.MissingExpression;
            if (options.source != null) return error.TooManySources;
            options.source = .{ .expr = text };
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--file")) {
            const path = args_iter.next() orelse return error.MissingPath;
            if (options.source != null) return error.TooManySources;
            options.source = .{ .file = path };
        } else if (std.mem.eql(u8, arg, "--strict")) {
            options.strict = true;
        } else if (std.mem.eql(u8, arg, "--no-eval")) {
            options.no_eval = true;
        } else if (std.mem.eql(u8, arg, "--top")) {
            const text = args_iter.next() orelse return error.MissingTop;
            options.top = std.fmt.parseInt(u32, text, 10) catch return error.InvalidTop;
        } else if (std.mem.eql(u8, arg, "--workers")) {
            const text = args_iter.next() orelse return error.MissingWorkers;
            options.workers = std.fmt.parseInt(u8, text, 10) catch return error.InvalidWorkers;
        } else if (std.mem.startsWith(u8, arg, "--workers=")) {
            options.workers = std.fmt.parseInt(u8, arg["--workers=".len..], 10) catch return error.InvalidWorkers;
        } else {
            return error.UnknownOption;
        }
    }
    return options;
}

fn optionErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.MissingExpression => "missing expression after -E or --expr",
        error.MissingPath => "missing path after --file",
        error.MissingTop => "missing N after --top",
        error.InvalidTop => "expected --top to be a non-negative integer",
        error.MissingWorkers => "missing N after --workers",
        error.InvalidWorkers => "expected --workers to be a non-negative integer",
        error.TooManySources => "provide only one expression or file",
        error.UnknownOption => "unknown option",
        else => @errorName(err),
    };
}
