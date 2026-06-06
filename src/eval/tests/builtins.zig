const std = @import("std");
const eval_mod = @import("../../eval.zig");
const Evaluator = eval_mod.Evaluator;
const Diagnostic = eval_mod.Diagnostic;
const Value = @import("../../value.zig").Value;
const path_ops = @import("../../runtime/paths.zig");
const helpers = @import("../test_helpers.zig");
const renderForTest = helpers.renderForTest;
const renderStrictForTest = helpers.renderStrictForTest;
const renderForTestFromCurrentPath = helpers.renderForTestFromCurrentPath;
const renderXmlForTest = helpers.renderXmlForTest;

test "evaluate all and any builtins" {
    const all_true = try renderForTest("builtins.all (x: x < 3) [ 1 2 ]");
    defer std.testing.allocator.free(all_true);
    try std.testing.expectEqualStrings("true", all_true);

    const all_short_circuit = try renderForTest("builtins.all (x: x < 3) [ 1 4 (1 / 0) ]");
    defer std.testing.allocator.free(all_short_circuit);
    try std.testing.expectEqualStrings("false", all_short_circuit);

    const any_short_circuit = try renderForTest("builtins.any (x: x == 2) [ 1 2 (1 / 0) ]");
    defer std.testing.allocator.free(any_short_circuit);
    try std.testing.expectEqualStrings("true", any_short_circuit);

    const any_false = try renderForTest("builtins.any (x: x == 2) [ 1 3 ]");
    defer std.testing.allocator.free(any_false);
    try std.testing.expectEqualStrings("false", any_false);
}

test "evaluate filter builtin" {
    const filtered = try renderForTest("builtins.filter (x: x < 3) [ 1 4 2 ]");
    defer std.testing.allocator.free(filtered);
    try std.testing.expectEqualStrings("[ 1 2 ]", filtered);

    const length_lazy = try renderForTest("builtins.length (builtins.filter (x: true) [ (1 / 0) ])");
    defer std.testing.allocator.free(length_lazy);
    try std.testing.expectEqualStrings("1", length_lazy);

    const reject_lazy = try renderForTest("builtins.filter (x: false) [ (1 / 0) ]");
    defer std.testing.allocator.free(reject_lazy);
    try std.testing.expectEqualStrings("[ ]", reject_lazy);
}

test "evaluate map concatMap mapAttrs and genList builtins" {
    const mapped = try renderForTest("builtins.toJSON (builtins.map (x: x + 1) [ 1 2 3 ])");
    defer std.testing.allocator.free(mapped);
    try std.testing.expectEqualStrings("\"[2,3,4]\"", mapped);

    const map_lazy_length = try renderForTest("builtins.length (builtins.map (x: builtins.throw \"bad\") [ 1 ])");
    defer std.testing.allocator.free(map_lazy_length);
    try std.testing.expectEqualStrings("1", map_lazy_length);

    const concat_mapped = try renderForTest("builtins.elemAt (builtins.concatMap (x: [ x (x + 10) ]) [ 1 2 ]) 1");
    defer std.testing.allocator.free(concat_mapped);
    try std.testing.expectEqualStrings("11", concat_mapped);

    const mapped_attrs = try renderForTest("(builtins.mapAttrs (name: value: value + 1) { a = 1; b = 2; }).b");
    defer std.testing.allocator.free(mapped_attrs);
    try std.testing.expectEqualStrings("3", mapped_attrs);

    const map_attrs_lazy_select = try renderForTest("(builtins.mapAttrs (name: value: if name == \"a\" then value else builtins.throw \"bad\") { a = 1; b = 2; }).a");
    defer std.testing.allocator.free(map_attrs_lazy_select);
    try std.testing.expectEqualStrings("1", map_attrs_lazy_select);

    const map_attrs_lazy_has_attr = try renderForTest("(builtins.mapAttrs (name: value: builtins.throw \"bad\") { a = 1; }) ? a");
    defer std.testing.allocator.free(map_attrs_lazy_has_attr);
    try std.testing.expectEqualStrings("true", map_attrs_lazy_has_attr);

    const map_attrs_fixed_point = try renderForTest("let fix = f: let x = f x; in x; in builtins.attrNames (fix (self: let y = builtins.mapAttrs self.f { a = 1; }; in { f = n: v: v; } // y))");
    defer std.testing.allocator.free(map_attrs_fixed_point);
    try std.testing.expectEqualStrings("[ \"a\" \"f\" ]", map_attrs_fixed_point);

    const generated = try renderForTest("builtins.genList (x: x + 1) 3");
    defer std.testing.allocator.free(generated);
    try std.testing.expectEqualStrings("[ ... ... ... ]", generated);

    const generated_forced = try renderForTest("builtins.elemAt (builtins.genList (x: x + 1) 3) 2");
    defer std.testing.allocator.free(generated_forced);
    try std.testing.expectEqualStrings("3", generated_forced);
}

