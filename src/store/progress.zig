//! Thread-safe progress capability shared by store and expression layers.

/// A category of concurrent work that gets its own grouping node with a live
/// `[done/total]` count; individual activities nest under it.
pub const SpanGroup = enum {
    fetch,
    store,
    source,
    build,

    pub fn label(self: SpanGroup) []const u8 {
        return switch (self) {
            .fetch => "fetching",
            .store => "writing to store",
            .source => "copying sources",
            .build => "building",
        };
    }
};

/// Opaque handle to a concurrent progress span. It retains the sink that
/// created it, so replacing a live sink cannot misroute an in-flight token.
pub const Span = struct {
    context: *anyopaque,
    token: usize,
    end_fn: *const fn (*anyopaque, usize) void,
    update_fn: *const fn (*anyopaque, usize, u64, u64) void,

    pub fn end(self: Span) void {
        self.end_fn(self.context, self.token);
    }

    pub fn update(self: Span, downloaded: u64, total: u64) void {
        self.update_fn(self.context, self.token, downloaded, total);
    }
};

/// Thread-safe concurrent progress spans. A span may be opened on one
/// thread/fiber and closed or updated on another.
pub const SpanSink = struct {
    context: *anyopaque,
    begin_span_fn: *const fn (*anyopaque, SpanGroup, []const u8) usize,
    end_span_fn: *const fn (*anyopaque, usize) void,
    update_span_fn: *const fn (*anyopaque, usize, u64, u64) void,

    pub fn beginSpan(self: SpanSink, group: SpanGroup, subject: []const u8) Span {
        return .{
            .context = self.context,
            .token = self.begin_span_fn(self.context, group, subject),
            .end_fn = self.end_span_fn,
            .update_fn = self.update_span_fn,
        };
    }

    pub fn endSpan(self: SpanSink, span: Span) void {
        _ = self;
        span.end();
    }

    pub fn updateSpan(self: SpanSink, span: Span, downloaded: u64, total: u64) void {
        _ = self;
        span.update(downloaded, total);
    }
};
