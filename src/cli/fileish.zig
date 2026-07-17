//! Legacy nix-instantiate/nix-build "fileish" argument resolution.
//!
//! Every non-expression CLI source passes through here, so commands agree on
//! directories, lookup paths, tarballs, channels, and flake source trees.

const std = @import("std");
const Evaluator = @import("expr").Evaluator;

pub const Kind = enum { stdin, path, lookup, tarball, channel, flake };

pub fn classify(input: []const u8) Kind {
    if (std.mem.eql(u8, input, "-")) return .stdin;
    if (input.len >= 2 and input[0] == '<' and input[input.len - 1] == '>') return .lookup;
    if (std.mem.startsWith(u8, input, "http://") or std.mem.startsWith(u8, input, "https://")) return .tarball;
    if (std.mem.startsWith(u8, input, "channel:")) return .channel;
    if (std.mem.startsWith(u8, input, "flake:")) return .flake;
    return .path;
}

pub fn requiresFlakes(input: []const u8) bool {
    return classify(input) == .flake;
}

pub const Source = struct {
    text: []const u8,
    owned: bool = false,
    abs_path: ?[]const u8 = null,
    base_path: ?[]const u8 = null,

    pub fn deinit(self: Source, allocator: std.mem.Allocator) void {
        if (self.owned) allocator.free(self.text);
        if (self.abs_path) |p| allocator.free(p);
        if (self.base_path) |p| allocator.free(p);
    }
};

/// Resolve and load one fileish argument. Returned file bytes are borrowed
/// from the evaluator's file cache; stdin is owned. Paths and base paths are
/// owned so source positions and relative imports remain tied to this input.
pub fn load(ev: *Evaluator, io: std.Io, input: []const u8) !Source {
    const allocator = ev.hostAllocator();
    if (classify(input) == .stdin) {
        var stdin_buffer: [64 * 1024]u8 = undefined;
        var stdin = std.Io.File.stdin().readerStreaming(io, &stdin_buffer);
        const text = try stdin.interface.allocRemaining(allocator, .limited(128 << 20));
        errdefer allocator.free(text);
        const base = if (ev.basePath()) |p| try allocator.dupe(u8, p) else null;
        return .{ .text = text, .owned = true, .base_path = base };
    }

    var path: []u8 = switch (classify(input)) {
        .stdin => unreachable,
        .path => blk: {
            const resolved = try ev.resolveHostPath(input);
            defer if (resolved.owned) allocator.free(resolved.text);
            break :blk try allocator.dupe(u8, resolved.text);
        },
        .lookup => try ev.resolveLookupPath(input[1 .. input.len - 1]),
        .tarball => try ev.fetchTarballPath(input),
        .channel => blk: {
            const url = try channelUrl(allocator, input["channel:".len..]);
            defer allocator.free(url);
            break :blk try ev.fetchTarballPath(url);
        },
        .flake => try ev.fetchFlakeSourcePath(input["flake:".len..]),
    };
    errdefer allocator.free(path);

    if (try ev.isSourceDirectory(path)) {
        const default_path = try std.fs.path.join(allocator, &.{ path, "default.nix" });
        allocator.free(path);
        path = default_path;
    }

    const text = try ev.readSourceFile(path);
    const dir = std.fs.path.dirname(path) orelse "/";
    const base = try allocator.dupe(u8, dir);
    errdefer allocator.free(base);
    return .{ .text = text, .abs_path = path, .base_path = base };
}

fn channelUrl(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "https://channels.nixos.org/{s}/nixexprs.tar.xz", .{name});
}

test "classify legacy fileish syntax and path disambiguation" {
    try std.testing.expectEqual(Kind.stdin, classify("-"));
    try std.testing.expectEqual(Kind.lookup, classify("<nixpkgs>"));
    try std.testing.expectEqual(Kind.tarball, classify("https://example.test/source.tar.xz"));
    try std.testing.expectEqual(Kind.channel, classify("channel:nixos-unstable"));
    try std.testing.expectEqual(Kind.flake, classify("flake:github:NixOS/nixpkgs"));
    try std.testing.expectEqual(Kind.path, classify("./<nixpkgs>"));
    try std.testing.expectEqual(Kind.path, classify("./channel:local"));
    try std.testing.expectEqual(Kind.path, classify("./flake:local"));

    const url = try channelUrl(std.testing.allocator, "nixos-unstable");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz", url);
}

test "load resolves directories and lookup paths to default.nix" {
    var ev = try Evaluator.init(std.testing.allocator, 1);
    defer ev.deinit();
    try ev.setBasePathFromCurrentPath(std.testing.io);

    const directory = try load(&ev, std.testing.io, "test/fileish");
    defer directory.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.endsWith(u8, directory.abs_path.?, "/test/fileish/default.nix"));
    try std.testing.expect(std.mem.indexOf(u8, directory.text, "relative.nix") != null);

    const nix_path = try std.fmt.allocPrint(std.testing.allocator, "fixture={s}/test/fileish", .{ev.basePath().?});
    defer std.testing.allocator.free(nix_path);
    try ev.setNixPath(nix_path);
    const lookup = try load(&ev, std.testing.io, "<fixture>");
    defer lookup.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(directory.abs_path.?, lookup.abs_path.?);
    try std.testing.expectEqualStrings(directory.text, lookup.text);
}
