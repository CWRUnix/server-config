{ config, pkgs, lib, ... }:
# zeus's side of the raw-TCP relay (see proxy/ and infra/ for the VPS
# itself):
#
#   * frpc dials OUT to the relay VPS and re-exposes nginx:443 there, so
#     stock tailscaled clients can complete the TS2021 control handshake
#     that Cloudflare's tunnel corrupts (Upgrade stripped on POST).
#   * proxy-provision.service creates/configures the VPS via OpenTofu
#     (infra/main.tf), moves headscale-zeus.cwrunix.com DNS to it, and
#     pushes the frp auth token over SSH (so the token never sits in the
#     world-readable nix store).
#
# The service is intentionally tolerant: with no linode/api_token in sops
# or no built image at /root/infra-tofu/proxy-image it logs and exits 0
# (retriggered when the secret changes or on next boot); transient API
# failures retry every 10 min.
let
  stateDir = "/root/infra-tofu"; # /root is persisted (hardware/persistence.nix)

  # Same offline dev_overrides pattern as the authentik bootstrap: fetch
  # the provider binaries once at build time, no registry access at
  # runtime. Pinned in infra/main.tf's required_providers.
  linodeTfPlugin = pkgs.stdenvNoCC.mkDerivation {
    pname = "terraform-provider-linode";
    version = "4.7.0";
    src = pkgs.fetchurl {
      url = "https://github.com/linode/terraform-provider-linode/releases/download/v4.7.0/terraform-provider-linode_4.7.0_linux_amd64.zip";
      hash = "sha256-CEB5/4Sf8mnjGCwz8Y6yXu03yTxqOpXvt2G4z3NpWF0=";
    };
    nativeBuildInputs = [ pkgs.unzip ];
    sourceRoot = ".";
    installPhase = "install -Dm755 terraform-provider-linode_v$version $out/bin/terraform-provider-linode";
  };
  cloudflareTfPlugin = pkgs.stdenvNoCC.mkDerivation {
    pname = "terraform-provider-cloudflare";
    version = "5.28.0";
    src = pkgs.fetchurl {
      url = "https://github.com/cloudflare/terraform-provider-cloudflare/releases/download/v5.28.0/terraform-provider-cloudflare_5.28.0_linux_amd64.zip";
      hash = "sha256-IW4D4N1wL0vikoBYQpA4jH/tDUvrCpmPPBIpy3QWa3s=";
    };
    nativeBuildInputs = [ pkgs.unzip ];
    sourceRoot = ".";
    installPhase = "install -Dm755 terraform-provider-cloudflare_v$version $out/bin/terraform-provider-cloudflare";
  };

  cliConfig = pkgs.writeText "infra-tofu-cli.tfrc" ''
    provider_installation {
      dev_overrides {
        "linode/linode" = "${linodeTfPlugin}/bin"
        "cloudflare/cloudflare" = "${cloudflareTfPlugin}/bin"
      }
      direct {}
    }
  '';
