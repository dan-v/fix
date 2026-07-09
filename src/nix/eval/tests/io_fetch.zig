const std = @import("std");
const eval_mod = @import("../../eval.zig");
const Evaluator = eval_mod.Evaluator;
const Diagnostic = eval_mod.Diagnostic;
const Value = @import("runtime").value.Value;
const path_ops = @import("runtime").paths;
const helpers = @import("../test_helpers.zig");
const renderForTest = helpers.renderForTest;
const renderWithFetchTree = helpers.renderWithFetchTree;
const renderWithFlakes = helpers.renderWithFlakes;
const renderStrictForTest = helpers.renderStrictForTest;
const renderForTestFromCurrentPath = helpers.renderForTestFromCurrentPath;
const renderXmlForTest = helpers.renderXmlForTest;

test "evaluate pathExists and readFile builtins through file cache" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "input.txt", .data = "abc\n" });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const file_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "input.txt",
    });
    defer std.testing.allocator.free(file_path);

    const exists_source = try std.fmt.allocPrint(std.testing.allocator, "builtins.pathExists \"{s}\"", .{file_path});
    defer std.testing.allocator.free(exists_source);
    const read_source = try std.fmt.allocPrint(std.testing.allocator, "builtins.readFile \"{s}\"", .{file_path});
    defer std.testing.allocator.free(read_source);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    const exists = try ev.evaluate(exists_source);
    try std.testing.expect(exists.asBool());

    const contents = try ev.evaluate(read_source);
    try std.testing.expectEqualStrings("abc\n", ev.intern.get(contents.asInternId()));

    const reread = try ev.evaluate(read_source);
    try std.testing.expectEqual(contents.asInternId(), reread.asInternId());
}

test "read source files through evaluator file cache" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "source.nix", .data = "1 + 2\n" });

    const relative_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/source.nix", .{tmp.sub_path});
    defer std.testing.allocator.free(relative_path);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    try ev.setBasePathFromCurrentPath(std.testing.io);

    const source = try ev.readSourceFile(relative_path);
    try std.testing.expectEqualStrings("1 + 2\n", source);

    const cached_source = try ev.readSourceFile(relative_path);
    try std.testing.expectEqual(@intFromPtr(source.ptr), @intFromPtr(cached_source.ptr));
}

test "evaluate readDir builtin through file cache" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "file.txt", .data = "x" });
    try tmp.dir.createDir(std.testing.io, "sub", .default_dir);

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const dir_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
    });
    defer std.testing.allocator.free(dir_path);

    const file_source = try std.fmt.allocPrint(std.testing.allocator, "builtins.getAttr \"file.txt\" (builtins.readDir {s})", .{dir_path});
    defer std.testing.allocator.free(file_source);
    const dir_source = try std.fmt.allocPrint(std.testing.allocator, "(builtins.readDir {s}).sub", .{dir_path});
    defer std.testing.allocator.free(dir_source);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    const file_kind = try ev.evaluate(file_source);
    try std.testing.expectEqualStrings("regular", ev.intern.get(file_kind.asInternId()));

    const dir_kind = try ev.evaluate(dir_source);
    try std.testing.expectEqualStrings("directory", ev.intern.get(dir_kind.asInternId()));
}

test "evaluate readFileType builtin through file cache" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "file.txt", .data = "x" });
    try tmp.dir.createDir(std.testing.io, "sub", .default_dir);

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const base_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
    });
    defer std.testing.allocator.free(base_path);

    const file_path = try std.fs.path.resolve(std.testing.allocator, &.{ base_path, "file.txt" });
    defer std.testing.allocator.free(file_path);
    const dir_path = try std.fs.path.resolve(std.testing.allocator, &.{ base_path, "sub" });
    defer std.testing.allocator.free(dir_path);

    const file_source = try std.fmt.allocPrint(std.testing.allocator, "builtins.readFileType {s}", .{file_path});
    defer std.testing.allocator.free(file_source);
    const dir_source = try std.fmt.allocPrint(std.testing.allocator, "builtins.readFileType {s}", .{dir_path});
    defer std.testing.allocator.free(dir_source);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    const file_kind = try ev.evaluate(file_source);
    try std.testing.expectEqualStrings("regular", ev.intern.get(file_kind.asInternId()));

    const dir_kind = try ev.evaluate(dir_source);
    try std.testing.expectEqualStrings("directory", ev.intern.get(dir_kind.asInternId()));
}

