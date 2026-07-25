{pkgs}: let
  version = "0.11.4-worker-9cfd91e";
in
  pkgs.rustPlatform.buildRustPackage {
    pname = "ab-av1";
    inherit version;

    src = pkgs.fetchFromGitHub {
      owner = "mjc";
      repo = "ab-av1";
      rev = "9cfd91e";
      hash = "sha256-ZMLwcrUVwW2hM44OW1qAl3ETGg6LPyNdejovfPzxBzc=";
    };

    cargoHash = "sha256-QAIyQbUoLaZZd4K1PjIJodEZqGUbrcKnuCnitlNRVYA=";

    nativeBuildInputs = [pkgs.pkg-config];
    buildInputs = [pkgs.openssl];
    # Upstream's test suite invokes ffmpeg/ffprobe, which are supplied by the
    # Reencodarr runtime closure rather than this package build sandbox.
    doCheck = false;

    meta.mainProgram = "ab-av1";
  }
