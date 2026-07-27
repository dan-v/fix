const std = @import("std");
const eval_mod = @import("../../evaluator.zig");
const Engine = eval_mod.Engine;
const Value = @import("runtime").value.Value;
const heap_mod = @import("runtime").heap;
const vm = @import("../../vm.zig");
const vm_builtins = vm.builtins;
const vm_force = vm.force;
const FakeDaemon = @import("store").realization.testing.FakeDaemon;

/// Task 5 GREEN exposes the one shared path-demand integration through the VM
/// builtin facade. Until then every regression below reports this exact RED,
/// rather than accidentally passing through the legacy live-derivation path.
fn sharedDemandIntegrationAvailable() bool {
    return @hasDecl(vm_builtins, "demandPathArg");
}

const DemandCase = enum {
    read_file,
    path_exists,
    read_file_type,
    read_dir,
    import_file,
    scoped_import,
    interpolated_subpath,
};

const ProducedOutput = struct {
    output: Value,
    derivation_id: @import("runtime").types.ObjectId,
};

const DemandFixture = struct {
    allocator: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    store_dir: []u8,
    fake: *FakeDaemon,
    ev: Engine,

    fn init(allocator: std.mem.Allocator, workers: u8) !DemandFixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDir(std.testing.io, "store", .default_dir);

        const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
        defer allocator.free(cwd);
        const store_dir = try std.fs.path.resolve(allocator, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "store" });
        errdefer allocator.free(store_dir);

        const fake = try FakeDaemon.start(allocator, std.testing.io);
        errdefer fake.deinit();
        var ev = try Engine.init(allocator, .{ .worker_count = workers });
        errdefer ev.deinit();
        ev.setFileIo(std.testing.io);
        ev.store.realization.store_dir = store_dir;
        ev.store.realization.setDaemonSocketBorrowedForTest(fake.socketPath());

        return .{
            .allocator = allocator,
            .tmp = tmp,
            .store_dir = store_dir,
            .fake = fake,
            .ev = ev,
        };
    }

    fn deinit(self: *DemandFixture) void {
        self.ev.deinit();
        self.fake.deinit();
        self.allocator.free(self.store_dir);
        self.tmp.cleanup();
    }

    /// Construct the derivation-shaped attrset explicitly, capture its exact
    /// ObjectId, then return only that id and the forced context-bearing output.
    /// No Value retaining the attrset escapes this frame.
    fn makeDerivationAndOutput(self: *DemandFixture) !ProducedOutput {
        const derived = try self.ev.evaluate(
            \\builtins.derivation {
            \\  name = "cold-path-demand";
            \\  system = "x86_64-linux";
            \\  builder = "/bin/sh";
            \\  args = [ ];
            \\}
        );
        if (!derived.isAttrs()) return error.ExpectedDerivationAttrs;
        const derivation_id = derived.asObjectId();
        const output = try self.ev.forceValue(try self.ev.heap.getAttrValue(
            derivation_id,
            try self.ev.intern.intern("outPath"),
        ));
        return .{ .output = output, .derivation_id = derivation_id };
    }

    fn makeOutputOnly(self: *DemandFixture) !Value {
        return (try self.makeDerivationAndOutput()).output;
    }

    fn outputInfo(self: *DemandFixture, output: Value) !struct { path: []const u8, drv_path: []const u8 } {
        const string = try self.ev.heap.getContextString(output.asObjectId());
        var drv_path: ?[]const u8 = null;
        for (string.context) |entry| {
            const path = self.ev.intern.get(entry.name);
            if (std.mem.endsWith(u8, path, ".drv")) drv_path = path;
        }
        return .{
            .path = self.ev.intern.get(string.text),
            .drv_path = drv_path orelse return error.MissingDerivationContext,
        };
    }

    fn registerOutputTree(self: *DemandFixture, output: Value) ![]u8 {
        const info = try self.outputInfo(output);
        const subject = try std.fmt.allocPrint(self.allocator, "{s}!out", .{info.drv_path});
        errdefer self.allocator.free(subject);

        const nested = try std.fs.path.resolve(self.allocator, &.{ info.path, "nested" });
        defer self.allocator.free(nested);
        const payload = try std.fs.path.resolve(self.allocator, &.{ info.path, "payload.txt" });
        defer self.allocator.free(payload);
        const imported = try std.fs.path.resolve(self.allocator, &.{ info.path, "import.nix" });
        defer self.allocator.free(imported);
        const scoped = try std.fs.path.resolve(self.allocator, &.{ info.path, "scope.nix" });
        defer self.allocator.free(scoped);
        const nested_payload = try std.fs.path.resolve(self.allocator, &.{ nested, "child.txt" });
        defer self.allocator.free(nested_payload);

        try self.fake.registerBuildDirectory(subject, info.path);
        try self.fake.registerBuildDirectory(subject, nested);
        try self.fake.registerBuildFile(subject, payload, "cold payload");
        try self.fake.registerBuildFile(subject, imported, "{ value = 42; }\n");
        try self.fake.registerBuildFile(subject, scoped, "x + y\n");
        try self.fake.registerBuildFile(subject, nested_payload, "nested payload");
        return subject;
    }

    fn scopeWithOutput(self: *DemandFixture, output: Value) !Value {
        const entries = [_]heap_mod.AttrEntry{.{
            .name = try self.ev.intern.intern("p"),
            .value = output,
        }};
        return Value.attrs(try self.ev.heap.addAttrs(&entries));
    }

    fn assertOneRealization(self: *DemandFixture, output: Value, subject: []const u8) !void {
        const info = try self.outputInfo(output);
        const drv_basename = std.fs.path.basename(info.drv_path);
        try std.testing.expect(drv_basename.len > 33 and drv_basename[32] == '-');
        try std.testing.expectEqual(@as(usize, 1), self.fake.count(.text));
        try std.testing.expect(self.fake.nthSubjectEquals(.text, 0, drv_basename[33..]));
        try std.testing.expectEqual(@as(usize, 1), self.fake.count(.build));
        try std.testing.expect(self.fake.nthSubjectEquals(.build, 0, subject));
    }
};

