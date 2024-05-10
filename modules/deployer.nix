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
    mkMerge
    mkIf
    types
    mapAttrsToList
    listToAttrs
    nameValuePair
    recursiveUpdate
    fold
    optional
    ;
  inherit (lib.lists) map;
  inherit (utils) escapeSystemdPath;
  cfg = config.deployer;
  monitorCfg = config.monitor;

  phases = [
    "evaluated"
    "built"
    "tested"
    "copied"
    "deployed"
  ];

  hostOpts =
    { name, ... }:
    {
      options = {
        name = mkOption {
          type = types.str;
          default = name;
        };
        attribute = mkOption {
          type = types.str;
          default = name;
        };
        ssh = {
          user = mkOption {
            type = types.str;
            default = "root";
          };
          host = mkOption {
            type = types.str;
            default = name;
          };
        };
      };
    };

  makeHostServices =
    unitCommon: hostCfg:
    let
      serviceCommon = unitCommon // {
        path =
          [ cfg.packages.nix ]
          ++ (with pkgs; [
            jq
            git
            openssh
          ]);
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
      "${cfg.unitPrefix}-evaluate@${escapedName}" = recursiveUpdate serviceCommon {
        description = "Evaluate %I";
        requiredBy = [ "${cfg.unitPrefix}-evaluated.target" ];
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

      "${cfg.unitPrefix}-build@${escapedName}" = recursiveUpdate serviceCommon rec {
        description = "Build %I";
        requiredBy = [ "${cfg.unitPrefix}-built.target" ];
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

      "${cfg.unitPrefix}-copy@${escapedName}" = recursiveUpdate serviceCommon rec {
        description = "Copy to %I";
        requiredBy = [ "${cfg.unitPrefix}-copied.target" ];
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

      "${cfg.unitPrefix}-test@${escapedName}" = recursiveUpdate serviceCommon rec {
        description = "Test %I";
        requiredBy = [ "${cfg.unitPrefix}-tested.target" ];
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

      "${cfg.unitPrefix}-deploy@${escapedName}" = recursiveUpdate serviceCommon rec {
        description = "Deploy %I";
        requiredBy = [ "${cfg.unitPrefix}-deployed.target" ];
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
      identifier = mkOption { type = types.str; };
      flake = mkOption { type = types.str; };
      hosts = mkOption { type = with types; attrsOf (submodule hostOpts); };
      phase = mkOption {
        type = types.enum phases;
        default = "deployed";
      };
      syncMode =
        let
          type = types.enum [
            "requiredBy"
            "wantedBy"
          ];
          syncModeOpt = mkOption {
            inherit type;
            default = cfg.syncMode.default;
          };
        in
        {
          default = mkOption {
            inherit type;
            default = "requiredBy";
          };
        }
        // listToAttrs (map (p: nameValuePair p syncModeOpt) phases);
      syncOn =
        let
          syncOnOpt = mkOption {
            type = types.bool;
            default = cfg.syncOn.default;
          };
        in
        {
          default = mkOption {
            type = types.bool;
            default = true;
          };
        }
        // listToAttrs (map (p: nameValuePair p syncOnOpt) phases);
      packages = {
        nix = mkOption {
          type = types.package;
          default = pkgs.nix;
          defaultText = "pkgs.nix";
        };
      };
      unitsDirectory = mkOption {
        type = types.str;
        default = "$XDG_RUNTIME_DIR/systemd/user";
      };

      unitPrefix = mkOption {
        type = types.str;
        default = "wd-${cfg.identifier}";
      };
    };
    monitor = {
      interval = mkOption {
        type = types.str;
        default = "0.5";
      };
    };
  };

  config = mkMerge [
    (
      let
        common = {
          unitConfig = {
            StopWhenUnneeded = true;
          };
        };
      in
      {
        systemd.services = fold recursiveUpdate { } (mapAttrsToList (_: makeHostServices common) cfg.hosts);
        systemd.targets = listToAttrs (
          map (
            phase:
            nameValuePair "${cfg.unitPrefix}-${phase}" (
              recursiveUpdate common {
                description = "All Hosts ${phase}";
                aliases = mkIf (phase == cfg.phase) [ "${cfg.unitPrefix}.target" ];
              }
            )
          ) phases
        );
        systemd.slices."${cfg.unitPrefix}" = recursiveUpdate common {
          description = "Slice deplyer ${cfg.identifier}";
        };
      }
    )

    {
      build.deployer = pkgs.writeShellApplication {
        name = "deployer";
        runtimeInputs = [ config.build.monitor ] ++ (with pkgs; [ getopt ]);
        text = ''
          # cmdline argument parsing
          # https://stackoverflow.com/a/29754866/7362315

          LONGOPTS=include:,exclude:,install-only
          OPTIONS=i:e:

          PARSED=$(getopt --options="$OPTIONS" --longoptions="$LONGOPTS" --name "$0" -- "$@") || exit 1
          eval set -- "$PARSED"

          include_regex=".*"
          exclude_regex=""
          install_only=""
          while true; do
            case "$1" in
              -i|--include)
                include_regex="$2"
                shift 2
                ;;
              -e|--exclude)
                exclude_regex="$2"
                shift 2
                ;;
              --install-only)
                install_only=1
                shift
                ;;
              --)
                shift
                break
                ;;
              *)
                echo "unexpected parameter: $1"
                exit 1
                ;;
            esac
          done
          if [[ $# -ne 0 ]]; then
              echo "unexpected parameters: $*"
              exit 1
          fi

          # filter units

          units="$(mktemp -t --directory "weird-deployer-units-XXXXXX")"
          cp --recursive --no-dereference "${config.build.generatedUnits}/"* "$units/"
          chmod --recursive u+w "$units"
          pushd "$units" >/dev/null
          for host_file in "${cfg.unitPrefix}"-*@*.service; do
            [[ "$host_file" =~ ^.*@(.+)\.service$ ]]
            host="''${BASH_REMATCH[1]}"
            if [[ ! "$host" =~ ^$include_regex$ ]] || [[ "$host" =~ ^$exclude_regex$ ]]; then
              # mask file
              ln --symbolic --force /dev/null "$host_file"
            fi
          done
          popd >/dev/null

          # install and  start units

          mkdir --parents "${cfg.unitsDirectory}"
          rm --recursive --force "${cfg.unitsDirectory}/${cfg.unitPrefix}"*
          cp --recursive --no-dereference "$units/"* "${cfg.unitsDirectory}/"
          rm --recursive "$units"

          systemctl --user daemon-reload
          systemctl --user reset-failed "${cfg.unitPrefix}*"

          if [ "$install_only" = "1" ]; then
            exit
          fi

          function stop_all {
            systemctl --user stop "${cfg.unitPrefix}*"
          }
          trap stop_all EXIT
          before_start="$(date --iso-8601=seconds)"
          systemctl --user start "${cfg.unitPrefix}.target" --no-block
          WEIRD_DEPLOYER_MONITOR_SINCE="$before_start" monitor
        '';
      };

      build.clean = pkgs.writeShellApplication {
        name = "clean";
        text = ''
          set -x
          systemctl --user stop "${cfg.unitPrefix}*"
          systemctl --user reset-failed "${cfg.unitPrefix}*"
          rm --recursive "${cfg.unitsDirectory}/${cfg.unitPrefix}"*
          systemctl --user daemon-reload
        '';
      };

      build.monitor = pkgs.writeShellApplication {
        name = "monitor";
        runtimeInputs = with pkgs; [
          tmux
          viddy
          jq
        ];
        text = ''
          session="${cfg.unitPrefix}"

          tmux kill-session -t "$session" 2>/dev/null || true

          if [ -v WEIRD_DEPLOYER_MONITOR_SINCE ] &&
             [ -n "$WEIRD_DEPLOYER_MONITOR_SINCE" ]; then
            since="$WEIRD_DEPLOYER_MONITOR_SINCE"
          else
            since="$(date --iso-8601=seconds)"
          fi

          tmux new-session -d -s "$session" \
            'SYSTEMD_COLORS=true viddy --interval "${monitorCfg.interval}" \
              systemctl \
                --user list-units \
                --state=activating --state=failed \
                "${cfg.unitPrefix}*"'
          window=0
          tmux split-window -t "$session:$window" -v -l 50% -d \
            "journalctl --user --unit '${cfg.unitPrefix}*' \
               --follow --since '$since' --output=json | \
               jq --raw-output '\"\(.SYSLOG_IDENTIFIER)> \(.MESSAGE)\"'"
          tmux split-window -t "$session:$window.{bottom}" -h -l 30% -d \
            "journalctl --user --unit '${cfg.unitPrefix}*' \
               --follow --since '$since' \
               --identifier systemd --output=cat"
          tmux split-window -t "$session:$window" -h -l 30% -d \
            'SYSTEMD_COLORS=true viddy --interval "${monitorCfg.interval}" \
              systemctl --user list-jobs "${cfg.unitPrefix}*"'
          tmux rename-window -t "$session:$window" "monitor"

          tmux set-option -t "$session" mouse on

          # run bind-key commands in the tmux session
          window=1
          tmux new-window -t "$session:1" bash -c "
          for key in C-c q Escape; do
            tmux bind-key -T root \"\$key\" kill-session -t '$session'
          done
          "

          if [ -v WEIRD_DEPLOYER_MONITOR_NO_ATTACH ] &&
             [ "$WEIRD_DEPLOYER_MONITOR_NO_ATTACH" = "1" ]; then
            echo "$session"
            exit
          fi

          tmux attach-session -t "$session"
        '';
      };
    }
  ];
}
