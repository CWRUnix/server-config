{ modulesPath, ... }:
{
  imports = [
    ./disko.nix
    ./disks.nix
    ./persistence.nix
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  hardware.enableRedistributableFirmware = true;
}
