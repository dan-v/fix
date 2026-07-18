//! Runtime-gated structured observability.
//!
//! Producers describe operations locally with a static `SpanSpec`; consumers
//! decide whether those operations become terminal records, a profile, both,
//! or nothing. A disabled or verbosity-filtered span returns before reading a
//! clock, copying a subject, taking a lock, or calling through the sink.

pub const Level = u8;

pub const SpanSpec = struct {
    category: []const u8,
    name: []const u8,
    begin_verb: []const u8,
    finish_verb: []const u8,
    begin_level: Level = 1,
    finish_level: Level = 0,
    profile: bool = true,
};

pub const EventSpec = struct {
    category: []const u8,
    name: []const u8,
    verb: []const u8,
    level: Level = 0,
    profile: bool = true,
};

pub const Subject = union(enum) {
    none,
    text: []const u8,
    path: []const u8,
    url: []const u8,
    source: Source,

    pub const Source = struct {
        file: u32,
        line: u32 = 0,
    };

    pub fn bytes(self: Subject) []const u8 {
        return switch (self) {
            .none, .source => "",
            .text, .path, .url => |value| value,
        };
    }
};

pub const Details = struct {
    subject: Subject = .none,
    destination: Subject = .none,
};

pub const Unit = enum { none, items, bytes, nanoseconds };

pub const Metric = struct {
    name: []const u8,
    value: Value,
    unit: Unit = .none,

    pub const Value = union(enum) {
        unsigned: u64,
        signed: i64,
        float: f64,
        text: []const u8,
    };
};

pub const Finish = struct {
    details: ?Details = null,
    metrics: []const Metric = &.{},
};

pub const Track = union(enum) {
    current,
    worker: u16,
    fiber: u32,
    activity: u64,
};

pub const Interest = struct {
    log_begin: bool = false,
    log_finish: bool = false,
    profile: bool = false,
    updates: bool = false,

    pub fn any(self: Interest) bool {
        return self.log_begin or self.log_finish or self.profile;
    }
};

pub const Sink = struct {
    context: *anyopaque,
    begin_fn: *const fn (*anyopaque, *const SpanSpec, Details, Track, Interest) usize,
    finish_fn: *const fn (*anyopaque, usize, *const SpanSpec, Details, Track, Interest, Finish, bool) void,
    update_fn: *const fn (*anyopaque, usize, *const SpanSpec, Interest, []const Metric) void,
    event_fn: *const fn (*anyopaque, *const EventSpec, Details, Track, Interest, []const Metric) void,
};

/// A cheap, copyable capability. The sink it references must outlive all spans
/// created from the handle.
pub const Observer = struct {
    sink: ?Sink = null,
    verbosity: Level = 0,
    log_enabled: bool = false,
    profile_enabled: bool = false,
    capture_updates: bool = false,

    pub fn begin(self: Observer, spec: *const SpanSpec, details: Details) Span {
        return self.beginOn(spec, details, .current);
    }

    pub inline fn beginOn(self: Observer, spec: *const SpanSpec, details: Details, track: Track) Span {
        const sink = self.sink orelse return .{};
        const interest: Interest = .{
            .log_begin = self.log_enabled and self.verbosity >= spec.begin_level,
            .log_finish = self.log_enabled and self.verbosity >= spec.finish_level,
            .profile = self.profile_enabled and spec.profile,
            .updates = self.capture_updates,
        };
        if (!interest.any()) return .{};
        const token = if (interest.log_begin or interest.profile)
            sink.begin_fn(sink.context, spec, details, track, interest)
        else
            0;
        return .{
            .sink = sink,
            .spec = spec,
            .details = details,
            .track = track,
            .interest = interest,
            .token = token,
        };
    }

    pub fn event(self: Observer, spec: *const EventSpec, details: Details, metrics: []const Metric) void {
        const sink = self.sink orelse return;
        const interest: Interest = .{
            .log_finish = self.log_enabled and self.verbosity >= spec.level,
            .profile = self.profile_enabled and spec.profile,
        };
        if (!interest.any()) return;
        sink.event_fn(sink.context, spec, details, .current, interest, metrics);
    }
};

/// A span is explicitly finished on success. `cancel` closes profiling state
/// without printing a misleading success record and is intended for `defer`.
pub const Span = struct {
    sink: ?Sink = null,
    spec: *const SpanSpec = undefined,
    details: Details = .{},
    track: Track = .current,
    interest: Interest = .{},
    token: usize = 0,

    pub fn finish(self: *Span, completion: Finish) void {
        self.close(completion, true);
    }

    pub fn cancel(self: *Span) void {
        self.close(.{}, false);
    }

    pub fn update(self: *const Span, metrics: []const Metric) void {
        const sink = self.sink orelse return;
        if (!self.interest.updates) return;
        sink.update_fn(sink.context, self.token, self.spec, self.interest, metrics);
    }

    pub fn active(self: *const Span) bool {
        return self.sink != null;
    }

    fn close(self: *Span, completion: Finish, success: bool) void {
        const sink = self.sink orelse return;
        self.sink = null;
        sink.finish_fn(
            sink.context,
            self.token,
            self.spec,
            self.details,
            self.track,
            self.interest,
            completion,
            success,
        );
    }
};

test "verbosity-filtered spans do not enter the sink" {
    const Recorder = struct {
        begins: usize = 0,
        finishes: usize = 0,

        fn sink(self: *@This()) Sink {
            return .{
                .context = self,
                .begin_fn = begin,
                .finish_fn = finish,
                .update_fn = update,
                .event_fn = event,
            };
        }

        fn begin(raw: *anyopaque, _: *const SpanSpec, _: Details, _: Track, _: Interest) usize {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.begins += 1;
            return 1;
        }

        fn finish(raw: *anyopaque, _: usize, _: *const SpanSpec, _: Details, _: Track, _: Interest, _: Finish, success: bool) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (success) self.finishes += 1;
        }

        fn update(_: *anyopaque, _: usize, _: *const SpanSpec, _: Interest, _: []const Metric) void {}
        fn event(_: *anyopaque, _: *const EventSpec, _: Details, _: Track, _: Interest, _: []const Metric) void {}
    };

    const spec: SpanSpec = .{
        .category = "eval",
        .name = "parse",
        .begin_verb = "parsing",
        .finish_verb = "parsed",
        .begin_level = 3,
        .finish_level = 2,
    };
    var recorder: Recorder = .{};
    const hidden: Observer = .{ .sink = recorder.sink(), .log_enabled = true, .verbosity = 1 };
    var hidden_span = hidden.begin(&spec, .{});
    hidden_span.finish(.{});
    try @import("std").testing.expectEqual(@as(usize, 0), recorder.begins);
    try @import("std").testing.expectEqual(@as(usize, 0), recorder.finishes);

    const completions: Observer = .{ .sink = recorder.sink(), .log_enabled = true, .verbosity = 2 };
    var completion_span = completions.begin(&spec, .{});
    defer completion_span.cancel();
    try @import("std").testing.expectEqual(@as(usize, 0), recorder.begins);
    completion_span.finish(.{});
    try @import("std").testing.expectEqual(@as(usize, 1), recorder.finishes);
}
