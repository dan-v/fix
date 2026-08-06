# Full-laziness torture: an expensive parameter-independent apply INSIDE a
# lambda applied ~10^3 times with distinct arguments. The enclosing closure
# carries more than two upvalues and every whole-thunk memo key differs
# call-to-call, so per-object memoization never collapses the work; only
# floating the anonymous apply out of the lambda (one shared thunk per
# closure creation) removes the re-evaluation. Expect multi-x under
# FIX_FULL_LAZY=1; identical value either way.
let
  lib = {
    range = n: builtins.genList (i: i) n;
    sum = xs: builtins.foldl' (a: b: a + b) 0 xs;
  };
  base = 7;
  scale = 3;
  bias = 11;
  # `lib.sum (lib.range 5000)` is free of `x`: the MFE. `x`, `base`,
  # `scale`, `bias` keep the surrounding arithmetic param-dependent and the
  # closure's upvalue count above the memo's reach.
  f = x: (x * scale + base) + bias * (lib.sum (lib.range 5000));
  applications = builtins.genList (k: f k) 1000;
in
{
  total = lib.sum applications;
  spot = f 17;
}
