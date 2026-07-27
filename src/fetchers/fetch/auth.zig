//! Owned fetch authentication policy: access tokens and netrc credentials.

const std = @import("std");
const Forge = @import("types.zig").Forge;

const TokenEntry = struct { host: []u8, token: []u8 };
const NetrcEntry = struct { machine: ?[]u8, login: []u8, password: []u8 };

pub const Header = struct {
    name: []u8,
    value: []u8,

    pub fn deinit(self: Header, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.value);
    }
};

pub const Credentials = struct {
    username: []u8,
    password: []u8,

    pub fn deinit(self: Credentials, allocator: std.mem.Allocator) void {
        allocator.free(self.username);
        allocator.free(self.password);
    }
};

pub const Auth = struct {
    allocator: std.mem.Allocator,
    access_tokens: std.ArrayListUnmanaged(TokenEntry) = .empty,
    netrc: std.ArrayListUnmanaged(NetrcEntry) = .empty,

    pub fn init(allocator: std.mem.Allocator) Auth {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Auth) void {
        self.deinitTokens(&self.access_tokens);
        self.deinitNetrc(&self.netrc);
    }

    pub fn setNetrc(self: *Auth, content: []const u8) !void {
        var replacement: std.ArrayListUnmanaged(NetrcEntry) = .empty;
        errdefer self.deinitNetrc(&replacement);
        var it = std.mem.tokenizeAny(u8, content, " \t\r\n");
        var current: ?usize = null;
        while (it.next()) |token| {
            if (std.mem.eql(u8, token, "machine")) {
                const name = it.next() orelse break;
                try replacement.ensureUnusedCapacity(self.allocator, 1);
                const machine = try self.allocator.dupe(u8, name);
                errdefer self.allocator.free(machine);
                const login = try self.allocator.dupe(u8, "");
                errdefer self.allocator.free(login);
                const password = try self.allocator.dupe(u8, "");
                errdefer self.allocator.free(password);
                replacement.appendAssumeCapacity(.{ .machine = machine, .login = login, .password = password });
                current = replacement.items.len - 1;
            } else if (std.mem.eql(u8, token, "default")) {
                try replacement.ensureUnusedCapacity(self.allocator, 1);
                const login = try self.allocator.dupe(u8, "");
                errdefer self.allocator.free(login);
                const password = try self.allocator.dupe(u8, "");
                errdefer self.allocator.free(password);
                replacement.appendAssumeCapacity(.{ .machine = null, .login = login, .password = password });
                current = replacement.items.len - 1;
            } else if (std.mem.eql(u8, token, "login")) {
                const value = it.next() orelse break;
                if (current) |index| {
                    const login = try self.allocator.dupe(u8, value);
                    self.allocator.free(replacement.items[index].login);
                    replacement.items[index].login = login;
                }
            } else if (std.mem.eql(u8, token, "password")) {
                const value = it.next() orelse break;
                if (current) |index| {
                    const password = try self.allocator.dupe(u8, value);
                    self.allocator.free(replacement.items[index].password);
                    replacement.items[index].password = password;
                }
            } else if (std.mem.eql(u8, token, "account") or std.mem.eql(u8, token, "macdef")) {
                _ = it.next();
            }
        }

        self.deinitNetrc(&self.netrc);
        self.netrc = replacement;
    }

    pub fn setAccessTokens(self: *Auth, raw: []const u8) !void {
        var replacement: std.ArrayListUnmanaged(TokenEntry) = .empty;
        errdefer self.deinitTokens(&replacement);
        var it = std.mem.tokenizeAny(u8, raw, " \t");
        while (it.next()) |entry| {
            const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
            const host = entry[0..eq];
            const token = entry[eq + 1 ..];
            if (host.len == 0 or token.len == 0) continue;
            try replacement.ensureUnusedCapacity(self.allocator, 1);
            const owned_host = try self.allocator.dupe(u8, host);
            errdefer self.allocator.free(owned_host);
            const owned_token = try self.allocator.dupe(u8, token);
            errdefer self.allocator.free(owned_token);
            replacement.appendAssumeCapacity(.{ .host = owned_host, .token = owned_token });
        }

        self.deinitTokens(&self.access_tokens);
        self.access_tokens = replacement;
    }

    pub fn tokenFor(self: *const Auth, url: []const u8) ?[]const u8 {
        if (self.access_tokens.items.len == 0) return null;
        const host_path = urlHostPath(url);
        const lookup = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ host_path.host, host_path.path }) catch return null;
        defer self.allocator.free(lookup);

        var best: ?[]const u8 = null;
        var best_len: usize = 0;
        for (self.access_tokens.items) |entry| {
            const matches = std.mem.eql(u8, lookup, entry.host) or
                (lookup.len > entry.host.len and std.mem.startsWith(u8, lookup, entry.host) and lookup[entry.host.len] == '/');
            if (matches and entry.host.len >= best_len) {
                best = entry.token;
                best_len = entry.host.len;
            }
        }
        return best;
    }

    pub fn netrcHeader(self: *const Auth, url: []const u8) !?Header {
        const entry = self.netrcFor(url) orelse return null;
        if (entry.login.len == 0) return null;
        const text = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ entry.login, entry.password });
        defer self.allocator.free(text);
        const encoder = std.base64.standard.Encoder;
        const buffer = try self.allocator.alloc(u8, encoder.calcSize(text.len));
        defer self.allocator.free(buffer);
        return @as(?Header, try headerFormat(self.allocator, "Authorization", "Basic {s}", .{encoder.encode(buffer, text)}));
    }

    pub fn forgeHeader(self: *const Auth, forge: Forge, url: []const u8) !?Header {
        var github_lookup: ?[]u8 = null;
        defer if (github_lookup) |value| self.allocator.free(value);
        const direct = self.tokenFor(url);
        const token = direct orelse token: {
            if (forge != .github or !std.mem.eql(u8, urlHostPath(url).host, "codeload.github.com")) return null;
            github_lookup = try std.fmt.allocPrint(self.allocator, "https://github.com{s}", .{urlHostPath(url).path});
            break :token self.tokenFor(github_lookup.?) orelse return null;
        };
        const header: Header = switch (forge) {
            .github => try headerFormat(self.allocator, "Authorization", "token {s}", .{token}),
            .sourcehut => try headerFormat(self.allocator, "Authorization", "Bearer {s}", .{token}),
            .gitlab => blk: {
                const colon = std.mem.indexOfScalar(u8, token, ':');
                const kind = if (colon) |index| token[0..index] else token;
                const value = if (colon) |index| token[index + 1 ..] else "";
                if (std.mem.eql(u8, kind, "OAuth2"))
                    break :blk try headerFormat(self.allocator, "Authorization", "Bearer {s}", .{value});
                if (std.mem.eql(u8, kind, "PAT"))
                    break :blk try headerCopy(self.allocator, "Private-token", value);
                break :blk try headerCopy(self.allocator, kind, value);
            },
        };
        return header;
    }

    pub fn gitCredentials(self: *const Auth, url: []const u8) !?Credentials {
        if (self.tokenFor(url)) |raw| {
            const colon = std.mem.indexOfScalar(u8, raw, ':');
            const host = urlHostPath(url).host;
            const token = if (colon) |index| token: {
                const kind = raw[0..index];
                break :token if (std.mem.eql(u8, kind, "PAT") or std.mem.eql(u8, kind, "OAuth2")) raw[index + 1 ..] else raw;
            } else raw;
            return @as(?Credentials, try self.ownedCredentials(if (std.mem.indexOf(u8, host, "github") != null) "x-access-token" else "oauth2", token));
        }
        const entry = self.netrcFor(url) orelse return null;
        if (entry.login.len == 0) return null;
        return @as(?Credentials, try self.ownedCredentials(entry.login, entry.password));
    }

    fn ownedCredentials(self: *const Auth, username: []const u8, password: []const u8) !Credentials {
        const owned_username = try self.allocator.dupe(u8, username);
        errdefer self.allocator.free(owned_username);
        return .{
            .username = owned_username,
            .password = try self.allocator.dupe(u8, password),
        };
    }

    fn netrcFor(self: *const Auth, url: []const u8) ?NetrcEntry {
        const host = urlHostPath(url).host;
        var fallback: ?NetrcEntry = null;
        for (self.netrc.items) |entry| {
            if (entry.machine) |machine| {
                if (std.mem.eql(u8, machine, host)) return entry;
            } else if (fallback == null) fallback = entry;
        }
        return fallback;
    }

    fn deinitTokens(self: *Auth, entries: *std.ArrayListUnmanaged(TokenEntry)) void {
        for (entries.items) |entry| {
            self.allocator.free(entry.host);
            self.allocator.free(entry.token);
        }
        entries.deinit(self.allocator);
        entries.* = .empty;
    }

    fn deinitNetrc(self: *Auth, entries: *std.ArrayListUnmanaged(NetrcEntry)) void {
        for (entries.items) |entry| {
            if (entry.machine) |machine| self.allocator.free(machine);
            self.allocator.free(entry.login);
            self.allocator.free(entry.password);
        }
        entries.deinit(self.allocator);
        entries.* = .empty;
    }
};

pub const UrlHostPath = struct { host: []const u8, path: []const u8 };

pub fn urlHostPath(url: []const u8) UrlHostPath {
    var rest = url;
    if (std.mem.indexOf(u8, rest, "://")) |index| rest = rest[index + 3 ..];
    const path_start = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    var authority = rest[0..path_start];
    if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| authority = authority[at + 1 ..];
    if (std.mem.indexOfScalar(u8, authority, ':')) |colon| authority = authority[0..colon];
    return .{ .host = authority, .path = rest[path_start..] };
}

fn headerCopy(allocator: std.mem.Allocator, name: []const u8, value: []const u8) !Header {
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    return .{ .name = owned_name, .value = try allocator.dupe(u8, value) };
}

fn headerFormat(allocator: std.mem.Allocator, name: []const u8, comptime fmt: []const u8, args: anytype) !Header {
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    return .{ .name = owned_name, .value = try std.fmt.allocPrint(allocator, fmt, args) };
}
