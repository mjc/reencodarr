{
  lib,
  pkgs,
  beam_minimal,
  sqlite,
}: let
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

    preConfigure =
      (old.preConfigure or "")
      + ''
        export TMPDIR="/tmp/ffmpeg-configure-tmp"
        mkdir -p "$TMPDIR"
      '';
  });

  erlang = beam_minimal.interpreters.erlang_28;
  beamPackages = beam_minimal.packagesWith erlang;
  elixir = beamPackages.elixir_1_19;

  runtimePath = lib.makeBinPath [
    pkgs.ab-av1
    ffmpeg-svt-hdr
    pkgs.gpac
    pkgs.mediainfo
    pkgs.procps
    pkgs.coreutils
  ];
in
  beamPackages.mixRelease rec {
    pname = "reencodarr";
    version = "0.1.0";
    src = lib.cleanSource ../.;

    mixFodDeps = beamPackages.fetchMixDeps {
      pname = "${pname}-mix-deps";
      inherit src version;
      hash = "sha256-JVWQYieiSMbkDbiMmO8OWC4iRDVXo12ZPTdZFqXeYFU=";
    };

    removeCookie = false;

    nativeBuildInputs = [
      pkgs.tailwindcss
      pkgs.esbuild
    ];

    buildInputs = [sqlite];

    inherit elixir erlang;

    env = {
      EXQLITE_USE_SYSTEM = "1";
      EXQLITE_SYSTEM_CFLAGS = "-I${sqlite.dev}/include";
      EXQLITE_SYSTEM_LDFLAGS = "-L${sqlite.out}/lib -lsqlite3";
      SECRET_KEY_BASE = "nix-build-secret-key-base-not-for-runtime";
    };

    preBuild = ''
      cat >> config/config.exs <<EOF
      config :tailwind, path: "${lib.getExe pkgs.tailwindcss}"
      config :esbuild, path: "${lib.getExe pkgs.esbuild}"
      EOF

      for target in linux-x64 linux-arm64 macos-x64 macos-arm64; do
        ln -sf "${lib.getExe pkgs.tailwindcss}" "_build/tailwind-$target"
        ln -sf "${lib.getExe pkgs.esbuild}" "_build/esbuild-$target"
      done
    '';

    postBuild = ''
      mix do deps.loadpaths --no-deps-check, assets.deploy
    '';

    postInstall = ''
      wrapProgram "$out/bin/reencodarr" \
        --run '
          if [ -z "''${TZDATA_DATA_DIR:-}" ]; then
            if [ -n "''${REENCODARR_DATA_DIR:-}" ]; then
              export TZDATA_DATA_DIR="$REENCODARR_DATA_DIR/tzdata"
            elif [ -n "''${HOME:-}" ]; then
              export TZDATA_DATA_DIR="$HOME/tzdata"
            else
              export TZDATA_DATA_DIR=/tmp/elixir_tzdata
            fi
          fi
          mkdir -p "$TZDATA_DATA_DIR"
        ' \
        --prefix PATH : "${runtimePath}"
    '';

    meta = {
      description = "Bulk AV1 transcoding Phoenix app";
      homepage = "https://github.com/mjc/reencodarr";
      license = lib.licenses.mit;
      mainProgram = "reencodarr";
      platforms = lib.platforms.unix;
    };
  }
