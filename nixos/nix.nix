{ pkgs, ... }:
{
  nix = {
    package = pkgs.nix;
    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      builders-use-substitutes = true;
      trusted-substituters = [ "https://cache.nixos.org/" ];
      auto-optimise-store = true;
      # Remote users get nix via the bind-mounted daemon socket, but stay
      # untrusted: no custom substituters, and all their builds run in the
      # nix build sandbox.
      sandbox = true;
      trusted-users = [ "@wheel" ];
    };
    gc = {
      automatic = true;
      dates = "weekly";
      # NOTE: users' home-manager generations live under
      # /nix/var/nix/profiles/per-user and are gcrooted, but old generations
      # are collected after this age. Keep it generous for rollbacks.
      options = "--delete-older-than 30d";
    };
  };
}
