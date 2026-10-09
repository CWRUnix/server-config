{ ... }:
{
  # !!! Fill in the real disk IDs before installation (`ls -l /dev/disk/by-id/`).
  #
  # Layout: ephemeral tmpfs root (see disks.nix); the main disk holds the
  # nix store and /persist (impermanence), the large disk holds /home for
  # remote users.
  disko.devices.disk = {
    main = {
      device = "/dev/disk/by-id/CHANGE-ME-MAIN";
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
      device = "/dev/disk/by-id/CHANGE-ME-LARGE";
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
