//! `fix disasm` — compile a Nix expression and pretty-print its bytecode.
//!
//! By default this statically compiles the top expression and disassembles the
//! reachable chunk graph. `--eval` instead evaluates the expression first, so
//! imported files and lazily-compiled attribute bodies are compiled too, then
//! dumps every chunk in the registry. When stdout is a terminal the output is
//! piped to `$PAGER`.

const std = @import("std");
const engine = @import("nix");
const bytecode = engine.bytecode;
const cli = @import("cli.zig");
const args = @import("args.zig");
const setup = @import("setup.zig");
const runner = @import("run.zig");

const Evaluator = engine.Evaluator;
const ChunkId = engine.types.ChunkId;

pub const synopsis =
    \\usage: fix disasm [options] [path | -e <expression>]
    \\
    \\compile a Nix expression, file, or flake output and disassemble its
    \\bytecode. With no source, uses ./default.nix (or, with --flake, the flake
    \\in the current directory).
    \\
    \\When stdout is a terminal the output is piped to $PAGER (disable with
    \\--no-pager). For color through the pager, set e.g. PAGER='less -R' or LESS=R.
;

pub fn run(allocator: std.mem.Allocator, init: std.process.Init, args_iter: *std.process.Args.Iterator) !u8 {
    var options = args.parse(allocator, args_iter, null) catch |err| switch (err) {
        error.Help => {
            args.writeHelp(init.io, synopsis, .disasm);
            return 0;
        },
        else => {
            std.debug.print("error: {s}\n\n{s}\n", .{ args.errorMessage(err), synopsis });
            return 2;
        },
    };
    defer options.deinit(allocator);

    const source_arg = options.source orelse options.defaultSource();

    // `--eval` runs the evaluator single-threaded and without speculation: we
    // want exactly the chunks the demand path compiles, and speculative forcing
    // on unguarded worker fibers can blow their stacks on deeply or infinitely
    // recursive values (e.g. a NixOS toplevel). The static path never evaluates,
    // so its worker count is immaterial.
    const worker_count: u8 = if (options.disasm_eval) 1 else try setup.workerCount(options);

    // Resolve heap backing before the evaluator maps its stores
    // (`--hugetlb` > `FIX_HUGETLB` > auto).
    setup.applyMemoryBacking(options.hugetlb, init);
    var ev = try Evaluator.init(allocator, worker_count);
    defer ev.deinit();
    // Configure features (pipe-operators/flakes), base path, and NIX_PATH so the
    // compile matches what `eval`/`build` would see. No progress: disasm prints
    // bytecode, not a progress bar.
    _ = try setup.configure(&ev, init, options);
    if (options.disasm_eval) ev.setParallelismToggles(true, true);
    // Best-effort chunk naming: attribute each lambda/thunk chunk to the attr
    // or let binding it was compiled for, so the disassembly headers read like
    // `chunk #42 fetchGit`. Safe here — disasm compiles single-threaded.
    ev.setCaptureChunkNames(true);

    if (source_arg == .flake and !ev.flakes_enabled) {
        std.debug.print("error: {s}\n\n{s}\n", .{ args.errorMessage(error.FlakesFeatureRequired), synopsis });
        return 2;
    }

    // Coloring and paging both follow stdout (where the disassembly goes),
    // unlike the eval commands whose diagnostics go to stderr.
    const stdout_tty = std.Io.File.stdout().isTty(init.io) catch false;
    const use_color = switch (options.color) {
        .always => true,
        .never => false,
        .auto => cli.autoColor(stdout_tty, init.environ_map),
    };

    const source = runner.getSource(&ev, source_arg, options) catch |err| {
        std.debug.print("error: reading source: {s}\n", .{@errorName(err)});
        return 1;
    };
    // `--flake`/`-A`/`--arg` synthesize source text on `ev.allocator`; plain
    // expr/file text is borrowed (argv) or owned by the evaluator's file cache.
    defer source.deinit(ev.allocator);

    // Compile (or evaluate) up front, before any pager is spawned: this is where
    // user-facing errors and warnings surface, and it resolves the single target
    // chunk (a bad `--chunk` should fail cleanly, not through the pager).
    var target_id: ChunkId = 0;
    var target_chunk: ?*const bytecode.Chunk = null;
    // Only a plain `--file`/positional (no selector wrapping) carries a real
    // source path for span annotations; synthesized text has none.
    const source_path: ?[]const u8 = switch (source_arg) {
        .file => |p| if (source.owned) null else p,
        else => null,
    };
    if (options.disasm_eval) {
        try compileByEval(&ev, source.text, source_path);
        if (options.disasm_chunk) |id| {
            target_id = id;
            target_chunk = ev.getChunk(id) orelse {
                std.debug.print("error: chunk #{d} not found\n", .{id});
                return 1;
            };
        }
    } else {
        const top_id = ev.compileSource(source.text, source_path) catch |err| {
            std.debug.print("error: compilation failed: {s}\n", .{@errorName(err)});
            return 1;
        };
        target_id = options.disasm_chunk orelse top_id;
        target_chunk = ev.getChunk(target_id) orelse {
            std.debug.print("error: chunk #{d} not found\n", .{target_id});
            return 1;
        };
    }

    const symbols = bytecode.disasm.Symbols{
        .intern = ev.internTable(),
        .registry = ev.chunkRegistry(),
    };
    // Cross-reference graph over the whole registry, so each chunk header can
    // list its incoming/outgoing chunk references. Best-effort: on failure we
    // simply omit the section. `--stats` never renders references.
    var ref_graph: ?bytecode.inspect.RefGraph = if (options.disasm_stats) null else bytecode.inspect.RefGraph.build(allocator, ev.chunkRegistry()) catch null;
    defer if (ref_graph) |*g| g.deinit();
    const opts = bytecode.disasm.Options{
        .show_constants = !options.disasm_no_constants,
        .show_source = !options.disasm_no_source,
        .show_bytes = !options.disasm_no_bytes,
        // The `--eval` registry walk visits every chunk once, so recursion is
        // only for the static single-chunk-graph path.
        .recurse = !options.disasm_eval and !options.disasm_no_recurse,
        .use_color = use_color,
        .max_depth = 0, // unlimited: the visited set guarantees termination.
        .refs = if (ref_graph) |*g| g else null,
        // Queried before any pager spawns (stdout is still the terminal), so
        // the zebra row background can extend across the full line.
        .line_width = terminalWidth() orelse 100,
    };

    // Pipe to $PAGER when interactive; fall back to stdout on any spawn failure.
    const pager_cmd: ?[]const u8 = if (!options.disasm_no_pager and stdout_tty) blk: {
        const p = init.environ_map.get("PAGER") orelse break :blk null;
        break :blk if (p.len == 0) null else p;
    } else null;
    var pager: ?Pager = if (pager_cmd) |cmd| Pager.start(init, cmd) else null;
    const sink: std.Io.File = if (pager) |p| p.child.stdin.? else std.Io.File.stdout();
    if (use_color and pager == null) std.Io.File.stdout().enableAnsiEscapeCodes(init.io) catch {};

    var out_buffer: [1 << 15]u8 = undefined;
    var stream = sink.writerStreaming(init.io, &out_buffer);
    const writer = &stream.interface;

    const write_err: ?anyerror = blk: {
        if (options.disasm_stats) {
            bytecode.disasm.writeStats(allocator, writer, ev.chunkRegistry(), symbols) catch |e| break :blk e;
        } else if (options.disasm_eval and options.disasm_chunk == null) {
            dumpAll(writer, &ev, symbols, opts) catch |e| break :blk e;
        } else {
            bytecode.disasm.writeChunk(allocator, writer, target_id, target_chunk.?, symbols, opts) catch |e| break :blk e;
        }
        stream.interface.flush() catch |e| break :blk e;
        break :blk null;
    };

    if (pager) |*p| p.finish(init.io);

    if (write_err) |e| {
        // A broken pipe means a downstream reader closed early — our own $PAGER,
        // or a manual `| less` / `| head`. That's a normal exit, not an error.
        // The interface collapses the real cause into `WriteFailed`; the actual
        // errno is stashed on the file writer. Any other write failure (e.g. the
        // operand scratch buffer overflowing, or a full disk) is a real error and
        // must surface — don't blanket-swallow just because a pager was spawned.
        const broken_pipe = if (stream.err) |we| we == error.BrokenPipe else false;
        if (broken_pipe) return 0;
        return e;
    }
    return 0;
}

