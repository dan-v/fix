//! Shallow, terminal-safe rendering for `builtins.trace` messages.
//!
//! Nix accepts any value as a trace message. The outer value is forced by the
//! builtin, but lazy children are displayed as `«thunk»` rather than demanded
//! merely for logging. Strings at the root are written raw; nested strings use
//! the ordinary quoted Nix form.

const std = @import("std");
const VM = @import("context.zig").VM;
const Value = @import("runtime").value.Value;
const ObjectId = @import("runtime").types.ObjectId;
const FutureState = @import("runtime").future.FutureState;
const terminal_text = @import("base").terminal_text;
const vm_strings = @import("strings.zig");

/// A rendered effect message. `text` is either borrowed (an interned string
/// that needed no sanitizing) or a prefix of `owned`; call `deinit` once the
/// effect has been emitted. Messages are never interned: they are consumed
/// synchronously by the sink or copied by the speculation journal, so keeping
/// them in the intern table would only grow it without dedup benefit.
pub const Message = struct {
    text: []const u8,
    owned: ?[]u8 = null,

    pub fn deinit(self: Message, allocator: std.mem.Allocator) void {
        if (self.owned) |buf| allocator.free(buf);
    }
};

pub fn render(self: *VM, forced: Value) !Message {
    // Fast path: a root string-like value renders as its raw text, so when the
    // text is already terminal-safe the interned bytes can be borrowed
    // directly — no render buffer, no copy, no intern.
    const text_id = switch (forced.kind()) {
        .string, .path => forced.asInternId(),
        .string_context => (try self.heap.getContextString(forced.asObjectId())).text,
        else => null,
    };
    if (text_id) |id| return sanitizeString(self, self.intern.get(id));

    var out: std.Io.Writer.Allocating = .init(self.allocator);
    defer out.deinit();
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer seen.deinit(self.allocator);
    try writeValue(self, &out.writer, forced, true, &seen);
    const owned = try out.toOwnedSlice();
    return .{ .text = terminal_text.stripAnsiInPlace(owned), .owned = owned };
}

pub fn sanitizeString(self: *VM, raw: []const u8) !Message {
    if (!needsSanitize(raw)) return .{ .text = raw };
    const copy = try self.allocator.dupe(u8, raw);
    return .{ .text = terminal_text.stripAnsiInPlace(copy), .owned = copy };
}

/// Mirrors the byte classes `stripAnsiInPlace` removes: ESC, C0 controls
/// other than `\n` and `\t`, and DEL. Clean text strips to itself and can be
/// borrowed instead of copied.
fn needsSanitize(text: []const u8) bool {
    for (text) |c| {
        if (c == 0x1b or c == 0x7f or (c < 0x20 and c != '\n' and c != '\t')) return true;
    }
    return false;
}

fn writeValue(
    self: *VM,
    writer: *std.Io.Writer,
    value: Value,
    root: bool,
    seen: *std.AutoHashMapUnmanaged(u64, void),
) anyerror!void {
    switch (value.kind()) {
        .null => try writer.writeAll("null"),
        .bool_false => try writer.writeAll("false"),
        .bool_true => try writer.writeAll("true"),
        .int => try writer.print("{d}", .{value.asInt()}),
        .boxed_int => try writer.print("{d}", .{try self.heap.getBoxedInt(value.asObjectId())}),
        .float => try writer.print("{d}", .{value.asFloat()}),
        .string => try writeString(writer, self.intern.get(value.asInternId()), root),
        .heap_string => try writeString(writer, try vm_strings.stringBytes(self, value), root),
        .path => try writer.writeAll(self.intern.get(value.asInternId())),
        .string_context => {
            const string = try self.heap.getContextString(value.asObjectId());
            try writeString(writer, self.intern.get(string.text), root);
        },
        .list => try writeList(self, writer, value.asObjectId(), seen),
        .attrs => try writeAttrs(self, writer, value.asObjectId(), seen),
        .thunk => try writeThunk(self, writer, value.asObjectId(), root, seen),
        .closure => try writer.writeAll("«lambda»"),
        .builtin => try writer.writeAll("«primop»"),
        .builtin_closure, .partial_app => try writer.writeAll("«primop-app»"),
    }
}

fn writeList(self: *VM, writer: *std.Io.Writer, id: ObjectId, seen: *std.AutoHashMapUnmanaged(u64, void)) !void {
    if (!try enter(seen, self.allocator, id, 1)) return writer.writeAll("«repeated»");
    const items = try self.heap.getList(id);
    try writer.writeAll("[ ");
    for (items, 0..) |item, index| {
        if (index != 0) try writer.writeByte(' ');
        try writeValue(self, writer, item, false, seen);
    }
    try writer.writeAll(" ]");
}

fn writeAttrs(self: *VM, writer: *std.Io.Writer, id: ObjectId, seen: *std.AutoHashMapUnmanaged(u64, void)) !void {
    if (!try enter(seen, self.allocator, id, 2)) return writer.writeAll("«repeated»");
    const stored = try self.heap.materializeAttrs(id);
    const Entry = @import("runtime").heap.AttrEntry;
    const entries = try self.allocator.alloc(Entry, stored.len());
    defer self.allocator.free(entries);
    for (entries, stored.names, stored.values) |*e, n, v| e.* = .{ .name = n, .value = v };
    try self.intern.sortByNameLex(self.allocator, Entry, entries);

    try writer.writeAll("{ ");
    for (entries) |entry| {
        try writeAttrName(writer, self.intern.get(entry.name));
        try writer.writeAll(" = ");
        try writeValue(self, writer, entry.value, false, seen);
        try writer.writeAll("; ");
    }
    try writer.writeByte('}');
}

fn writeThunk(
    self: *VM,
    writer: *std.Io.Writer,
    id: ObjectId,
    root: bool,
    seen: *std.AutoHashMapUnmanaged(u64, void),
) !void {
    if (!try enter(seen, self.allocator, id, 3)) return writer.writeAll("«repeated»");
    const thunk = try self.heap.getThunk(id);
    const state: FutureState = thunk.future.stateField(.acquire);
    // A helper may have resolved this child ahead of demand. Keep that work
    // invisible in a shallow trace message just as lazy XML does.
    if (state != .resolved or !thunk.isDemanded()) return writer.writeAll("«thunk»");
    try writeValue(self, writer, thunk.payload.result, root, seen);
}

fn writeString(writer: *std.Io.Writer, text: []const u8, root: bool) !void {
    if (root) return writer.writeAll(text);
    try writer.writeByte('"');
    for (text) |c| switch (c) {
        '\\' => try writer.writeAll("\\\\"),
        '"' => try writer.writeAll("\\\""),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => try writer.writeByte(c),
    };
    try writer.writeByte('"');
}

fn writeAttrName(writer: *std.Io.Writer, name: []const u8) !void {
    if (name.len != 0 and (std.ascii.isAlphabetic(name[0]) or name[0] == '_')) {
        for (name[1..]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '\'')) {
            return writeString(writer, name, false);
        };
        return writer.writeAll(name);
    }
    try writeString(writer, name, false);
}

fn enter(seen: *std.AutoHashMapUnmanaged(u64, void), allocator: std.mem.Allocator, id: ObjectId, tag: u2) !bool {
    const gop = try seen.getOrPut(allocator, (@as(u64, id) << 2) | tag);
    return !gop.found_existing;
}
