# Full-laziness expectation-temper: a realistic NixOS-module-shaped mimic —
# expensive parameter-free option defaults inside a "module" function that
# is applied only a HANDFUL of times. Sharing helps by that small factor at
# best; this fixture keeps the win honest next to shared-mfe.nix's ideal.
let
  concatMap = f: xs: builtins.concatLists (map f xs);
  mkDefaultText = builtins.concatStringsSep "," (builtins.genList (i: toString (i * i)) 400);
  module = cfg:
    let
      options = {
        enable = { default = false; description = mkDefaultText; };
        packages = {
          # Param-free apply: floats out of `module`.
          default = concatMap (n: [ n (n * 2) ]) (builtins.genList (i: i + 1) 300);
          description = mkDefaultText;
        };
        extra = cfg.extra or [ ];
      };
    in
    {
      inherit (options.enable) description;
      count = builtins.length options.packages.default + builtins.length options.extra;
      tag = cfg.tag;
    };
  configs = [
    { tag = "a"; }
    { tag = "b"; extra = [ 1 2 3 ]; }
    { tag = "c"; }
    { tag = "d"; extra = [ 9 ]; }
  ];
in
map module configs
