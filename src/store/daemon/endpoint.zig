//! Daemon endpoint parsing and transport policy.
//!
//! This module turns a store selector into a validated transport target. It
//! deliberately does not open sockets or spawn processes; the client owns
//! those resources after endpoint selection is complete.

const std = @import("std");

pub const default_socket_path = "/nix/var/nix/daemon-socket/socket";
const default_socket_dir = "/nix/var/nix/daemon-socket";

pub const Ssh = struct {
    host: []const u8,
    port: ?[]const u8 = null,
    ssh_key: ?[]const u8 = null,
    compress: bool = false,

    pub const max_command_args = 13;

    /// Build the OpenSSH argv with the same security boundary as Lix's
    /// SSHMaster: a validated destination, transport settings, and `--`
    /// before the remote program. Batch mode prevents store commands from
    /// hanging on an interactive credential prompt.
    pub fn commandArgs(self: Ssh, argv: *[max_command_args][]const u8) []const []const u8 {
        var argc: usize = 0;
        argv[argc] = "ssh";
        argc += 1;
        argv[argc] = self.host;
        argc += 1;
        argv[argc] = "-x";
        argc += 1;
        argv[argc] = "-o";
        argc += 1;
        argv[argc] = "BatchMode=yes";
        argc += 1;
        if (self.compress) {
            argv[argc] = "-C";
            argc += 1;
        }
        if (self.port) |port| {
            argv[argc] = "-p";
            argc += 1;
            argv[argc] = port;
            argc += 1;
        }
        if (self.ssh_key) |key| {
            argv[argc] = "-i";
            argc += 1;
            argv[argc] = key;
            argc += 1;
        }
        argv[argc] = "--";
        argc += 1;
        argv[argc] = "nix-daemon";
        argc += 1;
        argv[argc] = "--stdio";
        argc += 1;
        return argv[0..argc];
    }
};

pub const Tcp = struct {
    host: []const u8,
    port: u16,
};

pub const Unix = struct {
    path: []const u8,
    append_legacy_socket: bool = false,
};

pub const Target = union(enum) {
    unix: Unix,
    tcp: Tcp,
    ssh: Ssh,
};

/// Parse the normalized endpoint stored by RealizationStore. Unlike a Nix
/// store selector, an absolute value here is an explicit Unix socket (including
/// NIX_DAEMON_SOCKET_PATH and test sockets).
pub fn parse(store: []const u8) !Target {
    if (store.len == 0 or std.mem.eql(u8, store, "daemon"))
        return .{ .unix = .{ .path = default_socket_path } };
    if (std.mem.eql(u8, store, "auto") or
        std.mem.eql(u8, store, "local") or
        std.mem.startsWith(u8, store, "local?") or
        std.mem.startsWith(u8, store, "local://") or
        std.mem.startsWith(u8, store, "local-root:"))
        return error.NativeLocalStoreUnsupported;
    if (std.mem.startsWith(u8, store, "ssh-ng://"))
        return .{ .ssh = try parseSsh(store) };
    if (std.mem.startsWith(u8, store, "tcp://"))
        return .{ .tcp = parseTcp(store) orelse return error.InvalidStoreUri };
    if (std.mem.startsWith(u8, store, "unix://"))
        return .{ .unix = try parseUnix(store) };
    if (std.mem.indexOf(u8, store, "://") != null)
        return error.UnsupportedStoreUri;
    return .{ .unix = .{ .path = store } };
}

/// Validate a user-facing store selector. An arbitrary absolute path selects a
/// native local store, not a socket; only the conventional daemon socket path
/// is accepted here. Connection code receives a normalized endpoint and calls
/// `parse` directly.
pub fn validateStoreUri(store: []const u8) !void {
    if (std.fs.path.isAbsolute(store) and
        !std.mem.endsWith(u8, store, "/daemon-socket/socket"))
        return error.NativeLocalStoreUnsupported;
    _ = try parse(store);
}

