{ config, ... }:
{
  # The cloudflare tunnel is the only public ingress (zeus has no public IP).
  #
  # Bootstrap:
  #   1. `cloudflared tunnel create zeus` (or reuse an existing tunnel)
  #   2. put the resulting credentials JSON into sops key `cloudflared-creds`
  #   3. replace the tunnel ID below
  #   4. create the DNS routes (CNAMEs) for the hostnames below
  services.cloudflared = {
    enable = true;
    tunnels = {
      "00000000-0000-0000-0000-000000000000" = {
        credentialsFile = config.sops.secrets.cloudflared-creds.path;
        default = "http_status:404";
        ingress = {
          "authentik.zeus.cwrunix.com" = "http://localhost:80";
          "headscale.zeus.cwrunix.com" = "http://localhost:80";
        };
      };
    };
  };
}
