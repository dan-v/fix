//! Borrowed, responsibility-oriented views over the lifecycle-owning engine.
//!
//! These are intentionally zero-state adapters. They make dependencies
//! explicit at call sites without duplicating state or introducing callback
//! indirection between expression-engine layers.

const std = @import("std");
const runtime = @import("runtime");
const store = @import("store");
const bytecode = @import("../bytecode.zig");
const BuildSession = @import("../build_session.zig").BuildSession;
const ReleaseAction = @import("../eval/lifecycle.zig").ReleaseAction;

const Value = runtime.Value;
const ChunkId = runtime.types.ChunkId;

pub fn Evaluation(comptime Service: type) type {
    return struct {
        engine: *Service,

        pub fn evaluate(self: @This(), source: []const u8) !Value {
            return self.engine.evaluate(source);
        }

        pub fn evaluatePath(self: @This(), source: []const u8, source_path: ?[]const u8) !Value {
            return self.engine.evaluatePath(source, source_path);
        }

        pub fn evaluatePathAt(self: @This(), source: []const u8, base_path: ?[]const u8, source_path: ?[]const u8) !Value {
            return self.engine.evaluatePathAt(source, base_path, source_path);
        }

        pub fn evaluateWithScope(self: @This(), source: []const u8, scope: ?Value) !Value {
            return self.engine.evaluateWithScope(source, scope);
        }

        pub fn force(self: @This(), value: Value) !Value {
            return self.engine.forceValue(value);
        }

        pub fn forceDeep(self: @This(), value: Value) !void {
            return self.engine.forceDeep(value);
        }
    };
}

pub fn Values(comptime Service: type) type {
    return struct {
        engine: *Service,

        pub fn write(self: @This(), writer: *std.Io.Writer, value: Value) !void {
            return self.engine.writeValue(writer, value);
        }

        pub fn writeRaw(self: @This(), writer: *std.Io.Writer, value: Value) !void {
            return self.engine.writeRawValue(writer, value);
        }

        pub fn writeJson(self: @This(), writer: *std.Io.Writer, value: Value) !void {
            return self.engine.writeJsonValue(writer, value);
        }

        pub fn writeXml(self: @This(), writer: *std.Io.Writer, value: Value) !void {
            return self.engine.writeXmlValue(writer, value);
        }

        pub fn attr(self: @This(), value: Value, name: []const u8) !?Value {
            return self.engine.getAttr(value, name);
        }

        pub fn attrPath(self: @This(), value: Value, path: []const u8) !?Value {
            return self.engine.attrPathValue(value, path);
        }

        pub fn string(self: @This(), value: Value) !?[]const u8 {
            return self.engine.stringValue(value);
        }
    };
}

pub fn Sources(comptime Service: type) type {
    return struct {
        engine: *Service,

        pub fn readFile(self: @This(), path: []const u8) ![]const u8 {
            return self.engine.readSourceFile(path);
        }

        pub fn resolveLookupPath(self: @This(), allocator: std.mem.Allocator, name: []const u8) ![]u8 {
            return self.engine.resolveLookupPath(allocator, name);
        }

        pub fn fetchTarballPath(self: @This(), allocator: std.mem.Allocator, url: []const u8) ![]u8 {
            return self.engine.fetchTarballPath(allocator, url);
        }

        pub fn resolveHostPath(self: @This(), path: []const u8) !@import("../eval/search_path.zig").ResolvedPath {
            return self.engine.resolveHostPath(path);
        }
    };
}

pub fn Debugger(comptime Service: type) type {
    return struct {
        engine: *Service,

        pub fn tooling(self: @This()) Service.Tooling {
            return self.engine.tooling();
        }

        pub fn setBreakpoint(self: @This(), file: []const u8, line: u32) !bytecode.BreakpointTable.SetResult {
            return self.engine.setBreakpoint(file, line);
        }

        pub fn deleteBreakpoint(self: @This(), id: u32) bool {
            return self.engine.deleteBreakpoint(id);
        }

        pub fn clearUi(self: @This()) void {
            self.engine.clearDebugUi();
        }
    };
}

pub fn Inspection(comptime Service: type) type {
    return struct {
        engine: *const Service,

        pub fn heapStats(self: @This()) runtime.heap.ObjectHeap.Stats {
            return self.engine.heapStats();
        }

        pub fn heapCounts(self: @This()) runtime.heap.ObjectHeap.Counts {
            return self.engine.heapCounts();
        }

        pub fn getChunk(self: @This(), id: ChunkId) ?*const bytecode.Chunk {
            return self.engine.getChunk(id);
        }

        pub fn workerCount(self: @This()) u8 {
            return self.engine.workerCount();
        }
    };
}

pub fn Builds(comptime Service: type) type {
    return struct {
        engine: *Service,

        pub fn enableWrites(self: @This()) void {
            self.engine.enableStoreWrites();
        }

        pub fn begin(self: @This(), derived_paths: []const []const u8, after_release: ?ReleaseAction) !BuildSession {
            return self.engine.beginBuildPhase(derived_paths, after_release);
        }

        pub fn configureDaemon(self: @This(), settings: store.daemon.BuildSettings) !void {
            return self.engine.setDaemonBuildSettings(settings);
        }

        pub fn setStoreDir(self: @This(), dir: []const u8) !void {
            return self.engine.setStoreDir(dir);
        }
    };
}

pub fn Instrumentation(comptime Service: type) type {
    return struct {
        engine: *Service,

        pub fn setTraceFlows(self: @This(), enabled: bool) void {
            self.engine.setTraceFlows(enabled);
        }

        pub fn setTraceVerbose(self: @This(), enabled: bool) void {
            self.engine.setTraceVerbose(enabled);
        }

        pub fn collectNow(self: @This()) Service.CollectNowResult {
            return self.engine.collectNow();
        }
    };
}
