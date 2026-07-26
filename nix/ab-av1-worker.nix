{pkgs}: let
  version = "0.11.4-worker-491fe32";
in
  pkgs.rustPlatform.buildRustPackage {
    pname = "ab-av1";
    inherit version;

    src = pkgs.fetchFromGitHub {
      owner = "mjc";
      repo = "ab-av1";
      rev = "491fe32006bbcf670b72ded24665195624cb56c0";
      hash = "sha256-vTO78z8LK+1ZUxUdCKSy/vgH2NS4iMDq+4ndiX6gEPg=";
    };

    cargoHash = "sha256-QAIyQbUoLaZZd4K1PjIJodEZqGUbrcKnuCnitlNRVYA=";

    nativeBuildInputs = [pkgs.pkg-config];
    buildInputs = [pkgs.openssl];
    # Upstream's test suite invokes ffmpeg/ffprobe, which are supplied by the
    # Reencodarr runtime closure rather than this package build sandbox.
    doCheck = false;

    meta.mainProgram = "ab-av1";
  }
