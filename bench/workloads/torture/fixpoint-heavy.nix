# Fixpoint-bound: a self-referential attribute set resolved through `fix`,
# where each attribute depends on earlier ones. This mirrors the shape of the
# NixOS/home-manager module fixpoint and stresses lazy self-reference,
# thunk sharing, and dynamic attribute resolution.
let
  fix = f: let x = f x; in x;
  n = 4000;
  overlay = self:
    builtins.listToAttrs (builtins.genList (i: {
      name = "n${toString i}";
      value =
        if i == 0
        then 1
        else self."n${toString (i - 1)}" + i;
    }) n);
  resolved = fix overlay;
in
  builtins.foldl' (acc: k: acc + resolved.${k}) 0 (builtins.attrNames resolved)
