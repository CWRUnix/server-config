{ pkgs, ... }:
# Declarative authentik bootstrap: runs OpenTofu inside the authentik
# container after the API is up, creating the LDAP stack (stages, flow,
# provider, application, ldapservice account, outpost) and the headscale
# OIDC provider/application — replacing all manual UI setup except users.
#
# Config lives in tofu/ (repo root); state persists in the container's
# /var/lib/authentik-tofu (part of the container state dir, so it travels
# with container backups). Secrets arrive via /run/secrets/authentik-tofu-env
# (sops template, bind-mounted from the host — see nixos/sops.nix).
let
  # nixpkgs doesn't package the authentik provider; fetch the official
  # release binary and use a tofu dev_overrides CLI config (offline-friendly,
  # no registry access needed at runtime).
  authentikTfPlugin = pkgs.stdenvNoCC.mkDerivation {
    pname = "terraform-provider-authentik";
    version = "2026.5.2";
    src = pkgs.fetchurl {
      url = "https://github.com/goauthentik/terraform-provider-authentik/releases/download/v2026.5.2/terraform-provider-authentik_2026.5.2_linux_amd64.zip";
      hash = "sha256-jnqZRTgy4pp2NOZ66WiponIvYoCwnQ0llazBy4Ko5n8=";
    };
    nativeBuildInputs = [ pkgs.unzip ];
    sourceRoot = ".";
    installPhase = "install -Dm755 terraform-provider-authentik_v$version $out/bin/terraform-provider-authentik";
  };

  cliConfig = pkgs.writeText "authentik-tofu-cli.tfrc" ''
    provider_installation {
      dev_overrides {
        "goauthentik/authentik" = "${authentikTfPlugin}/bin"
      }
      direct {}
    }
  '';

  tofuConfig = ../tofu;
in
{
  systemd.services.authentik-tofu = {
    description = "Configure authentik via OpenTofu";
    after = [ "authentik.service" ];
    requires = [ "authentik.service" ];
    wantedBy = [ "multi-user.target" ];

    path = with pkgs; [
      opentofu
      curl
      python3
      rsync
    ];

    environment = {
      TF_CLI_CONFIG_FILE = "${cliConfig}";
      TF_IN_AUTOMATION = "1";
      TF_INPUT = "0";
    };

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      StateDirectory = "authentik-tofu";
      EnvironmentFile = "/run/secrets/authentik-tofu-env";
      Restart = "on-failure";
      RestartSec = "30s";
      # First boot: authentik migrations + initialisation take a while.
      TimeoutStartSec = "15min";
    };

    script = ''
      set -euo pipefail

      echo "waiting for the authentik API..."
      for i in $(seq 1 120); do
        if curl -sf http://localhost:9000/-/health/ready/ > /dev/null; then
          break
        fi
        if [ "$i" -eq 120 ]; then
          echo "authentik API never became ready" >&2
          exit 1
        fi
        sleep 5
      done

      # The default flows/cert/scope mappings are created asynchronously by
      # the worker after the API is already healthy; the tofu data sources
      # need them, so wait until they exist.
      wait_for() {
        for i in $(seq 1 90); do
          if curl -sf -H "Authorization: Bearer $AUTHENTIK_TOKEN" "http://localhost:9000$1" | grep -q "$2"; then
            return 0
          fi
          sleep 5
        done
        echo "timed out waiting for $2 at $1" >&2
        return 1
      }
      wait_for "/api/v3/flows/instances/" "default-invalidation-flow"
      wait_for "/api/v3/flows/instances/" "default-provider-authorization-implicit-consent"
      wait_for "/api/v3/flows/instances/" "default-provider-invalidation-flow"
      wait_for "/api/v3/crypto/certificatekeypairs/" "Self-signed"
      wait_for "/api/v3/propertymappings/provider/scope/" "scope-openid"

      state=/var/lib/authentik-tofu
      mkdir -p "$state"
      # Refresh the config from the nix store (read-only) each run. State
      # (terraform.tfstate) lives in the parent dir, outside the rsync'd
      # config dir.
      rsync -a --delete --chmod=u+w ${tofuConfig}/ "$state/config"/
      cd "$state/config"

      # NB: no `tofu init` — with provider dev_overrides in effect, OpenTofu
      # skips provider resolution and recommends skipping init entirely
      # (this also keeps the container fully offline: no registry access).
      tofu apply -auto-approve -input=false -no-color -state="$state/terraform.tfstate"

      echo "ensuring LDAP outpost token matches sops value..."
      python3 ${./ensure-outpost-token.py}

      echo "ensuring the discord source is on the default login page..."
      python3 ${./ensure-source-on-login.py}
    '';
  };
}
