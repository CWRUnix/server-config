{
  writeShellApplication,
  coreutils,
  dnsmasq,
  iproute2,
  updog,
  ...
}:
# Tethered DHCP/PXE server for netbooting zeus' hardware without a USB
# stick. Adapted from the open-ortho nixos-configs dhcp-tether.nix.
#
# Usage:
#   nix build .#netboot-dir
#   sudo nix run .#pxe-server -- <iface> ./result
# (if NetworkManager manages the tether NIC: nmcli device set <iface> managed no)
#
# Serves DHCP + TFTP (iPXE chainload) on 192.168.100.1, and the heavy
# kernel/initrd over HTTP on :9999 (matching the iPXE script baked into
# the netboot-dir package).

writeShellApplication {
  name = "zeus-pxe-server";

  runtimeInputs = [
    coreutils
    dnsmasq
    iproute2
    updog
  ];

  text = ''
    if [ "$#" -ne 2 ]; then
      echo "Error: Missing arguments."
      echo "Usage: sudo zeus-pxe-server <interface_name> <netboot_tftp_dir>"
      echo "Example: sudo zeus-pxe-server enp8s0f4u1 \$(nix build .#netboot-dir --no-link --print-out-paths)"
      echo "With NetworkManager, unmanage the tether NIC first:"
      echo "  nmcli device set <iface> managed no"
      exit 1
    fi

    INTERFACE="$1"
    TFTP_DIR="$(realpath "$2")"

    if [ "$(id -u)" -ne 0 ]; then
      echo "Error: Modifying network layers and binding low ports requires root. Please run via sudo."
      exit 1
    fi

    if [ ! -d "$TFTP_DIR" ]; then
      echo "Error: Targeted TFTP directory does not exist at $TFTP_DIR"
      exit 1
    fi

    if ! ip link show "$INTERFACE" > /dev/null 2>&1; then
      echo "Error: Network interface '$INTERFACE' was not found on this system."
      exit 1
    fi

    echo "Configuring network interface: $INTERFACE..."
    ip link set "$INTERFACE" down
    ip addr flush dev "$INTERFACE" scope global || true
    ip addr add 192.168.100.1/24 dev "$INTERFACE"
    ip link set "$INTERFACE" up

    RUN_DIR=$(mktemp -d -t zeus-pxe-XXXXXX)
    CONF_FILE="$RUN_DIR/dnsmasq.conf"
    LEASE_FILE="$RUN_DIR/dnsmasq.leases"

    cleanup() {
      echo ""
      echo "Shutting down DHCP/PXE server..."
      rm -rf "$RUN_DIR"
      ip link set "$INTERFACE" down 2>/dev/null || true
      ip addr del 192.168.100.1/24 dev "$INTERFACE" 2>/dev/null || true
      echo "Done. Host network environment restored."
    }
    trap cleanup EXIT

    cat << EOF > "$CONF_FILE"
    keep-in-foreground
    log-dhcp
    interface=$INTERFACE
    dhcp-range=192.168.100.10,192.168.100.20,1h
    dhcp-option=option:router,192.168.100.1
    dhcp-leasefile=$LEASE_FILE

    # Built-in TFTP server
    enable-tftp
    tftp-root=$TFTP_DIR

    # PXE bootloader selection
    dhcp-match=set:bios,option:client-arch,0
    dhcp-match=set:efi64,option:client-arch,7
    dhcp-match=set:efi64,option:client-arch,9

    # iPXE itself asking -> hand it the NixOS boot script
    dhcp-match=set:ipxe,175

    dhcp-boot=tag:ipxe,netboot.ipxe
    dhcp-boot=tag:efi64,ipxe.efi
    dhcp-boot=tag:bios,undionly.kpxe.0
    EOF

    echo "--------------------------------------------------------"
    echo " DHCP & PXE Server Active on $INTERFACE (192.168.100.1)"
    echo " Serving TFTP Root from: $TFTP_DIR"
    echo " Press [Ctrl + C] to terminate and revert changes"
    echo "--------------------------------------------------------"

    updog -d "$TFTP_DIR" -p 9999 &
    dnsmasq -C "$CONF_FILE"
  '';
}