fn valueText(fixture: *DemandFixture, value: Value) ![]const u8 {
    const forced = try fixture.ev.forceValue(value);
    return switch (forced.kind()) {
        .string, .path => fixture.ev.intern.get(forced.asInternId()),
        .string_context => fixture.ev.intern.get((try fixture.ev.heap.getContextString(forced.asObjectId())).text),
        else => error.ExpectedStringResult,
    };
}

fn runDemandCase(case: DemandCase) !void {
    var fixture = try DemandFixture.init(std.testing.allocator, 1);
    defer fixture.deinit();
    const output = try fixture.makeOutputOnly();
    const subject = try fixture.registerOutputTree(output);
    defer fixture.allocator.free(subject);
    const scope = try fixture.scopeWithOutput(output);

    const source = switch (case) {
        .read_file => "builtins.readFile (p + \"/payload.txt\")",
        .path_exists => "builtins.pathExists (p + \"/payload.txt\")",
        .read_file_type => "builtins.readFileType (p + \"/payload.txt\")",
        .read_dir => "builtins.getAttr \"payload.txt\" (builtins.readDir p)",
        .import_file => "(import (p + \"/import.nix\")).value",
        .scoped_import => "builtins.scopedImport { x = 1; y = 2; } (p + \"/scope.nix\")",
        .interpolated_subpath => "builtins.readFile \"${p}/payload.txt\"",
    };
    const result = try fixture.ev.evaluateWithScope(source, scope);

    switch (case) {
        .read_file, .interpolated_subpath => try std.testing.expectEqualStrings("cold payload", try valueText(&fixture, result)),
        .path_exists => try std.testing.expect((try fixture.ev.forceValue(result)).asBool()),
        .read_file_type, .read_dir => try std.testing.expectEqualStrings("regular", try valueText(&fixture, result)),
        .import_file => try std.testing.expectEqual(@as(i64, 42), (try fixture.ev.forceValue(result)).asInt()),
        .scoped_import => try std.testing.expectEqual(@as(i64, 3), (try fixture.ev.forceValue(result)).asInt()),
    }
    try fixture.assertOneRealization(output, subject);
}

fn guardedDemandCase(case: DemandCase) !void {
    if (comptime sharedDemandIntegrationAvailable()) {
        try runDemandCase(case);
    } else return error.MissingSharedDemandPathIntegration;
}

