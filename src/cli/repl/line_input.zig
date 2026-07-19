//! The ordinary, inline REPL line editor.
//!
//! This owns raw mode only while one prompt is active. Full-screen tools such
//! as the VM explorer are entered explicitly after the submitted line has
//! restored the terminal, so the default REPL remains ordinary scrollback.

const std = @import("std");
const presentation = @import("../presentation.zig");
const editor_mod = @import("editor.zig");
const keys_mod = @import("keys.zig");
const render_mod = @import("render.zig");
const term_mod = @import("term.zig");

const prompt_main = "fix> ";
const prompt_cont = "...> ";

/// Read one (possibly multiline) input. Returns null on Ctrl-D at an empty
/// prompt. The returned allocation belongs to the caller.
pub fn read(
    allocator: std.mem.Allocator,
    io: std.Io,
    use_color: bool,
    editor: *editor_mod.Editor,
) !?[]u8 {
    var raw = term_mod.RawMode.enable() catch return error.NotATerminal;
    defer raw.disable();

    var stdout_buffer: [8 * 1024]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const w = &stdout_w.interface;

    try w.writeAll("\x1b[?2004h");
    defer {
        w.writeAll("\x1b[?2004l") catch {};
        w.flush() catch {};
    }

    var renderer = render_mod.Renderer.init(
        allocator,
        term_mod.size().cols,
        use_color,
        presentation.styleCode(true, .trace_label),
    );
    defer renderer.deinit();

    editor.reset();
    var decoder = keys_mod.Decoder{};
    var events: keys_mod.Decoder.List = .empty;
    defer events.deinit(allocator);
    var overlay_arena = std.heap.ArenaAllocator.init(allocator);
    defer overlay_arena.deinit();

    var read_buf: [512]u8 = undefined;
    while (true) {
        _ = overlay_arena.reset(.retain_capacity);
        try renderer.draw(w, try buildView(editor, overlay_arena.allocator()));
        try w.flush();

        const result = term_mod.readInput(&read_buf, if (decoder.wantsMore()) 40 else -1);
        events.clearRetainingCapacity();
        switch (result) {
            .timeout => try decoder.idleFlush(allocator, &events),
            .winch => {
                renderer.setWidth(term_mod.size().cols);
                renderer.invalidate();
                try w.writeAll("\r\x1b[J");
                continue;
            },
            .eof => {
                try renderer.finish(w);
                return null;
            },
            .data => |n| for (read_buf[0..n]) |b| try decoder.feed(allocator, b, &events),
        }

        for (events.items) |key| {
            switch (try editor.handleKey(key)) {
                .none => {},
                .bell => try w.writeAll("\x07"),
                .submit => {
                    try closeFrame(&renderer, w, editor.text());
                    try w.flush();
                    return try editor.takeText();
                },
                .eof => {
                    try closeFrame(&renderer, w, editor.text());
                    try w.flush();
                    return null;
                },
                .cancel => {
                    try closeFrame(&renderer, w, editor.text());
                    editor.reset();
                },
                .clear_screen => {
                    try w.writeAll("\x1b[H\x1b[2J");
                    renderer.invalidate();
                },
                .suspend_process => {
                    try closeFrame(&renderer, w, editor.text());
                    try w.flush();
                    raw.suspendProcess();
                    renderer.setWidth(term_mod.size().cols);
                    renderer.invalidate();
                },
            }
        }
    }
}

fn closeFrame(renderer: *render_mod.Renderer, w: *std.Io.Writer, text: []const u8) !void {
    try renderer.draw(w, .{
        .prompt = prompt_main,
        .cont_prompt = prompt_cont,
        .text = text,
        .cursor = text.len,
    });
    try renderer.finish(w);
}

fn buildView(editor: *editor_mod.Editor, arena: std.mem.Allocator) !render_mod.View {
    var view: render_mod.View = .{
        .prompt = prompt_main,
        .cont_prompt = prompt_cont,
        .text = editor.text(),
        .cursor = editor.cursor,
    };
    var search_buf: [96]u8 = undefined;
    if (editor.searchPrompt(&search_buf)) |prompt| {
        view.prompt = try arena.dupe(u8, prompt);
        view.cont_prompt = view.prompt;
    }
    const menu = editor.menuLines();
    if (menu.len > 0) {
        view.overlay = try render_mod.formatColumns(arena, menu, term_mod.size().cols, 8);
    }
    return view;
}
