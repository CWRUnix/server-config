{ ... }:
{
  # Browser-based shell for members: ttyd serves login(1) over the tailnet,
  # so members authenticate with their actual LDAP (authentik) password —
  # real PAM auth, landing in their sandboxed account. (headplane's browser
  # SSH can't do password auth — its WASM client is Tailscale-SSH "none"
  # auth only — and Tailscale SSH is admin-scoped in the headscale policy,
  # since tailnet identity otherwise replaces OS auth entirely.)
  #
  # Members open http://zeus.ts.zeus.cwrunix.com:7681 (tailnet-only; the
  # listener binds the tailscale0 device and is never on a physical
  # interface). Traffic is WireGuard-encrypted, so the password prompt is
  # not exposed in cleartext.
  services.ttyd = {
    enable = true;
    interface = "tailscale0";
    port = 7681;
    writeable = true;
    # entrypoint defaults to login(1) — keep it.
  };

  # tailscale0 only exists once tailscaled is up; don't let ttyd race it.
  systemd.services.ttyd = {
    after = [ "tailscaled-autoconnect.service" ];
    wants = [ "tailscaled-autoconnect.service" ];
    serviceConfig.Restart = "on-failure";
  };
}
