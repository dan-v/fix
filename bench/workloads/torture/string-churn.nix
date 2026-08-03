# String-churn probe: a strict fold that creates fresh UNIQUE strings every
# step and keeps only the last one. Lengths are capped (substring) so this
# isolates churn volume from the separate quadratic-growth pathology of
# unbounded accumulation.
#
# Under immortal interning every intermediate string lives forever, so RSS
# and intern data bytes grow linearly with the step count. With GC-able
# heap strings the intermediates die young and the footprint should
# plateau. Compare:
#   fix eval --stats bench/workloads/torture/string-churn.nix   (intern: data_bytes)
let
  n = 1000000;
in
  builtins.stringLength (
    builtins.foldl'
      (acc: i: builtins.substring 0 64 "u${toString i}-${acc}")
      "seed"
      (builtins.genList (x: x) n)
  )
