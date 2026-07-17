//! Wiring for the optional `--vm-trace` and `--thunks-log` event sinks.
//!
//! Each `setup*` allocates the writer + trace object (when the corresponding
//! build flag is on and a path was requested) and returns an owner that the
//! caller `deinit`s; `finish` flushes before teardown.

const std = @import("std");
const engine = @import("nix");
const Evaluator = engine.Evaluator;
const Options = @import("args.zig").Options;
const vm_trace_mod = engine.tooling.vm.trace_log;
const thunk_trace_mod = engine.tooling.probe.thunk_trace;
const thunks_log_enabled = engine.tooling.vm.thunks_log_enabled;

pub const ThunkTraceSetup = struct {
    trace: ?*thunk_trace_mod.ThunkTrace = null,
    file: ?std.Io.File = null,
    io: ?std.Io = null,
    writer: ?*std.Io.File.Writer = null,
    buffer: []u8 = &.{},

    pub fn deinit(self: *ThunkTraceSetup, allocator: std.mem.Allocator) void {
        if (self.writer) |w| allocator.destroy(w);
        if (self.trace) |t| allocator.destroy(t);
        if (self.buffer.len > 0) allocator.free(self.buffer);
        if (self.file) |f| if (self.io) |io| f.close(io);
    }

    pub fn finish(self: *ThunkTraceSetup) void {
        if (self.trace) |t| t.flush() catch {};
    }
};

pub fn setupThunkTrace(
    allocator: std.mem.Allocator,
    io: std.Io,
    ev: *Evaluator,
    options: Options,
) !ThunkTraceSetup {
    var setup: ThunkTraceSetup = .{};
    const path = options.thunks_log_path orelse return setup;
    if (comptime !thunks_log_enabled) {
        std.debug.print(
            "warning: --thunks-log requested but binary was built without -Dthunks-log; the log will be empty\n",
            .{},
        );
        return setup;
    }

    setup.buffer = try allocator.alloc(u8, 64 * 1024);
    errdefer allocator.free(setup.buffer);

    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    setup.file = file;
    setup.io = io;
    const writer_ptr = try allocator.create(std.Io.File.Writer);
    errdefer allocator.destroy(writer_ptr);
    writer_ptr.* = file.writerStreaming(io, setup.buffer);
    setup.writer = writer_ptr;

    const trace_ptr = try allocator.create(thunk_trace_mod.ThunkTrace);
    errdefer allocator.destroy(trace_ptr);
    trace_ptr.* = ev.initThunkTrace(&writer_ptr.interface);
    setup.trace = trace_ptr;
    return setup;
}

pub const VmTraceSetup = struct {
    trace: ?*vm_trace_mod.VmTrace = null,
    trace_storage: ?*vm_trace_mod.VmTrace = null,
    file: ?std.Io.File = null,
    io: ?std.Io = null,
    writer: ?*std.Io.File.Writer = null,
    buffer: []u8 = &.{},

    pub fn deinit(self: *VmTraceSetup, allocator: std.mem.Allocator) void {
        if (self.writer) |w| allocator.destroy(w);
        if (self.trace_storage) |t| allocator.destroy(t);
        if (self.buffer.len > 0) allocator.free(self.buffer);
        if (self.file) |f| if (self.io) |io| f.close(io);
    }

    pub fn finish(self: *VmTraceSetup) void {
        if (self.trace) |t| t.flush() catch {};
    }
};

pub fn setupVmTrace(allocator: std.mem.Allocator, io: std.Io, options: Options) !VmTraceSetup {
    var setup: VmTraceSetup = .{};
    const path = options.vm_trace_path orelse return setup;

    if (!vm_trace_mod.enabled) {
        std.debug.print("warning: --vm-trace requested but binary was built without -Dvm-trace=true\n", .{});
        return setup;
    }

    setup.buffer = try allocator.alloc(u8, 64 * 1024);
    errdefer allocator.free(setup.buffer);

    if (std.mem.eql(u8, path, "-")) {
        const writer_ptr = try allocator.create(std.Io.File.Writer);
        errdefer allocator.destroy(writer_ptr);
        writer_ptr.* = std.Io.File.stderr().writerStreaming(io, setup.buffer);
        setup.writer = writer_ptr;
    } else {
        const file = try std.Io.Dir.cwd().createFile(io, path, .{});
        setup.file = file;
        setup.io = io;
        const writer_ptr = try allocator.create(std.Io.File.Writer);
        errdefer allocator.destroy(writer_ptr);
        writer_ptr.* = file.writerStreaming(io, setup.buffer);
        setup.writer = writer_ptr;
    }

    const trace_ptr = try allocator.create(vm_trace_mod.VmTrace);
    errdefer allocator.destroy(trace_ptr);
    trace_ptr.* = vm_trace_mod.VmTrace.init(&setup.writer.?.interface, switch (options.vm_trace_format) {
        .text => .text,
        .binary => .binary,
    });
    trace_ptr.setMaxEvents(options.vm_trace_max_events);
    trace_ptr.setMainOnly(options.vm_trace_main_only);
    setup.trace_storage = trace_ptr;
    setup.trace = trace_ptr;
    return setup;
}