fn parseSsh(store: []const u8) !Ssh {
    var rest = store["ssh-ng://".len..];
    const query_at = std.mem.indexOfScalar(u8, rest, '?');
    const authority = if (query_at) |q| rest[0..q] else rest;
    if (authority.len == 0 or std.mem.indexOfScalar(u8, authority, '/') != null)
        return error.InvalidStoreUri;

    // OpenSSH treats a leading dash in either the user or host component as
    // an option, even when the combined authority does not begin with one.
    const at = std.mem.lastIndexOfScalar(u8, authority, '@');
    const user = if (at) |i| authority[0..i] else null;
    const host = if (at) |i| authority[i + 1 ..] else authority;
    if (user) |name| {
        if (name.len == 0 or name[0] == '-') return error.InvalidStoreUri;
    }
    if (host.len == 0 or host[0] == '-') return error.InvalidStoreUri;

    var target: Ssh = .{ .host = authority };
    if (query_at) |q| {
        rest = rest[q + 1 ..];
        var fields = std.mem.splitScalar(u8, rest, '&');
        while (fields.next()) |field| {
            if (field.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, field, '=') orelse return error.InvalidStoreUri;
            const name = field[0..eq];
            const value = field[eq + 1 ..];
            if (std.mem.eql(u8, name, "port")) {
                _ = std.fmt.parseInt(u16, value, 10) catch return error.InvalidStoreUri;
                target.port = value;
            } else if (std.mem.eql(u8, name, "ssh-key")) {
                if (value.len == 0) return error.InvalidStoreUri;
                target.ssh_key = value;
            } else if (std.mem.eql(u8, name, "compress")) {
                if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1"))
                    target.compress = true
                else if (!std.mem.eql(u8, value, "false") and !std.mem.eql(u8, value, "0"))
                    return error.InvalidStoreUri;
            } else {
                return error.UnsupportedSshStoreSetting;
            }
        }
    }
    return target;
}

fn parseTcp(store: []const u8) ?Tcp {
    var rest = store["tcp://".len..];
    if (std.mem.indexOfScalar(u8, rest, '?')) |q| rest = rest[0..q];
    if (std.mem.indexOfScalar(u8, rest, '/')) |s| rest = rest[0..s];
    if (rest.len != 0 and rest[0] == '[') {
        const close = std.mem.indexOfScalar(u8, rest, ']') orelse return null;
        const host = rest[1..close];
        const after = rest[close + 1 ..];
        if (after.len < 2 or after[0] != ':') return null;
        const port = std.fmt.parseInt(u16, after[1..], 10) catch return null;
        return if (host.len == 0) null else .{ .host = host, .port = port };
    }
    const colon = std.mem.lastIndexOfScalar(u8, rest, ':') orelse return null;
    const host = rest[0..colon];
    const port = std.fmt.parseInt(u16, rest[colon + 1 ..], 10) catch return null;
    return if (host.len == 0) null else .{ .host = host, .port = port };
}

/// Parse Lix's protocol-selecting Unix store URI. XP-only endpoints are
/// rejected until fix has its own `lix-xp-1` implementation.
fn parseUnix(store: []const u8) !Unix {
    const body = store["unix://".len..];
    const query_at = std.mem.indexOfScalar(u8, body, '?');
    const raw_path = if (query_at) |at| body[0..at] else body;
    const path = if (raw_path.len == 0) default_socket_path else raw_path;
    const query = if (query_at) |at| body[at + 1 ..] else return .{ .path = path };

    var fields = std.mem.splitScalar(u8, query, '&');
    while (fields.next()) |field| {
        if (!std.mem.startsWith(u8, field, "protocol=")) continue;
        const protocols = field["protocol=".len..];
        var has_legacy = false;
        var has_combined = false;
        var has_xp = false;
        var names = std.mem.tokenizeAny(u8, protocols, ", ");
        while (names.next()) |name| {
            if (std.mem.eql(u8, name, "any") or std.mem.eql(u8, name, "legacy"))
                has_legacy = true
            else if (std.mem.eql(u8, name, "legacy-combined"))
                has_combined = true
            else if (std.mem.eql(u8, name, "lix-xp-1"))
                has_xp = true
            else
                return error.UnsupportedDaemonProtocol;
        }
        if (has_legacy) return .{
            .path = if (raw_path.len == 0) default_socket_dir else raw_path,
            .append_legacy_socket = true,
        };
        if (has_combined) return .{ .path = path };
        if (has_xp) return error.UnsupportedLixRpcProtocol;
        return error.UnsupportedDaemonProtocol;
    }
    return .{ .path = path };
}

