# A moderately large, deeply traversed JSON document. Computation is light;
# value traversal, string handling and serialization dominate.
let
  groups = 48;
  entries = 96;
  mkEntry = group: index: {
    id = group * entries + index;
    name = "group-${toString group}-entry-${toString index}";
    enabled = builtins.bitAnd (group + index) 1 == 0;
    metrics = {
      square = index * index;
      weighted = (group + 1) * (index + 3);
      tags = ["benchmark" "group-${toString group}" "entry-${toString index}"];
    };
  };
in
  builtins.listToAttrs (builtins.genList (group: {
    name = "group-${toString group}";
    value = {
      inherit group;
      entries = builtins.genList (mkEntry group) entries;
    };
  }) groups)
