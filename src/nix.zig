//! Public Nix evaluation API.
//!
//! This is the narrow public facade. Representation-level subsystems remain
//! available to diagnostics through the explicit `tooling` namespace.

const runtime = @import("runtime");
const expr = @import("expr");
const store_protocol = @import("store").daemon;

pub const tooling = @import("nix_tooling.zig");

pub const Evaluator = expr.Evaluator;
pub const BuildSession = expr.BuildSession;
pub const Value = runtime.value.Value;
pub const Diagnostic = expr.Diagnostic;
pub const EvalTrace = expr.EvalTrace;
/// Stable producer/consumer protocol for evaluation progress. Terminal
/// rendering remains a CLI concern.
pub const EvalProgress = expr.EvalProgress;
pub const DebugSession = expr.DebugSession;
pub const DebugFrame = expr.DebugFrame;
pub const BreakReason = expr.BreakReason;
pub const ReleaseAction = expr.ReleaseAction;
pub const BuildMode = store_protocol.BuildMode;
pub const BuildEvent = store_protocol.BuildEvent;
pub const BuildSink = store_protocol.BuildSink;
pub const BuildSettings = store_protocol.BuildSettings;
pub const BuildSetting = store_protocol.Setting;
pub const LanguagePolicy = expr.LanguagePolicy;
pub const ExperimentalFeature = expr.ExperimentalFeature;
pub const ExperimentalFeatures = expr.ExperimentalFeatures;
pub const DeprecatedFeature = expr.DeprecatedFeature;
pub const DeprecatedFeatures = expr.DeprecatedFeatures;
pub const parseMemorySize = expr.parseMemorySize;

test {
    _ = @import("integration/nix_api.zig");
}
