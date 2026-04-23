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
        svt-av1-hdr = pkgs.svt-av1.overrideAttrs (_old: {
          pname = "svt-av1-hdr";
          version = "4.0.1";
          src = pkgs.fetchFromGitHub {
            owner = "juliobbv-p";
            repo = "svt-av1-hdr";
            rev = "v4.0.1";
            hash = "sha256-jfyolWcPcfMzxjBszg1KY9eHc6KRsp41h3lQKsrgiDU=";
          };
        });
        ffmpeg-svt-hdr = (pkgs.ffmpeg-full.override {svt-av1 = svt-av1-hdr;}).overrideAttrs (old: {
          # ffmpeg 8.x references enable_adaptive_quantization which was removed in SVT-AV1 2.x
          # (the base for svt-av1-hdr v4.x). Drop the line so the encoder uses its default.
          postPatch =
            (old.postPatch or "")
            + ''
              substituteInPlace libavcodec/libsvtav1.c \
                --replace-fail "param->enable_adaptive_quantization = 0;" ""
            '';
        });
        # Use beam_minimal (wxSupport=false) to drop the wxwidgets → webkitgtk build chain;
        # observer/wx GUI not needed for a server app.
        erlang = pkgs.beam_minimal.interpreters.erlang_28;
        beamPackages = pkgs.beam_minimal.packagesWith erlang;
        elixir = beamPackages.elixir_1_19;
      in {
        # Docker image for the application
        packages.dockerImage = pkgs.dockerTools.buildLayeredImage {
          name = "reencodarr";
          tag = "latest";

          contents = [
            erlang
            elixir
            ffmpeg-svt-hdr
            pkgs.gpac
            pkgs.fd
            pkgs.curl
            pkgs.bash
            pkgs.coreutils
            pkgs.sqlite
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
          buildInputs = [
            pkgs.bashInteractive
          ];
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
              pkgs.cspell
              pkgs.alejandra
              pkgs.nil
              ffmpeg-svt-hdr
              pkgs.fd
              pkgs.curl
              pkgs.docker-compose
              pkgs.gnupg
              pkgs.pinentry-curses
              # Video processing tools for CI/dev
              pkgs.ab-av1
              pkgs.mediainfo
              pkgs.gpac
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
            export SECRET_KEY_BASE="WEWsPGIpK/OgJA2ZcwzsgZxWKSAp35IsqWPYsvSUmm5awBUGpvsVOcG2kkDteXR1" # dev only, not a secret
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
