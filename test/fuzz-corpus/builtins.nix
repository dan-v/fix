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
builtins.concatMap (x: [ x ]) [ 1 2 ]
(builtins.mapAttrs (name: value: value) { a = 1; }).a
builtins.genList (x: x) 2
builtins.stringLength "abcd"
builtins.concatStringsSep "," [ "a" "b" ]
builtins.substring 1 2 "abcd"
builtins.replaceStrings [ "a" "d" ] [ "A" "D" ] "abcd"
builtins.foldl' (a: b: a + b) 0 [ 1 2 3 ]
builtins.foldl' (a: b: a) 1 [ (1 / 0) ]
builtins.foldl' (a: b: b) 0 [ 1 2 ]
