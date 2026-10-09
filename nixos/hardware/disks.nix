{ ... }:
{
  # Ephemeral root — see persistence.nix for what survives a reboot.
  fileSystems."/" = {
    device = "none";
    fsType = "tmpfs";
    options = [
      "defaults"
      "size=64G"
      "mode=755"
    ];
  };
}
