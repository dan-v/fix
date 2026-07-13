const std = @import("std");
const eval_mod = @import("../../eval.zig");
const Evaluator = eval_mod.Evaluator;
const DerivationStore = @import("derivation").DerivationStore;
const Value = @import("runtime").value.Value;
const ObjectId = @import("runtime").types.ObjectId;
const nar = @import("runtime").nar;
const FakeDaemon = @import("../../test_daemon.zig").FakeDaemon;

fn recipeInspectionAvailable() bool {
    return @hasDecl(DerivationStore, "RecipeVariantForTest") and
        @hasDecl(DerivationStore, "recipeCountForTest") and
        @hasDecl(DerivationStore, "recipeVariantForTest") and
        @hasDecl(DerivationStore, "recipePayloadPointerForTest") and
        @hasDecl(DerivationStore, "recipePayloadBytesForTest") and
        @hasDecl(DerivationStore, "recipeReferencesForTest") and
        @hasDecl(DerivationStore, "noteProducerPayloadForTest") and
        @hasDecl(DerivationStore, "producerPayloadPointerForTest");
}

const Fixture = struct {
    allocator: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    store_dir: []u8,
    fake: *FakeDaemon,
    ev: Evaluator,

    fn init(allocator: std.mem.Allocator, enable_store_writes: bool) !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDir(std.testing.io, "store", .default_dir);

        const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
        defer allocator.free(cwd);
        const store_dir = try std.fs.path.resolve(allocator, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "store" });
        errdefer allocator.free(store_dir);

        const fake = try FakeDaemon.start(allocator, std.testing.io);
        errdefer fake.deinit();

        var ev = try Evaluator.init(allocator, 0);
        errdefer ev.deinit();
        ev.setFileIo(std.testing.io);
        ev.derivations.store_dir = store_dir;
        ev.derivations.daemon_socket = fake.socketPath();
        if (enable_store_writes) ev.enableStoreWrites();

        return .{
            .allocator = allocator,
            .tmp = tmp,
            .store_dir = store_dir,
            .fake = fake,
            .ev = ev,
        };
    }

    fn deinit(self: *Fixture) void {
        self.ev.deinit();
        self.fake.deinit();
        self.allocator.free(self.store_dir);
        self.tmp.cleanup();
    }

    fn evaluateAttrs(self: *Fixture, source: []const u8) !ObjectId {
        const value = try self.ev.evaluate(source);
        if (!value.isAttrs()) return error.ExpectedAttrs;
        return value.asObjectId();
    }

    fn forceAttrValue(self: *Fixture, attrs_id: ObjectId, name: []const u8) !Value {
        return self.ev.forceValue(try self.ev.heap.getAttrValue(attrs_id, try self.ev.intern.intern(name)));
    }

    fn forceAttrText(self: *Fixture, attrs_id: ObjectId, name: []const u8) ![]const u8 {
        return valueText(self, try self.forceAttrValue(attrs_id, name));
    }
};

fn valueText(fixture: *Fixture, value: Value) ![]const u8 {
    const forced = try fixture.ev.forceValue(value);
    return switch (forced.kind()) {
        .string, .path => fixture.ev.intern.get(forced.asInternId()),
        .string_context => fixture.ev.intern.get((try fixture.ev.heap.getContextString(forced.asObjectId())).text),
        else => error.ExpectedStringResult,
    };
}

fn expectRefsEqual(actual: []const []const u8, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |exp, got| try std.testing.expectEqualStrings(exp, got);
}

fn storePathSubject(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    if (base.len > 33 and base[32] == '-') return base[33..];
    return base;
}

fn expectRecipeText(store: *DerivationStore, store_path: []const u8, payload: []const u8, refs: []const []const u8) !void {
    if (comptime recipeInspectionAvailable()) {
        try std.testing.expectEqual(DerivationStore.RecipeVariantForTest.text, store.recipeVariantForTest(store_path).?);
        try std.testing.expectEqual(store.producerPayloadPointerForTest(store_path).?, store.recipePayloadPointerForTest(store_path).?);
        try std.testing.expectEqualStrings(payload, store.recipePayloadBytesForTest(store_path).?);
        try expectRefsEqual(store.recipeReferencesForTest(store_path).?, refs);
    } else unreachable;
}

fn expectRecipeNar(store: *DerivationStore, store_path: []const u8, payload: []const u8) !void {
    if (comptime recipeInspectionAvailable()) {
        try std.testing.expectEqual(DerivationStore.RecipeVariantForTest.nar, store.recipeVariantForTest(store_path).?);
        try std.testing.expectEqual(store.producerPayloadPointerForTest(store_path).?, store.recipePayloadPointerForTest(store_path).?);
        try std.testing.expectEqualStrings(payload, store.recipePayloadBytesForTest(store_path).?);
        try expectRefsEqual(store.recipeReferencesForTest(store_path).?, &.{});
    } else unreachable;
}

