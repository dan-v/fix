(x: x + 1) 41
let inc = x: x + 1; in inc 41
let f = x: 1; in f (1 / 0)
({ x }: x) { x = 41; }
({ x, y }: x + y) { x = 40; y = 2; }
({ x }: 1) { x = 1 / 0; }
({ x ? 2 }: x) { }
({ x, ... }: x) { x = 1; y = 2; }
(args@{ x }: args.x) { x = 3; }
({ x }@args: args.x) { x = 4; }
with { x = 40; y = 2; }; x + y
let x = 1; in with { x = 2; }; x
builtins.toString 42
builtins.isAttrs {}
