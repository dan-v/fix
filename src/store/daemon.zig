//! nix-daemon client facade: protocol framing, connections, pooling, build
//! events, and settings.

pub const wire = @import("daemon/wire.zig");
pub const endpoint = @import("daemon/endpoint.zig");
pub const client = @import("daemon/client.zig");
pub const pool = @import("daemon/pool.zig");
pub const build_events = @import("daemon/build_events.zig");
pub const settings = @import("daemon/settings.zig");

pub const DaemonStore = client.DaemonStore;
pub const BuildEvent = build_events.Event;
pub const BuildSink = build_events.Sink;
pub const BuildMode = settings.Mode;
pub const BuildSettings = settings.Settings;
pub const Setting = settings.Setting;
pub const MissingPlan = client.MissingPlan;
pub const default_socket_path = endpoint.default_socket_path;
pub const validateStoreUri = endpoint.validateStoreUri;
pub const DaemonPool = pool.DaemonPool;

test {
    _ = pool;
    _ = endpoint;
    _ = build_events;
    _ = settings;
}
