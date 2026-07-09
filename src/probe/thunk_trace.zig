//! Per-thunk lifecycle event log.
//!
//! Records every state transition a thunk takes during an evaluation,
//! together with the source location of the bytecode that *created*
//! the thunk and a structural summary of the resolved value. The
//! summary is computed eagerly (at resolve time) so the log is
//! self-contained — `fix thunks dump` / `fix thunks diff` need only
//! the log file.
//!
//! Why a dedicated log instead of leaning on `--vm-trace`: `--vm-trace`
//! captures every opcode and is the wrong granularity for "what value
//! did thunk #42 resolve to and where was it created." This log fires
//! ~once per thunk lifecycle (create / claim / resolve / reset /
//! blackhole) — orders of magnitude less data, indexed by the thing
//! you actually want to compare across runs.
//!
//! Use:
//!   fix --thunks-log=/tmp/single.log --workers 1 -e ...
//!   fix --thunks-log=/tmp/multi.log  --workers 7 -e ...
//!   fix thunks diff /tmp/single.log /tmp/multi.log
//!
//! Format: one event per line, key=value pairs. Stable across runs is
//! the (creator_file, creator_line) tuple — chunk_ids and thunk_ids
//! are not stable, so the diff tool matches by source location.

const std = @import("std");
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const ChunkId = types.ChunkId;
const ObjectId = types.ObjectId;
const InternTable = @import("runtime").intern.InternTable;
const heap_mod = @import("runtime").heap;
const ObjectHeap = heap_mod.ObjectHeap;
const stable = @import("runtime").stable_segments;
const bytecode = @import("bytecode");
const ChunkRegistry = bytecode.ChunkRegistry;
const Chunk = bytecode.chunk.Chunk;

pub const TargetKind = enum {
    closure,
    bytecode,
    pass_through,
    builtin_closure,
};

pub const ThunkTrace = struct {
    writer: *std.Io.Writer,
    intern: *const InternTable,
    heap: *ObjectHeap,
    registry: *const ChunkRegistry,
    mu: stable.SpinMutex = .{},
    seq: std.atomic.Value(u64) = .init(0),

    pub fn init(
        writer: *std.Io.Writer,
        intern: *const InternTable,
        heap: *ObjectHeap,
        registry: *const ChunkRegistry,
    ) ThunkTrace {
        return .{ .writer = writer, .intern = intern, .heap = heap, .registry = registry };
    }

    pub fn flush(self: *ThunkTrace) !void {
        self.mu.lock();
        defer self.mu.unlock();
        try self.writer.flush();
    }

    pub fn recordCreate(
        self: *ThunkTrace,
        thunk_id: ObjectId,
        worker_id: u8,
        fiber_id: u32,
        creator_chunk_id: ChunkId,
        creator_ip: u32,
        target_kind: TargetKind,
        target_chunk_id: ?ChunkId,
    ) void {
        const seq = self.seq.fetchAdd(1, .monotonic);
        const creator_loc = self.lookupSpan(creator_chunk_id, creator_ip);
        const target_loc = if (target_chunk_id) |id| self.lookupSpan(id, 0) else null;
        self.mu.lock();
        defer self.mu.unlock();
        const w = self.writer;
        w.print(
            "seq={d} kind=create thunk={d} worker={d} fiber={d} target={s}",
            .{ seq, thunk_id, worker_id, fiber_id, @tagName(target_kind) },
        ) catch return;
        writeLoc(w, " creator", creator_loc, self.intern) catch return;
        if (target_loc) |loc| writeLoc(w, " target_at", loc, self.intern) catch return;
        w.writeByte('\n') catch return;
    }

    pub fn recordClaim(
        self: *ThunkTrace,
        thunk_id: ObjectId,
        worker_id: u8,
        fiber_id: u32,
    ) void {
        const seq = self.seq.fetchAdd(1, .monotonic);
        self.mu.lock();
        defer self.mu.unlock();
        self.writer.print(
            "seq={d} kind=claim thunk={d} worker={d} fiber={d}\n",
            .{ seq, thunk_id, worker_id, fiber_id },
        ) catch return;
    }

    pub fn recordResolve(
        self: *ThunkTrace,
        thunk_id: ObjectId,
        worker_id: u8,
        fiber_id: u32,
        value: Value,
    ) void {
        const seq = self.seq.fetchAdd(1, .monotonic);
        // Render the value summary into a small fixed-size scratch
        // buffer first, so a single huge attrset can't blow the log
        // into the gigabytes. Most divergences are visible from shape
        // + first few hundred bytes.
        var scratch: [256]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&scratch);
        writeValueInner(&writer, self.intern, self.heap, value, 2) catch {};
        const summary = writer.buffered();
        self.mu.lock();
        defer self.mu.unlock();
        const w = self.writer;
        w.print(
            "seq={d} kind=resolve thunk={d} worker={d} fiber={d} disc={s} value=",
            .{ seq, thunk_id, worker_id, fiber_id, @tagName(value.kind()) },
        ) catch return;
        w.writeAll(summary) catch return;
        if (summary.len == scratch.len) w.writeAll("...TRUNCATED") catch return;
        w.writeByte('\n') catch return;
    }

    pub fn recordReset(
        self: *ThunkTrace,
        thunk_id: ObjectId,
        worker_id: u8,
        fiber_id: u32,
        err_name: []const u8,
    ) void {
        const seq = self.seq.fetchAdd(1, .monotonic);
        self.mu.lock();
        defer self.mu.unlock();
        const w = self.writer;
        w.print(
            "seq={d} kind=reset thunk={d} worker={d} fiber={d} err=",
            .{ seq, thunk_id, worker_id, fiber_id },
        ) catch return;
        writeEscapedQuoted(w, err_name) catch return;
        w.writeByte('\n') catch return;
    }

    pub fn recordErrored(
        self: *ThunkTrace,
        thunk_id: ObjectId,
        worker_id: u8,
        fiber_id: u32,
        err_name: []const u8,
        message: ?[]const u8,
    ) void {
        const seq = self.seq.fetchAdd(1, .monotonic);
        self.mu.lock();
        defer self.mu.unlock();
        const w = self.writer;
        w.print(
            "seq={d} kind=errored thunk={d} worker={d} fiber={d} err=",
            .{ seq, thunk_id, worker_id, fiber_id },
        ) catch return;
        writeEscapedQuoted(w, err_name) catch return;
        if (message) |m| {
            w.writeAll(" message=") catch return;
            writeEscapedQuoted(w, m) catch return;
        }
        w.writeByte('\n') catch return;
    }

    pub fn recordBlackhole(
        self: *ThunkTrace,
        thunk_id: ObjectId,
        worker_id: u8,
        fiber_id: u32,
    ) void {
        const seq = self.seq.fetchAdd(1, .monotonic);
        self.mu.lock();
        defer self.mu.unlock();
        self.writer.print(
            "seq={d} kind=blackhole thunk={d} worker={d} fiber={d}\n",
            .{ seq, thunk_id, worker_id, fiber_id },
        ) catch return;
    }

    fn lookupSpan(self: *const ThunkTrace, chunk_id: ChunkId, ip: u32) ?Chunk.SourceSpan {
        const ch = self.registry.get(chunk_id) orelse return null;
        if (ch.source_map.len == 0) return null;
        const pc = if (ip == 0) 0 else ip - 1;
        var best: ?Chunk.SourceMapEntry = null;
        for (ch.source_map) |entry| {
            if (pc < entry.start or pc >= entry.end) continue;
            if (best == null or entry.end - entry.start <= best.?.end - best.?.start) {
                best = entry;
            }
        }
        return if (best) |entry| entry.span else null;
    }
};