fn expectRecipeFlat(store: *DerivationStore, store_path: []const u8, expected_ptr: usize, payload: []const u8) !void {
    if (comptime recipeInspectionAvailable()) {
        try std.testing.expectEqual(DerivationStore.RecipeVariantForTest.flat, store.recipeVariantForTest(store_path).?);
        try std.testing.expectEqual(expected_ptr, store.recipePayloadPointerForTest(store_path).?);
        try std.testing.expectEqualStrings(payload, store.recipePayloadBytesForTest(store_path).?);
        try expectRefsEqual(store.recipeReferencesForTest(store_path).?, &.{});
    } else unreachable;
}

fn expectEffect(fake: *FakeDaemon, index: usize, kind: FakeDaemon.Kind, subject: []const u8, payload: []const u8, refs: []const []const u8) !void {
    try std.testing.expectEqual(kind, fake.effectKindAt(index).?);
    try std.testing.expect(fake.effectSubjectEquals(index, subject));
    try std.testing.expect(fake.effectPayloadEquals(index, payload));
    try std.testing.expect(fake.effectReferencesEqual(index, refs));
}

test "storeless derivation normalization records the exact drv text recipe" {
    if (comptime recipeInspectionAvailable()) {
        var fixture = try Fixture.init(std.testing.allocator, false);
        defer fixture.deinit();
        fixture.ev.setDerivationDebug(true);

        const attrs_id = try fixture.evaluateAttrs(
            \\let drv = builtins.derivation {
            \\  name = "recipe-drv";
            \\  system = "x86_64-linux";
            \\  builder = "/bin/sh";
            \\}; in { drv = drv.drvPath; }
        );
        const drv_path = try fixture.forceAttrText(attrs_id, "drv");
        const records = fixture.ev.derivationDebugRecords();
        try std.testing.expectEqual(@as(usize, 1), records.len);
        try std.testing.expectEqual(@as(usize, 1), fixture.ev.derivations.recipeCountForTest());
        try expectRecipeText(&fixture.ev.derivations, drv_path, records[0].drv_aterm, records[0].drv_text_references);

        try fixture.ev.derivations.ensureClosure(drv_path);
        try std.testing.expectEqual(@as(usize, 1), fixture.fake.effectCount());
        try expectEffect(fixture.fake, 0, .text, storePathSubject(drv_path), records[0].drv_aterm, records[0].drv_text_references);
        try std.testing.expectEqual(@as(usize, 0), fixture.ev.derivations.recipeCountForTest());
    } else return error.MissingRecipeInspectionApi;
}

test "builtins.toFile records owned text and exact references" {
    if (comptime recipeInspectionAvailable()) {
        var fixture = try Fixture.init(std.testing.allocator, false);
        defer fixture.deinit();

        const attrs_id = try fixture.evaluateAttrs(
            \\let
            \\  dep = builtins.toFile "dep.txt" "dep payload";
            \\  root = builtins.toFile "root.txt" "${dep}\nroot payload";
            \\in {
            \\  inherit dep root;
            \\  contents = "${dep}\nroot payload";
            \\}
        );
        const dep_path = try fixture.forceAttrText(attrs_id, "dep");
        const root_path = try fixture.forceAttrText(attrs_id, "root");
        const root_contents = try fixture.forceAttrText(attrs_id, "contents");

        try std.testing.expectEqual(@as(usize, 2), fixture.ev.derivations.recipeCountForTest());
        try expectRecipeText(&fixture.ev.derivations, dep_path, "dep payload", &.{});
        try expectRecipeText(&fixture.ev.derivations, root_path, root_contents, &.{dep_path});

        try fixture.ev.derivations.ensureClosure(root_path);
        try std.testing.expectEqual(@as(usize, 2), fixture.fake.effectCount());
        try expectEffect(fixture.fake, 0, .text, storePathSubject(dep_path), "dep payload", &.{});
        try expectEffect(fixture.fake, 1, .text, storePathSubject(root_path), root_contents, &.{dep_path});
        try std.testing.expectEqual(@as(usize, 0), fixture.ev.derivations.recipeCountForTest());
    } else return error.MissingRecipeInspectionApi;
}