test "evaluate filterSource builtin through file cache" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "keep.txt", .data = "x" });
    try tmp.dir.createDir(std.testing.io, "keepdir", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "keepdir/nested.txt", .data = "x" });
    try tmp.dir.createDir(std.testing.io, "skip", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "skip/boom.txt", .data = "x" });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const dir_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
    });
    defer std.testing.allocator.free(dir_path);

    const source = try std.fmt.allocPrint(
        std.testing.allocator,
        \\builtins.filterSource
        \\  (path: type:
        \\    if builtins.baseNameOf path == "boom.txt"
        \\    then builtins.throw "descended into rejected directory"
        \\    else builtins.baseNameOf path != "skip")
        \\  {s}
    ,
        .{dir_path},
    );
    defer std.testing.allocator.free(source);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    const filtered = try ev.evaluate(source);
    try std.testing.expectEqual(.string_context, filtered.kind());
    const filtered_string = try ev.heap.getContextString(filtered.asObjectId());
    const filtered_path = ev.intern.get(filtered_string.text);
    try std.testing.expect(std.mem.startsWith(u8, filtered_path, "/nix/store/"));
    try std.testing.expect(std.mem.endsWith(u8, filtered_path, &tmp.sub_path));
    try std.testing.expectEqual(@as(usize, 1), filtered_string.context.len);
    try std.testing.expectEqual(filtered_string.text, filtered_string.context[0].name);

    ev.setDerivationDebug(true);
    const drv_source = try std.fmt.allocPrint(
        std.testing.allocator,
        \\let
        \\  src = builtins.filterSource
        \\    (path: type:
        \\      if builtins.baseNameOf path == "boom.txt"
        \\      then builtins.throw "descended into rejected directory"
        \\      else builtins.baseNameOf path != "skip")
        \\    {s};
        \\in (builtins.derivation {{
        \\  name = "uses-filter-source";
        \\  system = "x86_64-linux";
        \\  builder = "/bin/sh";
        \\  preHook = src;
        \\}}).drvPath
    ,
        .{dir_path},
    );
    defer std.testing.allocator.free(drv_source);
    _ = try ev.evaluate(drv_source);
    const records = ev.derivationDebugRecords();
    try std.testing.expectEqual(@as(usize, 1), records.len);
    try std.testing.expectEqual(@as(usize, 1), records[0].input_srcs.len);
    try std.testing.expectEqualStrings(filtered_path, records[0].input_srcs[0]);

    const called_source = try std.fmt.allocPrint(
        std.testing.allocator,
        \\builtins.filterSource
        \\  (path: type:
        \\    if builtins.baseNameOf path == "keep.txt"
        \\    then builtins.throw "predicate called"
        \\    else true)
        \\  {s}
    ,
        .{dir_path},
    );
    defer std.testing.allocator.free(called_source);
    try std.testing.expectError(error.NixThrow, ev.evaluate(called_source));

    const path_filter_called_source = try std.fmt.allocPrint(
        std.testing.allocator,
        \\builtins.path {{
        \\  path = {s};
        \\  name = "filtered-source";
        \\  filter = path: type:
        \\    if builtins.baseNameOf path == "keep.txt"
        \\    then builtins.throw "predicate called"
        \\    else true;
        \\}}
    ,
        .{dir_path},
    );
    defer std.testing.allocator.free(path_filter_called_source);
    try std.testing.expectError(error.NixThrow, ev.evaluate(path_filter_called_source));

    const path_filter_source = try std.fmt.allocPrint(
        std.testing.allocator,
        \\builtins.path {{
        \\  path = {s};
        \\  name = "filtered-source";
        \\  filter = path: type:
        \\    if builtins.baseNameOf path == "boom.txt"
        \\    then builtins.throw "descended into rejected directory"
        \\    else builtins.baseNameOf path != "skip";
        \\}}
    ,
        .{dir_path},
    );
    defer std.testing.allocator.free(path_filter_source);
    const filtered_path_value = try ev.evaluate(path_filter_source);
    try std.testing.expectEqual(.string_context, filtered_path_value.kind());
    const filtered_path_string = try ev.heap.getContextString(filtered_path_value.asObjectId());
    const builtins_path_filtered_path = ev.intern.get(filtered_path_string.text);
    try std.testing.expect(std.mem.startsWith(u8, builtins_path_filtered_path, "/nix/store/"));
    try std.testing.expect(std.mem.endsWith(u8, builtins_path_filtered_path, "-filtered-source"));
}

