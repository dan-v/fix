test {
    _ = @import("tests/core.zig");
    _ = @import("tests/io_fetch.zig");
    _ = @import("tests/builtins.zig");
    _ = @import("tests/derivation.zig");
    _ = @import("tests/diagnostics.zig");
    _ = @import("tests/pipe_operators.zig");
    _ = @import("tests/hashing.zig");
    _ = @import("tests/string_builtins.zig");
    _ = @import("tests/arithmetic.zig");
    _ = @import("tests/string_context.zig");
    _ = @import("tests/closures.zig");
    _ = @import("tests/forcing.zig");
    _ = @import("tests/deferred_compile.zig");
}
