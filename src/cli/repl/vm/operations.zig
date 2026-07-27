//! Named VM-explorer subsystem capabilities.
//!
//! The generic `Methods` pattern breaks import cycles without flattening every
//! operation into one mega namespace. Call sites retain the owning subsystem
//! in their spelling (`Ops.controller.open`, `Ops.pages.refreshPage`, ...).

const pages_mod = @import("pages.zig");
const source_view_mod = @import("source_view.zig");
const view_state_mod = @import("view_state.zig");
const tree_projection_mod = @import("tree_projection.zig");
const controller_mod = @import("controller.zig");
const preview_mod = @import("preview.zig");
const value_summary_mod = @import("value_summary.zig");
const tree_render_mod = @import("tree_render.zig");
const debug_view_mod = @import("debug_view.zig");

pub fn Operations(comptime Explorer: type) type {
    return struct {
        pub const pages = pages_mod.Methods(Explorer);
        pub const source_view = source_view_mod.Methods(Explorer);
        pub const view_state = view_state_mod.Methods(Explorer);
        pub const tree_projection = tree_projection_mod.Methods(Explorer);
        pub const controller = controller_mod.Methods(Explorer);
        pub const preview = preview_mod.Methods(Explorer);
        pub const value_summary = value_summary_mod.Methods(Explorer);
        pub const tree_render = tree_render_mod.Methods(Explorer);
        pub const debug_view = debug_view_mod.Methods(Explorer);
    };
}
