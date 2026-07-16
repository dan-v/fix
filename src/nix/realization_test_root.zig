//! Integration-test root for realization and its fake daemon.

test {
    _ = @import("realization");
    _ = @import("realization/tests.zig");
    _ = @import("realization/recipe_tests.zig");
    _ = @import("test_daemon.zig");
}
