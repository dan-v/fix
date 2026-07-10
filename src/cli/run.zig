//! Driving a single evaluation: run the source, write the result, render
//! failures, and load source text.

const std = @import("std");
const render = @import("render.zig");
const args = @import("args.zig");
const derivation_debug = @import("derivation_debug.zig");
const eval = @import("fix").eval;
const Evaluator = eval.Evaluator;
const Value = @import("runtime").value.Value;
const rstore = @import("runtime").store;
const EvaluationMode = args.EvaluationMode;
const SourceArg = args.SourceArg;

/// The build realization mode selected by `--check`/`--repair` (`--check`
/// takes precedence). `--repair`/`--check` require a trusted daemon user.
pub fn buildMode(options: args.Options) rstore.BuildMode {
    if (options.check) return .check;
    if (options.repair) return .repair;
    return .normal;
}

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
    source_path: ?[]const u8,
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

    const result = ev.evaluatePath(source, source_path) catch |err| {
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
    /// True when `text` was freshly allocated on `ev.allocator` (a `--flake`
    /// lowering and/or `-A`/`--arg` wrapping); the caller must free it.
    owned: bool = false,
};

/// The real file path behind a source, when the text is the file's own
/// content (not `--flake`/`-A`/`--arg`-synthesized wrapping) — so evaluation
/// attributes spans and attr positions to the file, like Nix does. Positions
/// only make sense against the original text, hence the `owned` guard.
pub fn sourcePathOf(source: SourceArg, loaded: Source) ?[]const u8 {
    return switch (source) {
        .file => |p| if (loaded.owned) null else p,
        else => null,
    };
}

/// A short human label for the progress "evaluating <label>" node.
pub fn sourceLabel(source: SourceArg) []const u8 {
    return switch (source) {
        .file => |p| std.fs.path.basename(p),
        .expr => "expression",
        .flake => |inst| inst,
    };
}

/// Render a store-op failure (daemon down / daemon error) specially, else fall
/// back to the normal eval-failure trace. Returns exit code 1. Shared by the
/// store-writing subcommands (`instantiate`, `build`).
pub fn storeOrEvalFailure(io: std.Io, use_color: bool, show_trace: bool, ev: *Evaluator, source: []const u8, err: anyerror) !u8 {
    switch (err) {
        error.DaemonError => std.debug.print("error: daemon: {s}\n", .{ev.lastStoreError() orelse "unknown"}),
        error.StoreUnavailable => std.debug.print("error: cannot reach the nix-daemon (is it running?)\n", .{}),
        else => try render.evalFailure(io, use_color, show_trace, ev, source, err),
    }
    return 1;
}

pub fn getSource(ev: *Evaluator, source: SourceArg, options: args.Options) !Source {
    // Load the base source text (borrowed for expr/file, owned for flake).
    const base: Source = switch (source) {
        .expr => |text| .{ .text = text, .owned = false },
        .file => |path| blk: {
            const text = try ev.readSourceFile(path);
            // Resolve the file's relative path literals (`./x`, `import ./y`)
            // against the file's directory, like Nix — not the process cwd.
            try ev.setBasePathToFileDir(path);
            break :blk .{ .text = text, .owned = false };
        },
        .flake => |installable| .{ .text = try lowerFlakeInstallable(ev, installable), .owned = true },
    };

    // Apply `-A`/`--arg`/`--argstr`. When they wrap the text, the base flake
    // lowering (if any) is now embedded in the wrapper, so free it.
    const selected = try applySelectors(ev, base.text, options);
    if (selected.owned and base.owned) ev.allocator.free(base.text);
    return if (selected.owned) selected else base;
}

/// Wrap `base_text` to apply `-A`/`--arg`/`--argstr`, as in `nix-instantiate`:
/// when `--arg`/`--argstr` are given and the value is a function, auto-call it
/// with those args intersected against its formals; then select the `-A`
/// attribute path. Returns owned wrapped text, or `base_text` borrowed when no
/// selector applies.
fn applySelectors(ev: *Evaluator, base_text: []const u8, options: args.Options) !Source {
    const alloc = ev.allocator;
    const has_args = options.arg_defs.items.len > 0;
    // A `-A` with only empty components (`.`/``) selects nothing.
    const has_attr = if (options.attr) |a| std.mem.indexOfNone(u8, a, ".") != null else false;
    if (!has_args and !has_attr) return .{ .text = base_text, .owned = false };

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);

    try out.appendSlice(alloc, "let __fix_top = (");
    try out.appendSlice(alloc, base_text);
    try out.appendSlice(alloc, ");\n");

    // Auto-call a top-level function with `--arg`/`--argstr` args intersected
    // against its formals (as in `nix-instantiate`, so missing formals fall
    // back to their defaults and extra args are dropped). A non-function value
    // passes through unchanged, so plain attrset files still work with `-A`.
    try out.appendSlice(alloc, "    __fix_args = {");
    for (options.arg_defs.items) |a| {
        try out.appendSlice(alloc, " \"");
        try appendNixEscaped(alloc, &out, a.name);
        try out.appendSlice(alloc, "\" = ");
        if (a.is_string) {
            try out.append(alloc, '"');
            try appendNixEscaped(alloc, &out, a.value);
            try out.append(alloc, '"');
        } else {
            try out.append(alloc, '(');
            try out.appendSlice(alloc, a.value);
            try out.append(alloc, ')');
        }
        try out.append(alloc, ';');
    }
    try out.appendSlice(alloc, " };\n    __fix_v = if builtins.isFunction __fix_top" ++
        " then __fix_top (builtins.intersectAttrs (builtins.functionArgs __fix_top) __fix_args)" ++
        " else __fix_top;\n");

    try out.appendSlice(alloc, "in __fix_v");
    if (options.attr) |attr| _ = try appendAttrPathSuffix(alloc, &out, attr);
    return .{ .text = try out.toOwnedSlice(alloc), .owned = true };
}

