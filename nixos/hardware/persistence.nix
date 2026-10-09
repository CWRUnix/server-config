{ lib, config, ... }:
{
  # Everything below survives the tmpfs root. User homes live on the
  # separate @home subvolume (see disko.nix) and need no persistence entries.
  environment.persistence."/persist" = {
    hideMounts = true;
    directories = [
      "/var/lib/nixos" # uid/gid allocation state
      "/var/lib/sss" # sssd cache (LDAP logins keep working over blips)
      "/var/lib/nixos-containers" # authentik (postgres!) + headscale state
      "/var/lib/tailscale"
      "/var/lib/systemd" # timers, random seed, ...
      "/var/log/journal"
      "/root"
    ];
    files = [
      "/etc/machine-id"
      "/etc/ssh/ssh_host_ed25519_key"
      "/etc/ssh/ssh_host_ed25519_key.pub"
      "/etc/ssh/ssh_host_rsa_key"
      "/etc/ssh/ssh_host_rsa_key.pub"
    ];
  };

  # The impermanence module asserts that the persistent filesystem is
  # mounted in initrd. (Gated on disko so the throwaway test VM, which has
  # no /persist, can disable both together.)
  fileSystems."/persist".neededForBoot = lib.mkIf (config.disko.enableConfig or false) true;
}
