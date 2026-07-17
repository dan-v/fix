//! nix-daemon store client: worker-protocol framing (`wire`) and the
//! `DaemonStore` connection. See `store/daemon.zig`.

pub const wire = @import("store/wire.zig");
pub const daemon = @import("store/daemon.zig");
pub const pool = @import("store/pool.zig");
pub const build_events = @import("store/build_events.zig");
pub const build_options = @import("store/build_options.zig");

pub const DaemonStore = daemon.DaemonStore;
pub const BuildEvent = build_events.Event;
pub const BuildSink = build_events.Sink;
pub const BuildMode = build_options.Mode;
pub const BuildSettings = build_options.Settings;
pub const Setting = build_options.Setting;
pub const Trust = daemon.Trust;
pub const default_socket_path = daemon.default_socket_path;
pub const DaemonPool = pool.DaemonPool;

test {
    _ = pool;
    _ = build_events;
    _ = build_options;
}
