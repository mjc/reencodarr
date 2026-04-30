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
      export SECRET_KEY_BASE="$(< ${cfg.secretKeyBaseFile})"
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
      "d ${builtins.dirOf cfg.databasePath} 0750 ${cfg.user} ${cfg.group} - -"
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
        Restart = "on-failure";
        RestartSec = 5;
      };
    };

    networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall [cfg.port];
  };
}
