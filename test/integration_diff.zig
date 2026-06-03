//! Differential integration runner for fix.
//!
//! The generator deliberately avoids owning a second Nix grammar. It combines a
//! corpus of real expressions, then asks real Nix and fix what each candidate
//! means.

const std = @import("std");

const Config = struct {
    seed: ?u64 = null,
    corpus_dir: []const u8 = "test/fuzz-corpus",
    failure_dir: []const u8 = "",
    fix_bin: []const u8 = "zig-out/bin/fix",
    nix_bin: []const u8 = "nix-instantiate",
    min_depth: u8 = 0,
    max_depth: u8 = 4,
    jobs: usize = 0,
    shrink: bool = false,
    dump_cases_path: ?[]const u8 = null,
    dump_skipped_path: ?[]const u8 = null,
};

const Fragment = struct {
    text: []const u8,
    free_names: []const []const u8 = &.{},

    fn deinit(self: Fragment, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        for (self.free_names) |name| allocator.free(name);
        if (self.free_names.len != 0) allocator.free(self.free_names);
    }

    fn closed(self: Fragment) bool {
        return self.free_names.len == 0;
    }
};

const GeneratedCase = struct {
    index: usize,
    expr: []u8,
    skipped: bool = false,

    fn deinit(self: GeneratedCase, allocator: std.mem.Allocator) void {
        allocator.free(self.expr);
    }
};

const CaseStream = struct {
    allocator: std.mem.Allocator,
    corpus: []const Fragment,
    seed: u64,
    min_depth: u8,
    total: usize,
    next_index: usize = 0,

    fn init(
        allocator: std.mem.Allocator,
        corpus: []const Fragment,
        seed: u64,
        min_depth: u8,
        max_depth: u8,
    ) !CaseStream {
        return .{
            .allocator = allocator,
            .corpus = corpus,
            .seed = seed,
            .min_depth = min_depth,
            .total = try generatedCaseCount(corpus.len, min_depth, max_depth),
        };
    }

    fn next(self: *CaseStream) !?GeneratedCase {
        if (self.next_index >= self.total) return null;
        const index = self.next_index;
        self.next_index += 1;
        return try generateCase(self.allocator, self.corpus, self.seed, index, self.min_depth);
    }
};

const Template = enum {
    direct_add,
    let_scope,
    with_scope,
    rec_scope,
    lambda_scope,
};

const FragmentCorpus = std.ArrayListUnmanaged(Fragment);
const ShrinkCandidates = std.ArrayListUnmanaged([]const u8);
const command_stdout_limit = 8 * 1024 * 1024;
const command_stderr_limit = 1024 * 1024;
const progress_interval_ns = std.time.ns_per_s;
const job_queue_per_worker = 64;
const job_queue_min = 1024;
const result_queue_per_worker = 8;
const result_queue_min = 128;

const Reporter = struct {
    io: std.Io,
    interactive: bool,
    use_color: bool,
    started_ns: i96,
    next_progress_ns: i96,
    drew_progress: bool = false,
    found_count: usize = 0,
    checked_count: usize = 0,
    skipped_count: usize = 0,

    fn init(io: std.Io, env: *const std.process.Environ.Map) Reporter {
        const now = nowNs(io);
        const interactive = interactiveOutput(io, env);
        return .{
            .io = io,
            .interactive = interactive,
            .use_color = autoColor(interactive, env),
            .started_ns = now,
            .next_progress_ns = now + progress_interval_ns,
        };
    }

    fn printRepro(self: Reporter, config: Config, seed: u64, worker_count: usize, total_jobs: usize) void {
        const dim = if (self.use_color) "\x1b[2m" else "";
        const reset = if (self.use_color) "\x1b[0m" else "";
        std.debug.print(
            "{s}integration-diff:{s} zig build integration-test -- --seed={} --jobs={} --min-depth={} --max-depth={} --corpus={s} --failures={s} --fix-bin={s} --nix-bin={s}",
            .{
                dim,
                reset,
                seed,
                worker_count,
                config.min_depth,
                config.max_depth,
                config.corpus_dir,
                config.failure_dir,
                config.fix_bin,
                config.nix_bin,
            },
        );
        if (config.shrink) std.debug.print(" --shrink", .{});
        if (config.dump_cases_path) |path| std.debug.print(" --dump-cases={s}", .{path});
        if (config.dump_skipped_path) |path| std.debug.print(" --dump-skipped={s}", .{path});
        std.debug.print(" # cases={}\n", .{total_jobs});
    }

    fn progress(self: *Reporter, completed: usize, total: usize) void {
        if (total == 0 or completed >= total) return;
        const now = nowNs(self.io);
        if (now < self.next_progress_ns) return;
        self.printProgress(now, completed, total);
        while (self.next_progress_ns <= now) self.next_progress_ns += progress_interval_ns;
    }

    fn printProgress(self: *Reporter, now: i96, completed: usize, total: usize) void {
        const dim = if (self.use_color) "\x1b[2m" else "";
        const reset = if (self.use_color) "\x1b[0m" else "";
        const elapsed_ns = @max(now - self.started_ns, 1);
        const elapsed_s = @as(u64, @intCast(@max(@divTrunc(elapsed_ns, std.time.ns_per_s), 0)));
        const rate = casesPerSecond(completed, elapsed_ns);
        const eta_s = etaSeconds(total - completed, rate);
        const percent = if (total == 0) 100 else completed * 100 / total;
        const skip_permille = permille(self.skipped_count, completed);
        const spinner = spinnerFrame(elapsed_ns);
        if (self.interactive) std.debug.print("\r\x1b[2K", .{});
        std.debug.print(
            "{s}integration-diff:{s} {c} done={}/{} {}% skipped={}.{}% ({}) found={} rate={}/s eta={}s elapsed={}s",
            .{
                dim,
                reset,
                spinner,
                completed,
                total,
                percent,
                skip_permille / 10,
                skip_permille % 10,
                self.skipped_count,
                self.found_count,
                rate,
                eta_s,
                elapsed_s,
            },
        );
        if (!self.interactive) std.debug.print("\n", .{});
        self.drew_progress = true;
    }

    fn checked(self: *Reporter) void {
        self.checked_count += 1;
    }

    fn skipped(self: *Reporter) void {
        self.skipped_count += 1;
    }

    fn commandError(self: Reporter, seed: u64, iteration: usize, err: anyerror, expr: []const u8) void {
        const red = if (self.use_color) "\x1b[31m" else "";
        const reset = if (self.use_color) "\x1b[0m" else "";
        std.debug.print(
            "{s}integration-diff: command failed{s} at seed {} iteration {}: {s}\n",
            .{ red, reset, seed, iteration, @errorName(err) },
        );
        std.debug.print("expression:\n{s}\n", .{expr});
    }

    fn saveError(self: Reporter, seed: u64, iteration: usize, err: anyerror) void {
        const red = if (self.use_color) "\x1b[31m" else "";
        const reset = if (self.use_color) "\x1b[0m" else "";
        std.debug.print(
            "{s}integration-diff: failed to save mismatch{s} at seed {} iteration {}: {s}\n",
            .{ red, reset, seed, iteration, @errorName(err) },
        );
    }

    fn mismatch(self: *Reporter, outcome: Outcome, seed: u64, iteration: usize, failure_dir: []const u8, expr: []const u8) void {
        self.found_count += 1;
        const red = if (self.use_color) "\x1b[31m" else "";
        const reset = if (self.use_color) "\x1b[0m" else "";
        std.debug.print(
            "{s}integration-diff: found {s}{s} at seed {} iteration {}; saved under {s}\n",
            .{ red, @tagName(outcome), reset, seed, iteration, failure_dir },
        );
        std.debug.print("expression:\n{s}\n", .{expr});
    }

    fn finish(self: Reporter, total: usize) void {
        if (self.interactive and self.drew_progress) std.debug.print("\r\x1b[2K", .{});
        const color = if (self.use_color)
            if (self.found_count == 0) "\x1b[32m" else "\x1b[31m"
        else
            "";
        const reset = if (self.use_color) "\x1b[0m" else "";
        std.debug.print(
            "{s}integration-diff: found={} checked={} skipped={} cases={}{s}\n",
            .{ color, self.found_count, self.checked_count, self.skipped_count, total, reset },
        );
    }

    fn corpusError(self: Reporter, comptime fmt: []const u8, args: anytype) void {
        const red = if (self.use_color) "\x1b[31m" else "";
        const reset = if (self.use_color) "\x1b[0m" else "";
        std.debug.print("{s}integration-diff: ", .{red});
        std.debug.print(fmt, args);
        std.debug.print("{s}\n", .{reset});
    }
};

