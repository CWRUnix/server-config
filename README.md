# CWRUnix's official Server Configuration Files

## To Install:

With netboot:

1. Tether your device to the server via Ethernet
2. `nix build .#netboot-dir`
3. `sudo nix run .#pxe-server -- <Ethernet Interface> ./result`

- Alternatively, just run `sudo nix run .#pxe-server -- <Ethernet Interface> $(nix build .#netboot-dir --print-out-paths)`

4. Turn on the server and boot from (i)PXE
5. Wait for the boot to complete and show the login screen
6. `nix run .#deploy -- <Path to SOPS key> root@<IP assigned to server from pxe-server>`
7. Wait
