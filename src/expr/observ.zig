//! Evaluation observability sinks — the interfaces the interpreter writes to,
//! implemented by the evaluator/CLI above it.
//!
//! `progress` is the progress-reporting protocol (the demand-only `StageSink`
//! + thread-safe `SpanSink` halves of the `Sink`, along with its event and stage
//! types). `trace` is the error-trace collector. Both
//! are pure interface/state types with no dependency on the engine or the
//! evaluator, so the VM can hold them without reaching upward.

pub const progress = @import("observ/progress.zig");
pub const trace = @import("observ/trace.zig");