/// Lower a flake installable `<flakeref>[#<attrpath>]` into a Nix expression
/// `(builtins.getFlake "<ref>").<attrpath>` and hand it to the normal evaluate
/// path. `.` and relative flakerefs resolve against the evaluator's base path
/// (the CLI's cwd); scheme refs (`github:`, `path:`, …) pass through to
/// `getFlake`. The attrpath is dot-split into quoted selections, so component
/// names may contain any character except `.`. The returned text is owned by
/// `ev.allocator` and lives for the rest of the (one-shot) run.
fn lowerFlakeInstallable(ev: *Evaluator, installable: []const u8) ![]const u8 {
    const alloc = ev.allocator;
    const hash = std.mem.indexOfScalar(u8, installable, '#');
    const flake_ref = if (hash) |i| installable[0..i] else installable;
    const attr_path = if (hash) |i| installable[i + 1 ..] else "";

    const resolved = try resolveFlakeRef(ev, flake_ref);
    defer if (resolved.owned) alloc.free(resolved.ref);

    // Build the attr-select suffix (`."a"."b"`) from the fragment.
    var suffix: std.ArrayListUnmanaged(u8) = .empty;
    defer suffix.deinit(alloc);
    const has_attr = (try appendAttrPathSuffix(alloc, &suffix, attr_path)) > 0;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);

    // No attr path: the whole flake.
    if (!has_attr) {
        try out.appendSlice(alloc, "(builtins.getFlake \"");
        try appendNixEscaped(alloc, &out, resolved.ref);
        try out.appendSlice(alloc, "\")");
        return out.toOwnedSlice(alloc);
    }

    // With an attr path, try the `nix build`/`nix eval` installable prefixes —
    // `packages.<system>.<attr>`, then `legacyPackages.<system>.<attr>` (for
    // `nixpkgs#hello`), falling back to the literal `<attr>` (for flake outputs
    // at top level). `or` catches a missing attr at any point in each path.
    try out.appendSlice(alloc, "(let f = builtins.getFlake \"");
    try appendNixEscaped(alloc, &out, resolved.ref);
    try out.appendSlice(alloc, "\"; s = builtins.currentSystem; in f.packages.${s}");
    try out.appendSlice(alloc, suffix.items);
    try out.appendSlice(alloc, " or f.legacyPackages.${s}");
    try out.appendSlice(alloc, suffix.items);
    try out.appendSlice(alloc, " or f");
    try out.appendSlice(alloc, suffix.items);
    try out.appendSlice(alloc, ")");
    return out.toOwnedSlice(alloc);
}

const ResolvedRef = struct { ref: []const u8, owned: bool };

/// Turn a CLI flakeref into one `builtins.getFlake` accepts. Only the
/// CLI-specific bit lives here: `.` and paths (`/…`, `./…`, `../…`) resolve to
/// an absolute path against the base path (the cwd). Everything else — scheme
/// refs (`github:…`, `git+…`) and bare indirect ids (`nixpkgs`) — passes through
/// to getFlake, which resolves indirect ids via the flake registry itself.
fn resolveFlakeRef(ev: *Evaluator, flake_ref: []const u8) !ResolvedRef {
    if (flake_ref.len > 0 and (flake_ref[0] == '/' or flake_ref[0] == '.')) {
        const base = ev.base_path orelse return .{ .ref = flake_ref, .owned = false };
        const abs = try std.fs.path.resolve(ev.allocator, &.{ base, flake_ref });
        return .{ .ref = abs, .owned = true };
    }
    return .{ .ref = flake_ref, .owned = false };
}

/// Append `."a"."b"` selections for the dotted `attr_path` to `out`, each
/// component quoted and escaped so it may contain any character except `.`.
/// Empty components (from `a..b`, a leading/trailing `.`, or a bare `.`) are
/// skipped. Returns the number of components appended.
fn appendAttrPathSuffix(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), attr_path: []const u8) !usize {
    var it = std.mem.splitScalar(u8, attr_path, '.');
    var count: usize = 0;
    while (it.next()) |component| {
        if (component.len == 0) continue;
        count += 1;
        try out.appendSlice(allocator, ".\"");
        try appendNixEscaped(allocator, out, component);
        try out.append(allocator, '"');
    }
    return count;
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
