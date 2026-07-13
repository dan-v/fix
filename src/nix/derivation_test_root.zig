//! Standalone derivation-module test root. Keeping test-only imports here means
//! consumers of the production `derivation` module never acquire fake-daemon
//! or recipe-test source files as module members.

test {
    _ = @import("derivation.zig");
    _ = @import("derivation/tests.zig");
    _ = @import("derivation/recipe_tests.zig");
    _ = @import("test_daemon.zig");
}
