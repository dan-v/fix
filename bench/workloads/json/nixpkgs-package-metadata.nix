# A real-world-ish wide JSON result: instantiate several independent nixpkgs
# packages and serialize a stable subset of their metadata.
let
  pkgs = import <nixpkgs> {system = "x86_64-linux";};
  names = [
    "bash" "coreutils" "curl" "git" "gnutar" "gzip" "jq" "nix"
    "openssh" "python3" "ripgrep" "sqlite" "systemd" "vim" "wget" "zlib"
  ];
in
  builtins.listToAttrs (map (name: {
    inherit name;
    value = let package = pkgs.${name}; in {
      inherit (package) pname version outputs;
      drvPath = package.drvPath;
      outputName = package.outputName;
    };
  }) names)
