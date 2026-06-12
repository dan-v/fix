//! fix — blazing fast Nix evaluator CLI entry point.

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli.zig");
const eval = @import("eval.zig");
const derivation_debug = @import("derivation/debug.zig");
const diagnostic = @import("diagnostic.zig");
const repl_line = @import("cli/repl.zig");
const disasm_cmd = @import("cli/disasm.zig");
const inspect_cmd = @import("cli/inspect.zig");
const trace_cmd = @import("cli/trace.zig");
const thunks_cmd = @import("cli/thunks.zig");
const vm_trace_mod = @import("vm/trace_log.zig");
const thunk_trace_mod = @import("eval/thunk_trace.zig");
const Evaluator = eval.Evaluator;
const EvalTrace = eval.EvalTrace;
const Value = @import("runtime/value.zig").Value;

const usage =
    \\usage: fix [options] (-e <expression> | --expr <expression> | --file <path>)
    \\
    \\options:
    \\  --repl                 read and evaluate expressions interactively
    \\  -e, --expr EXPR        evaluate expression text
    \\  --json                 write the evaluated value as JSON
    \\  --xml                  write the evaluated value as XML
    \\  --strict               recursively force attr values and list items before writing
    \\  --debug-derivations[=MODE]
    \\                         write derivation debug records to stderr: summary, full
    \\  --debug-derivation-filter TEXT
    \\                         only show derivations whose name/path/input mentions TEXT
    \\  --debug-derivation-name NAME
    \\                         only show derivations with exactly NAME
    \\  --debug-derivation-drv PATH
    \\                         only show the derivation with exactly PATH
    \\  --show-trace           show full evaluation traces
    \\  --color[=when]         color diagnostics: auto, always, never
    \\  --no-color             disable color diagnostics
    \\  --progress[=when]      show evaluation progress on stderr: auto, always, never
    \\  --no-progress          disable evaluation progress
    \\  -h, --help             show this help
    \\
;

const OutputFormat = enum {
    nix,
    json,
    xml,
};

const EvaluationMode = struct {
    output: OutputFormat = .nix,
    strict: bool = false,
};

const SourceArg = union(enum) {
    expr: []const u8,
    file: []const u8,
};