const Outcome = enum {
    skipped,
    both_ok_same,
    both_ok_different,
    nix_accepts_fix_rejects,
    fix_accepts_nix_rejects,
    both_reject,
};

const CommandResult = struct {
    ok: bool,
    comparable: bool = true,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: CommandResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

const Classification = struct {
    outcome: Outcome,
    nix: CommandResult,
    fix: CommandResult,

    fn deinit(self: Classification, allocator: std.mem.Allocator) void {
        self.nix.deinit(allocator);
        self.fix.deinit(allocator);
    }

    fn interesting(self: Classification) bool {
        return switch (self.outcome) {
            .skipped, .both_ok_same, .both_reject => false,
            .both_ok_different, .nix_accepts_fix_rejects, .fix_accepts_nix_rejects => true,
        };
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var config = Config{};
    try parseArgs(&config, init);

    const seed = config.seed orelse randomSeed(init.io);
    const worker_count = try resolveWorkerCount(config.jobs);

    var default_failure_dir: ?[]u8 = null;
    defer if (default_failure_dir) |dir| allocator.free(dir);
    if (config.failure_dir.len == 0) {
        default_failure_dir = try std.fmt.allocPrint(
            allocator,
            "/tmp/fix-integration-failures-{d}-{d}",
            .{ seed, randomSeed(init.io) },
        );
        config.failure_dir = default_failure_dir.?;
    }

    const early_reporter = Reporter.init(init.io, init.environ_map);
    var corpus: FragmentCorpus = .empty;
    defer {
        for (corpus.items) |fragment| fragment.deinit(allocator);
        corpus.deinit(allocator);
    }
    loadCorpus(allocator, init.io, config.corpus_dir, &corpus) catch |err| {
        early_reporter.corpusError("failed to load corpus {s}: {s}", .{ config.corpus_dir, @errorName(err) });
        std.process.exit(1);
    };
    if (corpus.items.len == 0) {
        early_reporter.corpusError("corpus {s} did not contain any expressions", .{config.corpus_dir});
        std.process.exit(1);
    }
    sortCorpus(corpus.items);

    if (config.min_depth > config.max_depth) {
        early_reporter.corpusError("--min-depth must be less than or equal to --max-depth", .{});
        std.process.exit(1);
    }

    var stream = try CaseStream.init(allocator, corpus.items, seed, config.min_depth, config.max_depth);
    const total_jobs = stream.total;
    var reporter = Reporter.init(init.io, init.environ_map);
    reporter.printRepro(config, seed, worker_count, total_jobs);

    if (total_jobs == 0) {
        reporter.finish(total_jobs);
        return;
    }

    if (config.dump_cases_path != null or config.dump_skipped_path != null) {
        try dumpGeneratedCases(allocator, init.io, &config, &stream, &reporter);
        reporter.finish(total_jobs);
        return;
    }

    try runHarness(allocator, init.io, &config, &stream, worker_count, total_jobs, &reporter);
}

const Job = struct {
    index: usize,
    seed: u64,
    iteration: usize,
    expr: []u8,
    skipped: bool = false,
};

const JobResult = struct {
    index: usize,
    seed: u64,
    iteration: usize,
    expr: []u8,
    classification: ?Classification = null,
    err: ?anyerror = null,
    skipped: bool = false,

    fn deinit(self: *JobResult, allocator: std.mem.Allocator) void {
        if (self.classification) |classification| classification.deinit(allocator);
        allocator.free(self.expr);
    }
};

fn BlockingQueue(comptime T: type) type {
    return struct {
        queue: std.Io.TypeErasedQueue,

        const Self = @This();

        fn init(storage: []T) Self {
            return .{
                .queue = .init(std.mem.sliceAsBytes(storage)),
            };
        }

        fn put(self: *Self, io: std.Io, item: T) !void {
            var copy = item;
            const bytes = std.mem.asBytes(&copy);
            const written = try self.queue.putUncancelable(io, bytes, bytes.len);
            if (written != bytes.len) return error.ShortQueueWrite;
        }

        fn get(self: *Self, io: std.Io) !?T {
            var item: T = undefined;
            const bytes = std.mem.asBytes(&item);
            const read = self.queue.getUncancelable(io, bytes, bytes.len) catch |err| switch (err) {
                error.Closed => return null,
            };
            if (read != bytes.len) return error.ShortQueueRead;
            return item;
        }

        fn close(self: *Self, io: std.Io) void {
            self.queue.close(io);
        }
    };
}

const JobQueue = BlockingQueue(Job);
const ResultQueue = BlockingQueue(JobResult);

const ProducerContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: *CaseStream,
    jobs: *JobQueue,
};

const WorkerContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: *const Config,
    jobs: *JobQueue,
    results: *ResultQueue,
};

