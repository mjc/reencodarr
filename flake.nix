{
  description = "Development environment for reencodarr";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs = {
    self,
    nixpkgs,
    flake-utils,
    ...
  }:
    flake-utils.lib.eachDefaultSystem (
      system: let
        pkgs = import nixpkgs {inherit system;};
        lib = pkgs.lib;
        erlang = pkgs.erlang.override {
          version = "27.3.1";
          src = pkgs.fetchurl {
            url = "https://github.com/erlang/otp/releases/download/OTP-${erlang.version}/otp_src_${erlang.version}.tar.gz";
            sha256 = "sha256-bTDwrGmlZa3xMX9bpsjVPpyRY63sSuXLpJWE5Z+iDag=";
          };
        };
        beamPackages = pkgs.beam.packagesWith erlang;
        elixir = beamPackages.elixir.override {
          erlang = erlang;
          version = "1.18.3";
          src = pkgs.fetchurl {
            url = "https://github.com/elixir-lang/elixir/archive/refs/tags/v${elixir.version}.tar.gz";
            sha256 = "sha256-+NQ3YxEFjdmnjtNl+h35/Rsi0kaMWH4/D0+zICg6Htc=";
          };
        };
      in {
        devShell = pkgs.mkShell {
          nativeBuildInputs =
            [
              erlang
              elixir
              beamPackages.ex_doc
              beamPackages.hex
              beamPackages.rebar
              beamPackages.rebar3
              beamPackages.rebar3-nix
              pkgs.tailwindcss
              pkgs.git
              pkgs.gh
              pkgs.nodePackages.cspell
              pkgs.alejandra
              pkgs.nil
            ]
            ++ lib.optional pkgs.stdenv.isLinux pkgs.libnotify
            ++ lib.optional pkgs.stdenv.isLinux pkgs.inotify-tools
            ++ lib.optional pkgs.stdenv.isDarwin pkgs.terminal-notifier
            ++ lib.optionals pkgs.stdenv.isDarwin (with pkgs.darwin.apple_sdk.frameworks; [CoreFoundation CoreServices]);
          shellHook = ''
            gh auth switch --user mjc
            export ERL_AFLAGS="-kernel shell_history enabled"
            export DATABASE_URL="ecto://mjc@localhost:5432/reencodarr_dev"
            export SECRET_KEY_BASE="WEWsPGIpK/OgJA2ZcwzsgZxWKSAp35IsqWPYsvSUmm5awBUGpvsVOcG2kkDteXR1"
          '';
        };
      }
    );
}