test "cold output demand routes readFile through shared realization" {
    try guardedDemandCase(.read_file);
}

test "cold output demand routes pathExists through shared realization" {
    try guardedDemandCase(.path_exists);
}

test "cold output demand routes readFileType through shared realization" {
    try guardedDemandCase(.read_file_type);
}

test "cold output demand routes readDir through shared realization" {
    try guardedDemandCase(.read_dir);
}

test "cold output demand routes import through shared realization" {
    try guardedDemandCase(.import_file);
}

test "cold output demand routes scopedImport through shared realization" {
    try guardedDemandCase(.scoped_import);
}

test "cold output demand preserves context on an interpolated subpath" {
    try guardedDemandCase(.interpolated_subpath);
}

test "cold output demand succeeds after derivation-shaped value is gone" {
    if (comptime sharedDemandIntegrationAvailable()) {
        try runDemandCase(.read_file);
    } else return error.MissingSharedDemandPathIntegration;
}

test "cold output demand survives a major GC with only output context rooted" {
    if (comptime sharedDemandIntegrationAvailable()) {
        var fixture = try DemandFixture.init(std.testing.allocator, 1);
        defer fixture.deinit();

        // The first explicit collection establishes the pinned old floor and
        // arms alloc-bit tracking. Construct the shape only after that floor so
        // the second major can prove this exact ObjectId was reclaimed.
        _ = try fixture.ev.evaluate("1");
        const armed = fixture.ev.collectMajorNow();
        try std.testing.expect(armed.ran);

        const produced = try fixture.makeDerivationAndOutput();
        const output = produced.output;
        const subject = try fixture.registerOutputTree(output);
        defer fixture.allocator.free(subject);
        try std.testing.expect((try fixture.ev.heap.materializeAttrs(produced.derivation_id)).len != 0);

        try fixture.ev.gcSetExternalRoots(&.{output});
        defer fixture.ev.gcSetExternalRoots(&.{}) catch {};
        const collected = fixture.ev.collectMajorNow();
        try std.testing.expect(collected.ran);
        try std.testing.expect(!fixture.ev.heap.isObjectAllocatedForTest(produced.derivation_id));

        const scope = try fixture.scopeWithOutput(output);
        const result = try fixture.ev.evaluateWithScope("builtins.readFile (p + \"/payload.txt\")", scope);
        try std.testing.expectEqualStrings("cold payload", try valueText(&fixture, result));
        try fixture.assertOneRealization(output, subject);
    } else return error.MissingSharedDemandPathIntegration;
}

test "concurrent cold output demands issue exactly one daemon build" {
    if (comptime sharedDemandIntegrationAvailable()) {
        var fixture = try DemandFixture.init(std.testing.allocator, 8);
        defer fixture.deinit();
        const output = try fixture.makeOutputOnly();
        const subject = try fixture.registerOutputTree(output);
        defer fixture.allocator.free(subject);
        const scope = try fixture.scopeWithOutput(output);

        // Eight top-level attr thunks cross forceAttrsAccelerate's guaranteed
        // fan-out threshold and exercise the scheduled strict walk.
        const demands = try fixture.ev.evaluateWithScope(
            \\{
            \\  d0 = builtins.readFile (p + "/payload.txt");
            \\  d1 = builtins.readFile (p + "/payload.txt");
            \\  d2 = builtins.readFile (p + "/payload.txt");
            \\  d3 = builtins.readFile (p + "/payload.txt");
            \\  d4 = builtins.readFile (p + "/payload.txt");
            \\  d5 = builtins.readFile (p + "/payload.txt");
            \\  d6 = builtins.readFile (p + "/payload.txt");
            \\  d7 = builtins.readFile (p + "/payload.txt");
            \\}
        , scope);
        try fixture.ev.forceDeep(demands);
        for (try fixture.ev.heap.materializeAttrs(demands.asObjectId())) |entry| {
            try std.testing.expectEqualStrings("cold payload", try valueText(&fixture, entry.value));
        }
        try fixture.assertOneRealization(output, subject);
    } else return error.MissingSharedDemandPathIntegration;
}
