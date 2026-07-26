{pkgs}: let
  version = "0.11.4-worker-da0f11f";
in
  pkgs.rustPlatform.buildRustPackage {
    pname = "ab-av1";
    inherit version;

    src = pkgs.fetchFromGitHub {
      owner = "mjc";
      repo = "ab-av1";
      rev = "da0f11f5c15f0b74de0db8444ec1b6a659659328";
      hash = "sha256-6HDUZKRQr8PU5tu1neBfBqIgxcGCTQ0n9tB0cYz+XWg=";
    };

    cargoHash = "sha256-QAIyQbUoLaZZd4K1PjIJodEZqGUbrcKnuCnitlNRVYA=";

    nativeBuildInputs = [pkgs.pkg-config];
    buildInputs = [pkgs.openssl];
    # Upstream's test suite invokes ffmpeg/ffprobe, which are supplied by the
    # Reencodarr runtime closure rather than this package build sandbox.
    doCheck = false;

    meta.mainProgram = "ab-av1";
  }
