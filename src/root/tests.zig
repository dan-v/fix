test {
    _ = @import("tests/values.zig");
    _ = @import("tests/bindings.zig");
    _ = @import("tests/attrs.zig");
    _ = @import("tests/functions.zig");
    _ = @import("tests/builtins.zig");
    _ = @import("tests/parallel.zig");
    // Whole jit/ and probe/ subsystems via their aggregator facades, so no
    // submodule can silently drop out of the test run (native/exec/record/
    // jit_helpers were previously missing from a hand-maintained list).
    _ = @import("../jit.zig");
    _ = @import("../probe.zig");
}
