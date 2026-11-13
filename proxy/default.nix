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
# Mail: ports 25/465/587/993 are forwarded the same way (frp tcp proxies,
# PROXY protocol v2 so Stalwart on zeus sees real sender IPs) — Cloudflare
# can't proxy those ports, so this box is the public face of
# mail.cwrunix.com (A record + rDNS in infra/main.tf). Outbound club mail
# takes the reverse path: Stalwart on zeus -> frp stcp visitor
# (10.77.3.1:2587) -> stcp proxy here -> Postfix on 127.0.0.1:2587 ->
# internet. The smarthost accepts only from loopback (only the
# token-authenticated stcp proxy reaches it), so no SASL is needed; the
# frp channel already provides mutual auth + encryption. zeus originates
# nothing itself — campus egress blocks port 25 and has no PTR.
#
# The image (gzipped raw, ~1 GB) is built into the SERVER's closure:
# flake.nix passes it to .#server as the proxyImage specialArg, and
# proxy-provision.service on zeus uploads/configures the instance via
# infra/main.tf. Manual build (fallback path, one-off testing):
#   nix build .#proxy-image
#   nix build .#proxy-image --out-link /root/infra-tofu/proxy-image   (on zeus)
#
# Updates after the instance exists:
#   nixos-rebuild switch --target-host root@<relay-ip> --flake .#proxy
{
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

  # frps + sshd + a loopback Postfix smarthost is all this box runs; keep
  # the image small (Linode expands it to the full instance disk on
  # deploy). 2 GB was too small for the closure copy during the image
  # build; 4 GB works.
  virtualisation.diskSize = 4096;

  # frps control plane. zeus's frpc registers the 443 relay + the mail
  # port relays from its side.
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
      # Only these relays may be registered with this token (headscale's
      # 443 + the public mail ports; the stcp smarthost hop below has no
      # remote port and is unaffected by this list).
      allowPorts = [
        { single = 443; }
        { single = 25; }
        { single = 465; }
        { single = 587; }
        { single = 993; }
      ];
    };
  };

  # stcp server-side of the OUTBOUND mail hop: exposes the loopback
  # Postfix to zeus's visitor. Client and server meet at this box's frps.
  services.frp.instances.mail-outbound = {
    enable = true;
    role = "client";
    environmentFiles = [ "/etc/frp/frps.env" ];
    settings = {
      serverAddr = "127.0.0.1";
      serverPort = 7000;
      auth.method = "token";
      auth.token = "{{ .Envs.FRP_TOKEN }}";
      proxies = [
        {
          name = "mail-outbound";
          type = "stcp";
          # The visitor side (on zeus) must present the same key. Reusing
          # the frp auth token: same trust boundary, one less secret.
          secretKey = "{{ .Envs.FRP_TOKEN }}";
          localIP = "127.0.0.1";
          localPort = 2587;
        }
      ];
    };
  };

  # The outbound smarthost. Loopback-only (reached exclusively through the
  # stcp proxy above); relays anything from loopback, nothing else. :25
  # stays off — frps owns it (forwarded to zeus's Stalwart). No TLS/SASL:
  # the frp channel covers both, and STARTTLS with an invalid cert would
  # break Stalwart's default TLS strategy.
  services.postfix = {
    enable = true;
    enableSmtp = false; # frps owns :25
    settings = {
      main = {
        # HELO/PTR/SPF all line up on this name (rDNS set in infra/main.tf).
        myhostname = "mail.cwrunix.com";
        mydomain = "cwrunix.com";
        myorigin = "mail.cwrunix.com";
        # Pure relay: no local domains, no local delivery.
        mydestination = [ ];
        inet_interfaces = "loopback-only";
        mynetworks = [ "127.0.0.0/8" ];
        # defer_unauth_destination: relay only for mynetworks (loopback).
        smtpd_relay_restrictions = "permit_mynetworks,defer_unauth_destination";
        # Match Stalwart's default max message size so it doesn't bounce
        # at the relay after Stalwart already accepted it.
        message_size_limit = 52428800;
      };
      master = {
        # The loopback smtpd Stalwart relays through (via the stcp
        # visitor). enableSmtp=false keeps :25 free for frps.
        "2587" = {
          type = "inet";
          private = false;
          chroot = false;
          command = "smtpd";
        };
        # enableSmtp=false also drops the OUTBOUND delivery agent
        # (nixpkgs gates `smtp = {};` on it) — without it every relay
        # defers with "connect to transport private/smtp: No such file".
        # Re-add the stock unix service.
        "smtp" = { };
        "relay" = {
          command = "smtp";
          args = [
            "-o"
            "smtp_fallback_relay="
          ];
        };
      };
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
    # Public mail ports, forwarded to zeus's mail container:
    25
    465
    587
    993
  ];

  # No ACME/nginx here (TLS terminates on zeus), no docs, no extras.
  documentation.enable = false;
  environment.defaultPackages = lib.mkForce [ ];
}
