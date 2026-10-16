{ ... }:
{
  # Disk IDs from `ls -l /dev/disk/by-id/` on the machine (netboot installer).
  #
  # Layout: ephemeral tmpfs root (see disks.nix); the main disk holds the
  # nix store and /persist (impermanence), the large disk holds /home for
  # remote users.
  disko.devices.disk = {
    main = {
      device = "/dev/disk/by-id/nvme-CT500P3PSSD8_25154F625340";
      type = "disk";
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            type = "EF00";
            size = "500M";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              mountOptions = [ "umask=0077" ];
            };
          };
          swap = {
            size = "128G";
            content = {
              type = "swap";
            };
          };
          root = {
            size = "100%";
            content = {
              type = "btrfs";
              subvolumes = {
                "@nix" = {
                  mountpoint = "/nix";
                  mountOptions = [
                    "compress=zstd"
                    "noatime"
                  ];
                };
                "@persist" = {
                  mountpoint = "/persist";
                  mountOptions = [
                    "compress=zstd"
                    "noatime"
                  ];
                };
              };
            };
          };
        };
      };
    };

    large = {
      device = "/dev/disk/by-id/ata-ST20000NM007D-3DJ103_ZVT4D32C";
      type = "disk";
      content = {
        type = "gpt";
        partitions = {
          home = {
            size = "100%";
            content = {
              type = "btrfs";
              subvolumes = {
                "@home" = {
                  mountpoint = "/home";
                  mountOptions = [
                    "compress=zstd"
                    "noatime"
                  ];
                };
              };
            };
          };
        };
      };
    };
  };
}
