{self}: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.reencodarr;
  inherit (lib) mkEnableOption mkIf mkOption literalExpression types;

  serviceEnv =
    {
      PHX_SERVER = "true";
      PHX_HOST = cfg.host;
      PORT = toString cfg.port;
      DATABASE_PATH = cfg.databasePath;
      REENCODARR_DATA_DIR = toString cfg.dataDir;
      REENCODARR_TMPDIR = toString cfg.cacheDir;
    }
    // cfg.extraEnvironment;

  envScript = pkgs.writeShellScript "reencodarr-env" ''
    set -euo pipefail
    ${lib.optionalString (cfg.environmentFile != null) ''
      set -a
      . ${cfg.environmentFile}
      set +a
    ''}
    ${lib.optionalString (cfg.secretKeyBaseFile != null) ''
      export SECRET_KEY_BASE="$(< "$CREDENTIALS_DIRECTORY/secret_key_base")"
    ''}
  '';

  migrateScript = pkgs.writeShellScript "reencodarr-migrate" ''
    set -euo pipefail
    . ${envScript}
    exec ${lib.getExe cfg.package} eval "Reencodarr.Release.migrate()"
  '';

  startScript = pkgs.writeShellScript "reencodarr-start" ''
    set -euo pipefail
    . ${envScript}
    exec ${lib.getExe cfg.package} start
  '';

  remoteScript = pkgs.writeShellApplication {
    name = "reencodarr-remote";
    runtimeInputs = [pkgs.systemd];
    text = ''
      runner=()
      if [ "$(id -u)" -ne 0 ]; then
        if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
          runner=(sudo)
        elif [ -x /run/wrappers/bin/doas ]; then
          runner=(/run/wrappers/bin/doas)
        elif [ -x /run/wrappers/bin/sudo ]; then
          runner=(/run/wrappers/bin/sudo)
        elif command -v doas >/dev/null 2>&1; then
          runner=("$(command -v doas)")
        else
          echo "reencodarr-remote requires root, sudo, or doas" >&2
          exit 1
        fi
      fi

      exec "''${runner[@]}" systemd-run \
        --quiet \
        --wait \
        --collect \
        --pty \
        --uid=${cfg.user} \
        --gid=${cfg.group} \
        --working-directory=${cfg.dataDir} \
        --setenv=REENCODARR_DATA_DIR=${cfg.dataDir} \
        ${lib.getExe cfg.package} remote
    '';
  };

  rpcScript = pkgs.writeShellApplication {
    name = "reencodarr-rpc";
    runtimeInputs = [pkgs.systemd];
    text = ''
      if [ "$#" -eq 0 ]; then
        echo "usage: reencodarr-rpc 'Elixir.expression()'" >&2
        exit 64
      fi

      runner=()
      if [ "$(id -u)" -ne 0 ]; then
        if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
          runner=(sudo)
        elif [ -x /run/wrappers/bin/doas ]; then
          runner=(/run/wrappers/bin/doas)
        elif [ -x /run/wrappers/bin/sudo ]; then
          runner=(/run/wrappers/bin/sudo)
        elif command -v doas >/dev/null 2>&1; then
          runner=("$(command -v doas)")
        else
          echo "reencodarr-rpc requires root, sudo, or doas" >&2
          exit 1
        fi
      fi

      exec "''${runner[@]}" systemd-run \
        --quiet \
        --wait \
        --collect \
        --pipe \
        --uid=${cfg.user} \
        --gid=${cfg.group} \
        --working-directory=${cfg.dataDir} \
        --setenv=REENCODARR_DATA_DIR=${cfg.dataDir} \
        ${lib.getExe cfg.package} rpc "$@"
    '';
  };
in {
  options.services.reencodarr = {
    enable = mkEnableOption "Reencodarr";

    package = mkOption {
      type = types.package;
      default = self.packages.${pkgs.system}.default;
      defaultText = literalExpression "inputs.reencodarr.packages.${pkgs.system}.default";
      example = literalExpression "inputs.reencodarr.packages.${pkgs.system}.default";
      description = "Reencodarr package to run.";
    };

    host = mkOption {
      type = types.str;
      default = "127.0.0.1";
    };

    port = mkOption {
      type = types.port;
      default = 4000;
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/reencodarr";
    };

    cacheDir = mkOption {
      type = types.path;
      default = "/var/cache/reencodarr";
      description = "Directory for temporary working files and caches.";
    };

    databasePath = mkOption {
      type = types.str;
      default = "/var/lib/reencodarr/reencodarr.db";
      defaultText = literalExpression ''"${config.services.reencodarr.dataDir}/reencodarr.db"'';
      description = "Path to the SQLite database file.";
    };

    user = mkOption {
      type = types.str;
      default = "reencodarr";
    };

    group = mkOption {
      type = types.str;
      default = "reencodarr";
    };

    nice = mkOption {
      type = types.int;
      default = 19;
      description = "CPU niceness for the Reencodarr service.";
    };

    ioSchedulingClass = mkOption {
      type = types.enum ["realtime" "best-effort" "idle"];
      default = "idle";
      description = "I/O scheduling class for the Reencodarr service.";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
    };

    environmentFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Shell-style environment file loaded before startup.";
    };

    secretKeyBaseFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "File containing the Phoenix SECRET_KEY_BASE.";
    };

    extraEnvironment = mkOption {
      type = types.attrsOf types.str;
      default = {};
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion =
          cfg.secretKeyBaseFile
          != null
          || cfg.environmentFile != null
          || builtins.hasAttr "SECRET_KEY_BASE" cfg.extraEnvironment;
        message = "services.reencodarr requires SECRET_KEY_BASE via secretKeyBaseFile, environmentFile, or extraEnvironment.";
      }
    ];

    users.groups = mkIf (cfg.group == "reencodarr") {
      reencodarr = {};
    };

    users.users = mkIf (cfg.user == "reencodarr") {
      reencodarr = {
        isSystemUser = true;
        group = cfg.group;
        home = cfg.dataDir;
        createHome = true;
      };
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 ${cfg.user} ${cfg.group} - -"
      "d ${cfg.cacheDir} 0750 ${cfg.user} ${cfg.group} - -"
      "d ${builtins.dirOf cfg.databasePath} 0750 ${cfg.user} ${cfg.group} - -"
    ];

    environment.systemPackages = [
      remoteScript
      rpcScript
    ];

    systemd.services.reencodarr = {
      description = "Reencodarr";
      wantedBy = ["multi-user.target"];
      after = ["network-online.target"];
      wants = ["network-online.target"];
      environment = serviceEnv;
      path = [pkgs.bash];
      preStart = "${migrateScript}";
      script = "${startScript}";
      serviceConfig = {
        Type = "exec";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.dataDir;
        ReadWritePaths = [cfg.cacheDir cfg.dataDir (builtins.dirOf cfg.databasePath)];
        LoadCredential = lib.optional (cfg.secretKeyBaseFile != null) "secret_key_base:${cfg.secretKeyBaseFile}";
        Nice = cfg.nice;
        IOSchedulingClass = cfg.ioSchedulingClass;
        Restart = "on-failure";
        RestartSec = 5;
      };
    };

    networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall [cfg.port];
  };
}
