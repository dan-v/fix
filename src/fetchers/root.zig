//! Nix source acquisition: filesystem snapshots, remote-source caching,
//! provider conventions, transports, and NAR serialization of fetched trees.

const store = @import("store");

pub const file_cache = store.file_cache;
pub const fetch_cache = @import("fetch_cache.zig");
pub const forge = @import("forge.zig");
pub const nar = store.nar;
pub const curl_transport = @import("curl_transport.zig");
pub const git_transport = @import("git_transport.zig");

pub const FileCache = store.FileCache;
pub const FetchCache = fetch_cache.FetchCache;

test {
    _ = FileCache;
    _ = FetchCache;
    _ = forge;
    _ = nar;
    _ = curl_transport;
    _ = git_transport;
}
