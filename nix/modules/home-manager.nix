# home-manager module for fix. home-manager's `programs.direnv` exposes
# `stdlib` (written to the per-user direnvrc), which is where `use fix` goes.
import ./shared.nix {
  installPackage = pkg: {home.packages = [pkg];};
  direnvOption = ["programs" "direnv" "stdlib"];
}
