//! `fix completions` — generated shell adapters plus the live completion
//! backend they call.
//!
//! The backend follows Nix's deliberately small protocol: the first line is a
//! completion kind (`normal`, `filenames`, or `attrs`), followed by
//! `value<TAB>description` candidates. Shell-specific code stays tiny while
//! option metadata and Nix evaluation remain in `fix`.

const std = @import("std");
const args = @import("../args.zig");
const command_match = @import("../command_match.zig");
const command_meta = @import("../command_meta.zig");
const eval_support = @import("../eval_support.zig");
const presentation = @import("../presentation.zig");
const setup = @import("../setup.zig");
const engine = @import("expr");
const runtime = @import("runtime");

const Evaluator = engine.Evaluator;
const Value = runtime.Value;

pub const synopsis =
    \\usage: fix completions <bash|zsh|fish>
    \\
    \\generate a shell completion script on stdout. The installed Nix package
    \\places these scripts in each shell's standard vendor completion directory.
;

const bash_script =
    \\# shellcheck shell=bash
    \\_fix_complete() {
    \\    local -a words response
    \\    local cword cur type line completion
    \\    _get_comp_words_by_ref -n ':=&' words cword cur
    \\    mapfile -t response < <("${words[0]}" completions --complete "$cword" -- "${words[@]}" 2>/dev/null)
    \\    type=${response[0]%%$'\t'*}
    \\    if [[ $type == filenames ]]; then
    \\        _filedir
    \\        return
    \\    elif [[ $type == attrs ]]; then
    \\        compopt -o nospace
    \\    fi
    \\    for line in "${response[@]:1}"; do
    \\        completion=${line%%$'\t'*}
    \\        if [[ $cur == *=* ]]; then
    \\            completion=${completion#*=}
    \\        fi
    \\        COMPREPLY+=("$completion")
    \\    done
    \\    __ltrim_colon_completions "$cur"
    \\}
    \\complete -F _fix_complete fix
;

const zsh_script =
    \\#compdef fix
    \\# shellcheck disable=all
    \\_fix() {
    \\    local ifs_bk="$IFS"
    \\    local input=("${(Q)words[@]}")
    \\    IFS=$'\n'
    \\    local response=($("$input[1]" completions --complete "$((CURRENT - 1))" -- "$input[@]" 2>/dev/null))
    \\    IFS="$ifs_bk"
    \\    local type="${response[1]%%$'\t'*}"
    \\    if [[ $type == filenames ]]; then
    \\        _files
    \\        return
    \\    fi
    \\    local -a suggestions suggestions_display compadd_args
    \\    local line suggestion description
    \\    for line in ${response:1}; do
    \\        suggestion="${line%%$'\t'*}"
    \\        suggestions+=("$suggestion")
    \\        if [[ $line == *$'\t'* ]]; then
    \\            description="${line#*$'\t'}"
    \\        else
    \\            description=
    \\        fi
    \\        if [[ -n $description ]]; then
    \\            suggestions_display+=("$suggestion -- $description")
    \\        else
    \\            suggestions_display+=("$suggestion")
    \\        fi
    \\    done
    \\    if [[ $type == attrs ]]; then
    \\        compadd_args+=('-S' '')
    \\    fi
    \\    compadd -J fix "${compadd_args[@]}" -d suggestions_display -a suggestions
    \\}
    \\# When autoloaded from a site-functions directory, run the completion.
    \\# When sourced directly, register it instead of calling compadd outside ZLE.
    \\if [[ $funcstack[1] == _fix ]] || (( ! $+functions[compdef] )); then
    \\    _fix "$@"
    \\else
    \\    compdef _fix fix
    \\fi
;

const fish_script =
    \\function __fix_complete
    \\    set -l fix_args (commandline --current-process --tokenize --cut-at-cursor)
    \\    set -l current_token (commandline --current-token --cut-at-cursor)
    \\    set -l arg_to_complete (count $fix_args)
    \\    command $fix_args[1] completions --complete $arg_to_complete -- $fix_args $current_token
    \\end
    \\
    \\function __fix_accepts_files
    \\    set -l response (__fix_complete 2>/dev/null)
    \\    test "$response[1]" = filenames
    \\end
    \\
    \\function __fix_candidates
    \\    set -l response (__fix_complete 2>/dev/null)
    \\    string collect -- $response[2..-1]
    \\end
    \\
    \\complete --command fix --condition 'not __fix_accepts_files' --no-files
    \\complete --command fix --arguments '(__fix_candidates)'
;

pub fn run(process: @import("../process_context.zig").ProcessContext, init: std.process.Init, args_iter: *std.process.Args.Iterator) !u8 {
    const mode = args_iter.next() orelse {
        std.debug.print("error: choose bash, zsh, or fish\n\n{s}\n", .{synopsis});
        return 2;
    };
    if (presentation.isHelpFlag(mode)) {
        presentation.printHelp(init.io, synopsis);
        return 0;
    }
    if (std.mem.eql(u8, mode, "--complete"))
        return runLive(process.allocator, init, args_iter);

    const script = if (std.mem.eql(u8, mode, "bash"))
        bash_script
    else if (std.mem.eql(u8, mode, "zsh"))
        zsh_script
    else if (std.mem.eql(u8, mode, "fish"))
        fish_script
    else {
        std.debug.print("error: unknown shell '{s}' (expected bash, zsh, or fish)\n\n{s}\n", .{ mode, synopsis });
        return 2;
    };
    if (args_iter.next() != null) {
        std.debug.print("error: completions accepts exactly one shell name\n\n{s}\n", .{synopsis});
        return 2;
    }
    try writeStdout(init.io, script);
    return 0;
}

fn writeStdout(io: std.Io, text: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    try stdout.interface.writeAll(text);
    try stdout.interface.writeByte('\n');
    try stdout.interface.flush();
}

fn runLive(allocator: std.mem.Allocator, init: std.process.Init, args_iter: *std.process.Args.Iterator) !u8 {
    const index_text = args_iter.next() orelse return 2;
    const target = std.fmt.parseInt(usize, index_text, 10) catch return 2;
    const separator = args_iter.next() orelse return 2;
    if (!std.mem.eql(u8, separator, "--")) return 2;

    var words: std.ArrayListUnmanaged([:0]const u8) = .empty;
    defer words.deinit(allocator);
    while (args_iter.next()) |word| try words.append(allocator, word);
    if (words.items.len == 0) return 2;

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    try complete(allocator, init, &stdout.interface, words.items, target);
    try stdout.interface.flush();
    return 0;
}

fn commandEnabled(kind: command_meta.Kind) bool {
    return switch (kind) {
        .thunks => @import("expr").vm.thunks_log_enabled,
        .trace => @import("expr").vm.trace_log.enabled,
        else => true,
    };
}

const AvailableCommands = struct {
    metas: std.ArrayListUnmanaged(*const command_meta.Command) = .empty,
    names: std.ArrayListUnmanaged([]const u8) = .empty,

    fn init(allocator: std.mem.Allocator) !AvailableCommands {
        var result: AvailableCommands = .{};
        errdefer result.deinit(allocator);
        for (&command_meta.table) |*command| {
            if (!commandEnabled(command.kind)) continue;
            try result.metas.append(allocator, command);
            try result.names.append(allocator, command.name);
        }
        return result;
    }

    fn deinit(self: *AvailableCommands, allocator: std.mem.Allocator) void {
        self.metas.deinit(allocator);
        self.names.deinit(allocator);
    }
};

fn complete(allocator: std.mem.Allocator, init: std.process.Init, w: *std.Io.Writer, words: []const [:0]const u8, target: usize) !void {
    const current: []const u8 = if (target < words.len) words[target] else "";
    var available = try AvailableCommands.init(allocator);
    defer available.deinit(allocator);

    if (target <= 1) {
        try w.writeAll("normal\n");
        for (available.metas.items) |command| {
            if (std.mem.startsWith(u8, command.name, current))
                try writeCandidate(w, command.name, command.summary);
        }
        return;
    }

    const command = switch (command_match.resolve(available.names.items, words[1])) {
        .match => |index| available.metas.items[index],
        else => {
            try w.writeAll("normal\n");
            return;
        },
    };

    if (command.kind == .completions) {
        try w.writeAll("normal\n");
        if (target == 2) try writeWordCandidates(w, current, "", &.{ "bash", "fish", "zsh" });
        return;
    }
    const cmd = command.args_cmd orelse {
        try w.writeAll("filenames\n");
        return;
    };

    const scan = scanContext(words, target, cmd);
    if (scan.expected) |expected| {
        try completeHint(allocator, init, w, words, cmd, expected, current);
        return;
    }

    if (!scan.end_options) {
        if (inlineValue(current, cmd, target)) |expected| {
            try completeHint(allocator, init, w, words, cmd, expected, current[expected.value_start..]);
            return;
        }
        if (std.mem.startsWith(u8, current, "-")) {
            try w.writeAll("normal\n");
            try args.writeOptionCompletions(w, cmd, current);
            return;
        }
    }

    if (cmd == .@"switch" and scan.positional_count == 0) {
        try w.writeAll("normal\n");
        try writeWordCandidates(w, current, "", &.{ "boot", "build", "dry-activate", "switch", "test" });
        return;
    }
    if (scan.end_options and (cmd == .run or cmd == .shell)) {
        try w.writeAll("normal\n");
        return;
    }
    try w.writeAll("filenames\n");
}

const Expected = struct {
    hint: args.CompletionHint,
    trigger: usize,
    value_start: usize = 0,
    replacement: []const u8 = "",
};

const Scan = struct {
    expected: ?Expected = null,
    positional_count: usize = 0,
    end_options: bool = false,
};

fn scanContext(words: []const [:0]const u8, target: usize, cmd: args.Cmd) Scan {
    const Pending = struct { option: args.CompletionOption, next: usize, trigger: usize };
    var pending: ?Pending = null;
    var multi: ?Expected = null;
    var result: Scan = .{};
    var index: usize = 2;
    while (index < @min(target, words.len)) : (index += 1) {
        const word: []const u8 = words[index];
        if (pending) |*p| {
            p.next += 1;
            const needed: usize = if (p.option.arity == .req2) 2 else 1;
            if (p.next >= needed) pending = null;
            continue;
        }
        if (multi != null) {
            if (!std.mem.startsWith(u8, word, "-")) continue;
            multi = null;
        }
        if (result.end_options) {
            result.positional_count += 1;
            continue;
        }
        if (std.mem.eql(u8, word, "--")) {
            result.end_options = true;
            continue;
        }

        if (optionToken(word, cmd)) |parsed| {
            switch (parsed.option.arity) {
                .flag, .opt => {},
                .req => {
                    if (!parsed.inline_value) pending = .{ .option = parsed.option, .next = 0, .trigger = index };
                },
                .req2 => pending = .{ .option = parsed.option, .next = if (parsed.inline_value) 1 else 0, .trigger = index },
                .multi => multi = .{ .hint = parsed.option.hints[0], .trigger = index },
            }
            continue;
        }
        result.positional_count += 1;
    }

    if (pending) |p| result.expected = .{
        .hint = p.option.hints[p.next],
        .trigger = p.trigger,
    } else if (multi) |expected| {
        const current: []const u8 = if (target < words.len) words[target] else "";
        if (!std.mem.startsWith(u8, current, "-")) result.expected = expected;
    }
    return result;
}

const ParsedOption = struct {
    option: args.CompletionOption,
    inline_value: bool,
};

fn optionToken(word: []const u8, cmd: args.Cmd) ?ParsedOption {
    if (std.mem.indexOfScalar(u8, word, '=')) |equals| {
        const option = args.completionOption(word[0..equals], cmd) orelse return null;
        return .{ .option = option, .inline_value = true };
    }
    if (args.completionOption(word, cmd)) |option|
        return .{ .option = option, .inline_value = false };
    if (word.len > 2 and word[0] == '-') {
        const option = args.completionOption(word[0..2], cmd) orelse return null;
        if (option.arity == .req) return .{ .option = option, .inline_value = true };
    }
    return null;
}

fn inlineValue(current: []const u8, cmd: args.Cmd, target: usize) ?Expected {
    if (std.mem.indexOfScalar(u8, current, '=')) |equals| {
        const option = args.completionOption(current[0..equals], cmd) orelse return null;
        if (option.arity == .flag or option.arity == .multi) return null;
        return .{
            .hint = option.hints[0],
            .trigger = target,
            .value_start = equals + 1,
            .replacement = current[0 .. equals + 1],
        };
    }
    if (current.len > 2 and current[0] == '-') {
        const option = args.completionOption(current[0..2], cmd) orelse return null;
        if (option.arity != .req) return null;
        return .{
            .hint = option.hints[0],
            .trigger = target,
            .value_start = 2,
            .replacement = current[0..2],
        };
    }
    return null;
}

fn completeHint(
    allocator: std.mem.Allocator,
    init: std.process.Init,
    w: *std.Io.Writer,
    words: []const [:0]const u8,
    cmd: args.Cmd,
    expected: Expected,
    value_prefix: []const u8,
) !void {
    switch (expected.hint) {
        .file => try w.writeAll("filenames\n"),
        .attr => {
            try w.writeAll("attrs\n");
            completeSourceAttrs(allocator, init, w, words, cmd, expected.trigger, value_prefix, expected.replacement) catch {};
        },
        .package => {
            try w.writeAll("attrs\n");
            completePackageAttrs(allocator, init, w, words, cmd, expected.trigger, value_prefix, expected.replacement) catch {};
        },
        .installable => {
            if (std.mem.indexOfScalar(u8, value_prefix, '#') == null) {
                if (value_prefix.len == 0 or value_prefix[0] == '.' or value_prefix[0] == '/') {
                    try w.writeAll("filenames\n");
                } else {
                    try w.writeAll("normal\n");
                    try writeWordCandidates(w, value_prefix, expected.replacement, &.{"nixpkgs#"});
                }
            } else {
                try w.writeAll("attrs\n");
                completeFlakeAttrs(allocator, init, w, words, cmd, expected.trigger, value_prefix, expected.replacement) catch {};
            }
        },
        .color => {
            try w.writeAll("normal\n");
            try writeWordCandidates(w, value_prefix, expected.replacement, &.{ "always", "auto", "never" });
        },
        .experimental_feature => {
            try w.writeAll("normal\n");
            try writeListValueCandidates(w, value_prefix, expected.replacement, &.{ "fetch-tree", "flakes", "pipe-operators" });
        },
        .deprecated_feature => {
            try w.writeAll("normal\n");
            try writeListValueCandidates(w, value_prefix, expected.replacement, &.{ "floor-ceil-corrupt-integers", "nul-bytes" });
        },
        .setting => {
            try w.writeAll("normal\n");
            try writeWordCandidates(w, value_prefix, expected.replacement, &setting_names);
        },
        .max_jobs => {
            try w.writeAll("normal\n");
            try writeWordCandidates(w, value_prefix, expected.replacement, &.{"auto"});
        },
        .hugetlb => {
            try w.writeAll("normal\n");
            try writeWordCandidates(w, value_prefix, expected.replacement, &.{ "auto", "off", "on" });
        },
        .timeline_flows => {
            try w.writeAll("normal\n");
            try writeWordCandidates(w, value_prefix, expected.replacement, &.{ "all", "off" });
        },
        .none => try w.writeAll("normal\n"),
    }
}

const setting_names = [_][]const u8{
    "access-tokens",
    "connect-timeout",
    "cores",
    "download-attempts",
    "download-speed",
    "experimental-features",
    "fallback",
    "flake-registry",
    "http-connections",
    "keep-failed",
    "keep-going",
    "max-call-depth",
    "max-jobs",
    "max-silent-time",
    "netrc-file",
    "ssl-cert-file",
    "stalled-download-timeout",
    "substitute",
    "substituters",
    "tarball-ttl",
    "timeout",
};

fn parseOptionsBefore(
    allocator: std.mem.Allocator,
    words: []const [:0]const u8,
    cmd: args.Cmd,
    stop: usize,
) !args.Options {
    var vector: std.ArrayListUnmanaged([*:0]const u8) = .empty;
    defer vector.deinit(allocator);
    try vector.append(allocator, words[0].ptr);
    for (words[2..@min(stop, words.len)]) |word| try vector.append(allocator, word.ptr);

    var process_args: std.process.Args = .{ .vector = vector.items };
    var iter = try process_args.iterateAllocator(allocator);
    defer iter.deinit();
    _ = iter.next();
    var options = try args.parse(allocator, &iter, null, cmd);
    options.attr = null;
    options.attrs.clearRetainingCapacity();
    options.color = .never;
    options.progress = .disabled;
    return options;
}

fn completeSourceAttrs(
    allocator: std.mem.Allocator,
    init: std.process.Init,
    w: *std.Io.Writer,
    words: []const [:0]const u8,
    cmd: args.Cmd,
    stop: usize,
    prefix: []const u8,
    replacement: []const u8,
) !void {
    var options = try parseOptionsBefore(allocator, words, cmd, stop);
    defer options.deinit(allocator);
    const source_arg = options.source orelse options.defaultSource();
    if (source_arg == .flake) options.experimental_features.insert(.flakes);

    var ev = try Evaluator.init(allocator, 1);
    defer ev.deinit();
    ev.setParallelismToggles(true, true);
    _ = try setup.configure(&ev, init, options);
    const source = try eval_support.getCompletionSource(&ev, init.io, source_arg, options);
    defer source.deinit(ev.hostAllocator());
    const value = try ev.evaluatePathAt(source.text, source.base_path, source.abs_path);
    try writeAttrCandidates(allocator, w, &ev, value, prefix, replacement);
}

fn completePackageAttrs(
    allocator: std.mem.Allocator,
    init: std.process.Init,
    w: *std.Io.Writer,
    words: []const [:0]const u8,
    cmd: args.Cmd,
    stop: usize,
    prefix: []const u8,
    replacement: []const u8,
) !void {
    var options = try parseOptionsBefore(allocator, words, cmd, stop);
    defer options.deinit(allocator);
    var ev = try Evaluator.init(allocator, 1);
    defer ev.deinit();
    ev.setParallelismToggles(true, true);
    _ = try setup.configure(&ev, init, options);
    const value = try ev.evaluate("import <nixpkgs> { }");
    try writeAttrCandidates(allocator, w, &ev, value, prefix, replacement);
}

fn completeFlakeAttrs(
    allocator: std.mem.Allocator,
    init: std.process.Init,
    w: *std.Io.Writer,
    words: []const [:0]const u8,
    cmd: args.Cmd,
    stop: usize,
    prefix: []const u8,
    replacement: []const u8,
) !void {
    const hash = std.mem.indexOfScalar(u8, prefix, '#').?;
    const flake_ref = if (hash == 0) "." else prefix[0..hash];
    const fragment = prefix[hash + 1 ..];
    const parts = attrParts(fragment);

    var options = try parseOptionsBefore(allocator, words, cmd, stop);
    defer options.deinit(allocator);
    options.experimental_features.insert(.flakes);
    var ev = try Evaluator.init(allocator, 1);
    defer ev.deinit();
    ev.setParallelismToggles(true, true);
    _ = try setup.configure(&ev, init, options);

    const source = try eval_support.lowerFlakeCompletion(&ev, flake_ref, parts.parent);
    defer ev.hostAllocator().free(source);
    const value = try ev.evaluate(source);
    const name_prefix = prefix[0 .. hash + 1 + parts.stem_len];
    try writeAttrEntries(allocator, w, &ev, value, parts.partial, replacement, name_prefix);
}

const AttrParts = struct {
    parent: []const u8,
    partial: []const u8,
    stem_len: usize,
};

fn attrParts(prefix: []const u8) AttrParts {
    const dot = std.mem.lastIndexOfScalar(u8, prefix, '.') orelse
        return .{ .parent = "", .partial = prefix, .stem_len = 0 };
    return .{
        .parent = prefix[0..dot],
        .partial = prefix[dot + 1 ..],
        .stem_len = dot + 1,
    };
}

fn writeAttrCandidates(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    ev: *Evaluator,
    root: Value,
    prefix: []const u8,
    replacement: []const u8,
) !void {
    const parts = attrParts(prefix);
    const value = if (parts.parent.len == 0)
        try ev.forceValue(root)
    else
        (try ev.attrPathValue(root, parts.parent)) orelse return;
    try writeAttrEntries(allocator, w, ev, value, parts.partial, replacement, prefix[0..parts.stem_len]);
}

fn writeAttrEntries(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    ev: *Evaluator,
    value: Value,
    partial: []const u8,
    replacement: []const u8,
    name_prefix: []const u8,
) !void {
    const forced = try ev.forceValue(value);
    if (!forced.isAttrs()) return;
    const entries = try ev.tooling().attrs(forced);
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer names.deinit(allocator);
    for (entries) |entry| {
        const name = ev.tooling().internText(entry.name);
        if (std.mem.startsWith(u8, name, partial) and std.mem.indexOfAny(u8, name, "\t\r\n") == null)
            try names.append(allocator, name);
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);
    for (names.items) |name| try w.print("{s}{s}{s}\n", .{ replacement, name_prefix, name });
}

fn writeCandidate(w: *std.Io.Writer, value: []const u8, description: []const u8) !void {
    try w.print("{s}\t{s}\n", .{ value, description });
}

fn writeWordCandidates(w: *std.Io.Writer, prefix: []const u8, replacement: []const u8, candidates: []const []const u8) !void {
    for (candidates) |candidate| {
        if (std.mem.startsWith(u8, candidate, prefix))
            try w.print("{s}{s}\n", .{ replacement, candidate });
    }
}

fn writeListValueCandidates(w: *std.Io.Writer, prefix: []const u8, replacement: []const u8, candidates: []const []const u8) !void {
    const space = std.mem.lastIndexOfScalar(u8, prefix, ' ');
    const head = if (space) |index| prefix[0 .. index + 1] else "";
    const partial = if (space) |index| prefix[index + 1 ..] else prefix;
    for (candidates) |candidate| {
        if (std.mem.startsWith(u8, candidate, partial))
            try w.print("{s}{s}{s}\n", .{ replacement, head, candidate });
    }
}

test "generated adapters call the live backend" {
    try std.testing.expect(std.mem.indexOf(u8, bash_script, "completions --complete") != null);
    try std.testing.expect(std.mem.indexOf(u8, zsh_script, "completions --complete") != null);
    try std.testing.expect(std.mem.indexOf(u8, fish_script, "completions --complete") != null);
    try std.testing.expect(std.mem.indexOf(u8, zsh_script, "compdef _fix fix") != null);
    try std.testing.expect(std.mem.indexOf(u8, zsh_script, "funcstack[1] == _fix") != null);
    try std.testing.expect(std.mem.indexOf(u8, zsh_script, "-d suggestions_display") != null);
    try std.testing.expect(std.mem.indexOf(u8, zsh_script, "suggestion -- $description") != null);
}

test "attribute prefixes retain their completed parent" {
    const nested = attrParts("python3Packages.req");
    try std.testing.expectEqualStrings("python3Packages", nested.parent);
    try std.testing.expectEqualStrings("req", nested.partial);
    try std.testing.expectEqual(@as(usize, "python3Packages.".len), nested.stem_len);

    const root = attrParts("rip");
    try std.testing.expectEqualStrings("", root.parent);
    try std.testing.expectEqualStrings("rip", root.partial);
}

test "completion context tracks required and multi-value options" {
    const attr_words = [_][:0]const u8{ "fix", "eval", "--file", "default.nix", "--attr", "" };
    const attr_scan = scanContext(&attr_words, 5, .eval);
    try std.testing.expectEqual(args.CompletionHint.attr, attr_scan.expected.?.hint);
    try std.testing.expectEqual(@as(usize, 4), attr_scan.expected.?.trigger);

    const package_words = [_][:0]const u8{ "fix", "shell", "-p", "rip" };
    const package_scan = scanContext(&package_words, 3, .shell);
    try std.testing.expectEqual(args.CompletionHint.package, package_scan.expected.?.hint);
}
