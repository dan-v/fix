//! Evaluator-scoped Perfetto recording for structured observations.
//!
//! Producers use `base.observ`; this recorder is only one possible sink. It
//! reserves fixed event/name buffers up front, so recording never allocates or
//! takes a global lock. A disabled observer never reaches this code.

const std = @import("std");
const observ = @import("base").observ;
const clock = @import("base").clock;
const worker_id = @import("base").worker_id;
const InternTable = @import("runtime").intern.InternTable;

const Kind = enum(u8) { span, instant, counter, flow_out, flow_in };

const Text = struct {
    off: u32 = 0,
    len: u32 = 0,
};

const Event = struct {
    ts_ns: u64,
    dur_ns: u64 = 0,
    tid: u16,
    kind: Kind,
    category: []const u8,
    name: []const u8,
    subject: Text = .{},
    args: Text = .{},
    flow_id: u64 = 0,
    complete: bool = false,
};

pub const Recorder = struct {
    allocator: std.mem.Allocator,
    intern: *const InternTable,
    worker_count: usize,
    start_ns: u64,
    source: []const u8 = "",
    events: []Event,
    event_len: std.atomic.Value(usize) = .init(0),
    dropped_events: std.atomic.Value(u64) = .init(0),
    names: []u8,
    name_len: std.atomic.Value(usize) = .init(0),
    dropped_names: std.atomic.Value(u64) = .init(0),
    next_flow_id: std.atomic.Value(u64) = .init(1),
    flow_sample: u32 = 1,
    last_sample_ns: std.atomic.Value(u64) = .init(0),
    active: std.atomic.Value(bool) = .init(true),

    pub fn init(allocator: std.mem.Allocator, worker_count: usize, event_cap: usize, intern: *const InternTable) !Recorder {
        const events = try allocator.alloc(Event, event_cap);
        errdefer allocator.free(events);
        const names = try allocator.alloc(u8, 8 << 20);
        return .{
            .allocator = allocator,
            .intern = intern,
            .worker_count = worker_count,
            .start_ns = clock.monotonicNs(),
            .events = events,
            .names = names,
        };
    }

    pub fn deinit(self: *Recorder) void {
        self.allocator.free(self.events);
        self.allocator.free(self.names);
        self.events = &.{};
        self.names = &.{};
        self.active.store(false, .release);
    }

    pub fn setSource(self: *Recorder, source: []const u8) void {
        self.source = source;
    }

    pub fn setFlowSample(self: *Recorder, sample: u32) void {
        self.flow_sample = sample;
    }

    pub fn begin(self: *Recorder, spec: *const observ.SpanSpec, details: observ.Details, track: observ.Track) usize {
        const index = self.reserveEvent() orelse return 0;
        const subject = self.storeSubject(details.subject);
        self.events[index] = .{
            .ts_ns = clock.monotonicNs(),
            .tid = trackId(track),
            .kind = .span,
            .category = spec.category,
            .name = spec.name,
            .subject = subject,
        };
        return index + 1;
    }

    pub fn finish(self: *Recorder, token: usize, spec: *const observ.SpanSpec, completion: observ.Finish, success: bool) void {
        if (token == 0) return;
        const index = token - 1;
        if (index >= @min(self.event_len.load(.monotonic), self.events.len)) return;
        const now = clock.monotonicNs();
        const event = &self.events[index];
        event.dur_ns = now -| event.ts_ns;
        if (completion.details) |details| event.subject = self.storeSubject(details.subject);
        event.args = self.formatArgs(spec.name, completion.details, completion.metrics, success);
        event.complete = true;
    }

    pub fn update(self: *Recorder, token: usize, spec: *const observ.SpanSpec, metrics: []const observ.Metric) void {
        if (token == 0) return;
        const index = token - 1;
        if (index >= @min(self.event_len.load(.monotonic), self.events.len)) return;
        self.events[index].args = self.formatArgs(spec.name, null, metrics, true);
    }

    pub fn instant(self: *Recorder, spec: *const observ.EventSpec, details: observ.Details, track: observ.Track, metrics: []const observ.Metric) void {
        const index = self.reserveEvent() orelse return;
        const subject = self.storeSubject(details.subject);
        self.events[index] = .{
            .ts_ns = clock.monotonicNs(),
            .tid = trackId(track),
            .kind = .instant,
            .category = spec.category,
            .name = spec.name,
            .subject = subject,
            .args = self.formatArgs(spec.name, details, metrics, true),
            .complete = true,
        };
    }

    pub fn counter(self: *Recorder, spec: *const observ.CounterSpec, track: observ.Track, metrics: []const observ.Metric) void {
        const index = self.reserveEvent() orelse return;
        self.events[index] = .{
            .ts_ns = clock.monotonicNs(),
            .tid = trackId(track),
            .kind = .counter,
            .category = spec.category,
            .name = spec.name,
            .args = self.formatArgs("", null, metrics, true),
            .complete = true,
        };
    }

    pub fn nextFlowId(self: *Recorder) u64 {
        return self.next_flow_id.fetchAdd(1, .monotonic);
    }

    pub fn flow(self: *Recorder, spec: *const observ.FlowSpec, id: u64, phase: observ.FlowPhase, track: observ.Track, at_ns: u64) void {
        if (id == 0 or self.flow_sample == 0) return;
        if (self.flow_sample > 1 and id % self.flow_sample != 0) return;
        const index = self.reserveEvent() orelse return;
        self.events[index] = .{
            .ts_ns = if (at_ns == 0) clock.monotonicNs() else at_ns,
            .tid = trackId(track),
            .kind = if (phase == .out) .flow_out else .flow_in,
            .category = spec.category,
            .name = spec.name,
            .flow_id = id,
            .complete = true,
        };
    }

    pub fn shouldSample(self: *Recorder, min_gap_ns: u64) bool {
        const now = clock.monotonicNs();
        const last = self.last_sample_ns.load(.monotonic);
        if (now < last + min_gap_ns) return false;
        return self.last_sample_ns.cmpxchgStrong(last, now, .monotonic, .monotonic) == null;
    }

    fn reserveEvent(self: *Recorder) ?usize {
        if (!self.active.load(.acquire)) return null;
        const index = self.event_len.fetchAdd(1, .monotonic);
        if (index < self.events.len) return index;
        _ = self.dropped_events.fetchAdd(1, .monotonic);
        return null;
    }

    fn storeText(self: *Recorder, bytes: []const u8) Text {
        if (bytes.len == 0) return .{};
        const offset = self.name_len.fetchAdd(bytes.len, .monotonic);
        if (offset + bytes.len > self.names.len) {
            _ = self.dropped_names.fetchAdd(1, .monotonic);
            return .{};
        }
        @memcpy(self.names[offset..][0..bytes.len], bytes);
        return .{ .off = @intCast(offset), .len = @intCast(bytes.len) };
    }

    fn storeSubject(self: *Recorder, subject: observ.Subject) Text {
        return switch (subject) {
            .none => .{},
            .text, .path, .url => |bytes| self.storeText(bytes),
            .source => |source| blk: {
                if (source.file == 0) break :blk .{};
                const path = self.intern.get(source.file);
                const base = std.fs.path.basename(path);
                const directory = std.fs.path.basename(std.fs.path.dirname(path) orelse "");
                var buffer: [512]u8 = undefined;
                const label = std.fmt.bufPrint(&buffer, "{s}/{s}:{d}", .{ directory, base, source.line }) catch base;
                break :blk self.storeText(label);
            },
        };
    }

    fn formatArgs(self: *Recorder, operation: []const u8, details: ?observ.Details, metrics: []const observ.Metric, success: bool) Text {
        var buffer: [2048]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        var any = false;
        if (operation.len != 0) {
            writeFieldName(&writer, "operation", &any) catch return .{};
            writeJsonString(&writer, operation) catch return .{};
        }
        if (details) |value| switch (value.destination) {
            .none, .source => {},
            .text, .path, .url => |destination| {
                writeFieldName(&writer, "destination", &any) catch return .{};
                writeJsonString(&writer, destination) catch return .{};
            },
        };
        for (metrics) |metric| {
            writeFieldName(&writer, metric.name, &any) catch return .{};
            switch (metric.value) {
                .unsigned => |value| writer.print("{d}", .{value}) catch return .{},
                .signed => |value| writer.print("{d}", .{value}) catch return .{},
                .float => |value| writer.print("{d}", .{value}) catch return .{},
                .text => |value| writeJsonString(&writer, value) catch return .{},
            }
        }
        if (!success) {
            writeFieldName(&writer, "success", &any) catch return .{};
            writer.writeAll("false") catch return .{};
        }
        return self.storeText(buffer[0..writer.end]);
    }

    pub fn dump(self: *Recorder, io: std.Io, path: []const u8) void {
        if (!self.active.swap(false, .acq_rel)) return;
        self.dumpImpl(io, path) catch |err| {
            std.debug.print("timeline: failed to write {s}: {s}\n", .{ path, @errorName(err) });
        };
    }

    fn dumpImpl(self: *Recorder, io: std.Io, path: []const u8) !void {
        const reserved = @min(self.event_len.load(.monotonic), self.events.len);
        var count: usize = 0;
        for (self.events[0..reserved]) |event| {
            if (!event.complete) continue;
            self.events[count] = event;
            count += 1;
        }
        std.mem.sort(Event, self.events[0..count], {}, struct {
            fn less(_: void, a: Event, b: Event) bool {
                if (a.ts_ns != b.ts_ns) return a.ts_ns < b.ts_ns;
                return a.dur_ns > b.dur_ns;
            }
        }.less);

        const file = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        var buffer: [64 * 1024]u8 = undefined;
        var file_writer = file.writerStreaming(io, &buffer);
        const writer = &file_writer.interface;
        try writer.writeAll("{\"traceEvents\":[\n");
        var first = true;
        for (0..self.worker_count) |tid| {
            try separator(writer, &first);
            try writer.print("{{\"ph\":\"M\",\"pid\":1,\"tid\":{d},\"name\":\"thread_name\",\"args\":{{\"name\":\"worker {d}", .{ tid, tid });
            if (tid == 0) try writer.writeAll(" (main / serial path)");
            try writer.writeAll("\"}}");
        }
        try separator(writer, &first);
        try writer.writeAll("{\"ph\":\"M\",\"pid\":1,\"tid\":500,\"name\":\"thread_name\",\"args\":{\"name\":\"critical path (demand waits)\"}}");

        for (self.events[0..count]) |event| {
            try separator(writer, &first);
            try self.writeEvent(writer, event);
        }
        try writer.writeAll("\n],\n\"displayTimeUnit\":\"ns\",\n\"metadata\":{");
        try writer.print("\"tool\":\"fix\",\"workers\":{d},\"start-monotonic-ns\":{d},\"source\":", .{ self.worker_count, self.start_ns });
        try writeJsonString(writer, self.source);
        try writer.writeAll("}\n}\n");
        try writer.flush();

        const dropped_events = self.dropped_events.load(.monotonic);
        const dropped_names = self.dropped_names.load(.monotonic);
        std.debug.print("timeline: wrote {d} events to {s} (open in https://ui.perfetto.dev)\n", .{ count, path });
        if (dropped_events != 0 or dropped_names != 0)
            std.debug.print("timeline: dropped {d} events and {d} names\n", .{ dropped_events, dropped_names });
    }

    fn writeEvent(self: *Recorder, writer: *std.Io.Writer, event: Event) !void {
        const relative = event.ts_ns -| self.start_ns;
        if (event.kind == .counter) {
            try writer.print("{{\"ph\":\"C\",\"pid\":1,\"tid\":{d},\"ts\":{d:.3},\"cat\":", .{ event.tid, micros(relative) });
            try writeJsonString(writer, event.category);
            try writer.writeAll(",\"name\":");
            try writeJsonString(writer, event.name);
            try writer.print(",\"args\":{{{s}}}}}", .{self.text(event.args)});
            return;
        }
        if (event.kind == .flow_out or event.kind == .flow_in) {
            try writer.print("{{\"ph\":\"{s}\",\"id\":{d},\"pid\":1,\"tid\":{d},\"ts\":{d:.3},\"cat\":", .{
                if (event.kind == .flow_out) "s" else "f",
                event.flow_id,
                event.tid,
                micros(relative),
            });
            try writeJsonString(writer, event.category);
            try writer.writeAll(",\"name\":");
            try writeJsonString(writer, event.name);
            if (event.kind == .flow_in) try writer.writeAll(",\"bp\":\"e\"");
            try writer.writeByte('}');
            return;
        }
        try writer.print("{{\"ph\":\"{s}\",\"pid\":1,\"tid\":{d},\"ts\":{d:.3}", .{
            if (event.kind == .instant) "i" else "X",
            event.tid,
            micros(relative),
        });
        if (event.kind == .instant)
            try writer.writeAll(",\"s\":\"t\"")
        else
            try writer.print(",\"dur\":{d:.3}", .{micros(event.dur_ns)});
        try writer.writeAll(",\"cat\":");
        try writeJsonString(writer, event.category);
        try writer.writeAll(",\"name\":");
        const subject = self.text(event.subject);
        try writeJsonString(writer, if (subject.len == 0) event.name else subject);
        const args = self.text(event.args);
        if (args.len != 0) try writer.print(",\"args\":{{{s}}}", .{args});
        try writer.writeByte('}');
    }

    fn text(self: *const Recorder, stored: Text) []const u8 {
        if (stored.len == 0) return "";
        return self.names[stored.off..][0..stored.len];
    }
};

fn trackId(track: observ.Track) u16 {
    return switch (track) {
        .current => worker_id.current,
        .worker => |id| id,
        .fiber => |id| @intCast(@min(id, std.math.maxInt(u16))),
        .activity => |id| @intCast(@min(id, std.math.maxInt(u16))),
    };
}

fn separator(writer: *std.Io.Writer, first: *bool) !void {
    if (first.*)
        first.* = false
    else
        try writer.writeAll(",\n");
}

fn writeFieldName(writer: *std.Io.Writer, name: []const u8, any: *bool) !void {
    if (any.*) try writer.writeByte(',');
    any.* = true;
    try writeJsonString(writer, name);
    try writer.writeByte(':');
}

fn writeJsonString(writer: *std.Io.Writer, bytes: []const u8) !void {
    try writer.writeByte('"');
    for (bytes) |byte| switch (byte) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => if (byte < 0x20)
            try writer.print("\\u{x:0>4}", .{byte})
        else
            try writer.writeByte(byte),
    };
    try writer.writeByte('"');
}

fn micros(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1000.0;
}
