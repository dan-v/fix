//! Nix expression engine: bytecode compiler, lazy VM, builtins, evaluator,
//! worker runtime, and language-visible support libraries.

const evaluator = @import("evaluator.zig");
const policy = @import("policy.zig");
const memory_config = @import("memory_config.zig");
const effects = @import("effects.zig");

pub const bytecode = @import("tooling/bytecode.zig");
pub const workers = @import("eval/workers.zig");
pub const vm = @import("vm.zig");
pub const probe = @import("probe.zig");

pub const Evaluator = evaluator.Evaluator;
pub const BuildSession = evaluator.BuildSession;
pub const Diagnostic = evaluator.Diagnostic;
pub const EvalTrace = evaluator.EvalTrace;
pub const EvaluationResult = evaluator.EvaluationResult;
pub const DebugSession = evaluator.DebugSession;
pub const DebugFrame = evaluator.DebugFrame;
pub const BreakReason = evaluator.BreakReason;
pub const ReleaseAction = evaluator.ReleaseAction;
pub const EffectKind = effects.Kind;
pub const EffectSink = effects.Sink;
pub const LanguagePolicy = policy.LanguagePolicy;
pub const ExperimentalFeature = policy.ExperimentalFeature;
pub const ExperimentalFeatures = policy.ExperimentalFeatures;
pub const DeprecatedFeature = policy.DeprecatedFeature;
pub const DeprecatedFeatures = policy.DeprecatedFeatures;
pub const parseMemorySize = memory_config.parseSize;

test {
    _ = @import("bytecode.zig");
    _ = @import("compiler.zig");
    _ = @import("vm.zig");
    _ = evaluator;
    _ = @import("support.zig");
    _ = probe;
}
