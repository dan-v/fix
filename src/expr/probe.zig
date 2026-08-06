//! `probe` subsystem facade — opt-in diagnostic instrumentation.
//!
//! Timeline traces, profilers, and thunk traces.
//! Each is gated behind its own build flag or env var and compiled out of
//! default builds. Aggregates the submodules so consumers and the test runner
//! reach the whole subsystem through one import instead of hand-listing files.

pub const timeline = @import("probe/timeline.zig");
pub const prof = @import("probe/prof.zig");
pub const prof_path = @import("probe/prof_path.zig");
pub const prof_census = @import("probe/prof_census.zig");
pub const prof_dup = @import("probe/prof_dup.zig");
pub const thunk_trace = @import("probe/thunk_trace.zig");

test {
    _ = timeline;
    _ = prof;
    _ = prof_path;
    _ = prof_census;
    _ = thunk_trace;
}