test "storeless builtins.path recursive source records the serialized NAR" {
    if (comptime recipeInspectionAvailable()) {
        var fixture = try Fixture.init(std.testing.allocator, false);
        defer fixture.deinit();
        try fixture.tmp.dir.createDir(std.testing.io, "tree", .default_dir);
        try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "tree/file.txt", .data = "nar payload" });

        const cwd = try std.process.currentPathAlloc(std.testing.io, fixture.allocator);
        defer fixture.allocator.free(cwd);
        const tree_path = try std.fs.path.resolve(fixture.allocator, &.{ cwd, ".zig-cache", "tmp", &fixture.tmp.sub_path, "tree" });
        defer fixture.allocator.free(tree_path);
        const source = try std.fmt.allocPrint(
            fixture.allocator,
            "builtins.path {{ path = \"{s}\"; name = \"source-tree\"; }}",
            .{tree_path},
        );
        defer fixture.allocator.free(source);

        const store_path = try valueText(&fixture, try fixture.ev.evaluate(source));
        const nar_bytes = try nar.serialize(fixture.allocator, &fixture.ev.files, tree_path, null);
        defer fixture.allocator.free(nar_bytes);

        try std.testing.expectEqual(@as(usize, 1), fixture.ev.derivations.recipeCountForTest());
        try expectRecipeNar(&fixture.ev.derivations, store_path, nar_bytes);

        try fixture.ev.derivations.ensureClosure(store_path);
        try std.testing.expectEqual(@as(usize, 1), fixture.fake.effectCount());
        try expectEffect(fixture.fake, 0, .nar, storePathSubject(store_path), nar_bytes, &.{});
        try std.testing.expectEqual(@as(usize, 0), fixture.ev.derivations.recipeCountForTest());
    } else return error.MissingRecipeInspectionApi;
}

test "storeless builtins.path recursive false records retained flat file identity" {
    if (comptime recipeInspectionAvailable()) {
        var fixture = try Fixture.init(std.testing.allocator, false);
        defer fixture.deinit();
        try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "flat.txt", .data = "flat source payload" });

        const cwd = try std.process.currentPathAlloc(std.testing.io, fixture.allocator);
        defer fixture.allocator.free(cwd);
        const flat_path = try std.fs.path.resolve(fixture.allocator, &.{ cwd, ".zig-cache", "tmp", &fixture.tmp.sub_path, "flat.txt" });
        defer fixture.allocator.free(flat_path);
        const source = try std.fmt.allocPrint(
            fixture.allocator,
            "builtins.path {{ path = \"{s}\"; name = \"flat-source\"; recursive = false; }}",
            .{flat_path},
        );
        defer fixture.allocator.free(source);

        const store_path = try valueText(&fixture, try fixture.ev.evaluate(source));
        var retained = try fixture.ev.files.retainFile(flat_path);
        defer retained.release();

        try std.testing.expectEqual(@as(usize, 1), fixture.ev.derivations.recipeCountForTest());
        try expectRecipeFlat(&fixture.ev.derivations, store_path, @intFromPtr(retained.bytes().ptr), "flat source payload");

        try fixture.ev.derivations.ensureClosure(store_path);
        try std.testing.expectEqual(@as(usize, 1), fixture.fake.effectCount());
        try expectEffect(fixture.fake, 0, .flat, storePathSubject(store_path), "flat source payload", &.{});
        try std.testing.expectEqual(@as(usize, 0), fixture.ev.derivations.recipeCountForTest());
    } else return error.MissingRecipeInspectionApi;
}

test "storeless fetchurl records retained flat file identity" {
    if (comptime recipeInspectionAvailable()) {
        var fixture = try Fixture.init(std.testing.allocator, false);
        defer fixture.deinit();
        try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "payload.txt", .data = "fetch payload" });

        const cwd = try std.process.currentPathAlloc(std.testing.io, fixture.allocator);
        defer fixture.allocator.free(cwd);
        const file_path = try std.fs.path.resolve(fixture.allocator, &.{ cwd, ".zig-cache", "tmp", &fixture.tmp.sub_path, "payload.txt" });
        defer fixture.allocator.free(file_path);
        const source = try std.fmt.allocPrint(
            fixture.allocator,
            "builtins.fetchurl {{ url = \"file://{s}\"; name = \"payload.txt\"; }}",
            .{file_path},
        );
        defer fixture.allocator.free(source);

        const store_path = try valueText(&fixture, try fixture.ev.evaluate(source));
        var retained = try fixture.ev.files.retainFile(store_path);
        defer retained.release();

        try std.testing.expectEqual(@as(usize, 1), fixture.ev.derivations.recipeCountForTest());
        try expectRecipeFlat(&fixture.ev.derivations, store_path, @intFromPtr(retained.bytes().ptr), "fetch payload");

        try fixture.ev.derivations.ensureClosure(store_path);
        try std.testing.expectEqual(@as(usize, 1), fixture.fake.effectCount());
        try expectEffect(fixture.fake, 0, .flat, storePathSubject(store_path), "fetch payload", &.{});
        try std.testing.expectEqual(@as(usize, 0), fixture.ev.derivations.recipeCountForTest());
    } else return error.MissingRecipeInspectionApi;
}

