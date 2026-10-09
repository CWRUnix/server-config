{ config, ... }:
{
  # The host joins its own headscale tailnet (headscale runs in a local
  # nixos-container, reached through the cloudflare tunnel). Members SSH to
  # zeus over the tailnet from anywhere.
  #
  # Bootstrap: after headscale is up, create a user + preauth key inside the
  # container (`sudo nixos-container run headscale -- headscale users create
  # admin` / `headscale preauthkeys create ...`) and store the key in sops as
  # "headscale/preauth_key".
  services.tailscale = {
    enable = true;
    openFirewall = true;
    authKeyFile = config.sops.secrets."headscale/preauth_key".path;
    authKeyParameters.baseURL = "https://headscale.zeus.cwrunix.com";
  };
}
