test {
    _ = @import("tests/values.zig");
    _ = @import("tests/bindings.zig");
    _ = @import("tests/attrs.zig");
    _ = @import("tests/functions.zig");
    _ = @import("tests/builtins.zig");
    _ = @import("tests/parallel.zig");
    // Whole probe/ subsystem via its aggregator facade, so no submodule can
    // silently drop out of the test run.
    _ = @import("probe");
}
