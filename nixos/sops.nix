{ config, ... }:
{
  sops.defaultSopsFile = ../secrets.yaml;
  sops.defaultSopsFormat = "yaml";

  # On the server the age key lives on the persistent disk directly (no
  # bind mount, so sops sees it as early as possible). The test VM
  # overrides this to the 9p share (see vm.nix).
  sops.age.keyFile = "/persist/sops-nix/key.txt";

  sops.secrets = {
    github_token = { };
    cloudflared-creds = { };
    "authentik/secret_key" = { };
    "authentik/bootstrap_password" = { };
    "authentik/ldap_outpost_token" = { };
    "ldap/bind_password" = { };
    "headscale/oidc_client_secret" = {
      # Read by the headscale service *inside* its nixos-container; the
      # container shares the host's UID space but the headscale UID exists
      # only inside the container, so the host can't chown to it. Local
      # non-admin accounts don't exist on this host (remote users are
      # sandboxed and cannot see this filesystem), hence 0444.
      mode = "0444";
    };
    # Scoped Cloudflare API token with Zone.DNS edit rights for
    # cwrunix.com, used by the ACME DNS-01 challenge (see nginx.nix).
    "cloudflare/dns_api_token" = { };
    "headscale/preauth_key" = { };
  };

  # Rendered environment files, passed into containers/services via
  # systemd EnvironmentFile (see containers/ and auth/).
  sops.templates = {
    "authentik-env" = {
      path = "/run/secrets/rendered/authentik-env";
      content = ''
        AUTHENTIK_SECRET_KEY=${config.sops.placeholder."authentik/secret_key"}
        AUTHENTIK_BOOTSTRAP_PASSWORD=${config.sops.placeholder."authentik/bootstrap_password"}
        AUTHENTIK_BOOTSTRAP_EMAIL=admin@cwrunix.com
      '';
    };

    "authentik-ldap-env" = {
      path = "/run/secrets/rendered/authentik-ldap-env";
      content = ''
        # Outpost runs in the same container as the server -> plain HTTP on
        # localhost is fine.
        AUTHENTIK_HOST=http://localhost:9000
        AUTHENTIK_INSECURE=true
        AUTHENTIK_TOKEN=${config.sops.placeholder."authentik/ldap_outpost_token"}
      '';
    };

    # Consumed by services.sssd.environmentFile; the sssd module substitutes
    # $LDAP_BIND_PW into sssd.conf at service start (never in the nix store).
    "sssd-env" = {
      path = "/run/secrets/rendered/sssd-env";
      content = ''
        LDAP_BIND_PW=${config.sops.placeholder."ldap/bind_password"}
      '';
    };
  };
}
