# NixOS module for fix. Adds `programs.fix.enable` and, when direnv is enabled,
# wires `use fix` into the system direnvrc via `programs.direnv.direnvrcExtra`.
import ./shared.nix {
  installPackage = pkg: {environment.systemPackages = [pkg];};
  direnvOption = ["programs" "direnv" "direnvrcExtra"];
}
