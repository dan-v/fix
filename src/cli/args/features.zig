//! Experimental/deprecated feature-list parsing.

const std = @import("std");
const engine = @import("expr");

pub const ExperimentalFeature = engine.ExperimentalFeature;
pub const ExperimentalFeatures = engine.ExperimentalFeatures;
pub const DeprecatedFeature = engine.DeprecatedFeature;
pub const DeprecatedFeatures = engine.DeprecatedFeatures;

pub fn parseDeprecatedList(set: *DeprecatedFeatures, list: []const u8) void {
    var it = std.mem.tokenizeScalar(u8, list, ' ');
    while (it.next()) |name| {
        if (DeprecatedFeature.fromName(name)) |feature| set.insert(feature);
    }
}

pub fn parseExperimentalList(set: *ExperimentalFeatures, list: []const u8) !void {
    // Unknown names are skipped silently, exactly like the config-sourced
    // path below: drop-in callers pass Nix's own feature names wholesale
    // ("nix-command flakes" is nix-eval-jobs' standard invocation, and
    // consumers add ca-derivations and friends), and rejecting or warning
    // would break invocations — and test suites that assert clean stderr —
    // that work against Nix. A typo just leaves the feature unenabled, and
    // the feature gate's own error then names what to pass.
    var it = std.mem.tokenizeScalar(u8, list, ' ');
    while (it.next()) |name| {
        if (ExperimentalFeature.fromName(name)) |feature| set.insert(feature);
    }
}

pub fn mergeConfigured(set: *ExperimentalFeatures, list: []const u8) void {
    var it = std.mem.tokenizeScalar(u8, list, ' ');
    while (it.next()) |name| {
        if (ExperimentalFeature.fromName(name)) |feature| set.insert(feature);
    }
}
