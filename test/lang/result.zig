//! The shared verdict type for both conformance suites. Mirrors run.py's
//! `Result`: every case is attempted and ends as pass / fail / blocked.

const std = @import("std");

pub const Status = enum { pass, fail, blocked };

pub const Result = struct {
    suite: []const u8,
    ident: []const u8,
    status: Status,
    /// Diff or reason. Always shown for a fail (the point of the suite) and for
    /// a blocked case (its external cause). Allocated in the report arena.
    detail: []const u8 = "",

    pub fn pass(suite: []const u8, ident: []const u8) Result {
        return .{ .suite = suite, .ident = ident, .status = .pass };
    }
    pub fn fail(suite: []const u8, ident: []const u8, detail: []const u8) Result {
        return .{ .suite = suite, .ident = ident, .status = .fail, .detail = detail };
    }
    pub fn blocked(suite: []const u8, ident: []const u8, detail: []const u8) Result {
        return .{ .suite = suite, .ident = ident, .status = .blocked, .detail = detail };
    }
};
