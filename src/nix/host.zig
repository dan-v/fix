//! Compatibility facade for host-effect services used by the evaluator and CLI.
//!
//! Source acquisition is owned by the independent `fetchers` module. Store
//! protocol and daemon runtime remain here until the store-domain extraction.

const fetchers = @import("fetchers");

pub const file_cache = fetchers.file_cache;
pub const fetch_cache = fetchers.fetch_cache;
pub const nar = fetchers.nar;
pub const store = @import("host/store.zig");
pub const daemon_runtime = @import("host/daemon_runtime.zig");

pub const FileCache = fetchers.FileCache;
pub const FetchCache = fetchers.FetchCache;
pub const DaemonRuntime = daemon_runtime.DaemonRuntime;

test {
    _ = file_cache;
    _ = fetch_cache;
    _ = nar;
    _ = store;
    _ = daemon_runtime;
}
