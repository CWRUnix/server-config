{ config, pkgs, ... }:
# Browser shell for members WITHOUT a tailscale client: a second ttyd
# instance behind oauth2-proxy (authentik SSO), exposed publicly through
# the Cloudflare tunnel as ttyd-zeus.cwrunix.com.
#
# Security model: authentik SSO proves club membership; after that the
# member STILL authenticates to login(1) with their LDAP password — the
# tunnel path carries no tailnet identity, so OS auth still applies.
# (This is exactly why it is safe to expose, and why Tailscale SSH —
# where tailnet identity replaces OS auth — stays admin-only.)
#
# The tailnet-only ttyd is untouched (nixos/ttyd.nix).
#
# ttyd's WebSocket is a GET upgrade, which the tunnel passes fine (only
# POST+Upgrade is stripped — the headscale TS2021 problem).
{
  services.oauth2-proxy = {
    enable = true;
    provider = "oidc";
    oidcIssuerUrl = "https://authentik-zeus.cwrunix.com/application/o/webtty/";
    clientID = "webtty";
    clientSecretFile = config.sops.secrets."webtty/client_secret".path;
    email.domains = [ "*" ]; # any active authentik account (all are approved members)
    reverseProxy = true; # trust nginx's X-Forwarded-* (https scheme for cookies)
    # ...but only from nginx on this host — without this, reverseProxy
    # trusts X-Forwarded-* from ANY source IP (oauth2-proxy's default is
    # 0.0.0.0/0 + a startup warning).
    trustedProxyIP = [
      "127.0.0.1/32"
      "::1/128"
    ];
    httpAddress = "127.0.0.1:4180";
    upstream = "http://127.0.0.1:7682"; # only hit directly on :4180; nginx auth_requests it
    cookie = {
      secretFile = config.sops.secrets."webtty/cookie_secret".path;
      secure = true;
    };
    nginx = {
      domain = "ttyd-zeus.cwrunix.com";
      # New-style attrset form (list form is deprecated); empty set = no
      # per-vhost group/email restrictions.
      virtualHosts."ttyd-zeus.cwrunix.com" = { };
      # The integration's default (oauth2-proxy's bare "127.0.0.1:4180"
      # httpAddress) renders an invalid schemeless proxy_pass; be explicit.
      proxy = "http://127.0.0.1:4180";
    };
    extraConfig = {
      # authentik has no SMTP, so local accounts never carry a verified
      # email claim (and Discord-sourced emails are verified by Discord).
      # Either way the shell behind this still does its own PAM auth; the
      # claim is only used for display headers.
      insecure-oidc-allow-unverified-email = true;
      # Allow the post-login redirect back to our own host (the rd=
      # round-trip); without it oauth2-proxy logs "not in whitelist" and
      # drops users on / instead of where they were going.
      whitelist-domain = "ttyd-zeus.cwrunix.com";
    };
  };

  # Discovery at startup needs nginx (local name resolves to 127.0.0.1)
  # AND the in-container tofu bootstrap to have created the webtty
  # provider — on first boot that's minutes away, so retry patiently
  # instead of hitting the start limit.
  systemd.services.oauth2-proxy = {
    after = [ "nginx.service" ];
    wants = [ "nginx.service" ];
    unitConfig.StartLimitIntervalSec = 0;
    serviceConfig.RestartSec = "15s";
  };

  # Second ttyd instance on localhost for the tunnel path (the tailnet one
  # binds tailscale0). login(1) needs root for PAM + setuid, same as the
  # main ttyd service.
  systemd.services.ttyd-public = {
    description = "ttyd (tunnel-facing, behind oauth2-proxy)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.ttyd}/bin/ttyd --interface 127.0.0.1 --port 7682 --writable ${pkgs.shadow}/bin/login";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };
}
