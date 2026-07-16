//! Store realization for derivations and source paths.
//!
//! `derivation` defines the deterministic model and hashing rules. This module
//! owns the effectful recipe graph, source-ingest memoization, daemon claims,
//! and build operations.

pub const store = @import("derivation/store.zig");
pub const source_path = @import("derivation/source_path.zig");

pub const DerivationStore = store.DerivationStore;
pub const SpanGroup = store.SpanGroup;

test {
    _ = store;
    _ = source_path;
}
