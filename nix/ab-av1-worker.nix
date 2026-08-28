{pkgs}: let
  version = "0.11.5-worker-a4a34a6";
in
  pkgs.rustPlatform.buildRustPackage {
    pname = "ab-av1";
    inherit version;

    src = pkgs.fetchFromGitHub {
      owner = "mjc";
      repo = "ab-av1";
      rev = "a4a34a6";
      hash = "sha256-cPNFdlrOt8tCYXtvfzo8vrhFQ3snIphJ43bOzZH3fkw=";
    };

    cargoHash = "sha256-T+ejY4HbYMUoyLHK9WbDMe9xijcDNAOCMCoakJIfIW4=";

    nativeBuildInputs = [pkgs.pkg-config];
    buildInputs = [pkgs.openssl];
    # Upstream's test suite invokes ffmpeg/ffprobe, which are supplied by the
    # Reencodarr runtime closure rather than this package build sandbox.
    doCheck = false;

    meta.mainProgram = "ab-av1";
  }
