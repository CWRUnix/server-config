{ config, ... }:
{
  # headscale coordination server for the club tailnet. Members join via
  # authentik SSO (OIDC). Served at https://headscale.zeus.cwrunix.com via
  # nginx + cloudflared on the host.
  #
  # Bootstrap checklist (first deploy):
  #   1. In authentik, create an OIDC provider + application "headscale"
  #      (redirect URI: https://headscale.zeus.cwrunix.com/oidc/callback).
  #   2. Store the client secret in sops as "headscale/oidc_client_secret".
  #   3. Create the tailnet admin user + a preauth key for zeus itself
  #      (see nixos/tailscale.nix).
  containers.headscale = {
    autoStart = true;
    privateNetwork = true;
    hostAddress = "10.77.1.1";
    localAddress = "10.77.1.2";

    bindMounts = {
      "/run/secrets/headscale-oidc" = {
        hostPath = config.sops.secrets."headscale/oidc_client_secret".path;
        isReadOnly = true;
      };
    };

    config =
      { ... }:
      {
        networking.firewall.allowedTCPPorts = [ 8080 ];

        # OIDC discovery via the host's nginx (wildcard cert), avoiding a
        # cloudflare-tunnel hairpin for an on-host dependency.
        networking.hosts."10.77.1.1" = [ "authentik.zeus.cwrunix.com" ];

        services.headscale = {
          enable = true;
          address = "0.0.0.0";
          port = 8080;
          settings = {
            server_url = "https://headscale.zeus.cwrunix.com";

            dns = {
              magic_dns = true;
              base_domain = "ts.zeus.cwrunix.com";
              # Upstream resolvers handed to tailnet clients for
              # non-tailnet names.
              nameservers.global = [
                "1.1.1.1"
                "1.0.0.1"
                "9.9.9.9"
              ];
            };

            # Embedded DERP relay as a NAT-traversal fallback. It is served
            # on the main listener (/derp), so it works through the tunnel.
            # Its STUN endpoint (UDP 3478) does NOT traverse cloudflare; on
            # the campus LAN clients can usually establish direct
            # connections anyway, and worst case traffic is relayed.
            derp.server = {
              enabled = true;
              region_id = 999;
              region_code = "zeus";
              region_name = "zeus";
              stun_listen_addr = "0.0.0.0:3478";
            };

            oidc = {
              issuer = "https://authentik.zeus.cwrunix.com/application/o/headscale/";
              client_id = "headscale";
              client_secret_path = "/run/secrets/headscale-oidc";
            };
          };
        };

        system.stateVersion = "25.11";
      };
  };
}