fn runHarness(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: *const Config,
    stream: *CaseStream,
    worker_count: usize,
    total_jobs: usize,
    reporter: *Reporter,
) !void {
    const job_queue_len = queueCapacity(worker_count, total_jobs, job_queue_per_worker, job_queue_min);
    const result_queue_len = queueCapacity(worker_count, total_jobs, result_queue_per_worker, result_queue_min);

    const job_storage = try allocator.alloc(Job, job_queue_len);
    defer allocator.free(job_storage);
    var job_queue = JobQueue.init(job_storage);

    const result_storage = try allocator.alloc(JobResult, result_queue_len);
    defer allocator.free(result_storage);
    var result_queue = ResultQueue.init(result_storage);

    var producer_context: ProducerContext = .{
        .allocator = allocator,
        .io = io,
        .stream = stream,
        .jobs = &job_queue,
    };
    const producer = try std.Thread.spawn(.{}, producerMain, .{&producer_context});

    var worker_context: WorkerContext = .{
        .allocator = allocator,
        .io = io,
        .config = config,
        .jobs = &job_queue,
        .results = &result_queue,
    };
    const workers = try allocator.alloc(std.Thread, worker_count);
    defer allocator.free(workers);
    for (workers) |*worker| {
        worker.* = try std.Thread.spawn(.{}, workerMain, .{&worker_context});
    }

    var pending = try allocator.alloc(?JobResult, total_jobs);
    defer allocator.free(pending);
    @memset(pending, null);
    defer {
        for (pending) |*maybe_result| {
            if (maybe_result.*) |*result| result.deinit(allocator);
        }
    }

    var next_to_report: usize = 0;
    var received: usize = 0;
    var found_mismatch = false;
    var command_error: ?anyerror = null;

    while (received < total_jobs) : (received += 1) {
        const result = (try result_queue.get(io)) orelse return error.ResultQueueClosed;
        pending[result.index] = result;

        while (next_to_report < total_jobs) {
            const current = pending[next_to_report] orelse break;
            pending[next_to_report] = null;
            var mutable_current = current;
            defer mutable_current.deinit(allocator);

            if (mutable_current.skipped) {
                reporter.skipped();
            } else if (mutable_current.err) |err| {
                command_error = err;
                reporter.commandError(mutable_current.seed, mutable_current.iteration, err, mutable_current.expr);
            } else if (mutable_current.classification) |*classification| {
                if (classification.outcome == .skipped) {
                    reporter.skipped();
                } else {
                    reporter.checked();
                }
                if (classification.interesting()) {
                    found_mismatch = true;
                    reportInteresting(
                        allocator,
                        io,
                        config,
                        mutable_current.seed,
                        mutable_current.iteration,
                        mutable_current.expr,
                        classification,
                        reporter,
                    ) catch |err| {
                        command_error = err;
                        reporter.saveError(mutable_current.seed, mutable_current.iteration, err);
                    };
                }
            }

            next_to_report += 1;
            reporter.progress(next_to_report, total_jobs);
        }
    }

    producer.join();
    for (workers) |worker| worker.join();

    if (command_error) |err| return err;
    reporter.finish(total_jobs);
    if (found_mismatch) std.process.exit(1);
}

fn producerMain(context: *ProducerContext) void {
    defer context.jobs.close(context.io);
    produceJobs(context) catch |err| {
        std.debug.panic("integration-diff producer failed: {s}", .{@errorName(err)});
    };
}

fn produceJobs(context: *ProducerContext) !void {
    while (try context.stream.next()) |generated| {
        errdefer generated.deinit(context.allocator);
        try context.jobs.put(context.io, .{
            .index = generated.index,
            .seed = context.stream.seed,
            .iteration = generated.index,
            .expr = generated.expr,
            .skipped = generated.skipped,
        });
    }
}

fn workerMain(context: *WorkerContext) void {
    while (true) {
        const job = context.jobs.get(context.io) catch |err| {
            std.debug.panic("integration-diff job queue failed: {s}", .{@errorName(err)});
        } orelse return;

        var result: JobResult = .{
            .index = job.index,
            .seed = job.seed,
            .iteration = job.iteration,
            .expr = job.expr,
            .skipped = job.skipped,
        };
        if (job.skipped) {
            context.results.put(context.io, result) catch |err| {
                std.debug.panic("integration-diff result queue failed: {s}", .{@errorName(err)});
            };
            continue;
        }

        result.classification = classify(context.allocator, context.io, context.config, job.expr) catch |err| {
            result.err = err;
            result.classification = null;
            context.results.put(context.io, result) catch |queue_err| {
                std.debug.panic("integration-diff result queue failed: {s}", .{@errorName(queue_err)});
            };
            continue;
        };

        context.results.put(context.io, result) catch |err| {
            std.debug.panic("integration-diff result queue failed: {s}", .{@errorName(err)});
        };
    }
}

fn queueCapacity(worker_count: usize, total_jobs: usize, per_worker: usize, minimum: usize) usize {
    const scaled = std.math.mul(usize, worker_count, per_worker) catch total_jobs;
    return @min(total_jobs, @max(@max(scaled, minimum), 1));
}

