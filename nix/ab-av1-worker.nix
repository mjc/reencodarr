{pkgs}: let
  version = "0.11.4-worker-00b76a7";
in
  pkgs.rustPlatform.buildRustPackage {
    pname = "ab-av1";
    inherit version;

    src = pkgs.fetchFromGitHub {
      owner = "mjc";
      repo = "ab-av1";
      rev = "00b76a7";
      hash = "sha256-WM+sKVqiCrO+19o4UrmzaFyTUy5llSfl+NjPg4X/4xY=";
    };

    cargoHash = "sha256-uqnxEfSuv0V5pimU7ciUwMqHshxPENtiiZf6Ol+KKds=";

    nativeBuildInputs = [pkgs.pkg-config];
    buildInputs = [pkgs.openssl];
    # Upstream's test suite invokes ffmpeg/ffprobe, which are supplied by the
    # Reencodarr runtime closure rather than this package build sandbox.
    doCheck = false;

    meta.mainProgram = "ab-av1";
  }
