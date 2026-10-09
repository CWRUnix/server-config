{
  description = "CWRUnix club server (zeus.cwrunix.com)";

  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    # Hypervisor support is intentionally kept as an input but NOT imported
    # anywhere yet; see nixos/proxmox.nix.
    proxmox-nixos.url = "github:SaumonNet/proxmox-nixos";

    # authentik (IdP) + LDAP outpost, packaged for NixOS.
    # NOTE: do NOT make its nixpkgs follow ours; it is version-sensitive.
    authentik-nix.url = "github:nix-community/authentik-nix";

    disko = {
      url = "github:nix-community/disko/latest";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    impermanence = {
      url = "github:nix-community/impermanence";
    };
  };

  outputs =
    {
      self,
      ...
    }@inputs:
    let
      mkSystem =
        modules:
        inputs.nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = { inherit inputs; };
          inherit modules;
        };
    in
    inputs.flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import inputs.nixpkgs { inherit system; };
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
              gnupg
            ];
          };
        };

        # `nix run .#vm` from the repo root: boots a local QEMU VM of the
        # server for testing. The temporary sops age key (./key.txt) is
        # injected into the VM over a 9p share so sops secrets decrypt.
        apps.vm =
          let
            vm = self.nixosConfigurations.vm.config.system.build.vm;
          in
          {
            type = "app";
            program = toString (
              pkgs.writeShellScript "run-zeus-vm" ''
                set -euo pipefail
                if [ ! -f ./key.txt ]; then
                  echo "error: run from the repo root; ./key.txt (temporary sops age key) is needed in the VM" >&2
                  exit 1
                fi
                keydir=$(mktemp -d)
                trap 'rm -rf "$keydir"' EXIT
                install -m600 ./key.txt "$keydir/key.txt"
                export QEMU_OPTS="''${QEMU_OPTS:-} -virtfs local,path=$keydir,mount_tag=sopskey,security_model=none"
                export NIX_DISK_IMAGE="''${NIX_DISK_IMAGE:-$PWD/zeus-vm.qcow2}"
                exec ${vm}/bin/run-nixos-vm "$@"
              ''
            );
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
    )
    // {
      nixosConfigurations = {
        default = self.nixosConfigurations.server;

        # The real server.
        server = mkSystem [
          inputs.disko.nixosModules.disko
          inputs.sops-nix.nixosModules.sops
          inputs.impermanence.nixosModules.impermanence
          ./nixos
        ];

        # Local QEMU test VM: `nix run .#vm`
        # (or: nixos-rebuild build-vm --flake .#vm)
        vm = mkSystem [
          # disko is only imported so the `disko.*` options exist; vm.nix
          # sets disko.enableConfig = false (single throwaway disk).
          inputs.disko.nixosModules.disko
          inputs.sops-nix.nixosModules.sops
          inputs.impermanence.nixosModules.impermanence
          ./nixos
          ./vm.nix
        ];
      };
    };
}
