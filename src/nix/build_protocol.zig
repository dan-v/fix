//! Stable build-session protocol shared by the public facade, realization,
//! daemon transport, and CLI.  The daemon decodes its wire stream into these
//! domain events; consumers never need to import host protocol internals.

pub const Mode = enum(u64) { normal = 0, repair = 1, check = 2 };

pub const Activity = struct {
    id: u64,
    text: []const u8,
};

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

pub const Progress = struct {
    id: u64,
    done: u64,
    expected: u64,
};

pub const Event = union(enum) {
    start: Activity,
    stop: u64,
    progress: Progress,
    log: []const u8,
};

pub const Sink = struct {
    context: *anyopaque,
    emit_fn: *const fn (context: *anyopaque, event: Event) void,

    pub fn emit(self: Sink, event: Event) void {
        self.emit_fn(self.context, event);
    }
};
