//! `fix parse` — parse a Nix expression and print its AST as JSON, matching
//! Lix's `nix-instantiate --parse` schema.
//!
//! Nix's `--parse` runs static name-binding (`bindVars`) after parsing, so
//! unbound variables and the deprecated-feature gates are reported before the
//! AST is printed. We mirror that: after the syntactic parse (used for the JSON
//! AST), we compile-and-discard through the evaluator to surface those static
//! errors. This is the CLI reusing the evaluator — like `fix inspect
//! --no-eval` — not the syntax layer depending on the compiler. Byte-parity
//! with Nix's error prose is out of scope; the exit code and rejection are what
//! the pinned parse corpus checks.

const std = @import("std");
const engine = @import("expr");
const syntax = @import("syntax");
const args = @import("../args.zig");
const setup = @import("../setup.zig");

const Evaluator = engine.Evaluator;
const Parser = syntax.parser.Parser;
const AstArena = syntax.ast.AstArena;
const Diagnostic = syntax.diagnostic.Diagnostic;

pub const synopsis =
    \\usage: fix parse [options] [path | -e <expression>]
    \\
    \\parse a Nix expression, file, or the default file and print its AST as
    \\JSON (the schema of `nix-instantiate --parse`). Output always JSON;
    \\`--json` is accepted for compatibility. Unbound variables and disabled
    \\deprecated features are reported as errors, as in `nix-instantiate --parse`.
;

pub fn run(process: @import("../process_context.zig").ProcessContext, init: std.process.Init, args_iter: *std.process.Args.Iterator) !u8 {
    const allocator = process.allocator;
    var options = args.parse(allocator, args_iter, null) catch |err| switch (err) {
        error.Help => {
            args.writeHelp(init.io, synopsis, .parse);
            return 0;
        },
        else => {
            std.debug.print("error: {s}\n\n{s}\n", .{ args.errorMessage(err), synopsis });
            return 2;
        },
    };
    defer options.deinit(allocator);
    if (options.sources.items.len > 1) {
        std.debug.print("error: this command accepts one expression or file\n\n{s}\n", .{synopsis});
        return 2;
    }

    const source_arg = options.source orelse options.defaultSource();
    const loaded = loadSource(allocator, init, source_arg) catch |err| {
        std.debug.print("error: reading source: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer if (loaded.owned) allocator.free(loaded.text);
    const source = loaded.text;
    const source_path: ?[]const u8 = switch (source_arg) {
        .file => |p| p,
        else => null,
    };

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
            try writeDiagnostics(init, source, parser.diagnostics.items);
            return 1;
        },
        else => return err,
    };

    // 2. Static binding / feature check — compile-and-discard through the
    // evaluator so unbound variables and the deprecated-feature gates surface
    // exactly as `fix eval` would report them. `source_path = null` forces
    // eager, whole-expression compilation (no lazy body deferral), so an
    // unbound variable in any position is caught, matching `bindVars`.
    setup.applyMemoryBacking(null);
    var ev = try Evaluator.init(allocator, 1);
    defer ev.deinit();
    _ = setup.configure(&ev, init, options) catch |err| {
        std.debug.print("error: {s}\n", .{@errorName(err)});
        return 1;
    };
    _ = ev.compileSource(source, null) catch {
        try writeDiagnostics(init, source, ev.getDiagnostics());
        return 1;
    };

    // Deprecation warnings: emit each recorded warning whose feature is not
    // enabled (to stderr, semantically — not Nix's exact prose).
    try emitWarnings(init, allocator, &parser, options, source, source_path);

    // A surviving CR line ending means cr-line-endings is enabled (otherwise
    // compileSource would have errored above); Lix still warns in that case.
    // This gate is inverted (the feature enables rather than silences), so it
    // is emitted directly, not through emitWarnings.
    if (parser.first_cr_offset) |off| {
        try writeDiagnostics(init, source, &.{.{
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
        std.debug.print("error: writing JSON: {s}\n", .{@errorName(err)});
        return 1;
    };
    w.interface.flush() catch {};
    return 0;
}

const Loaded = struct { text: []const u8, owned: bool };

fn loadSource(allocator: std.mem.Allocator, init: std.process.Init, source_arg: args.SourceArg) !Loaded {
    return switch (source_arg) {
        .expr => |text| .{ .text = text, .owned = false },
        .file => |path| .{
            .text = try std.Io.Dir.cwd().readFileAlloc(init.io, path, allocator, .limited(64 << 20)),
            .owned = true,
        },
        .flake => error.FlakeParseUnsupported,
    };
}

const DeprecationWarning = syntax.parser.DeprecationWarning;

fn emitWarnings(init: std.process.Init, allocator: std.mem.Allocator, parser: *Parser, options: args.Options, source: []const u8, source_path: ?[]const u8) !void {
    if (parser.warnings.items.len == 0) return;
    var warns: std.ArrayListUnmanaged(Diagnostic) = .empty;
    defer warns.deinit(allocator);
    for (parser.warnings.items) |wn| {
        // Silenced when its deprecated feature is enabled.
        if (args.DeprecatedFeature.fromName(DeprecationWarning.feature(wn.kind))) |feat| {
            if (options.deprecated_features.contains(feat)) continue;
        }
        warns.append(allocator, .{
            .severity = .warning,
            .line = syntax.diagnostic.lineForOffset(source, wn.offset),
            .column = syntax.diagnostic.columnForOffset(source, wn.offset),
            .offset = wn.offset,
            .len = wn.len,
            .token_type = null,
            .message = DeprecationWarning.message(wn.kind),
            .source = source,
            .source_path = source_path,
        }) catch break;
    }
    if (warns.items.len != 0) try writeDiagnostics(init, source, warns.items);
}

fn writeDiagnostics(init: std.process.Init, source: []const u8, diagnostics: []const Diagnostic) !void {
    var buf: [8192]u8 = undefined;
    var stderr = try init.io.lockStderr(&buf, null);
    defer init.io.unlockStderr();
    const w = &stderr.file_writer.interface;
    syntax.diagnostic.writeAll(w, source, diagnostics) catch {};
    w.flush() catch {};
}
