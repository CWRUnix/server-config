{
  pkgs,
  lib,
  config,
  modulesPath,
  ...
}:
# Netboot (PXE/iPXE) installer system for zeus' hardware — we have no USB
# stick on hand, so the desktop network-boots this off a tethered laptop
# instead (see netboot/pxe-server.nix and the flake's netboot-dir package
# / pxe-server app).
#
# Flow:
#   1. laptop:  nix build .#netboot-dir
#               sudo nix run .#pxe-server -- <iface> ./result
#   2. desktop: choose UEFI PXE/network boot in the firmware menu
#   3. laptop:  ssh tev@192.168.100.x works; then run the install from the
#               laptop (nixos-anywhere --flake .#server ...).
#
# The image is a self-contained minimal NixOS (initrd carries the whole
# closure): sshd with the admin keys, nix with flakes, disko tools.
{
  imports = [
    (modulesPath + "/installer/netboot/netboot.nix")
    (modulesPath + "/profiles/minimal.nix")
    # The club admin account + SSH keys, single source of truth.
    ../nixos/admins
  ];

  networking.hostName = "zeus-netboot";

  # nixos-anywhere logs in over SSH (key-only). root gets the admin keys;
  # wheel sudo is passwordless for the install session.
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
    };
  };
  users.users.root.openssh.authorizedKeys.keys = config.users.users.tev.openssh.authorizedKeys.keys;
  security.sudo.wheelNeedsPassword = false;

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # The minimal profile trims firmware; the installer still wants it
  # (amdgpu init for the GPUs, rtl8125b for the onboard NIC).
  hardware.enableRedistributableFirmware = true;

  environment.systemPackages = with pkgs; [
    git
    btop
    disko
  ];

  # The admins bundle sets defaultUserShell=zsh. On the INSTALLER root must
  # stay bash: nixos-anywhere uploads the closure via a store URI with a
  # glob char in it (local?root=/mnt), and zsh hard-errors on unmatched
  # globs ("no matches found") where bash passes them through — the upload
  # dies instantly. (Real server keeps zsh per policy; nothing there drives
  # nixos-anywhere-style root ssh automation.)
  users.defaultUserShell = lib.mkForce pkgs.bashInteractive;

  # The image is throwaway; silence minimal.nix's harmless warnings.
  system.stateVersion = "25.11";

  # nixos-anywhere's get-facts decides "already an installer, skip kexec"
  # purely from VARIANT_ID=installer in os-release — and the bare netboot
  # module doesn't set it (iso-image does via installation-device.nix).
  # Without this it tries to download a kexec tarball on the target, which
  # is offline by construction (tethered install).
  system.nixos.variant_id = "installer";
}
