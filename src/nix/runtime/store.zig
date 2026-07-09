//! nix-daemon store client: worker-protocol framing (`wire`) and the
//! `DaemonStore` connection. See `store/daemon.zig`.

pub const wire = @import("store/wire.zig");
pub const daemon = @import("store/daemon.zig");

pub const DaemonStore = daemon.DaemonStore;
pub const Trust = daemon.Trust;
pub const default_socket_path = daemon.default_socket_path;