test "evaluate fetchGit builtin for local repository" {
    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);

    const out_path_source = try std.fmt.allocPrint(std.testing.allocator, "(builtins.fetchGit {{ url = \"{s}\"; }}).outPath", .{cwd});
    defer std.testing.allocator.free(out_path_source);
    const short_rev_source = try std.fmt.allocPrint(std.testing.allocator, "builtins.stringLength (builtins.fetchGit {{ url = \"{s}\"; }}).shortRev", .{cwd});
    defer std.testing.allocator.free(short_rev_source);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    const out_path = try ev.evaluate(out_path_source);
    try std.testing.expectEqualStrings(cwd, ev.intern.get(out_path.asInternId()));

    const short_rev_len = try ev.evaluate(short_rev_source);
    try std.testing.expectEqual(@as(i64, 7), short_rev_len.asInt());
}

test "evaluate fetchurl builtin through fetch cache" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "payload.txt", .data = "payload" });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const file_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "payload.txt",
    });
    defer std.testing.allocator.free(file_path);

    const source = try std.fmt.allocPrint(std.testing.allocator, "builtins.readFile (builtins.fetchurl {{ url = \"file://{s}\"; name = \"payload.txt\"; }})", .{file_path});
    defer std.testing.allocator.free(source);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    const contents = try ev.evaluate(source);
    try std.testing.expectEqualStrings("payload", ev.intern.get(contents.asInternId()));
}

test "evaluate fetchTarball builtin through fetch cache" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "archive-root", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "archive-root/file.txt", .data = "payload" });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const base_path = try std.fs.path.resolve(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(base_path);
    const archive_path = try std.fs.path.resolve(std.testing.allocator, &.{ base_path, "archive.tar.gz" });
    defer std.testing.allocator.free(archive_path);

    const tar = try std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ "tar", "-czf", archive_path, "-C", base_path, "archive-root" },
    });
    defer std.testing.allocator.free(tar.stdout);
    defer std.testing.allocator.free(tar.stderr);
    switch (tar.term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedTarFailure,
    }

    const source = try std.fmt.allocPrint(std.testing.allocator, "builtins.readFile ((builtins.fetchTarball {{ url = \"file://{s}\"; name = \"src\"; }}) + \"/file.txt\")", .{archive_path});
    defer std.testing.allocator.free(source);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    const contents = try ev.evaluate(source);
    try std.testing.expectEqualStrings("payload", ev.intern.get(contents.asInternId()));
}

test "evaluate fetchTree builtin through fetch cache" {
    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "payload.txt", .data = "payload" });

    const file_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "payload.txt",
    });
    defer std.testing.allocator.free(file_path);

    const path_source = try std.fmt.allocPrint(std.testing.allocator, "(builtins.fetchTree {{ type = \"path\"; path = \"{s}\"; }}).outPath", .{cwd});
    defer std.testing.allocator.free(path_source);
    const file_source = try std.fmt.allocPrint(std.testing.allocator, "builtins.readFile (builtins.fetchTree {{ type = \"file\"; url = \"file://{s}\"; }}).outPath", .{file_path});
    defer std.testing.allocator.free(file_source);
    const git_source = try std.fmt.allocPrint(std.testing.allocator, "builtins.stringLength (builtins.fetchTree {{ type = \"git\"; url = \"{s}\"; }}).shortRev", .{cwd});
    defer std.testing.allocator.free(git_source);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    ev.setFileIo(std.testing.io);
    ev.fetch_tree_enabled = true;

    const out_path = try ev.evaluate(path_source);
    try std.testing.expectEqualStrings(cwd, ev.intern.get(out_path.asInternId()));

    const contents = try ev.evaluate(file_source);
    try std.testing.expectEqualStrings("payload", ev.intern.get(contents.asInternId()));

    const short_rev_len = try ev.evaluate(git_source);
    try std.testing.expectEqual(@as(i64, 7), short_rev_len.asInt());
}

