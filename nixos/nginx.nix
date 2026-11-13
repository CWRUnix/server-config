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
      certs."mail-zeus.cwrunix.com" = acmeHost;
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

      # The mail webmail needs the real client IP for per-IP auth rate
      # limits. cloudflared connects from localhost with the visitor
      # address in CF-Connecting-IP; direct LAN/tailnet clients are their
      # own source. Stalwart is configured to take the client address from
      # exactly one XFF entry (containers/mail.nix), so the mail vhost
      # replaces X-Forwarded-For with this single-entry value.
      #
      # $mail_admin_ok guards the mail webadmin/management API: it keys on
      # the REAL client IP, because every tunnel connection arrives from
      # cloudflared (127.0.0.1) — an allow-by-$remote_addr list would
      # wrongly let the whole public internet into /admin.
      appendHttpConfig = ''
        # Only localhost peers (cloudflared, or genuine host-local traffic)
        # may claim a different address via CF-Connecting-IP; everyone else
        # is their own source address. An empty CF header (no tunnel) means
        # the localhost peer is the client.
        map $http_cf_connecting_ip $mail_cf_claim {
          "" $remote_addr;
          default $http_cf_connecting_ip;
        }
        map $remote_addr $mail_client_ip {
          default $remote_addr;
          127.0.0.1 $mail_cf_claim;
          ::1 $mail_cf_claim;
        }
        # Stalwart rejects loopback client claims in XFF (anti-spoofing);
        # for those, send no XFF at all — it falls back to the (trusted,
        # host-local) peer address instead.
        map $mail_client_ip $mail_xff {
          "127.0.0.1" "";
          "::1" "";
          default $mail_client_ip;
        }
        geo $mail_client_ip $mail_admin_ok {
          default 0;
          127.0.0.1 1;
          ::1 1;
          100.64.0.0/10 1; # tailnet
        }
      '';

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

        # Webmail (Bulwark, hosted by Stalwart at /webmail) + JMAP +
        # Stalwart's OAuth endpoints, from the mail container. The web
        # admin (/admin) and the management REST API (/api) are NOT public:
        # tailnet/localhost only — EXCEPT /api/auth, which the webmail
        # login flow posts to.
        "mail-zeus.cwrunix.com" =
          let
            # Manual header set: the location-level recommendedProxySettings
            # include would shadow the single-entry XFF override (a location
            # with its own proxy_set_header inherits none from the server).
            # $mail_client_ip is the appendHttpConfig map above. NOTE: an
            # empty $mail_client_ip (localhost probe, no CF header) sends
            # NO XFF — Stalwart then 400s by design (missing/loopback XFF
            # claims are rejected); only real proxy/LAN paths yield a
            # client IP.
            proxyHeaders = ''
              proxy_set_header Host $host;
              proxy_set_header X-Real-IP $remote_addr;
              proxy_set_header X-Forwarded-For $mail_xff;
              proxy_set_header X-Forwarded-Proto $scheme;
              proxy_set_header X-Forwarded-Host $host;
              proxy_set_header X-Forwarded-Server $hostname;
            '';
            adminGuard = ''
              if ($mail_admin_ok = 0) { return 403; }
            '';
          in
          {
            useACMEHost = lib.mkIf tls "mail-zeus.cwrunix.com";
            addSSL = tls;
            extraConfig = ''
              # JMAP uploads (message send with attachments).
              client_max_body_size 100m;
            '';
            locations."/" = {
              proxyPass = "http://10.77.3.2:8080"; # mail container (stalwart)
              proxyWebsockets = true;
              recommendedProxySettings = false;
              extraConfig = ''
                ${proxyHeaders}
                # JMAP push (EventSource) is a long-lived stream.
                proxy_read_timeout 3600s;
                proxy_send_timeout 3600s;
              '';
            };
            # Public (unguarded) management-API exceptions — both are part of
            # the LOGIN flow and are safe to expose (Stalwart rate-limits
            # anonymous callers itself):
            #  * /api/auth: password/token login the webmail POSTs to.
            #  * /api/discover/<address>: the lookup the webmail's login
            #    page uses to learn whether an address signs in via SSO
            #    (returns the OIDC endpoints) or with a password. Without
            #    this the "Sign in with SSO" flow never starts.
            locations."/api/auth" = {
              proxyPass = "http://10.77.3.2:8080";
              recommendedProxySettings = false;
              extraConfig = proxyHeaders;
            };
            locations."/api/discover/" = {
              proxyPass = "http://10.77.3.2:8080";
              recommendedProxySettings = false;
              extraConfig = proxyHeaders;
            };
            locations."/api" = {
              proxyPass = "http://10.77.3.2:8080";
              recommendedProxySettings = false;
              extraConfig = ''
                ${proxyHeaders}
                ${adminGuard}
              '';
            };
            locations."/admin" = {
              proxyPass = "http://10.77.3.2:8080";
              proxyWebsockets = true;
              recommendedProxySettings = false;
              extraConfig = ''
                ${proxyHeaders}
                ${adminGuard}
              '';
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
