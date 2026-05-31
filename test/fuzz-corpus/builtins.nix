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