fn parseArgs(config: *Config, init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();

    _ = args.next();
    while (args.next()) |arg| {
        if (try optionValue(&args, arg, "--seed")) |value| {
            config.seed = try std.fmt.parseInt(u64, value, 0);
        } else if (try optionValue(&args, arg, "--corpus")) |value| {
            config.corpus_dir = value;
        } else if (try optionValue(&args, arg, "--failures")) |value| {
            config.failure_dir = value;
        } else if (try optionValue(&args, arg, "--fix-bin")) |value| {
            config.fix_bin = value;
        } else if (try optionValue(&args, arg, "--nix-bin")) |value| {
            config.nix_bin = value;
        } else if (try optionValue(&args, arg, "--min-depth")) |value| {
            config.min_depth = try std.fmt.parseInt(u8, value, 10);
        } else if (try optionValue(&args, arg, "--max-depth")) |value| {
            config.max_depth = try std.fmt.parseInt(u8, value, 10);
        } else if (try optionValue(&args, arg, "--jobs")) |value| {
            config.jobs = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.eql(u8, arg, "--shrink")) {
            config.shrink = true;
        } else if (try optionValue(&args, arg, "--dump-cases")) |value| {
            config.dump_cases_path = value;
        } else if (try optionValue(&args, arg, "--dump-skipped")) |value| {
            config.dump_skipped_path = value;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            usage();
            std.process.exit(0);
        } else {
            std.debug.print("unknown argument: {s}\n", .{arg});
            usage();
            return error.UnknownArgument;
        }
    }
}

fn optionValue(args: anytype, arg: []const u8, comptime name: []const u8) !?[]const u8 {
    if (std.mem.eql(u8, arg, name)) return args.next() orelse error.MissingArgument;
    if (std.mem.startsWith(u8, arg, name) and arg.len > name.len and arg[name.len] == '=') {
        return arg[name.len + 1 ..];
    }
    return null;
}

fn usage() void {
    std.debug.print(
        \\usage: zig build integration-test -- [options]
        \\
        \\options:
        \\  --seed N            deterministic RNG seed; random when omitted
        \\  --corpus PATH       directory of .nix seed files
        \\  --failures PATH     directory for reproducers (default: /tmp/fix-integration-failures-$seed-$nonce)
        \\  --fix-bin PATH      fix executable (default: zig-out/bin/fix)
        \\  --nix-bin PATH      nix-instantiate executable
        \\  --min-depth N       minimum composition depth (default: 0)
        \\  --max-depth N       maximum composition depth (default: 4)
        \\  --jobs N            parallel evaluator jobs; 0 means CPU count
        \\  --shrink            minimize each saved failing candidate
        \\  --dump-cases PATH   write generated checkable cases and exit
        \\  --dump-skipped PATH write generated skipped candidates and exit
        \\
    , .{});
}

fn resolveWorkerCount(requested: usize) !usize {
    if (requested != 0) return requested;
    return @max(@as(usize, 1), try std.Thread.getCpuCount());
}

fn generatedCaseCount(corpus_len: usize, min_depth: u8, max_depth: u8) !usize {
    const pair_count = std.math.mul(usize, corpus_len, corpus_len) catch return error.TooManyCases;
    const depth_count = @as(usize, max_depth - min_depth) + 1;
    return std.math.mul(usize, pair_count, depth_count) catch error.TooManyCases;
}

fn randomSeed(io: std.Io) u64 {
    var bytes: [8]u8 = undefined;
    io.random(&bytes);
    return @bitCast(bytes);
}

fn nowNs(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).toNanoseconds();
}

fn interactiveOutput(io: std.Io, env: *const std.process.Environ.Map) bool {
    if (env.get("TERM")) |term| {
        if (std.mem.eql(u8, term, "dumb")) return false;
    }
    return std.Io.File.stderr().isTty(io) catch false;
}

fn autoColor(interactive: bool, env: *const std.process.Environ.Map) bool {
    if (!interactive) return false;
    if (env.get("NO_COLOR")) |_| return false;
    return true;
}

fn casesPerSecond(completed: usize, elapsed_ns: i96) u64 {
    const elapsed = @as(u128, @intCast(@max(elapsed_ns, 1)));
    return @intCast((@as(u128, completed) * std.time.ns_per_s) / elapsed);
}

fn etaSeconds(remaining: usize, rate: u64) u64 {
    if (rate == 0) return 0;
    return @intCast((remaining + rate - 1) / rate);
}

fn permille(part: usize, whole: usize) usize {
    if (whole == 0) return 0;
    return part * 1000 / whole;
}

fn spinnerFrame(elapsed_ns: i96) u8 {
    const frames = [_]u8{ '|', '/', '-', '\\' };
    const tick: usize = @intCast(@divTrunc(@max(elapsed_ns, 0), std.time.ns_per_s));
    return frames[tick % frames.len];
}

fn loadCorpus(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    corpus: *FragmentCorpus,
) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".nix")) continue;

        const text = try dir.readFileAlloc(io, entry.name, allocator, .limited(1024 * 1024));
        defer allocator.free(text);
        try appendCorpusLines(allocator, text, corpus);
    }
}

fn appendCorpusLines(allocator: std.mem.Allocator, text: []const u8, corpus: *FragmentCorpus) !void {
    var pending_free_names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (pending_free_names.items) |name| allocator.free(name);
        pending_free_names.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (trimmed[0] == '#') {
            if (std.mem.startsWith(u8, trimmed, "# free:")) {
                for (pending_free_names.items) |name| allocator.free(name);
                pending_free_names.clearRetainingCapacity();
                try appendFreeNameList(allocator, &pending_free_names, trimmed["# free:".len..]);
            }
            continue;
        }

        const free_names = try pending_free_names.toOwnedSlice(allocator);
        pending_free_names = .empty;
        const fragment_text = allocator.dupe(u8, trimmed) catch |err| {
            freeNames(allocator, free_names);
            return err;
        };
        var fragment: Fragment = .{
            .text = fragment_text,
            .free_names = free_names,
        };
        corpus.append(allocator, fragment) catch |err| {
            fragment.deinit(allocator);
            return err;
        };
    }
}

