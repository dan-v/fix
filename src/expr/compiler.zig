//! Compiler facade: context, recursive driver, and cohesive node compilers.

pub const context = @import("compiler/context.zig");
pub const literals = @import("compiler/literals.zig");
pub const control = @import("compiler/control.zig");
pub const attrs = @import("compiler/attrs.zig");
pub const access = @import("compiler/access.zig");
pub const emit = @import("compiler/emit.zig");
pub const scope = @import("compiler/scope.zig");
pub const thunks = @import("compiler/thunks.zig");
pub const diagnostics = @import("compiler/diagnostics.zig");
pub const strictness = @import("compiler/strictness.zig");
pub const deferred_table = @import("compiler/deferred_table.zig");
pub const deferred = @import("compiler/deferred.zig");
pub const fold = @import("compiler/fold.zig");
pub const lambda = @import("compiler/lambda.zig");
pub const let = @import("compiler/let.zig");
pub const refs = @import("compiler/refs.zig");

const driver_mod = @import("compiler/driver.zig");

pub const Compiler = context.Compiler;
pub const Driver = context.Driver;
pub const ChunkRegistrationSink = context.ChunkRegistrationSink;
pub const driver = driver_mod.driver;

pub const Node = context.Node;
pub const NodeTag = context.NodeTag;
pub const BinaryOp = context.BinaryOp;
pub const Local = context.Local;
pub const Capture = context.Capture;
pub const WithScope = context.WithScope;
pub const AttrEntryView = context.AttrEntryView;
pub const AttrEntryGroup = context.AttrEntryGroup;
pub const AttrEntryGroups = context.AttrEntryGroups;
pub const ContainerValueOptions = context.ContainerValueOptions;
pub const with_capture_name = context.with_capture_name;

test {
    _ = driver;
    _ = deferred;
    _ = @import("compiler/tests.zig");
}
