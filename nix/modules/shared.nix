# Shared implementation for the fix modules (NixOS, home-manager, nix-darwin).
#
# Two option trees:
#   * programs.fix           — the CLI itself (install it, pick the package).
#   * programs.direnv.fix     — the direnv integration, sitting alongside
#     programs.direnv.{nix-direnv,mise} the way home-manager groups direnv
#     sub-integrations. It auto-enables with direnv and self-installs fix (so
#     `use fix` works even without programs.fix.enable), mirroring nix-direnv.
#
# The three module systems differ in only two spots, both passed in:
#   * `installPackage pkg` — how to add a package to the environment
#     (NixOS/darwin: `environment.systemPackages`; home-manager: `home.packages`).
#   * `direnvOption` — the attr path of the direnv module's "extra direnvrc"
#     hook (NixOS/darwin: `programs.direnv.direnvrcExtra`; home-manager:
#     `programs.direnv.stdlib`). Both are `types.lines` sourced from the user's
#     direnvrc, which is exactly where fix's `use_fix` helpers need to live.
{
  installPackage,
  direnvOption,
}: {
  config,
  lib,
  pkgs,
  ...
}: let
  fixCfg = config.programs.fix;
  direnvCfg = config.programs.direnv.fix;
  # Register fix's direnv library so `.envrc` files can `use fix`.
  hook = ''
    # fix — `use fix` / `use fix_flake` (managed by programs.direnv.fix.enable)
    source ${fixCfg.package}/share/fix/direnv/fix.sh
  '';
in {
  options.programs.fix = {
    enable = lib.mkEnableOption "the fix Nix evaluator CLI";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../fix.nix {};
      defaultText = lib.literalExpression "pkgs.callPackage (fix + \"/nix/fix.nix\") {}";
      description = "The fix package to install.";
    };
  };

  options.programs.direnv.fix = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = config.programs.direnv.enable or false;
      defaultText = lib.literalExpression "config.programs.direnv.enable";
      description = ''
        Whether to add fix's direnv integration: the `use fix` and
        `use fix_flake` helpers, a drop-in replacement for `use nix` /
        `use flake`.

        Enabled automatically whenever {option}`programs.direnv.enable` is
        set (and requires it — the helper is sourced from the direnvrc the
        direnv module manages). Enabling this also installs
        {option}`programs.fix.package`, so `use fix` resolves the CLI.
      '';
    };
  };

  config = lib.mkMerge [
    (lib.mkIf fixCfg.enable (installPackage fixCfg.package))
    (lib.mkIf direnvCfg.enable (lib.mkMerge [
      {
        assertions = [
          {
            assertion = config.programs.direnv.enable or false;
            message = "programs.direnv.fix.enable requires programs.direnv.enable.";
          }
        ];
      }
      # Self-install so `use fix` works even without programs.fix.enable.
      (installPackage fixCfg.package)
      (lib.setAttrByPath direnvOption (lib.mkAfter hook))
    ]))
  ];
}
