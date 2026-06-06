//! Integration diff fuzz harness.
//!
//! Generates random nix expressions and runs both nix-instantiate and `fix`
//! against them, classifying mismatches and saving reproducers.

const std = @import("std");
const cli = @import("fix-cli");
const harness = @import("harness");
const generator = @import("integration_diff/generator.zig");
const reporter_mod = @import("integration_diff/reporter.zig");
const xml = @import("integration_diff/xml.zig");
const queue = @import("integration_diff/queue.zig");
const failure_writer = @import("integration_diff/failure_writer.zig");

const CommandResult = harness.CommandResult;
const CaseSpace = generator.CaseSpace;
const FragmentCorpus = generator.FragmentCorpus;
const GeneratedCase = generator.GeneratedCase;
const Reporter = reporter_mod.Reporter;
const WorkStats = reporter_mod.WorkStats;
const optionValue = harness.optionValue;
const runCommand = harness.runCommand;
const JobResult = queue.JobResult;
const ResultQueue = queue.ResultQueue;

pub const Config = struct {
    seed: ?u64 = null,
    corpus_dir: []const u8 = "test/fuzz-corpus",
    failure_dir: []const u8 = "",
    fix_bin: []const u8 = "zig-out/bin/fix",
    nix_bin: []const u8 = "nix-instantiate",
    min_depth: u8 = 0,
    max_depth: u8 = 4,
    case_count: usize = default_case_count,
    jobs: usize = 0,
    command_timeout_seconds: u32 = 60,
    shrink: bool = false,
    dump_cases_path: ?[]const u8 = null,
    dump_skipped_path: ?[]const u8 = null,
};

const default_case_count = 64_000;
const result_queue_per_worker = 8;
const result_queue_min = 128;

pub const Outcome = enum {
    skipped,
    both_ok_same,
    both_ok_different,
    nix_accepts_fix_rejects,
    fix_accepts_nix_rejects,
    both_reject,
};

pub const Classification = struct {
    outcome: Outcome,
    nix: CommandResult,
    fix: CommandResult,

    pub fn deinit(self: Classification, allocator: std.mem.Allocator) void {
        self.nix.deinit(allocator);
        self.fix.deinit(allocator);
    }

    fn interesting(self: Classification) bool {
        return switch (self.outcome) {
            .skipped, .both_ok_same, .both_reject => false,
            .both_ok_different, .nix_accepts_fix_rejects, .fix_accepts_nix_rejects => true,
        };
    }

    fn timedOut(self: Classification) bool {
        return self.nix.timed_out or self.fix.timed_out;
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
    generator.loadCorpus(allocator, init.io, config.corpus_dir, &corpus) catch |err| {
        early_reporter.corpusError("failed to load corpus {s}: {s}", .{ config.corpus_dir, @errorName(err) });
        std.process.exit(1);
    };
    if (corpus.items.len == 0) {
        early_reporter.corpusError("corpus {s} did not contain any expressions", .{config.corpus_dir});
        std.process.exit(1);
    }
    generator.sortCorpus(corpus.items);

    if (config.min_depth > config.max_depth) {
        early_reporter.corpusError("--min-depth must be less than or equal to --max-depth", .{});
        std.process.exit(1);
    }
    if (config.command_timeout_seconds == 0) {
        early_reporter.corpusError("--command-timeout-seconds must be greater than zero", .{});
        std.process.exit(1);
    }

    const case_space: CaseSpace = .{
        .corpus = corpus.items,
        .seed = seed,
        .min_depth = config.min_depth,
        .max_depth = config.max_depth,
        .total = config.case_count,
    };
    const total_jobs = case_space.total;
    var reporter = Reporter.init(init.io, init.environ_map);
    reporter.printRepro(config, seed, worker_count, total_jobs);

    if (total_jobs == 0) {
        reporter.finish(total_jobs);
        return;
    }

    if (config.dump_cases_path != null or config.dump_skipped_path != null) {
        try generator.dumpGeneratedCases(allocator, init.io, &config, case_space, &reporter);
        reporter.finish(total_jobs);
        return;
    }

    try runHarness(allocator, init.io, &config, case_space, worker_count, total_jobs, &reporter);
}

const WorkerContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: *const Config,
    case_space: CaseSpace,
    total_jobs: usize,
    results: *ResultQueue,
    stats: *WorkStats,
};

