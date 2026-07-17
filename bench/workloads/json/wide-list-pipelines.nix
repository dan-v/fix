# Independent list pipelines whose scalar results are collected into one wide
# JSON list. This mixes allocation, callbacks and forcing across many branches.
let
  branches = 64;
  width = 30000;
  pipeline = seed:
    let
      xs = builtins.genList (i: i + seed) width;
      mapped = map (x: x * 3 + 1) xs;
      selected = builtins.filter (x: builtins.bitAnd x 7 == 0) mapped;
    in
      builtins.foldl' (acc: x: acc + x) 0 selected;
in
  builtins.genList pipeline branches
