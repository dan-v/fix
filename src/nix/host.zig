//! Host-effect services used by the evaluator and CLI.
//!
//! Filesystem snapshots, fetching, NAR serialization, and nix-daemon access
//! live here rather than in `runtime`, whose boundary is the language value
//! model. The concrete services depend on language primitives, never the VM.

pub const file_cache = @import("host/file_cache.zig");
pub const fetch_cache = @import("host/fetch_cache.zig");
pub const nar = @import("host/nar.zig");
pub const store = @import("host/store.zig");
pub const daemon_runtime = @import("host/daemon_runtime.zig");

pub const FileCache = file_cache.FileCache;
pub const FetchCache = fetch_cache.FetchCache;
pub const DaemonRuntime = daemon_runtime.DaemonRuntime;

test {
    _ = file_cache;
    _ = fetch_cache;
    _ = nar;
    _ = store;
    _ = daemon_runtime;
}
