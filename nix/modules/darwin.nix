# nix-darwin module for fix. nix-darwin's `programs.direnv` mirrors NixOS's,
# including `direnvrcExtra`, so the wiring is identical to the NixOS module.
import ./shared.nix {
  installPackage = pkg: {environment.systemPackages = [pkg];};
  direnvOption = ["programs" "direnv" "direnvrcExtra"];
}
