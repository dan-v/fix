//! Driving a single evaluation: run the source, write the result, render
//! failures, and load source text.

const std = @import("std");
const render = @import("render.zig");
const args = @import("args.zig");
const derivation_debug = @import("derivation_debug.zig");
const eval = @import("../eval.zig");
const Evaluator = eval.Evaluator;
const Value = @import("runtime").value.Value;
const EvaluationMode = args.EvaluationMode;
const SourceArg = args.SourceArg;

/// Evaluate `source`, write the result (or render the failure), and emit any
/// requested derivation-debug records. Returns whether evaluation succeeded.
pub fn evaluateAndWrite(
    io: std.Io,
    mode: EvaluationMode,
    use_color: bool,
    show_trace: bool,
    debug_options: derivation_debug.Options,
    ev: *Evaluator,
    source: []const u8,
    label: []const u8,
) !bool {
    // Bracket the whole run (evaluate + force + render) so the progress bar
    // keeps an always-open "evaluating <label>" node and a ~100ms counter
    // sampler running across every phase. Defers are LIFO: the sampler stops
    // (and joins) before the session's nodes are torn down.
    ev.progressSessionBegin(label);
    defer ev.progressSessionEnd();
    ev.startProgressSampler();
    defer ev.stopProgressSampler();

    const result = ev.evaluate(source) catch |err| {
        try render.evalFailure(io, use_color, show_trace, ev, source, err);
        return false;
    };

    writeResult(io, mode, ev, result) catch |err| {
        try render.evaluationError(io, use_color, show_trace, ev, source, err);
        return false;
    };
    try derivation_debug.write(io, use_color, ev.allocator, debug_options, ev.derivationDebugRecords());
    return true;
}

fn writeResult(io: std.Io, mode: EvaluationMode, ev: *Evaluator, result: Value) !void {
    if (mode.strict) try ev.forceDeep(result);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    switch (mode.output) {
        .nix => try ev.writeValue(&stdout.interface, result),
        .json => try ev.writeJsonValue(&stdout.interface, result),
        .xml => try ev.writeXmlValue(&stdout.interface, result),
    }
    if (mode.output != .xml) try stdout.interface.writeByte('\n');
    try stdout.interface.flush();
}

pub const Source = struct {
    text: []const u8,
};

pub fn getSource(ev: *Evaluator, source: SourceArg) !Source {
    return switch (source) {
        .expr => |text| .{ .text = text },
        .file => |path| .{ .text = try ev.readSourceFile(path) },
    };
}
