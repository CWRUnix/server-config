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

    # Prebuilt nix-index database for comma / command-not-found (members
    # shouldn't have to build the index themselves).
    nix-index-database = {
      url = "github:nix-community/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # The club Discord bot (self-service /reset-password etc.), running in
    # its own container — see nixos/containers/discord-bot.nix.
    cwrunix-bot.url = "github:CWRUnix/cwrunix-bot";

    # Club branding assets (logos/posters, built by CI). The default package
    # is one derivation with all artifacts; we lift two files out of it for
    # the authentik login page (see nixos/branding.nix).
    marketing.url = "github:CWRUnix/marketing";
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
          modules = [ inputs.nix-index-database.nixosModules.nix-index ] ++ modules;
        };

      # The PXE/iPXE installer for zeus' hardware (no USB stick needed) —
      # see netboot/. Built per-host-system below as .#netboot-dir.
      netbootSystem = inputs.nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; };
        modules = [ ./netboot ];
      };
    in
    inputs.flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import inputs.nixpkgs { inherit system; };
      in
      {
        packages.proxy-image = self.nixosConfigurations.proxy.config.system.build.image;

        # TFTP root for the tethered netboot of zeus' hardware:
        #   nix build .#netboot-dir
        #   sudo nix run .#pxe-server -- <iface> ./result
        packages.netboot-dir = pkgs.symlinkJoin {
          name = "netboot-tftp-dir";
          paths = with netbootSystem.config.system.build; [
            kernel # bzImage
            netbootRamdisk # initrd (carries the whole closure)
            (netbootIpxeScript.overrideAttrs (_: {
              # Chainload via HTTP from the pxe-server's updog (:9999 on
              # 192.168.100.1 — the subnet netboot/pxe-server.nix sets up).
              text = ''
                #!ipxe
                kernel http://192.168.100.1:9999/bzImage init=${netbootSystem.config.system.build.toplevel}/init initrd=initrd ${toString netbootSystem.config.boot.kernelParams} ''${cmdline}
                initrd http://192.168.100.1:9999/initrd
                boot
              '';
            }))
            pkgs.ipxe # ipxe.efi (+ pxelinux.0 legacy fallback)
          ];
          postBuild = ''
            ln -s $out/netboot.ipxe $out/autoexec.ipxe
          '';
        };

        apps.pxe-server = {
          type = "app";
          program = "${pkgs.callPackage ./netboot/pxe-server.nix { }}/bin/zeus-pxe-server";
        };

        # Install .#server onto the netbooted hardware (disko format +
        # install + sops deploy key staged). Usage:
        #   nix run .#deploy -- <deploy-age-keyfile> [ssh opts] <host>
        apps.deploy = {
          type = "app";
          program = "${pkgs.callPackage ./deploy.nix { }}/bin/zeus-deploy";
        };

        devShells = {
          default = pkgs.mkShell {
            SOPS_AGE_KEY_FILE = "key.txt";
            packages = with pkgs; [
              nil
              nixd
              sops
              age
              gnupg
              opentofu
            ];
          };
        };

        # `nix run .#vm` from the repo root: boots a local QEMU VM of the
        # server for testing. The temporary sops age key (./key.txt) is
        # injected into the VM over a 9p share so sops secrets decrypt.
        apps.vm =
          let
            vmCfg = self.nixosConfigurations.vm.config;
            vm = vmCfg.system.build.vm;
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
                # ACME certs persist across test runs in ./.vm-acme
                mkdir -p ./.vm-acme
                export QEMU_OPTS="''${QEMU_OPTS:-} -virtfs local,path=$keydir,mount_tag=sopskey,security_model=none -virtfs local,path=$PWD/.vm-acme,mount_tag=acmedir,security_model=mapped-file"
                export NIX_DISK_IMAGE="''${NIX_DISK_IMAGE:-$PWD/zeus-vm.qcow2}"
                # the runner name follows the VM's hostname (run-<host>-vm)
                exec ${vm}/bin/run-${vmCfg.networking.hostName}-vm "$@"
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

        # The raw-TCP relay VPS (Linode). Builds a gzipped raw Linode
        # image via `nix build .#proxy-image`; see proxy/default.nix.
        proxy = mkSystem [ ./proxy ];
      };
    };
}
