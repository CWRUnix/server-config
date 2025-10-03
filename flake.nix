{
  description = "CWRUnix club server";

  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    proxmox-nixos.url = "github:SaumonNet/proxmox-nixos";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      proxmox-nixos,
      ...
    }@inputs:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        devShells = {
          default = pkgs.mkShell {
            packages = with pkgs; [
              nil
              nixd
            ];
          };
        };
        nixosConfigurations = rec {
          default = server;
          server = nixpkgs.lib.nixosSystem rec {
            system = "x86_64-linux";
            modules = [
              proxmox-nixos.nixosModules.proxmox-ve
              (
                { pkgs, lib, ... }:
                {
                  services.proxmox-ve = {
                    enable = true;
                    ipAddress = "192.168.0.1";
                  };

                  nixpkgs.overlays = [
                    proxmox-nixos.overlays.${system}
                  ];
                }
              )
            ];
          };
        };
        formatter =
          let
            treefmtconfig = inputs.treefmt-nix.lib.evalModule pkgs {
              projectRootFile = "flake.nix";
              programs = {
                nixfmt.enable = true;
                prettier.enable = true;
              };
            };
          in
          treefmtconfig.config.build.wrapper;
      }
    );
}