fn appendFreeNameList(
    allocator: std.mem.Allocator,
    names: *std.ArrayListUnmanaged([]const u8),
    text: []const u8,
) !void {
    var parts = std.mem.tokenizeAny(u8, text, " \t\r,");
    while (parts.next()) |name| {
        if (!validBinderName(name)) return error.InvalidFreeName;
        try appendUniqueName(allocator, names, name);
    }
}

fn validBinderName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!isIdentStart(name[0])) return false;
    for (name[1..]) |c| {
        if (!isIdentRest(c)) return false;
    }
    return true;
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentRest(c: u8) bool {
    return isIdentStart(c) or std.ascii.isDigit(c) or c == '\'' or c == '-';
}

fn sortCorpus(corpus: []Fragment) void {
    std.mem.sort(Fragment, corpus, {}, lessThanExpr);
}

fn lessThanExpr(_: void, lhs: Fragment, rhs: Fragment) bool {
    return std.mem.lessThan(u8, lhs.text, rhs.text);
}

fn dumpGeneratedCases(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: *const Config,
    stream: *CaseStream,
    reporter: *Reporter,
) !void {
    var cases = try DumpFile.open(io, config.dump_cases_path);
    defer cases.close();
    var skipped = try DumpFile.open(io, config.dump_skipped_path);
    defer skipped.close();

    while (try stream.next()) |generated| {
        errdefer generated.deinit(allocator);

        if (generated.skipped) {
            try skipped.writeLine(generated.expr);
            reporter.skipped();
        } else {
            try cases.writeLine(generated.expr);
            reporter.checked();
        }
        generated.deinit(allocator);
        reporter.progress(stream.next_index, stream.total);
    }
}

const DumpFile = struct {
    io: std.Io,
    file: ?std.Io.File = null,

    fn open(io: std.Io, maybe_path: ?[]const u8) !DumpFile {
        const path = maybe_path orelse return .{ .io = io };
        if (std.fs.path.dirname(path)) |dir| try std.Io.Dir.cwd().createDirPath(io, dir);
        return .{
            .io = io,
            .file = try std.Io.Dir.cwd().createFile(io, path, .{}),
        };
    }

    fn close(self: *DumpFile) void {
        if (self.file) |file| file.close(self.io);
        self.file = null;
    }

    fn writeLine(self: DumpFile, line: []const u8) !void {
        const file = self.file orelse return;
        try file.writeStreamingAll(self.io, line);
        try file.writeStreamingAll(self.io, "\n");
    }
};

fn generateCase(
    allocator: std.mem.Allocator,
    corpus: []const Fragment,
    seed: u64,
    iteration: usize,
    min_depth: u8,
) !GeneratedCase {
    const pair_count = try pairCount(corpus.len);
    const depth = min_depth + @as(u8, @intCast(iteration / pair_count));
    const pair_index = permutedIndex(seed, iteration % pair_count, pair_count);
    const left = corpus[pair_index / corpus.len];
    const right = corpus[pair_index % corpus.len];
    var fragment = if (right.free_names.len != 0)
        try scopedBodyFragment(allocator, left, right, depth)
    else if (left.free_names.len != 0)
        try scopedBodyFragment(allocator, right, left, depth)
    else
        try closedPairFragment(allocator, left, right, depth);
    errdefer fragment.deinit(allocator);

    const skipped = !fragment.closed();
    const expr = try allocator.dupe(u8, fragment.text);
    fragment.deinit(allocator);
    return .{ .index = iteration, .expr = expr, .skipped = skipped };
}

fn closedPairFragment(allocator: std.mem.Allocator, left: Fragment, right: Fragment, depth: u8) !Fragment {
    const template = closedTemplate(depth);
    const text = switch (template) {
        .direct_add => try binary(allocator, left.text, "+", right.text),
        .let_scope => try std.mem.concat(allocator, u8, &.{ "let x = ", left.text, "; y = ", right.text, "; in x + y" }),
        .with_scope => try std.mem.concat(allocator, u8, &.{ "with { x = ", left.text, "; y = ", right.text, "; }; x + y" }),
        .rec_scope => try std.mem.concat(allocator, u8, &.{ "(rec { x = ", left.text, "; y = ", right.text, "; z = x + y; }).z" }),
        .lambda_scope => try std.mem.concat(allocator, u8, &.{ "(x: y: x + y) (", left.text, ") (", right.text, ")" }),
    };
    errdefer allocator.free(text);
    return .{
        .text = text,
        .free_names = try unionNames(allocator, left.free_names, right.free_names),
    };
}

fn scopedBodyFragment(allocator: std.mem.Allocator, value: Fragment, body: Fragment, depth: u8) !Fragment {
    var fragment = try cloneFragment(allocator, body);
    errdefer fragment.deinit(allocator);

    var step: u8 = 0;
    while (step < depth and fragment.free_names.len != 0) : (step += 1) {
        const name = fragment.free_names[0];
        const template = binderTemplate(step);
        const next = try bindOneFreeName(allocator, template, value, fragment, name);
        fragment.deinit(allocator);
        fragment = next;
    }

    return fragment;
}

fn closedTemplate(depth: u8) Template {
    return switch (depth) {
        0 => .direct_add,
        1 => .let_scope,
        2 => .with_scope,
        3 => .rec_scope,
        else => .lambda_scope,
    };
}

fn binderTemplate(step: u8) Template {
    return switch (step % 4) {
        0 => .let_scope,
        1 => .with_scope,
        2 => .rec_scope,
        else => .lambda_scope,
    };
}

fn bindOneFreeName(
    allocator: std.mem.Allocator,
    template: Template,
    value: Fragment,
    body: Fragment,
    name: []const u8,
) !Fragment {
    const text = switch (template) {
        .let_scope => try std.mem.concat(allocator, u8, &.{ "let ", name, " = ", value.text, "; in ", body.text }),
        .with_scope => try std.mem.concat(allocator, u8, &.{ "with { ", name, " = ", value.text, "; }; ", body.text }),
        .rec_scope => try std.mem.concat(allocator, u8, &.{ "(rec { ", name, " = ", value.text, "; result = ", body.text, "; }).result" }),
        .lambda_scope => try std.mem.concat(allocator, u8, &.{ "(", name, ": ", body.text, ") (", value.text, ")" }),
        .direct_add => unreachable,
    };
    errdefer allocator.free(text);

    const remaining_body_names = try subtractName(allocator, body.free_names, name);
    defer freeNames(allocator, remaining_body_names);
    return .{
        .text = text,
        .free_names = try unionNames(allocator, value.free_names, remaining_body_names),
    };
}

