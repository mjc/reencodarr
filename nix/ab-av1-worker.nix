{pkgs}: let
  version = "0.11.5-worker-c0210f6";
in
  pkgs.rustPlatform.buildRustPackage {
    pname = "ab-av1";
    inherit version;

    src = pkgs.fetchFromGitHub {
      owner = "mjc";
      repo = "ab-av1";
      rev = "c0210f6";
      hash = "sha256-ladsQFOVgkMVwrVrDK+6+jeFz9FN2mWzucn2oorGgTU=";
    };

    cargoHash = "sha256-T+ejY4HbYMUoyLHK9WbDMe9xijcDNAOCMCoakJIfIW4=";

    nativeBuildInputs = [pkgs.pkg-config];
    buildInputs = [pkgs.openssl];
    # Upstream's test suite invokes ffmpeg/ffprobe, which are supplied by the
    # Reencodarr runtime closure rather than this package build sandbox.
    doCheck = false;

    meta.mainProgram = "ab-av1";
  }
