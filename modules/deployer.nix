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
    concatMapStringsSep
    escapeShellArgs
    fold
    optional
    attrNames
    ;
  inherit (lib.lists) map subtractLists;
  inherit (utils) escapeSystemdPath;
  cfg = config.deployer;
  monitorCfg = config.monitor;

  phaseCfgs = {
    evaluated = {
      requires = [ ];
    };
    built = {
      requires = [ "evaluated" ];
    };
    copied = {
      requires = [ "built" ];
    };
    system-saved = {
      requires = [ ];
    };
    tested = {
      requires = [
        "copied"
        "system-saved"
      ];
    };
    profile-saved = {
      requires = [ ];
    };
    profile-updated = {
      requires = [
        "tested"
        "profile-saved"
      ];
    };
    deployed = {
      requires = [ "profile-updated" ];
    };
  };
  phases = attrNames phaseCfgs;

  tasks = [
    "evaluate"
    "build"
    "copy"
    "system-save"
    "test"
    "test-rollback"
    "profile-save"
    "profile-update"
    "profile-rollback"
    "deploy"
    "deploy-rollback"
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
      nixCmd = "nix --extra-experimental-features 'nix-command flakes' --log-format raw --verbose";
      escapedName = escapeSystemdPath hostCfg.name;

      prelude = pkgs.writeShellScript "prelude.sh" ''
        function target_command {
          ssh "${hostCfg.ssh.user}@${hostCfg.ssh.host}" "$@"
        }
        function target_switch_to_configuration {
          toplevel="$1"
          shift
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
              "$toplevel/bin/switch-to-configuration" \
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
        requires = [ "${cfg.unitPrefix}-evaluate@${escapedName}.service" ];
        after = requires ++ optional cfg.syncOn.evaluated "${cfg.unitPrefix}-evaluated.target";
        unitConfig = {
          JoinsNamespaceOf = [ "${cfg.unitPrefix}-evaluate@${escapedName}.service" ];
        };
        serviceConfig = {
          SyslogIdentifier = "wd-build-${hostCfg.name}";
        };
        script = ''
          ${nixCmd} build "$(cat evaluate-result)^out" \
            --out-link toplevel \
            --print-build-logs
          echo "result: $(realpath toplevel)"
        '';
      };

      "${cfg.unitPrefix}-copy@${escapedName}" = recursiveUpdate serviceCommon rec {
        description = "Copy to %I";
        requiredBy = [ "${cfg.unitPrefix}-copied.target" ];
        requires = [ "${cfg.unitPrefix}-build@${escapedName}.service" ];
        after = requires ++ optional cfg.syncOn.built "${cfg.unitPrefix}-built.target";
        unitConfig = {
          JoinsNamespaceOf = [ "${cfg.unitPrefix}-build@${escapedName}.service" ];
        };
        serviceConfig = {
          SyslogIdentifier = "wd-copy-${hostCfg.name}";
        };
        script = ''
          ${nixCmd} copy --to "ssh://"${hostCfg.ssh.user}@${hostCfg.ssh.host}"" ./toplevel
        '';
      };

      "${cfg.unitPrefix}-system-save@${escapedName}" = recursiveUpdate serviceCommon {
        description = "System save %I";
        requiredBy = [ "${cfg.unitPrefix}-system-saved.target" ];
        serviceConfig = {
          SyslogIdentifier = "wd-system-save-${hostCfg.name}";
        };
        script = ''
          source "${prelude}"
          target_command readlink /run/current-system >old-current-system
        '';
      };

      "${cfg.unitPrefix}-test@${escapedName}" = recursiveUpdate serviceCommon rec {
        description = "Test %I";
        requiredBy = [ "${cfg.unitPrefix}-tested.target" ];
        requires = [
          "${cfg.unitPrefix}-copy@${escapedName}.service"
          "${cfg.unitPrefix}-system-save@${escapedName}.service"
        ];
        after =
          requires
          ++ optional cfg.syncOn.copied "${cfg.unitPrefix}-copied.target"
          ++ optional cfg.syncOn.system-saved "${cfg.unitPrefix}-system-saved.target";
        unitConfig = {
          JoinsNamespaceOf = [ "${cfg.unitPrefix}-build@${escapedName}.service" ];
        };
        serviceConfig = {
          SyslogIdentifier = "wd-test-${hostCfg.name}";
        };
        script = ''
          source "${prelude}"
          target_switch_to_configuration "$(readlink toplevel)" test
        '';
      };

      "${cfg.unitPrefix}-test-rollback@${escapedName}" = recursiveUpdate serviceCommon {
        description = "System rollback %I";
        requiredBy = [ "${cfg.unitPrefix}-rollbacked@${escapedName}.target" ];
        conflicts = [ "${cfg.unitPrefix}-test@${escapedName}.service" ];
        unitConfig = {
          JoinsNamespaceOf = [ "${cfg.unitPrefix}-system-save@${escapedName}.service" ];
        };
        serviceConfig = {
          SyslogIdentifier = "wd-test-rollback-${hostCfg.name}";
        };
        script = ''
          if [ -f old-current-system ]; then
            source "${prelude}"
            target_switch_to_configuration "$(cat old-current-system)" test
          else
            echo "no need to rollback"
          fi
        '';
      };

      "${cfg.unitPrefix}-profile-save@${escapedName}" = recursiveUpdate serviceCommon {
        description = "Profile save %I";
        requiredBy = [ "${cfg.unitPrefix}-profile-saved.target" ];
        serviceConfig = {
          SyslogIdentifier = "wd-profile-save-${hostCfg.name}";
        };
        script = ''
          source "${prelude}"
          target_command readlink /nix/var/nix/profiles/system >old-system-profile
        '';
      };

      "${cfg.unitPrefix}-profile-update@${escapedName}" = recursiveUpdate serviceCommon rec {
        description = "Profile update %I";
        requiredBy = [ "${cfg.unitPrefix}-profile-updated.target" ];
        requires = [
          "${cfg.unitPrefix}-test@${escapedName}.service"
          "${cfg.unitPrefix}-profile-save@${escapedName}.service"
        ];
        after =
          requires
          ++ optional cfg.syncOn.tested "${cfg.unitPrefix}-tested.target"
          ++ optional cfg.syncOn.profile-saved "${cfg.unitPrefix}-profile-saved.target";
        unitConfig = {
          JoinsNamespaceOf = [ "${cfg.unitPrefix}-build@${escapedName}.service" ];
        };
        serviceConfig = {
          SyslogIdentifier = "wd-profile-update-${hostCfg.name}";
        };
        script = ''
          source "${prelude}"
          target_command nix-env --profile /nix/var/nix/profiles/system --set "$(readlink toplevel)"
        '';
      };

      "${cfg.unitPrefix}-profile-rollback@${escapedName}" = recursiveUpdate serviceCommon {
        description = "Profile rollback %I";
        requiredBy = [ "${cfg.unitPrefix}-rollbacked@${escapedName}.target" ];
        conflicts = [ "${cfg.unitPrefix}-profile-update@${escapedName}.service" ];
        unitConfig = {
          JoinsNamespaceOf = [ "${cfg.unitPrefix}-profile-save@${escapedName}.service" ];
        };
        serviceConfig = {
          SyslogIdentifier = "wd-profile-rollback-${hostCfg.name}";
        };
        script = ''
          if [ -f old-system-profile ]; then
            source "${prelude}"
            target_command ln --symbolic --force --no-dereference --verbose \
              "$(cat old-system-profile)" /nix/var/nix/profiles/system
          else
            echo "no need to rollback"
          fi
        '';
      };

      "${cfg.unitPrefix}-deploy@${escapedName}" = recursiveUpdate serviceCommon rec {
        description = "Deploy %I";
        requiredBy = [ "${cfg.unitPrefix}-deployed@${escapedName}.target" ];
        requires = [ "${cfg.unitPrefix}-profile-update@${escapedName}.service" ];
        after = requires ++ optional cfg.syncOn.profile-updated "${cfg.unitPrefix}-profile-updated.target";
        serviceConfig = {
          SyslogIdentifier = "wd-deploy-${hostCfg.name}";
        };
        script = ''
          source "${prelude}"
          target_switch_to_configuration /run/current-system boot
        '';
      };

      "${cfg.unitPrefix}-deploy-rollback@${escapedName}" = recursiveUpdate serviceCommon rec {
        description = "Deploy rollback %I";
        requiredBy = [ "${cfg.unitPrefix}-rollbacked@${escapedName}.target" ];
        requires = [
          "${cfg.unitPrefix}-test-rollback@${escapedName}.service"
          "${cfg.unitPrefix}-profile-rollback@${escapedName}.service"
        ];
        after = requires;
        unitConfig = {
          JoinsNamespaceOf = [ "${cfg.unitPrefix}-profile-save@${escapedName}.service" ];
        };
        serviceConfig = {
          SyslogIdentifier = "wd-deploy-rollback-${hostCfg.name}";
        };
        script = ''
          if [ -f old-system-profile ]; then
            source "${prelude}"
            target_switch_to_configuration /run/current-system boot
          else
            echo "no need to rollback"
          fi
        '';
      };
    };

  makeHostTargets =
    unitCommon: hostCfg:
    let
      escapedName = escapeSystemdPath hostCfg.name;
    in
    {
      "${cfg.unitPrefix}-rollbacked@${escapedName}" = {
        description = "Host %I rollbacked";
        conflicts = [ "${cfg.unitPrefix}-deployed@${escapedName}.target" ];
      };
      "${cfg.unitPrefix}-deployed@${escapedName}" = {
        description = "Host %I deployed";
        requiredBy = [ "${cfg.unitPrefix}-deployed.target" ];
        onFailure = lib.mkIf cfg.autoRollback [ "${cfg.unitPrefix}-rollbacked@${escapedName}.target" ];
      };
    };

  makePhaseTargets = unitCommon: phase: phaseCfg: {
    "${cfg.unitPrefix}-${phase}" = {
      description = "All Hosts ${phase}";
      aliases = mkIf (phase == cfg.defaultPhase) [ "${cfg.unitPrefix}-default.target" ];
      requires = map (u: "${cfg.unitPrefix}-${u}.target") phaseCfg.requires;
    };
  };
