const std = @import("std");
const cli = @import("fix-cli");

const interactive_progress_interval_ns = 250 * std.time.ns_per_ms;
const log_progress_interval_ns = 5 * std.time.ns_per_s;
const progress_bar_width = 28;
const progress_dashboard_lines = 3;

pub const WorkSnapshot = struct {
    worker_count: usize,
    claimed: usize,
    in_flight: usize,
    remaining: usize,
};

pub const WorkStats = struct {
    worker_count: usize,
    next_index: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    pub fn init(worker_count: usize) WorkStats {
        return .{
            .worker_count = worker_count,
        };
    }

    pub fn claim(self: *WorkStats, total: usize) ?usize {
        const index = self.next_index.fetchAdd(1, .monotonic);
        return if (index < total) index else null;
    }

    fn snapshot(self: *const WorkStats, completed: usize, total: usize) WorkSnapshot {
        const claimed = @min(self.next_index.load(.monotonic), total);
        return .{
            .worker_count = self.worker_count,
            .claimed = claimed,
            .in_flight = cli.saturatedSub(claimed, completed),
            .remaining = cli.saturatedSub(total, claimed),
        };
    }
};

pub const Reporter = struct {
    io: std.Io,
    interactive: bool,
    use_color: bool,
    work_stats: ?*const WorkStats = null,
    started_ns: i96,
    next_progress_ns: i96,
    drew_progress: bool = false,
    found_count: usize = 0,
    checked_count: usize = 0,
    skipped_count: usize = 0,
    timeout_count: usize = 0,

    pub fn init(io: std.Io, env: *const std.process.Environ.Map) Reporter {
        const now = nowNs(io);
        const interactive = cli.stderrInteractive(io, env);
        return .{
            .io = io,
            .interactive = interactive,
            .use_color = cli.autoColor(interactive, env),
            .started_ns = now,
            .next_progress_ns = now + progressInterval(interactive),
        };
    }

    pub fn printRepro(self: Reporter, config: anytype, seed: u64, worker_count: usize, total_jobs: usize) void {
        const dim = cli.styleCode(self.use_color, .dim);
        const reset = cli.resetCode(self.use_color);
        std.debug.print(
            "{s}integration-diff:{s} zig build integration-test -- --seed={} --jobs={} --min-depth={} --max-depth={} --cases={} --corpus={s} --failures={s} --fix-bin={s} --nix-bin={s}",
            .{
                dim,
                reset,
                seed,
                worker_count,
                config.min_depth,
                config.max_depth,
                config.case_count,
                config.corpus_dir,
                config.failure_dir,
                config.fix_bin,
                config.nix_bin,
            },
        );
        if (config.shrink) std.debug.print(" --shrink", .{});
        std.debug.print(" --command-timeout-seconds={}", .{config.command_timeout_seconds});
        if (config.dump_cases_path) |path| std.debug.print(" --dump-cases={s}", .{path});
        if (config.dump_skipped_path) |path| std.debug.print(" --dump-skipped={s}", .{path});
        std.debug.print(" # cases={}\n", .{total_jobs});
    }

    pub fn progress(self: *Reporter, completed: usize, total: usize) void {
        if (total == 0 or completed >= total) return;
        const now = nowNs(self.io);
        if (now < self.next_progress_ns) return;
        self.printProgress(now, completed, total);
        const interval = progressInterval(self.interactive);
        while (self.next_progress_ns <= now) self.next_progress_ns += interval;
    }

    fn printProgress(self: *Reporter, now: i96, completed: usize, total: usize) void {
        const elapsed_ns = @max(now - self.started_ns, 1);
        const elapsed_s = @as(u64, @intCast(@max(@divTrunc(elapsed_ns, std.time.ns_per_s), 0)));
        const rate = casesPerSecond(completed, elapsed_ns);
        const eta_s = etaSeconds(total - completed, rate);
        const percent_x10 = cli.percentTenths(completed, total);
        const skip_permille = cli.permille(self.skipped_count, completed);
        const work_snapshot = if (self.work_stats) |stats| stats.snapshot(completed, total) else null;
        const spinner = cli.spinnerFrame(elapsed_ns);

        if (self.interactive) {
            self.printDashboard(spinner, completed, total, percent_x10, skip_permille, rate, eta_s, elapsed_s, work_snapshot);
        } else {
            self.printLogProgress(spinner, completed, total, percent_x10, skip_permille, rate, eta_s, elapsed_s, work_snapshot);
        }
        self.drew_progress = true;
    }

    fn printDashboard(
        self: *Reporter,
        spinner: u8,
        completed: usize,
        total: usize,
        percent_x10: usize,
        skip_permille: usize,
        rate: u64,
        eta_s: u64,
        elapsed_s: u64,
        work_snapshot: ?WorkSnapshot,
    ) void {
        if (self.drew_progress) std.debug.print("\x1b[{}F", .{progress_dashboard_lines});

        const reset = cli.resetCode(self.use_color);
        const dim = cli.styleCode(self.use_color, .dim);
        const status_color = cli.styleCode(self.use_color, if (self.found_count == 0) .success else .error_label);
        const status = if (self.found_count == 0) "RUN" else "FAIL";

        std.debug.print("\x1b[2K{s}integration-diff{s} {s}{s}{s} {c} ", .{ dim, reset, status_color, status, reset, spinner });
        self.printProgressBar(completed, total);
        std.debug.print(" {}.{}%  {}/{}\n", .{ percent_x10 / 10, percent_x10 % 10, completed, total });

        std.debug.print("\x1b[2K  rate {}/s  eta ", .{rate});
        cli.printDuration(eta_s);
        std.debug.print("  elapsed ", .{});
        cli.printDuration(elapsed_s);
        std.debug.print("  skipped {}.{}% ({})  timed out {}  found {}\n", .{ skip_permille / 10, skip_permille % 10, self.skipped_count, self.timeout_count, self.found_count });

        std.debug.print("\x1b[2K  work ", .{});
        if (work_snapshot) |snapshot| {
            self.printWork(snapshot);
        } else {
            std.debug.print("{s}n/a{s}", .{ dim, reset });
        }
        std.debug.print("\n", .{});
    }

    fn printLogProgress(
        self: *Reporter,
        spinner: u8,
        completed: usize,
        total: usize,
        percent_x10: usize,
        skip_permille: usize,
        rate: u64,
        eta_s: u64,
        elapsed_s: u64,
        work_snapshot: ?WorkSnapshot,
    ) void {
        std.debug.print(
            "integration-diff: {c} {}.{}% {}/{} rate {}/s eta ",
            .{ spinner, percent_x10 / 10, percent_x10 % 10, completed, total, rate },
        );
        cli.printDuration(eta_s);
        std.debug.print(" elapsed ", .{});
        cli.printDuration(elapsed_s);
        std.debug.print(" skipped {}.{}% ({}) timeout {} found {}", .{ skip_permille / 10, skip_permille % 10, self.skipped_count, self.timeout_count, self.found_count });
        if (work_snapshot) |snapshot| {
            std.debug.print(" work ", .{});
            printWorkText(snapshot, self.use_color);
        }
        std.debug.print("\n", .{});
    }

    fn printProgressBar(self: Reporter, completed: usize, total: usize) void {
        cli.printProgressBar(self.use_color, completed, total, progress_bar_width, if (self.found_count == 0) .success else .error_label);
    }

    fn printWork(self: Reporter, snapshot: WorkSnapshot) void {
        printWorkText(snapshot, self.use_color);
    }

    pub fn checked(self: *Reporter) void {
        self.checked_count += 1;
    }

    pub fn skipped(self: *Reporter) void {
        self.skipped_count += 1;
    }

    pub fn timedOut(self: *Reporter) void {
        self.timeout_count += 1;
    }

    pub fn clearProgress(self: *Reporter) void {
        if (self.interactive and self.drew_progress) {
            std.debug.print("\x1b[{}F\x1b[J", .{progress_dashboard_lines});
            self.drew_progress = false;
        }
    }

    pub fn commandError(self: *Reporter, seed: u64, iteration: usize, err: anyerror, expr: []const u8) void {
        self.clearProgress();
        const red = cli.styleCode(self.use_color, .error_label);
        const reset = cli.resetCode(self.use_color);
        std.debug.print(
            "{s}integration-diff: command failed{s} at seed {} iteration {}: {s}\n",
            .{ red, reset, seed, iteration, @errorName(err) },
        );
        std.debug.print("expression:\n{s}\n", .{expr});
    }

    pub fn saveError(self: *Reporter, seed: u64, iteration: usize, err: anyerror) void {
        self.clearProgress();
        const red = cli.styleCode(self.use_color, .error_label);
        const reset = cli.resetCode(self.use_color);
        std.debug.print(
            "{s}integration-diff: failed to save mismatch{s} at seed {} iteration {}: {s}\n",
            .{ red, reset, seed, iteration, @errorName(err) },
        );
    }

    pub fn mismatch(self: *Reporter, outcome: anytype, seed: u64, iteration: usize, failure_dir: []const u8, expr: []const u8) void {
        self.clearProgress();
        self.found_count += 1;
        const red = cli.styleCode(self.use_color, .error_label);
        const reset = cli.resetCode(self.use_color);
        std.debug.print(
            "{s}integration-diff: found {s}{s} at seed {} iteration {}; saved under {s}\n",
            .{ red, @tagName(outcome), reset, seed, iteration, failure_dir },
        );
        std.debug.print("expression:\n{s}\n", .{expr});
    }

    pub fn finish(self: *Reporter, total: usize) void {
        self.clearProgress();
        const color = cli.styleCode(self.use_color, if (self.found_count == 0) .success else .error_label);
        const reset = cli.resetCode(self.use_color);
        std.debug.print(
            "{s}integration-diff: found={} checked={} skipped={} timed_out={} cases={}{s}\n",
            .{ color, self.found_count, self.checked_count, self.skipped_count, self.timeout_count, total, reset },
        );
    }

    pub fn corpusError(self: Reporter, comptime fmt: []const u8, args: anytype) void {
        const red = cli.styleCode(self.use_color, .error_label);
        const reset = cli.resetCode(self.use_color);
        std.debug.print("{s}integration-diff: ", .{red});
        std.debug.print(fmt, args);
        std.debug.print("{s}\n", .{reset});
    }
};