fn cloneFragment(allocator: std.mem.Allocator, fragment: Fragment) !Fragment {
    return .{
        .text = try allocator.dupe(u8, fragment.text),
        .free_names = try dupeNames(allocator, fragment.free_names),
    };
}

fn dupeNames(allocator: std.mem.Allocator, names: []const []const u8) ![]const []const u8 {
    if (names.len == 0) return &.{};
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (out.items) |name| allocator.free(name);
        out.deinit(allocator);
    }
    for (names) |name| try appendUniqueName(allocator, &out, name);
    return out.toOwnedSlice(allocator);
}

fn unionNames(allocator: std.mem.Allocator, left: []const []const u8, right: []const []const u8) ![]const []const u8 {
    if (left.len == 0 and right.len == 0) return &.{};
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (out.items) |name| allocator.free(name);
        out.deinit(allocator);
    }
    for (left) |name| try appendUniqueName(allocator, &out, name);
    for (right) |name| try appendUniqueName(allocator, &out, name);
    return out.toOwnedSlice(allocator);
}

fn subtractName(allocator: std.mem.Allocator, names: []const []const u8, bound: []const u8) ![]const []const u8 {
    if (names.len == 0) return &.{};
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (out.items) |name| allocator.free(name);
        out.deinit(allocator);
    }
    for (names) |name| {
        if (!std.mem.eql(u8, name, bound)) try appendUniqueName(allocator, &out, name);
    }
    if (out.items.len == 0) return &.{};
    return out.toOwnedSlice(allocator);
}

fn appendUniqueName(
    allocator: std.mem.Allocator,
    names: *std.ArrayListUnmanaged([]const u8),
    name: []const u8,
) !void {
    for (names.items) |existing| {
        if (std.mem.eql(u8, existing, name)) return;
    }
    try names.append(allocator, try allocator.dupe(u8, name));
}

fn freeNames(allocator: std.mem.Allocator, names: []const []const u8) void {
    for (names) |name| allocator.free(name);
    if (names.len != 0) allocator.free(names);
}

fn pairCount(corpus_len: usize) !usize {
    return std.math.mul(usize, corpus_len, corpus_len) catch error.TooManyCases;
}

fn permutedIndex(seed: u64, iteration: usize, count: usize) usize {
    const offset: usize = @intCast(seed % count);
    const stride = coprimeStride(seed / @as(u64, @intCast(count)), count);
    return (offset + iteration *% stride) % count;
}

fn coprimeStride(seed: u64, count: usize) usize {
    std.debug.assert(count > 0);
    if (count == 1) return 1;
    var stride: usize = @intCast(seed % count);
    stride = @max(stride, 1);
    while (gcd(stride, count) != 1) {
        stride += 1;
        if (stride == count) stride = 1;
    }
    return stride;
}

fn gcd(a_start: usize, b_start: usize) usize {
    var a = a_start;
    var b = b_start;
    while (b != 0) {
        const next = a % b;
        a = b;
        b = next;
    }
    return a;
}

fn binary(allocator: std.mem.Allocator, left: []const u8, op: []const u8, right: []const u8) ![]u8 {
    return std.mem.concat(allocator, u8, &.{ "(", left, ") ", op, " (", right, ")" });
}

fn classify(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: *const Config,
    expr: []const u8,
) !Classification {
    const nix_expr = try std.mem.concat(allocator, u8, &.{ "(", expr, ")" });
    defer allocator.free(nix_expr);

    const nix = try runCommand(allocator, io, &.{ config.nix_bin, "--eval", "--xml", "--expr", nix_expr });
    errdefer nix.deinit(allocator);

    const fix = try runCommand(allocator, io, &.{ config.fix_bin, "--xml", "--expr", expr });
    errdefer fix.deinit(allocator);

    const outcome: Outcome = if (!nix.comparable or !fix.comparable)
        .skipped
    else if (nix.ok and fix.ok)
        if (try equivalentXml(allocator, nix.stdout, fix.stdout)) .both_ok_same else .both_ok_different
    else if (nix.ok and !fix.ok)
        .nix_accepts_fix_rejects
    else if (!nix.ok and fix.ok)
        .fix_accepts_nix_rejects
    else
        .both_reject;

    return .{
        .outcome = outcome,
        .nix = nix,
        .fix = fix,
    };
}

