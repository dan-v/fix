const std = @import("std");
const vm_mod = @import("../vm.zig");
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
        const diag_frame = diagnostic.Diagnostic{
            .severity = .note,
            .kind = .compile,
            .line = span.line,
            .column = span.column,
            .offset = span.offset,
            .len = span.len,
            .token_type = null,
            .message = "while evaluating",
        };
        const source_path = if (span.file) |file| self.intern.get(file) else null;
        try trace.pushDiagnosticFrame(source_path, diag_frame);
    }
    trace.markCapturedStack();
}

pub fn sourceSpanForFrame(frame: Frame) ?chunk.Chunk.SourceSpan {
    if (frame.chunk_ptr.source_map.len == 0) return null;
    const pc = if (frame.ip == 0) 0 else frame.ip - 1;
    var best: ?chunk.Chunk.SourceMapEntry = null;
    for (frame.chunk_ptr.source_map) |entry| {
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
        error.NotCallable => "value is not callable",
        error.MissingAttribute => "missing attribute",
        error.UndefinedVariable => "undefined variable",
        error.DivisionByZero => "division by zero",
        error.AssertionFailed => "assertion failed",
        error.ImportCycle => "import cycle detected",
        error.FileNotFound => "file not found",
        else => @errorName(err),
    };
}
