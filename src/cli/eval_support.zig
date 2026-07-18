//! Driving a single evaluation: run the source, write the result, render
//! failures, and load source text.

const std = @import("std");
const render = @import("render.zig");
const args = @import("args.zig");
const fileish = @import("fileish.zig");
const engine = @import("expr");
const runtime = @import("runtime");
const store = @import("store");
const Evaluator = engine.Evaluator;
const Value = runtime.Value;
const EvaluationMode = args.EvaluationMode;
const SourceArg = args.SourceArg;

/// The build realization mode selected by `--check`/`--repair` (`--check`
/// takes precedence). `--repair`/`--check` require a trusted daemon user.
pub fn buildMode(options: args.Options) store.daemon.BuildMode {
    if (options.check) return .check;
    if (options.repair) return .repair;
    return .normal;
}

/// Evaluate `source` and write the result, or render the failure. Returns
/// whether evaluation succeeded.
pub fn evaluateAndWrite(
    io: std.Io,
    mode: EvaluationMode,
    use_color: bool,
    show_trace: bool,
    ev: *Evaluator,
    source: Source,
    label: []const u8,
) !bool {
    // Bracket the whole run so progress state is cleanly scoped across inputs.
    // Values render in the same palette as diagnostics when writing to a tty.
    ev.setValueColor(use_color);
    ev.progressSessionBegin(label);
    defer ev.progressSessionEnd();

    const result = ev.evaluatePathAt(source.text, source.base_path, source.abs_path) catch |err| {
        try render.evalFailure(io, use_color, show_trace, ev, source.text, err);
        return false;
    };

    writeResult(io, mode, ev, result) catch |err| {
        try render.evaluationError(io, use_color, show_trace, ev, source.text, err);
        return false;
    };
    return true;
}

fn writeResult(io: std.Io, mode: EvaluationMode, ev: *Evaluator, result: Value) !void {
    if (mode.strict) try ev.forceDeep(result);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    switch (mode.output) {
        .nix => try ev.writeValue(&stdout.interface, result),
        .raw => try ev.writeRawValue(&stdout.interface, result),
        .json => try ev.writeJsonValue(&stdout.interface, result),
        .xml => try ev.writeXmlValue(&stdout.interface, result),
    }
    if (mode.output != .xml and mode.output != .raw) try stdout.interface.writeByte('\n');
    try stdout.interface.flush();
}

pub const Source = fileish.Source;

pub fn sourceRequiresFlakes(source: SourceArg) bool {
    return switch (source) {
        .flake => true,
        .file => |path| fileish.requiresFlakes(path),
        .expr => false,
    };
}

/// One ordered CLI input after expanding sources × `-A` selectors. The options
/// value borrows all list storage from the command's parsed Options and changes
/// only the legacy single-selector mirror consumed by `getSource`.
pub const SelectedInput = struct {
    source_arg: SourceArg,
    options: args.Options,
};

pub const LoadedInput = struct {
    source_arg: SourceArg,
    source: Source,

    pub fn deinit(self: LoadedInput, ev: *Evaluator) void {
        self.source.deinit(ev.hostAllocator());
    }

    pub fn label(self: LoadedInput) []const u8 {
        return sourceLabel(self.source_arg);
    }
};

/// Shared ordered expansion used by build, eval, and instantiate. Inputs are
/// source-major, with repeated `-A` selectors kept in their command-line order.
pub const InputPlan = struct {
    parsed: args.Options,
    io: std.Io,
    default_source: SourceArg,
    selector_count: usize,

    pub fn init(options: args.Options, io: std.Io) InputPlan {
        return .{
            .parsed = options,
            .io = io,
            .default_source = options.defaultSource(),
            .selector_count = if (options.attrs.items.len == 0) 1 else options.attrs.items.len,
        };
    }

    pub fn count(self: InputPlan) !usize {
        const source_count: usize = if (self.parsed.sources.items.len == 0) 1 else self.parsed.sources.items.len;
        return std.math.mul(usize, source_count, self.selector_count);
    }

    pub fn selected(self: InputPlan, index: usize) SelectedInput {
        const source_index = index / self.selector_count;
        const selector_index = index % self.selector_count;
        const source_arg = if (self.parsed.sources.items.len == 0)
            self.default_source
        else
            self.parsed.sources.items[source_index];
        var input_options = self.parsed;
        input_options.attr = if (self.parsed.attrs.items.len == 0) null else self.parsed.attrs.items[selector_index];
        return .{ .source_arg = source_arg, .options = input_options };
    }

    pub fn validate(self: InputPlan, ev: *Evaluator) !void {
        if (ev.languagePolicy().flakes_enabled) return;
        const input_count = try self.count();
        for (0..input_count) |index| {
            if (sourceRequiresFlakes(self.selected(index).source_arg)) return error.FlakesFeatureRequired;
        }
    }

    pub fn load(self: InputPlan, ev: *Evaluator, index: usize) !LoadedInput {
        const input = self.selected(index);
        return .{
            .source_arg = input.source_arg,
            .source = try getSource(ev, self.io, input.source_arg, input.options),
        };
    }
};