in
{
  options = {
    deployer = {
      identifier = mkOption { type = types.str; };
      flake = mkOption { type = types.str; };
      hosts = mkOption { type = with types; attrsOf (submodule hostOpts); };
      defaultPhase = mkOption {
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
      autoRollback = mkOption {
        type = types.bool;
        default = true;
      };

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

      cli = {
        systemctl = {
          extraOptions = lib.mkOption {
            type = with types; listOf str;
            default = [
              "--user"
              "--show-transaction"
            ];
          };
          commandShotcuts = lib.mkOption {
            type = with types; listOf str;
            default = [
              "list-units"
              "is-active"
              "is-failed"
              "status"
              "show"
              "cat"
              "start"
              "stop"
              "restart"
              "try-restart"
              "kill"
              "freeze"
              "thaw"
              "reset-failed"
              "list-unit-files"
              "list-jobs"
            ];
          };
        };
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
          # nothing
        };
      in
      {
        systemd.services = fold recursiveUpdate { } (mapAttrsToList (_: makeHostServices common) cfg.hosts);
        systemd.targets =
          fold recursiveUpdate { } (mapAttrsToList (_: makeHostTargets common) cfg.hosts)
          // fold recursiveUpdate { } (mapAttrsToList (makePhaseTargets common) phaseCfgs);
        systemd.slices."${cfg.unitPrefix}" = recursiveUpdate common {
          description = "Slice deplyer ${cfg.identifier}";
        };
      }
    )

    (
      let
        systemctl = "systemctl ${escapeShellArgs cfg.cli.systemctl.extraOptions}";
      in
      {
        build.deployer = pkgs.writeShellApplication {
          name = "weird-deployer";
          runtimeInputs =
            (with config.build; [
              prepare
              monitor
            ])
            ++ (with pkgs; [ diffutils ]);
          text = ''
            args=("$@")
            action=""
            if [[ "$#" -ge 1 ]]; then
              action="$1"
              action_args=("''${args[@]:1}")
            fi

            function wd_prepare {
              wd-prepare "$@"
            }
            function wd_systemctl {
              command="$1"
              shift
              systemctl_args=()
              for arg in "$@"; do
                case "$arg" in
                  -*)
                    systemctl_args+=("$arg")
                    ;;
                  *)
                    systemctl_args+=("${cfg.unitPrefix}-$arg")
                    ;;
                esac
              done
              ${systemctl} "$command" "''${systemctl_args[@]}"
            }
            function wd_systemctl_task {
              command="$1"
              shift
              task="$1"
              shift
              wd_systemctl_args=()
              for arg in "$@"; do
                case "$arg" in
                  -*)
                    wd_systemctl_args+=("$arg")
                    ;;
                  *)
                    wd_systemctl_args+=("$task@$arg")
                    ;;
                esac
              done
              wd_systemctl "$command" "''${wd_systemctl_args[@]}"
            }
            function wd_start_phase {
              if [ "$#" -gt 1 ]; then
                phase="$1"
              else
                phase="default"
              fi
              shift
              wd_systemctl start "$phase.target" "$@"
            }
            function wd_stop_all {
              wd_systemctl stop "*"
            }
            function wd_deploy_all {
              wd_systemctl start default.target
            }
            function wd_deploy_all_before_monitor {
              systemctl ${
                escapeShellArgs (subtractLists [ "--show-transaction" ] cfg.cli.systemctl.extraOptions)
              } start "${cfg.unitPrefix}-default.target" --no-block
            }
            function wd_clean {
              wd_systemctl stop "*"
              wd_systemctl reset-failed "*"

              rm --recursive --force --verbose "${cfg.unitsDirectory}/${cfg.unitPrefix}"*
              wd_systemctl daemon-reload
            }
            function wd_monitor {
              wd-monitor "$@"
            }
            function wd {
              no_stop=""
              no_prepare=""
              no_monitor=""
              extra_args=()
              while [ "$#" -ge 1 ]; do
                case "$1" in
                  --no-stop)
                    no_stop="1"
                    shift
                    ;;
                  --no-prepare)
                    no_prepare="1"
                    shift
                    ;;
                  --no-monitor)
                    no_monitor="1"
                    shift
                    ;;
                  *)
                    extra_args+=("$1")
                    shift
                    ;;
                esac
              done

              if [ "$no_prepare" != "1" ]; then
                wd_prepare "''${extra_args[@]}"
              fi
              if [ "$no_stop" != "1" ]; then
                trap wd_stop_all EXIT
              fi

              before_start="$(date --iso-8601=seconds)"
              if [ "$no_monitor" = "1" ]; then
                wd_deploy_all
              else
                wd_deploy_all_before_monitor
                WEIRD_DEPLOYER_MONITOR_SINCE="$before_start" wd_monitor
              fi
            }

            # parse done
            case "$action" in
              prepare)
                wd_prepare "''${action_args[@]}"
                ;;
              systemctl)
                wd_systemctl "''${action_args[@]}"
                ;;
              ${concatMapStringsSep "|" (c: "'${c}'") cfg.cli.systemctl.commandShotcuts})
                wd_systemctl "$action" "''${action_args[@]}"
                ;;
              ${concatMapStringsSep "|" (t: "'${t}'") tasks})
                wd_systemctl_task start "$action" "''${action_args[@]}"
                ;;
              clean)
                wd_clean "''${action_args[@]}"
                ;;
              monitor)
                wd_monitor "''${action_args[@]}"
                ;;
              monitor-attach)
                WEIRD_DEPLOYER_MONITOR_ATTACH_ONLY=1 wd_monitor "''${action_args[@]}"
                ;;
              *)
                # default action
                wd "$@"
                ;;
            esac
          '';
        };

        build.prepare = pkgs.writeShellApplication {
          name = "wd-prepare";
          runtimeInputs = with pkgs; [ getopt ];
          text = ''
            LONGOPTS="include:,exclude:"
            OPTIONS="i:,e:"

            PARSED=$(getopt --options="$OPTIONS" --longoptions="$LONGOPTS" --name "$0" -- "$@") || exit 1
            eval set -- "$PARSED"

            include_regex=".*"
            exclude_regex=""
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
            for host_file in *; do
              if [[ "$host_file" =~ ^.*@(.+)\.(service|target)$ ]]; then
                host="''${BASH_REMATCH[1]}"
                if [[ ! "$host" =~ ^$include_regex$ ]] || [[ "$host" =~ ^$exclude_regex$ ]]; then
                  # mask file
                  ln --symbolic --force /dev/null "$host_file"
                fi
              fi
            done
            popd >/dev/null

            # install and start units

            mkdir --parents "${cfg.unitsDirectory}"
            pushd "$units" >/dev/null
            units_changed=()
            for unit in *; do
              if [[ "$unit" =~ ^.*@(.+)\.(service|target)$ ]] &&
                 [ -e "${cfg.unitsDirectory}/$unit" ] &&
                 ! diff "$unit" "${cfg.unitsDirectory}/$unit" >/dev/null; then
                units_changed+=("$unit")
              fi
            done
            popd >/dev/null
            rm --recursive --force "${cfg.unitsDirectory}/${cfg.unitPrefix}"*
            cp --recursive --no-dereference "$units/"* "${cfg.unitsDirectory}/"
            rm --recursive "$units"

            ${systemctl} daemon-reload
            # stop units under new dependencies
            for unit in "''${units_changed[@]}"; do
              if ${systemctl} is-active "$unit" >/dev/null; then
                ${systemctl} stop "$unit"
              fi
            done
          '';
        };

        build.monitor = pkgs.writeShellApplication {
          name = "wd-monitor";
          runtimeInputs = with pkgs; [
            tmux
            viddy
            jq
          ];
          text = ''
            session="${cfg.unitPrefix}"

            if [ ! -v WEIRD_DEPLOYER_MONITOR_REPLACE_SESSION ] ||
               [ "$WEIRD_DEPLOYER_MONITOR_REPLACE_SESSION" != 1 ]; then
              if tmux has-session -t "$session" 2>/dev/null; then
                tmux attach-session -t "$session"
                exit
              fi
            fi


            if [ ! -v WEIRD_DEPLOYER_MONITOR_ATTACH_ONLY ] ||
               [ "$WEIRD_DEPLOYER_MONITOR_ATTACH_ONLY" != 1 ]; then

              tmux kill-session -t "$session" 2>/dev/null || true

              if [ -v WEIRD_DEPLOYER_MONITOR_SINCE ] &&
                [ -n "$WEIRD_DEPLOYER_MONITOR_SINCE" ]; then
                since="$WEIRD_DEPLOYER_MONITOR_SINCE"
              else
                since="$(date --iso-8601=seconds)"
              fi

              tmux new-session -d -s "$session" \
                'SYSTEMD_COLORS=true viddy --interval "${monitorCfg.interval}" \
                  ${systemctl} list-units "${cfg.unitPrefix}*"'
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
                  ${systemctl} list-jobs "${cfg.unitPrefix}*"'
              tmux rename-window -t "$session:$window" "monitor"

              tmux set-option -t "$session" mouse on

              # run bind-key commands in the tmux session
              window=1
              tmux new-window -t "$session:1" bash -c "
              for key in C-c q Escape; do
                tmux bind-key -T root \"\$key\" detach-client
              done
              "

            fi

            if [ -v WEIRD_DEPLOYER_MONITOR_NO_ATTACH ] &&
               [ "$WEIRD_DEPLOYER_MONITOR_NO_ATTACH" = "1" ]; then
              echo "$session"
              exit
            fi

            tmux attach-session -t "$session"
          '';
        };
      }
    )
  ];
}