fn runHarness(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: *const Config,
    case_space: CaseSpace,
    worker_count: usize,
    total_jobs: usize,
    reporter: *Reporter,
) !void {
    const result_queue_len = queue.queueCapacity(worker_count, total_jobs, result_queue_per_worker, result_queue_min);

    const result_storage = try allocator.alloc(JobResult, result_queue_len);
    defer allocator.free(result_storage);
    var result_queue = ResultQueue.init(result_storage);

    var work_stats = WorkStats.init(worker_count);
    reporter.work_stats = &work_stats;

    var worker_context: WorkerContext = .{
        .allocator = allocator,
        .io = io,
        .config = config,
        .case_space = case_space,
        .total_jobs = total_jobs,
        .results = &result_queue,
        .stats = &work_stats,
    };
    const workers = try allocator.alloc(std.Thread, worker_count);
    defer allocator.free(workers);
    for (workers) |*worker| {
        worker.* = try std.Thread.spawn(.{}, workerMain, .{&worker_context});
    }

    var received: usize = 0;
    var found_mismatch = false;
    var command_error: ?anyerror = null;

    while (received < total_jobs) : (received += 1) {
        const result = (try result_queue.get(io)) orelse return error.ResultQueueClosed;
        var mutable_result = result;
        defer mutable_result.deinit(allocator);

        if (mutable_result.skipped) {
            reporter.skipped();
        } else if (mutable_result.err) |err| {
            command_error = err;
            reporter.commandError(mutable_result.seed, mutable_result.iteration, err, mutable_result.expr);
        } else if (mutable_result.classification) |*classification| {
            if (classification.outcome == .skipped) {
                reporter.skipped();
                if (classification.timedOut()) reporter.timedOut();
            } else {
                reporter.checked();
            }
            if (classification.interesting()) {
                found_mismatch = true;
                failure_writer.reportInteresting(
                    allocator,
                    io,
                    classify,
                    config,
                    mutable_result.seed,
                    mutable_result.iteration,
                    mutable_result.expr,
                    classification,
                    reporter,
                ) catch |err| {
                    command_error = err;
                    reporter.saveError(mutable_result.seed, mutable_result.iteration, err);
                };
            }
        }

        reporter.progress(received + 1, total_jobs);
    }

    for (workers) |worker| worker.join();

    if (command_error) |err| return err;
    reporter.finish(total_jobs);
    if (found_mismatch) std.process.exit(1);
}

fn workerMain(context: *WorkerContext) void {
    while (context.stats.claim(context.total_jobs)) |index| {
        const generated = generator.generateWorkerCase(context.allocator, context.case_space, index) catch |err| {
            std.debug.panic("integration-diff case generation failed: {s}", .{@errorName(err)});
        };

        var result: JobResult = .{
            .index = index,
            .seed = context.case_space.seed,
            .iteration = index,
            .expr = generated.expr,
            .skipped = generated.skipped,
        };
        if (generated.skipped) {
            context.results.put(context.io, result) catch |err| {
                std.debug.panic("integration-diff result queue failed: {s}", .{@errorName(err)});
            };
            continue;
        }

        result.classification = classify(context.allocator, context.io, context.config, result.expr) catch |err| {
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
        } else if (try optionValue(&args, arg, "--cases")) |value| {
            config.case_count = try std.fmt.parseInt(usize, value, 10);
        } else if (try optionValue(&args, arg, "--jobs")) |value| {
            config.jobs = try std.fmt.parseInt(usize, value, 10);
        } else if (try optionValue(&args, arg, "--command-timeout-seconds")) |value| {
            config.command_timeout_seconds = try std.fmt.parseInt(u32, value, 10);
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
        \\  --min-depth N       minimum recursive composition depth (default: 0)
        \\  --max-depth N       maximum recursive composition depth (default: 4)
        \\  --cases N           generated fuzz cases to run (default: 64000)
        \\  --jobs N            parallel evaluator jobs; 0 means CPU count
        \\  --command-timeout-seconds N
        \\                      max seconds for one evaluator command (default: 60)
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

fn randomSeed(io: std.Io) u64 {
    var bytes: [8]u8 = undefined;
    io.random(&bytes);
    return @bitCast(bytes);
}

fn classify(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: *const Config,
    expr: []const u8,
) !Classification {
    const nix_expr = try std.mem.concat(allocator, u8, &.{ "(", expr, ")" });
    defer allocator.free(nix_expr);

    const nix = try runCommand(allocator, io, config.command_timeout_seconds, &.{ config.nix_bin, "--eval", "--xml", "--expr", nix_expr });
    errdefer nix.deinit(allocator);

    const fix = try runCommand(allocator, io, config.command_timeout_seconds, &.{ config.fix_bin, "--xml", "--expr", expr });
    errdefer fix.deinit(allocator);

    const outcome: Outcome = if (!nix.comparable or !fix.comparable)
        .skipped
    else if (nix.ok and fix.ok)
        if (try xml.equivalentXml(allocator, nix.stdout, fix.stdout)) .both_ok_same else .both_ok_different
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

test {
    _ = generator;
    _ = xml;
}