pub fn reportInputReadError(input_count: usize, index: usize, err: anyerror) void {
    if (input_count == 1)
        std.debug.print("error: reading source: {s}\n", .{@errorName(err)})
    else
        std.debug.print("error: reading input {d}: {s}\n", .{ index + 1, @errorName(err) });
}

test "input plan shares ordered source and selector expansion" {
    var options: args.Options = .{};
    defer options.deinit(std.testing.allocator);
    try options.sources.append(std.testing.allocator, .{ .expr = "one" });
    try options.sources.append(std.testing.allocator, .{ .expr = "two" });
    try options.attrs.append(std.testing.allocator, "first");
    try options.attrs.append(std.testing.allocator, "second");

    const plan = InputPlan.init(options, std.testing.io);
    try std.testing.expectEqual(@as(usize, 4), try plan.count());
    const expected_sources = [_][]const u8{ "one", "one", "two", "two" };
    const expected_attrs = [_][]const u8{ "first", "second", "first", "second" };
    for (expected_sources, expected_attrs, 0..) |expected_source, expected_attr, index| {
        const input = plan.selected(index);
        try std.testing.expectEqualStrings(expected_source, input.source_arg.expr);
        try std.testing.expectEqualStrings(expected_attr, input.options.attr.?);
    }
}

/// The real file path behind a source, when the text is the file's own
/// content (not `--flake`/`-A`/`--arg`-synthesized wrapping) — so evaluation
/// attributes spans and attr positions to the file, like Nix does. This is the
/// absolute path (Nix reports absolute paths); null for wrapped/synthetic text.
pub fn sourcePathOf(source: SourceArg, loaded: Source) ?[]const u8 {
    _ = source;
    return loaded.abs_path;
}

/// The source identity used for an evaluation progress session.
pub fn sourceLabel(source: SourceArg) []const u8 {
    return switch (source) {
        .file => |p| p,
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

/// `storeOrEvalFailure` for after `Evaluator.releaseEvalState`: the language
/// heap (diagnostics, trace, intern table) is gone, so a build failure can
/// only render store-side state. Evaluation already succeeded by the time a
/// build runs — there are no eval diagnostics to lose — and the daemon's own
/// message (still owned by the surviving RealizationStore) is the useful part.
pub fn buildFailure(last_store_error: ?[]const u8, err: anyerror) u8 {
    switch (err) {
        error.DaemonError => std.debug.print("error: daemon: {s}\n", .{last_store_error orelse "unknown"}),
        error.StoreUnavailable => std.debug.print("error: cannot reach the nix-daemon (is it running?)\n", .{}),
        else => std.debug.print("error: build failed: {s}\n", .{@errorName(err)}),
    }
    return 1;
}

pub fn getSource(ev: *Evaluator, io: std.Io, source: SourceArg, options: args.Options) !Source {
    const allocator = ev.hostAllocator();
    // Load the base source text (borrowed for expr/file, owned for flake).
    var base: Source = switch (source) {
        .expr => |text| .{ .text = text, .owned = false },
        .file => |path| try fileish.load(ev, io, path),
        .flake => |installable| .{ .text = try lowerFlakeInstallable(ev, installable), .owned = true },
    };

    // If selector wrapping fails, `base` (owned flake text and/or file
    // `abs_path`) would otherwise leak. This only fires on the error path; the
    // success paths below hand `base` off or free it explicitly.
    errdefer base.deinit(allocator);

    // Apply `-A`/`--arg`/`--argstr`. When they wrap the text, the wrapper
    // prefix shifts every byte offset, so the file path no longer describes
    // `text`: drop the whole base (freeing its text and abs_path).
    const selected = try applySelectors(ev, base.text, options);
    if (selected.owned) {
        var wrapped = selected;
        wrapped.base_path = base.base_path;
        base.base_path = null;
        base.deinit(allocator);
        return wrapped;
    }
    return base;
}

/// Wrap `base_text` to apply `-A`/`--arg`/`--argstr`, as in `nix-instantiate`:
/// when `--arg`/`--argstr` are given and the value is a function, auto-call it
/// with those args intersected against its formals; then select the `-A`
/// attribute path. Returns owned wrapped text, or `base_text` borrowed when no
/// selector applies.
fn applySelectors(ev: *Evaluator, base_text: []const u8, options: args.Options) !Source {
    const alloc = ev.hostAllocator();
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
/// the evaluator's host allocator and lives for the rest of the (one-shot) run.
fn lowerFlakeInstallable(ev: *Evaluator, installable: []const u8) ![]const u8 {
    const alloc = ev.hostAllocator();
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
        const base = ev.basePath() orelse return .{ .ref = flake_ref, .owned = false };
        const abs = try std.fs.path.resolve(ev.hostAllocator(), &.{ base, flake_ref });
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
