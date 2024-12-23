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
  }:
    flake-utils.lib.eachDefaultSystem (
      system: let
        pkgs = import nixpkgs {inherit system;};
        erlang = pkgs.erlang.override (old: {
          version = "27.2";
          src = pkgs.fetchurl {
            url = "https://github.com/erlang/otp/releases/download/OTP-27.2/otp_src_27.2.tar.gz";
            sha256 = "sha256-tmwsxPoshyEbZo5EhtTz5bG2cFaYhz6j5tmFCAGsmS0=";
          };
        });
        beamPackages = pkgs.beam.packagesWith erlang;
        elixir = beamPackages.elixir.override {
          erlang = erlang;
          version = "1.18.0";
          src = pkgs.fetchurl {
            url = "https://github.com/elixir-lang/elixir/archive/v1.18.0.tar.gz";
            sha256 = "sha256-8pEErloOp4eGtfuW3ODFaduR31vR00crNl3C6hTqeE8=";
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
            ++ pkgs.lib.optional pkgs.stdenv.isLinux pkgs.libnotify # For ExUnit Notifier on Linux.
            ++ pkgs.lib.optional pkgs.stdenv.isLinux pkgs.inotify-tools # For file_system on Linux.
            ++ pkgs.lib.optional pkgs.stdenv.isDarwin pkgs.terminal-notifier # For ExUnit Notifier on macOS.
            ++ pkgs.lib.optionals pkgs.stdenv.isDarwin (with pkgs.darwin.apple_sdk.frameworks; [
              CoreFoundation
              CoreServices
            ]);

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
