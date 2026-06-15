test {
    _ = @import("tests/values.zig");
    _ = @import("tests/bindings.zig");
    _ = @import("tests/attrs.zig");
    _ = @import("tests/functions.zig");
    _ = @import("tests/builtins.zig");
    _ = @import("tests/parallel.zig");
    _ = @import("../tjit/ir.zig");
    _ = @import("../tjit/hot.zig");
    _ = @import("../tjit/recorder.zig");
}
