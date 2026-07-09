//! Command-line option parsing for `fix`.

const std = @import("std");
const cli = @import("cli.zig");
const derivation_debug = @import("derivation_debug.zig");
const eval_gc = @import("fix").eval_gc;

pub const usage =
    \\usage: fix eval [options] (-e <expression> | --file <path> | --flake <installable>)
    \\
    \\evaluate a Nix expression, file, or flake output and print the value.
    \\
    \\options:
    \\  -e, --expr EXPR        evaluate expression text
    \\  --file PATH            evaluate a file
    \\  --flake INSTALLABLE    evaluate a flake output: <flakeref>[#<attrpath>]
    \\                         (requires the flakes experimental feature)
    \\  --json                 write the evaluated value as JSON
    \\  --xml                  write the evaluated value as XML
    \\  --strict               recursively force attr values and list items before writing
    \\  --experimental-features FEATS
    \\                         space-separated experimental features to enable,
    \\                         replacing the current set
    \\                         (available: pipe-operators, fetch-tree, flakes)
    \\  --extra-experimental-features FEATS
    \\                         like --experimental-features, but adds to the set
    \\  --debug-derivations[=MODE]
    \\                         write derivation debug records to stderr: summary, full
    \\  --debug-derivation-filter TEXT
    \\                         only show derivations whose name/path/input mentions TEXT
    \\  --debug-derivation-name NAME
    \\                         only show derivations with exactly NAME
    \\  --debug-derivation-drv PATH
    \\                         only show the derivation with exactly PATH
    \\  --max-memory SIZE      memory budget before garbage collection kicks in
    \\                         (MiB, or with a k/m/g suffix; 0 = never collect;
    \\                         default: half of MemAvailable). -Dgc builds only.
    \\  --show-trace           show full evaluation traces
    \\  --color[=when]         color diagnostics: auto, always, never
    \\  --no-color             disable color diagnostics
    \\  --progress[=when]      show evaluation progress on stderr: auto, always, never
    \\  --no-progress          disable evaluation progress
    \\  -h, --help             show this help
    \\
;

pub const OutputFormat = enum {
    nix,
    json,
    xml,
};

/// Nix-style experimental features. Names match Nix's spelling so that the
/// same `--experimental-features pipe-operators` invocation works here.
pub const ExperimentalFeature = enum {
    pipe_operators,
    fetch_tree,
    flakes,

    pub fn fromName(name: []const u8) ?ExperimentalFeature {
        if (std.mem.eql(u8, name, "pipe-operators")) return .pipe_operators;
        if (std.mem.eql(u8, name, "fetch-tree")) return .fetch_tree;
        if (std.mem.eql(u8, name, "flakes")) return .flakes;
        return null;
    }
};

pub const ExperimentalFeatures = std.EnumSet(ExperimentalFeature);

/// Parse a space-separated feature list into `set`, inserting each recognized
/// feature. Unknown names are an error (Nix warns; we reject to keep the CLI's
/// fail-fast behaviour). An empty/whitespace-only list inserts nothing.
fn parseFeatureList(set: *ExperimentalFeatures, list: []const u8) !void {
    var it = std.mem.tokenizeScalar(u8, list, ' ');
    while (it.next()) |name| {
        const feat = ExperimentalFeature.fromName(name) orelse return error.UnknownExperimentalFeature;
        set.insert(feat);
    }
}

pub const EvaluationMode = struct {
    output: OutputFormat = .nix,
    strict: bool = false,
};

pub const SourceArg = union(enum) {
    expr: []const u8,
    file: []const u8,
    /// A flake installable `<flakeref>[#<attrpath>]` from `--flake`. Lowered
    /// to a `builtins.getFlake` expression at source-load time (see
    /// `cli/run.zig`). Requires the `flakes` experimental feature.
    flake: []const u8,
};

pub const Options = struct {
    output: OutputFormat = .nix,
    strict: bool = false,
    experimental_features: ExperimentalFeatures = .{},
    color: cli.When = .auto,
    progress: cli.When = .auto,
    show_trace: bool = false,
    derivation_debug: derivation_debug.Options = .{},
    /// `fix build --no-link`: skip creating the `./result` symlink.
    no_link: bool = false,
    /// `fix shell -p <names>`: package attr-paths in `<nixpkgs>`. Borrowed from
    /// argv; the list backing is owned (caller frees via `packages.deinit`).
    packages: std.ArrayListUnmanaged([]const u8) = .empty,
    source: ?SourceArg = null,
    vm_trace_path: ?[:0]const u8 = null,
    vm_trace_format: enum { text, binary } = .text,
    vm_trace_max_events: u64 = 0,
    vm_trace_main_only: bool = false,
    thunks_log_path: ?[:0]const u8 = null,
    workers: ?u8 = null,
    /// GC (`-Dgc`) memory budget in bytes (`--max-memory`); see
    /// `eval/gc.zig:memoryBudget`. `null` = resolve the default at eval
    /// setup; `0` = never collect.
    max_memory: ?u64 = null,
    /// Speculation (eager background thunk forcing) is ON by default: it is
    /// worth ~20-32% wall at --workers>1 (spec-off→on: 2.62→2.11s with GC,
    /// 2.10→1.43s without), and the RSS it costs is absorbed by the GC without
    /// thrashing (3→9 minor collections, +70ms mark — measured, see
    /// docs/plans/inlining-demand-compilation.md era). `--no-spec-thunks` opts
    /// out (bounds RSS at the cost of that wall); it was the pre-2026-07
    /// default when RSS was over-weighted vs the measured GC cost.
    disable_spec_thunks: bool = false,
    disable_fanout: bool = false,
    print_sched_stats: bool = false,
    timeline_path: ?[]const u8 = null,
    /// `--timeline-flows`: steal-arrow flow-event volume. 0 = off, 1 = all
    /// (default), N>1 = keep 1/N (flows are ~half the trace by event count).
    timeline_flows: u32 = 1,

    fn setSource(self: *Options, source: SourceArg) !void {
        if (self.source != null) return error.TooManySources;
        self.source = source;
    }

    pub fn evaluationMode(self: Options) EvaluationMode {
        return .{
            .output = self.output,
            .strict = self.strict,
        };
    }
};

pub fn parse(allocator: std.mem.Allocator, args_iter: *std.process.Args.Iterator, first: ?[:0]const u8) !Options {
    var options: Options = .{};

    var carried = first;
    parse_loop: while (true) {
        const arg = if (carried) |c| blk: {
            carried = null;
            break :blk c;
        } else (args_iter.next() orelse break);
        if (std.mem.eql(u8, arg, "--json")) {
            options.output = .json;
        } else if (std.mem.eql(u8, arg, "--xml")) {
            options.output = .xml;
        } else if (std.mem.eql(u8, arg, "--strict")) {
            options.strict = true;
        } else if (std.mem.eql(u8, arg, "--experimental-features")) {
            options.experimental_features = .{};
            try parseFeatureList(&options.experimental_features, args_iter.next() orelse return error.MissingExperimentalFeatures);
        } else if (std.mem.startsWith(u8, arg, "--experimental-features=")) {
            options.experimental_features = .{};
            try parseFeatureList(&options.experimental_features, arg["--experimental-features=".len..]);
        } else if (std.mem.eql(u8, arg, "--extra-experimental-features")) {
            try parseFeatureList(&options.experimental_features, args_iter.next() orelse return error.MissingExperimentalFeatures);
        } else if (std.mem.startsWith(u8, arg, "--extra-experimental-features=")) {
            try parseFeatureList(&options.experimental_features, arg["--extra-experimental-features=".len..]);
        } else if (std.mem.eql(u8, arg, "--debug-derivations")) {
            options.derivation_debug.mode = .summary;
        } else if (std.mem.startsWith(u8, arg, "--debug-derivations=")) {
            options.derivation_debug.mode = derivation_debug.parseMode(arg["--debug-derivations=".len..]) orelse return error.InvalidDerivationDebugMode;
        } else if (std.mem.eql(u8, arg, "--debug-derivation-filter")) {
            options.derivation_debug.filter = args_iter.next() orelse return error.MissingDerivationDebugFilter;
        } else if (std.mem.eql(u8, arg, "--debug-derivation-name")) {
            options.derivation_debug.name = args_iter.next() orelse return error.MissingDerivationDebugName;
        } else if (std.mem.eql(u8, arg, "--debug-derivation-drv")) {
            options.derivation_debug.drv_path = args_iter.next() orelse return error.MissingDerivationDebugDrv;
        } else if (std.mem.eql(u8, arg, "--no-link")) {
            options.no_link = true;
        } else if (std.mem.eql(u8, arg, "--show-trace")) {
            options.show_trace = true;
        } else if (std.mem.eql(u8, arg, "--color")) {
            options.color = .always;
        } else if (std.mem.startsWith(u8, arg, "--color=")) {
            options.color = cli.parseWhen(arg["--color=".len..]) orelse return error.InvalidColorMode;
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            options.color = .never;
        } else if (std.mem.eql(u8, arg, "--progress")) {
            options.progress = .always;
        } else if (std.mem.startsWith(u8, arg, "--progress=")) {
            options.progress = cli.parseWhen(arg["--progress=".len..]) orelse return error.InvalidProgressMode;
        } else if (std.mem.eql(u8, arg, "--no-progress")) {
            options.progress = .never;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            return error.Help;
        } else if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--expr")) {
            try options.setSource(.{ .expr = args_iter.next() orelse return error.MissingExpression });
        } else if (std.mem.eql(u8, arg, "--file")) {
            try options.setSource(.{ .file = args_iter.next() orelse return error.MissingPath });
        } else if (std.mem.eql(u8, arg, "--flake")) {
            try options.setSource(.{ .flake = args_iter.next() orelse return error.MissingFlakeInstallable });
        } else if (std.mem.eql(u8, arg, "--vm-trace")) {
            options.vm_trace_path = "-"; // stderr
        } else if (std.mem.startsWith(u8, arg, "--vm-trace=")) {
            options.vm_trace_path = arg["--vm-trace=".len..];
        } else if (std.mem.eql(u8, arg, "--vm-trace-format")) {
            const text = args_iter.next() orelse return error.MissingVmTraceFormat;
            options.vm_trace_format = parseVmTraceFormat(text) orelse return error.InvalidVmTraceFormat;
        } else if (std.mem.startsWith(u8, arg, "--vm-trace-format=")) {
            options.vm_trace_format = parseVmTraceFormat(arg["--vm-trace-format=".len..]) orelse return error.InvalidVmTraceFormat;
        } else if (std.mem.eql(u8, arg, "--vm-trace-max-events")) {
            const text = args_iter.next() orelse return error.MissingVmTraceMaxEvents;
            options.vm_trace_max_events = std.fmt.parseInt(u64, text, 10) catch return error.InvalidVmTraceMaxEvents;
        } else if (std.mem.startsWith(u8, arg, "--vm-trace-max-events=")) {
            const text = arg["--vm-trace-max-events=".len..];
            options.vm_trace_max_events = std.fmt.parseInt(u64, text, 10) catch return error.InvalidVmTraceMaxEvents;
        } else if (std.mem.eql(u8, arg, "--vm-trace-main-only")) {
            options.vm_trace_main_only = true;
        } else if (std.mem.eql(u8, arg, "--max-memory")) {
            const text = args_iter.next() orelse return error.MissingMaxMemory;
            options.max_memory = eval_gc.parseMemorySize(text) orelse return error.InvalidMaxMemory;
        } else if (std.mem.startsWith(u8, arg, "--max-memory=")) {
            options.max_memory = eval_gc.parseMemorySize(arg["--max-memory=".len..]) orelse return error.InvalidMaxMemory;
        } else if (std.mem.eql(u8, arg, "--workers")) {
            const text = args_iter.next() orelse return error.MissingWorkers;
            options.workers = std.fmt.parseInt(u8, text, 10) catch return error.InvalidWorkers;
        } else if (std.mem.startsWith(u8, arg, "--workers=")) {
            options.workers = std.fmt.parseInt(u8, arg["--workers=".len..], 10) catch return error.InvalidWorkers;
        } else if (std.mem.startsWith(u8, arg, "--thunks-log=")) {
            options.thunks_log_path = arg["--thunks-log=".len..];
        } else if (std.mem.eql(u8, arg, "--speculate")) {
            options.disable_spec_thunks = false;
        } else if (std.mem.eql(u8, arg, "--no-spec-thunks")) {
            options.disable_spec_thunks = true; // now the default; kept for A/B
        } else if (std.mem.eql(u8, arg, "--no-fanout")) {
            options.disable_fanout = true;
        } else if (std.mem.eql(u8, arg, "--print-sched-stats")) {
            options.print_sched_stats = true;
        } else if (std.mem.eql(u8, arg, "--timeline")) {
            options.timeline_path = "fix-timeline.json";
        } else if (std.mem.startsWith(u8, arg, "--timeline=")) {
            options.timeline_path = arg["--timeline=".len..];
        } else if (std.mem.startsWith(u8, arg, "--timeline-flows=")) {
            const v = arg["--timeline-flows=".len..];
            options.timeline_flows = if (std.mem.eql(u8, v, "off")) 0 else if (std.mem.eql(u8, v, "all")) 1 else (std.fmt.parseInt(u32, v, 10) catch return error.UnknownOption);
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--packages")) {
            // Greedy: every following token is a package name (an attr path in
            // `<nixpkgs>`) until `--` or end. `fix shell -p ripgrep jq`.
            while (args_iter.next()) |name| {
                if (std.mem.eql(u8, name, "--")) break :parse_loop;
                try options.packages.append(allocator, name);
            }
            break :parse_loop;
        } else if (std.mem.eql(u8, arg, "--")) {
            // End of options: leave the rest in the iterator (e.g. `fix run`
            // forwards them as program arguments).
            break;
        } else {
            return error.UnknownOption;
        }
    }

    return options;
}