test "evaluate string builtins" {
    const length = try renderForTest("builtins.stringLength \"abcd\"");
    defer std.testing.allocator.free(length);
    try std.testing.expectEqualStrings("4", length);

    const out_path_length = try renderForTest("builtins.stringLength { outPath = \"/x\"; }");
    defer std.testing.allocator.free(out_path_length);
    try std.testing.expectEqualStrings("2", out_path_length);

    try std.testing.expectError(error.TypeError, renderForTest("builtins.stringLength 1"));

    const joined = try renderForTest("builtins.concatStringsSep \",\" [ \"a\" \"b\" \"c\" ]");
    defer std.testing.allocator.free(joined);
    try std.testing.expectEqualStrings("\"a,b,c\"", joined);

    const joined_path = try renderForTest("builtins.concatStringsSep \",\" [ ./src/root.zig { outPath = \"/nix/store/example\"; } ]");
    defer std.testing.allocator.free(joined_path);
    try std.testing.expect(std.mem.indexOf(u8, joined_path, "/nix/store/example") != null);

    try std.testing.expectError(error.TypeError, renderForTest("builtins.concatStringsSep \",\" [ 1 ]"));

    const list_string_empty_lists = try renderForTest(
        \\builtins.toJSON [
        \\  (builtins.toString [ [ ] "a" "b" ])
        \\  (builtins.toString [ "a" [ ] "b" ])
        \\  (builtins.toString [ "a" "b" [ ] ])
        \\  (builtins.toString [ "a" [ ] [ ] ])
        \\  (builtins.toString [ "" [ ] ])
        \\]
    );
    defer std.testing.allocator.free(list_string_empty_lists);
    try std.testing.expectEqualStrings("\"[\\\"a b\\\",\\\"a b\\\",\\\"a b \\\",\\\"a \\\",\\\" \\\"]\"", list_string_empty_lists);

    const substring = try renderForTest("builtins.substring 1 2 \"abcd\"");
    defer std.testing.allocator.free(substring);
    try std.testing.expectEqualStrings("\"bc\"", substring);

    const substring_to_end = try renderForTest("builtins.substring 1 (-1) \"abcd\"");
    defer std.testing.allocator.free(substring_to_end);
    try std.testing.expectEqualStrings("\"bcd\"", substring_to_end);

    try std.testing.expectError(error.TypeError, renderForTest("builtins.substring (-1) 2 \"abcd\""));

    const out_path_substring = try renderForTest("builtins.substring 0 1 { outPath = \"/x\"; }");
    defer std.testing.allocator.free(out_path_substring);
    try std.testing.expectEqualStrings("\"/\"", out_path_substring);

    const replaced = try renderForTest("builtins.replaceStrings [ \"ab\" \"d\" ] [ \"X\" \"Y\" ] \"abcd\"");
    defer std.testing.allocator.free(replaced);
    try std.testing.expectEqualStrings("\"XcY\"", replaced);

    const replace_preserves_used_context = try renderForTest(
        \\let
        \\  dep = builtins.derivation { name = "dep"; outputs = [ "out" "dev" ]; system = "x86_64-linux"; builder = "/bin/sh"; };
        \\  result = builtins.replaceStrings [ "@x@" ] [ (builtins.toJSON [ "${dep.dev}/include" "${dep.out}/lib" ]) ] "value @x@";
        \\  ctx = builtins.getContext result;
        \\in builtins.concatStringsSep "," ((builtins.getAttr (builtins.unsafeDiscardStringContext dep.drvPath) ctx).outputs)
    );
    defer std.testing.allocator.free(replace_preserves_used_context);
    try std.testing.expectEqualStrings("\"dev,out\"", replace_preserves_used_context);

    const replace_ignores_unused_context = try renderForTest(
        \\let
        \\  dep = builtins.derivation { name = "dep"; system = "x86_64-linux"; builder = "/bin/sh"; };
        \\in builtins.hasContext (builtins.replaceStrings [ "x" ] [ "${dep}" ] "abc")
    );
    defer std.testing.allocator.free(replace_ignores_unused_context);
    try std.testing.expectEqualStrings("false", replace_ignores_unused_context);

    const replace_keeps_input_context = try renderForTest(
        \\let
        \\  dep = builtins.derivation { name = "dep"; system = "x86_64-linux"; builder = "/bin/sh"; };
        \\in builtins.hasContext (builtins.replaceStrings [ (builtins.unsafeDiscardStringContext dep.outPath) ] [ "removed" ] "${dep.out}")
    );
    defer std.testing.allocator.free(replace_keeps_input_context);
    try std.testing.expectEqualStrings("true", replace_keeps_input_context);

    const to_file = try renderForTest("builtins.toFile \"x\" \"hello\"");
    defer std.testing.allocator.free(to_file);
    try std.testing.expectEqualStrings("\"/nix/store/4g4g9i669dl63abpww0djbl2jxl6bwiz-x\"", to_file);

    try std.testing.expectError(error.InvalidStorePathName, renderForTest("builtins.toFile \"x y\" \"hello\""));
    try std.testing.expectError(
        error.DerivationReferenceInToFile,
        renderForTest(
            \\let d = builtins.derivation { name = "dep"; system = "x86_64-linux"; builder = "/bin/sh"; };
            \\in builtins.toFile "x" "${d}"
        ),
    );
}