test "evaluate flake ref builtins" {
    const github = try renderWithFlakes("builtins.toJSON (builtins.parseFlakeRef \"github:NixOS/nixpkgs/nixos-unstable\")");
    defer std.testing.allocator.free(github);
    try std.testing.expectEqualStrings("\"{\\\"owner\\\":\\\"NixOS\\\",\\\"ref\\\":\\\"nixos-unstable\\\",\\\"repo\\\":\\\"nixpkgs\\\",\\\"type\\\":\\\"github\\\"}\"", github);

    const path = try renderWithFlakes("builtins.toJSON (builtins.parseFlakeRef \"path:/tmp/source?rev=abc&narHash=sha256-test\")");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("\"{\\\"narHash\\\":\\\"sha256-test\\\",\\\"path\\\":\\\"/tmp/source\\\",\\\"rev\\\":\\\"abc\\\",\\\"type\\\":\\\"path\\\"}\"", path);

    const stringified = try renderWithFlakes("builtins.flakeRefToString { type = \"github\"; owner = \"NixOS\"; repo = \"nixpkgs\"; ref = \"nixos-unstable\"; }");
    defer std.testing.allocator.free(stringified);
    try std.testing.expectEqualStrings("\"github:NixOS/nixpkgs/nixos-unstable\"", stringified);
}

test "parseFlakeRef handles github refs without a branch and bare absolute paths" {
    const github_no_ref = try renderWithFlakes("builtins.toJSON (builtins.parseFlakeRef \"github:NixOS/nixpkgs\")");
    defer std.testing.allocator.free(github_no_ref);
    try std.testing.expectEqualStrings("\"{\\\"owner\\\":\\\"NixOS\\\",\\\"repo\\\":\\\"nixpkgs\\\",\\\"type\\\":\\\"github\\\"}\"", github_no_ref);

    const path_no_query = try renderWithFlakes("builtins.toJSON (builtins.parseFlakeRef \"path:/tmp/source\")");
    defer std.testing.allocator.free(path_no_query);
    try std.testing.expectEqualStrings("\"{\\\"path\\\":\\\"/tmp/source\\\",\\\"type\\\":\\\"path\\\"}\"", path_no_query);

    const bare_absolute_path = try renderWithFlakes("builtins.toJSON (builtins.parseFlakeRef \"/tmp/source\")");
    defer std.testing.allocator.free(bare_absolute_path);
    try std.testing.expectEqualStrings("\"{\\\"path\\\":\\\"/tmp/source\\\",\\\"type\\\":\\\"path\\\"}\"", bare_absolute_path);
}

test "parseFlakeRef rejects malformed refs" {
    try std.testing.expectError(error.InvalidFlakeRef, renderWithFlakes("builtins.parseFlakeRef \"github:NixOS\""));
    try std.testing.expectError(error.InvalidFlakeRef, renderWithFlakes("builtins.parseFlakeRef \"relative/path\""));
    try std.testing.expectError(error.InvalidFlakeRef, renderWithFlakes("builtins.parseFlakeRef \"\""));
}

