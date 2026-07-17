//! Typed nix-daemon build activity stream.
//!
//! The daemon transport decodes its stderr sideband into these values; higher
//! layers may re-export them without depending on wire framing details.

pub const Activity = struct {
    id: u64,
    text: []const u8,
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
