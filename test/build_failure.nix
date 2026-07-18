# Evaluation and instantiation succeed; realization fails deliberately.
#
#   fix eval test/build_failure.nix
#   fix build --no-out-link test/build_failure.nix
let
  pkgs = import (import ../npins).nixpkgs {};
in
  pkgs.runCommand "fix-intentional-build-failure" {} ''
    echo "intentional build failure from test/build_failure.nix" >&2
    exit 1
  ''
