(x: x + 1) 41
let inc = x: x + 1; in inc 41
let f = x: 1; in f (1 / 0)
with { x = 40; y = 2; }; x + y
let x = 1; in with { x = 2; }; x
builtins.toString 42
builtins.isAttrs {}
