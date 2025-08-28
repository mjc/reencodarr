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
        # current is 28.0.2
        erlang = pkgs.erlang;
        # erlang = pkgs.erlang.override {
        #   version = "28.0.2";
        #   src = pkgs.fetchurl {
        #     url = "https://github.com/erlang/otp/releases/download/OTP-${erlang.version}/otp_src_${erlang.version}.tar.gz";
        #     sha256 = "sha256-zkPciimta8G22/yX8FPS6FC0pMKQ7KBlBY1rM85HbbU=";
        #   };
        # };
        beamPackages = pkgs.beam.packagesWith erlang;
        elixir = beamPackages.elixir.override {
          erlang = erlang;
          version = "1.19.0-rc.0";
          src = pkgs.fetchurl {
            url = "https://github.com/elixir-lang/elixir/archive/refs/tags/v${elixir.version}.tar.gz";
            sha256 = "sha256-YvkDCI578h4SmtEA5XP2XQNjixDGIHdwIEuOa50Uh5E=";
          };
        };
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
              pkgs.elixir
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
          '';
        };
      }
    );
}
