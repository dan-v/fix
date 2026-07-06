//! `probe` subsystem facade — opt-in diagnostic instrumentation.
//!
//! Timeline traces, profilers, thunk/struct censuses, and n-gram/drv probes.
//! Each is gated behind its own build flag or env var and compiled out of
//! default builds. Aggregates the submodules so consumers and the test runner
//! reach the whole subsystem through one import instead of hand-listing files.

pub const timeline = @import("probe/timeline.zig");
pub const prof = @import("probe/prof.zig");
pub const prof_path = @import("probe/prof_path.zig");
pub const thunk_census = @import("probe/thunk_census.zig");
pub const thunk_trace = @import("probe/thunk_trace.zig");
pub const trace_probe = @import("probe/trace_probe.zig");
pub const drv_probe = @import("probe/drv_probe.zig");
pub const ngram_probe = @import("probe/ngram_probe.zig");
pub const depth0_probe = @import("probe/depth0_probe.zig");

test {
    _ = timeline;
    _ = prof;
    _ = prof_path;
    _ = thunk_census;
    _ = thunk_trace;
    _ = trace_probe;
    _ = drv_probe;
    _ = ngram_probe;
    _ = depth0_probe;
}
