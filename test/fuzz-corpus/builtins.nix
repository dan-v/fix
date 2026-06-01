builtins.toString 42
builtins.toString true
builtins.toString "x"
builtins.isAttrs {}
builtins.isAttrs []
builtins.isList [ 1 2 ]
builtins.isString "x"
builtins.isInt 1
builtins.isInt 1.5
builtins.isBool false
builtins.isNull null
builtins.isFloat 1.5
builtins.isFunction (x: x)
builtins.isPath ./foo
builtins.length [ 1 (1 / 0) 3 ]
builtins.head [ 4 5 ]
builtins.tail [ 4 5 ]
builtins.attrNames { b = 2; a = 1; }
builtins.attrValues { b = 2; a = 1; }
builtins.hasAttr "a" { a = 1; }
builtins.hasAttr "b" { a = 1; }
builtins.getAttr "a" { a = 3; }
builtins.elemAt [ 1 2 3 ] 1
builtins.isFunction (builtins.elemAt [ 1 ])
builtins.typeOf 1
builtins.typeOf { }
builtins.typeOf (x: x)
builtins.add 1 2.5
builtins.sub 5 2
builtins.mul 3 4
builtins.div (-7) 2
builtins.lessThan "a" "b"
builtins.bitAnd 6 3
builtins.bitOr 4 1
builtins.bitXor 6 3
builtins.floor (-1.2)
builtins.ceil (-1.8)
builtins.baseNameOf /foo/bar
builtins.dirOf /foo/bar
builtins.typeOf (builtins.toPath /foo/bar)
builtins.isPath (builtins.toPath /foo/bar)
builtins.true
builtins.false
builtins.null
builtins.langVersion
builtins.storeDir
builtins.concatLists [ [ 1 ] [ (1 / 0) ] [ 3 ] ]
(builtins.listToAttrs [ { name = "a"; value = 1; } { name = "a"; value = 2; } ]).a
(builtins.listToAttrs [ { name = "a"; value = 1 / 0; } ]) ? a
(builtins.removeAttrs { a = 1; b = 2; } [ "a" ]).b
(builtins.removeAttrs { a = 1 / 0; b = 2; } [ "b" ]) ? a
(builtins.intersectAttrs { a = 1; } { a = 2; b = 3; }).a
(builtins.intersectAttrs { a = 1; } { a = 1 / 0; b = 2; }) ? a
builtins.elem 2 [ 1 2 3 ]
builtins.elem 4 [ 1 2 3 ]
builtins.elem 1 [ 1 (1 / 0) ]
builtins.seq 1 2
builtins.seq [ (1 / 0) ] 2
let x = builtins.seq (1 / 0) 2; in 3
builtins.deepSeq { a = 1; b = [ 2 ]; } 3
let x = builtins.deepSeq [ (1 / 0) ] 2; in 3
builtins.pathExists ./test/fuzz-corpus/builtins.nix
builtins.isString (builtins.readFile ./test/fuzz-corpus/basics.nix)
(import ./test/fuzz-corpus/imported.nix).value
(builtins.import ./test/fuzz-corpus/imported.nix).value
(import ./test/fuzz-corpus/import-dir).value
builtins.getAttr "default.nix" (builtins.readDir ./test/fuzz-corpus/import-dir)
builtins.readFileType ./test/fuzz-corpus/imported.nix
builtins.readFileType (builtins.findFile [ { prefix = "fixture"; path = ./test/fuzz-corpus; } ] "fixture/imported.nix")
builtins.all (x: x < 3) [ 1 2 ]
builtins.all (x: x < 3) [ 1 4 (1 / 0) ]
builtins.any (x: x == 2) [ 1 2 (1 / 0) ]
builtins.any (x: x == 2) [ 1 3 ]
builtins.filter (x: x < 3) [ 1 4 2 ]
builtins.length (builtins.filter (x: true) [ (1 / 0) ])
builtins.filter (x: false) [ (1 / 0) ]
builtins.map (x: x + 1) [ 1 2 ]
builtins.length (builtins.map (x: builtins.throw "x") [ 1 ])
builtins.concatMap (x: [ x ]) [ 1 2 ]
(builtins.mapAttrs (name: value: value) { a = 1; }).a
(let fix = f: let x = f x; in x; in builtins.attrNames (fix (self: let y = builtins.mapAttrs self.f { a = 1; }; in { f = n: v: v; } // y)))
(builtins.mapAttrs (name: value: if name == "a" then value else builtins.throw "bad") { a = 1; b = 2; }).a
builtins.genList (x: x) 2
builtins.stringLength "abcd"
builtins.concatStringsSep "," [ "a" "b" ]
builtins.substring 1 2 "abcd"
builtins.replaceStrings [ "a" "d" ] [ "A" "D" ] "abcd"
builtins.hashString "sha256" "abc"
builtins.toJSON { b = [ 2 false ]; a = "x"; }
builtins.toJSON { outPath = "/nix/store/example"; a = 1; }
builtins.toJSON { __toString = self: self.name; name = "pkg"; }
(builtins.fromJSON "{\"b\":2,\"a\":[1,true,null]}").a
builtins.compareVersions "1.0pre" "1.0"
builtins.splitVersion "1.0-beta2"
(builtins.parseDrvName "foo-bar-1.2pre3").version
(builtins.tryEval (builtins.throw "x")).success
(builtins.tryEval ((builtins.throw "x").a)).success
(builtins.tryEval ((builtins.throw "x").a or false)).success
builtins.trace "x" 1
(builtins.derivation { name = "pkg"; system = "x86_64-linux"; builder = "/bin/sh"; }).type
(builtins.derivation { name = "pkg"; outputs = [ "out" "dev" ]; system = "x86_64-linux"; builder = "/bin/sh"; }).dev.outputName
builtins.attrNames (builtins.derivation { name = "pkg"; outputs = [ "out" "dev" ]; system = "x86_64-linux"; builder = "/bin/sh"; }).dev
builtins.attrNames (builtins.derivationStrict { name = "pkg"; outputs = [ "out" "dev" ]; system = "x86_64-linux"; builder = "/bin/sh"; })
(builtins.derivation { name = "pkg"; system = "x86_64-linux"; builder = "/bin/sh"; __structuredAttrs = true; env = { A = 1; B = [ "x" ]; }; passAsFile = [ "foo" ]; foo = "bar"; }).drvAttrs.env.B
builtins.hasContext (builtins.toString (builtins.derivation { name = "pkg"; system = "x86_64-linux"; builder = "/bin/sh"; }))
(builtins.tryEval (builtins.derivation { name = builtins.throw "x"; system = "x86_64-linux"; builder = "/bin/sh"; })).success
(builtins.tryEval (builtins.derivation { name = builtins.throw "x"; system = "x86_64-linux"; builder = "/bin/sh"; }).outPath).success
(let mk = builder: builtins.derivation { name = "pkg"; system = "x86_64-linux"; inherit builder; }; in (mk "/bin/sh").outPath == (mk "/bin/bash").outPath)
(let mk = hash: builtins.derivation { name = "pkg"; system = "x86_64-linux"; builder = "/bin/sh"; outputHash = hash; outputHashAlgo = "sha256"; outputHashMode = "flat"; }; in (mk "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=").outPath == (mk "sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=").outPath)
builtins.attrNames builtins.builtins
rec { a = 1; ${"b"} = a + 1; }.b
builtins.isString (builtins.path { path = ./test/fuzz-corpus/imported.nix; name = "imported"; })
builtins.substring 0 11 (builtins.path { path = ./test/fuzz-corpus/imported.nix; name = "imported"; })
builtins.sort (a: b: a < b) [ 2 1 ]
(builtins.partition (x: x < 2) [ 1 2 ]).right
(builtins.groupBy (x: "k") [ 1 2 ]).k
builtins.catAttrs "a" [ { a = 1; } { b = 2; } { a = 3; } ]
(builtins.zipAttrsWith (name: values: builtins.length values) [ { a = 1; } { a = 2; b = 3; } ]).a
(builtins.zipAttrsWith (name: values: if name == "a" then 1 else builtins.throw "bad") [ { a = 1; b = 2; } ]).a
(builtins.functionArgs ({ a ? 1 }: a)).a
builtins.unsafeGetAttrPos "a" { a = 1; }
builtins.unsafeGetAttrPos "value" (import ./test/fuzz-corpus/imported.nix)
builtins.foldl' (a: b: a + b) 0 [ 1 2 3 ]
builtins.foldl' (a: b: a) 1 [ (1 / 0) ]
builtins.foldl' (a: b: b) 0 [ 1 2 ]