test "flakeRefToString round-trips path refs and rejects unsupported types" {
    const path_only = try renderWithFlakes("builtins.flakeRefToString { type = \"path\"; path = \"/tmp/source\"; }");
    defer std.testing.allocator.free(path_only);
    try std.testing.expectEqualStrings("\"path:/tmp/source\"", path_only);

    const path_with_query = try renderWithFlakes(
        "builtins.flakeRefToString { type = \"path\"; path = \"/tmp/source\"; rev = \"abc\"; narHash = \"sha256-test\"; }",
    );
    defer std.testing.allocator.free(path_with_query);
    try std.testing.expectEqualStrings("\"path:/tmp/source?rev=abc&narHash=sha256-test\"", path_with_query);

    try std.testing.expectError(
        error.InvalidFlakeRef,
        renderWithFlakes("builtins.flakeRefToString { type = \"git\"; url = \"https://example.com/repo\"; }"),
    );
    try std.testing.expectError(
        error.MissingAttribute,
        renderWithFlakes("builtins.flakeRefToString { type = \"github\"; owner = \"NixOS\"; }"),
    );
    try std.testing.expectError(error.TypeError, renderWithFlakes("builtins.flakeRefToString \"github:NixOS/nixpkgs\""));
}

test "fetchTree rejects unrecognized or non-attrset input without touching the network" {
    try std.testing.expectError(
        error.InvalidFlakeRef,
        renderWithFetchTree("builtins.fetchTree { type = \"bogus\"; }"),
    );
    try std.testing.expectError(error.TypeError, renderWithFetchTree("builtins.fetchTree 1"));
    try std.testing.expectError(error.MissingAttribute, renderWithFetchTree("builtins.fetchTree { }"));
}

test "fetchTree is gated on the fetch-tree experimental feature" {
    // Without the feature the builtin errors before touching its argument.
    try std.testing.expectError(
        error.MissingExperimentalFeature,
        renderForTest("builtins.fetchTree { type = \"path\"; path = \"/nonexistent\"; }"),
    );
    // A hard error like Nix: tryEval does not catch it, so the whole
    // evaluation fails rather than resolving to `{ success = false; }`.
    try std.testing.expectError(
        error.MissingExperimentalFeature,
        renderForTest("(builtins.tryEval (builtins.fetchTree { type = \"path\"; path = \"/x\"; })).success"),
    );
    // getFlake reaches the fetcher directly, so it is unaffected by the gate;
    // exercised by the "evaluate getFlake builtin for local path ref" test.
}

test "evaluate getFlake builtin for local path ref" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "flake.nix",
        .data =
        \\{
        \\  outputs = inputs: {
        \\    value = 7;
        \\    source = inputs.self.outPath;
        \\  };
        \\}
        ,
    });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const flake_dir = try std.fs.path.resolve(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(flake_dir);

    const value_source = try std.fmt.allocPrint(std.testing.allocator, "(builtins.getFlake \"path:{s}\").value", .{flake_dir});
    defer std.testing.allocator.free(value_source);
    const output_source = try std.fmt.allocPrint(std.testing.allocator, "(builtins.getFlake \"path:{s}\").outputs.value", .{flake_dir});
    defer std.testing.allocator.free(output_source);
    const self_source = try std.fmt.allocPrint(std.testing.allocator, "(builtins.getFlake \"path:{s}\").source", .{flake_dir});
    defer std.testing.allocator.free(self_source);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    ev.setFileIo(std.testing.io);
    ev.flakes_enabled = true;

    try std.testing.expectEqual(@as(i64, 7), (try ev.evaluate(value_source)).asInt());
    try std.testing.expectEqual(@as(i64, 7), (try ev.evaluate(output_source)).asInt());
    const self_path = try ev.evaluate(self_source);
    try std.testing.expectEqualStrings(flake_dir, ev.intern.get(self_path.asInternId()));
}

test "flake builtins are gated on the flakes experimental feature" {
    // getFlake / parseFlakeRef / flakeRefToString are hard-gated (uncatchable
    // by tryEval), like Nix. Without the feature they error before doing work.
    try std.testing.expectError(
        error.MissingExperimentalFeature,
        renderForTest("builtins.getFlake \"path:/nonexistent\""),
    );
    try std.testing.expectError(
        error.MissingExperimentalFeature,
        renderForTest("builtins.parseFlakeRef \"github:NixOS/nixpkgs\""),
    );
    try std.testing.expectError(
        error.MissingExperimentalFeature,
        renderForTest("builtins.flakeRefToString { type = \"path\"; path = \"/x\"; }"),
    );
}

