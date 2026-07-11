//! Source-line breakpoints by bytecode patching.
//!
//! A breakpoint replaces the single opcode byte at a line's first instruction
//! with the `breakpoint` opcode, saving the original byte. Execution then hits
//! the `breakpoint` handler, which pauses into the debugger and chains to the
//! saved original opcode (its operands are untouched). Clearing restores the
//! byte. This needs no change to the hot dispatch loop — the cost is paid only
//! when a patched instruction actually runs.
//!
//! Instruction boundaries come from the chunk's `source_map`: each entry keys a
//! `SourceSpan` by the code offset where that construct's first instruction was
//! emitted, so `entry.start` is always a safe patch point.
//!
//! Because bodies compile lazily (imports, deferred attrs register
//! mid-evaluation), the registry calls `sink()` for every newly registered
//! chunk so pending breakpoints land there too.

const std = @import("std");
const types = @import("runtime").types;
const InternTable = @import("runtime").intern.InternTable;
const chunk_mod = @import("chunk.zig");
const Chunk = chunk_mod.Chunk;
const ChunkRegistry = chunk_mod.ChunkRegistry;
const opcode = @import("opcode.zig");

const ChunkId = types.ChunkId;
const InternId = types.InternId;

const breakpoint_byte: u8 = @intFromEnum(opcode.OpCode.breakpoint);

