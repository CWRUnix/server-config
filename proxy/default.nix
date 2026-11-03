# Minimal NixOS relay VPS (Linode, us-ord): raw-TCP forwards port 443 to
# zeus over an frp tunnel that ZEUS dials OUT (zeus is behind double NAT).
# This is the only way stock tailscaled clients can reach headscale:
# Cloudflare strips the Upgrade header on POST requests (wontfix,
# cloudflared#883), so the TS2021 control handshake can never pass the
# Cloudflare tunnel that serves the rest of *.cwrunix.com.
#
# Traffic path: client --TCP/443--> this box --frp--> zeus nginx:443
# (TLS terminates on zeus as before; this box sees only ciphertext).
#
# Build the uploadable Linode image (gzipped raw, ~1 GB):
#   nix build .#proxy-image
# Then place it where proxy-provision.service on zeus expects it:
#   nix build .#proxy-image --out-link /root/infra-tofu/proxy-image   (on zeus)
# and the service uploads/configures the instance via infra/main.tf.
#
# Updates after the instance exists:
#   nixos-rebuild switch --target-host root@<relay-ip> --flake .#proxy
{
  pkgs,
  lib,
  modulesPath,
  ...
}:
{
  imports = [
    (modulesPath + "/virtualisation/linode-image.nix")
    # Same local admin account as zeus (SSH-key maintenance access).
    ../nixos/admins/tev.nix
  ];

  networking.hostName = "zeus-relay";
  system.stateVersion = "25.11";

  # frps + sshd is all this box runs; keep the image small (Linode expands
  # it to the full instance disk on deploy). 2 GB was too small for the
  # closure copy during the image build; 4 GB works.
  virtualisation.diskSize = 4096;

  # frps control plane. zeus's frpc registers the 443 relay from its side.
  # The auth token is deliberately NOT baked into the image (the image is
  # world-readable in zeus's nix store, which sandboxed club members can
  # read): proxy-provision.service on zeus writes /etc/frp/frps.env over
  # SSH after creating the instance. frps crash-loops harmlessly until
  # then (it never starts accepting without the token file).
  services.frp.instances.server = {
    enable = true;
    role = "server";
    environmentFiles = [ "/etc/frp/frps.env" ];
    settings = {
      bindAddr = "0.0.0.0";
      bindPort = 7000;
      auth.method = "token";
      auth.token = "{{ .Envs.FRP_TOKEN }}";
      # Only the 443 relay may be registered with this token.
      allowPorts = [ { single = 443; } ];
    };
  };

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };
  # root's keys come from the Linode API at instance-creation time
  # (infra/main.tf: the dedicated zeus provisioning keypair).
  users.users.root.openssh.authorizedKeys.keys = [ ];

  networking.firewall.allowedTCPPorts = [
    22 # maintenance SSH
    443 # the raw-TCP relay to zeus
    7000 # frp control (token-authenticated; zeus dials out to it)
  ];

  # No ACME/nginx here (TLS terminates on zeus), no docs, no extras.
  documentation.enable = false;
  environment.defaultPackages = lib.mkForce [ ];
}
