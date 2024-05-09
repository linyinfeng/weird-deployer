{
  config,
  pkgs,
  lib,
  utils,
  ...
}:
let
  inherit (lib)
    types
    mapAttrsToList
    recursiveUpdate
    fold
    optional
    ;
  inherit (utils) escapeSystemdPath;
  cfg = config.deployer;
  monitorCfg = config.monitor;

  hostOpts =
    { name, ... }:
    {
      options = {
        name = lib.mkOption {
          type = types.str;
          default = name;
        };
        attribute = lib.mkOption {
          type = types.str;
          default = name;
        };
        ssh = {
          user = lib.mkOption {
            type = types.str;
            default = "root";
          };
          host = lib.mkOption {
            type = types.str;
            default = name;
          };
        };
      };
    };

  makeHostServices =
    hostCfg:
    let
      common = {
        path =
          [ cfg.packages.nix ]
          ++ (with pkgs; [
            jq
            git
            openssh
          ]);
        unitConfig = {
          StopWhenUnneeded = true;
        };
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          PrivateTmp = true;
          WorkingDirectory = "/tmp";
          Slice = "${cfg.unitPrefix}.slice";
        };
      };
      nixCmd = "nix --extra-experimental-features 'nix-command flakes'";
      escapedName = escapeSystemdPath hostCfg.name;

      prelude = pkgs.writeShellScript "prelude.sh" ''
        toplevel_store_path="$(readlink toplevel)"
        function target_command {
          ssh "${hostCfg.ssh.user}@${hostCfg.ssh.host}" "$@"
        }
        function target_switch_to_configuration {
          target_command \
            systemd-run \
              --setenv=LOCALE_ARCHIVE \
              --collect \
              --no-ask-password \
              --pipe \
              --quiet \
              --service-type=exec \
              --unit=nixos-rebuild-switch-to-configuration \
              --wait \
              "$toplevel_store_path/bin/switch-to-configuration" \
              "$@"
        }
      '';
    in
    {
      "${cfg.unitPrefix}-evaluate@${escapedName}" = recursiveUpdate common {
        description = "Evaluate %I";
        serviceConfig = {
          SyslogIdentifier = "wd-evaluate-${hostCfg.name}";
        };
        script = ''
          ${nixCmd} path-info --derivation \
            "${cfg.flake}#nixosConfigurations.\"${hostCfg.attribute}\".config.system.build.toplevel" \
            >evaluate-result
          echo "result: $(cat evaluate-result)"
        '';
      };

      "${cfg.unitPrefix}-build@${escapedName}" = recursiveUpdate common rec {
        description = "Build %I";
        requires = [
          "${cfg.unitPrefix}-evaluate@${escapedName}.service"
        ] ++ optional cfg.syncOn.evaluated "${cfg.unitPrefix}-evaluated.target";
        after = requires;
        unitConfig = {
          JoinsNamespaceOf = [ "${cfg.unitPrefix}-evaluate@${escapedName}.service" ];
        };
        serviceConfig = {
          SyslogIdentifier = "wd-build-${hostCfg.name}";
        };
        script = ''
          ${nixCmd} build "$(cat evaluate-result)^out" \
            --out-link toplevel \
            --print-build-logs \
            --verbose
          echo "result: $(realpath toplevel)"
        '';
      };

      "${cfg.unitPrefix}-copy@${escapedName}" = recursiveUpdate common rec {
        description = "Copy to %I";
        requires = [
          "${cfg.unitPrefix}-build@${escapedName}.service"
        ] ++ optional cfg.syncOn.built "${cfg.unitPrefix}-built.target";
        after = requires;
        unitConfig = {
          JoinsNamespaceOf = [ "${cfg.unitPrefix}-build@${escapedName}.service" ];
        };
        serviceConfig = {
          SyslogIdentifier = "wd-copy-${hostCfg.name}";
        };
        script = ''
          nix copy --to "ssh://"${hostCfg.ssh.user}@${hostCfg.ssh.host}"" ./toplevel
        '';
      };

      "${cfg.unitPrefix}-test@${escapedName}" = recursiveUpdate common rec {
        description = "Test %I";
        requires = [
          "${cfg.unitPrefix}-copy@${escapedName}.service"
        ] ++ optional cfg.syncOn.copied "${cfg.unitPrefix}-copied.target";
        after = requires;
        unitConfig = {
          JoinsNamespaceOf = [ "${cfg.unitPrefix}-build@${escapedName}.service" ];
        };
        serviceConfig = {
          SyslogIdentifier = "wd-test-${hostCfg.name}";
        };
        script = ''
          source "${prelude}"
          target_command
          target_switch_to_configuration test
        '';
      };

      "${cfg.unitPrefix}-deploy@${escapedName}" = recursiveUpdate common rec {
        description = "Deploy %I";
        requires = [
          "${cfg.unitPrefix}-test@${escapedName}.service"
        ] ++ optional cfg.syncOn.tested "${cfg.unitPrefix}-tested.target";
        after = requires;
        unitConfig = {
          JoinsNamespaceOf = [ "${cfg.unitPrefix}-build@${escapedName}.service" ];
        };
        serviceConfig = {
          SyslogIdentifier = "wd-deploy-${hostCfg.name}";
        };
        script = ''
          source "${prelude}"
          target_command nix-env --profile /nix/var/nix/profiles/system --set "$toplevel_store_path"
          target_switch_to_configuration boot
        '';
      };
    };
