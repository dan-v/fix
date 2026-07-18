//! The repl's `:` command table — single source of truth for dispatch
//! (repl.zig), `:?` help rendering, and `:`-completion. Names follow nix
//! repl muscle memory where the commands overlap (:l, :t, :p, :q, :?).

const std = @import("std");

pub const Arg = enum { none, expr, path, opt_expr };

pub const Id = enum {
    help,
    quit,
    load,
    reload,
    type_of,
    print,
    inspect,
    vm,
    env,
    gc,
};

pub const Command = struct {
    id: Id,
    /// All spellings; the first is canonical (shown first in help).
    names: []const []const u8,
    arg: Arg,
    metavar: []const u8 = "",
    help: []const u8,
};

pub const table = [_]Command{
    .{ .id = .help, .names = &.{ ":?", ":help" }, .arg = .none, .help = "show this command table" },
    .{ .id = .quit, .names = &.{ ":q", ":quit", ":exit" }, .arg = .none, .help = "exit the repl (also Ctrl-D on an empty line)" },
    .{ .id = .load, .names = &.{ ":l", ":load" }, .arg = .path, .metavar = "PATH", .help = "evaluate a file and add its attrset bindings to scope" },
    .{ .id = .reload, .names = &.{ ":r", ":reload" }, .arg = .none, .help = "reload all :l-loaded files" },
    .{ .id = .type_of, .names = &.{ ":t", ":type" }, .arg = .expr, .metavar = "EXPR", .help = "show the type of a value (forces to weak head)" },
    .{ .id = .print, .names = &.{ ":p", ":print" }, .arg = .expr, .metavar = "EXPR", .help = "deep-force a value and print it fully" },
    .{ .id = .inspect, .names = &.{ ":i", ":inspect" }, .arg = .expr, .metavar = "EXPR", .help = "inspect a value: kind, thunk state, backing chunk, size" },
    .{ .id = .vm, .names = &.{ ":vm", ":d", ":disasm" }, .arg = .opt_expr, .metavar = "[COMMAND | EXPR]", .help = "explore VM chunks and tables; `:vm help` for commands\n(interactive TUI on a tty; bounded text in bare mode)" },
    .{ .id = .env, .names = &.{":env"}, .arg = .none, .help = "list the current scope bindings" },
    .{ .id = .gc, .names = &.{":gc"}, .arg = .none, .help = "run a garbage collection now and report heap usage" },
};

/// Look a command up by its typed name (e.g. ":t").
pub fn find(name: []const u8) ?*const Command {
    for (&table) |*cmd| {
        for (cmd.names) |n| {
            if (std.mem.eql(u8, n, name)) return cmd;
        }
    }
    return null;
}

/// Render the `:?` help table.
pub fn writeHelp(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\Evaluate a Nix expression, or bind one with `name = expr`. The last
        \\printed value is bound as `it`. Enter continues incomplete input on
        \\a new line; Alt-Enter submits as-is; Tab completes.
        \\
        \\
    );
    const col = 22;
    for (&table) |*cmd| {
        var line_len: usize = 2;
        try w.writeAll("  ");
        for (cmd.names, 0..) |n, i| {
            if (i > 0) {
                try w.writeAll(", ");
                line_len += 2;
            }
            try w.writeAll(n);
            line_len += n.len;
        }
        if (cmd.metavar.len > 0) {
            try w.writeByte(' ');
            try w.writeAll(cmd.metavar);
            line_len += cmd.metavar.len + 1;
        }
        if (line_len + 2 <= col) {
            try w.splatByteAll(' ', col - line_len);
        } else {
            try w.writeByte('\n');
            try w.splatByteAll(' ', col);
        }
        var lines = std.mem.splitScalar(u8, cmd.help, '\n');
        var first = true;
        while (lines.next()) |line| {
            if (!first) {
                try w.writeByte('\n');
                try w.splatByteAll(' ', col);
            }
            try w.writeAll(line);
            first = false;
        }
        try w.writeByte('\n');
    }
}

const testing = std.testing;

test "every alias resolves to its command" {
    for (&table) |*cmd| {
        for (cmd.names) |n| {
            try testing.expectEqual(cmd, find(n).?);
        }
    }
    try testing.expect(find(":nope") == null);
}

test "help renders every command name" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeHelp(&out.writer);
    for (&table) |*cmd| {
        for (cmd.names) |n| {
            try testing.expect(std.mem.indexOf(u8, out.written(), n) != null);
        }
    }
}
