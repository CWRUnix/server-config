{ config, pkgs, ... }:
let
  tunnelId = "c961c294-f5a7-49e0-842b-a855daba33a6";
  # Hostnames the tunnel still SERVES. headscale-zeus stays here as a
  # fallback (browser/WASM flows work through the tunnel); native
  # tailscaled clients can't use it (Cloudflare strips Upgrade on POST)
  # and reach headscale via the Linode raw-TCP relay instead (proxy/,
  # nixos/proxy-relay.nix).
  hostnames = [
    "authentik-zeus.cwrunix.com"
    "headscale-zeus.cwrunix.com"
    "headplane-zeus.cwrunix.com"
    "ttyd-zeus.cwrunix.com"
  ];
  # Hostnames whose DNS the dns-routes service below manages. headscale-
  # zeus is deliberately absent: its record is a grey-cloud A record
  # pointing at the relay VPS, managed by infra/main.tf via
  # proxy-provision.service (which also deletes the legacy tunnel CNAME).
  dnsHostnames = [
    "authentik-zeus.cwrunix.com"
    "headplane-zeus.cwrunix.com"
    "ttyd-zeus.cwrunix.com"
  ];
in
{
  # The cloudflare tunnel is the only public ingress (zeus has no public IP).
  #
  # This tunnel is LOCALLY MANAGED: ingress rules and DNS routes live here
  # in the repo. (If the tunnel shows up as "remotely managed" because it
  # was created in the dashboard, the dashboard config silently overrides
  # everything below — the connector logs "Updated to new configuration"
  # on start. Delete such a tunnel and recreate it via the CLI.)
  #
  # Bootstrap:
  #   1. `cloudflared tunnel login`                     (browser auth)
  #   2. `cloudflared tunnel create zeus`               (writes ~/.cloudflared/<id>.json)
  #   3. put the credentials JSON into sops key `cloudflared-creds`
  #   4. replace tunnelId below with the new tunnel's ID
  #   5. deploy — the cloudflared-dns-routes service registers the DNS
  #      CNAMEs automatically (uses the ACME DNS API token).
  services.cloudflared = {
    enable = true;
    tunnels.${tunnelId} = {
      credentialsFile = config.sops.secrets.cloudflared-creds.path;
      default = "http_status:404";
      # Proxy to the local nginx over HTTPS, verified against the per-host
      # Let's Encrypt certs on the origin (like "Full (strict)" mode):
      # edge cert is Cloudflare's, origin cert is ours.
      ingress = builtins.listToAttrs (
        map (h: {
          name = h;
          value = {
            service = "https://localhost:443";
            originRequest.originServerName = h;
          };
        }) hostnames
      );
    };
  };

  # Keep the tunnel's DNS routes (CNAME -> <tunnel>.cfargotunnel.com,
  # proxied) in sync with the ingress hostnames above, using the scoped
  # Cloudflare DNS API token from sops (no account-wide cert.pem needed).
  # Idempotent: creates or updates the records on every deploy.
  systemd.services.cloudflared-dns-routes = {
    description = "Register Cloudflare Tunnel DNS routes";
    wantedBy = [ "multi-user.target" ];
    after = [
      "cloudflared-tunnel-${tunnelId}.service"
      "network-online.target"
    ];
    wants = [
      "cloudflared-tunnel-${tunnelId}.service"
      "network-online.target"
    ];
    path = with pkgs; [
      curl
      jq
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      LoadCredential = "dns-token:${config.sops.secrets."cloudflare/dns_api_token".path}";
      # The campus LAN can take minutes to pass traffic after link-up
      # (seen on first boot of the real hardware: api.cloudflare.com was
      # unreachable when this ran). network-online.target isn't enough —
      # keep retrying.
      Restart = "on-failure";
      RestartSec = "30s";
    };
    script = ''
      set -euo pipefail
      token="$(cat "$CREDENTIALS_DIRECTORY/dns-token")"
      api="https://api.cloudflare.com/client/v4"
      auth="Authorization: Bearer $token"

      zone_id=$(curl -fsS "$api/zones?name=cwrunix.com" -H "$auth" | jq -r '.result[0].id')
      if [ -z "$zone_id" ] || [ "$zone_id" = "null" ]; then
        echo "error: could not resolve zone id for cwrunix.com" >&2
        exit 1
      fi

      for host in ${toString dnsHostnames}; do
        body=$(jq -n --arg name "$host" --arg target "${tunnelId}.cfargotunnel.com" \
          '{type:"CNAME", name:$name, content:$target, proxied:true, ttl:1}')
        record_id=$(curl -fsS "$api/zones/$zone_id/dns_records?type=CNAME&name=$host" -H "$auth" | jq -r '.result[0].id // empty')
        if [ -n "$record_id" ]; then
          curl -fsS -X PUT "$api/zones/$zone_id/dns_records/$record_id" -H "$auth" \
            -H 'Content-Type: application/json' -d "$body" > /dev/null
          echo "updated DNS route for $host"
        else
          curl -fsS -X POST "$api/zones/$zone_id/dns_records" -H "$auth" \
            -H 'Content-Type: application/json' -d "$body" > /dev/null
          echo "created DNS route for $host"
        fi
      done
    '';
  };
}
