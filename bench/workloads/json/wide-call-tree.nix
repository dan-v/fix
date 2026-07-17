# A wide attribute set of independent call-heavy values. JSON serialization
# forces every leaf and gives parallel evaluators useful work to distribute.
let
  branches = 96;
  fib = n: if n < 2 then n else fib (n - 1) + fib (n - 2);
in
  builtins.listToAttrs (builtins.genList (i: {
    name = "branch-${toString i}";
    value = fib 22 + i;
  }) branches)
