//! `fix parse` — parse a Nix expression and print its AST as JSON, matching
//! Lix's `nix-instantiate --parse` schema. Parsing only: no evaluator, no
//! store. On a parse error, fix's own diagnostics go to stderr and we exit 1
//! (byte-parity with Nix's parse-fail messages is out of scope).

const std = @import("std");
const syntax = @import("syntax");
const args = @import("args.zig");

const Parser = syntax.parser.Parser;
const AstArena = syntax.ast.AstArena;

pub const synopsis =
    \\usage: fix parse [options] [path | -e <expression>]
    \\
    \\parse a Nix expression, file, or the default file and print its AST as
    \\JSON (the schema of `nix-instantiate --parse`). Output always JSON;
    \\`--json` is accepted for compatibility.
;

pub fn run_cmd(allocator: std.mem.Allocator, init: std.process.Init, args_iter: *std.process.Args.Iterator) !u8 {
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

    var arena = AstArena.init(allocator);
    defer arena.deinit();
    var parser = Parser.init(allocator, &arena, source);
    defer parser.deinit();

    const node = parser.parse() catch |err| switch (err) {
        error.ParseError => {
            try writeDiagnostics(init, &parser, source, source_path);
            return 1;
        },
        else => return err,
    };

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

fn writeDiagnostics(init: std.process.Init, parser: *Parser, source: []const u8, source_path: ?[]const u8) !void {
    var buf: [8192]u8 = undefined;
    var stderr = try init.io.lockStderr(&buf, null);
    defer init.io.unlockStderr();
    const w = &stderr.file_writer.interface;
    // Fill in the shared source (diagnostics carry only spans) and path.
    for (parser.diagnostics.items) |*d| {
        if (d.source == null) d.source = source;
        if (d.source_path == null) d.source_path = source_path;
    }
    syntax.diagnostic.writeAll(w, source, parser.diagnostics.items) catch {};
    w.flush() catch {};
}
