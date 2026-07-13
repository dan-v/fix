# Attribute-set-bound: build large sets, merge them, and look values back up.
# Stresses listToAttrs, attrNames, mapAttrs, the `//` update operator, and
# dynamic attribute selection — the operations the module system leans on.
let
  n = 60000;
  mk = builtins.listToAttrs (builtins.genList (i: {
    name = "k${toString i}";
    value = i;
  }) n);
  bumped = builtins.mapAttrs (_: v: v + 1) mk;
  merged = mk // bumped // { sentinel = 0; };
in
  builtins.foldl' (acc: k: acc + merged.${k}) 0 (builtins.attrNames merged)
