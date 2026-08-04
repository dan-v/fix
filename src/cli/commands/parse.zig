//! `fix parse` — parse a Nix expression and print its AST as JSON, matching
//! Lix's `nix-instantiate --parse` schema.
//!
//! Nix's `--parse` runs static name-binding (`bindVars`) after parsing, so
//! unbound variables and the deprecated-feature gates are reported before the
//! AST is printed. We mirror that: after the syntactic parse (used for the JSON
//! AST), we compile-and-discard through the evaluator to surface those static
//! errors. This is the CLI reusing the evaluator for static validation, not
//! the syntax layer depending on the compiler. Byte-parity
//! with Nix's error prose is out of scope; the exit code and rejection are what
//! the pinned parse corpus checks.

const std = @import("std");
const engine = @import("expr");
const syntax = @import("syntax");
const args = @import("../args.zig");
const fileish = @import("../fileish.zig");
const presentation = @import("../presentation.zig");
const render = @import("../render.zig");
const setup = @import("../setup.zig");

const Engine = engine.Engine;
const Parser = syntax.parser.Parser;
const AstArena = syntax.ast.AstArena;
const Diagnostic = syntax.diagnostic.Diagnostic;

pub const synopsis =
    \\usage: fix parse [options] [path | -E <expression>]
    \\
    \\parse a Nix expression, file, or the default file and print its AST as
    \\JSON (the schema of `nix-instantiate --parse`). Output always JSON;
    \\`--json` is accepted for compatibility. Unbound variables and disabled
    \\deprecated features are reported as errors, as in `nix-instantiate --parse`.
;

pub fn run(process: @import("../process_context.zig").ProcessContext, init: std.process.Init, args_iter: *std.process.Args.Iterator) !u8 {
    const allocator = process.allocator;
    var diag: args.Diag = .{};
    var options = args.parse(allocator, args_iter, null, .parse, &diag) catch |err| switch (err) {
        error.Help => {
            args.writeHelp(init.io, synopsis, .parse);
            return 0;
        },
        else => {
            render.usageError(init.io, init.environ_map, args.errorMessage(err), diag.offending, synopsis);
            return 2;
        },
    };
    defer options.deinit(allocator);
    if (options.sources.items.len > 1) {
        render.usageError(init.io, init.environ_map, "this command accepts one expression or file", null, synopsis);
        return 2;
    }
    const use_color = presentation.colorDepth(options.color, init.io, init.environ_map).enabled();

    const memory_backing = setup.applyMemoryBacking(process, null);
    var settings = setup.loadSettingsAndFlakeConfig(allocator, init, &options) catch |err| {
        if (err != error.ConfigError) return err;
        return 1;
    };
    defer settings.deinit();
    var ev = try Engine.init(allocator, setup.engineConfig(init, 1, memory_backing));
    defer ev.deinit();
    _ = setup.configure(&ev, init, &options, &settings) catch |err| {
        render.caughtError(init.io, use_color, err, "", .{});
        return 1;
    };

    const source_arg = options.source orelse options.defaultSource();
    var loaded = loadSource(&ev, init.io, source_arg) catch |err| {
        render.caughtError(init.io, use_color, err, "reading source", .{});
        return 1;
    };
    defer loaded.deinit(allocator);
    const source = loaded.slice();
    const source_path = loaded.abs_path;

    // 1. Syntactic parse — the AST we print, and the syntax-error gate.
    var arena = AstArena.init(allocator);
    defer arena.deinit();
    var parser = Parser.init(allocator, &arena, source);
    defer parser.deinit();
    const node = parser.parse() catch |err| switch (err) {
        error.ParseError => {
            // Diagnostics carry only spans; fill in the shared source and path.
            for (parser.diagnostics.items) |*d| {
                if (d.source == null) d.source = source;
                if (d.source_path == null) d.source_path = source_path;
            }
            try writeDiagnostics(init, use_color, source, parser.diagnostics.items);
            return 1;
        },
        else => return err,
    };

    // 2. Static binding / feature check — compile-and-discard through the
    // evaluator so unbound variables and the deprecated-feature gates surface
    // exactly as `fix eval` would report them. `source_path = null` forces
    // eager, whole-expression compilation (no lazy body deferral), so an
    // unbound variable in any position is caught, matching `bindVars`.
    _ = ev.compileSource(source, null) catch {
        try writeDiagnostics(init, use_color, source, ev.getDiagnostics());
        return 1;
    };

    // Deprecation warnings: emit each recorded warning whose feature is not
    // enabled (to stderr, semantically — not Nix's exact prose).
    try emitWarnings(init, use_color, allocator, &parser, &options, source, source_path);

    // A surviving CR line ending means cr-line-endings is enabled (otherwise
    // compileSource would have errored above); Lix still warns in that case.
    // This gate is inverted (the feature enables rather than silences), so it
    // is emitted directly, not through emitWarnings.
    if (parser.first_cr_offset) |off| {
        try writeDiagnostics(init, use_color, source, &.{.{
            .severity = .warning,
            .line = syntax.diagnostic.lineForOffset(source, off),
            .column = syntax.diagnostic.columnForOffset(source, off),
            .offset = off,
            .len = 1,
            .token_type = null,
            .message = DeprecationWarning.message(.cr_line_endings),
            .source = source,
            .source_path = source_path,
        }});
    }

    // 3. Emit the AST as JSON.
    var buf: [64 * 1024]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(init.io, &buf);
    syntax.json.write(&w.interface, allocator, source, node) catch |err| {
        render.caughtError(init.io, use_color, err, "writing JSON", .{});
        return 1;
    };
    w.interface.flush() catch {};
    return 0;
}

const DeprecationWarning = syntax.parser.DeprecationWarning;

fn loadSource(ev: *Engine, io: std.Io, source: args.SourceArg) !fileish.Source {
    return switch (source) {
        .expr => |text| .{ .text = .{ .borrowed = text } },
        .file => |path| try fileish.load(ev, io, path),
        .flake => error.FlakeParseUnsupported,
    };
}

fn emitWarnings(init: std.process.Init, use_color: bool, allocator: std.mem.Allocator, parser: *Parser, options: *const args.Options, source: []const u8, source_path: ?[]const u8) !void {
    if (parser.warnings.items.len == 0) return;
    var warns: std.ArrayListUnmanaged(Diagnostic) = .empty;
    defer warns.deinit(allocator);
    for (parser.warnings.items) |wn| {
        // Silenced when its deprecated feature is enabled.
        if (args.DeprecatedFeature.fromName(DeprecationWarning.feature(wn.kind))) |feat| {
            if (options.deprecated_features.contains(feat)) continue;
        }
        try warns.append(allocator, .{
            .severity = .warning,
            .line = syntax.diagnostic.lineForOffset(source, wn.offset),
            .column = syntax.diagnostic.columnForOffset(source, wn.offset),
            .offset = wn.offset,
            .len = wn.len,
            .token_type = null,
            .message = DeprecationWarning.message(wn.kind),
            .source = source,
            .source_path = source_path,
        });
    }
    if (warns.items.len != 0) try writeDiagnostics(init, use_color, source, warns.items);
}

fn writeDiagnostics(init: std.process.Init, use_color: bool, source: []const u8, diagnostics: []const Diagnostic) !void {
    var buf: [8192]u8 = undefined;
    var stderr = try init.io.lockStderr(&buf, null);
    defer init.io.unlockStderr();
    const w = &stderr.file_writer.interface;
    syntax.diagnostic.writeAllWithOptions(w, source, diagnostics, .{ .color = use_color }) catch {};
    w.flush() catch {};
}
