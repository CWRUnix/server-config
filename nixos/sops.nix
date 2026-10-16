{ config, lib, ... }:
let
  tunnelUnits = lib.optionals config.services.cloudflared.enable (
    map (id: "cloudflared-tunnel-${id}.service") (builtins.attrNames config.services.cloudflared.tunnels)
  );
  acmeUnits = map (n: "acme-${n}.service") (builtins.attrNames config.security.acme.certs);
in
{
  sops.defaultSopsFile = ../secrets.yaml;
  sops.defaultSopsFormat = "yaml";

  # On the server the age key lives on the persistent disk directly (no
  # bind mount, so sops sees it as early as possible). The test VM
  # overrides this to the 9p share (see vm.nix).
  sops.age.keyFile = "/persist/sops-nix/key.txt";

  sops.secrets = {
    github_token = { };

    # Tunnel credentials JSON (from `cloudflared tunnel create`). Restart
    # the tunnel connector when it changes.
    cloudflared-creds = {
      restartUnits = tunnelUnits;
    };

    "authentik/secret_key" = { };
    "authentik/bootstrap_password" = { };
    "authentik/ldap_outpost_token" = { };
    # Static API token for akadmin, created by authentik at first boot
    # (AUTHENTIK_BOOTSTRAP_TOKEN). Used by the in-container OpenTofu
    # bootstrap (see nixos/authentik-bootstrap.nix).
    "authentik/bootstrap_token" = { };
    "ldap/bind_password" = { };
    "headscale/oidc_client_secret" = {
      # Read by the headscale service *inside* its nixos-container; the
      # container shares the host's UID space but the headscale UID exists
      # only inside the container, so the host can't chown to it. Local
      # non-admin accounts don't exist on this host (remote users are
      # sandboxed and cannot see this filesystem), hence 0444.
      mode = "0444";
      restartUnits = [ "container@headscale.service" ];
    };
    # Scoped Cloudflare API token with Zone.DNS edit rights for
    # cwrunix.com, used by the ACME DNS-01 challenge (see nginx.nix) and
    # for auto-registering tunnel DNS routes (see cloudflare.nix).
    "cloudflare/dns_api_token" = {
      restartUnits =
        acmeUnits ++ lib.optional config.services.cloudflared.enable "cloudflared-dns-routes.service";
    };
    "headscale/preauth_key" = {
      restartUnits = [ "tailscaled-autoconnect.service" ];
    };
    # Both consumed by headplane inside the headscale container (0444 for the
    # same UID-space reason as headscale/oidc_client_secret above).
    #   cookie_secret: exactly 32 chars, session cookie signing key.
    #   api_key: `headscale apikeys create` output; headplane's server-side
    #     API access + the agent's ephemeral pre-auth key minting.
    "headplane/cookie_secret" = {
      mode = "0444";
      restartUnits = [ "container@headscale.service" ];
    };
    "headplane/api_key" = {
      mode = "0444";
      restartUnits = [ "container@headscale.service" ];
    };
    # Discord SSO source (see tofu/main.tf): OAuth app credentials + the
    # club guild/role the enrollment policy checks. Only client_secret is
    # truly sensitive; the rest live here so every deployment-specific
    # value is in one place.
    "discord/client_id" = { };
    "discord/client_secret" = { };
    "discord/guild_id" = { };
    "discord/role_id" = { };
    # Bot token for the cwrunix-bot Discord bot (Bot section of the same
    # Discord app). Empty until the bot user is created; the service
    # crash-loops with a clear error until then.
    "discord/bot_token" = {
      restartUnits = [ "container@discord-bot.service" ];
    };
    # Linode API token for the self-provisioning raw-TCP relay (see
    # nixos/proxy-relay.nix + infra/). Scopes: images:read_write,
    # linodes:read_write. Empty until the Linode account exists; the
    # provision service skips (and re-runs on change) while empty.
    "linode/api_token" = {
      restartUnits = [ "proxy-provision.service" ];
    };
    # Shared auth token between zeus's frpc and the relay VPS's frps.
    "frp/token" = {
      restartUnits = [
        "frp-relay.service"
        "proxy-provision.service"
      ];
    };
    # webtty OIDC client (tofu provider authentik_provider_oauth2.webtty)
    # + oauth2-proxy session cookie signing key (32 random bytes, base64).
    "webtty/client_secret" = {
      restartUnits = [
        "container@authentik.service"
        "oauth2-proxy.service"
      ];
    };
    "webtty/cookie_secret" = {
      restartUnits = [ "oauth2-proxy.service" ];
    };
  };

  # Rendered environment files, passed into containers/services via
  # systemd EnvironmentFile (see containers/ and auth/).
  sops.templates = {
    "authentik-env" = {
      path = "/run/secrets/rendered/authentik-env";
      restartUnits = [ "container@authentik.service" ];
      content = ''
        AUTHENTIK_SECRET_KEY=${config.sops.placeholder."authentik/secret_key"}
        AUTHENTIK_BOOTSTRAP_PASSWORD=${config.sops.placeholder."authentik/bootstrap_password"}
        AUTHENTIK_BOOTSTRAP_TOKEN=${config.sops.placeholder."authentik/bootstrap_token"}
        AUTHENTIK_BOOTSTRAP_EMAIL=admin@cwrunix.com
      '';
    };

    "authentik-ldap-env" = {
      path = "/run/secrets/rendered/authentik-ldap-env";
      restartUnits = [ "container@authentik.service" ];
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
      restartUnits = [ "sssd.service" ];
      content = ''
        LDAP_BIND_PW=${config.sops.placeholder."ldap/bind_password"}
      '';
    };

    # Consumed by the in-container authentik OpenTofu bootstrap service
    # (nixos/authentik-bootstrap.nix, bind-mounted into the container).
    "authentik-tofu-env" = {
      path = "/run/secrets/rendered/authentik-tofu-env";
      restartUnits = [ "container@authentik.service" ];
      content = ''
        AUTHENTIK_URL=http://localhost:9000
        AUTHENTIK_TOKEN=${config.sops.placeholder."authentik/bootstrap_token"}
        TF_VAR_ldap_bind_password=${config.sops.placeholder."ldap/bind_password"}
        TF_VAR_ldap_outpost_token=${config.sops.placeholder."authentik/ldap_outpost_token"}
        TF_VAR_headscale_client_secret=${config.sops.placeholder."headscale/oidc_client_secret"}
        TF_VAR_discord_client_id=${config.sops.placeholder."discord/client_id"}
        TF_VAR_discord_client_secret=${config.sops.placeholder."discord/client_secret"}
        TF_VAR_discord_guild_id=${config.sops.placeholder."discord/guild_id"}
        TF_VAR_discord_role_id=${config.sops.placeholder."discord/role_id"}
        TF_VAR_webtty_client_secret=${config.sops.placeholder."webtty/client_secret"}
      '';
    };

    # Consumed by frpc (needs FRP_TOKEN; systemd EnvironmentFile ignores
    # the rest) and by proxy-provision.service (nixos/proxy-relay.nix).
    "infra-tofu-env" = {
      path = "/run/secrets/rendered/infra-tofu-env";
      restartUnits = [
        "frp-relay.service"
        "proxy-provision.service"
      ];
      content = ''
        TF_VAR_linode_token=${config.sops.placeholder."linode/api_token"}
        TF_VAR_cloudflare_api_token=${config.sops.placeholder."cloudflare/dns_api_token"}
        FRP_TOKEN=${config.sops.placeholder."frp/token"}
      '';
    };

    # Consumed by the cwrunix-bot service inside the discord-bot container
    # (bind-mounted; see nixos/containers/discord-bot.nix). AUTHENTIK_TOKEN
    # is the akadmin bootstrap token (TODO: dedicated scoped account).
    "discord-bot-env" = {
      path = "/run/secrets/rendered/discord-bot-env";
      restartUnits = [ "container@discord-bot.service" ];
      content = ''
        DISCORD_BOT_TOKEN=${config.sops.placeholder."discord/bot_token"}
        DISCORD_GUILD_ID=${config.sops.placeholder."discord/guild_id"}
        AUTHENTIK_URL=https://authentik-zeus.cwrunix.com
        AUTHENTIK_PUBLIC_URL=https://authentik-zeus.cwrunix.com
        AUTHENTIK_TOKEN=${config.sops.placeholder."authentik/bootstrap_token"}
      '';
    };
  };
}
