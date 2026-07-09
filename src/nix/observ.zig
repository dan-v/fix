//! Evaluation observability sinks — the interfaces the interpreter writes to,
//! implemented by the evaluator/CLI above it.
//!
//! `progress` is the progress-reporting protocol (Sink/Event/Metrics/Stage +
//! the shared demand-block subject). `trace` is the error-trace collector. Both
//! are pure interface/state types with no dependency on the engine or the
//! evaluator, so the VM can hold them without reaching upward.

pub const progress = @import("observ/progress.zig");
pub const trace = @import("observ/trace.zig");