fn parseVmTraceFormat(text: []const u8) ?@TypeOf(@as(Options, undefined).vm_trace_format) {
    if (std.mem.eql(u8, text, "binary")) return .binary;
    if (std.mem.eql(u8, text, "text")) return .text;
    return null;
}

pub fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.MissingExpression => "missing expression after -e or --expr",
        error.MissingPath => "missing path after --file",
        error.MissingFlakeInstallable => "missing installable after --flake",
        error.FlakesFeatureRequired => "--flake requires the flakes experimental feature; pass --extra-experimental-features flakes",
        error.MissingDerivationDebugFilter => "missing text after --debug-derivation-filter",
        error.MissingDerivationDebugName => "missing name after --debug-derivation-name",
        error.MissingDerivationDebugDrv => "missing path after --debug-derivation-drv",
        error.TooManySources => "provide only one expression or file",
        error.InvalidColorMode => "expected --color to be auto, always, or never",
        error.InvalidProgressMode => "expected --progress to be auto, always, or never",
        error.InvalidDerivationDebugMode => "expected --debug-derivations to be summary or full",
        error.MissingVmTraceFormat => "missing format after --vm-trace-format",
        error.InvalidVmTraceFormat => "expected --vm-trace-format to be text or binary",
        error.MissingVmTraceMaxEvents => "missing count after --vm-trace-max-events",
        error.InvalidVmTraceMaxEvents => "expected --vm-trace-max-events to be a non-negative integer",
        error.MissingExperimentalFeatures => "missing feature list after --experimental-features or --extra-experimental-features",
        error.UnknownExperimentalFeature => "unknown experimental feature (available: pipe-operators, fetch-tree, flakes)",
        error.MissingWorkers => "missing N after --workers",
        error.InvalidWorkers => "expected --workers to be a non-negative integer",
        error.MissingMaxMemory => "missing size after --max-memory",
        error.InvalidMaxMemory => "expected --max-memory to be a size like 4096, 512m, or 4g",
        error.UnknownOption => "unknown option",
        else => @errorName(err),
    };
}
