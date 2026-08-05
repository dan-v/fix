//! Pure command-line context scan for live completion.

const std = @import("std");
const args = @import("../args.zig");

pub const Expected = struct {
    hint: args.CompletionHint,
    trigger: usize,
    value_start: usize = 0,
    replacement: []const u8 = "",
};

pub const Scan = struct {
    expected: ?Expected = null,
    positional_count: usize = 0,
    end_options: bool = false,
};

pub fn scan(words: []const [:0]const u8, target: usize, cmd: args.Cmd) Scan {
    const Pending = struct { option: args.CompletionOption, next: usize, trigger: usize };
    var pending: ?Pending = null;
    var multi: ?Expected = null;
    var result: Scan = .{};
    var index: usize = 2;
    while (index < @min(target, words.len)) : (index += 1) {
        const word: []const u8 = words[index];
        if (pending) |*item| {
            item.next += 1;
            const needed: usize = if (item.option.arity == .req2) 2 else 1;
            if (item.next >= needed) pending = null;
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
                    if (!parsed.inline_value)
                        pending = .{ .option = parsed.option, .next = 0, .trigger = index };
                },
                .req2 => pending = .{
                    .option = parsed.option,
                    .next = if (parsed.inline_value) 1 else 0,
                    .trigger = index,
                },
                .multi => multi = .{ .hint = parsed.option.hints[0], .trigger = index },
            }
            continue;
        }
        result.positional_count += 1;
    }

    if (pending) |item| {
        result.expected = .{
            .hint = item.option.hints[item.next],
            .trigger = item.trigger,
        };
    } else if (multi) |expected| {
        const current: []const u8 = if (target < words.len) words[target] else "";
        if (!std.mem.startsWith(u8, current, "-")) result.expected = expected;
    }
    return result;
}

pub fn inlineValue(current: []const u8, cmd: args.Cmd, target: usize) ?Expected {
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

pub fn parseOptionsBefore(
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
    var iterator = try process_args.iterateAllocator(allocator);
    defer iterator.deinit();
    _ = iterator.next();
    var options = try args.parse(allocator, &iterator, null, cmd, null);
    options.attr = null;
    options.attrs.clearRetainingCapacity();
    options.color = .never;
    options.progress = .disabled;
    return options;
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
