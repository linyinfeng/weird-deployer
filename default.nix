{
  pkgs ? import <nixpkgs> { },
  lib ? pkgs.lib,
}:
{ modules }:
let
  evalResult = lib.evalModules {
    modules =
      import ./modules/module-list.nix
      ++ [
        {
          _module.args = {
            inherit pkgs;
          };
        }
      ]
      ++ modules;
  };
in
evalResult
