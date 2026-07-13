# List/allocation-bound: build a large list, then map / filter / fold over it.
# Stresses genList, map, filter, foldl', list allocation and the GC.
let
  n = 600000;
  xs = builtins.genList (i: i) n;
  doubled = map (x: x * 2) xs;
  evens = builtins.filter (x: builtins.bitAnd x 3 == 0) doubled;
in
  builtins.foldl' (a: b: a + b) 0 evens