test "store uri parsing selects transport" {
    try std.testing.expectEqualStrings(default_socket_path, (try parse("")).unix.path);
    try std.testing.expectEqualStrings("/tmp/sock", (try parse("unix:///tmp/sock")).unix.path);
    const legacy = (try parse("unix:///tmp/daemon?protocol=lix-xp-1,legacy")).unix;
    try std.testing.expectEqualStrings("/tmp/daemon", legacy.path);
    try std.testing.expect(legacy.append_legacy_socket);
    const combined = (try parse("unix:///tmp/socket?protocol=legacy-combined")).unix;
    try std.testing.expectEqualStrings("/tmp/socket", combined.path);
    try std.testing.expect(!combined.append_legacy_socket);
    try std.testing.expectError(error.UnsupportedLixRpcProtocol, parse("unix:///tmp/daemon?protocol=lix-xp-1"));
    try std.testing.expectError(error.NativeLocalStoreUnsupported, validateStoreUri("auto"));
    try std.testing.expectError(error.NativeLocalStoreUnsupported, validateStoreUri("local?root=/tmp/store"));
    try std.testing.expectError(error.NativeLocalStoreUnsupported, validateStoreUri("/tmp/chroot"));

    const ssh = (try parse("ssh-ng://user@host?port=2222&ssh-key=/tmp/key&compress=true")).ssh;
    try std.testing.expectEqualStrings("user@host", ssh.host);
    try std.testing.expectEqualStrings("2222", ssh.port.?);
    try std.testing.expectEqualStrings("/tmp/key", ssh.ssh_key.?);
    try std.testing.expect(ssh.compress);
    var ssh_argv: [Ssh.max_command_args][]const u8 = undefined;
    const args = ssh.commandArgs(&ssh_argv);
    const expected_args = [_][]const u8{
        "ssh",  "user@host", "-x",       "-o", "BatchMode=yes", "-C",      "-p",
        "2222", "-i",        "/tmp/key", "--", "nix-daemon",    "--stdio",
    };
    try std.testing.expectEqual(expected_args.len, args.len);
    for (expected_args, args) |expected, actual|
        try std.testing.expectEqualStrings(expected, actual);

    try validateStoreUri("ssh-ng://build.example.com");
    try std.testing.expectError(error.InvalidStoreUri, validateStoreUri("ssh-ng://"));
    try std.testing.expectError(error.InvalidStoreUri, validateStoreUri("ssh-ng://-oProxyCommand=id"));
    try std.testing.expectError(error.InvalidStoreUri, validateStoreUri("ssh-ng://-user@host"));
    try std.testing.expectError(error.InvalidStoreUri, validateStoreUri("ssh-ng://user@-oProxyCommand=id"));
    try std.testing.expectError(error.UnsupportedSshStoreSetting, validateStoreUri("ssh-ng://host?remote-store=local"));
    try std.testing.expectError(error.UnsupportedLixRpcProtocol, validateStoreUri("unix:///tmp/daemon?protocol=lix-xp-1"));
    try validateStoreUri("/tmp/daemon-socket/socket");

    const tcp = (try parse("tcp://build.example.com:1234")).tcp;
    try std.testing.expectEqualStrings("build.example.com", tcp.host);
    try std.testing.expectEqual(@as(u16, 1234), tcp.port);
    const tcp6 = (try parse("tcp://[::1]:9999")).tcp;
    try std.testing.expectEqualStrings("::1", tcp6.host);
    try std.testing.expectEqual(@as(u16, 9999), tcp6.port);
}
