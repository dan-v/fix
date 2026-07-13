# String-bound: build, join, rewrite and split large strings.
# Stresses interpolation/toString, concatStringsSep, replaceStrings, split and
# stringLength — the string machinery.
let
  n = 120000;
  parts = builtins.genList (i: "item-${toString i}") n;
  joined = builtins.concatStringsSep "," parts;
  swapped = builtins.replaceStrings [ "," "item" ] [ ";" "elt" ] joined;
  pieces = builtins.filter builtins.isString (builtins.split ";" swapped);
in
  builtins.stringLength swapped + builtins.length pieces
