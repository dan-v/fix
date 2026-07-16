//! Integration-test root for realization and its fake daemon.

test {
    _ = @import("realization");
    _ = @import("derivation/tests.zig");
    _ = @import("derivation/recipe_tests.zig");
    _ = @import("test_daemon.zig");
}
