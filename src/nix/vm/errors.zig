//! Error-trace capture: walk the VM frame stack turning each frame's source span
//! into a "while evaluating" diagnostic note, plus the span-resolution helpers
//! (frame / chunk-entry / tightest-span-for-ip) shared with the timeline.
const std = @import("std");
const vm_mod = @import("context.zig");
const chunk = @import("../bytecode.zig").chunk;
const diagnostic = @import("syntax").diagnostic;

const VM = vm_mod.VM;
const Frame = vm_mod.Frame;

pub fn captureErrorTrace(self: *VM, err: anyerror) !void {
    const trace = self.trace orelse return;
    try trace.setMessageIfAbsent(defaultErrorMessage(err));
    if (trace.captured_stack) return;
    // Speculative thunk forces point vm.trace at a per-fiber scratch
    // trace whose only consumer is publishThunkFailure (which dupes
    // the message). Walking the frame stack to push N diagnostic
    // frames here is pure waste — skip it for those traces.
    if (trace.frames_disabled) {
        trace.markCapturedStack();
        return;
    }

    var previous: ?chunk.Chunk.SourceSpan = null;
    var i: usize = self.frames_len;
    while (i > 0) {
        i -= 1;
        const frame = self.frames[i];
        const span = sourceSpanForFrame(frame) orelse continue;
        if (previous) |prev| {
            if (sameSourceSpan(prev, span)) continue;
        }
        previous = span;
        // Attribute the frame to its qualified name when we have one, so the
        // trace reads `while evaluating 'pkgs.hello'` — always available now
        // via the name tree, no flag. Falls back to the bare note otherwise.
        var name_buf: [512]u8 = undefined;
        const message = frameMessage(self, frame.chunk_id, &name_buf);
        const diag_frame = diagnostic.Diagnostic{
            .severity = .note,
            .kind = .compile,
            .line = span.line,
            .column = span.column,
            .offset = span.offset,
            .len = span.len,
            .token_type = null,
            .message = message,
        };
        const source_path = if (span.file) |file| self.intern.get(file) else null;
        try trace.pushDiagnosticFrame(source_path, diag_frame);
    }
    trace.markCapturedStack();
}

/// The `while evaluating [<name>]` note for a frame, rendering the chunk's
/// qualified name into `buf` when it has one (else the bare note). Cold path.
fn frameMessage(self: *VM, chunk_id: @import("runtime").types.ChunkId, buf: []u8) []const u8 {
    if (!self.registry.hasQualifiedName(chunk_id)) return "while evaluating";
    var w: std.Io.Writer = .fixed(buf);
    w.writeAll("while evaluating '") catch return "while evaluating";
    self.registry.writeQualifiedName(&w, chunk_id, self.intern) catch return "while evaluating";
    w.writeByte('\'') catch return "while evaluating";
    return buf[0..w.end];
}

pub fn sourceSpanForFrame(frame: Frame) ?chunk.Chunk.SourceSpan {
    return sourceSpanForChunk(frame.chunk_ptr, frame.ip);
}

/// A chunk's representative source span for labelling a THUNK (which starts at
/// ip 0). Source maps are SPARSE — spans are added only for tail/apply
/// constructs, in code order — so ip 0 is usually uncovered by
/// `sourceSpanForChunk`; use the earliest recorded span instead. Null if the
/// chunk has no source map.
pub fn chunkEntrySpan(chunk_ptr: *const chunk.Chunk) ?chunk.Chunk.SourceSpan {
    // The body span covers every chunk (set at compile from the body node);
    // fall back to the earliest source-map entry for chunks that skipped it.
    if (chunk_ptr.body_span) |s| return s;
    if (chunk_ptr.source_map.len == 0) return null;
    return chunk_ptr.source_map[0].span;
}

/// The tightest source span covering `ip` in `chunk_ptr` (or null if the chunk
/// carries no source map). `ip == 0` resolves the chunk's entry point — used by
/// the timeline to label a thunk quantum with the expression it forces.
pub fn sourceSpanForChunk(chunk_ptr: *const chunk.Chunk, ip: usize) ?chunk.Chunk.SourceSpan {
    if (chunk_ptr.source_map.len == 0) return null;
    const pc = if (ip == 0) 0 else ip - 1;
    var best: ?chunk.Chunk.SourceMapEntry = null;
    for (chunk_ptr.source_map) |entry| {
        if (pc < entry.start or pc >= entry.end) continue;
        if (best == null or entry.end - entry.start <= best.?.end - best.?.start) {
            best = entry;
        }
    }
    return if (best) |entry| entry.span else null;
}

pub fn sameSourceSpan(left: chunk.Chunk.SourceSpan, right: chunk.Chunk.SourceSpan) bool {
    return left.file == right.file and
        left.offset == right.offset and
        left.len == right.len and
        left.line == right.line and
        left.column == right.column;
}

pub fn defaultErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.TypeError => "type error",
        error.StackOverflow => "stack overflow (possible infinite recursion)",
        error.NotCallable => "value is not callable",
        error.MissingAttribute => "missing attribute",
        error.UndefinedVariable => "undefined variable",
        error.DivisionByZero => "division by zero",
        error.AssertionFailed => "assertion failed",
        error.ImportCycle => "import cycle detected",
        error.FileNotFound => "No such file or directory",
        error.UnsupportedPathType => "file has an unsupported type",
        error.MissingExperimentalFeature => "experimental feature disabled",
        else => @errorName(err),
    };
}