test "realizeOutput realizes a mixed producer closure before the root derivation build" {
    if (comptime recipeInspectionAvailable()) {
        var fixture = try Fixture.init(std.testing.allocator, false);
        defer fixture.deinit();
        fixture.ev.setDerivationDebug(true);
        try fixture.tmp.dir.createDir(std.testing.io, "src", .default_dir);
        try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/file.txt", .data = "nar dep payload" });
        try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "flat.txt", .data = "flat dep payload" });

        const cwd = try std.process.currentPathAlloc(std.testing.io, fixture.allocator);
        defer fixture.allocator.free(cwd);
        const src_path = try std.fs.path.resolve(fixture.allocator, &.{ cwd, ".zig-cache", "tmp", &fixture.tmp.sub_path, "src" });
        defer fixture.allocator.free(src_path);
        const flat_path = try std.fs.path.resolve(fixture.allocator, &.{ cwd, ".zig-cache", "tmp", &fixture.tmp.sub_path, "flat.txt" });
        defer fixture.allocator.free(flat_path);
        const source = try std.fmt.allocPrint(
            fixture.allocator,
            \\let
            \\  text = builtins.toFile "mixed-text" "text dep payload";
            \\  src = builtins.path {{ path = "{s}"; name = "mixed-src"; }};
            \\  flat = builtins.path {{ path = "{s}"; name = "mixed-flat"; recursive = false; }};
            \\  drv = builtins.derivation {{
            \\    name = "mixed-root";
            \\    system = "x86_64-linux";
            \\    builder = "/bin/sh";
            \\    inherit text src flat;
            \\  }};
            \\in {{
            \\  inherit text src flat;
            \\  drv = drv.drvPath;
            \\}}
        ,
            .{ src_path, flat_path },
        );
        defer fixture.allocator.free(source);

        const attrs_id = try fixture.evaluateAttrs(source);
        const text_path = try fixture.forceAttrText(attrs_id, "text");
        const src_store_path = try fixture.forceAttrText(attrs_id, "src");
        const flat_store_path = try fixture.forceAttrText(attrs_id, "flat");
        const drv_path = try fixture.forceAttrText(attrs_id, "drv");
        const records = fixture.ev.derivationDebugRecords();
        try std.testing.expectEqual(@as(usize, 1), records.len);

        const nar_bytes = try nar.serialize(fixture.allocator, &fixture.ev.files, src_path, null);
        defer fixture.allocator.free(nar_bytes);
        var retained = try fixture.ev.files.retainFile(flat_path);
        defer retained.release();

        try std.testing.expectEqual(@as(usize, 4), fixture.ev.derivations.recipeCountForTest());
        try expectRecipeText(&fixture.ev.derivations, text_path, "text dep payload", &.{});
        try expectRecipeNar(&fixture.ev.derivations, src_store_path, nar_bytes);
        try expectRecipeFlat(&fixture.ev.derivations, flat_store_path, @intFromPtr(retained.bytes().ptr), "flat dep payload");
        try expectRecipeText(&fixture.ev.derivations, drv_path, records[0].drv_aterm, records[0].drv_text_references);

        const build_subject = try std.fmt.allocPrint(fixture.allocator, "{s}^out", .{drv_path});
        defer fixture.allocator.free(build_subject);
        try fixture.ev.derivations.realizeOutput(drv_path, &.{"out"});

        const refs = records[0].drv_text_references;
        try std.testing.expectEqual(refs.len + 2, fixture.fake.effectCount());
        for (refs, 0..) |ref, i| {
            if (std.mem.eql(u8, ref, text_path)) {
                try expectEffect(fixture.fake, i, .text, storePathSubject(text_path), "text dep payload", &.{});
            } else if (std.mem.eql(u8, ref, src_store_path)) {
                try expectEffect(fixture.fake, i, .nar, storePathSubject(src_store_path), nar_bytes, &.{});
            } else if (std.mem.eql(u8, ref, flat_store_path)) {
                try expectEffect(fixture.fake, i, .flat, storePathSubject(flat_store_path), "flat dep payload", &.{});
            } else return error.UnexpectedMixedReference;
        }
        try expectEffect(fixture.fake, refs.len, .text, storePathSubject(drv_path), records[0].drv_aterm, refs);
        try expectEffect(fixture.fake, refs.len + 1, .build, build_subject, "", &.{});
        try std.testing.expectEqual(@as(usize, 0), fixture.ev.derivations.recipeCountForTest());
    } else return error.MissingRecipeInspectionApi;
}

