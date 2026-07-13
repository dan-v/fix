# Arithmetic-bound: a tight tail loop doing many integer ops per step with
# little allocation. Isolates the integer add/sub/mul/div/compare paths and
# branch handling; the call count is modest relative to the ops per call.
let
  go = acc: i:
    if i == 0
    then acc
    else
      let
        sq = i * i;
        half = i / 2;
        adj = if half * 2 == i then sq else sq - half;
      in
        go (acc + adj - (acc / 8) + (i / 3)) (i - 1);
in
  go 0 4000000
