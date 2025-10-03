{
  description = "CWRUnix club server";

  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    proxmox-nixos.url = "github:SaumonNet/proxmox-nixos";

    disko.url = "github:nix-community/disko/latest";
    disko.inputs.nixpkgs.follows = "nixpkgs";

    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";

    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      disko,
      sops-nix,
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
            SOPS_AGE_KEY_FILE = "key.txt";
            packages = with pkgs; [
              nil
              nixd
              sops
              age
            ];
          };
        };
        nixosConfigurations = rec {
          default = server;
          server = nixpkgs.lib.nixosSystem {
            specialArgs = { inherit inputs; };
            system = "x86_64-linux";
            modules = [
              disko.nixosModules.disko
              sops-nix.nixosModules.sops
              ./nixos
              proxmox-nixos.nixosModules.proxmox-ve
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
