{pkgs}: let
  version = "0.11.4-worker-9ba783b";
in
  pkgs.rustPlatform.buildRustPackage {
    pname = "ab-av1";
    inherit version;

    src = pkgs.fetchFromGitHub {
      owner = "mjc";
      repo = "ab-av1";
      rev = "9ba783b0218e1fe4e4a66ce4a7e47b021e7cad63";
      hash = "sha256-/EDmNKID2lMAaiVXV6jxmeZ7vaxYSj2JJKBeO7or2yg=";
    };

    cargoHash = "sha256-QAIyQbUoLaZZd4K1PjIJodEZqGUbrcKnuCnitlNRVYA=";

    nativeBuildInputs = [pkgs.pkg-config];
    buildInputs = [pkgs.openssl];
    # Upstream's test suite invokes ffmpeg/ffprobe, which are supplied by the
    # Reencodarr runtime closure rather than this package build sandbox.
    doCheck = false;

    meta.mainProgram = "ab-av1";
  }
