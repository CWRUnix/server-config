{
  config,
  lib,
  ...
}:
# Stalwart mail server for @cwrunix.com, in its own nixos-container.
#
# Reachability (zeus has no public IP — see nixos/cloudflare.nix):
#   * Webmail/JMAP: Bulwark Lite, served by Stalwart itself as an
#     Application at /webmail, reached at https://mail-zeus.cwrunix.com via
#     the host's nginx + cloudflared (same pattern as the other services).
#   * SMTP/IMAP (TCP 25/465/587/993): forwarded by the Linode relay VPS over
#     the existing frp tunnel (nixos/proxy-relay.nix, proxy/). frp sends a
#     PROXY v2 header so Stalwart sees real sender IPs (SPF/DNSBL checks
#     keep working); the per-listener overrideProxyTrustedNetworks below
#     makes the header mandatory for connections from the frpc source IP.
#   * Outbound: campus egress blocks port 25 and has no PTR, so all
#     non-local mail goes via a Postfix smarthost on the relay VPS
#     (MtaRoute "relay" below). The hop to the VPS rides an frp stcp
#     visitor (10.77.3.1:2587 on the veth gateway), so it is encrypted and
#     needs no SASL/TLS of its own; the VPS originates with the correct
#     HELO/PTR (mail.cwrunix.com, rDNS set in infra/main.tf).
#
# Identity: accounts live under the club's authentik (OIDC directory
# below). Webmail login is "Sign in with SSO" (Bulwark runs the PKCE flow
# against authentik's public "bulwark-webmail" client — see tofu/main.tf);
# thick clients (IMAP/SMTP) use app passwords, which members mint
# themselves in the webmail (account settings). Accounts must exist before
# first login for INBOUND mail to be accepted, so mail-user-sync mirrors
# active authentik users into Stalwart on a timer (create-only, never
# deletes).
#
# DNS: Stalwart manages ONLY the DKIM records itself (dkimManagement
# Automatic + dnsManagement restricted to dkim, using the scoped Cloudflare
# token — this also covers key rotation). MX/SPF/DMARC/A/PTR are static and
# live in infra/main.tf (applied by proxy-provision.service).
#
# The NixOS module is vendored from nixpkgs PR #552103 (the stock module
# only supports Stalwart 0.15's TOML config) — see nixos/stalwart-1x/.
#
# Bootstrap checklist:
#   1. Add to secrets.yaml: mail/admin_password (stalwart fallback admin).
#   2. Deploy. stalwart-provision applies the objects; check with:
#        nixos-container run mail -- stalwart-cli ... (STALWART_URL etc.)
#   3. Linode blocks outbound SMTP ports on new accounts — if the relay
#      VPS can't send, open a Linode support ticket to lift the block.
#   4. The authentik side (public OIDC client) is applied by the in-
#      container tofu bootstrap; the DKIM keys + records self-manage.
# Be lenient with slow first boots (same reasoning as the authentik
# container).
{
  systemd.services."container@mail".serviceConfig.TimeoutStartSec = lib.mkForce "15min";

  containers.mail = {
    autoStart = true;
    privateNetwork = true;
    hostAddress = "10.77.3.1";
    localAddress = "10.77.3.2";

    # NOTE on the Cloudflare token bind mount below: the test VM decrypts
    # the REAL scoped DNS token via the shared sops key. vm.nix therefore
    # OVERRIDES this bind mount with a dummy token file (one that can only
    # fail auth), so a throwaway VM can never issue certs or touch DKIM
    # records in the real zone.
    bindMounts = {
      "/run/secrets/mail-admin" = {
        hostPath = config.sops.secrets."mail/admin_password".path;
        isReadOnly = true;
      };
      # Read by mail-user-sync to list authentik users (akadmin API token).
      "/run/secrets/authentik-api-token" = {
        hostPath = config.sops.secrets."authentik/bootstrap_token".path;
        isReadOnly = true;
      };
      # Scoped DNS token: Stalwart's ACME DNS-01 + DKIM record publishing.
      "/run/secrets/cloudflare-dns-token" = {
        hostPath = config.sops.secrets."cloudflare/dns_api_token".path;
        isReadOnly = true;
      };
    };

    config =
      {
        config,
        pkgs,
        ...
      }:
      let
        # Provision-plan helper: object variants are { "@type" = ...; }.
        variant = type: value: { "@type" = type; } // value;
        # Pinned Bulwark webmail release (bump to update; see the
        # Application object + stalwart-update-apps below).
        bulwarkVersion = "1.21.2";
      in
      {
        disabledModules = [ "services/mail/stalwart.nix" ];
        # the PR ships the service module and the provision module as two
        # separate module-list entries
        imports = [
          ../stalwart-1x
          ../stalwart-1x/provision.nix
        ];

        # DNS via the host's dnsmasq on the veth gateway — same story as
        # the other containers (see nixos/networking.nix).
        networking.resolvconf.enable = false;
        systemd.services.container-resolvconf = {
          description = "Write resolv.conf pointing at the host's dnsmasq";
          wantedBy = [ "multi-user.target" ];
          before = [ "network-online.target" ];
          serviceConfig.Type = "oneshot";
          script = ''
            rm -f /etc/resolv.conf
            printf 'nameserver 10.77.3.1\noptions edns0\n' > /etc/resolv.conf
          '';
        };

        # authentik (OIDC discovery/JWKS for the directory) via the host's
        # nginx (valid LE cert) — same no-cloudflare-hairpin pattern as the
        # other containers.
        networking.hosts."10.77.3.1" = [ "authentik-zeus.cwrunix.com" ];

        networking.firewall.allowedTCPPorts = [
          25 # SMTP (from the relay VPS, via frpc on the host)
          587 # submission (members' clients + authentik, direct via veth)
          465 # submissions
          993 # IMAPS
          8080 # HTTP: webmail/JMAP/webadmin (host nginx proxies here)
        ];

        services.stalwart = {
          enable = true;
          package = pkgs.stalwart_1_0;
          stateVersion = "26.11";
          url = "https://mail-zeus.cwrunix.com";

          # Fallback admin (webadmin at /admin, and the identity the
          # provision + user-sync services authenticate as). Password from
          # sops; the module expects a credential named after the user.
          admin = {
            enable = true;
            username = "admin";
          };
          credentials = {
            admin = "/run/secrets/mail-admin";
            cloudflare-dns = "/run/secrets/cloudflare-dns-token";
          };

          provision = {
            enable = true;
            urls = [ "http://127.0.0.1:8080" ];
            singletons = {
              SystemSettings = {
                defaultHostname = "mail.cwrunix.com";
                defaultDomainId = "#main-domain";
                # Used for the DNS zone data Stalwart computes (we publish
                # the MX record ourselves in infra/main.tf).
                mailExchangers = [
                  {
                    hostname = "mail.cwrunix.com";
                    priority = 10;
                  }
                ];
              };
              # Authenticate against authentik (OIDC). Accounts are still
              # local objects — the directory only validates OIDC tokens.
              Authentication.directoryId = "#authentik-oidc";
              Http = {
                # nginx normalizes X-Forwarded-For to exactly one entry —
                # the real client IP (see the $mail_client_ip map in
                # nginx.nix) — so the webmail's per-IP auth rate
                # limits/bans never key on the shared proxy address. A
                # single-entry XFF is REQUIRED (a forwardedHops underflow
                # is rejected with "Invalid forwarding header", not
                # clamped).
                clientIpSource = "xForwardedFor";
                forwardedHops = 1;
                redirectRoot = "/webmail/";
              };
              # All non-local mail leaves via the relay VPS smarthost (see
              # the header comment); local domains stay local.
              MtaOutboundStrategy.route = {
                match = [
                  {
                    "if" = "is_local_domain(rcpt_domain)";
                    "then" = "'local'";
                  }
                ];
                "else" = "'relay'";
              };
            };
            objects = {
              Tracer = {
                reconcile = true;
                match = [ "@type" ];
                objects.journal = variant "Journal" {
                  enable = true;
                  level = "info";
                };
              };
              NetworkListener = {
                reconcile = true;
                match = [ "name" ];
                objects = {
                  smtp = {
                    name = "smtp";
                    protocol = "smtp";
                    bind = [ "[::]:25" ];
                    implicitTls = false; # STARTTLS
                    overrideProxyTrustedNetworks = [ "10.77.3.1/32" ]; # frpc on the host
                  };
                  submission = {
                    name = "submission";
                    protocol = "smtp";
                    bind = [ "[::]:587" ];
                    implicitTls = false; # STARTTLS
                    overrideProxyTrustedNetworks = [ "10.77.3.1/32" ];
                  };
                  submissions = {
                    name = "submissions";
                    protocol = "smtp";
                    bind = [ "[::]:465" ];
                    implicitTls = true;
                    overrideProxyTrustedNetworks = [ "10.77.3.1/32" ];
                  };
                  imap = {
                    name = "imap";
                    protocol = "imap";
                    bind = [ "[::]:993" ];
                    implicitTls = true;
                    overrideProxyTrustedNetworks = [ "10.77.3.1/32" ];
                  };
                  http = {
                    name = "http";
                    protocol = "http";
                    bind = [ "[::]:8080" ];
                    implicitTls = false; # TLS terminates at the host's nginx
                  };
                };
              };
              Domain = {
                reconcile = true;
                match = [ "name" ];
                objects.main-domain = {
                  name = "cwrunix.com";
                  reportAddressUri = "mailto:postmaster@cwrunix.com";
                  subAddressing = variant "Enabled" { };
                  # LE via DNS-01 (zeus has no public ports for http-01).
                  # Cert covers cwrunix.com + mail.cwrunix.com.
                  certificateManagement = variant "Automatic" {
                    acmeProviderId = "#letsencrypt";
                    subjectAlternativeNames = [ "mail" ];
                  };
                  # Stalwart publishes/rotates ONLY the DKIM records; the
                  # rest of the zone is managed by infra/main.tf. (Schema
                  # "set" types are JSON arrays in the provision plan.)
                  dnsManagement = variant "Automatic" {
                    dnsServerId = "#cloudflare";
                    publishRecords = [ "dkim" ];
                  };
                  dkimManagement = variant "Automatic" { };
                };
              };
              DnsServer = {
                match = [ "@type" ];
                objects.cloudflare = variant "Cloudflare" {
                  description = "scoped DNS token for cwrunix.com (sops)";
                  secret = variant "File" {
                    filePath = "/run/credentials/stalwart.service/cloudflare-dns";
                  };
                };
              };
              AcmeProvider = {
                match = [ "directory" ];
                objects.letsencrypt = {
                  description = "Let's Encrypt";
                  directory = "https://acme-v02.api.letsencrypt.org/directory";
                  challengeType = "Dns01";
                  contact = [ "postmaster@cwrunix.com" ];
                };
              };
              Directory = {
                match = [ "@type" ];
                objects.authentik-oidc = variant "Oidc" {
                  description = "authentik (club SSO)";
                  issuerUrl = "https://authentik-zeus.cwrunix.com/application/o/mail/";
                  lenientIssuerMatch = true;
                  claimUsername = "preferred_username";
                  claimName = "name";
                  claimGroups = "groups";
                  # tln32 -> tln32@cwrunix.com (authentik usernames are not
                  # email-shaped; the mailbox domain is appended).
                  usernameDomain = "cwrunix.com";
                  # authentik sets aud = the client id of the app the token
                  # was issued to; the webmail is the public client below.
                  acceptedAudiences = [ "bulwark-webmail" ];
                  # authentik can't issue Stalwart's interoperable scopes;
                  # its tokens carry only openid/email/profile.
                  unscopedTokens = "interoperable";
                };
              };
              # The webmail's OAuth client at Stalwart (first-party so
              # account settings/app passwords work in the UI). The
              # authentik side of the same client id is in tofu/main.tf.
              OAuthClient = {
                match = [ "clientId" ];
                objects.bulwark-webmail = {
                  clientId = "bulwark-webmail";
                  description = "Bulwark webmail";
                  firstParty = true;
                  redirectUris = [
                    "https://mail-zeus.cwrunix.com/webmail/oauth/callback"
                    "https://mail-zeus.cwrunix.com/webmail/"
                  ];
                };
              };
              # Bulwark Lite, hosted by Stalwart itself at /webmail. Pinned
              # release (Stalwart re-downloads on "update applications" or
              # restart after the cache expires). Bump the tag to update.
              #
              # oauthClientId is deliberately UNSET: setting it makes
              # Bulwark show a generic "Sign in with SSO" button that
              # routes through Stalwart's own /login page — a dead end for
              # our members, whose accounts authenticate via the OIDC
              # directory (no local passwords exist). Without the field
              # the app still defaults to the client id "bulwark-webmail"
              # (registered above as first-party), and the only SSO button
              # left is the useful one: type your full @cwrunix.com
              # address, /api/discover flags it as OIDC-managed, and THAT
              # button goes straight to authentik.
              Application = {
                match = [ "description" ];
                objects.webmail = {
                  description = "Bulwark Webmail";
                  enable = true;
                  resourceUrl = "https://github.com/bulwarkmail/webmail/releases/download/${bulwarkVersion}/bulwark-lite-stalwart.zip";
                  urlPrefix = [ "/webmail" ];
                };
              };
              # Outbound smarthost: the relay VPS's Postfix, reached over
              # an frp stcp visitor on the veth gateway (encrypted by frp;
              # plaintext here is host-local only).
              MtaRoute = {
                match = [ "name" ]; # upsert only; never reconcile (would drop the built-in local/mx routes)
                objects.relay = variant "Relay" {
                  name = "relay";
                  host = "10.77.3.1";
                  port = 2587;
                  protocol = "smtp";
                  implicitTls = false;
                };
              };
              # postmaster@/abuse@/admin@ land here; mail-user-sync keeps
              # akadmin a member. (User accounts themselves are NOT
              # provisioned here — no secret values may touch the nix
              # store; the sync service manages them at runtime.)
              #
              # Groups can't carry a member list in this plan at all (the
              # schema has no such field — membership lives on each user's
              # memberGroupIds), and this set is upsert-only, so group
              # memberships edited at runtime are never clobbered by
              # deploys. frep@ is managed that way: mail-user-sync seeds
              # akadmin as the INITIAL member, after which akadmin runs
              # the list imperatively (Bulwark).
              Account = {
                match = [
                  "name"
                  "domainId"
                ];
                objects = {
                  mail-admins = variant "Group" {
                    name = "admins";
                    domainId = "#main-domain";
                    description = "Club admins; receives postmaster@/abuse@/admin@";
                    aliases = [
                      {
                        enable = true;
                        name = "postmaster";
                        domainId = "#main-domain";
                      }
                      {
                        enable = true;
                        name = "abuse";
                        domainId = "#main-domain";
                      }
                      {
                        enable = true;
                        name = "admin";
                        domainId = "#main-domain";
                      }
                    ];
                  };
                  frep = variant "Group" {
                    name = "frep";
                    domainId = "#main-domain";
                    description = "Frep mailing list";
                  };
                };
              };
            };
          };
        };

        # The provision apply does live network calls (ACME account
        # creation) and aborts on the first failure — race-proof it against
        # early-boot DNS and transient LE/Cloudflare outages. The apply is
        # upsert-idempotent, so retrying is safe.
        systemd.services.stalwart.after = [ "network-online.target" ];
        systemd.services.stalwart.wants = [ "network-online.target" ];
        systemd.services.stalwart-provision.serviceConfig = {
          Restart = "on-failure";
          RestartSec = "30s";
        };

        # Stalwart binds its compiled-in default listeners (25/465/993/8080)
        # at first start and only adopts the provisioned set on restart, so
        # bounce it once after a provision that CHANGED the listener set
        # (stamp = hash of the listener plan; first boot and any later
        # listener edit both trigger exactly one restart).
        systemd.services.stalwart-activate-listeners = {
          description = "Restart Stalwart to bind the provisioned listeners";
          after = [ "stalwart-provision.service" ];
          requires = [ "stalwart-provision.service" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig.Type = "oneshot";
          environment.LISTENER_STAMP = builtins.hashString "sha256" (
            builtins.toJSON config.services.stalwart.provision.objects.NetworkListener.objects
          );
          script = ''
            stamp=/var/lib/stalwart/.listener-stamp
            if [ "$(cat "$stamp" 2>/dev/null)" != "$LISTENER_STAMP" ]; then
              systemctl restart stalwart.service
              mkdir -p "$(dirname "$stamp")"
              echo "$LISTENER_STAMP" > "$stamp"
            fi
          '';
        };

        # Stalwart only (re)downloads Application bundles on restart or the
        # UpdateApps action — creating the object alone mounts nothing, so
        # without this /webmail stays 404 on first boot. Runs UpdateApps
        # until the bundle is actually served (first-boot provision is
        # still converging while this starts, so retry), and again whenever
        # the pinned webmail version changes.
        systemd.services.stalwart-update-apps = {
          description = "Fetch web Application bundles (Bulwark webmail)";
          wantedBy = [ "multi-user.target" ];
          after = [ "stalwart-activate-listeners.service" ];
          wants = [ "stalwart-activate-listeners.service" ];
          serviceConfig = {
            Type = "oneshot";
            LoadCredential = "admin:/run/secrets/mail-admin";
            Restart = "on-failure";
            RestartSec = "60s";
          };
          environment = {
            STALWART_URL = "http://127.0.0.1:8080";
            STALWART_USER = "admin";
            BULWARK_TAG = bulwarkVersion;
          };
          path = with pkgs; [
            curl
            stalwart-cli
          ];
          script = ''
            stamp=/var/lib/stalwart/.bulwark-bundle-tag
            if [ "$(cat "$stamp" 2>/dev/null)" = "$BULWARK_TAG" ] && curl -fsS -o /dev/null "$STALWART_URL/webmail/"; then
              exit 0
            fi
            export STALWART_PASSWORD="$(systemd-creds cat admin)"
            for i in 1 2 3 4 5; do
              stalwart-cli create Action/UpdateApps || true
              sleep 15
              if curl -fsS -o /dev/null "$STALWART_URL/webmail/"; then
                mkdir -p "$(dirname "$stamp")"
                echo "$BULWARK_TAG" > "$stamp"
                exit 0
              fi
            done
            echo "webmail bundle not mounted yet; retrying in a minute" >&2
            exit 1
          '';
        };

        # Mirror active authentik users into Stalwart accounts (create-only)
        # so inbound mail is accepted before a member's first login, and
        # manage the authentik@cwrunix.com service account (SMTP submission
        # for authentik's own mail) — runtime-only work because it handles
        # secret values. See mail-user-sync.py.
        systemd.services.mail-user-sync = {
          description = "Sync authentik users into Stalwart accounts";
          after = [
            "stalwart.service"
            "stalwart-provision.service"
          ];
          wants = [
            "stalwart.service"
            "stalwart-provision.service"
          ];
          path = [ pkgs.python3 ];
          serviceConfig = {
            Type = "oneshot";
            # first boot: authentik's migrations take minutes (slow disks);
            # converge quickly anyway — the 5min timer is the fallback.
            Restart = "on-failure";
            RestartSec = "45s";
          };
          script = ''
            python3 ${../mail-user-sync.py}
          '';
        };

        systemd.timers.mail-user-sync = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "3min";
            OnUnitActiveSec = "5min";
          };
        };

        system.stateVersion = "25.11";
      };
  };
}
