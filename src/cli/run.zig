//! Driving a single evaluation: run the source, write the result, render
//! failures, and load source text.

const std = @import("std");
const render = @import("render.zig");
const args = @import("args.zig");
const derivation_debug = @import("derivation_debug.zig");
const eval = @import("fix").eval;
const Evaluator = eval.Evaluator;
const Value = @import("runtime").value.Value;
const EvaluationMode = args.EvaluationMode;
const SourceArg = args.SourceArg;

/// Evaluate `source`, write the result (or render the failure), and emit any
/// requested derivation-debug records. Returns whether evaluation succeeded.
pub fn evaluateAndWrite(
    io: std.Io,
    mode: EvaluationMode,
    use_color: bool,
    show_trace: bool,
    debug_options: derivation_debug.Options,
    ev: *Evaluator,
    source: []const u8,
    label: []const u8,
) !bool {
    // Bracket the whole run (evaluate + force + render) so the progress bar
    // keeps an always-open "evaluating <label>" node and a ~100ms counter
    // sampler running across every phase. Defers are LIFO: the sampler stops
    // (and joins) before the session's nodes are torn down.
    ev.progressSessionBegin(label);
    defer ev.progressSessionEnd();
    ev.startProgressSampler();
    defer ev.stopProgressSampler();

    const result = ev.evaluate(source) catch |err| {
        try render.evalFailure(io, use_color, show_trace, ev, source, err);
        return false;
    };

    writeResult(io, mode, ev, result) catch |err| {
        try render.evaluationError(io, use_color, show_trace, ev, source, err);
        return false;
    };
    try derivation_debug.write(io, use_color, ev.allocator, debug_options, ev.derivationDebugRecords());
    return true;
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

pub const Source = struct {
    text: []const u8,
};

pub fn getSource(ev: *Evaluator, source: SourceArg) !Source {
    return switch (source) {
        .expr => |text| .{ .text = text },
        .file => |path| blk: {
            const text = try ev.readSourceFile(path);
            // Resolve the file's relative path literals (`./x`, `import ./y`)
            // against the file's directory, like Nix — not the process cwd.
            try ev.setBasePathToFileDir(path);
            break :blk .{ .text = text };
        },
        .flake => |installable| .{ .text = try lowerFlakeInstallable(ev, installable) },
    };
}

/// Lower a flake installable `<flakeref>[#<attrpath>]` into a Nix expression
/// `(builtins.getFlake "<ref>").<attrpath>` and hand it to the normal evaluate
/// path. `.` and relative flakerefs resolve against the evaluator's base path
/// (the CLI's cwd); scheme refs (`github:`, `path:`, …) pass through to
/// `getFlake`. The attrpath is dot-split into quoted selections, so component
/// names may contain any character except `.`. The returned text is owned by
/// `ev.allocator` and lives for the rest of the (one-shot) run.
fn lowerFlakeInstallable(ev: *Evaluator, installable: []const u8) ![]const u8 {
    const hash = std.mem.indexOfScalar(u8, installable, '#');
    const flake_ref = if (hash) |i| installable[0..i] else installable;
    const attr_path = if (hash) |i| installable[i + 1 ..] else "";

    const resolved = try resolveFlakeRef(ev, flake_ref);
    defer if (resolved.owned) ev.allocator.free(resolved.ref);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(ev.allocator);

    try out.appendSlice(ev.allocator, "(builtins.getFlake \"");
    try appendNixEscaped(ev.allocator, &out, resolved.ref);
    try out.appendSlice(ev.allocator, "\")");

    var it = std.mem.splitScalar(u8, attr_path, '.');
    while (it.next()) |component| {
        if (component.len == 0) continue;
        try out.appendSlice(ev.allocator, ".\"");
        try appendNixEscaped(ev.allocator, &out, component);
        try out.append(ev.allocator, '"');
    }

    return out.toOwnedSlice(ev.allocator);
}

const ResolvedRef = struct { ref: []const u8, owned: bool };

/// Turn a CLI flakeref into one `builtins.getFlake` accepts. `.` and paths
/// (`/…`, `./…`, `../…`) become an absolute path resolved against the base
/// path; everything else (scheme refs like `github:…`/`path:…`, bare registry
/// names) passes through unchanged for `getFlake`/`parseFlakeRef` to handle.
fn resolveFlakeRef(ev: *Evaluator, flake_ref: []const u8) !ResolvedRef {
    const is_path = flake_ref.len > 0 and (flake_ref[0] == '/' or flake_ref[0] == '.');
    if (!is_path) return .{ .ref = flake_ref, .owned = false };

    const base = ev.base_path orelse return .{ .ref = flake_ref, .owned = false };
    const abs = try std.fs.path.resolve(ev.allocator, &.{ base, flake_ref });
    return .{ .ref = abs, .owned = true };
}

/// Append `text` escaped for a Nix double-quoted string literal. `$` is escaped
/// too so a `${` in a flakeref/attr name can never start an interpolation.
fn appendNixEscaped(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '\\', '"', '$' => try out.append(allocator, '\\'),
            else => {},
        }
        try out.append(allocator, c);
    }
}
