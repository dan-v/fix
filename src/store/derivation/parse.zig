//! Parses Nix's `Derive(...)` ATerm text back into a `Drv` — the inverse of
//! `aterm.toATerm`. Aggregate rewriting (`eval-jobs --constituents`) loads a
//! recorded drv this way, appends constituent inputs, and recomputes paths.
//!
//! Every returned slice is allocated with the given allocator and never freed
//! field-by-field — hand in an arena and discard it wholesale.

const std = @import("std");
const types = @import("types.zig");
const drv_mod = @import("drv.zig");

pub const Drv = drv_mod.Drv;

pub fn parseDrv(allocator: std.mem.Allocator, aterm: []const u8) !Drv {
    var p = Parser{ .text = aterm, .allocator = allocator };
    try p.literal("Derive(");

    var outputs: std.ArrayListUnmanaged(types.DrvOutput) = .empty;
    try p.expect('[');
    while (!p.tryConsume(']')) {
        _ = p.tryConsume(',');
        try p.expect('(');
        const name = try p.string();
        try p.expect(',');
        const path = try p.string();
        try p.expect(',');
        const hash_algo = try p.string();
        try p.expect(',');
        const hash = try p.string();
        try p.expect(')');
        try outputs.append(allocator, .{ .name = name, .path = path, .hash_algo = hash_algo, .hash = hash });
    }
    try p.expect(',');

    var inputs: std.ArrayListUnmanaged(types.DrvInput) = .empty;
    try p.expect('[');
    while (!p.tryConsume(']')) {
        _ = p.tryConsume(',');
        try p.expect('(');
        const path = try p.string();
        try p.expect(',');
        const names = try p.stringList();
        try p.expect(')');
        try inputs.append(allocator, .{ .path = path, .outputs = names });
    }
    try p.expect(',');

    const input_srcs = try p.stringList();
    try p.expect(',');
    const system = try p.string();
    try p.expect(',');
    const builder = try p.string();
    try p.expect(',');
    const args = try p.stringList();
    try p.expect(',');

    var env: std.ArrayListUnmanaged(types.EnvVar) = .empty;
    try p.expect('[');
    while (!p.tryConsume(']')) {
        _ = p.tryConsume(',');
        try p.expect('(');
        const name = try p.string();
        try p.expect(',');
        const value = try p.string();
        try p.expect(')');
        try env.append(allocator, .{ .name = name, .value = value });
    }
    try p.expect(')');

    // The ATerm has no name field; Nix recovers it from the `name` env var.
    // A __structuredAttrs derivation keeps its attrs (name included) inside
    // the single `__json` env entry, so the name can be legitimately absent —
    // callers that require one (aggregate rewriting) must check.
    var drv_name: []const u8 = "";
    for (env.items) |entry| {
        if (std.mem.eql(u8, entry.name, "name")) drv_name = entry.value;
    }

    return .{
        .name = drv_name,
        .outputs = try outputs.toOwnedSlice(allocator),
        .input_drvs = try inputs.toOwnedSlice(allocator),
        .input_srcs = input_srcs,
        .system = system,
        .builder = builder,
        .args = args,
        .env = try env.toOwnedSlice(allocator),
    };
}

const Parser = struct {
    text: []const u8,
    allocator: std.mem.Allocator,
    at: usize = 0,

    fn literal(self: *Parser, lit: []const u8) !void {
        if (!std.mem.startsWith(u8, self.text[self.at..], lit)) return error.InvalidDrvAterm;
        self.at += lit.len;
    }

    fn expect(self: *Parser, c: u8) !void {
        if (self.at >= self.text.len or self.text[self.at] != c) return error.InvalidDrvAterm;
        self.at += 1;
    }

    fn tryConsume(self: *Parser, c: u8) bool {
        if (self.at < self.text.len and self.text[self.at] == c) {
            self.at += 1;
            return true;
        }
        return false;
    }

    /// A quoted string, unescaped (`\"` `\\` `\n` `\r` `\t` — the exact set
    /// the renderer escapes). Owned by the parser's allocator.
    fn string(self: *Parser) ![]const u8 {
        try self.expect('"');
        var out: std.ArrayListUnmanaged(u8) = .empty;
        while (self.at < self.text.len) {
            const c = self.text[self.at];
            self.at += 1;
            switch (c) {
                '"' => return out.toOwnedSlice(self.allocator),
                '\\' => {
                    if (self.at >= self.text.len) return error.InvalidDrvAterm;
                    const esc = self.text[self.at];
                    self.at += 1;
                    try out.append(self.allocator, switch (esc) {
                        'n' => '\n',
                        'r' => '\r',
                        't' => '\t',
                        else => esc, // `\"` and `\\` (and anything else, verbatim)
                    });
                },
                else => try out.append(self.allocator, c),
            }
        }
        return error.InvalidDrvAterm;
    }

    fn stringList(self: *Parser) ![]const []const u8 {
        try self.expect('[');
        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        while (!self.tryConsume(']')) {
            _ = self.tryConsume(',');
            try out.append(self.allocator, try self.string());
        }
        return out.toOwnedSlice(self.allocator);
    }
};

test "parse round-trips the renderer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var outputs = [_]types.DrvOutput{.{ .name = "out", .path = "/nix/store/o-x", .hash_algo = "", .hash = "" }};
    var env = [_]types.EnvVar{
        .{ .name = "name", .value = "x" },
        .{ .name = "weird", .value = "line\nquote\"tab\tback\\slash" },
        .{ .name = "out", .value = "/nix/store/o-x" },
    };
    var drv = Drv{
        .name = "x",
        .outputs = &outputs,
        .input_drvs = &.{.{ .path = "/nix/store/a.drv", .outputs = &.{ "dev", "out" } }},
        .input_srcs = &.{"/nix/store/src"},
        .system = "s",
        .builder = "/bin/sh",
        .args = &.{ "-c", ": > $out" },
        .env = &env,
    };
    const rendered = try drv.toATerm(a, false, null);
    var parsed = try parseDrv(a, rendered);
    const rerendered = try parsed.toATerm(a, false, null);
    try std.testing.expectEqualStrings(rendered, rerendered);
    try std.testing.expectEqualStrings("x", parsed.name);
    try std.testing.expectEqualStrings("dev", parsed.input_drvs[0].outputs[0]);
    try std.testing.expectEqualStrings("line\nquote\"tab\tback\\slash", parsed.env[2].value);
}
