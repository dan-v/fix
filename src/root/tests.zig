test {
    _ = @import("tests/values.zig");
    _ = @import("tests/bindings.zig");
    _ = @import("tests/attrs.zig");
    _ = @import("tests/functions.zig");
    _ = @import("tests/builtins.zig");
    _ = @import("tests/parallel.zig");
    _ = @import("../jit/ir.zig");
    _ = @import("../jit/hot.zig");
    _ = @import("../jit/recorder.zig");
    _ = @import("../jit/opt.zig");
    _ = @import("../jit/codegen.zig");
    _ = @import("../jit/linear.zig");
}
