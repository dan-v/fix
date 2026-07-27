const std = @import("std");

pub const Focus = enum { tree, subject };

pub const EscapeAction = enum {
    leave_source,
    focus_tree,
    clear_filter,
    tree_up,
    exit,
};

pub const EscapeContext = struct {
    source_active: bool,
    focus: Focus,
    filter_active: bool,
    tree_can_move_up: bool,
};

/// Escape always removes exactly one interaction layer.
pub fn escapeAction(context: EscapeContext) EscapeAction {
    if (context.source_active) return .leave_source;
    if (context.focus == .subject) return .focus_tree;
    if (context.filter_active) return .clear_filter;
    if (context.tree_can_move_up) return .tree_up;
    return .exit;
}

pub const PreviewScroll = struct {
    offset: usize = 0,

    pub fn reset(self: *PreviewScroll) void {
        self.offset = 0;
    }

    pub fn move(self: *PreviewScroll, delta: isize) void {
        if (delta >= 0) {
            self.offset +|= @intCast(delta);
        } else {
            self.offset -|= @intCast(-delta);
        }
    }

    /// Clamp to the actual popup body and return its first visible row.
    pub fn window(self: *PreviewScroll, total: usize, visible: usize) usize {
        self.offset = @min(self.offset, total -| visible);
        return self.offset;
    }
};

test "escape unwinds one explorer layer at a time" {
    try std.testing.expectEqual(EscapeAction.leave_source, escapeAction(.{
        .source_active = true,
        .focus = .subject,
        .filter_active = true,
        .tree_can_move_up = true,
    }));
    try std.testing.expectEqual(EscapeAction.focus_tree, escapeAction(.{
        .source_active = false,
        .focus = .subject,
        .filter_active = true,
        .tree_can_move_up = true,
    }));
    try std.testing.expectEqual(EscapeAction.clear_filter, escapeAction(.{
        .source_active = false,
        .focus = .tree,
        .filter_active = true,
        .tree_can_move_up = true,
    }));
    try std.testing.expectEqual(EscapeAction.tree_up, escapeAction(.{
        .source_active = false,
        .focus = .tree,
        .filter_active = false,
        .tree_can_move_up = true,
    }));
    try std.testing.expectEqual(EscapeAction.exit, escapeAction(.{
        .source_active = false,
        .focus = .tree,
        .filter_active = false,
        .tree_can_move_up = false,
    }));
}

test "preview scrolling advances and clamps to its body" {
    var scroll: PreviewScroll = .{};
    scroll.move(3);
    try std.testing.expectEqual(@as(usize, 3), scroll.window(20, 8));
    scroll.move(100);
    try std.testing.expectEqual(@as(usize, 12), scroll.window(20, 8));
    scroll.move(-2);
    try std.testing.expectEqual(@as(usize, 10), scroll.window(20, 8));
    scroll.reset();
    try std.testing.expectEqual(@as(usize, 0), scroll.window(20, 8));
}
