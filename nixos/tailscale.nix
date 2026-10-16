{ config, ... }:
{
  # The host joins its own headscale tailnet (headscale runs in a local
  # nixos-container, reached through the cloudflare tunnel). Members SSH to
  # zeus over the tailnet from anywhere.
  #
  # Bootstrap: after headscale is up, create a user + preauth key inside the
  # container (`sudo nixos-container run headscale -- headscale users create
  # admin` / `headscale preauthkeys create ...`) and store sops as
  # "headscale/preauth_key".
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
    authKeyFile = config.sops.secrets."headscale/preauth_key".path;
    extraUpFlags = [
      "--login-server"
      "https://headscale-zeus.cwrunix.com"
    ];
  };

  # extraUpFlags only apply at first `tailscale up`; prefs persist in
  # /var/lib/tailscale. This flips off the (previously enabled) Tailscale
  # SSH pref on already-registered nodes — idempotent, and a harmless no-op
  # on fresh ones (default is off without --ssh).
  systemd.services.tailscaled-autoconnect.postStart =
    "${config.services.tailscale.package}/bin/tailscale set --ssh=false || true";
}