pub const BreakpointTable = struct {
    gpa: std.mem.Allocator,
    intern: *const InternTable,
    requests: std.ArrayListUnmanaged(Request) = .empty,
    placements: std.ArrayListUnmanaged(Placement) = .empty,
    next_id: u32 = 1,
    /// Temporary patches for the in-progress step (cleared on the next pause).
    step_temps: std.ArrayListUnmanaged(Placement) = .empty,
    /// A step stops only when the frame depth is ≤ this (so a step-over doesn't
    /// stop inside a deeper recursion of the same chunk). `maxInt` = any depth.
    step_max_depth: u32 = 0,

    /// `req_id` sentinel marking a step temp rather than a user breakpoint.
    pub const STEP_REQ: u32 = 0;

    /// A candidate step-stop location.
    pub const Site = struct { chunk_id: ChunkId, offset: u32 };

    /// What the `breakpoint` handler should do at a patched site.
    pub const HitKind = enum { none, breakpoint, step };
    pub const Hit = struct { original: u8, pause: bool, kind: HitKind };

    /// A user request: "break on FILE:LINE". `line` is the resolved line (the
    /// nearest line at/after the requested one that carries code).
    pub const Request = struct {
        id: u32,
        file: []u8,
        line: u32,
    };

    /// A patched site realizing a request in a specific chunk.
    pub const Placement = struct {
        req_id: u32,
        chunk_id: ChunkId,
        offset: u32,
        original: u8,
    };

    pub const SetResult = struct {
        id: u32,
        /// Resolved line (may differ from the requested one).
        line: u32,
        /// How many sites were patched at set time (more may appear lazily).
        sites: usize,
    };

    pub fn init(gpa: std.mem.Allocator, intern: *const InternTable) BreakpointTable {
        return .{ .gpa = gpa, .intern = intern };
    }

    pub fn deinit(self: *BreakpointTable) void {
        for (self.requests.items) |r| self.gpa.free(r.file);
        self.requests.deinit(self.gpa);
        self.placements.deinit(self.gpa);
        self.step_temps.deinit(self.gpa);
    }

    /// The registration hook handed to `ChunkRegistry.breakpoint_sink`.
    pub fn sink(self: *BreakpointTable) chunk_mod.ChunkRegistry.BreakpointSink {
        return .{ .ctx = self, .place = placeCb };
    }

    fn placeCb(ctx: *anyopaque, chunk_id: ChunkId, chunk: *Chunk) void {
        const self: *BreakpointTable = @ptrCast(@alignCast(ctx));
        for (self.requests.items) |req| self.placeRequestInChunk(req, chunk_id, chunk) catch {};
    }

    /// Set a breakpoint at FILE:LINE. Resolves LINE to the nearest line ≥ LINE
    /// that carries code (in any registered chunk of that file); returns null if
    /// the file/line maps to nothing. Patches all matching registered chunks now
    /// and, via the sink, any that compile later.
    pub fn set(self: *BreakpointTable, registry: *ChunkRegistry, file: []const u8, line: u32) !?SetResult {
        const resolved = self.nearestLine(registry, file, line) orelse return null;
        const id = self.next_id;
        self.next_id += 1;
        try self.requests.append(self.gpa, .{ .id = id, .file = try self.gpa.dupe(u8, file), .line = resolved });
        const req = self.requests.items[self.requests.items.len - 1];

        const before = self.placements.items.len;
        var cid: ChunkId = 0;
        const n = registry.count();
        while (cid < n) : (cid += 1) {
            if (registry.get(cid)) |c| try self.placeRequestInChunk(req, cid, c);
        }
        return .{ .id = id, .line = resolved, .sites = self.placements.items.len - before };
    }

    /// Remove a breakpoint by id, restoring every byte it patched. Returns true
    /// if the id existed.
    pub fn remove(self: *BreakpointTable, registry: *ChunkRegistry, id: u32) bool {
        var found = false;
        var i: usize = 0;
        while (i < self.placements.items.len) {
            const p = self.placements.items[i];
            if (p.req_id == id) {
                if (registry.get(p.chunk_id)) |c| {
                    if (p.offset < c.code.len and c.code[p.offset] == breakpoint_byte) {
                        c.code[p.offset] = p.original;
                    }
                }
                _ = self.placements.swapRemove(i);
                found = true;
                continue;
            }
            i += 1;
        }
        var j: usize = 0;
        while (j < self.requests.items.len) : (j += 1) {
            if (self.requests.items[j].id == id) {
                self.gpa.free(self.requests.items[j].file);
                _ = self.requests.orderedRemove(j);
                found = true;
                break;
            }
        }
        return found;
    }

    /// Decide what the `breakpoint` handler does at `(chunk_id, offset)`: the
    /// saved original opcode to chain to, and whether to pause. A permanent
    /// breakpoint always pauses; a step temp pauses only at the target depth.
    pub fn hit(self: *const BreakpointTable, chunk_id: ChunkId, offset: u32, frames_len: u32) Hit {
        for (self.placements.items) |p| {
            if (p.chunk_id == chunk_id and p.offset == offset)
                return .{ .original = p.original, .pause = true, .kind = .breakpoint };
        }
        for (self.step_temps.items) |p| {
            if (p.chunk_id == chunk_id and p.offset == offset)
                return .{ .original = p.original, .pause = frames_len <= self.step_max_depth, .kind = .step };
        }
        return .{ .original = @intFromEnum(opcode.OpCode.halt), .pause = false, .kind = .none };
    }

    /// Arm a step: patch each site (unless a permanent breakpoint already sits
    /// there), and stop only at depth ≤ `max_depth`. Replaces any prior step.
    pub fn armStep(self: *BreakpointTable, registry: *ChunkRegistry, sites: []const Site, max_depth: u32) !void {
        self.clearStep(registry);
        self.step_max_depth = max_depth;
        for (sites) |site| {
            const c = registry.get(site.chunk_id) orelse continue;
            if (site.offset >= c.code.len) continue;
            if (c.code[site.offset] == breakpoint_byte) continue; // already patched (perm or dup)
            if (self.placedAt(site.chunk_id, site.offset)) continue;
            try self.step_temps.append(self.gpa, .{
                .req_id = STEP_REQ,
                .chunk_id = site.chunk_id,
                .offset = site.offset,
                .original = c.code[site.offset],
            });
            c.code[site.offset] = breakpoint_byte;
        }
    }

    /// Restore every step-temp byte and disarm the step.
    pub fn clearStep(self: *BreakpointTable, registry: *ChunkRegistry) void {
        for (self.step_temps.items) |p| {
            if (registry.get(p.chunk_id)) |c| {
                if (p.offset < c.code.len and c.code[p.offset] == breakpoint_byte) c.code[p.offset] = p.original;
            }
        }
        self.step_temps.clearRetainingCapacity();
        self.step_max_depth = 0;
    }

    fn placedAt(self: *const BreakpointTable, chunk_id: ChunkId, offset: u32) bool {
        for (self.placements.items) |p| {
            if (p.chunk_id == chunk_id and p.offset == offset) return true;
        }
        return false;
    }

    pub fn list(self: *const BreakpointTable) []const Request {
        return self.requests.items;
    }

    // -- internals --------------------------------------------------------------

    /// Nearest line ≥ `wanted` in `file` that any registered chunk carries.
    fn nearestLine(self: *const BreakpointTable, registry: *ChunkRegistry, file: []const u8, wanted: u32) ?u32 {
        var best: ?u32 = null;
        var cid: ChunkId = 0;
        const n = registry.count();
        while (cid < n) : (cid += 1) {
            const c = registry.get(cid) orelse continue;
            for (c.source_map) |entry| {
                if (!self.fileMatches(entry.span.file, file)) continue;
                const l = entry.span.line;
                if (l < wanted) continue;
                if (best == null or l < best.?) best = l;
            }
        }
        return best;
    }

    /// Patch `req`'s line into `chunk` if present and not already placed. Uses
    /// the earliest instruction of that line in the chunk (one site per chunk).
    fn placeRequestInChunk(self: *BreakpointTable, req: Request, chunk_id: ChunkId, chunk: *const Chunk) !void {
        var best_start: ?u32 = null;
        for (chunk.source_map) |entry| {
            if (entry.span.line != req.line) continue;
            if (!self.fileMatches(entry.span.file, req.file)) continue;
            if (best_start == null or entry.start < best_start.?) best_start = entry.start;
        }
        const start = best_start orelse return;
        if (start >= chunk.code.len) return;
        // Already placed here?
        for (self.placements.items) |p| {
            if (p.chunk_id == chunk_id and p.offset == start) return;
        }
        const original = chunk.code[start];
        if (original == breakpoint_byte) return; // patched by another request
        try self.placements.append(self.gpa, .{
            .req_id = req.id,
            .chunk_id = chunk_id,
            .offset = start,
            .original = original,
        });
        // `chunk.code` is `[]u8`; the bytes are mutable even through `*const`.
        chunk.code[start] = breakpoint_byte;
    }

    /// A stored span file matches the user's path if it's an exact match, a path
    /// suffix, or the same basename — forgiving of absolute-vs-relative forms.
    fn fileMatches(self: *const BreakpointTable, span_file: ?InternId, wanted: []const u8) bool {
        const id = span_file orelse return false;
        const text = self.intern.get(id);
        if (std.mem.eql(u8, text, wanted)) return true;
        if (std.mem.endsWith(u8, text, wanted)) return true;
        return std.mem.eql(u8, std.fs.path.basename(text), std.fs.path.basename(wanted));
    }
};
