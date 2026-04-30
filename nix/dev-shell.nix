{
  pkgs,
  beam_minimal,
}: let
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
    postPatch =
      (old.postPatch or "")
      + ''
        substituteInPlace libavcodec/libsvtav1.c \
          --replace-fail "param->enable_adaptive_quantization = 0;" ""
      '';
  });
  erlang = beam_minimal.interpreters.erlang_28;
  beamPackages = beam_minimal.packagesWith erlang;
  elixir = beamPackages.elixir_1_19;
in
  pkgs.mkShell {
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
        pkgs.ab-av1
        pkgs.mediainfo
        pkgs.gpac
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
      export SECRET_KEY_BASE="WEWsPGIpK/OgJA2ZcwzsgZxWKSAp35IsqWPYsvSUmm5awBUGpvsVOcG2kkDteXR1"
      export COMPOSE_BAKE=true

      export GPG_TTY=$(tty)
      export PINENTRY_USER_DATA="USE_CURSES=1"

      echo "pinentry-program ${pkgs.pinentry-curses}/bin/pinentry-curses" >> ~/.gnupg/gpg-agent.conf 2>/dev/null || true
      git config --global gpg.program "${pkgs.gnupg}/bin/gpg"
    '';
  }
