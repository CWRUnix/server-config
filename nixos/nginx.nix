{ config, lib, ... }:
let
  tls = config.cwrunix.wildcardTls;
in
{
  options.cwrunix.wildcardTls =
    (lib.mkEnableOption ''
      wildcard TLS for *.zeus.cwrunix.com via Let's Encrypt (ACME DNS-01
      with Cloudflare). The test VM disables this (no real DNS/API token).
    '')
    // {
      default = true;
    };

  config = {
    # zeus has no public IP, so HTTP-01 is impossible; DNS-01 through the
    # Cloudflare API works regardless. The scoped API token comes from sops.
    security.acme = lib.mkIf tls {
      acceptTerms = true;
      defaults.email = "admin@cwrunix.com"; # TODO: real contact address
      certs."zeus.cwrunix.com" = {
        extraDomainNames = [ "*.zeus.cwrunix.com" ];
        dnsProvider = "cloudflare";
        credentialFiles."CLOUDFLARE_DNS_API_TOKEN_FILE" =
          config.sops.secrets."cloudflare/dns_api_token".path;
        group = "nginx";
        reloadServices = [ "nginx" ];
      };
    };

    # Local HTTP(S) router: cloudflared (public, via tunnel) and direct
    # LAN/tailnet/container clients all end up here. Plain :80 stays for
    # cloudflared on loopback; :443 serves the wildcard cert for everything
    # else. Neither port is opened on the public firewall.
    services.nginx = {
      enable = true;
      recommendedProxySettings = true;
      recommendedOptimisation = true;
      recommendedTlsSettings = tls;

      virtualHosts = {
        "authentik.zeus.cwrunix.com" = {
          useACMEHost = lib.mkIf tls "zeus.cwrunix.com";
          addSSL = tls;
          locations."/" = {
            proxyPass = "http://10.77.0.2:9000"; # authentik container
            proxyWebsockets = true;
          };
        };

        "headscale.zeus.cwrunix.com" = {
          useACMEHost = lib.mkIf tls "zeus.cwrunix.com";
          addSSL = tls;
          locations."/" = {
            proxyPass = "http://10.77.1.2:8080"; # headscale container
            # headscale's embedded DERP relay uses a websocket upgrade.
            proxyWebsockets = true;
          };
        };
      };
    };

    # Resolve our own services locally instead of hairpinning through the
    # cloudflare tunnel. The wildcard cert is publicly signed, so TLS
    # verifies. This keeps tailnet enrollment (host tailscaled) and the
    # headscale container's OIDC discovery working even when the tunnel is
    # down.
    networking.hosts = lib.mkIf tls {
      "127.0.0.1" = [
        "authentik.zeus.cwrunix.com"
        "headscale.zeus.cwrunix.com"
      ];
    };
  };
}
