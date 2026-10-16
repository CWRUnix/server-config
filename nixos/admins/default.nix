{ pkgs, ... }:
{
  imports = [
    ./tev.nix
  ];

  users = {
    mutableUsers = false;
    defaultUserShell = pkgs.zsh;
  };

  programs.zsh.enable = true;

  # Local admins only (remote LDAP users are never in wheel).
  security.sudo.wheelNeedsPassword = false;
}
