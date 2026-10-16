{ config, lib, ... }:
let
  tls = config.cwrunix.originTls;

  # One Let's Encrypt cert per service hostname, via ACME DNS-01 with the
  # Cloudflare API (zeus has no public IP, so HTTP-01 is impossible; DNS-01
  # works regardless). The scoped API token comes from sops.
  acmeHost = {
    dnsProvider = "cloudflare";
    credentialFiles."CLOUDFLARE_DNS_API_TOKEN_FILE" =
      config.sops.secrets."cloudflare/dns_api_token".path;
    group = "nginx";
    reloadServices = [ "nginx" ];
    # Replace lego's propagation pre-check with a fixed 30s wait. The
    # check polls via the system resolver, which here is quad100 (tailnet
    # MagicDNS) — a chain that served stale TXT answers for hours in
    # testing (and both zeus and the test VM sit behind NATs with no
    # direct UDP/TCP 53 to public resolvers). --dns.propagation.wait
    # disables all checks and waits instead (per lego's help); Cloudflare
    # propagates in seconds, LE does its own external validation, and the
    # renewal timer covers the rare residual race (observed as an LE-side
    # NXDOMAIN when finalizing ~6s after TXT creation).
    extraLegoRunFlags = [ "--dns.propagation.wait=30s" ];
    extraLegoRenewFlags = [ "--dns.propagation.wait=30s" ];
  };
in
{
  options.cwrunix.originTls =
    (lib.mkEnableOption ''
      TLS for service hostnames via per-host Let's Encrypt certs (ACME
      DNS-01 with Cloudflare). The test VM disables this (no real DNS/API
      token).
    '')
    // {
      default = true;
    };

  config = {
    security.acme = lib.mkIf tls {
      acceptTerms = true;
      defaults.email = "admin@cwrunix.com"; # TODO: real contact address
      certs."authentik-zeus.cwrunix.com" = acmeHost;
      certs."headscale-zeus.cwrunix.com" = acmeHost;
      certs."headplane-zeus.cwrunix.com" = acmeHost;
      certs."ttyd-zeus.cwrunix.com" = acmeHost;
    };

    # Local HTTP(S) router: cloudflared (public, via tunnel) and direct
    # LAN/tailnet/container clients all end up here. Plain :80 stays for
    # local clients; :443 serves the LE certs. Neither port is opened on
    # the public firewall.
    services.nginx = {
      enable = true;
      recommendedProxySettings = true;
      recommendedOptimisation = true;
      recommendedTlsSettings = tls;

      virtualHosts = {
        "authentik-zeus.cwrunix.com" = {
          useACMEHost = lib.mkIf tls "authentik-zeus.cwrunix.com";
          addSSL = tls;
          locations."/" = {
            proxyPass = "http://10.77.0.2:9000"; # authentik container
            proxyWebsockets = true;
          };
        };

        "headscale-zeus.cwrunix.com" = {
          useACMEHost = lib.mkIf tls "headscale-zeus.cwrunix.com";
          addSSL = tls;
          locations."/" = {
            proxyPass = "http://10.77.1.2:8080"; # headscale container
            # headscale's embedded DERP relay uses a websocket upgrade.
            proxyWebsockets = true;
          };
          # CORS for headplane's browser SSH (hp_ssh.wasm), served from the
          # headplane-zeus origin but calling headscale's /key etc. from the
          # browser. The control websocket itself is not CORS-bound (and
          # headscale accepts any Origin); this is for plain fetches.
          extraConfig = ''
            add_header Access-Control-Allow-Origin "https://headplane-zeus.cwrunix.com" always;
            add_header Access-Control-Allow-Methods "GET, POST, OPTIONS" always;
            add_header Access-Control-Allow-Headers "Content-Type, Upgrade, Sec-WebSocket-Protocol" always;
            if ($request_method = OPTIONS) { return 204; }
          '';
        };

        "headplane-zeus.cwrunix.com" = {
          useACMEHost = lib.mkIf tls "headplane-zeus.cwrunix.com";
          addSSL = tls;
          locations."/" = {
            proxyPass = "http://10.77.1.2:3000"; # headplane (headscale container)
            proxyWebsockets = true;
          };
          # The UI lives under /admin; headplane 404s on /.
          locations."= /".extraConfig = ''
            return 302 /admin;
          '';
        };

        # Browser shell for members without a tailscale client (see
        # nixos/webtty.nix). The oauth2-proxy nginx integration adds the
        # auth_request / /oauth2 locations on this vhost.
        "ttyd-zeus.cwrunix.com" = {
          useACMEHost = lib.mkIf tls "ttyd-zeus.cwrunix.com";
          addSSL = tls;
          locations."/" = {
            proxyPass = "http://127.0.0.1:7682"; # ttyd-public
            proxyWebsockets = true;
          };
        };
      };
    };

    # Resolve our own services locally instead of hairpinning through the
    # cloudflare tunnel. The certs are publicly signed, so TLS verifies.
    # This keeps tailnet enrollment (host tailscaled) and the headscale
    # container's OIDC discovery working even when the tunnel is down.
    networking.hosts = lib.mkIf tls {
      "127.0.0.1" = [
        "authentik-zeus.cwrunix.com"
        "headscale-zeus.cwrunix.com"
      ];
    };
  };
}
