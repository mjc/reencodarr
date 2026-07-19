{pkgs}: let
  version = "0.11.4-worker-375d1cde";
in
  pkgs.rustPlatform.buildRustPackage {
    pname = "ab-av1";
    inherit version;

    src = pkgs.fetchFromGitHub {
      owner = "mjc";
      repo = "ab-av1";
      rev = "375d1cde1b24cca314043ddce94cbac48efd9198";
      hash = "sha256-q5vKCwSsrMNn+/rvLOUyMc99W4Qs+CWM2uRw0/siASY=";
    };

    cargoHash = "sha256-IQNMQnQfqmtqX1343LiZVrUg0TLTyT4tcCKbXKK8+6k=";

    nativeBuildInputs = [pkgs.pkg-config];
    buildInputs = [pkgs.openssl];
    # Upstream's test suite invokes ffmpeg/ffprobe, which are supplied by the
    # Reencodarr runtime closure rather than this package build sandbox.
    doCheck = false;

    meta.mainProgram = "ab-av1";
  }
