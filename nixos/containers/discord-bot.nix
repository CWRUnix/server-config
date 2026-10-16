{ config, lib, pkgs, inputs, ... }:
# CWRUnix Discord bot (separate repo, imported as a flake input — see
# flake.nix): currently just the self-service /reset-password slash
# command that mints an authentik recovery link and replies ephemerally.
# Gateway (websocket) mode — the bot dials OUT to Discord, so it needs NO
# public ingress, nginx vhost, or DNS record at all.
#
# It runs in its own nixos-container because it holds two powerful tokens
# (Discord bot token + an authentik admin API token); the container is the
# blast-radius boundary. TODO: a dedicated authentik service account with
# only user-recovery + connection-read permissions instead of the akadmin
# bootstrap token.
#
# One-time setup (Discord developer portal, on the EXISTING OAuth app):
#   1. Bot -> Reset Token -> copy into sops "discord/bot_token"
#   2. OAuth2 -> URL Generator: scopes "bot" + "applications.commands",
#      no bot permissions needed -> invite to the club guild
# Until the token is set the service crash-loops with a clear log line.
{
  systemd.services."container@discord-bot".serviceConfig.TimeoutStartSec = lib.mkForce "15min";

  containers.discord-bot = {
    autoStart = true;
    privateNetwork = true;
    hostAddress = "10.77.2.1";
    localAddress = "10.77.2.2";

    bindMounts."/run/secrets/discord-bot-env" = {
      hostPath = config.sops.templates."discord-bot-env".path;
      isReadOnly = true;
    };

    config =
      { ... }:
      {
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
            printf 'nameserver 10.77.2.1\noptions edns0\n' > /etc/resolv.conf
          '';
        };

        # authentik API via the host's nginx (valid LE cert) — same
        # pattern as the headscale container; no cloudflare hairpin.
        networking.hosts."10.77.2.1" = [ "authentik-zeus.cwrunix.com" ];

        systemd.services.cwrunix-bot = {
          description = "CWRUnix Discord bot";
          wantedBy = [ "multi-user.target" ];
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          serviceConfig = {
            ExecStart = "${inputs.cwrunix-bot.packages.x86_64-linux.default}/bin/cwrunix_bot";
            EnvironmentFile = "/run/secrets/discord-bot-env";
            Restart = "on-failure";
            RestartSec = "30s";
            DynamicUser = true;
            # Hardening: the bot only makes outbound HTTPS connections.
            ProtectSystem = "strict";
            ProtectHome = true;
            PrivateTmp = true;
            ProtectKernelTunables = true;
            ProtectKernelModules = true;
            ProtectControlGroups = true;
            RestrictAddressFamilies = [
              "AF_INET"
              "AF_INET6"
              "AF_UNIX"
            ];
            NoNewPrivileges = true;
          };
        };

        system.stateVersion = "25.11";
      };
  };
}
