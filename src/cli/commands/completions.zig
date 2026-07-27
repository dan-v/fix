//! `fix completions` — generated shell adapters plus the live completion
//! backend they call.
//!
//! The backend follows Nix's deliberately small protocol: the first line is a
//! completion kind (`normal`, `options`, `filenames`, or `attrs`), followed by
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

const Engine = engine.Engine;
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
    \\    local header="${response[1]#*$'\t'}"
    \\    [[ "$header" == "$response[1]" ]] && header=
    \\    if [[ $type == filenames ]]; then
    \\        _files
    \\        return
    \\    fi
    \\    local -a raw_suggestions raw_displays raw_descriptions option_specs option_matches compdescribe_expl grouped_args grouped_matches grouped_display suggestions descriptions suggestions_display compadd_args
    \\    local line rest suggestion display description combined_display escaped_display escaped_description
    \\    local base_list="$compstate[list]" grouped_list
    \\    local display_width=0 description_width menu_width index option_width=0 candidate_width
    \\    for line in ${response:1}; do
    \\        suggestion="${line%%$'\t'*}"
    \\        raw_suggestions+=("$suggestion")
    \\        display="$suggestion"
    \\        if [[ $line == *$'\t'* ]]; then
    \\            rest="${line#*$'\t'}"
    \\            if [[ $rest == *$'\t'* ]]; then
    \\                display="${rest%%$'\t'*}"
    \\                description="${rest#*$'\t'}"
    \\            else
    \\                description="$rest"
    \\            fi
    \\        else
    \\            description=
    \\        fi
    \\        raw_displays+=("$display")
    \\        raw_descriptions+=("$description")
    \\    done
    \\    if [[ $type == options ]]; then
    \\        for (( index = 1; index <= ${#raw_suggestions}; index++ )); do
    \\            display="${raw_displays[$index]}"
    \\            description="${raw_descriptions[$index]}"
    \\            if [[ ${raw_suggestions[$index]} == -? && ${raw_suggestions[$index]} != -- ]] && (( index < ${#raw_suggestions} )) && [[ ${raw_suggestions[$(( index + 1 ))]} == --* && ${raw_descriptions[$index]} == ${raw_descriptions[$(( index + 1 ))]} ]]; then
    \\                combined_display="${raw_displays[$(( index + 1 ))]}  $display"
    \\                escaped_display="${combined_display//:/\\:}"
    \\                escaped_description="${description//\%/%%}"
    \\                option_specs+=("$escaped_display:$escaped_description")
    \\                option_matches+=("${raw_suggestions[$index]}")
    \\                candidate_width=${#combined_display}
    \\                (( index++ ))
    \\            else
    \\                option_specs+=("${display//:/\\:}:${description//\%/%%}")
    \\                option_matches+=("${raw_suggestions[$index]}")
    \\                candidate_width=${#display}
    \\            fi
    \\            (( candidate_width > option_width )) && option_width=$candidate_width
    \\        done
    \\        zmodload -i zsh/computil
    \\        compdescribe -I "" "$option_width" "-- " compdescribe_expl -g option_specs option_matches -V fix -o nosort
    \\        while compdescribe -g grouped_list grouped_args grouped_matches grouped_display; do
    \\            compstate[list]="$base_list $grouped_list"
    \\            compadd "${grouped_args[@]}" -d grouped_display -a grouped_matches
    \\        done
    \\        return
    \\    fi
    \\    suggestions=("${raw_suggestions[@]}")
    \\    descriptions=("${raw_descriptions[@]}")
    \\    for suggestion in $suggestions; do
    \\        (( ${#suggestion} > display_width )) && display_width=${#suggestion}
    \\    done
    \\    menu_width=${COLUMNS:-100}
    \\    description_width=$(( menu_width - display_width - 4 ))
    \\    for (( index = 1; index <= ${#suggestions}; index++ )); do
    \\        suggestion="${suggestions[$index]}"
    \\        description="${descriptions[$index]}"
    \\        if [[ -n $description ]] && (( description_width > 3 )); then
    \\            if (( ${#description} > description_width )); then
    \\                description="${description[1,$(( description_width - 3 ))]}..."
    \\            fi
    \\            suggestions_display+=("${(r:${display_width}:: :)suggestion} -- $description")
    \\        else
    \\            suggestions_display+=("$suggestion")
    \\        fi
    \\    done
    \\    if [[ $type == attrs ]]; then
    \\        compadd_args+=('-S' '')
    \\    fi
    \\    local -a header_args
    \\    [[ -n "$header" ]] && header_args=(-X "$header")
    \\    compadd -V fix -l "${compadd_args[@]}" "${header_args[@]}" -d suggestions_display -a suggestions
    \\}
    \\# When autoloaded from a site-functions directory, run the completion.
    \\# When sourced directly, register it instead of calling compadd outside ZLE.
    \\if [[ $funcstack[1] == _fix ]] || (( ! $+functions[compdef] )); then
    \\    _fix "$@"
    \\else
    \\    compdef _fix fix
    \\fi
;

const fish_script_prefix =
    \\function __fix_command_is
    \\    set -l fix_args (commandline --current-process --tokenize --cut-at-cursor)
    \\    test (count $fix_args) -ge 2; or return 1
    \\    set -l typed $fix_args[2]
    \\    set -l matches
    \\    for candidate in
;

const fish_script_suffix =
    \\        if string match --quiet -- "$typed*" $candidate
    \\            set --append matches $candidate
    \\        end
    \\    end
    \\    test (count $matches) -eq 1; and test "$matches[1]" = "$argv[1]"
    \\end
    \\
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
    \\    test "$response[1]" = options; and return
    \\    set -l current_token (commandline --current-token --cut-at-cursor)
    \\    if string match --quiet -- '--*=*' $current_token; or string match --quiet --regex -- '^-[^-].+' $current_token
    \\        return
    \\    end
    \\    string collect -- $response[2..-1]
    \\end
    \\
    \\function __fix_option_candidates
    \\    set -l response (__fix_complete 2>/dev/null)
    \\    set -l replacement
    \\    set -l current_token (commandline --current-token --cut-at-cursor)
    \\    if string match --quiet -- '--*=*' $current_token
    \\        set replacement (string replace --regex '=.*$' '=' -- $current_token)
    \\    else if string match --quiet --regex -- '^-[^-].+' $current_token
    \\        set replacement (string sub --length 2 -- $current_token)
    \\    end
    \\    if test "$response[1]" = filenames
    \\        set -l value_prefix $current_token
    \\        if test -n "$replacement"
    \\            set value_prefix (string replace -- "$replacement" '' $current_token)
    \\        end
    \\        __fish_complete_path $value_prefix
    \\        return
    \\    end
    \\    for candidate in $response[2..-1]
    \\        if test -n "$replacement"
    \\            set candidate (string replace -- "$replacement" '' $candidate)
    \\        end
    \\        string collect -- $candidate
    \\    end
    \\end
    \\
    \\complete --command fix --condition 'not __fix_accepts_files' --no-files
    \\complete --command fix --keep-order --arguments '(__fix_candidates)'
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

    if (std.mem.eql(u8, mode, "fish")) {
        if (args_iter.next() != null) {
            std.debug.print("error: completions accepts exactly one shell name\n\n{s}\n", .{synopsis});
            return 2;
        }
        try writeFishScript(init.io);
        return 0;
    }

    const script = if (std.mem.eql(u8, mode, "bash"))
        bash_script
    else if (std.mem.eql(u8, mode, "zsh"))
        zsh_script
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

fn writeFishScript(io: std.Io) !void {
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    try writeFishScriptInner(&stdout.interface);
    try stdout.interface.flush();
}

fn writeFishScriptInner(w: *std.Io.Writer) !void {
    try w.writeAll(fish_script_prefix);
    for (&command_meta.table) |*command| {
        if (commandEnabled(command.kind)) try w.print(" {s}", .{command.name});
    }
    try w.writeByte('\n');
    try w.writeAll(fish_script_suffix);
    try w.writeByte('\n');
    for (&command_meta.table) |*command| {
        if (!commandEnabled(command.kind)) continue;
        if (command.args_cmd) |cmd| try args.writeFishOptionDeclarations(w, cmd, command.name);
    }
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
    if (command.kind == .flake) {
        try completeFlake(allocator, init, w, words, target, current);
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
            try w.writeAll("options\n");
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

const flake_subcommands = [_][]const u8{ "check", "lock", "metadata", "show", "update" };

/// Completions for `fix flake …`. Each context is a single category, labelled
/// with a group header (rendered by zsh; ignored by bash/fish) so subcommands,
/// input names, files, and flags never appear as one undifferentiated list.
fn completeFlake(
    allocator: std.mem.Allocator,
    init: std.process.Init,
    w: *std.Io.Writer,
    words: []const [:0]const u8,
    target: usize,
    current: []const u8,
) !void {
    if (target <= 2) {
        try w.writeAll("normal\tflake subcommand\n");
        try writeWordCandidates(w, current, "", &flake_subcommands);
        return;
    }
    // A flag anywhere → the shared (eval-grammar) option set.
    if (std.mem.startsWith(u8, current, "-")) {
        try w.writeAll("options\n");
        try args.writeOptionCompletions(w, .eval, current);
        return;
    }
    const sub = words[2];
    if (std.mem.eql(u8, sub, "update")) {
        // Positionals are the cwd flake's own input names.
        try w.writeAll("normal\tflake input\n");
        completeFlakeInputNames(allocator, init, w, current) catch {};
        return;
    }
    if (std.mem.eql(u8, sub, "lock")) {
        try w.writeAll("normal\n");
        return;
    }
    // metadata / show / check take a flakeref → offer paths.
    try w.writeAll("filenames\n");
}

/// List the declared input names of the flake in the current directory
/// (`flake.nix`'s `inputs` attrset) — no fetch, no outputs.
fn completeFlakeInputNames(allocator: std.mem.Allocator, init: std.process.Init, w: *std.Io.Writer, prefix: []const u8) !void {
    var ev = try Engine.init(allocator, setup.engineConfig(init, 1, null));
    defer ev.deinit();
    ev.setParallelismToggles(true, true);
    const cwd = try std.process.currentPathAlloc(init.io, allocator);
    defer allocator.free(cwd);
    const expr = try std.fmt.allocPrint(allocator, "(import \"{s}/flake.nix\").inputs or {{}}", .{cwd});
    defer allocator.free(expr);
    const inputs = try ev.evaluate(expr);
    try writeAttrEntries(allocator, w, &ev, inputs, prefix, "", "");
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

    var ev = try Engine.init(allocator, setup.engineConfig(init, 1, null));
    defer ev.deinit();
    ev.setParallelismToggles(true, true);
    _ = try setup.configure(&ev, init, options);
    var source = try eval_support.getCompletionSource(&ev, init.io, source_arg, options);
    defer source.deinit(ev.hostAllocator());
    const value = try ev.evaluatePathAt(source.slice(), source.base_path, source.abs_path);
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
    var ev = try Engine.init(allocator, setup.engineConfig(init, 1, null));
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
    var ev = try Engine.init(allocator, setup.engineConfig(init, 1, null));
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
    ev: *Engine,
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
    ev: *Engine,
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
    try std.testing.expect(std.mem.indexOf(u8, fish_script_suffix, "completions --complete") != null);
    try std.testing.expect(std.mem.indexOf(u8, zsh_script, "compdef _fix fix") != null);
    try std.testing.expect(std.mem.indexOf(u8, zsh_script, "funcstack[1] == _fix") != null);
    try std.testing.expect(std.mem.indexOf(u8, zsh_script, "-d suggestions_display") != null);
    try std.testing.expect(std.mem.indexOf(u8, zsh_script, "menu_width=${COLUMNS:-100}") != null);
    try std.testing.expect(std.mem.indexOf(u8, zsh_script, "(r:${display_width}:: :)suggestion") != null);
    try std.testing.expect(std.mem.indexOf(u8, zsh_script, "compadd -V fix -l") != null);
}

test "zsh groups option aliases and fish registers them natively" {
    try std.testing.expect(std.mem.indexOf(u8, zsh_script, "compdescribe -I") != null);
    try std.testing.expect(std.mem.indexOf(u8, zsh_script, "combined_display") != null);
    try std.testing.expect(std.mem.indexOf(u8, zsh_script, "-g option_specs option_matches -V fix -o nosort") != null);
    try std.testing.expect(std.mem.indexOf(u8, zsh_script, "fix-aliases") == null);

    var buffer: [128 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeFishScriptInner(&writer);
    const script = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, script, "complete --command fix --condition '__fix_command_is eval'") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "--short-option E --long-option expr --exclusive --arguments '(__fix_option_candidates)'") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "--description 'evaluate expression text (repeatable)'") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "test \"$response[1]\" = options; and return") != null);
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

test "flake subcommands complete under a group header, zsh renders it" {
    // The subcommand position lists the subcommands, tagged with a group header.
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const words = [_][:0]const u8{ "fix", "flake", "" };
    try complete(std.testing.allocator, undefined, &w, &words, 2);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "normal\tflake subcommand\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "metadata\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "update\n") != null);

    // A partial subcommand filters the list.
    var buf2: [4096]u8 = undefined;
    var w2 = std.Io.Writer.fixed(&buf2);
    const words2 = [_][:0]const u8{ "fix", "flake", "me" };
    try complete(std.testing.allocator, undefined, &w2, &words2, 2);
    const out2 = w2.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out2, "metadata\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out2, "update\n") == null);

    // The zsh adapter reads the header and passes it to `compadd -X`.
    try std.testing.expect(std.mem.indexOf(u8, zsh_script, "local header=") != null);
    try std.testing.expect(std.mem.indexOf(u8, zsh_script, "header_args=(-X \"$header\")") != null);
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
