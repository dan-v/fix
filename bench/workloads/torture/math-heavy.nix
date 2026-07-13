# Arithmetic-bound: many integer ops per step, folded iteratively.
#
# `builtins.foldl'` is strict and iterative in every evaluator, so this does
# not grow the call stack (a deep *recursive* loop would just overflow Nix's
# max-call-depth); the work is dominated by the add/sub/mul/div/compare in the
# step function rather than by allocation or calls.
let
  n = 3000000;
  step = acc: i:
    let
      sq = i * i;
      half = i / 2;
      adj = if half * 2 == i then sq else sq - half;
    in
      acc + adj - (acc / 8) + (i / 3);
in
  builtins.foldl' step 0 (builtins.genList (i: i) n)