pub fn nowNs(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).toNanoseconds();
}

fn progressInterval(interactive: bool) i96 {
    return if (interactive) interactive_progress_interval_ns else log_progress_interval_ns;
}

fn casesPerSecond(completed: usize, elapsed_ns: i96) u64 {
    const elapsed = @as(u128, @intCast(@max(elapsed_ns, 1)));
    return @intCast((@as(u128, completed) * std.time.ns_per_s) / elapsed);
}

fn etaSeconds(remaining: usize, rate: u64) u64 {
    if (rate == 0) return 0;
    return @intCast((remaining + rate - 1) / rate);
}

fn printWorkText(snapshot: WorkSnapshot, use_color: bool) void {
    const workers_busy = snapshot.in_flight >= snapshot.worker_count;
    const state: enum { saturated, active, starved, draining, done } =
        if (snapshot.remaining == 0 and snapshot.in_flight == 0)
            .done
        else if (snapshot.remaining == 0)
            .draining
        else if (workers_busy)
            .saturated
        else if (snapshot.in_flight != 0)
            .active
        else
            .starved;

    const color = cli.styleCode(use_color, switch (state) {
        .saturated => .success,
        .active => .warning,
        .starved => .error_label,
        .draining => .warning,
        .done => .success,
    });
    const reset = cli.resetCode(use_color);

    std.debug.print("{s}{s}{s} workers {}/{} claimed {} remaining {}", .{
        color,
        @tagName(state),
        reset,
        snapshot.in_flight,
        snapshot.worker_count,
        snapshot.claimed,
        snapshot.remaining,
    });
}