const Options = struct {
    output: OutputFormat = .nix,
    strict: bool = false,
    color: cli.When = .auto,
    progress: cli.When = .auto,
    show_trace: bool = false,
    derivation_debug: derivation_debug.Options = .{},
    repl: bool = false,
    source: ?SourceArg = null,
    vm_trace_path: ?[:0]const u8 = null,
    vm_trace_format: enum { text, binary } = .text,
    vm_trace_max_events: u64 = 0,
    vm_trace_main_only: bool = false,
    thunks_log_path: ?[:0]const u8 = null,
    workers: ?u8 = null,
    disable_spec_thunks: bool = false,
    disable_fanout: bool = false,
    print_sched_stats: bool = false,

    fn setSource(self: *Options, source: SourceArg) !void {
        if (self.source != null) return error.TooManySources;
        self.source = source;
    }

    fn evaluationMode(self: Options) EvaluationMode {
        return .{
            .output = self.output,
            .strict = self.strict,
        };
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args_iter = try init.minimal.args.iterateAllocator(allocator);
    defer args_iter.deinit();

    const prog_name = args_iter.next() orelse {
        std.debug.print("{s}", .{usage});
        std.process.exit(1);
    };
    _ = prog_name;

    const first_arg = args_iter.next();
    if (first_arg) |first| {
        if (std.mem.eql(u8, first, "disasm")) {
            const code = disasm_cmd.run(init, &args_iter) catch |err| {
                std.debug.print("error: {s}\n", .{@errorName(err)});
                std.process.exit(1);
            };
            std.process.exit(code);
        }
        if (std.mem.eql(u8, first, "inspect")) {
            const code = inspect_cmd.run(init, &args_iter) catch |err| {
                std.debug.print("error: {s}\n", .{@errorName(err)});
                std.process.exit(1);
            };
            std.process.exit(code);
        }
        if (std.mem.eql(u8, first, "trace")) {
            const code = trace_cmd.run(init, &args_iter) catch |err| {
                std.debug.print("error: {s}\n", .{@errorName(err)});
                std.process.exit(1);
            };
            std.process.exit(code);
        }
        if (std.mem.eql(u8, first, "thunks")) {
            const code = thunks_cmd.run(init, &args_iter) catch |err| {
                std.debug.print("error: {s}\n", .{@errorName(err)});
                std.process.exit(1);
            };
            std.process.exit(code);
        }
    }

    const options = parseOptions(&args_iter, first_arg) catch |err| {
        std.debug.print("error: {s}\n\n{s}", .{ optionErrorMessage(err), usage });
        std.process.exit(1);
    };

    const worker_count: u8 = options.workers orelse if (builtin.single_threaded)
        1
    else
        @intCast(@min(@as(u32, 8), @as(u32, @intCast(try std.Thread.getCpuCount()))));

    var ev = try Evaluator.init(allocator, worker_count);
    defer ev.deinit();
    ev.setParallelismToggles(options.disable_spec_thunks, options.disable_fanout);
    ev.setDerivationDebug(options.derivation_debug.enabled());
    ev.setEnvironment(init.environ_map);
    try ev.setBasePathFromCurrentPath(init.io);
    if (init.environ_map.get("NIX_PATH")) |nix_path| try ev.setNixPath(nix_path);
    const use_color = cli.shouldColor(options.color, init.io, init.environ_map);
    const show_progress = cli.shouldProgress(options.progress, init.io, init.environ_map);
    if (use_color) std.Io.File.stderr().enableAnsiEscapeCodes(init.io) catch {};

    if (options.repl) {
        if (options.source != null) {
            std.debug.print("error: --repl does not take an expression or file\n\n{s}", .{usage});
            std.process.exit(1);
        }
        var progress = cli.EvalProgress.init(init.io, show_progress);
        var repl_ok = false;
        defer progress.deinit(repl_ok);
        ev.setProgressSink(progress.sink());
        try runRepl(allocator, init.io, options, use_color, &ev);
        repl_ok = true;
        return;
    }

    const source_arg = options.source orelse {
        std.debug.print("{s}", .{usage});
        std.process.exit(1);
    };

    const source = getSource(&ev, source_arg) catch |err| {
        std.debug.print("Error reading source: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    var progress = cli.EvalProgress.init(init.io, show_progress);
    errdefer progress.deinit(false);
    ev.setProgressSink(progress.sink());

    var trace_setup = try setupVmTrace(allocator, init.io, options);
    defer trace_setup.deinit(allocator);
    if (trace_setup.trace) |t| ev.setVmTrace(t);

    var thunks_setup = try setupThunkTrace(allocator, init.io, &ev, options);
    defer thunks_setup.deinit(allocator);
    if (thunks_setup.trace) |t| ev.setThunkTrace(t);

    const ok = try evaluateAndWrite(init.io, options.evaluationMode(), use_color, options.show_trace, options.derivation_debug, &ev, source.text);
    progress.deinit(ok);
    trace_setup.finish();
    thunks_setup.finish();
    if (options.print_sched_stats) {
        const s = ev.schedulerStats();
        std.debug.print(
            "sched: spec_ok={d} spec_rej={d} urgent_ok={d} urgent_rej={d} pops={d} steals={d} parks={d}\n",
            .{ s.speculative_submitted, s.speculative_rejected, s.urgent_submitted, s.urgent_rejected, s.pops, s.steals, s.parks },
        );
        if (comptime @import("jit.zig").enabled) {
            const c = @import("jit.zig").compile_counts;
            std.debug.print(
                "jit: constant_ret={d} get_upvalue_ret={d} get_upvalue_attr_ret={d} get_upvalue_attr_attr_ret={d} builtin_attr_ret={d} upvalue_call_const_ret={d} mapattrs_apply={d} genlist_apply={d} unsupported={d}\n",
                .{ c.constant_ret, c.get_upvalue_ret, c.get_upvalue_attr_ret, c.get_upvalue_attr_attr_ret, c.builtin_attr_ret, c.upvalue_call_const_ret, c.mapattrs_apply, c.genlist_apply, c.unsupported },
            );
        }
    }
    if (!ok) {
        std.process.exit(1);
    }
}

const ThunkTraceSetup = struct {
    trace: ?*thunk_trace_mod.ThunkTrace = null,
    file: ?std.Io.File = null,
    io: ?std.Io = null,
    writer: ?*std.Io.File.Writer = null,
    buffer: []u8 = &.{},

    pub fn deinit(self: *ThunkTraceSetup, allocator: std.mem.Allocator) void {
        if (self.writer) |w| allocator.destroy(w);
        if (self.trace) |t| allocator.destroy(t);
        if (self.buffer.len > 0) allocator.free(self.buffer);
        if (self.file) |f| if (self.io) |io| f.close(io);
    }

    pub fn finish(self: *ThunkTraceSetup) void {
        if (self.trace) |t| t.flush() catch {};
    }
};

fn setupThunkTrace(
    allocator: std.mem.Allocator,
    io: std.Io,
    ev: *Evaluator,
    options: Options,
) !ThunkTraceSetup {
    var setup: ThunkTraceSetup = .{};
    const path = options.thunks_log_path orelse return setup;
    if (comptime !@import("vm.zig").thunks_log_enabled) {
        std.debug.print(
            "warning: --thunks-log requested but binary was built without -Dthunks-log; the log will be empty\n",
            .{},
        );
        return setup;
    }

    setup.buffer = try allocator.alloc(u8, 64 * 1024);
    errdefer allocator.free(setup.buffer);

    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    setup.file = file;
    setup.io = io;
    const writer_ptr = try allocator.create(std.Io.File.Writer);
    errdefer allocator.destroy(writer_ptr);
    writer_ptr.* = file.writerStreaming(io, setup.buffer);
    setup.writer = writer_ptr;

    const trace_ptr = try allocator.create(thunk_trace_mod.ThunkTrace);
    errdefer allocator.destroy(trace_ptr);
    trace_ptr.* = thunk_trace_mod.ThunkTrace.init(
        &writer_ptr.interface,
        ev.internTable(),
        &ev.heap,
        &ev.registry,
    );
    setup.trace = trace_ptr;
    return setup;
}

const VmTraceSetup = struct {
    trace: ?*vm_trace_mod.VmTrace = null,
    trace_storage: ?*vm_trace_mod.VmTrace = null,
    file: ?std.Io.File = null,
    io: ?std.Io = null,
    writer: ?*std.Io.File.Writer = null,
    buffer: []u8 = &.{},

    pub fn deinit(self: *VmTraceSetup, allocator: std.mem.Allocator) void {
        if (self.writer) |w| allocator.destroy(w);
        if (self.trace_storage) |t| allocator.destroy(t);
        if (self.buffer.len > 0) allocator.free(self.buffer);
        if (self.file) |f| if (self.io) |io| f.close(io);
    }

    pub fn finish(self: *VmTraceSetup) void {
        if (self.trace) |t| t.flush() catch {};
    }
};

fn setupVmTrace(allocator: std.mem.Allocator, io: std.Io, options: Options) !VmTraceSetup {
    var setup: VmTraceSetup = .{};
    const path = options.vm_trace_path orelse return setup;

    if (!vm_trace_mod.enabled) {
        std.debug.print("warning: --vm-trace requested but binary was built without -Dvm-trace=true\n", .{});
        return setup;
    }

    setup.buffer = try allocator.alloc(u8, 64 * 1024);
    errdefer allocator.free(setup.buffer);

    if (std.mem.eql(u8, path, "-")) {
        const writer_ptr = try allocator.create(std.Io.File.Writer);
        errdefer allocator.destroy(writer_ptr);
        writer_ptr.* = std.Io.File.stderr().writerStreaming(io, setup.buffer);
        setup.writer = writer_ptr;
    } else {
        const file = try std.Io.Dir.cwd().createFile(io, path, .{});
        setup.file = file;
        setup.io = io;
        const writer_ptr = try allocator.create(std.Io.File.Writer);
        errdefer allocator.destroy(writer_ptr);
        writer_ptr.* = file.writerStreaming(io, setup.buffer);
        setup.writer = writer_ptr;
    }

    const trace_ptr = try allocator.create(vm_trace_mod.VmTrace);
    errdefer allocator.destroy(trace_ptr);
    trace_ptr.* = vm_trace_mod.VmTrace.init(&setup.writer.?.interface, switch (options.vm_trace_format) {
        .text => .text,
        .binary => .binary,
    });
    trace_ptr.setMaxEvents(options.vm_trace_max_events);
    trace_ptr.setMainOnly(options.vm_trace_main_only);
    setup.trace_storage = trace_ptr;
    setup.trace = trace_ptr;
    return setup;
}

fn evaluateAndWrite(
    io: std.Io,
    mode: EvaluationMode,
    use_color: bool,
    show_trace: bool,
    debug_options: derivation_debug.Options,
    ev: *Evaluator,
    source: []const u8,
) !bool {
    const result = ev.evaluate(source) catch |err| {
        try writeEvalFailure(io, use_color, show_trace, ev, source, err);
        return false;
    };

    writeResult(io, mode, ev, result) catch |err| {
        try writeEvaluationError(io, use_color, show_trace, ev, source, err);
        return false;
    };
    try derivation_debug.write(io, use_color, ev.allocator, debug_options, ev.derivationDebugRecords());
    return true;
}

fn writeEvalFailure(
    io: std.Io,
    use_color: bool,
    show_trace: bool,
    ev: *Evaluator,
    source: []const u8,
    err: anyerror,
) !void {
    if (ev.getDiagnostics().len > 0) {
        var stderr_buffer: [4096]u8 = undefined;
        var stderr = try cli.lockStderr(io, &stderr_buffer);
        defer stderr.deinit();
        try diagnostic.writeAllWithOptions(stderr.writer(), source, ev.getDiagnostics(), .{ .color = use_color });
        try stderr.flush();
    } else {
        try writeEvaluationError(io, use_color, show_trace, ev, source, err);
    }
}

fn writeResult(io: std.Io, mode: EvaluationMode, ev: *Evaluator, result: Value) !void {
    if (mode.strict) try ev.forceDeep(result);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    switch (mode.output) {
        .nix => try ev.writeValue(&stdout.interface, result),
        .json => try ev.writeJsonValue(&stdout.interface, result),
        .xml => try ev.writeXmlValue(&stdout.interface, result),
    }
    if (mode.output != .xml) try stdout.interface.writeByte('\n');
    try stdout.interface.flush();
}

const Source = struct {
    text: []const u8,
};

fn getSource(
    ev: *Evaluator,
    source: SourceArg,
) !Source {
    return switch (source) {
        .expr => |text| .{ .text = text },
        .file => |path| .{ .text = try ev.readSourceFile(path) },
    };
}

fn parseOptions(args_iter: *std.process.Args.Iterator, first: ?[:0]const u8) !Options {
    var options: Options = .{};

    var carried = first;
    while (true) {
        const arg = if (carried) |c| blk: {
            carried = null;
            break :blk c;
        } else (args_iter.next() orelse break);
        if (std.mem.eql(u8, arg, "--repl")) {
            options.repl = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            options.output = .json;
        } else if (std.mem.eql(u8, arg, "--xml")) {
            options.output = .xml;
        } else if (std.mem.eql(u8, arg, "--strict")) {
            options.strict = true;
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
            std.debug.print("{s}", .{usage});
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--expr")) {
            try options.setSource(.{ .expr = args_iter.next() orelse return error.MissingExpression });
        } else if (std.mem.eql(u8, arg, "--file")) {
            try options.setSource(.{ .file = args_iter.next() orelse return error.MissingPath });
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
        } else if (std.mem.eql(u8, arg, "--workers")) {
            const text = args_iter.next() orelse return error.MissingWorkers;
            options.workers = std.fmt.parseInt(u8, text, 10) catch return error.InvalidWorkers;
        } else if (std.mem.startsWith(u8, arg, "--workers=")) {
            options.workers = std.fmt.parseInt(u8, arg["--workers=".len..], 10) catch return error.InvalidWorkers;
        } else if (std.mem.startsWith(u8, arg, "--thunks-log=")) {
            options.thunks_log_path = arg["--thunks-log=".len..];
        } else if (std.mem.eql(u8, arg, "--no-spec-thunks")) {
            options.disable_spec_thunks = true;
        } else if (std.mem.eql(u8, arg, "--no-fanout")) {
            options.disable_fanout = true;
        } else if (std.mem.eql(u8, arg, "--print-sched-stats")) {
            options.print_sched_stats = true;
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

fn optionErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.MissingExpression => "missing expression after -e or --expr",
        error.MissingPath => "missing path after --file",
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
        error.MissingWorkers => "missing N after --workers",
        error.InvalidWorkers => "expected --workers to be a non-negative integer",
        error.UnknownOption => "unknown option",
        else => @errorName(err),
    };
}

fn runRepl(allocator: std.mem.Allocator, io: std.Io, options: Options, use_color: bool, ev: *Evaluator) !void {
    const interactive = (std.Io.File.stdin().isTty(io) catch false) and (std.Io.File.stdout().isTty(io) catch false);

    var stdin_buffer: [64 * 1024]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(io, &stdin_buffer);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);

    if (interactive) {
        try stdout.interface.writeAll("fix repl\n");
        try stdout.interface.flush();
    }

    var history = repl_line.History.init(allocator);
    defer history.deinit();
    var raw_editor = interactive;

    while (true) {
        var owned_line: ?[]u8 = null;
        const line = if (raw_editor) line: {
            const maybe_line = repl_line.readInteractiveAlloc(allocator, io, "fix> ", use_color, &history) catch |err| switch (err) {
                error.UnsupportedTerminal => {
                    raw_editor = false;
                    break :line try readCanonicalReplLine(io, use_color, interactive, &stdin.interface, &stdout.interface) orelse break;
                },
                else => return err,
            };
            owned_line = maybe_line orelse break;
            break :line owned_line.?;
        } else line: {
            break :line try readCanonicalReplLine(io, use_color, interactive, &stdin.interface, &stdout.interface) orelse break;
        };
        defer if (owned_line) |owned| allocator.free(owned);

        const source = std.mem.trim(u8, line, " \t\r");
        if (source.len == 0) continue;

        if (!raw_editor) {
            try history.add(source);
        }

        if (std.mem.eql(u8, source, ":q") or
            std.mem.eql(u8, source, ":quit") or
            std.mem.eql(u8, source, ":exit"))
        {
            break;
        }
        if (std.mem.eql(u8, source, ":help")) {
            try writeReplHelp(&stdout.interface);
            try stdout.interface.flush();
            continue;
        }

        _ = try evaluateAndWrite(io, options.evaluationMode(), use_color, options.show_trace, options.derivation_debug, ev, source);
    }
}

fn readCanonicalReplLine(
    io: std.Io,
    use_color: bool,
    interactive: bool,
    stdin: *std.Io.Reader,
    stdout: *std.Io.Writer,
) !?[]const u8 {
    if (interactive) {
        try cli.style(stdout, use_color, .trace_label);
        try stdout.writeAll("fix> ");
        try cli.reset(stdout, use_color);
        try stdout.flush();
    }

    const raw_line = stdin.takeDelimiter('\n') catch |err| switch (err) {
        error.StreamTooLong => {
            try writeReplInputError(io, use_color, "input line is too long");
            _ = stdin.discardDelimiterInclusive('\n') catch {};
            return "";
        },
        else => return err,
    };
    return raw_line;
}

fn writeReplHelp(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\:help   show commands
        \\:q      exit
        \\:quit   exit
        \\
    );
}

fn writeReplInputError(io: std.Io, use_color: bool, message: []const u8) !void {
    var stderr_buffer: [1024]u8 = undefined;
    var stderr = try cli.lockStderr(io, &stderr_buffer);
    defer stderr.deinit();
    const writer = stderr.writer();
    try cli.style(writer, use_color, .error_label);
    try writer.writeAll("error");
    try cli.reset(writer, use_color);
    try writer.print(": {s}\n", .{message});
    try stderr.flush();
}

const default_trace_limit = 8;

fn writeEvaluationError(io: std.Io, use_color: bool, show_trace: bool, ev: *Evaluator, source: []const u8, err: anyerror) !void {
    var stderr_buffer: [4096]u8 = undefined;
    var stderr = try cli.lockStderr(io, &stderr_buffer);
    defer stderr.deinit();
    const writer = stderr.writer();
    const trace = ev.getTrace();

    try cli.style(writer, use_color, .error_label);
    try writer.writeAll("error");
    try cli.reset(writer, use_color);
    if (trace.message) |message| {
        try writer.print(": {s}\n", .{message});
    } else {
        try writer.print(": evaluation failed with {s}\n", .{@errorName(err)});
    }

    try writeTraceFrames(writer, use_color, show_trace, ev, source, trace.frames.items);
    try stderr.flush();
}

fn writeTraceFrames(
    writer: *std.Io.Writer,
    use_color: bool,
    show_trace: bool,
    ev: *Evaluator,
    source: []const u8,
    frames: []const EvalTrace.Frame,
) !void {
    if (frames.len == 0) return;

    try cli.style(writer, use_color, .dim);
    try writer.writeAll("\ntrace:\n");
    try cli.reset(writer, use_color);

    if (show_trace or frames.len <= default_trace_limit) {
        for (frames) |frame| try writeTraceFrame(writer, use_color, ev, source, frame);
        return;
    }

    const head_count = default_trace_limit / 2;
    const tail_count = default_trace_limit - head_count;
    for (frames[0..head_count]) |frame| try writeTraceFrame(writer, use_color, ev, source, frame);

    try cli.style(writer, use_color, .dim);
    try writer.print("  ... {d} frames omitted; use --show-trace to show all\n", .{frames.len - default_trace_limit});
    try cli.reset(writer, use_color);

    for (frames[frames.len - tail_count ..]) |frame| try writeTraceFrame(writer, use_color, ev, source, frame);
}

fn writeTraceFrame(writer: *std.Io.Writer, use_color: bool, ev: *Evaluator, source: []const u8, frame: EvalTrace.Frame) !void {
    if (frame.diagnostic) |diag| {
        if (traceFrameSource(ev, source, frame)) |frame_source| {
            try diagnostic.writeAllWithOptions(writer, frame_source, &.{diag}, .{ .color = use_color });
            return;
        }
        if (frame.source_path) |path| {
            try writer.print("  {s}:{d}:{d}: {s}\n", .{ path, diag.line, diag.column, frame.message });
            return;
        }
        try writer.print("  expression:{d}:{d}: {s}\n", .{ diag.line, diag.column, frame.message });
        return;
    }

    try writer.writeAll("  ");
    try cli.style(writer, use_color, .trace_label);
    try writer.writeAll("while evaluating");
    try cli.reset(writer, use_color);
    try writer.print(": {s}\n", .{frame.message});
}

fn traceFrameSource(ev: *Evaluator, source: []const u8, frame: EvalTrace.Frame) ?[]const u8 {
    if (frame.source_path) |path| {
        return ev.readSourceFile(path) catch null;
    }
    return source;
}
