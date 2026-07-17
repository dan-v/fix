//! Compatibility facade for host-effect services used by the evaluator and CLI.
//!
//! Source acquisition and store behavior are owned by independent modules.

const fetchers = @import("fetchers");
const store_domain = @import("store");

pub const file_cache = store_domain.file_cache;
pub const fetch_cache = fetchers.fetch_cache;
pub const nar = store_domain.nar;
pub const store = store_domain.daemon;
pub const daemon_runtime = store_domain.daemon_runtime;

pub const FileCache = store_domain.FileCache;
pub const FetchCache = fetchers.FetchCache;
pub const DaemonRuntime = store_domain.DaemonRuntime;

test {
    _ = file_cache;
    _ = fetch_cache;
    _ = nar;
    _ = store;
    _ = daemon_runtime;
}
