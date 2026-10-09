{ ... }:
{
  networking.hostName = "zeus";
  networking.domain = "cwrunix.com";

  # NOTE: no interface config here — the server uses DHCP by default.
  # Set networking.interfaces.<if>.ipv4.addresses (or a DHCP reservation)
  # once the NIC layout of the real machine is known.

  networking.firewall = {
    enable = true;
    # Public HTTP(S) arrives via the cloudflare tunnel (cloudflared is
    # outbound-only), so no web ports need to be opened here.
    allowedTCPPorts = [
      22 # SSH (campus LAN; tailnet traffic comes via tailscale0 below)
    ];
    # Members reach SSH over the tailnet; anything from tailscale0 is
    # tailnet-authenticated already.
    trustedInterfaces = [
      "tailscale0"
      "ve-+" # host<->nixos-container traffic (authentik, headscale)
    ];
  };

  # Outbound NAT for the private networks of the nixos-containers
  # (authentik -> SMTP/LDAP sources, headscale -> OIDC issuer, ...).
  networking.nat = {
    enable = true;
    internalInterfaces = [ "ve-+" ];
    # externalInterface intentionally unset: masquerade on any egress
    # (the real NIC name is not known yet).
  };

  networking.timeServers = [
    "0.nixos.pool.ntp.org"
    "1.nixos.pool.ntp.org"
    "2.nixos.pool.ntp.org"
    "3.nixos.pool.ntp.org"
    "time.google.com"
    "time2.google.com"
    "time3.google.com"
    "time4.google.com"
  ];
}