in
{
  # frpc: raw-TCP relay of local nginx:443 to the VPS's :443. The server
  # address is only known after provisioning, so it comes from a runtime
  # env file; before the first successful provision the unit fails fast
  # ("Failed to load environment files") and proxy-provision restarts it
  # once it has written the address.
  services.frp.instances.relay = {
    enable = true;
    role = "client";
    environmentFiles = [
      config.sops.templates."infra-tofu-env".path
      "${stateDir}/frpc-addr.env"
    ];
    settings = {
      serverAddr = "{{ .Envs.FRP_SERVER_ADDR }}";
      serverPort = 7000;
      auth.method = "token";
      auth.token = "{{ .Envs.FRP_TOKEN }}";
      proxies = [
        {
          name = "headscale-https";
          type = "tcp";
          localIP = "127.0.0.1";
          localPort = 443;
          remotePort = 443;
        }
      ];
    };
  };

  systemd.services.proxy-provision = {
    description = "Provision the Linode raw-TCP relay + headscale DNS record";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    path = with pkgs; [
      opentofu
      curl
      jq
      openssh
      rsync
    ];

    environment = {
      TF_CLI_CONFIG_FILE = "${cliConfig}";
      TF_IN_AUTOMATION = "1";
      TF_INPUT = "0";
      # linode_image upload uses the beta API.
      LINODE_API_VERSION = "v4beta";
    };

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      EnvironmentFile = config.sops.templates."infra-tofu-env".path;
      Restart = "on-failure";
      RestartSec = "10min";
      TimeoutStartSec = "30min"; # the image upload can be slow
    };

    script = ''
      set -euo pipefail
      state=${stateDir}
      mkdir -p "$state"

      if [ -z "''${TF_VAR_linode_token:-}" ]; then
        echo "linode/api_token is empty in sops — skipping relay provisioning"
        echo "(the service re-runs automatically when the secret changes)"
        exit 0
      fi

      if [ ! -e "$state/proxy-image" ]; then
        echo "no relay image at $state/proxy-image yet." >&2
        echo "build + place it with:" >&2
        echo "  nix build .#proxy-image --out-link $state/proxy-image" >&2
        echo "then: systemctl restart proxy-provision" >&2
        exit 0
      fi
      img=$(echo "$state"/proxy-image/*.img.gz)

      # Throwaway root password (SSH-key-only box; the Linode API just
      # requires the field). Generated once, persisted with the state.
      if [ ! -s "$state/root-pass" ]; then
        tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32 > "$state/root-pass"
        chmod 600 "$state/root-pass"
      fi

      # Dedicated provisioning keypair, installed on the instance via the
      # Linode API's authorized_keys.
      if [ ! -s "$state/provision-key" ]; then
        ssh-keygen -t ed25519 -N "" -C zeus-proxy-provision -f "$state/provision-key" -q
      fi

      # Resolve the Cloudflare zone id (the token is zone-scoped; the
      # name-filtered lookup works with Zone:Read on this zone).
      cf_api="https://api.cloudflare.com/client/v4"
      cf_auth="Authorization: Bearer $TF_VAR_cloudflare_api_token"
      zone_id=$(curl -fsS "$cf_api/zones?name=cwrunix.com" -H "$cf_auth" | jq -r '.result[0].id')
      if [ -z "$zone_id" ] || [ "$zone_id" = "null" ]; then
        echo "error: could not resolve zone id for cwrunix.com" >&2
        exit 1
      fi

      # Remove the legacy tunnel CNAME for headscale-zeus so tofu can
      # create the A record (the dns-routes service only manages the
      # remaining tunnel hostnames; it never deletes).
      record_name="headscale-zeus.cwrunix.com"
      old=$(curl -fsS "$cf_api/zones/$zone_id/dns_records?type=CNAME&name=$record_name" -H "$cf_auth" | jq -r '.result[0].id // empty')
      if [ -n "$old" ]; then
        curl -fsS -X DELETE "$cf_api/zones/$zone_id/dns_records/$old" -H "$cf_auth" > /dev/null
        echo "removed legacy tunnel CNAME for $record_name"
      fi

      export TF_VAR_cloudflare_zone_id="$zone_id"
      export TF_VAR_image_path="$img"
      export TF_VAR_root_pass="$(cat "$state/root-pass")"
      export TF_VAR_provision_ssh_pubkey="$(cat "$state/provision-key.pub")"

      rsync -a --delete ${../infra}/ "$state/workdir/"
      tofu -chdir="$state/workdir" init -input=false -no-color
      tofu -chdir="$state/workdir" apply -auto-approve -input=false -no-color
      ip=$(tofu -chdir="$state/workdir" output -raw proxy_ip)
      echo "relay provisioned at $ip"

      # Point frpc at the (possibly new) relay address.
      printf 'FRP_SERVER_ADDR=%s\n' "$ip" > "$state/frpc-addr.env"
      chmod 600 "$state/frpc-addr.env"
      systemctl restart frp-relay.service

      # Push the frp auth token to the relay (kept out of the image, which
      # is world-readable in the nix store).
      echo "waiting for ssh on the relay..."
      for i in $(seq 1 30); do
        if ssh -i "$state/provision-key" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 root@"$ip" true 2>/dev/null; then
          break
        fi
        if [ "$i" -eq 30 ]; then
          echo "error: relay ssh never came up" >&2
          exit 1
        fi
        sleep 10
      done
      printf 'FRP_TOKEN=%s\n' "$FRP_TOKEN" | ssh -i "$state/provision-key" -o StrictHostKeyChecking=accept-new root@"$ip" \
        'mkdir -p /etc/frp && cat > /etc/frp/frps.env && chmod 600 /etc/frp/frps.env && systemctl restart frp-server'
      echo "relay configured; frpc should now be connected"
    '';
  };
}
