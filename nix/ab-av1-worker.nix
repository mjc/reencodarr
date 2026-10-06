{pkgs}: let
  version = "0.11.7-worker-75e65e5";
  src = pkgs.fetchFromGitHub {
    owner = "mjc";
    repo = "ab-av1-worker";
    rev = "75e65e54be6b3d03b8123275ce9a39ed5a2ac0e8";
    hash = "sha256-iG2jOexXa10RYB33bP4rbVnFBbXOrxeAvLspfQ/GEls=";
  };
  toolchain = pkgs.rust-bin.fromRustupToolchainFile "${src}/rust-toolchain.toml";
  rustPlatform = pkgs.makeRustPlatform {
    cargo = toolchain;
    rustc = toolchain;
  };
in
  rustPlatform.buildRustPackage {
    pname = "ab-av1";
    inherit version src;

    cargoHash = "sha256-AqHPpDJ2uvnZ+68ZNj9GQ6nOL16TVNUQ1o+d4GPFZsI=";

    nativeBuildInputs = [pkgs.pkg-config];
    buildInputs = [pkgs.openssl];
    # Upstream's test suite invokes ffmpeg/ffprobe, which are supplied by the
    # Reencodarr runtime closure rather than this package build sandbox.
    doCheck = false;

    meta.mainProgram = "ab-av1";
  }
