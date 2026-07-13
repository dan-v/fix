# Standalone home-manager profile (drvPath of the activation package).
# `@nixpkgs@` / `@homeManager@` are substituted with pinned store paths by
# nix/bench.nix.
let
  pkgs = import @nixpkgs@ {
    system = "x86_64-linux";
    config = { allowUnfree = true; };
  };
  home-manager = import @homeManager@ { };
  cfg = home-manager.lib.homeManagerConfiguration {
    inherit pkgs;
    modules = [
      {
        home.username = "bench";
        home.homeDirectory = "/home/bench";
        home.stateVersion = "25.11";
        home.packages = with pkgs; [ ripgrep jq fd bat htop ];
        programs.bash.enable = true;
        programs.git = {
          enable = true;
          userName = "bench";
          userEmail = "bench@example.com";
        };
        programs.starship.enable = true;
      }
    ];
  };
in
  cfg.activationPackage.drvPath
