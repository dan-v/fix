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