test "global store-writing mode leaves no producer recipe after immediate instantiation" {
    if (comptime recipeInspectionAvailable()) {
        var fixture = try Fixture.init(std.testing.allocator, true);
        defer fixture.deinit();
        fixture.ev.setDerivationDebug(true);
        try fixture.tmp.dir.createDir(std.testing.io, "write-src", .default_dir);
        try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "write-src/file.txt", .data = "write nar payload" });
        try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "write-flat.txt", .data = "write flat payload" });
        try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "write-fetch.txt", .data = "write fetch payload" });

        const cwd = try std.process.currentPathAlloc(std.testing.io, fixture.allocator);
        defer fixture.allocator.free(cwd);
        const src_path = try std.fs.path.resolve(fixture.allocator, &.{ cwd, ".zig-cache", "tmp", &fixture.tmp.sub_path, "write-src" });
        defer fixture.allocator.free(src_path);
        const flat_path = try std.fs.path.resolve(fixture.allocator, &.{ cwd, ".zig-cache", "tmp", &fixture.tmp.sub_path, "write-flat.txt" });
        defer fixture.allocator.free(flat_path);
        const fetch_path = try std.fs.path.resolve(fixture.allocator, &.{ cwd, ".zig-cache", "tmp", &fixture.tmp.sub_path, "write-fetch.txt" });
        defer fixture.allocator.free(fetch_path);
        const source = try std.fmt.allocPrint(
            fixture.allocator,
            \\let
            \\  text = builtins.toFile "write-text" "write text payload";
            \\  src = builtins.path {{ path = "{s}"; name = "write-src"; }};
            \\  flat = builtins.path {{ path = "{s}"; name = "write-flat"; recursive = false; }};
            \\  fetched = builtins.fetchurl {{ url = "file://{s}"; name = "write-fetch"; }};
            \\  drv = builtins.derivation {{
            \\    name = "write-root";
            \\    system = "x86_64-linux";
            \\    builder = "/bin/sh";
            \\    inherit text src flat fetched;
            \\  }};
            \\in {{ inherit text src flat fetched; drv = drv.drvPath; }}
        ,
            .{ src_path, flat_path, fetch_path },
        );
        defer fixture.allocator.free(source);
        const attrs_id = try fixture.evaluateAttrs(source);

        const text_path = try fixture.forceAttrText(attrs_id, "text");
        try std.testing.expectEqual(@as(usize, 0), fixture.ev.derivations.recipeCountForTest());
        try expectEffect(fixture.fake, 0, .text, storePathSubject(text_path), "write text payload", &.{});

        const src_store_path = try fixture.forceAttrText(attrs_id, "src");
        const nar_bytes = try nar.serialize(fixture.allocator, &fixture.ev.files, src_path, null);
        defer fixture.allocator.free(nar_bytes);
        try std.testing.expectEqual(@as(usize, 0), fixture.ev.derivations.recipeCountForTest());
        try expectEffect(fixture.fake, 1, .nar, storePathSubject(src_store_path), nar_bytes, &.{});

        const flat_store_path = try fixture.forceAttrText(attrs_id, "flat");
        try std.testing.expectEqual(@as(usize, 0), fixture.ev.derivations.recipeCountForTest());
        try expectEffect(fixture.fake, 2, .flat, storePathSubject(flat_store_path), "write flat payload", &.{});

        const fetch_store_path = try fixture.forceAttrText(attrs_id, "fetched");
        try std.testing.expectEqual(@as(usize, 0), fixture.ev.derivations.recipeCountForTest());
        try expectEffect(fixture.fake, 3, .flat, storePathSubject(fetch_store_path), "write fetch payload", &.{});

        const drv_path = try fixture.forceAttrText(attrs_id, "drv");
        const records = fixture.ev.derivationDebugRecords();
        try std.testing.expectEqual(@as(usize, 1), records.len);
        try std.testing.expectEqual(@as(usize, 0), fixture.ev.derivations.recipeCountForTest());
        try std.testing.expectEqual(@as(usize, 5), fixture.fake.effectCount());
        try expectEffect(fixture.fake, 4, .text, storePathSubject(drv_path), records[0].drv_aterm, records[0].drv_text_references);
    } else return error.MissingRecipeInspectionApi;
}
