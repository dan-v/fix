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
    var it = std.mem.tokenizeScalar(u8, list, ' ');
    while (it.next()) |name| {
        const feature = ExperimentalFeature.fromName(name) orelse
            return error.UnknownExperimentalFeature;
        set.insert(feature);
    }
}

pub fn mergeConfigured(set: *ExperimentalFeatures, list: []const u8) void {
    var it = std.mem.tokenizeScalar(u8, list, ' ');
    while (it.next()) |name| {
        if (ExperimentalFeature.fromName(name)) |feature| set.insert(feature);
    }
}
