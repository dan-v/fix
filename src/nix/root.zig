//! Nix language implementation and evaluation engine.
//!
//! This is the narrow public facade. Representation-level subsystems remain
//! available to diagnostics through the explicit `tooling` namespace.

const runtime = @import("runtime");
const policy = @import("policy.zig");
const eval = @import("eval.zig");
const build_protocol = @import("build_protocol.zig");
const eval_progress = @import("observ.zig").progress;
const memory_config = @import("memory_config.zig");

pub const tooling = @import("tooling.zig");

pub const Evaluator = eval.Evaluator;
pub const BuildSession = eval.BuildSession;
pub const Value = runtime.value.Value;
pub const Diagnostic = eval.Diagnostic;
pub const EvalTrace = eval.EvalTrace;
/// Stable producer/consumer protocol for evaluation progress. Terminal
/// rendering remains a CLI concern.
pub const EvalProgress = eval_progress;
pub const DebugSession = eval.DebugSession;
pub const DebugFrame = eval.DebugFrame;
pub const BreakReason = eval.BreakReason;
pub const ReleaseAction = eval.ReleaseAction;
pub const BuildMode = build_protocol.Mode;
pub const BuildEvent = build_protocol.Event;
pub const BuildSink = build_protocol.Sink;
pub const BuildSettings = build_protocol.Settings;
pub const BuildSetting = build_protocol.Setting;
pub const LanguagePolicy = policy.LanguagePolicy;
pub const ExperimentalFeature = policy.ExperimentalFeature;
pub const ExperimentalFeatures = policy.ExperimentalFeatures;
pub const DeprecatedFeature = policy.DeprecatedFeature;
pub const DeprecatedFeatures = policy.DeprecatedFeatures;
pub const parseMemorySize = memory_config.parseSize;

test {
    _ = @import("root/tests.zig");
}