fn runCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
) !CommandResult {
    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(command_stdout_limit),
        .stderr_limit = .limited(command_stderr_limit),
    }) catch |err| switch (err) {
        error.StreamTooLong => return .{
            .ok = false,
            .comparable = false,
            .stdout = try allocator.dupe(u8, ""),
            .stderr = try allocator.dupe(u8, "output exceeded integration harness limit"),
        },
        else => return err,
    };

    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };

    return .{
        .ok = ok,
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

fn equivalentXml(allocator: std.mem.Allocator, left: []const u8, right: []const u8) !bool {
    var left_doc = parseXml(allocator, left) catch return false;
    defer left_doc.deinit();

    var right_doc = parseXml(allocator, right) catch return false;
    defer right_doc.deinit();

    return xmlNodesEqual(left_doc.root, right_doc.root);
}

const XmlDocument = struct {
    arena: std.heap.ArenaAllocator,
    root: XmlNode,

    fn deinit(self: *XmlDocument) void {
        self.arena.deinit();
    }
};

const XmlNode = struct {
    name: []const u8,
    attrs: []const XmlAttr,
    children: []const XmlNode,
};

const XmlAttr = struct {
    name: []const u8,
    value: []const u8,
};

const XmlParser = struct {
    allocator: std.mem.Allocator,
    input: []const u8,
    pos: usize = 0,

    fn document(self: *XmlParser) !XmlNode {
        self.skipWhitespace();
        if (self.startsWith("<?xml")) {
            self.pos += "<?xml".len;
            while (!self.eof() and !self.startsWith("?>")) self.pos += 1;
            if (self.eof()) return error.InvalidXml;
            self.pos += "?>".len;
        }
        self.skipWhitespace();
        const root = try self.element();
        self.skipWhitespace();
        if (!self.eof()) return error.InvalidXml;
        return root;
    }

    fn element(self: *XmlParser) !XmlNode {
        try self.expect('<');
        if (self.peek() == '/') return error.InvalidXml;

        const element_name = try self.name();
        var attrs: std.ArrayListUnmanaged(XmlAttr) = .empty;
        defer attrs.deinit(self.allocator);
        var children: std.ArrayListUnmanaged(XmlNode) = .empty;
        defer children.deinit(self.allocator);

        while (true) {
            self.skipWhitespace();
            if (self.consume("/>")) {
                return .{
                    .name = element_name,
                    .attrs = try attrs.toOwnedSlice(self.allocator),
                    .children = &.{},
                };
            }
            if (self.consume(">")) break;

            const attr = try self.attribute();
            if (!ignoredXmlAttr(attr.name)) try attrs.append(self.allocator, attr);
        }

        while (true) {
            self.skipWhitespace();
            if (self.consume("</")) {
                const close_name = try self.name();
                if (!std.mem.eql(u8, element_name, close_name)) return error.InvalidXml;
                self.skipWhitespace();
                try self.expect('>');
                return .{
                    .name = element_name,
                    .attrs = try attrs.toOwnedSlice(self.allocator),
                    .children = try children.toOwnedSlice(self.allocator),
                };
            }
            if (self.eof()) return error.InvalidXml;
            if (self.peek() != '<') return error.InvalidXml;
            try children.append(self.allocator, try self.element());
        }
    }

    fn attribute(self: *XmlParser) !XmlAttr {
        const attr_name = try self.name();
        self.skipWhitespace();
        try self.expect('=');
        self.skipWhitespace();

        const quote = self.peek() orelse return error.InvalidXml;
        if (quote != '"' and quote != '\'') return error.InvalidXml;
        self.pos += 1;

        var value: std.ArrayListUnmanaged(u8) = .empty;
        defer value.deinit(self.allocator);
        while (true) {
            const c = self.peek() orelse return error.InvalidXml;
            self.pos += 1;
            if (c == quote) break;
            if (c == '&') {
                try value.appendSlice(self.allocator, try self.entity());
            } else {
                try value.append(self.allocator, c);
            }
        }

        return .{ .name = attr_name, .value = try value.toOwnedSlice(self.allocator) };
    }

    fn entity(self: *XmlParser) ![]const u8 {
        if (self.consume("amp;")) return "&";
        if (self.consume("lt;")) return "<";
        if (self.consume("gt;")) return ">";
        if (self.consume("quot;")) return "\"";
        if (self.consume("apos;")) return "'";
        return error.InvalidXml;
    }

    fn name(self: *XmlParser) ![]const u8 {
        const start = self.pos;
        while (!self.eof() and isXmlNameChar(self.input[self.pos])) self.pos += 1;
        if (self.pos == start) return error.InvalidXml;
        return try self.allocator.dupe(u8, self.input[start..self.pos]);
    }

    fn skipWhitespace(self: *XmlParser) void {
        while (!self.eof() and std.ascii.isWhitespace(self.input[self.pos])) self.pos += 1;
    }

    fn expect(self: *XmlParser, c: u8) !void {
        if (self.peek() != c) return error.InvalidXml;
        self.pos += 1;
    }

    fn consume(self: *XmlParser, text: []const u8) bool {
        if (!self.startsWith(text)) return false;
        self.pos += text.len;
        return true;
    }

    fn startsWith(self: *const XmlParser, text: []const u8) bool {
        return std.mem.startsWith(u8, self.input[self.pos..], text);
    }

    fn peek(self: *const XmlParser) ?u8 {
        if (self.eof()) return null;
        return self.input[self.pos];
    }

    fn eof(self: *const XmlParser) bool {
        return self.pos >= self.input.len;
    }
};

fn parseXml(allocator: std.mem.Allocator, input: []const u8) !XmlDocument {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    var parser: XmlParser = .{
        .allocator = arena.allocator(),
        .input = input,
    };
    const root = try parser.document();
    return .{
        .arena = arena,
        .root = root,
    };
}

fn xmlNodesEqual(left: XmlNode, right: XmlNode) bool {
    if (!std.mem.eql(u8, left.name, right.name)) return false;
    if (left.attrs.len != right.attrs.len) return false;
    if (left.children.len != right.children.len) return false;

    for (left.attrs) |attr| {
        const other = xmlAttrValue(right.attrs, attr.name) orelse return false;
        if (!std.mem.eql(u8, attr.value, other)) return false;
    }
    for (left.children, right.children) |left_child, right_child| {
        if (!xmlNodesEqual(left_child, right_child)) return false;
    }
    return true;
}

fn xmlAttrValue(attrs: []const XmlAttr, name: []const u8) ?[]const u8 {
    for (attrs) |attr| {
        if (std.mem.eql(u8, attr.name, name)) return attr.value;
    }
    return null;
}

fn ignoredXmlAttr(name: []const u8) bool {
    return std.mem.eql(u8, name, "line") or std.mem.eql(u8, name, "column");
}

fn isXmlNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == ':' or c == '.';
}

test "XML comparison ignores source positions" {
    try std.testing.expect(try equivalentXml(
        std.testing.allocator,
        "<?xml version='1.0' encoding='utf-8'?><expr><attrs><attr line=\"1\" column=\"2\" name=\"a\"><int value=\"1\" /></attr></attrs></expr>",
        "<?xml version='1.0' encoding='utf-8'?><expr><attrs><attr name=\"a\"><int value=\"1\" /></attr></attrs></expr>",
    ));
}