test "evaluate hash builtins" {
    const hash_string = try renderForTest("builtins.hashString \"sha256\" \"abc\"");
    defer std.testing.allocator.free(hash_string);
    try std.testing.expectEqualStrings("\"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\"", hash_string);

    const placeholder_out = try renderForTest("builtins.placeholder \"out\"");
    defer std.testing.allocator.free(placeholder_out);
    try std.testing.expectEqualStrings("\"/1rz4g4znpzjwh1xymhjpm42vipw92pr73vdgl6xs1hycac8kf2n9\"", placeholder_out);

    const placeholder_dev = try renderForTest("builtins.placeholder \"dev\"");
    defer std.testing.allocator.free(placeholder_dev);
    try std.testing.expectEqualStrings("\"/02qcpld1y6xhs5gz9bchpxaw0xdhmsp5dv88lh25r2ss44kh8dxz\"", placeholder_dev);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "input.txt", .data = "abc" });

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

    const source = try std.fmt.allocPrint(std.testing.allocator, "builtins.hashFile \"sha1\" {s}", .{file_path});
    defer std.testing.allocator.free(source);

    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    const hash_file = try ev.evaluate(source);
    try std.testing.expectEqualStrings("a9993e364706816aba3e25717850c26c9cd0d89d", ev.intern.get(hash_file.asInternId()));
}

test "evaluate JSON builtins" {
    const json = try renderForTest("builtins.toJSON { b = [ 2 false ]; a = \"x\"; }");
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings("\"{\\\"a\\\":\\\"x\\\",\\\"b\\\":[2,false]}\"", json);

    const json_forces_values = try renderForTest("builtins.toJSON { a = 1; }");
    defer std.testing.allocator.free(json_forces_values);
    try std.testing.expectEqualStrings("\"{\\\"a\\\":1}\"", json_forces_values);

    const parsed_attr = try renderForTest("(builtins.fromJSON \"{\\\"b\\\":2,\\\"a\\\":[1,true,null]}\").a");
    defer std.testing.allocator.free(parsed_attr);
    try std.testing.expectEqualStrings("[ 1 true null ]", parsed_attr);

    const parsed_float_type = try renderForTest("builtins.typeOf (builtins.fromJSON \"1.5\")");
    defer std.testing.allocator.free(parsed_float_type);
    try std.testing.expectEqualStrings("\"float\"", parsed_float_type);

    const out_path_json = try renderForTest("builtins.toJSON { outPath = \"/nix/store/example\"; a = 1; }");
    defer std.testing.allocator.free(out_path_json);
    try std.testing.expectEqualStrings("\"\\\"/nix/store/example\\\"\"", out_path_json);

    const to_string_json = try renderForTest("builtins.toJSON { __toString = self: self.name; name = \"pkg\"; }");
    defer std.testing.allocator.free(to_string_json);
    try std.testing.expectEqualStrings("\"\\\"pkg\\\"\"", to_string_json);

    const json_preserves_string_context = try renderForTest(
        \\let
        \\  dep = builtins.derivation { name = "dep"; outputs = [ "out" "dev" ]; system = "x86_64-linux"; builder = "/bin/sh"; };
        \\  ctx = builtins.getContext (builtins.toJSON [ "${dep.dev}/include" "${dep.out}/lib" ]);
        \\in builtins.concatStringsSep "," ((builtins.getAttr (builtins.unsafeDiscardStringContext dep.drvPath) ctx).outputs)
    );
    defer std.testing.allocator.free(json_preserves_string_context);
    try std.testing.expectEqualStrings("\"dev,out\"", json_preserves_string_context);
}

