//! Evaluator lifecycle capabilities supplied by the process composition root.

/// Explicit process-owned work to run after evaluator language state has been
/// released. Passed to a release operation rather than stored on Evaluator.
pub const ReleaseAction = struct {
    context: *anyopaque,
    run: *const fn (context: *anyopaque) void,
};
