//! User-facing top-level command metadata, kept in display/completion order.

const args = @import("args.zig");

pub const Kind = enum {
    build,
    completions,
    disasm,
    eval,
    instantiate,
    parse,
    repl,
    run,
    shell,
    @"switch",
    thunks,
    trace,
};

pub const Command = struct {
    kind: Kind,
    name: []const u8,
    summary: []const u8,
    args_cmd: ?args.Cmd,
};

pub const table = [_]Command{
    .{ .kind = .build, .name = "build", .summary = "evaluate to a derivation, build its outputs, and link ./result", .args_cmd = .build },
    .{ .kind = .completions, .name = "completions", .summary = "generate shell completions for bash, zsh, or fish", .args_cmd = null },
    .{ .kind = .disasm, .name = "disasm", .summary = "disassemble compiled bytecode for an expression", .args_cmd = .disasm },
    .{ .kind = .eval, .name = "eval", .summary = "evaluate an expression, file, or flake output and print the value", .args_cmd = .eval },
    .{ .kind = .instantiate, .name = "instantiate", .summary = "evaluate to a derivation and add its .drv closure to the store", .args_cmd = .instantiate },
    .{ .kind = .parse, .name = "parse", .summary = "parse an expression and print its AST as JSON", .args_cmd = .parse },
    .{ .kind = .repl, .name = "repl", .summary = "start an interactive read-eval-print loop", .args_cmd = .repl },
    .{ .kind = .run, .name = "run", .summary = "build a derivation and run a program from its output", .args_cmd = .run },
    .{ .kind = .shell, .name = "shell", .summary = "build a derivation and open a shell with its bin/ on PATH", .args_cmd = .shell },
    .{ .kind = .@"switch", .name = "switch", .summary = "build and activate a NixOS/nix-darwin/home-manager configuration", .args_cmd = .@"switch" },
    .{ .kind = .thunks, .name = "thunks", .summary = "diff thunks-logs to find divergent resolutions", .args_cmd = null },
    .{ .kind = .trace, .name = "trace", .summary = "work with binary VM trace files", .args_cmd = null },
};

pub fn get(comptime kind: Kind) Command {
    inline for (table) |command| {
        if (command.kind == kind) return command;
    }
    unreachable;
}

test "command table is alphabetized" {
    const std = @import("std");
    for (table[1..], table[0 .. table.len - 1]) |command, previous| {
        try std.testing.expect(std.mem.lessThan(u8, previous.name, command.name));
    }
}