test "evaluate XML builtin" {
    const xml = try renderForTest("builtins.toXML { b = [ true \"x\" null ]; a = 1; }");
    defer std.testing.allocator.free(xml);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<?xml version='1.0' encoding='utf-8'?>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<attr name=\\\"a\\\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<bool value=\\\"true\\\" />") != null);

    const escaped = try renderForTest("builtins.toXML \"a<&\\\"b\"");
    defer std.testing.allocator.free(escaped);
    try std.testing.expect(std.mem.indexOf(u8, escaped, "a&lt;&amp;&quot;b") != null);

    const xml_preserves_string_context = try renderForTest(
        \\let
        \\  dep = builtins.derivation { name = "dep"; outputs = [ "out" "dev" ]; system = "x86_64-linux"; builder = "/bin/sh"; };
        \\  ctx = builtins.getContext (builtins.toXML [ "${dep.dev}/include" "${dep.out}/lib" ]);
        \\in builtins.concatStringsSep "," ((builtins.getAttr (builtins.unsafeDiscardStringContext dep.drvPath) ctx).outputs)
    );
    defer std.testing.allocator.free(xml_preserves_string_context);
    try std.testing.expectEqualStrings("\"dev,out\"", xml_preserves_string_context);
}

test "evaluate TOML builtin" {
    const parsed = try renderForTest(
        \\builtins.toJSON (let value = builtins.fromTOML ''
        \\  title = "demo"
        \\  enabled = true
        \\  count = 0x10
        \\  ratio = 1.5
        \\  tags = [ "a", "b" ]
        \\  [package]
        \\  name = "pkg"
        \\  meta.license = { text = "MIT" }
        \\''; in [ value.title value.enabled value.count value.ratio value.tags value.package.name value.package.meta.license.text ])
    );
    defer std.testing.allocator.free(parsed);
    try std.testing.expectEqualStrings("\"[\\\"demo\\\",true,16,1.5,[\\\"a\\\",\\\"b\\\"],\\\"pkg\\\",\\\"MIT\\\"]\"", parsed);

    const array_table = try renderForTest(
        \\let value = builtins.fromTOML ''
        \\  [[products]]
        \\  name = "hammer"
        \\  [[products]]
        \\  name = "nail"
        \\''; in builtins.toJSON (builtins.map (p: p.name) value.products)
    );
    defer std.testing.allocator.free(array_table);
    try std.testing.expectEqualStrings("\"[\\\"hammer\\\",\\\"nail\\\"]\"", array_table);
}

test "evaluate version parsing builtins" {
    const split = try renderForTest("builtins.splitVersion \"1.0-beta2\"");
    defer std.testing.allocator.free(split);
    try std.testing.expectEqualStrings("[ \"1\" \"0\" \"beta\" \"2\" ]", split);

    const equal = try renderForTest("builtins.compareVersions \"1.02\" \"1.2\"");
    defer std.testing.allocator.free(equal);
    try std.testing.expectEqualStrings("0", equal);

    const pre = try renderForTest("builtins.compareVersions \"1.0pre\" \"1.0\"");
    defer std.testing.allocator.free(pre);
    try std.testing.expectEqualStrings("-1", pre);

    const drv = try renderForTest("(builtins.parseDrvName \"foo-bar-1.2pre3\").version");
    defer std.testing.allocator.free(drv);
    try std.testing.expectEqualStrings("\"1.2pre3\"", drv);
}