in
{
  options = {
    deployer = {
      identifier = lib.mkOption { type = types.str; };
      flake = lib.mkOption { type = types.str; };
      hosts = lib.mkOption { type = with types; attrsOf (submodule hostOpts); };
      syncMode =
        let
          type = types.enum [
            "requires"
            "wants"
          ];
          syncModeOpt = lib.mkOption {
            inherit type;
            default = cfg.syncMode.default;
          };
        in
        {
          default = lib.mkOption {
            inherit type;
            default = "requires";
          };
          evaluated = syncModeOpt;
          built = syncModeOpt;
          copied = syncModeOpt;
          tested = syncModeOpt;
          deployed = syncModeOpt;
        };
      syncOn =
        let
          syncOnOpt = lib.mkOption {
            type = types.bool;
            default = cfg.syncOn.default;
          };
        in
        {
          default = lib.mkOption {
            type = types.bool;
            default = true;
          };
          evaluated = syncOnOpt;
          built = syncOnOpt;
          copied = syncOnOpt;
          tested = syncOnOpt;
        };
      packages = {
        nix = lib.mkOption {
          type = types.package;
          default = pkgs.nix;
          defaultText = "pkgs.nix";
        };
      };
      unitsDirectory = lib.mkOption {
        type = types.str;
        default = "$XDG_RUNTIME_DIR/systemd/user";
      };

      unitPrefix = lib.mkOption {
        type = types.str;
        default = "wd-${cfg.identifier}";
      };
    };
    monitor = {
      interval = lib.mkOption {
        type = types.str;
        default = "0.5";
      };
    };
  };

  config = lib.mkMerge [
    (
      let
        hostServices =
          action: mapAttrsToList (name: _: "${cfg.unitPrefix}-${action}@${name}.service") cfg.hosts;
      in
      {
        systemd.targets = {
          "${cfg.unitPrefix}-evaluated".${cfg.syncMode.evaluated} = hostServices "evaluate";
          "${cfg.unitPrefix}-built".${cfg.syncMode.built} = hostServices "build";
          "${cfg.unitPrefix}-copied".${cfg.syncMode.copied} = hostServices "copy";
          "${cfg.unitPrefix}-tested".${cfg.syncMode.tested} = hostServices "test";
          "${cfg.unitPrefix}-deployed".${cfg.syncMode.deployed} = hostServices "deploy";
        };
        systemd.services = fold recursiveUpdate { } (mapAttrsToList (_: makeHostServices) cfg.hosts);
      }
    )

    (
      let
        common = {
          unitConfig = {
            StopWhenUnneeded = true;
          };
        };
      in
      {
        # common units
        systemd.targets = {
          "${cfg.unitPrefix}-evaluated" = lib.recursiveUpdate common { description = "All Hosts Evaluated"; };
          "${cfg.unitPrefix}-built" = lib.recursiveUpdate common { description = "All Hosts Built"; };
          "${cfg.unitPrefix}-copied" = lib.recursiveUpdate common { description = "All Hosts Copied"; };
          "${cfg.unitPrefix}-tested" = lib.recursiveUpdate common { description = "All Hosts Tested"; };
          "${cfg.unitPrefix}-deployed" = lib.recursiveUpdate common { description = "All Hosts Deployed"; };
        };
        systemd.slices."${cfg.unitPrefix}" = lib.recursiveUpdate common {
          description = "Slice deplyer ${cfg.identifier}";
        };
      }
    )

    {
      build.deployer = pkgs.writeShellApplication {
        name = "deployer";
        runtimeInputs = [ config.build.monitor ];
        text = ''
          mkdir --parents "${cfg.unitsDirectory}"
          install -m644 "${config.build.generatedUnits}/"* "${cfg.unitsDirectory}/"
          systemctl --user daemon-reload
          systemctl --user reset-failed "${cfg.unitPrefix}*"

          function stop_all {
            systemctl --user stop "${cfg.unitPrefix}*"
          }
          trap stop_all EXIT
          systemctl --user start "${cfg.unitPrefix}-deployed.target" --no-block
          monitor
        '';
      };

      build.clean = pkgs.writeShellApplication {
        name = "clean";
        text = ''
          rm -v "${cfg.unitsDirectory}/${cfg.unitPrefix}"*
        '';
      };

      build.monitor = pkgs.writeShellApplication {
        name = "monitor";
        runtimeInputs = with pkgs; [
          tmux
          viddy
        ];
        text = ''
          session="${cfg.unitPrefix}"

          tmux kill-session -t "$session" 2>/dev/null || true

          tmux new-session -d -s "$session" \
            'SYSTEMD_COLORS=true viddy --interval "${monitorCfg.interval}" \
              systemctl \
                --user list-units \
                --state=activating --state=failed \
                "${cfg.unitPrefix}*"'
          window=0
          tmux split-window -t "$session:$window" -v -l 50% -d \
            'journalctl --user --unit "${cfg.unitPrefix}*" --no-hostname --follow'
          tmux split-window -t "$session:$window" -h -l 30% -d \
            'SYSTEMD_COLORS=true viddy --interval "${monitorCfg.interval}" \
              systemctl --user list-jobs "${cfg.unitPrefix}*"'
          tmux rename-window -t "$session:$window" "monitor"

          for key in "C-c" "q" "Escape"; do
            tmux bind-key -T root "$key" kill-session -t "$session"
          done

          tmux set-option -t "$session" mouse on

          tmux attach-session -t "$session"
        '';
      };
    }
  ];
}
