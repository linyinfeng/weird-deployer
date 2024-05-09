{
  config,
  lib,
  pkgs,
  ...
}:
{
  _module.args.utils = import "${pkgs.path}/nixos/lib/utils.nix" { inherit lib config pkgs; };
}
