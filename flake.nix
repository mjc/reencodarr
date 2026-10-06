{
  description = "Reencodarr: Phoenix app packaging and NixOS module";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    rust-overlay,
    ...
  }:
    flake-utils.lib.eachDefaultSystem (
      system: let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [rust-overlay.overlays.default];
        };
      in {
        packages = rec {
          reencodarr = pkgs.callPackage ./nix/package.nix {};
          default = reencodarr;

          dockerImage = pkgs.dockerTools.buildLayeredImage {
            name = "reencodarr";
            tag = "latest";

            contents = [reencodarr];

            config = {
              Cmd = ["${reencodarr}/bin/reencodarr" "start"];
              WorkingDir = "/var/lib/reencodarr";
              Env = [
                "PHX_SERVER=true"
                "PORT=4000"
              ];
              ExposedPorts = {
                "4000/tcp" = {};
              };
            };
          };
        };

        checks = {
          inherit (self.packages.${system}) reencodarr;
        };
      }
    )
    // {
      nixosModules = {
        default = import ./nix/module.nix {inherit self;};
        reencodarr = import ./nix/module.nix {inherit self;};
      };
    };
}
