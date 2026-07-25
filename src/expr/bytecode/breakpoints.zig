//! Source-line, exact-source-span, and instruction breakpoints by bytecode
//! patching.
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
const Value = @import("runtime").value.Value;
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
    /// `step into` must also follow code which does not exist yet when the
    /// command is issued (an import or deferred body compiled on demand).
    /// `placeRegisteredChunk` patches those entry points before they can run.
    step_follow_new_chunks: bool = false,
    step_armed: bool = false,
    step_hit_kind: HitKind = .step,

    /// `req_id` sentinel marking a step temp rather than a user breakpoint.
    pub const step_request_id: u32 = 0;

    /// A candidate step-stop location.
    pub const Site = struct { chunk_id: ChunkId, offset: u32 };

    /// What the `breakpoint` handler should do at a patched site.
    pub const HitKind = enum { none, breakpoint, step, entry };
    pub const Hit = struct { original: u8, pause: bool, kind: HitKind };

    /// A user request: "break on FILE:LINE". `line` is the resolved line (the
    /// nearest line at/after the requested one that carries code).
    pub const Request = struct {
        id: u32,
        file: []u8,
        requested_line: u32,
        line: u32,
        pending: bool,
        /// A per-instruction breakpoint pinned to one `(chunk_id, offset)` site
        /// rather than a FILE:LINE. Not re-placeable by line, so lazy chunk
        /// registration and pending-file resolution skip it.
        site_only: bool = false,
        /// An exact source-span request. The chunk id keeps equal source
        /// coordinates in separately compiled bodies independent.
        span_chunk: ?ChunkId = null,
        span: ?Chunk.SourceSpan = null,
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
        pending: bool,
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

    /// Apply pending breakpoint requests to one explicitly reported new chunk.
    /// The evaluator calls this after registration; the registry has no hidden
    /// debugger mutation hook.
    pub fn placeRegisteredChunk(self: *BreakpointTable, chunk_id: ChunkId, chunk: *Chunk) void {
        for (self.requests.items) |req| {
            if (req.site_only) continue;
            if (!req.pending) self.placeRequestInChunk(req, chunk_id, chunk) catch {};
        }
        if (self.step_armed and self.step_follow_new_chunks) {
            const offset = firstMappedOffset(chunk) orelse return;
            self.placeStepSite(chunk_id, offset, chunk) catch {};
        }
    }

    /// Set a breakpoint at FILE:LINE. Resolves LINE to the nearest line ≥ LINE
    /// in an already compiled file, or retains a pending request until the file
    /// compiles. Patches all matching registered chunks now and any that appear
    /// later.
    pub fn set(self: *BreakpointTable, registry: *ChunkRegistry, file: []const u8, line: u32) !SetResult {
        const resolved = self.nearestLine(registry, file, line);
        const id = self.next_id;
        self.next_id += 1;
        try self.requests.append(self.gpa, .{
            .id = id,
            .file = try self.gpa.dupe(u8, file),
            .requested_line = line,
            .line = resolved orelse line,
            .pending = resolved == null,
        });
        const req = self.requests.items[self.requests.items.len - 1];

        const before = self.placements.items.len;
        if (!req.pending) {
            var cid: ChunkId = 0;
            const n = registry.count();
            while (cid < n) : (cid += 1) {
                if (registry.get(cid)) |c| try self.placeRequestInChunk(req, cid, c);
            }
        }
        return .{
            .id = id,
            .line = req.line,
            .sites = self.placements.items.len - before,
            .pending = req.pending,
        };
    }

    /// Resolve requests for a source file once its top-level compilation unit
    /// is complete. This lets `break FILE:LINE` be set before an import exists
    /// without guessing the nearest executable line from a partially
    /// registered set of child chunks.
    pub fn resolvePendingFile(self: *BreakpointTable, registry: *ChunkRegistry, compiled_file: []const u8) void {
        for (self.requests.items) |*req| {
            if (!req.pending or !textFileMatches(req.file, compiled_file)) continue;
            const resolved = self.nearestLine(registry, compiled_file, req.requested_line) orelse continue;
            req.line = resolved;
            req.pending = false;
            var cid: ChunkId = 0;
            const n = registry.count();
            while (cid < n) : (cid += 1) {
                if (registry.get(cid)) |chunk| self.placeRequestInChunk(req.*, cid, chunk) catch {};
            }
        }
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

    /// Set a per-instruction breakpoint at an exact `(chunk_id, offset)` site.
    /// Unlike `set`, this does not resolve or track a source line: it patches
    /// the one instruction the caller selected. Source rows use `setSpan`
    /// because several nested spans may share an entry offset.
    pub fn setAt(self: *BreakpointTable, registry: *ChunkRegistry, chunk_id: ChunkId, offset: u32) !SetResult {
        const id = self.next_id;
        self.next_id += 1;
        try self.requests.append(self.gpa, .{
            .id = id,
            .file = try self.gpa.dupe(u8, ""),
            .requested_line = 0,
            .line = 0,
            .pending = false,
            .site_only = true,
        });
        const before = self.placements.items.len;
        if (registry.get(chunk_id)) |chunk| try self.placeSite(id, chunk_id, offset, chunk);
        return .{
            .id = id,
            .line = 0,
            .sites = self.placements.items.len - before,
            .pending = false,
        };
    }

    /// Set a breakpoint on one exact source-map span. Nested spans commonly
    /// share their first bytecode offset, so using the map entry's raw `start`
    /// would collapse them into a line-like breakpoint. Instead, resolve to the
    /// first instruction whose *tightest* source mapping is this exact span.
    /// If compiler lowering gave the span no distinct execution site, return
    /// zero sites rather than silently broadening it.
    pub fn setSpan(
        self: *BreakpointTable,
        registry: *ChunkRegistry,
        chunk_id: ChunkId,
        span: Chunk.SourceSpan,
    ) !SetResult {
        const chunk = registry.get(chunk_id) orelse return .{
            .id = 0,
            .line = span.line,
            .sites = 0,
            .pending = false,
        };
        const offset = self.firstExactSpanSite(chunk_id, chunk, span) orelse return .{
            .id = 0,
            .line = span.line,
            .sites = 0,
            .pending = false,
        };

        const id = self.next_id;
        self.next_id += 1;
        try self.requests.append(self.gpa, .{
            .id = id,
            .file = try self.gpa.dupe(u8, ""),
            .requested_line = span.line,
            .line = span.line,
            .pending = false,
            .site_only = true,
            .span_chunk = chunk_id,
            .span = span,
        });
        const before = self.placements.items.len;
        try self.placeSite(id, chunk_id, offset, chunk);
        const sites = self.placements.items.len - before;
        if (sites == 0) {
            const request = self.requests.pop().?;
            self.gpa.free(request.file);
        }
        return .{
            .id = if (sites == 0) 0 else id,
            .line = span.line,
            .sites = sites,
            .pending = false,
        };
    }

    /// Remove whatever breakpoint owns the placement at `(chunk_id, offset)`,
    /// restoring the patched byte. Returns true if a placement existed there.
    pub fn removeAt(self: *BreakpointTable, registry: *ChunkRegistry, chunk_id: ChunkId, offset: u32) bool {
        for (self.placements.items) |p| {
            if (p.chunk_id == chunk_id and p.offset == offset) return self.remove(registry, p.req_id);
        }
        return false;
    }

    pub fn removeSpan(
        self: *BreakpointTable,
        registry: *ChunkRegistry,
        chunk_id: ChunkId,
        span: Chunk.SourceSpan,
    ) bool {
        for (self.requests.items) |request| {
            const requested = request.span orelse continue;
            if (request.span_chunk == chunk_id and sameSpan(requested, span))
                return self.remove(registry, request.id);
        }
        return false;
    }

    /// Whether a permanent breakpoint is currently placed at this exact site.
    pub fn hasSite(self: *const BreakpointTable, chunk_id: ChunkId, offset: u32) bool {
        return self.placedAt(chunk_id, offset);
    }

    pub fn hasSpan(self: *const BreakpointTable, chunk_id: ChunkId, span: Chunk.SourceSpan) bool {
        for (self.requests.items) |request| {
            const requested = request.span orelse continue;
            if (request.span_chunk == chunk_id and sameSpan(requested, span)) return true;
        }
        return false;
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
                return .{ .original = p.original, .pause = frames_len <= self.step_max_depth, .kind = self.step_hit_kind };
        }
        return .{ .original = @intFromEnum(opcode.OpCode.halt), .pause = false, .kind = .none };
    }

    /// A frame return is also a useful step boundary: the caller is live again
    /// and the VM has the result available for display. Entry traps and
    /// permanent breakpoints do not opt into these virtual stops.
    pub fn pausesAfterReturn(self: *const BreakpointTable, frame_depth: u32) bool {
        return self.step_armed and self.step_hit_kind == .step and frame_depth <= self.step_max_depth;
    }

    /// Add bytecode-level evaluation boundaries from one chunk. These fill the
    /// gaps inside broad source-map spans (notably a curried `foo x y z`): the
    /// debugger can stop before each force/call without putting probes in the
    /// normal evaluator. `skip` is the instruction at the current pause.
    pub fn appendEvaluationStepSites(
        self: *const BreakpointTable,
        allocator: std.mem.Allocator,
        chunk_id: ChunkId,
        chunk: *const Chunk,
        skip: ?u32,
        sites: *std.ArrayListUnmanaged(Site),
    ) !void {
        var start: usize = 0;
        while (start < chunk.code.len) {
            const op = self.instructionOpcode(chunk_id, chunk, @intCast(start)) orelse return;
            if (evaluationStepBoundary(op) and (skip == null or start != skip.?)) {
                try sites.append(allocator, .{ .chunk_id = chunk_id, .offset = @intCast(start) });
            }
            const next = self.instructionEnd(chunk_id, chunk, start) orelse return;
            if (next <= start) return;
            start = next;
        }
    }

    /// Arm a step: patch each site (unless a permanent breakpoint already sits
    /// there), and stop only at depth ≤ `max_depth`. Replaces any prior step.
    pub fn armStep(
        self: *BreakpointTable,
        registry: *ChunkRegistry,
        sites: []const Site,
        max_depth: u32,
        follow_new_chunks: bool,
    ) !void {
        self.clearStep(registry);
        self.step_max_depth = max_depth;
        self.step_follow_new_chunks = follow_new_chunks;
        self.step_armed = true;
        self.step_hit_kind = .step;
        for (sites) |site| {
            const c = registry.get(site.chunk_id) orelse continue;
            try self.placeStepSite(site.chunk_id, site.offset, c);
        }
    }

    /// Arm a one-shot pause at the first source-mapped instruction in `chunk`.
    /// This is the native `:debug` entry stop: user source is compiled exactly
    /// as written, without a synthetic `builtins.break` wrapper.
    pub fn armEntry(self: *BreakpointTable, registry: *ChunkRegistry, chunk_id: ChunkId) !bool {
        self.clearStep(registry);
        const chunk = registry.get(chunk_id) orelse return false;
        const offset = firstMappedOffset(chunk) orelse return false;
        self.step_max_depth = std.math.maxInt(u32);
        self.step_armed = true;
        self.step_hit_kind = .entry;
        try self.placeStepSite(chunk_id, offset, chunk);
        return self.placedAt(chunk_id, offset) or self.stepPlacedAt(chunk_id, offset);
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
        self.step_follow_new_chunks = false;
        self.step_armed = false;
        self.step_hit_kind = .step;
    }

    /// Return the first instruction boundary at or after `offset`. A paused
    /// caller's saved ip is not necessarily a boundary: handlers record the ip
    /// just after their opcode before decoding operands or forcing a value.
    /// Stepping must advance such an ip past the rest of that instruction,
    /// rather than replacing one of its operand bytes with `breakpoint`.
    pub fn instructionBoundaryAtOrAfter(
        self: *const BreakpointTable,
        chunk_id: ChunkId,
        chunk: *const Chunk,
        offset: usize,
    ) ?u32 {
        var start: usize = 0;
        while (start < chunk.code.len) {
            if (offset <= start) return @intCast(start);
            const next = self.instructionEnd(chunk_id, chunk, start) orelse return null;
            if (offset < next) return if (next < chunk.code.len) @intCast(next) else null;
            start = next;
        }
        return null;
    }

    /// Resolve a frame's saved ip to the instruction which suspended there.
    /// Handlers save positions anywhere from just after the opcode through the
    /// end of its operands, so this deliberately treats `ip == end` as part of
    /// the preceding instruction. Patched breakpoint bytes are decoded through
    /// their saved original opcodes.
    pub fn instructionForSavedIp(
        self: *const BreakpointTable,
        chunk_id: ChunkId,
        chunk: *const Chunk,
        ip: usize,
    ) ?u32 {
        var start: usize = 0;
        while (start < chunk.code.len) {
            const end = self.instructionEnd(chunk_id, chunk, start) orelse return null;
            if (ip <= end) return @intCast(start);
            start = end;
        }
        return null;
    }

    /// Decode an instruction through any debugger patch currently covering its
    /// opcode byte. Used for both granular-step selection and UI breadcrumbs.
    pub fn instructionOpcode(self: *const BreakpointTable, chunk_id: ChunkId, chunk: *const Chunk, offset: u32) ?opcode.OpCode {
        if (offset >= chunk.code.len) return null;
        const raw = self.originalOpcodeByte(chunk_id, offset, chunk);
        if (raw >= opcode.count) return null;
        return @enumFromInt(raw);
    }

    /// Restore debugger-patched opcode bytes in a caller-owned copy of a
    /// chunk's code. Inspectors should describe the program, not the trap bytes
    /// temporarily installed to implement breakpoints and granular stepping.
    pub fn restoreOriginalCode(
        self: *const BreakpointTable,
        chunk_id: ChunkId,
        destination: []u8,
    ) void {
        for (self.placements.items) |placement| {
            if (placement.chunk_id == chunk_id and placement.offset < destination.len)
                destination[placement.offset] = placement.original;
        }
        for (self.step_temps.items) |placement| {
            if (placement.chunk_id == chunk_id and placement.offset < destination.len)
                destination[placement.offset] = placement.original;
        }
    }

    fn instructionEnd(self: *const BreakpointTable, chunk_id: ChunkId, chunk: *const Chunk, start: usize) ?usize {
        const raw = self.originalOpcodeByte(chunk_id, start, chunk);
        if (raw >= opcode.count) return null;
        const op: opcode.OpCode = @enumFromInt(raw);
        const operands_start = start + 1;
        const operands_len = opcode.operandLen(op, chunk.code, operands_start);
        if (operands_len > chunk.code.len - operands_start) return null;
        return operands_start + operands_len;
    }

    fn firstExactSpanSite(
        self: *const BreakpointTable,
        chunk_id: ChunkId,
        chunk: *const Chunk,
        wanted: Chunk.SourceSpan,
    ) ?u32 {
        var start: usize = 0;
        while (start < chunk.code.len) {
            var best: ?Chunk.SourceMapEntry = null;
            for (chunk.source_map) |entry| {
                if (start < entry.start or start >= entry.end) continue;
                if (best == null or entry.end - entry.start <= best.?.end - best.?.start)
                    best = entry;
            }
            if (best) |entry| if (sameSpan(entry.span, wanted)) return @intCast(start);
            const next = self.instructionEnd(chunk_id, chunk, start) orelse return null;
            if (next <= start) return null;
            start = next;
        }
        return null;
    }

    fn placedAt(self: *const BreakpointTable, chunk_id: ChunkId, offset: u32) bool {
        for (self.placements.items) |p| {
            if (p.chunk_id == chunk_id and p.offset == offset) return true;
        }
        return false;
    }

    fn stepPlacedAt(self: *const BreakpointTable, chunk_id: ChunkId, offset: u32) bool {
        for (self.step_temps.items) |p| {
            if (p.chunk_id == chunk_id and p.offset == offset) return true;
        }
        return false;
    }

    fn placeStepSite(self: *BreakpointTable, chunk_id: ChunkId, offset: u32, chunk: *const Chunk) !void {
        if (offset >= chunk.code.len) return;
        if (self.instructionBoundaryAtOrAfter(chunk_id, chunk, offset) != offset) return;
        if (self.placedAt(chunk_id, offset) or self.stepPlacedAt(chunk_id, offset)) return;
        if (chunk.code[offset] == breakpoint_byte) return;
        try self.step_temps.append(self.gpa, .{
            .req_id = step_request_id,
            .chunk_id = chunk_id,
            .offset = offset,
            .original = chunk.code[offset],
        });
        chunk.code[offset] = breakpoint_byte;
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
        try self.placeSite(req.id, chunk_id, start, chunk);
    }

    /// Patch one `(chunk_id, offset)` site to the breakpoint opcode under
    /// `req_id`, saving the original byte. Rejects offsets that aren't a real
    /// instruction boundary, sites already owned by another permanent
    /// placement, and promotes an overlapping step temp so a resolving
    /// permanent breakpoint doesn't get lost when the step clears.
    fn placeSite(self: *BreakpointTable, req_id: u32, chunk_id: ChunkId, offset: u32, chunk: *const Chunk) !void {
        if (offset >= chunk.code.len) return;
        if (self.instructionBoundaryAtOrAfter(chunk_id, chunk, offset) != offset) return;
        for (self.placements.items) |p| {
            if (p.chunk_id == chunk_id and p.offset == offset) return;
        }
        try self.placements.ensureUnusedCapacity(self.gpa, 1);
        var original = chunk.code[offset];
        if (original == breakpoint_byte) {
            const promoted = self.takeStepPlacement(chunk_id, offset) orelse return;
            original = promoted.original;
        }
        self.placements.appendAssumeCapacity(.{
            .req_id = req_id,
            .chunk_id = chunk_id,
            .offset = offset,
            .original = original,
        });
        // `chunk.code` is `[]u8`; the bytes are mutable even through `*const`.
        chunk.code[offset] = breakpoint_byte;
    }

    fn takeStepPlacement(self: *BreakpointTable, chunk_id: ChunkId, offset: u32) ?Placement {
        for (self.step_temps.items, 0..) |placement, i| {
            if (placement.chunk_id == chunk_id and placement.offset == offset)
                return self.step_temps.orderedRemove(i);
        }
        return null;
    }

    /// Read the opcode which was present before any debugger patch at this
    /// site, allowing boundary scans to run while permanent or temporary
    /// breakpoints are armed.
    fn originalOpcodeByte(self: *const BreakpointTable, chunk_id: ChunkId, offset: usize, chunk: *const Chunk) u8 {
        for (self.placements.items) |p| {
            if (p.chunk_id == chunk_id and p.offset == offset) return p.original;
        }
        for (self.step_temps.items) |p| {
            if (p.chunk_id == chunk_id and p.offset == offset) return p.original;
        }
        return chunk.code[offset];
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

fn textFileMatches(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    if (std.mem.endsWith(u8, a, b) or std.mem.endsWith(u8, b, a)) return true;
    return std.mem.eql(u8, std.fs.path.basename(a), std.fs.path.basename(b));
}

fn sameSpan(a: Chunk.SourceSpan, b: Chunk.SourceSpan) bool {
    return a.file == b.file and
        a.offset == b.offset and
        a.len == b.len and
        a.line == b.line and
        a.column == b.column;
}

fn firstMappedOffset(chunk: *const Chunk) ?u32 {
    var best: ?u32 = null;
    for (chunk.source_map) |entry| {
        if (best == null or entry.start < best.?) best = entry.start;
    }
    return best;
}

/// Instructions whose execution can enter another frame, force one or more
/// lazy values, or otherwise perform a strict evaluation boundary. Stack-only
/// plumbing is intentionally absent: source stepping should be more precise,
/// not a bytecode single-step firehose.
fn evaluationStepBoundary(op: opcode.OpCode) bool {
    return switch (op) {
        .loc_get,
        .loc_get_w,
        .up_get,
        .int_add,
        .int_sub,
        .int_mul,
        .int_div,
        .int_neg,
        .flt_add,
        .flt_sub,
        .flt_mul,
        .flt_div,
        .cmp_eq,
        .cmp_ne,
        .cmp_lt,
        .cmp_le,
        .cmp_gt,
        .cmp_ge,
        .cmp_eq_null,
        .cmp_ne_null,
        .bool_not,
        .jump_false,
        .attrs_new,
        .attrs_merge_strict,
        .attrs_merge,
        .list_cat,
        .list_cat_n,
        .str_cat,
        .path_cat,
        .thunk_arg,
        .call,
        .call_tail,
        .call_n,
        .call_tail_n,
        .loc_get_ret,
        .loc_get_ret_w,
        .up_get_ret,
        .up_get_attr,
        .loc_get_attr,
        .loc_get_attr_w,
        .attr_get,
        .attr_get_w,
        .attr_has_strict,
        .attr_has_strict_w,
        .attr_get_dyn,
        .attr_get_dyn_or,
        .attr_get_path_dyn_or,
        .attr_get_path_dyn_or_w,
        .attr_get_path_or,
        .attr_get_path_or_w,
        .attr_get_path_mix_or,
        .attr_has_path,
        .attr_has_path_w,
        .attr_has_path_mix,
        .attr_bind,
        .attr_bind_w,
        .with_lookup,
        .with_lookup_w,
        .arg_or_lit,
        .attrs_apply_overrides,
        => true,
        else => false,
    };
}

test "step sites advance suspended operand ips to instruction boundaries" {
    var intern = try InternTable.init(std.testing.allocator);
    defer intern.deinit();
    var table = BreakpointTable.init(std.testing.allocator, &intern);
    defer table.deinit();

    // loc_get has one operand and push_const has two. A handler can suspend
    // with its saved ip at any of the marked operand positions.
    var code = [_]u8{
        @intFromEnum(opcode.OpCode.loc_get),    7,
        @intFromEnum(opcode.OpCode.push_const), 0,
        0,                                      @intFromEnum(opcode.OpCode.halt),
    };
    var constants: [0]Value = .{};
    var chunk: Chunk = .{ .code = &code, .constants = &constants, .local_count = 0 };

    try std.testing.expectEqual(@as(?u32, 0), table.instructionBoundaryAtOrAfter(9, &chunk, 0));
    try std.testing.expectEqual(@as(?u32, 2), table.instructionBoundaryAtOrAfter(9, &chunk, 1));
    try std.testing.expectEqual(@as(?u32, 2), table.instructionBoundaryAtOrAfter(9, &chunk, 2));
    try std.testing.expectEqual(@as(?u32, 5), table.instructionBoundaryAtOrAfter(9, &chunk, 3));
    try std.testing.expectEqual(@as(?u32, 5), table.instructionBoundaryAtOrAfter(9, &chunk, 4));

    // A raw operand offset is rejected, while the normalized boundary is
    // patched. Boundary scans still work through that debugger-owned patch.
    try table.placeStepSite(9, 1, &chunk);
    try std.testing.expectEqual(@as(u8, 7), code[1]);
    try table.placeStepSite(9, 2, &chunk);
    try std.testing.expectEqual(breakpoint_byte, code[2]);
    var inspected = code;
    table.restoreOriginalCode(9, &inspected);
    try std.testing.expectEqual(@intFromEnum(opcode.OpCode.push_const), inspected[2]);
    try std.testing.expectEqual(breakpoint_byte, code[2]);
    try std.testing.expectEqual(@as(?u32, 5), table.instructionBoundaryAtOrAfter(9, &chunk, 3));
    try std.testing.expectEqual(@as(?u32, 0), table.instructionForSavedIp(9, &chunk, 1));
    try std.testing.expectEqual(@as(?u32, 0), table.instructionForSavedIp(9, &chunk, 2));
    try std.testing.expectEqual(@as(?u32, 2), table.instructionForSavedIp(9, &chunk, 3));
    try std.testing.expectEqual(@as(?u32, 2), table.instructionForSavedIp(9, &chunk, 5));
}

test "evaluation step sites include forces and calls but skip stack plumbing" {
    var intern = try InternTable.init(std.testing.allocator);
    defer intern.deinit();
    var table = BreakpointTable.init(std.testing.allocator, &intern);
    defer table.deinit();

    var code = [_]u8{
        @intFromEnum(opcode.OpCode.push_null),
        @intFromEnum(opcode.OpCode.loc_get),
        0,
        @intFromEnum(opcode.OpCode.pop),
        @intFromEnum(opcode.OpCode.call),
        @intFromEnum(opcode.OpCode.halt),
    };
    var constants: [0]Value = .{};
    var chunk: Chunk = .{ .code = &code, .constants = &constants, .local_count = 1 };
    var sites: std.ArrayListUnmanaged(BreakpointTable.Site) = .empty;
    defer sites.deinit(std.testing.allocator);

    try table.appendEvaluationStepSites(std.testing.allocator, 3, &chunk, 1, &sites);
    try std.testing.expectEqualSlices(BreakpointTable.Site, &.{.{ .chunk_id = 3, .offset = 4 }}, sites.items);
}

test "source-span breakpoints distinguish nested expressions on one line" {
    const allocator = std.testing.allocator;
    var intern = try InternTable.init(allocator);
    defer intern.deinit();
    var registry = try ChunkRegistry.init(allocator);
    defer registry.deinit();
    var table = BreakpointTable.init(allocator, &intern);
    defer table.deinit();

    var builder = try chunk_mod.ChunkBuilder.init(allocator);
    defer builder.deinit(allocator);
    try builder.emitConstant(allocator, Value.int(1)); // 0..3
    try builder.emitConstant(allocator, Value.int(2)); // 3..6
    try builder.writeOp(allocator, .int_add); // 6..7
    try builder.writeOp(allocator, .ret);
    try builder.writeOp(allocator, .halt);

    const outer: Chunk.SourceSpan = .{ .file = null, .offset = 0, .len = 5, .line = 1, .column = 1 };
    const left: Chunk.SourceSpan = .{ .file = null, .offset = 0, .len = 1, .line = 1, .column = 1 };
    const right: Chunk.SourceSpan = .{ .file = null, .offset = 4, .len = 1, .line = 1, .column = 5 };
    try builder.addSourceMapEntry(allocator, 0, 3, left);
    try builder.addSourceMapEntry(allocator, 3, 6, right);
    try builder.addSourceMapEntry(allocator, 0, 7, outer);

    const chunk_id = try registry.register(try builder.finish(allocator, 0));
    const chunk = registry.get(chunk_id).?;

    try std.testing.expectEqual(@as(usize, 1), (try table.setSpan(&registry, chunk_id, left)).sites);
    try std.testing.expectEqual(@as(usize, 1), (try table.setSpan(&registry, chunk_id, right)).sites);
    try std.testing.expectEqual(@as(usize, 1), (try table.setSpan(&registry, chunk_id, outer)).sites);
    try std.testing.expect(table.hasSpan(chunk_id, left));
    try std.testing.expect(table.hasSpan(chunk_id, right));
    try std.testing.expect(table.hasSpan(chunk_id, outer));
    try std.testing.expect(table.hasSite(chunk_id, 0));
    try std.testing.expect(table.hasSite(chunk_id, 3));
    try std.testing.expect(table.hasSite(chunk_id, 6));

    try std.testing.expect(table.removeSpan(&registry, chunk_id, outer));
    try std.testing.expect(!table.hasSpan(chunk_id, outer));
    try std.testing.expectEqual(@as(u8, @intFromEnum(opcode.OpCode.int_add)), chunk.code[6]);
    try std.testing.expect(table.hasSpan(chunk_id, left));
    try std.testing.expect(table.hasSpan(chunk_id, right));
    try std.testing.expect(table.removeSpan(&registry, chunk_id, left));
    try std.testing.expect(table.removeSpan(&registry, chunk_id, right));
}
