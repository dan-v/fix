//! Nix language implementation and evaluation engine.
//!
//! This is the narrow public facade. Representation-level subsystems remain
//! available to diagnostics through the explicit `tooling` namespace.

const runtime = @import("runtime");
const policy = @import("policy.zig");
const eval = @import("eval.zig");
const store_protocol = @import("store").daemon;
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
pub const BuildMode = store_protocol.BuildMode;
pub const BuildEvent = store_protocol.BuildEvent;
pub const BuildSink = store_protocol.BuildSink;
pub const BuildSettings = store_protocol.BuildSettings;
pub const BuildSetting = store_protocol.Setting;
pub const LanguagePolicy = policy.LanguagePolicy;
pub const ExperimentalFeature = policy.ExperimentalFeature;
pub const ExperimentalFeatures = policy.ExperimentalFeatures;
pub const DeprecatedFeature = policy.DeprecatedFeature;
pub const DeprecatedFeatures = policy.DeprecatedFeatures;
pub const parseMemorySize = memory_config.parseSize;

test {
    _ = @import("root/tests.zig");
}
