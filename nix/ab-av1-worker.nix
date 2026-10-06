{pkgs}: let
  version = "0.11.7-worker-a191e5c";
in
  pkgs.rustPlatform.buildRustPackage {
    pname = "ab-av1";
    inherit version;

    src = pkgs.fetchFromGitHub {
      owner = "mjc";
      repo = "ab-av1-worker";
      rev = "a191e5c43698cd47d08b3c6c3d7927b20e383dbb";
      hash = "sha256-/lpI2yMHngik0ttRoqwhY3UNfz1I/dSuenepE2/JKoM=";
    };

    cargoHash = "sha256-AqHPpDJ2uvnZ+68ZNj9GQ6nOL16TVNUQ1o+d4GPFZsI=";

    nativeBuildInputs = [pkgs.pkg-config];
    buildInputs = [pkgs.openssl];
    # Upstream's test suite invokes ffmpeg/ffprobe, which are supplied by the
    # Reencodarr runtime closure rather than this package build sandbox.
    doCheck = false;

    meta.mainProgram = "ab-av1";
  }
