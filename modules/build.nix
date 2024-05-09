{ lib, ... }:
let
  inherit (lib) types;
in
{
  options.build = lib.mkOption {
    type = types.submoduleWith {
      modules = [ { freeformType = with types; lazyAttrsOf (uniq unspecified); } ];
    };
  };
}
