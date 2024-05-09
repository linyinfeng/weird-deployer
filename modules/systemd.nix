{
  config,
  pkgs,
  lib,
  utils,
  ...
}:
let
  inherit (lib)
    mkOption
    mkPackageOption
    mapAttrs'
    types
    ;
  inherit (utils) systemdUtils;
  inherit (systemdUtils.lib) generateUnits targetToUnit serviceToUnit;
  cfg = config.systemd;
in
{
  options.systemd = {
    services = mkOption {
      type = systemdUtils.types.services;
      default = { };
    };
    targets = mkOption {
      type = systemdUtils.types.targets;
      default = { };
    };
    units = mkOption {
      type = systemdUtils.types.units;
      default = { };
    };
    slices = mkOption {
      type = systemdUtils.types.slices;
      default = { };
    };

    # required by systemd utils
    package = mkPackageOption pkgs "systemd" { };
    globalEnvironment = mkOption {
      type =
        with types;
        attrsOf (
          nullOr (oneOf [
            str
            path
            package
          ])
        );
      default = { };
    };
  };
  config = {
    systemd.units =
      let
        withName = cfgToUnit: cfg: lib.nameValuePair cfg.name (cfgToUnit cfg);
      in
      mapAttrs' (_: withName serviceToUnit) cfg.services
      // mapAttrs' (_: withName targetToUnit) cfg.targets
      // mapAttrs' (_: withName targetToUnit) cfg.slices;
    build.generatedUnits = generateUnits {
      allowCollisions = false;
      units = cfg.units;

      # packages are not important
      # since we have no upstream units or wants
      type = "user";
      packages = [ ];
      package = pkgs.runCommand "empty" { } "mkdir $out";
      upstreamUnits = [ ];
      upstreamWants = [ ];
    };
  };
}