test "evaluate regex builtins" {
    const matched = try renderForTest("builtins.match \"(.*)e?abi.*\" \"gnueabihf\"");
    defer std.testing.allocator.free(matched);
    try std.testing.expectEqualStrings("[ \"gnue\" ]", matched);

    const unmatched = try renderForTest("builtins.match \"[[:digit:]]+\" \"abc\"");
    defer std.testing.allocator.free(unmatched);
    try std.testing.expectEqualStrings("null", unmatched);

    const interval = try renderForTest("builtins.match \"^$|^[[:alnum:]]([[:alnum:]_-]{0,61}[[:alnum:]])?$\" \"nixos\"");
    defer std.testing.allocator.free(interval);
    try std.testing.expectEqualStrings("[ \"ixos\" ]", interval);

    const split = try renderForTest("builtins.split \"[^[:alnum:]+._?=-]+\" \"abc///def\"");
    defer std.testing.allocator.free(split);
    try std.testing.expectEqualStrings("[ \"abc\" [ ] \"def\" ]", split);
}

test "evaluate control and error builtins" {
    var ev = try Evaluator.init(std.testing.allocator, 0);
    defer ev.deinit();

    try std.testing.expectError(error.NixThrow, ev.evaluate("builtins.throw \"nope\""));
    try std.testing.expectError(error.NixAbort, ev.evaluate("builtins.abort \"nope\""));

    const try_success = try renderForTest("(builtins.tryEval (1 + 2)).success");
    defer std.testing.allocator.free(try_success);
    try std.testing.expectEqualStrings("true", try_success);

    const try_value = try renderForTest("(builtins.tryEval (builtins.throw \"nope\")).value");
    defer std.testing.allocator.free(try_value);
    try std.testing.expectEqualStrings("false", try_value);

    const try_attr_select = try renderForTest("(builtins.tryEval ((builtins.throw \"nope\").a)).success");
    defer std.testing.allocator.free(try_attr_select);
    try std.testing.expectEqualStrings("false", try_attr_select);

    const try_attr_or = try renderForTest("(builtins.tryEval ((builtins.throw \"nope\").a or false)).success");
    defer std.testing.allocator.free(try_attr_or);
    try std.testing.expectEqualStrings("false", try_attr_or);

    const try_after_failed_call = try renderForTest("let f = x: builtins.throw \"nope\"; in builtins.toJSON (builtins.tryEval (f 1))");
    defer std.testing.allocator.free(try_after_failed_call);
    try std.testing.expectEqualStrings("\"{\\\"success\\\":false,\\\"value\\\":false}\"", try_after_failed_call);

    const traced = try renderForTest("builtins.trace \"message\" 42");
    defer std.testing.allocator.free(traced);
    try std.testing.expectEqualStrings("42", traced);

    const broken = try renderForTest("builtins.break 42");
    defer std.testing.allocator.free(broken);
    try std.testing.expectEqualStrings("42", broken);
}

