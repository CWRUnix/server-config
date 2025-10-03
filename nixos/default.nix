{ pkgs, ... }:
{
  imports = [
    ./disco.nix
    ./proxmox.nix
  ];

  documentation = {
    enable = true;
    man = {
      enable = true;
      generateCaches = true;
    };
    dev.enable = true;
  };

  environment.systemPackages = [
    pkgs.man-pages
    pkgs.man-pages-posix
  ];
}