test "XML comparison decodes entities structurally" {
    try std.testing.expect(try equivalentXml(
        std.testing.allocator,
        "<expr><string value=\"a&lt;&amp;&quot;&apos;&gt;\" /></expr>",
        "<expr><string value=\"a&lt;&amp;&quot;&apos;&gt;\" /></expr>",
    ));
    try std.testing.expect(!try equivalentXml(
        std.testing.allocator,
        "<expr><string value=\"a\" /></expr>",
        "<expr><string value=\"b\" /></expr>",
    ));
}

fn shrinkInteresting(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: *const Config,
    expr: []const u8,
    target: Outcome,
) ![]u8 {
    var current = try allocator.dupe(u8, expr);
    errdefer allocator.free(current);

    var changed = true;
    while (changed) {
        changed = false;

        var candidates: ShrinkCandidates = .empty;
        defer {
            for (candidates.items) |candidate| allocator.free(candidate);
            candidates.deinit(allocator);
        }
        try shrinkCandidates(allocator, current, &candidates);

        for (candidates.items) |candidate| {
            if (candidate.len == 0 or candidate.len >= current.len) continue;
            var c = try classify(allocator, io, config, candidate);
            defer c.deinit(allocator);
            if (c.outcome == target) {
                allocator.free(current);
                current = try allocator.dupe(u8, candidate);
                changed = true;
                break;
            }
        }
    }

    return current;
}

fn shrinkCandidates(allocator: std.mem.Allocator, expr: []const u8, out: *ShrinkCandidates) !void {
    const constants = [_][]const u8{ "1", "true", "false", "null", "[]", "{}" };
    for (constants) |constant| try out.append(allocator, try allocator.dupe(u8, constant));

    const trimmed = std.mem.trim(u8, expr, " \t\r\n");
    if (trimmed.len >= 2 and trimmed[0] == '(' and trimmed[trimmed.len - 1] == ')' and balanced(trimmed[1 .. trimmed.len - 1])) {
        try out.append(allocator, try allocator.dupe(u8, trimmed[1 .. trimmed.len - 1]));
    }

    var i: usize = 0;
    while (i < expr.len) : (i += 1) {
        if (expr[i] != '(' and expr[i] != '[' and expr[i] != '{') continue;
        if (matchingClose(expr[i])) |close| {
            if (findMatching(expr, i, close)) |end| {
                try out.append(allocator, try std.mem.concat(allocator, u8, &.{ expr[0..i], "1", expr[end + 1 ..] }));
            }
        }
    }
}

fn matchingClose(open: u8) ?u8 {
    return switch (open) {
        '(' => ')',
        '[' => ']',
        '{' => '}',
        else => null,
    };
}

fn findMatching(expr: []const u8, start: usize, close: u8) ?usize {
    var depth: usize = 0;
    var in_string = false;
    var i = start;
    while (i < expr.len) : (i += 1) {
        const c = expr[i];
        if (in_string) {
            if (c == '\\') {
                i += 1;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        if (c == '"') {
            in_string = true;
        } else if (c == expr[start]) {
            depth += 1;
        } else if (c == close) {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn balanced(expr: []const u8) bool {
    var parens: isize = 0;
    var brackets: isize = 0;
    var braces: isize = 0;
    var in_string = false;

    var i: usize = 0;
    while (i < expr.len) : (i += 1) {
        const c = expr[i];
        if (in_string) {
            if (c == '\\') {
                i += 1;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '(' => parens += 1,
            ')' => parens -= 1,
            '[' => brackets += 1,
            ']' => brackets -= 1,
            '{' => braces += 1,
            '}' => braces -= 1,
            else => {},
        }
        if (parens < 0 or brackets < 0 or braces < 0) return false;
    }
    return !in_string and parens == 0 and brackets == 0 and braces == 0;
}

fn reportInteresting(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: *const Config,
    seed: u64,
    iteration: usize,
    expr: []const u8,
    classification: *const Classification,
    reporter: *Reporter,
) !void {
    if (!config.shrink) {
        try saveAndPrintFailure(allocator, io, config, seed, iteration, expr, classification.*, reporter);
        return;
    }

    const saved_expr = try shrinkInteresting(allocator, io, config, expr, classification.outcome);
    defer allocator.free(saved_expr);

    var saved_classification = try classify(allocator, io, config, saved_expr);
    defer saved_classification.deinit(allocator);

    try saveAndPrintFailure(allocator, io, config, seed, iteration, saved_expr, saved_classification, reporter);
}

fn saveAndPrintFailure(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: *const Config,
    seed: u64,
    iteration: usize,
    expr: []const u8,
    classification: Classification,
    reporter: *Reporter,
) !void {
    try saveFailure(allocator, io, config, seed, iteration, expr, classification);
    reporter.mismatch(classification.outcome, seed, iteration, config.failure_dir, expr);
}

fn saveFailure(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: *const Config,
    seed: u64,
    iteration: usize,
    expr: []const u8,
    classification: Classification,
) !void {
    try std.Io.Dir.cwd().createDirPath(io, config.failure_dir);

    const prefix = try std.fmt.allocPrint(allocator, "{s}/case-{d}-{d}-{s}", .{
        config.failure_dir,
        seed,
        iteration,
        @tagName(classification.outcome),
    });
    defer allocator.free(prefix);

    const expr_path = try std.fmt.allocPrint(allocator, "{s}.nix", .{prefix});
    defer allocator.free(expr_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = expr_path, .data = expr });

    const report = try std.fmt.allocPrint(allocator,
        \\outcome: {s}
        \\seed: {d}
        \\iteration: {d}
        \\
        \\expression:
        \\{s}
        \\
        \\nix ok: {}
        \\nix stdout:
        \\{s}
        \\nix stderr:
        \\{s}
        \\
        \\fix ok: {}
        \\fix stdout:
        \\{s}
        \\fix stderr:
        \\{s}
        \\
    , .{
        @tagName(classification.outcome),
        seed,
        iteration,
        expr,
        classification.nix.ok,
        classification.nix.stdout,
        classification.nix.stderr,
        classification.fix.ok,
        classification.fix.stdout,
        classification.fix.stderr,
    });
    defer allocator.free(report);

    const report_path = try std.fmt.allocPrint(allocator, "{s}.txt", .{prefix});
    defer allocator.free(report_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = report_path, .data = report });
}
