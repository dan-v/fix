//! Nix-daemon build mode and per-connection settings.

pub const Mode = enum(u64) { normal = 0, repair = 1, check = 2 };

pub const Setting = struct { name: []const u8, value: []const u8 };

pub const Settings = struct {
    keep_failed: bool = false,
    keep_going: bool = false,
    fallback: bool = false,
    verbosity: u64 = 0,
    max_build_jobs: u64 = 1,
    max_silent_time: u64 = 0,
    build_cores: u64 = 0,
    use_substitutes: bool = true,
    overrides: []const Setting = &.{},
};
