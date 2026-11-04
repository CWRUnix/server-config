{ pkgs, ... }:
{
  imports = [
    ./boot.nix
    ./branding.nix
    ./cloudflare.nix
    ./localization.nix
    ./networking.nix
    ./nginx.nix
    ./nix.nix
    ./openssh.nix
    ./proxy-relay.nix
    ./sops.nix
    ./tailscale.nix
    ./ttyd.nix
    ./webtty.nix

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

  # zsh is the default shell for everyone (members' forced login-sandbox
  # shell is set separately in sandbox/ (cwrunix-sandbox) — sssd overrides
  # remote users' shells to it).
  programs.zsh.enable = true;
  users.defaultUserShell = pkgs.zsh;

  # comma (`, <cmd>` runs any nixpkgs program) for admins on the host,
  # with the prebuilt nix-index database; the module also provides
  # nix-index itself. Members get the same inside their sandbox (see
  # sandbox/default.nix).
  programs.nix-index-database.comma.enable = true;

  documentation = {
    enable = true;
    man = {
      enable = true;
      cache.enable = true;
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
    # `upg` — update zeus to the latest pushed config and switch into it
    # (admins; wheel sudo is passwordless here). Fetches straight from
    # GitHub (the repo is public); --refresh bypasses the fetch cache so
    # you always get origin/main.
    (writeShellScriptBin "upg" ''
      set -euo pipefail
      exec sudo nixos-rebuild switch --refresh --flake github:CWRUnix/server-config#server "$@"
    '')
  ];
}
