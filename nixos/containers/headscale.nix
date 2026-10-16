{ config, lib, pkgs, ... }:
{
  # headscale coordination server for the club tailnet. Members join via
  # authentik SSO (OIDC). Served at https://headscale-zeus.cwrunix.com via
  # nginx + cloudflared on the host. headplane (the web UI, with browser SSH)
  # shares this container at https://headplane-zeus.cwrunix.com — the NixOS
  # headplane module asserts that services.headscale is enabled on the same
  # system, and the co-location gives the correct headscale.url /
  # config_path / public_url defaults for free.
  #
  # IMPORTANT Cloudflare tunnel limitation: tailscale's TS2021 control
  # handshake uses `POST /ts2021` with an Upgrade header, and cloudflared
  # strips Upgrade on POST (cloudflare/cloudflared#883, wontfix; headscale
  # docs: "behind cloudflare tunnel ... will not work"). Consequences:
  #   - NEW node registration only works when the client can reach nginx
  #     directly (campus LAN / existing tailnet), NOT through the tunnel.
  #   - Already-registered nodes keep working through the tunnel (HTTP
  #     long-poll control fallback + DERP relay, which uses GET upgrades).
  # So: members must do their first `tailscale up` while on campus.
  #
  # The authentik OIDC provider/application for headscale is created
  # declaratively by the authentik OpenTofu bootstrap (see tofu/); the client
  # secret lives in sops as "headscale/oidc_client_secret".
  #
  # Bootstrap checklist (first deploy / after a state wipe):
  #   1. Create users + keys inside the container and store them in sops:
  #        headscale users create admin --email admin@cwrunix.com
  #          (the email MUST match akadmin's authentik bootstrap email so the
  #          headplane owner account auto-links to it — the manual
  #          claim-picker is patched out, see headplane-disable-manual-linking.patch)
  #        headscale users create headplane-agent   # used by the headplane agent
  #        headscale preauthkeys create --user admin --reusable --expiration 8760h
  #          -> sops "headscale/preauth_key"   (see nixos/tailscale.nix)
  #        headscale apikeys create --expiration 8760h
  #          -> sops "headplane/api_key"
  #   2. Members then onboard through headplane (authentik SSO) or by doing
  #      their first `tailscale up` somewhere with direct (non-tunnel) access
  #      to nginx — see the cloudflare POST-Upgrade note above.
  # Be lenient with slow first boots (same reasoning as the authentik
  # container).
  systemd.services."container@headscale".serviceConfig.TimeoutStartSec = lib.mkForce "15min";

  containers.headscale = {
    autoStart = true;
    privateNetwork = true;
    hostAddress = "10.77.1.1";
    localAddress = "10.77.1.2";

    bindMounts = {
      "/run/secrets/headscale-oidc" = {
        hostPath = config.sops.secrets."headscale/oidc_client_secret".path;
        isReadOnly = true;
      };
      "/run/secrets/headplane-cookie" = {
        hostPath = config.sops.secrets."headplane/cookie_secret".path;
        isReadOnly = true;
      };
      "/run/secrets/headplane-api-key" = {
        hostPath = config.sops.secrets."headplane/api_key".path;
        isReadOnly = true;
      };
      # Read by headscale-user-sync to list authentik users (the tofu
      # bootstrap's akadmin API token).
      "/run/secrets/authentik-api-token" = {
        hostPath = config.sops.secrets."authentik/bootstrap_token".path;
        isReadOnly = true;
      };
    };

    config =
      { config, pkgs, ... }:
      {
        networking.firewall.allowedTCPPorts = [
          8080 # headscale
          3000 # headplane
        ];

        # OIDC discovery via the host's nginx (serving the per-host Let's
        # Encrypt cert), avoiding a cloudflare-tunnel hairpin for on-host
        # dependencies. headplane's server also calls its own public URL
        # (browser-SSH session setup) and headscale's — map all of them.
        #
        # DNS: the host's dnsmasq answers on the veth gateway (see
        # nixos/networking.nix). Same resolv.conf story as the authentik
        # container — write it directly, no resolvconf.
        networking.resolvconf.enable = false;
        systemd.services.container-resolvconf = {
          description = "Write resolv.conf pointing at the host's dnsmasq";
          wantedBy = [ "multi-user.target" ];
          before = [ "network-online.target" ];
          serviceConfig.Type = "oneshot";
          script = ''
            rm -f /etc/resolv.conf
            printf 'nameserver 10.77.1.1\noptions edns0\n' > /etc/resolv.conf
          '';
        };
        networking.hosts."10.77.1.1" = [
          "authentik-zeus.cwrunix.com"
          "headscale-zeus.cwrunix.com"
          "headplane-zeus.cwrunix.com"
        ];

        services.headscale = {
          enable = true;
          address = "0.0.0.0";
          port = 8080;
          settings = {
            server_url = "https://headscale-zeus.cwrunix.com";

            dns = {
              magic_dns = true;
              base_domain = "ts.zeus.cwrunix.com";
              # Upstream resolvers handed to tailnet clients for
              # non-tailnet names.
              nameservers.global = [
                "1.1.1.1"
                "1.0.0.1"
                "9.9.9.9"
              ];
            };

            # Embedded DERP relay as a NAT-traversal fallback. It is served
            # on the main listener (/derp), so it works through the tunnel.
            # Its STUN endpoint (UDP 3478) does NOT traverse cloudflare; on
            # the campus LAN clients can usually establish direct
            # connections anyway, and worst case traffic is relayed.
            #
            # urls = []: don't fetch tailscale's public DERP map — the
            # container has no outbound DNS, and headscale >= 0.29 treats a
            # DERP map fetch failure as fatal at startup. Embedded-only.
            derp = {
              urls = [ ];
              server = {
                enabled = true;
                region_id = 999;
                region_code = "zeus";
                region_name = "zeus";
                stun_listen_addr = "0.0.0.0:3478";
              };
            };

            oidc = {
              issuer = "https://authentik-zeus.cwrunix.com/application/o/headscale/";
              client_id = "headscale";
              client_secret_path = "/run/secrets/headscale-oidc";
            };

            # ACL policy. Tailscale SSH is ADMIN-ONLY: tailnet identity
            # replaces OS auth on the target, and the previous
            # member->member rule let ANY member become ANY non-root OS
            # user — an auth bypass. Members authenticate with their LDAP
            # password instead (sshd over the tailnet, or ttyd in the
            # browser — see nixos/ttyd.nix).
            #
            # group:admins lists headscale user identifiers — in 0.29+ these
            # must be email-form ("user@domain"), matching the user's email
            # (bare names are rejected at parse time). Manage membership
            # here for now.
            policy = {
              mode = "file";
              path = pkgs.writeText "headscale-policy.hujson" ''
                {
                  "groups": {
                    "group:admins": ["admin@cwrunix.com", "tln32@case.edu"]
                  },
                  "acls": [
                    {"action": "accept", "src": ["*"], "dst": ["*:*"]}
                  ],
                  "ssh": [
                    {
                      "action": "accept",
                      "src": ["group:admins"],
                      "dst": ["autogroup:member"],
                      "users": ["autogroup:nonroot", "root"]
                    }
                  ]
                }
              '';
            };
          };
        };

        # Web UI + browser SSH, served at https://headplane-zeus.cwrunix.com.
        # Shares authentik's "headscale" OIDC client (same sub claims =>
        # automatic identity linking, per headplane docs). Secrets are bind
        # mounted from the host (sops); the generated config only references
        # their paths.
        services.headplane = {
          enable = true;
          # Patch out the manual "claim an unlinked headscale user" picker:
          # users are provisioned with matching emails by headscale-user-sync
          # (below), so linking is automatic — and nobody can claim an
          # unlinked service/admin user from the picker (or a crafted POST).
          package = pkgs.headplane.overrideAttrs (old: {
            patches = (old.patches or [ ]) ++ [ ../headplane-disable-manual-linking.patch ];
          });
          settings = {
            server = {
              host = "0.0.0.0";
              port = 3000;
              base_url = "https://headplane-zeus.cwrunix.com";
              cookie_secret_path = "/run/secrets/headplane-cookie";
              cookie_secure = true;
            };
            headscale = {
              api_key_path = "/run/secrets/headplane-api-key";
              # url (http://127.0.0.1:8080), public_url (server_url) and
              # config_path (the module's generated config) all default
              # correctly because headscale lives in this same container.
            };
            # The agent joins the tailnet as "headplane-agent" (that user is
            # created at bootstrap) and mints the ephemeral pre-auth keys
            # browser SSH sessions use.
            integration.agent.enabled = true;
            oidc = {
              issuer = "https://authentik-zeus.cwrunix.com/application/o/headscale/";
              client_id = "headscale";
              client_secret_path = "/run/secrets/headscale-oidc";
              disable_api_key_login = true;
            };
          };
        };

        # Mirror authentik users into headscale with their email, so
        # headplane's email-fallback linking always succeeds automatically
        # (the manual claim-picker is patched out — see
        # nixos/headplane-disable-manual-linking.patch). Runs on a timer;
        # idempotent, create-only (never deletes).
        systemd.services.headscale-user-sync = {
          description = "Sync authentik users into headscale (email-matched)";
          after = [ "headscale.service" ];
          wants = [ "headscale.service" ];
          path = [
            config.services.headscale.package
            pkgs.python3
          ];
          serviceConfig.Type = "oneshot";
          script = ''
            python3 ${../headscale-user-sync.py}
          '';
        };

        systemd.timers.headscale-user-sync = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "2min";
            OnUnitActiveSec = "5min";
          };
        };

        system.stateVersion = "25.11";
      };
  };
}
