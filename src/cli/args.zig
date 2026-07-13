//! Command-line option parsing for `fix`, driven by a single option table
//! (`specs`). The table is the source of truth for names, value arity, and help
//! text, so `parse` matches generically, `--help` renders from it, and shell
//! completions can be generated from it. Adding an option means adding a `Spec`
//! entry plus one `apply` arm.

const std = @import("std");
const cli = @import("cli.zig");
const derivation_debug = @import("derivation_debug.zig");
const eval_gc = @import("fix").eval_gc;
const hugetlb = @import("base").hugetlb;

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
    coerce_integers,

    pub fn fromName(name: []const u8) ?ExperimentalFeature {
        if (std.mem.eql(u8, name, "pipe-operators")) return .pipe_operators;
        if (std.mem.eql(u8, name, "fetch-tree")) return .fetch_tree;
        if (std.mem.eql(u8, name, "flakes")) return .flakes;
        if (std.mem.eql(u8, name, "coerce-integers")) return .coerce_integers;
        return null;
    }
};

pub const ExperimentalFeatures = std.EnumSet(ExperimentalFeature);

/// Nix-style deprecated features (Lix `--extra-deprecated-features`). Enabling
/// one re-permits behaviour that fix rejects by default. Names match Lix.
pub const DeprecatedFeature = enum {
    nul_bytes,
    floor_ceil_corrupt_integers,
    // Accepted for compatibility but not gated — fix is already lenient here,
    // so enabling them is a no-op (the corresponding syntax/behaviour always
    // works). Kept so `--extra-deprecated-features <name>` doesn't error.
    floating_without_zero,
    cr_line_endings,
    or_as_identifier,
    rec_set_merges,

    pub fn fromName(name: []const u8) ?DeprecatedFeature {
        if (std.mem.eql(u8, name, "nul-bytes")) return .nul_bytes;
        if (std.mem.eql(u8, name, "floor-ceil-corrupt-integers")) return .floor_ceil_corrupt_integers;
        if (std.mem.eql(u8, name, "floating-without-zero")) return .floating_without_zero;
        if (std.mem.eql(u8, name, "cr-line-endings")) return .cr_line_endings;
        if (std.mem.eql(u8, name, "or-as-identifier")) return .or_as_identifier;
        if (std.mem.eql(u8, name, "rec-set-merges")) return .rec_set_merges;
        return null;
    }
};

pub const DeprecatedFeatures = std.EnumSet(DeprecatedFeature);

fn parseDeprecatedList(set: *DeprecatedFeatures, list: []const u8) !void {
    var it = std.mem.tokenizeScalar(u8, list, ' ');
    while (it.next()) |name| {
        // Unknown names are accepted as no-ops: many Lix deprecated features
        // (rec-set-overrides, ancient-let, rec-set-dynamic-attrs, …) name
        // behaviour fix implements unconditionally, so enabling them changes
        // nothing. Only the gated ones (nul-bytes, floor-ceil-corrupt-integers)
        // matter.
        if (DeprecatedFeature.fromName(name)) |feat| set.insert(feat);
    }
}

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

