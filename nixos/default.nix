{ pkgs, ... }:
{
  imports = [
    ./boot.nix
    ./cloudflare.nix
    ./localization.nix
    ./networking.nix
    ./nginx.nix
    ./nix.nix
    ./openssh.nix
    ./sops.nix
    ./tailscale.nix

    ./admins
    ./auth
    ./containers
    ./hardware
    ./sandbox
  ];

  # proxmox.nix (hypervisor role) is deliberately NOT imported yet; it is
  # kept in the tree for later. Large system services run as declarative
  # nixos-containers (see containers/).

  system.stateVersion = "25.11";

  documentation = {
    enable = true;
    man = {
      enable = true;
      generateCaches = true;
    };
  };

  environment.systemPackages = with pkgs; [
    nano
    neovim
    git
    curl
    jq
    htop
    man-pages
    man-pages-posix
  ];
}
