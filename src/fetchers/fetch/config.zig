//! Borrowed initialization values for `FetchService`.

const std = @import("std");

pub const Config = struct {
    io: ?std.Io = null,
    environment: ?*const std.process.Environ.Map = null,
    cache_root: ?[]const u8 = null,
    max_connections: u32 = 0,
    download_attempts: u32 = 5,
    tarball_ttl: u32 = 3600,
    connect_timeout_seconds: u32 = 15,
    stalled_timeout_seconds: u32 = 300,
    download_speed_kib: u64 = 0,
    ssl_cert_file: ?[]const u8 = null,
    flake_registry_url: ?[]const u8 = null,
    access_tokens: ?[]const u8 = null,
    netrc: ?[]const u8 = null,
};
