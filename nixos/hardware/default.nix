{ modulesPath, ... }:
{
  imports = [
    ./disko.nix
    ./disks.nix
    ./gpu.nix
    ./persistence.nix
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  hardware.enableRedistributableFirmware = true;

  # It's a headless server in a club room — silence the PC speaker bell
  # permanently. (Hardware alarms like the GPU power buzzer are NOT this
  # and can't be muted here; they mean something's actually wrong.)
  boot.blacklistedKernelModules = [
    "pcspkr"
    "snd_pcsp"
  ];
}
