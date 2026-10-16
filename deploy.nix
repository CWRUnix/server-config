{
  writeShellApplication,
  coreutils,
  nixos-anywhere,
  openssh,
  gitMinimal,
  ...
}:
# One-shot installer for zeus' hardware: nixos-anywhere (disko format +
# install) with the sops age deploy key staged via --extra-files, so the
# first real boot decrypts secrets cleanly (sops-nix reads
# /persist/sops-nix/key.txt very early; landing it during install avoids
# a broken first boot + rescue reboot).
#
# Usage:
#   nix run .#deploy -- <path-to-deploy-age-key> [ssh/nixos-anywhere opts] <host>
# Example (tethered netboot installer):
#   nix run .#deploy -- ~/keys/zeus-deploy.key root@192.168.100.10
#
# The key must be the private half of the "deploy" recipient in .sops.yaml.
# Run from the repo root (the flake ref is ".#server").
#
# WARNING: disko REFORMATS the target's disks (see nixos/hardware/disko.nix).

writeShellApplication {
  name = "zeus-deploy";

  runtimeInputs = [
    coreutils
    nixos-anywhere
    openssh
    gitMinimal # nix builds the dirty working-tree flake via git
  ];

  text = ''
    if [ "$#" -lt 2 ]; then
      echo "Usage: nix run .#deploy -- <sops-age-keyfile> [ssh/nixos-anywhere opts] <host>"
      echo "Example: nix run .#deploy -- ~/keys/zeus-deploy.key root@192.168.100.10"
      exit 1
    fi

    KEYFILE="$1"
    shift

    if [ ! -s "$KEYFILE" ]; then
      echo "Error: sops age keyfile '$KEYFILE' does not exist or is empty."
      exit 1
    fi
    if ! grep -q '^AGE-SECRET-KEY-' "$KEYFILE"; then
      echo "Warning: '$KEYFILE' does not look like an age secret key (no AGE-SECRET-KEY- line)." >&2
      echo "Continuing anyway in 3s — Ctrl-C to abort." >&2
      sleep 3
    fi

    RUN_DIR=$(mktemp -d -t zeus-deploy-XXXXXX)
    cleanup() {
      rm -rf "$RUN_DIR"
    }
    trap cleanup EXIT

    # Staged into the installed system by nixos-anywhere --extra-files.
    mkdir -p "$RUN_DIR/persist/sops-nix"
    install -m600 "$KEYFILE" "$RUN_DIR/persist/sops-nix/key.txt"

    echo "------------------------------------------------------------"
    echo " Deploying .#server to: $*"
    echo " disko will REFORMAT the target's disks. Ctrl-C to abort."
    echo "------------------------------------------------------------"
    sleep 3

    # --phases: explicitly skip kexec
    # --no-use-machine-substituters: by default nixos-anywhere copies the
    # server config's substituters (cache.nixos.org) into the INSTALLER's
    # nix, which then pings the cache on the offline target — 25s of
    # timeouts per invocation.
    nixos-anywhere \
      --phases disko,install,reboot \
      --no-use-machine-substituters \
      --flake .#server --extra-files "$RUN_DIR" "$@"
  '';
}
