//! Nix expression engine: bytecode compiler, lazy VM, builtins, evaluator,
//! worker runtime, and language-visible support libraries.

const eval = @import("eval.zig");
const policy = @import("policy.zig");
const observ = @import("observ.zig");
const memory_config = @import("memory_config.zig");

pub const tooling = @import("tooling.zig");

pub const Evaluator = eval.Evaluator;
pub const BuildSession = eval.BuildSession;
pub const Diagnostic = eval.Diagnostic;
pub const EvalTrace = eval.EvalTrace;
pub const EvalProgress = observ.progress;
pub const DebugSession = eval.DebugSession;
pub const DebugFrame = eval.DebugFrame;
pub const BreakReason = eval.BreakReason;
pub const ReleaseAction = eval.ReleaseAction;
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
    _ = eval;
    _ = @import("support.zig");
    _ = @import("probe.zig");
    _ = tooling;
}