fn writeLoc(
    writer: *std.Io.Writer,
    key: []const u8,
    span: ?Chunk.SourceSpan,
    intern: *const InternTable,
) !void {
    try writer.writeAll(key);
    try writer.writeByte('=');
    if (span) |s| {
        if (s.file) |fid| {
            try writer.writeByte('"');
            try writeEscaped(writer, intern.get(fid));
            try writer.writeByte('"');
        } else {
            try writer.writeAll("\"?\"");
        }
        try writer.print(":{d}:{d}", .{ s.line, s.column });
    } else {
        try writer.writeAll("\"?\":0:0");
    }
}

fn writeValueInner(
    writer: *std.Io.Writer,
    intern: *const InternTable,
    heap: *ObjectHeap,
    value: Value,
    depth: u8,
) !void {
    switch (value.kind()) {
        .null => try writer.writeAll("null"),
        .bool_true => try writer.writeAll("true"),
        .bool_false => try writer.writeAll("false"),
        .int => try writer.print("{d}", .{value.asInt()}),
        .boxed_int => try writer.print("{d}", .{heap.getBoxedInt(value.asObjectId()) catch 0}),
        .float => try writer.print("{d}", .{value.asFloat()}),
        .string => {
            try writer.writeByte('"');
            try writeEscaped(writer, intern.get(value.asInternId()));
            try writer.writeByte('"');
        },
        .path => {
            try writer.writeAll("p\"");
            try writeEscaped(writer, intern.get(value.asInternId()));
            try writer.writeByte('"');
        },
        .string_context => {
            const cs = heap.getContextString(value.asObjectId()) catch {
                try writer.writeAll("sc_err");
                return;
            };
            try writer.writeAll("sc\"");
            try writeEscaped(writer, intern.get(cs.text));
            try writer.writeByte('"');
        },
        .list => {
            if (depth == 0) {
                try writer.writeAll("[...]");
                return;
            }
            const items = heap.getList(value.asObjectId()) catch {
                try writer.writeAll("[list_err]");
                return;
            };
            try writer.writeByte('[');
            for (items, 0..) |item, i| {
                if (i > 0) try writer.writeByte(',');
                try writeValueInner(writer, intern, heap, item, depth - 1);
            }
            try writer.writeByte(']');
        },
        .attrs => {
            if (depth == 0) {
                try writer.writeAll("{...}");
                return;
            }
            const entries = heap.getAttrs(value.asObjectId()) catch {
                try writer.writeAll("{attrs_err}");
                return;
            };
            try writer.writeByte('{');
            for (entries, 0..) |entry, i| {
                if (i > 0) try writer.writeByte(',');
                try writer.writeAll(intern.get(entry.name));
                try writer.writeByte('=');
                try writeValueInner(writer, intern, heap, entry.value, depth - 1);
            }
            try writer.writeByte('}');
        },
        .closure => try writer.writeAll("<closure>"),
        .partial_app => try writer.writeAll("<partial-app>"),
        .thunk => try writer.print("<thunk {d}>", .{value.asObjectId()}),
        .builtin => try writer.writeAll("<builtin>"),
        .builtin_closure => try writer.writeAll("<builtin_closure>"),
    }
}

fn writeEscaped(writer: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
}

fn writeEscapedQuoted(writer: *std.Io.Writer, s: []const u8) !void {
    try writer.writeByte('"');
    try writeEscaped(writer, s);
    try writer.writeByte('"');
}
