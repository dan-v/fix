//! Terminal test runner for Fix's unit-test binaries.
//!
//! Fix switches stacks inside the evaluator. Zig's default segfault handler
//! attempts to unwind the current stack after a crash; if that stack belongs to
//! a fiber, the unwinder can fault or wedge before aborting. Let the operating
//! system terminate a crashing test instead, so the build sees the signal
//! immediately and the outer timeout remains only a deadlock guard.

const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;

pub const std_options: std.Options = .{
    .enable_segfault_handler = false,
    .logFn = log,
};

var log_err_count: usize = 0;

pub fn main(init: std.process.Init.Minimal) void {
    @disableInstrumentation();

    const test_fns = builtin.test_functions;
    var passed: usize = 0;
    var skipped: usize = 0;
    var failed: usize = 0;
    var leaked: usize = 0;

    for (test_fns, 0..) |test_fn, index| {
        testing.allocator_instance = .{};
        testing.io_instance = .init(testing.allocator, .{
            .argv0 = .init(init.args),
            .environ = init.environ,
        });
        defer {
            testing.io_instance.deinit();
            if (testing.allocator_instance.deinit() == .leak) leaked += 1;
        }
        testing.log_level = .warn;
        testing.environ = init.environ;

        std.debug.print("{d}/{d} {s}...", .{ index + 1, test_fns.len, test_fn.name });
        if (test_fn.func()) |_| {
            passed += 1;
            std.debug.print("OK\n", .{});
        } else |err| switch (err) {
            error.SkipZigTest => {
                skipped += 1;
                std.debug.print("SKIP\n", .{});
            },
            else => {
                failed += 1;
                std.debug.print("FAIL ({t})\n", .{err});
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpErrorReturnTrace(trace);
                }
            },
        }
    }

    if (passed == test_fns.len) {
        std.debug.print("All {d} tests passed.\n", .{passed});
    } else {
        std.debug.print("{d} passed; {d} skipped; {d} failed.\n", .{ passed, skipped, failed });
    }
    if (log_err_count != 0) std.debug.print("{d} errors were logged.\n", .{log_err_count});
    if (leaked != 0) std.debug.print("{d} tests leaked memory.\n", .{leaked});

    if (failed != 0 or log_err_count != 0 or leaked != 0) {
        std.process.exit(1);
    }
}

fn log(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    @disableInstrumentation();
    if (@intFromEnum(message_level) <= @intFromEnum(std.log.Level.err)) {
        log_err_count +|= 1;
    }
    if (@intFromEnum(message_level) <= @intFromEnum(testing.log_level)) {
        std.debug.print(
            "[" ++ @tagName(scope) ++ "] (" ++ @tagName(message_level) ++ "): " ++ format ++ "\n",
            args,
        );
    }
}
