{
  description = "Development environment for reencodarr";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs = {
    self,
    nixpkgs,
    flake-utils,
    ...
  }:
    flake-utils.lib.eachDefaultSystem (
      system: let
        pkgs = import nixpkgs {inherit system;};
        lib = pkgs.lib;
        # Use latest stable OTP 28 with Elixir 1.19
        erlang = pkgs.erlang_28;
        beamPackages = pkgs.beam.packagesWith erlang;
        elixir = beamPackages.elixir_1_19;
      in {
        # Docker image for the application
        packages.dockerImage = pkgs.dockerTools.buildLayeredImage {
          name = "reencodarr";
          tag = "latest";

          contents = with pkgs; [
            erlang
            elixir
            ffmpeg-full
            fd
            curl
            bash
            coreutils
            sqlite
          ];

          config = {
            Cmd = ["${pkgs.bash}/bin/bash"];
            WorkingDir = "/app";
            Env = [
              "MIX_ENV=prod"
              "PHX_SERVER=true"
              "PORT=4000"
            ];
            ExposedPorts = {
              "4000/tcp" = {};
            };
          };
        };

        devShells.default = pkgs.mkShell {
          nativeBuildInputs =
            [
              erlang
              elixir
              beamPackages.ex_doc
              beamPackages.hex
              beamPackages.rebar
              beamPackages.rebar3
              beamPackages.rebar3-nix
              pkgs.tailwindcss
              pkgs.git
              pkgs.gh
              pkgs.nodePackages.cspell
              pkgs.alejandra
              pkgs.nil
              pkgs.ffmpeg-full
              pkgs.fd
              pkgs.curl
              pkgs.docker-compose
              pkgs.gnupg
              pkgs.pinentry-curses
              # Video processing tools for CI/dev
              pkgs.ab-av1
              pkgs.mediainfo
              # GitHub Actions local testing
              pkgs.act
            ]
            ++ lib.optional pkgs.stdenv.isLinux pkgs.libnotify
            ++ lib.optional pkgs.stdenv.isLinux pkgs.inotify-tools
            ++ lib.optional pkgs.stdenv.isDarwin pkgs.terminal-notifier
            ++ lib.optionals pkgs.stdenv.isDarwin [
              pkgs.apple-sdk
            ];
          shellHook = ''
            gh auth switch --user mjc
            export MIX_OS_DEPS_COMPILE_PARTITION_COUNT=$(( $(nproc) / 2 ))
            export ERL_AFLAGS="-kernel shell_history enabled"
            export DATABASE_URL="ecto://mjc@localhost:5432/reencodarr_dev"
            export SECRET_KEY_BASE="WEWsPGIpK/OgJA2ZcwzsgZxWKSAp35IsqWPYsvSUmm5awBUGpvsVOcG2kkDteXR1"
            export COMPOSE_BAKE=true

            # GPG Configuration
            export GPG_TTY=$(tty)
            export PINENTRY_USER_DATA="USE_CURSES=1"

            # Ensure GPG agent is using the right pinentry
            echo "pinentry-program ${pkgs.pinentry-curses}/bin/pinentry-curses" >> ~/.gnupg/gpg-agent.conf 2>/dev/null || true

            # Configure git to use nix-provided GPG
            git config --global gpg.program "${pkgs.gnupg}/bin/gpg"
          '';
        };
      }
    );
}
