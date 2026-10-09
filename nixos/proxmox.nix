{ pkgs, inputs, ... }:
{
  # NOTE: this module is intentionally NOT imported (see nixos/default.nix).
  # Proxmox/hypervisor support is deferred; when it is picked up again,
  # remember to import this file and re-check the IP address.
  services.proxmox-ve = {
    enable = true;
    ipAddress = "192.168.0.1";
  };

  nixpkgs.overlays = [
    inputs.proxmox-nixos.overlays.${pkgs.stdenv.hostPlatform.system}
  ];
}
