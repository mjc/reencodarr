{pkgs}: let
  version = "0.11.4-worker-6df0047";
in
  pkgs.rustPlatform.buildRustPackage {
    pname = "ab-av1";
    inherit version;

    src = pkgs.fetchFromGitHub {
      owner = "mjc";
      repo = "ab-av1";
      rev = "6df0047eecf466416d7430cb50f3fe8c8a5b62b7";
      hash = "sha256-HHsMmSSX5Cb43LnVa355Hy6NbwvGjV0W2shmZeV1uDg=";
    };

    cargoHash = "sha256-QAIyQbUoLaZZd4K1PjIJodEZqGUbrcKnuCnitlNRVYA=";

    nativeBuildInputs = [pkgs.pkg-config];
    buildInputs = [pkgs.openssl];
    # Upstream's test suite invokes ffmpeg/ffprobe, which are supplied by the
    # Reencodarr runtime closure rather than this package build sandbox.
    doCheck = false;

    meta.mainProgram = "ab-av1";
  }
