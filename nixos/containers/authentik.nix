{ config, inputs, ... }:
{
  # authentik (IdP) + its LDAP outpost, from the nix-community/authentik-nix
  # flake. Runs in a declarative nixos-container so the host stays barebones.
  #
  # Reachable as https://authentik.zeus.cwrunix.com via nginx + cloudflared
  # on the host. The LDAP outpost listens on the container's private address
  # only and is consumed by sssd on the host (see nixos/auth/).
  #
  # Bootstrap checklist (first deploy):
  #   1. Log in as akadmin (bootstrap password from sops
  #      "authentik/bootstrap_password").
  #   2. Create an LDAP provider + an LDAP outpost assigned to it.
  #   3. Create the bind user "ldapservice" with a strong password; store it
  #      in sops as "ldap/bind_password".
  #   4. Store the outpost token in sops as "authentik/ldap_outpost_token".
  #   5. Add an LDAP property mapping exposing the user attribute
  #      "ssh_public_key" as "sshPublicKey" so sssd can serve SSH keys.
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
    };

    config =
      { ... }:
      {
        imports = [ inputs.authentik-nix.nixosModules.default ];

        networking.firewall.allowedTCPPorts = [
          9000 # web UI (plain HTTP; TLS is terminated at cloudflare)
          389 # LDAP outpost (private veth only, never leaves the host)
          636 # LDAPS (unused for now)
        ];

        services.authentik = {
          enable = true;
          environmentFile = "/run/secrets/authentik-env";
          settings = {
            disable_startup_analytics = true;
            disable_update_check = true;
            avatars = "initials";
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