/// Like `parseFeatureList`, but for features sourced from `nix.conf` rather than
/// argv: unknown names are silently skipped (Nix only warns for config-sourced
/// `experimental-features`, and rejecting would make an unrelated Nix setting
/// break `fix`). Never fails.
pub fn mergeConfigFeatures(set: *ExperimentalFeatures, list: []const u8) void {
    var it = std.mem.tokenizeScalar(u8, list, ' ');
    while (it.next()) |name| {
        if (ExperimentalFeature.fromName(name)) |feat| set.insert(feat);
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

/// A `--arg NAME EXPR` / `--argstr NAME STR` top-level function argument. When
/// the source evaluates to a function, it is auto-called with these (as in
/// `nix-instantiate`). `value` is a Nix expression when `is_string` is false,
/// or a literal string when true. Both fields are borrowed from argv.
pub const ArgDef = struct {
    name: []const u8,
    value: []const u8,
    is_string: bool,
};

/// A `--option NAME VALUE` override for a `nix.conf` setting. Applied over the
/// loaded config at highest precedence (see `setup.configure`). Borrowed from
/// argv.
pub const OptionOverride = struct {
    name: []const u8,
    value: []const u8,
};

/// Which subcommand is asking (used only to scope `--help` output; every
/// subcommand shares this one parser and accepts the whole option set).
pub const Cmd = enum { eval, parse, instantiate, build, run, shell, repl, disasm, @"switch" };

/// `fix switch` target: which activation flavour to build and switch to. Chosen
/// by `--nixos`/`--darwin`/`--home-manager`, else auto-detected in `switch.zig`.
pub const SwitchTarget = enum { nixos, darwin, home_manager };

pub const Options = struct {
    output: OutputFormat = .nix,
    strict: bool = false,
    /// `--no-location`: omit source positions from `--xml` output. fix's XML
    /// serializer never emits positions, so this is accepted for CLI/tooling
    /// compatibility (Nix's `nix-instantiate --eval --xml --no-location`) and
    /// is effectively a no-op — the output already matches Nix's no-location form.
    no_location: bool = false,
    experimental_features: ExperimentalFeatures = .{},
    /// True once `--experimental-features` (the replace form) has been seen on
    /// the CLI. It overrides the `nix.conf` base entirely; without it the config
    /// value is the base and `--extra-experimental-features` appends to it (Nix
    /// precedence). See `setup.configure`.
    experimental_features_reset: bool = false,
    /// Deprecated features enabled via `--extra-deprecated-features` /
    /// `--deprecated-features` (Lix compat).
    deprecated_features: DeprecatedFeatures = .{},
    deprecated_features_reset: bool = false,
    /// `--option NAME VALUE`: nix.conf setting overrides, in argv order.
    /// Borrowed from argv; the list backing is owned (caller frees via `deinit`).
    option_overrides: std.ArrayListUnmanaged(OptionOverride) = .empty,
    color: cli.When = .auto,
    progress: cli.When = .auto,
    /// `fix repl --bare`: plain line-based input (no raw mode, no escape
    /// sequences), regardless of whether stdin/stdout are a terminal. The
    /// non-tty repl path is always bare; this forces it for automation.
    bare: bool = false,
    show_trace: bool = false,
    /// Drop into the interactive debug console at `builtins.break` (and, later,
    /// on evaluation errors). Forces single-worker, speculation-free evaluation
    /// so the pause point is deterministic.
    debugger: bool = false,
    derivation_debug: derivation_debug.Options = .{},
    /// `fix build --no-link`/`--no-out-link`: skip creating the result symlink.
    no_link: bool = false,
    /// `--out-link NAME`/`-o`: name of the result symlink (default `result`).
    out_link: ?[]const u8 = null,
    /// `--drv-link NAME`: name of the derivation symlink (default `derivation`).
    drv_link: ?[]const u8 = null,
    /// `--add-drv-link`: also create a symlink to the top-level `.drv`.
    add_drv_link: bool = false,
    /// `--add-root PATH`: create the output/`.drv` link at PATH and register it
    /// as an (indirect) GC root. Borrowed from argv.
    add_root: ?[]const u8 = null,
    /// `--indirect`: make the `--add-root` root indirect (accepted; roots here
    /// are always registered indirectly).
    indirect: bool = false,
    /// `--check`: rebuild and verify outputs are unchanged (BuildMode check).
    check: bool = false,
    /// `--repair`: rebuild and repair corrupted store paths (BuildMode repair).
    repair: bool = false,
    /// `--verbose`/`-v` repeat count → daemon build-log verbosity.
    verbose: u8 = 0,
    /// `fix switch --nixos|--darwin|--home-manager`: the activation target.
    /// `null` = auto-detect (see `switch.zig:resolveTarget`).
    switch_target: ?SwitchTarget = null,
    /// `fix switch --activate-toplevel PATH` (hidden, internal): when set, the
    /// eval+build phase is skipped and the given store path is activated. This
    /// is how the non-root run re-execs its privileged half under `sudo`.
    activate_toplevel: ?[]const u8 = null,
    /// `fix switch --target-host [user@]host`: build locally, copy the closure
    /// (`nix-copy-closure`), and activate on that remote host over SSH. Borrowed
    /// from argv.
    target_host: ?[]const u8 = null,
    /// `fix switch --use-remote-sudo`: prefix the remote profile-set/activation
    /// commands with `sudo` (when the SSH user is not root).
    use_remote_sudo: bool = false,
    /// `fix shell -p <names>`: package attr-paths in `<nixpkgs>`. Borrowed from
    /// argv; the list backing is owned (caller frees via `deinit`).
    packages: std.ArrayListUnmanaged([]const u8) = .empty,
    /// `-I`/`--include` search-path entries (`[prefix=]path`), in argv order.
    /// Prepended to `$NIX_PATH` at setup (they take precedence, as in Nix).
    /// Borrowed from argv; the list backing is owned (caller frees via `deinit`).
    include: std.ArrayListUnmanaged([]const u8) = .empty,
    /// `--flake`: interpret the (positional or default) source as a flake
    /// installable rather than a file. See `defaultSource`.
    flake_mode: bool = false,
    /// `-A`/`--attr`: dotted attribute path to select from the evaluated value
    /// (as in `nix-build -A`). Borrowed from argv.
    attr: ?[]const u8 = null,
    /// `--arg`/`--argstr` top-level function arguments, in argv order. Borrowed
    /// from argv; the list backing is owned (caller frees via `deinit`).
    arg_defs: std.ArrayListUnmanaged(ArgDef) = .empty,
    /// `fix disasm --chunk N`: disassemble only chunk #N (else all reachable).
    disasm_chunk: ?u32 = null,
    /// `fix disasm --no-recurse`: only show the top chunk.
    disasm_no_recurse: bool = false,
    /// `fix disasm --no-source`: omit source-span annotations.
    disasm_no_source: bool = false,
    /// `fix disasm --no-constants`: omit the constant-pool listing.
    disasm_no_constants: bool = false,
    /// `fix disasm --no-bytes`: omit the raw-bytecode hex column.
    disasm_no_bytes: bool = false,
    /// `fix disasm --no-pager`: never pipe output to `$PAGER`.
    disasm_no_pager: bool = false,
    /// `fix disasm --eval`: evaluate first, then disassemble every chunk that
    /// compiled (follows imports and lazy attr bodies), instead of statically
    /// compiling the top expression only.
    disasm_eval: bool = false,
    /// `fix disasm --stats`: print corpus statistics instead of a listing.
    disasm_stats: bool = false,
    source: ?SourceArg = null,
    vm_trace_path: ?[:0]const u8 = null,
    vm_trace_format: enum { text, binary } = .text,
    vm_trace_max_events: u64 = 0,
    vm_trace_main_only: bool = false,
    thunks_log_path: ?[:0]const u8 = null,
    workers: ?u8 = null,
    /// GC (`-Dgc`) collection-line override in bytes (`--max-memory`); see
    /// `eval/gc.zig:memoryBudget`. `null` = the automatic RAM-scaled line;
    /// `0` = never collect.
    max_memory: ?u64 = null,
    /// `--hugetlb auto|on|off`: back the evaluation heap with explicit 2 MB
    /// huge pages. `null` = not given; resolution (CLI > `FIX_HUGETLB` env >
    /// `auto`) happens in `setup.applyMemoryBacking`, BEFORE the heap maps.
    hugetlb: ?hugetlb.Mode = null,
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

    pub fn deinit(self: *Options, allocator: std.mem.Allocator) void {
        self.packages.deinit(allocator);
        self.include.deinit(allocator);
        self.arg_defs.deinit(allocator);
        self.option_overrides.deinit(allocator);
    }

    /// The source to evaluate when none was given on the command line: the
    /// flake in the current directory under `--flake`, else `./default.nix`
    /// (matching `nix-build`/`nix-instantiate`). Subcommands that want a
    /// no-source default (`eval`, `build`, `instantiate`, `run`) call this;
    /// `repl`/`shell` handle a null source themselves.
    pub fn defaultSource(self: Options) SourceArg {
        return if (self.flake_mode) .{ .flake = "." } else .{ .file = "default.nix" };
    }

    pub fn evaluationMode(self: Options) EvaluationMode {
        return .{
            .output = self.output,
            .strict = self.strict,
        };
    }
};

// ---------------------------------------------------------------------------
// Option table
// ---------------------------------------------------------------------------

/// Stable identity of each option. `apply` switches on it.
const Opt = enum {
    // Source selection.
    expr,
    file,
    flake,
    include,
    attr,
    arg,
    argstr,
    // Output.
    json,
    xml,
    strict,
    no_location,
    // Settings / features.
    experimental_features,
    extra_experimental_features,
    deprecated_features,
    extra_deprecated_features,
    option,
    // Build outputs / links.
    no_link,
    out_link,
    drv_link,
    add_drv_link,
    add_root,
    indirect,
    // Build realization.
    check,
    repair,
    // Daemon build settings (folded into option_overrides, applied via set_options).
    max_jobs,
    cores,
    fallback,
    keep_failed,
    max_silent_time,
    timeout,
    verbose,
    // Diagnostics.
    show_trace,
    debugger,
    color,
    no_color,
    progress,
    no_progress,
    debug_derivations,
    debug_derivation_filter,
    debug_derivation_name,
    debug_derivation_drv,
    max_memory,
    hugetlb,
    help,
    // Repl.
    bare,
    // Shell.
    packages,
    // Switch.
    nixos,
    darwin,
    home_manager,
    activate_toplevel,
    target_host,
    use_remote_sudo,
    // Disasm.
    chunk,
    no_recurse,
    no_source,
    no_constants,
    no_bytes,
    no_pager,
    disasm_eval,
    disasm_stats,
    // Internal perf/trace knobs (hidden from help, still parsed everywhere).
    workers,
    vm_trace,
    vm_trace_format,
    vm_trace_max_events,
    vm_trace_main_only,
    thunks_log,
    speculate,
    no_spec_thunks,
    no_fanout,
    print_sched_stats,
    timeline,
    timeline_flows,
};

/// Value arity of an option.
const Arg = enum {
    /// No value: `--json`. (`--json=x` is an error.)
    flag,
    /// Optional value, supplied only via `--x=value`; the bare `--x` form is
    /// valid. Never consumes the next token (avoids swallowing a positional).
    opt,
    /// One required value: `--x value`, `--x=value`, or short `-Xvalue`.
    req,
    /// Two required values: `--x NAME VALUE`.
    req2,
    /// Consumes every following token until `--` or end (`-p pkg1 pkg2`).
    greedy,
};

const Spec = struct {
    id: Opt,
    long: ?[]const u8 = null,
    short: ?[]const u8 = null,
    arg: Arg = .flag,
    /// Placeholder shown in help (`PATH`, `NAME EXPR`, `WHEN`, ...). For `.flag`
    /// options a non-empty metavar renders as an optional operand, e.g.
    /// `--flake [INSTALLABLE]`.
    metavar: []const u8 = "",
    /// One-line (or multi-line, `\n`-separated) help text.
    help: []const u8 = "",
    /// Subcommands whose `--help` lists this option; empty = all of them.
    show_in: []const Cmd = &.{},
    /// Internal knob: parsed everywhere but never shown in help.
    hidden: bool = false,
};

/// Commands that take a source expression and its selectors (everything but the
/// bare `repl`). `disasm` compiles rather than evaluates, but shares the same
/// source model (bare path / `-e` / `--file` / `--flake` / `-A` / `-I`).
const source_cmds = &[_]Cmd{ .eval, .parse, .instantiate, .build, .run, .shell, .disasm, .@"switch" };
/// Commands that run the evaluator, so diagnostics (`--show-trace`, `--color`),
/// progress, and the GC memory budget apply. `disasm` stops at compilation, so
/// it is excluded.
const eval_cmds = &[_]Cmd{ .eval, .instantiate, .build, .run, .shell, .repl, .@"switch" };
/// Commands that print an evaluated value, so the output format (`--json`,
/// `--xml`) and `--strict` apply. The realizing commands print store paths, not
/// a value, and `disasm` prints bytecode.
const value_cmds = &[_]Cmd{ .eval, .parse, .repl };
/// Commands that evaluate to a derivation whose debug records make sense.
const derivation_debug_cmds = &[_]Cmd{ .eval, .instantiate, .build, .run, .shell, .@"switch" };
/// Commands that produce a top-level `.drv` a link/root can point at.
const drv_cmds = &[_]Cmd{ .build, .instantiate };
/// Commands that realize (build/substitute) derivations via the daemon.
const realize_cmds = &[_]Cmd{ .build, .run, .shell, .@"switch" };

const specs = [_]Spec{
    .{ .id = .expr, .short = "-e", .long = "--expr", .arg = .req, .metavar = "EXPR", .help = "evaluate expression text", .show_in = source_cmds },
    .{ .id = .file, .long = "--file", .arg = .req, .metavar = "PATH", .help = "evaluate a file (same as a bare PATH)", .show_in = source_cmds },
    .{ .id = .flake, .long = "--flake", .arg = .flag, .metavar = "INSTALLABLE", .help = "evaluate a flake output <flakeref>[#<attrpath>]\n(default flakeref `.`; requires the flakes feature)", .show_in = source_cmds },
    .{ .id = .include, .short = "-I", .long = "--include", .arg = .req, .metavar = "PATH", .help = "prepend a search-path entry (as in NIX_PATH);\nPATH may be `prefix=path`. Repeatable.", .show_in = source_cmds },
    .{ .id = .attr, .short = "-A", .long = "--attr", .arg = .req, .metavar = "ATTR", .help = "select attribute path ATTR from the result", .show_in = source_cmds },
    .{ .id = .arg, .long = "--arg", .arg = .req2, .metavar = "NAME EXPR", .help = "pass EXPR as top-level function argument NAME", .show_in = source_cmds },
    .{ .id = .argstr, .long = "--argstr", .arg = .req2, .metavar = "NAME STR", .help = "pass string STR as top-level function argument NAME", .show_in = source_cmds },

    .{ .id = .json, .long = "--json", .help = "write the evaluated value as JSON", .show_in = value_cmds },
    .{ .id = .xml, .long = "--xml", .help = "write the evaluated value as XML", .show_in = value_cmds },
    .{ .id = .no_location, .long = "--no-location", .help = "omit source positions from --xml output", .show_in = value_cmds },
    .{ .id = .strict, .long = "--strict", .help = "recursively force values before writing", .show_in = value_cmds },

    .{ .id = .experimental_features, .long = "--experimental-features", .arg = .req, .metavar = "FEATS", .help = "space-separated experimental features to enable,\nreplacing the current set (available: pipe-operators,\nfetch-tree, flakes)" },
    .{ .id = .extra_experimental_features, .long = "--extra-experimental-features", .arg = .req, .metavar = "FEATS", .help = "like --experimental-features, but adds to the set" },
    .{ .id = .deprecated_features, .long = "--deprecated-features", .arg = .req, .metavar = "FEATS", .help = "space-separated deprecated features to re-enable,\nreplacing the current set (available: nul-bytes,\nfloor-ceil-corrupt-integers)" },
    .{ .id = .extra_deprecated_features, .long = "--extra-deprecated-features", .arg = .req, .metavar = "FEATS", .help = "like --deprecated-features, but adds to the set" },
    .{ .id = .option, .long = "--option", .arg = .req2, .metavar = "NAME VALUE", .help = "override a nix.conf setting" },

    .{ .id = .out_link, .short = "-o", .long = "--out-link", .arg = .req, .metavar = "NAME", .help = "name of the result symlink (default: result)", .show_in = &.{.build} },
    .{ .id = .no_link, .long = "--no-out-link", .help = "do not create the result symlink", .show_in = &.{.build} },
    .{ .id = .no_link, .long = "--no-link", .hidden = true }, // alias of --no-out-link
    .{ .id = .drv_link, .long = "--drv-link", .arg = .req, .metavar = "NAME", .help = "name of the derivation symlink (default: derivation)", .show_in = drv_cmds },
    .{ .id = .add_drv_link, .long = "--add-drv-link", .help = "also create a symlink to the .drv", .show_in = drv_cmds },
    .{ .id = .add_root, .long = "--add-root", .arg = .req, .metavar = "PATH", .help = "create the link at PATH and register it as a GC root", .show_in = drv_cmds },
    .{ .id = .indirect, .long = "--indirect", .help = "make the --add-root GC root indirect", .show_in = drv_cmds },

    .{ .id = .check, .long = "--check", .help = "rebuild and check that outputs are unchanged", .show_in = realize_cmds },
    .{ .id = .repair, .long = "--repair", .help = "rebuild and repair corrupted store paths", .show_in = realize_cmds },
    .{ .id = .max_jobs, .short = "-j", .long = "--max-jobs", .arg = .req, .metavar = "N", .help = "maximum number of parallel build jobs (or `auto`)", .show_in = realize_cmds },
    .{ .id = .cores, .long = "--cores", .arg = .req, .metavar = "N", .help = "build cores per job (0 = all available)", .show_in = realize_cmds },
    .{ .id = .fallback, .long = "--fallback", .help = "build from source if a substitute fails", .show_in = realize_cmds },
    .{ .id = .keep_failed, .short = "-K", .long = "--keep-failed", .help = "keep the build tree of failed builds", .show_in = realize_cmds },
    .{ .id = .max_silent_time, .long = "--max-silent-time", .arg = .req, .metavar = "SECS", .help = "abort a build silent for SECS seconds (0 = no limit)", .show_in = realize_cmds },
    .{ .id = .timeout, .long = "--timeout", .arg = .req, .metavar = "SECS", .help = "abort a build running longer than SECS (0 = no limit)", .show_in = realize_cmds },
    .{ .id = .verbose, .short = "-v", .long = "--verbose", .help = "increase daemon build verbosity (repeatable)", .show_in = realize_cmds },

    .{ .id = .show_trace, .long = "--show-trace", .help = "show full evaluation traces on error", .show_in = eval_cmds },
    .{ .id = .debugger, .long = "--debugger", .help = "pause into an interactive debugger at builtins.break\n(forces --workers=1)", .show_in = &[_]Cmd{ .eval, .repl } },
    .{ .id = .color, .long = "--color", .arg = .opt, .metavar = "WHEN", .help = "color diagnostics: auto, always, never" },
    .{ .id = .no_color, .long = "--no-color", .help = "disable color diagnostics" },
    .{ .id = .progress, .long = "--progress", .arg = .opt, .metavar = "WHEN", .help = "show evaluation progress: auto, always, never", .show_in = eval_cmds },
    .{ .id = .no_progress, .long = "--no-progress", .help = "disable evaluation progress", .show_in = eval_cmds },
    .{ .id = .debug_derivations, .long = "--debug-derivations", .arg = .opt, .metavar = "MODE", .help = "write derivation debug records to stderr: summary, full", .show_in = derivation_debug_cmds },
    .{ .id = .debug_derivation_filter, .long = "--debug-derivation-filter", .arg = .req, .metavar = "TEXT", .help = "only show derivations mentioning TEXT", .show_in = derivation_debug_cmds },
    .{ .id = .debug_derivation_name, .long = "--debug-derivation-name", .arg = .req, .metavar = "NAME", .help = "only show derivations with exactly NAME", .show_in = derivation_debug_cmds },
    .{ .id = .debug_derivation_drv, .long = "--debug-derivation-drv", .arg = .req, .metavar = "PATH", .help = "only show the derivation with exactly PATH", .show_in = derivation_debug_cmds },
    .{ .id = .max_memory, .long = "--max-memory", .arg = .req, .metavar = "SIZE", .help = "override the automatic GC line (MiB, or with a\nk/m/g suffix; 0 = never collect). Default: auto,\nscaled to RAM. -Dgc builds only.", .show_in = eval_cmds },
    .{ .id = .hugetlb, .long = "--hugetlb", .arg = .req, .metavar = "MODE", .help = "back the evaluation heap with 2 MB huge pages: auto,\non, off (default auto = only when the kernel pool\nhas capacity; provision via vm.nr_hugepages)", .show_in = eval_cmds },
    .{ .id = .help, .short = "-h", .long = "--help", .help = "show this help" },

    .{ .id = .bare, .long = "--bare", .help = "plain line-based input: no editor, no escape\nsequences (for pipes and expect-style automation)", .show_in = &.{.repl} },

    .{ .id = .packages, .short = "-p", .long = "--packages", .arg = .greedy, .metavar = "NAMES...", .help = "packages (attr paths) from <nixpkgs>, e.g. -p ripgrep jq", .show_in = &.{.shell} },

    .{ .id = .nixos, .long = "--nixos", .help = "build/activate a NixOS system configuration", .show_in = &.{.@"switch"} },
    .{ .id = .darwin, .long = "--darwin", .help = "build/activate a nix-darwin configuration", .show_in = &.{.@"switch"} },
    .{ .id = .home_manager, .long = "--home-manager", .help = "build/activate a home-manager configuration", .show_in = &.{.@"switch"} },
    .{ .id = .home_manager, .long = "--hm", .hidden = true }, // alias for --home-manager
    .{ .id = .target_host, .long = "--target-host", .arg = .req, .metavar = "[USER@]HOST", .help = "build locally, then copy the closure and activate on\nthis remote host over SSH", .show_in = &.{.@"switch"} },
    .{ .id = .use_remote_sudo, .long = "--use-remote-sudo", .help = "run the remote profile-set/activation under sudo", .show_in = &.{.@"switch"} },
    .{ .id = .activate_toplevel, .long = "--activate-toplevel", .arg = .req, .metavar = "PATH", .hidden = true },

    // Disasm.
    .{ .id = .disasm_eval, .long = "--eval", .help = "evaluate first, then disassemble every chunk that\ncompiled (imports + whatever evaluation forces)", .show_in = &.{.disasm} },
    .{ .id = .disasm_stats, .long = "--stats", .help = "print corpus statistics (sizes, categories, reuse,\ncompressibility) instead of a disassembly", .show_in = &.{.disasm} },
    .{ .id = .chunk, .long = "--chunk", .arg = .req, .metavar = "N", .help = "disassemble only chunk N (decimal or 0x hex, as\nshown in chunk headers; default: all reachable)", .show_in = &.{.disasm} },
    .{ .id = .no_recurse, .long = "--no-recurse", .help = "only show the top chunk", .show_in = &.{.disasm} },
    .{ .id = .no_bytes, .long = "--no-bytes", .help = "omit the raw bytecode hex column", .show_in = &.{.disasm} },
    .{ .id = .no_pager, .long = "--no-pager", .help = "do not pipe output to $PAGER", .show_in = &.{.disasm} },
    .{ .id = .no_source, .long = "--no-source", .help = "omit source-span annotations", .show_in = &.{.disasm} },
    .{ .id = .no_constants, .long = "--no-constants", .help = "omit the constant pool listing", .show_in = &.{.disasm} },

    // Hidden perf/trace knobs.
    .{ .id = .workers, .long = "--workers", .arg = .req, .metavar = "N", .hidden = true },
    .{ .id = .vm_trace, .long = "--vm-trace", .arg = .opt, .metavar = "PATH", .hidden = true },
    .{ .id = .vm_trace_format, .long = "--vm-trace-format", .arg = .req, .metavar = "FMT", .hidden = true },
    .{ .id = .vm_trace_max_events, .long = "--vm-trace-max-events", .arg = .req, .metavar = "N", .hidden = true },
    .{ .id = .vm_trace_main_only, .long = "--vm-trace-main-only", .hidden = true },
    .{ .id = .thunks_log, .long = "--thunks-log", .arg = .req, .metavar = "PATH", .hidden = true },
    .{ .id = .speculate, .long = "--speculate", .hidden = true },
    .{ .id = .no_spec_thunks, .long = "--no-spec-thunks", .hidden = true },
    .{ .id = .no_fanout, .long = "--no-fanout", .hidden = true },
    .{ .id = .print_sched_stats, .long = "--print-sched-stats", .hidden = true },
    .{ .id = .timeline, .long = "--timeline", .arg = .opt, .metavar = "PATH", .hidden = true },
    .{ .id = .timeline_flows, .long = "--timeline-flows", .arg = .req, .metavar = "N", .hidden = true },
};

fn findLong(name: []const u8) ?*const Spec {
    for (&specs) |*s| {
        if (s.long) |l| if (std.mem.eql(u8, l, name)) return s;
    }
    return null;
}

fn findShort(name: []const u8) ?*const Spec {
    for (&specs) |*s| {
        if (s.short) |sh| if (std.mem.eql(u8, sh, name)) return s;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

pub fn parse(allocator: std.mem.Allocator, args_iter: *std.process.Args.Iterator, first: ?[:0]const u8) !Options {
    var options: Options = .{};

    // A bare (non-flag) token is the source path/installable. Resolved into
    // `options.source` after the loop, once `--flake` (which may appear on
    // either side of it) has been seen.
    var positional: ?[]const u8 = null;

    var carried = first;
    parse_loop: while (true) {
        const arg = if (carried) |c| blk: {
            carried = null;
            break :blk c;
        } else (args_iter.next() orelse break);

        // End of options: leave the rest in the iterator (e.g. `fix run`
        // forwards them as program arguments).
        if (std.mem.eql(u8, arg, "--")) break;

        // Match the token against the table, extracting any inline `=value`.
        var spec: ?*const Spec = null;
        var inline_value: ?[:0]const u8 = null;
        if (std.mem.startsWith(u8, arg, "--")) {
            if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
                spec = findLong(arg[0..eq]);
                inline_value = arg[eq + 1 ..];
            } else {
                spec = findLong(arg);
            }
        } else if (arg.len >= 2 and arg[0] == '-') {
            spec = findShort(arg);
            if (spec == null) {
                // Attached short value, e.g. `-Ifoo=bar` for a `.req` short.
                const s = findShort(arg[0..2]);
                if (s != null and s.?.arg == .req) {
                    spec = s;
                    inline_value = arg[2..];
                }
            }
        } else {
            // A bare token: the source path (or flake installable under
            // `--flake`). Only one is allowed.
            if (positional != null) return error.TooManySources;
            positional = arg;
            continue;
        }

        const s = spec orelse return error.UnknownOption;

        // Greedy options drain the rest of argv themselves.
        if (s.arg == .greedy) {
            if (inline_value != null) return error.UnexpectedValue;
            while (args_iter.next()) |name| {
                if (std.mem.eql(u8, name, "--")) break :parse_loop;
                try options.packages.append(allocator, name);
            }
            break :parse_loop;
        }

        // Gather the option's value(s) per arity.
        var v0: ?[:0]const u8 = null;
        var v1: ?[:0]const u8 = null;
        switch (s.arg) {
            .flag => if (inline_value != null) return error.UnexpectedValue,
            .opt => v0 = inline_value,
            .req => v0 = inline_value orelse (args_iter.next() orelse return error.MissingValue),
            .req2 => {
                v0 = inline_value orelse (args_iter.next() orelse return error.MissingValue);
                v1 = args_iter.next() orelse return error.MissingSecondValue;
            },
            .greedy => unreachable,
        }

        try apply(&options, allocator, s.id, v0, v1);
    }

    // Fold the positional into the source, respecting `--flake`. An explicit
    // `-e`/`--file` plus a positional is contradictory (`setSource` rejects it).
    if (positional) |p|
        try options.setSource(if (options.flake_mode) .{ .flake = p } else .{ .file = p });

    return options;
}

/// Apply a matched option to `options`. `v0`/`v1` carry the gathered values
/// (present according to the spec's arity). Value-format failures surface as
/// the specific `Invalid*` errors.
fn apply(options: *Options, allocator: std.mem.Allocator, id: Opt, v0: ?[:0]const u8, v1: ?[:0]const u8) !void {
    switch (id) {
        .expr => try options.setSource(.{ .expr = v0.? }),
        .file => try options.setSource(.{ .file = v0.? }),
        .flake => options.flake_mode = true,
        .include => try options.include.append(allocator, v0.?),
        .attr => options.attr = v0.?,
        .arg => try options.arg_defs.append(allocator, .{ .name = v0.?, .value = v1.?, .is_string = false }),
        .argstr => try options.arg_defs.append(allocator, .{ .name = v0.?, .value = v1.?, .is_string = true }),

        .json => options.output = .json,
        .xml => options.output = .xml,
        .no_location => options.no_location = true,
        .strict => options.strict = true,

        .experimental_features => {
            options.experimental_features = .{};
            options.experimental_features_reset = true;
            try parseFeatureList(&options.experimental_features, v0.?);
        },
        .extra_experimental_features => try parseFeatureList(&options.experimental_features, v0.?),
        .deprecated_features => {
            options.deprecated_features = .{};
            options.deprecated_features_reset = true;
            try parseDeprecatedList(&options.deprecated_features, v0.?);
        },
        .extra_deprecated_features => try parseDeprecatedList(&options.deprecated_features, v0.?),
        .option => try options.option_overrides.append(allocator, .{ .name = v0.?, .value = v1.? }),

        .no_link => options.no_link = true,
        .out_link => options.out_link = v0.?,
        .drv_link => options.drv_link = v0.?,
        .add_drv_link => options.add_drv_link = true,
        .add_root => options.add_root = v0.?,
        .indirect => options.indirect = true,
        .check => options.check = true,
        .repair => options.repair = true,
        // Build-setting sugar: fold into the nix.conf override list so
        // `setup.configure` applies them via `set_options` (same path as
        // `--option`). `--cores 4` == `--option cores 4`.
        .max_jobs => try options.option_overrides.append(allocator, .{ .name = "max-jobs", .value = v0.? }),
        .cores => try options.option_overrides.append(allocator, .{ .name = "cores", .value = v0.? }),
        .max_silent_time => try options.option_overrides.append(allocator, .{ .name = "max-silent-time", .value = v0.? }),
        .timeout => try options.option_overrides.append(allocator, .{ .name = "timeout", .value = v0.? }),
        .fallback => try options.option_overrides.append(allocator, .{ .name = "fallback", .value = "true" }),
        .keep_failed => try options.option_overrides.append(allocator, .{ .name = "keep-failed", .value = "true" }),
        .verbose => options.verbose +|= 1,

        .show_trace => options.show_trace = true,
        .debugger => options.debugger = true,
        .color => options.color = if (v0) |v| (cli.parseWhen(v) orelse return error.InvalidColorMode) else .always,
        .no_color => options.color = .never,
        .progress => options.progress = if (v0) |v| (cli.parseWhen(v) orelse return error.InvalidProgressMode) else .always,
        .no_progress => options.progress = .never,
        .debug_derivations => options.derivation_debug.mode = if (v0) |v|
            (derivation_debug.parseMode(v) orelse return error.InvalidDerivationDebugMode)
        else
            .summary,
        .debug_derivation_filter => options.derivation_debug.filter = v0.?,
        .debug_derivation_name => options.derivation_debug.name = v0.?,
        .debug_derivation_drv => options.derivation_debug.drv_path = v0.?,
        .max_memory => options.max_memory = eval_gc.parseMemorySize(v0.?) orelse return error.InvalidMaxMemory,
        .hugetlb => options.hugetlb = hugetlb.parseMode(v0.?) orelse return error.InvalidHugetlbMode,
        .help => return error.Help,

        .bare => options.bare = true,

        .packages => unreachable, // handled in the parse loop

        .nixos => options.switch_target = .nixos,
        .darwin => options.switch_target = .darwin,
        .home_manager => options.switch_target = .home_manager,
        .activate_toplevel => options.activate_toplevel = v0.?,
        .target_host => options.target_host = v0.?,
        .use_remote_sudo => options.use_remote_sudo = true,

        // Accept decimal or `0x` hex (disasm prints ids in hex).
        .chunk => options.disasm_chunk = std.fmt.parseInt(u32, v0.?, 0) catch return error.InvalidChunkId,
        .no_recurse => options.disasm_no_recurse = true,
        .no_source => options.disasm_no_source = true,
        .no_constants => options.disasm_no_constants = true,
        .no_bytes => options.disasm_no_bytes = true,
        .no_pager => options.disasm_no_pager = true,
        .disasm_eval => options.disasm_eval = true,
        .disasm_stats => options.disasm_stats = true,

        .workers => options.workers = std.fmt.parseInt(u8, v0.?, 10) catch return error.InvalidWorkers,
        .vm_trace => options.vm_trace_path = v0 orelse "-",
        .vm_trace_format => options.vm_trace_format = parseVmTraceFormat(v0.?) orelse return error.InvalidVmTraceFormat,
        .vm_trace_max_events => options.vm_trace_max_events = std.fmt.parseInt(u64, v0.?, 10) catch return error.InvalidVmTraceMaxEvents,
        .vm_trace_main_only => options.vm_trace_main_only = true,
        .thunks_log => options.thunks_log_path = v0.?,
        .speculate => options.disable_spec_thunks = false,
        .no_spec_thunks => options.disable_spec_thunks = true, // now the default; kept for A/B
        .no_fanout => options.disable_fanout = true,
        .print_sched_stats => options.print_sched_stats = true,
        .timeline => options.timeline_path = v0 orelse "fix-timeline.json",
        .timeline_flows => {
            const v = v0.?;
            options.timeline_flows = if (std.mem.eql(u8, v, "off"))
                0
            else if (std.mem.eql(u8, v, "all"))
                1
            else
                (std.fmt.parseInt(u32, v, 10) catch return error.InvalidTimelineFlows);
        },
    }
}

fn parseVmTraceFormat(text: []const u8) ?@TypeOf(@as(Options, undefined).vm_trace_format) {
    if (std.mem.eql(u8, text, "binary")) return .binary;
    if (std.mem.eql(u8, text, "text")) return .text;
    return null;
}

// ---------------------------------------------------------------------------
// Help rendering (from the table)
// ---------------------------------------------------------------------------

const help_col = 26;

/// Print `synopsis`, then the options section for `cmd`, to stdout. Best-effort
/// (a failed write must not change exit status), mirroring `cli.printHelp`.
pub fn writeHelp(io: std.Io, synopsis: []const u8, cmd: Cmd) void {
    var buf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(io, &buf);
    writeHelpInner(&w.interface, synopsis, cmd) catch return;
    w.interface.flush() catch {};
}

fn writeHelpInner(w: *std.Io.Writer, synopsis: []const u8, cmd: Cmd) !void {
    try w.writeAll(synopsis);
    try w.writeAll("\n\noptions:\n");
    for (&specs) |*s| {
        if (s.hidden) continue;
        if (s.show_in.len != 0 and std.mem.indexOfScalar(Cmd, s.show_in, cmd) == null) continue;
        try writeOptionLine(w, s);
    }
}

fn writeOptionLine(w: *std.Io.Writer, s: *const Spec) !void {
    try w.writeAll("  ");
    var col: usize = 2;
    if (s.short) |sh| {
        try w.writeAll(sh);
        col += sh.len;
        if (s.long != null) {
            try w.writeAll(", ");
            col += 2;
        }
    }
    if (s.long) |l| {
        try w.writeAll(l);
        col += l.len;
    }
    if (s.metavar.len != 0) {
        switch (s.arg) {
            .flag => {
                try w.print(" [{s}]", .{s.metavar});
                col += s.metavar.len + 3;
            },
            .opt => {
                try w.print("[={s}]", .{s.metavar});
                col += s.metavar.len + 3;
            },
            .req, .req2, .greedy => {
                try w.print(" {s}", .{s.metavar});
                col += s.metavar.len + 1;
            },
        }
    }

    if (s.help.len == 0) {
        try w.writeByte('\n');
        return;
    }
    // Align the help column; wrap to a fresh line if the head is too wide.
    if (col + 2 <= help_col) {
        try w.splatByteAll(' ', help_col - col);
    } else {
        try w.writeByte('\n');
        try w.splatByteAll(' ', help_col);
    }
    // Continuation lines in a multi-line `help` re-indent to the help column.
    var lines = std.mem.splitScalar(u8, s.help, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) {
            try w.writeByte('\n');
            try w.splatByteAll(' ', help_col);
        }
        try w.writeAll(line);
        first = false;
    }
    try w.writeByte('\n');
}

pub fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.MissingValue => "missing value after that option",
        error.MissingSecondValue => "that option expects two values (NAME and VALUE)",
        error.UnexpectedValue => "that option does not take a value",
        error.FlakesFeatureRequired => "--flake requires the flakes experimental feature; pass --extra-experimental-features flakes",
        error.TooManySources => "provide only one expression or file",
        error.InvalidColorMode => "expected --color to be auto, always, or never",
        error.InvalidProgressMode => "expected --progress to be auto, always, or never",
        error.InvalidDerivationDebugMode => "expected --debug-derivations to be summary or full",
        error.InvalidVmTraceFormat => "expected --vm-trace-format to be text or binary",
        error.InvalidVmTraceMaxEvents => "expected --vm-trace-max-events to be a non-negative integer",
        error.UnknownExperimentalFeature => "unknown experimental feature (available: pipe-operators, fetch-tree, flakes)",
        error.InvalidWorkers => "expected --workers to be a non-negative integer",
        error.InvalidMaxMemory => "expected --max-memory to be a size like 4096, 512m, or 4g",
        error.InvalidHugetlbMode => "expected --hugetlb to be auto, on, or off",
        error.InvalidTimelineFlows => "expected --timeline-flows to be off, all, or a non-negative integer",
        error.InvalidChunkId => "expected --chunk to be a chunk id (decimal, or 0x-prefixed hex)",
        error.UnknownOption => "unknown option",
        else => @errorName(err),
    };
}