test "evaluate findFile builtin through explicit search path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "target.nix", .data = "1" });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const base_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
    });
    defer std.testing.allocator.free(base_path);
    const expected_path = try std.fs.path.resolve(std.testing.allocator, &.{ base_path, "target.nix" });
    defer std.testing.allocator.free(expected_path);

    const source = try std.fmt.allocPrint(std.testing.allocator, "builtins.findFile [ {{ prefix = \"pkg\"; path = {s}; }} ] \"pkg/target.nix\"", .{base_path});
    defer std.testing.allocator.free(source);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    const found = try ev.evaluate(source);
    try std.testing.expectEqualStrings(expected_path, ev.intern.get(found.asInternId()));
}

test "evaluate angle search path literals through cached nix path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "target.nix", .data = "{ value = 5; }" });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const base_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
    });
    defer std.testing.allocator.free(base_path);

    const nix_path = try std.fmt.allocPrint(std.testing.allocator, "pkg={s}", .{base_path});
    defer std.testing.allocator.free(nix_path);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    ev.setFileIo(std.testing.io);
    try ev.setNixPath(nix_path);

    const imported = try ev.evaluate("(import <pkg/target.nix>).value");
    try std.testing.expectEqual(@as(i64, 5), imported.asInt());
}

test "evaluate import through evaluator file cache" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "imported.nix", .data = "{ value = 42; }\n" });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const file_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "imported.nix",
    });
    defer std.testing.allocator.free(file_path);

    const source = try std.fmt.allocPrint(std.testing.allocator, "let a = import {s}; b = import {s}; in a.value + b.value", .{ file_path, file_path });
    defer std.testing.allocator.free(source);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    const imported = try ev.evaluate(source);
    try std.testing.expectEqual(@as(i64, 84), imported.asInt());
    try std.testing.expectEqual(@as(u32, 1), ev.imports.entries.count());
}

test "evaluate path builtins coerce outPath attrsets" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "imported.nix", .data = "{ value = 21; }\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "payload.txt", .data = "payload" });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const imported_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "imported.nix",
    });
    defer std.testing.allocator.free(imported_path);
    const payload_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "payload.txt",
    });
    defer std.testing.allocator.free(payload_path);

    const source = try std.fmt.allocPrint(std.testing.allocator,
        \\let
        \\  imported = (import {{ outPath = "{s}"; }}).value;
        \\  contents = builtins.readFile {{ outPath = "{s}"; }};
        \\in imported + builtins.stringLength contents
    , .{ imported_path, payload_path });
    defer std.testing.allocator.free(source);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    const result = try ev.evaluate(source);
    try std.testing.expectEqual(@as(i64, 28), result.asInt());
}

test "evaluate directory import through default nix" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "pkg", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "pkg/default.nix", .data = "{ value = 9; }\n" });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const dir_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "pkg",
    });
    defer std.testing.allocator.free(dir_path);

    const source = try std.fmt.allocPrint(std.testing.allocator, "(import {s}).value", .{dir_path});
    defer std.testing.allocator.free(source);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    const imported = try ev.evaluate(source);
    try std.testing.expectEqual(@as(i64, 9), imported.asInt());
}

test "evaluate scopedImport through ambient scope" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "scope.nix", .data = "x + y\n" });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const file_path = try std.fs.path.resolve(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "scope.nix" });
    defer std.testing.allocator.free(file_path);

    const source = try std.fmt.allocPrint(std.testing.allocator, "builtins.scopedImport {{ x = 1; y = 2; }} {s}", .{file_path});
    defer std.testing.allocator.free(source);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    const imported = try ev.evaluate(source);
    try std.testing.expectEqual(@as(i64, 3), imported.asInt());
}

test "detect recursive imports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "cycle.nix", .data = "import ./cycle.nix\n" });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const file_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "cycle.nix",
    });
    defer std.testing.allocator.free(file_path);

    const source = try std.fmt.allocPrint(std.testing.allocator, "import {s}", .{file_path});
    defer std.testing.allocator.free(source);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    try std.testing.expectError(error.ImportCycle, ev.evaluate(source));
}