test "evaluate string context builtins" {
    const drv_context = try renderForTest(
        \\let d = builtins.derivation { name = "pkg"; system = "x86_64-linux"; builder = "/bin/sh"; };
        \\in builtins.hasContext (builtins.toString d)
    );
    defer std.testing.allocator.free(drv_context);
    try std.testing.expectEqualStrings("true", drv_context);

    const interpolated = try renderForTest(
        \\let d = builtins.derivation { name = "pkg"; system = "x86_64-linux"; builder = "/bin/sh"; };
        \\in builtins.hasContext "${d}"
    );
    defer std.testing.allocator.free(interpolated);
    try std.testing.expectEqualStrings("true", interpolated);

    const discarded = try renderForTest(
        \\let d = builtins.derivation { name = "pkg"; system = "x86_64-linux"; builder = "/bin/sh"; };
        \\in builtins.getContext (builtins.unsafeDiscardOutputDependency d.drvPath)
    );
    defer std.testing.allocator.free(discarded);
    try std.testing.expect(std.mem.indexOf(u8, discarded, "path = true") != null);

    const appended = try renderForTest(
        \\builtins.hasContext (builtins.appendContext "x" {
        \\  "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-a.drv" = { outputs = [ "out" ]; };
        \\})
    );
    defer std.testing.allocator.free(appended);
    try std.testing.expectEqualStrings("true", appended);

    const merged_outputs = try renderForTest(
        \\let
        \\  dep = builtins.derivation { name = "dep"; outputs = [ "out" "bin" ]; system = "x86_64-linux"; builder = "/bin/sh"; };
        \\  ctx = builtins.getContext "${dep.bin}${dep.out}";
        \\in builtins.concatStringsSep "," ((builtins.getAttr (builtins.unsafeDiscardStringContext dep.drvPath) ctx).outputs)
    );
    defer std.testing.allocator.free(merged_outputs);
    try std.testing.expectEqualStrings("\"bin,out\"", merged_outputs);

    const merged_output_drv_path = try renderForTest(
        \\let
        \\  dep = builtins.derivation { name = "dep"; outputs = [ "out" "bin" ]; system = "x86_64-linux"; builder = "/bin/sh"; };
        \\  pkg = builtins.derivation { name = "pkg"; system = "x86_64-linux"; builder = "/bin/sh"; text = "${dep.bin}${dep.out}"; };
        \\in pkg.drvPath
    );
    defer std.testing.allocator.free(merged_output_drv_path);
    try std.testing.expectEqualStrings("\"/nix/store/8yjj0xh9r8937p4mv51iwnrl62jjx08p-pkg.drv\"", merged_output_drv_path);

    const json_context_drv_path = try renderForTest(
        \\let
        \\  dep = builtins.derivation { name = "dep"; outputs = [ "out" "dev" ]; system = "x86_64-linux"; builder = "/bin/sh"; };
        \\  pkg = builtins.derivation {
        \\    name = "pkg";
        \\    system = "x86_64-linux";
        \\    builder = "/bin/sh";
        \\    text = builtins.toJSON [ "${dep.dev}/include" "${dep.out}/lib" ];
        \\  };
        \\in pkg.drvPath
    );
    defer std.testing.allocator.free(json_context_drv_path);
    try std.testing.expectEqualStrings("\"/nix/store/ls6lgnv49ck6xbl68m7pgabhy8mn90ss-pkg.drv\"", json_context_drv_path);

    const replace_json_context_drv_path = try renderForTest(
        \\let
        \\  dep = builtins.derivation { name = "dep"; outputs = [ "out" "dev" ]; system = "x86_64-linux"; builder = "/bin/sh"; };
        \\  pkg = builtins.derivation {
        \\    name = "pkg";
        \\    system = "x86_64-linux";
        \\    builder = "/bin/sh";
        \\    text = builtins.replaceStrings [ "@x@" ] [ (builtins.toJSON [ "${dep.dev}/include" "${dep.out}/lib" ]) ] "value @x@";
        \\  };
        \\in pkg.drvPath
    );
    defer std.testing.allocator.free(replace_json_context_drv_path);
    try std.testing.expectEqualStrings("\"/nix/store/kbi5xhbc0747awhah1yjsn6qpsbq62mg-pkg.drv\"", replace_json_context_drv_path);

    const xml_context_drv_path = try renderForTest(
        \\let
        \\  dep = builtins.derivation { name = "dep"; outputs = [ "out" "dev" ]; system = "x86_64-linux"; builder = "/bin/sh"; };
        \\  pkg = builtins.derivation {
        \\    name = "pkg";
        \\    system = "x86_64-linux";
        \\    builder = "/bin/sh";
        \\    text = builtins.toXML [ "${dep.dev}/include" "${dep.out}/lib" ];
        \\  };
        \\in pkg.drvPath
    );
    defer std.testing.allocator.free(xml_context_drv_path);
    try std.testing.expectEqualStrings("\"/nix/store/xmzlcawiq24yfhr33qs49i0p54czwsc3-pkg.drv\"", xml_context_drv_path);

    const derivation_list_trailing_empty_drv_path = try renderForTest(
        \\let
        \\  pkg = builtins.derivation {
        \\    name = "pkg2";
        \\    system = "x86_64-linux";
        \\    builder = "/bin/sh";
        \\    x = [ "a" "b" [ ] ];
        \\  };
        \\in pkg.drvPath
    );
    defer std.testing.allocator.free(derivation_list_trailing_empty_drv_path);
    try std.testing.expectEqualStrings("\"/nix/store/riqzq8wvpskgpp5azvvdypvy22impx7s-pkg2.drv\"", derivation_list_trailing_empty_drv_path);
}
