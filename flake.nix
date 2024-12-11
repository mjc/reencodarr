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
          version = "27.1.3";
          src = pkgs.fetchurl {
            url = "https://github.com/erlang/otp/releases/download/OTP-27.1.3/otp_src_27.1.3.tar.gz";
            sha256 = "sha256-Gx6x7ZGWJcrtPdVulxgpVmE7PWUFVrobiy1sm8DFHCg=";
          };
        });
        beamPackages = pkgs.beam.packagesWith erlang;
        elixir = beamPackages.elixir.override {
          erlang = erlang;
          version = "1.18.0-rc.0";
          src = pkgs.fetchurl {
            url = "https://github.com/elixir-lang/elixir/archive/v1.18.0-rc.0.tar.gz";
            sha256 = "sha256-6/RKNDF+2axaDsVLRuO+QfXaryLauTNquHOTgZpHZYQ=";
          };
        };
      in {
        devShell = pkgs.mkShell {
          nativeBuildInputs = [
            erlang
            elixir
            beamPackages.elixir

            pkgs.git
            pkgs.gh
            pkgs.nodePackages.cspell

            pkgs.alejandra
            pkgs.nil

            pkgs.inotify-tools
          ];

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
