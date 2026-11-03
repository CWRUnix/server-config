{ config, pkgs, ... }:
let
  # Key the host's tailscaled registers with. Self-provisioned on first boot
  # by headscale-bootstrap-key.service (below) via the headscale CLI inside
  # the container, then persisted — headscale 0.29 stores keys as
  # prefix+bcrypt-hash only, so a sops-pinned value cannot be inserted into
  # a fresh DB through any supported interface; generating here is the
  # simple path that always matches the DB.
  authKeyFile = "/var/lib/headscale-bootstrap/preauth-key";
in
{
  # The host joins its own headscale tailnet (headscale runs in a local
  # nixos-container, reached through the cloudflare tunnel). Members SSH to
  # zeus over the tailnet from anywhere.
  #
  # NOTE: do NOT use authKeyParameters.baseURL to select the login server —
  # the module appends it as a query string on the auth key
  # (`--auth-key "<key>?baseURL=..."`) and tailscale 1.86 ignores it, so the
  # node silently registers against controlplane.tailscale.com and fails with
  # "invalid key: unable to validate API key". --login-server works.
  #
  # Deliberately NO Tailscale SSH (--ssh): tailnet identity would replace OS
  # auth entirely. Members use ttyd (nixos/ttyd.nix, nixos/webtty.nix) or
  # plain sshd with their LDAP password; admins use sshd over the tailnet
  # (tailscale0 is a trusted interface) or the campus LAN. The ssh section
  # in the headscale policy (containers/headscale.nix) is inert without any
  # node advertising SSH.
  services.tailscale = {
    enable = true;
    openFirewall = true;
    authKeyFile = authKeyFile;
    extraUpFlags = [
      "--login-server"
      "https://headscale-zeus.cwrunix.com"
    ];
  };

  # Provision the tailnet's "admin" user (node owner) and a reusable preauth
  # key for this host's tailscaled, on first boot only. Runs on the HOST
  # (not inside the container) so the same keyfile path works on the server
  # (/persist-backed) and the VM; nixos-container runs the CLI against the
  # container's headscale. Idempotent: skips if the keyfile exists. A key
  # that later expires only affects FRESH registrations (logged-in nodes
  # keep working); delete the keyfile and restart this unit to rotate.
  systemd.services.headscale-bootstrap-key = {
    description = "Provision headscale admin user + preauth key for local tailscaled";
    wantedBy = [ "multi-user.target" ];
    requires = [ "container@headscale.service" ];
    after = [ "container@headscale.service" ];
    path = with pkgs; [ jq ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      UMask = "0077";
      # headscale can take a moment inside the container at first boot.
      TimeoutStartSec = "5min";
    };
    script = ''
      set -euo pipefail
      keyfile=${authKeyFile}
      if [ -s "$keyfile" ]; then
        exit 0
      fi
      mkdir -p "$(dirname "$keyfile")"

      hs() { ${pkgs.nixos-container}/bin/nixos-container run headscale -- headscale "$@"; }

      # wait for headscale inside the container to answer
      for i in $(seq 1 60); do
        if hs users list -o json >/dev/null 2>&1; then
          break
        fi
        sleep 5
      done

      uid=$(hs users list -o json | jq -r '[.[]? | select(.name=="admin")] | .[0].id // empty')
      if [ -z "$uid" ]; then
        hs users create admin --email admin@cwrunix.com >/dev/null
        uid=$(hs users list -o json | jq -r '[.[]? | select(.name=="admin")] | .[0].id // empty')
      fi

      hs preauthkeys create --user "$uid" --reusable --expiration 8760h -o json \
        | jq -r '.key' > "$keyfile.tmp"
      mv "$keyfile.tmp" "$keyfile"
    '';
  };

  systemd.services.tailscaled-autoconnect = {
    # needs the keyfile above; also tolerates a late network (the campus LAN
    # can take minutes to pass traffic after link-up — seen as a boot-time
    # hang + timeout on the real hardware).
    requires = [ "headscale-bootstrap-key.service" ];
    after = [ "headscale-bootstrap-key.service" ];
    serviceConfig = {
      Restart = "on-failure";
      RestartSec = "60s";
    };

    # extraUpFlags only apply at first `tailscale up`; prefs persist in
    # /var/lib/tailscale. This flips off the (previously enabled) Tailscale
    # SSH pref on already-registered nodes — idempotent, and a harmless
    # no-op on fresh ones (default is off without --ssh).
    postStart =
      "${config.services.tailscale.package}/bin/tailscale set --ssh=false || true";
  };
}
