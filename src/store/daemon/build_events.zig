//! Typed nix-daemon build activity stream.
//!
//! The daemon transport decodes its stderr sideband into these values; higher
//! layers may re-export them without depending on wire framing details.

pub const ActivityKind = enum {
    build,
    substitute,
    post_build_hook,
};

pub const Activity = struct {
    id: u64,
    kind: ActivityKind,
    subject: []const u8,
    detail: []const u8,
};

pub const Progress = struct {
    id: u64,
    done: u64,
    expected: u64,
};

pub const LogKind = enum {
    daemon,
    build,
    post_build,
};

pub const Log = struct {
    activity_id: ?u64,
    kind: LogKind,
    text: []const u8,
};

pub const Event = union(enum) {
    start: Activity,
    stop: u64,
    progress: Progress,
    log: Log,
};

pub const Sink = struct {
    context: *anyopaque,
    emit_fn: *const fn (context: *anyopaque, event: Event) void,

    pub fn emit(self: Sink, event: Event) void {
        self.emit_fn(self.context, event);
    }
};