/// The terminal's column count (from stdout), or null when stdout isn't a
/// terminal / the query fails.
fn terminalWidth() ?u16 {
    var ws: std.posix.winsize = undefined;
    // Route through the per-OS backend (linux syscall / libc) so this works
    // on Darwin as well as Linux; TIOCGWINSZ + winsize exist on both.
    const rc = std.posix.system.ioctl(1, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
    if (std.posix.errno(rc) != .SUCCESS) return null;
    return if (ws.col > 0) ws.col else null;
}

/// A `$PAGER` child process fed the disassembly on its stdin.
const Pager = struct {
    child: std.process.Child,

    /// Spawn `sh -c <cmd>` with a stdin pipe (so `$PAGER` may carry arguments,
    /// e.g. `less -R`). Returns null on any spawn failure — the caller then
    /// writes straight to stdout.
    fn start(init: std.process.Init, cmd: []const u8) ?Pager {
        const child = std.process.spawn(init.io, .{
            .argv = &[_][]const u8{ "sh", "-c", cmd },
            .environ_map = init.environ_map,
            .stdin = .pipe,
        }) catch return null;
        return .{ .child = child };
    }

    /// Close our end of the pipe (EOF for the pager) and wait for it to exit.
    fn finish(self: *Pager, io: std.Io) void {
        if (self.child.stdin) |f| {
            f.close(io);
            self.child.stdin = null;
        }
        _ = self.child.wait(io) catch {};
    }
};

/// Evaluate `source` to weak head normal form — the same non-strict evaluation
/// `fix eval` does — so imports (and any attribute bodies forced along the way)
/// compile into the registry, then dump whatever compiled. We deliberately do
/// NOT deep-force: a full force of e.g. a NixOS toplevel recurses without bound
/// (and would FrameOverflow, or blow a speculative worker's stack). Best-effort:
/// a failing eval still leaves its compiled chunks behind to inspect, so a
/// failure is a warning, not an abort.
fn compileByEval(ev: *Evaluator, source: []const u8, source_path: ?[]const u8) !void {
    _ = ev.evaluatePath(source, source_path) catch |err| {
        std.debug.print("warning: evaluation failed: {s} (dumping chunks compiled so far)\n", .{@errorName(err)});
    };
}

/// Dump every compiled chunk in id order. Recursion is off in `opts` here: the
/// registry walk already visits every chunk exactly once.
fn dumpAll(
    writer: *std.Io.Writer,
    ev: *Evaluator,
    symbols: bytecode.disasm.Symbols,
    opts: bytecode.disasm.Options,
) !void {
    const registry = ev.chunkRegistry();
    const total = registry.count();
    var id: ChunkId = 0;
    var first = true;
    while (id < total) : (id += 1) {
        const chunk = registry.get(id) orelse continue;
        if (!first) try writer.writeByte('\n');
        first = false;
        try bytecode.disasm.writeChunk(ev.allocator, writer, id, chunk, symbols, opts);
    }
}
