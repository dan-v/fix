//! `jit` subsystem facade — the tracing JIT (opt-in `-Djit`/`-Dtjit`).
//!
//! Hot-loop detection, bytecode-trace recording, an SSA-ish IR with an
//! optimizer, x86-64 code generation, and native execution. The interpreter
//! stays canonical; this layer is compiled out (or dead) unless enabled.
//! Aggregates the submodules so consumers and the test runner reach the whole
//! subsystem through one import instead of hand-listing files.

pub const ir = @import("jit/ir.zig");
pub const hot = @import("jit/hot.zig");
pub const record_driver = @import("jit/record_driver.zig");
pub const recorder = @import("jit/recorder.zig");
pub const opt = @import("jit/opt.zig");
pub const codegen = @import("jit/codegen.zig");
pub const linear = @import("jit/linear.zig");
pub const native = @import("jit/native.zig");
pub const exec = @import("jit/exec.zig");
pub const jit_helpers = @import("jit/jit_helpers.zig");

test {
    _ = ir;
    _ = hot;
    _ = record_driver;
    _ = recorder;
    _ = opt;
    _ = codegen;
    _ = linear;
    _ = native;
    _ = exec;
    _ = jit_helpers;
}
