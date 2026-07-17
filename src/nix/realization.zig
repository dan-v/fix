//! Store realization for derivations and source paths.
//!
//! `derivation` defines the deterministic model and hashing rules. This module
//! owns the effectful recipe graph, source-ingest memoization, daemon claims,
//! and build operations.

pub const store = @import("realization/store.zig");
pub const source_path = @import("realization/source_path.zig");
pub const daemon_execution = @import("realization/daemon_execution.zig");

pub const RealizationStore = store.RealizationStore;
pub const SpanGroup = store.SpanGroup;

test {
    _ = store;
    _ = source_path;
    _ = daemon_execution;
    _ = @import("realization/tests.zig");
    _ = @import("realization/recipe_tests.zig");
    _ = @import("realization/testing/fake_daemon.zig");
}
