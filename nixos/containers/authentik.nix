{ config, inputs, lib, ... }:
{
  # authentik (IdP) + its LDAP outpost, from the nix-community/authentik-nix
  # flake. Runs in a declarative nixos-container so the host stays barebones.
  #
  # Reachable as https://authentik-zeus.cwrunix.com via nginx + cloudflared
  # on the host. The LDAP outpost listens on the container's private address
  # only and is consumed by sssd on the host (see nixos/auth/).
  #
  # All configuration (LDAP stack, headscale OIDC, outpost token) is applied
  # non-interactively by the in-container OpenTofu bootstrap — see
  # nixos/authentik-bootstrap.nix and tofu/. Only *users* are managed in the
  # UI (Directory -> Users; set "sshPublicKey" attribute for SSH key login).
  # Fresh-boot DB migrations can take several minutes on slow disks; the
  # module's default 1min unit start timeout would SIGTERM the container
  # mid-migrate and wedge the machined registration ("Machine 'authentik'
  # already exists").
  systemd.services."container@authentik".serviceConfig.TimeoutStartSec = lib.mkForce "15min";

  containers.authentik = {
    autoStart = true;
    privateNetwork = true;
    hostAddress = "10.77.0.1";
    localAddress = "10.77.0.2";

    # Secrets are decrypted by sops-nix on the host and passed in read-only.
    bindMounts = {
      "/run/secrets/authentik-env" = {
        hostPath = config.sops.templates."authentik-env".path;
        isReadOnly = true;
      };
      "/run/secrets/authentik-ldap-env" = {
        hostPath = config.sops.templates."authentik-ldap-env".path;
        isReadOnly = true;
      };
      "/run/secrets/authentik-tofu-env" = {
        hostPath = config.sops.templates."authentik-tofu-env".path;
        isReadOnly = true;
      };
    };

    config =
      { ... }:
      {
        imports = [
          inputs.authentik-nix.nixosModules.default
          ../authentik-bootstrap.nix
        ];

        # DNS: the host's dnsmasq answers on the veth gateway (see
        # nixos/networking.nix). We can't rely on networking.nameservers +
        # resolvconf here: the host's resolv.conf is copied over the
        # container's at prestart and points at host-local resolvers
        # (quad100) — resolvconf merges muddled past that — so disable
        # resolvconf and write the file directly at boot.
        networking.resolvconf.enable = false;
        systemd.services.container-resolvconf = {
          description = "Write resolv.conf pointing at the host's dnsmasq";
          wantedBy = [ "multi-user.target" ];
          before = [ "network-online.target" ];
          serviceConfig.Type = "oneshot";
          script = ''
            rm -f /etc/resolv.conf
            printf 'nameserver 10.77.0.1\noptions edns0\n' > /etc/resolv.conf
          '';
        };

        networking.firewall.allowedTCPPorts = [
          9000 # web UI (plain HTTP; TLS is terminated at cloudflare)
          3389 # LDAP outpost (private veth only, never leaves the host)
          6636 # LDAPS (unused for now)
        ];

        services.authentik = {
          enable = true;
          environmentFile = "/run/secrets/authentik-env";
          settings = {
            disable_startup_analytics = true;
            disable_update_check = true;
            avatars = "initials";
            # Base URL system setting (2026.8+, required as of 2026.11).
            # This env value only *seeds* the setting when empty and never
            # overwrites an Admin-UI/API value; the tofu provider we pin
            # (2026.5.2) predates the setting, hence not managed there.
            web.base_url = "https://authentik-zeus.cwrunix.com";
            # TODO: SMTP, needed for enrollment invites + password resets:
            # email = {
            #   host = "smtp.example.com";
            #   port = 587;
            #   use_tls = true;
            #   username = "...";
            #   from = "authentik@zeus.cwrunix.com";
            # };
            # (password goes into the environmentFile as
            #  AUTHENTIK_EMAIL__PASSWORD)
          };
        };

        services.authentik-ldap = {
          enable = true;
          environmentFile = "/run/secrets/authentik-ldap-env";
        };

        system.stateVersion = "25.11";
      };
  };
}
