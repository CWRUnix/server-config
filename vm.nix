{ lib, modulesPath, ... }:
{
  # Throwaway QEMU test VM — `nix run .#vm` from the repo root.
  #
  # Differences from the real server:
  #   * no disko/impermanence (single throwaway ext4 disk; the real disk
  #     layout is only exercised at actual install time)
  #   * the temporary sops age key is injected via a 9p share (the flake
  #     app copies ./key.txt into place and passes the virtfs flag)
  #   * cloudflared runs with the real credentials, so the tunnel ingress
  #     IS testable here; nginx is also reachable via forwarded ports:
  #       - http://localhost:8080  (plain; set a Host header)
  #       - https://localhost:8443 (TLS; e.g. curl --resolve
  #         authentik-zeus.cwrunix.com:8443:127.0.0.1 https://...)
  #       - ssh -p 2222 tev@localhost
  imports = [ (modulesPath + "/virtualisation/qemu-vm.nix") ];

  disko.enableConfig = lib.mkForce false;
  environment.persistence = lib.mkForce { };

  sops.age.keyFile = lib.mkForce "/var/lib/sops-nix/key.txt";

  virtualisation = {
    memorySize = 4096;
    cores = 4;
    diskSize = 8192;
    graphics = false;

    forwardPorts = [
      {
        from = "host";
        host.port = 8080;
        guest.port = 80;
      }
      {
        from = "host";
        host.port = 8443;
        guest.port = 443;
      }
      {
        from = "host";
        host.port = 2222;
        guest.port = 22;
      }
    ];

    # Populated at launch by the flake app (see flake.nix).
    # neededForBoot: sops decrypts during early activation, before ordinary
    # mounts happen.
    fileSystems."/var/lib/sops-nix" = {
      device = "sopskey";
      fsType = "9p";
      neededForBoot = true;
      options = [
        "trans=virtio"
        "version=9p2000.L"
        "ro"
        "x-systemd.requires=modprobe@9pnet_virtio.service"
      ];
    };

    # ACME certs persist across test VM rebuilds/wipes via a 9p share with
    # the host (./.vm-acme). mapped-file keeps VM-side ownership/permissions
    # (acme:nginx) virtual instead of failing chowns on the host fs.
    fileSystems."/var/lib/acme" = {
      device = "acmedir";
      fsType = "9p";
      options = [
        "trans=virtio"
        "version=9p2000.L"
        "x-systemd.requires=modprobe@9pnet_virtio.service"
      ];
    };

    # NOTE: container state (/var/lib/nixos-containers) is deliberately NOT
    # shared this way — postgres on 9p proved unreliable (authentik's
    # settings import races and migrate crash-loops). To carry VM state to
    # the real server, use a tarball instead (chattr -i is needed because
    # nixos-containers marks var/empty immutable):
    #   VM:     sudo systemctl stop container@authentik
    #           sudo tar cpf - -C /var/lib nixos-containers/authentik > authentik-state.tar
    #   server: sudo systemctl stop container@authentik 2>/dev/null
    #           sudo chattr -i /persist/var/lib/nixos-containers/authentik/var/empty 2>/dev/null
    #           sudo rm -rf /persist/var/lib/nixos-containers/authentik
    #           sudo tar xpf authentik-state.tar -C /persist/var/lib/nixos-containers/ --strip-components=1
    #
    # ACME state: on the real server /var/lib/acme persists via /persist and
    # fresh certs self-issue; copying the VM's certs is optional. If you do,
    # copy with trailing slashes / rsync -a — the lego account lives in the
    # .lego DOTDIR, which a `cp -r *` glob silently skips, and certs without
    # their account fail with "could not resolve account with key".
  };

  # No real tunnel credentials in the test VM: never join the production
  # tunnel (two connectors would load-balance live traffic into the
  # throwaway VM), and never touch real Cloudflare DNS records.
  services.cloudflared.enable = lib.mkForce false;
  systemd.services.cloudflared-dns-routes.wantedBy = lib.mkForce [ ];

  # No real Cloudflare DNS API token in the test VM either — nginx serves
  # plain HTTP only if originTls is disabled. With it on, ACME runs against
  # the Let's Encrypt staging CA (untrusted certs, but exercises issuance):
  cwrunix.originTls = lib.mkForce false;
  # security.acme.defaults.server = "https://acme-staging-v02.api.letsencrypt.org/directory";

  # TEST ONLY: known password for the admin account inside the throwaway VM
  # ("zeus-test"), so console login and sudo work without real credentials.
  users.users.tev.hashedPassword = lib.mkForce "$6$yxN9qlVzA6vaIx1s$RdC8cIhMesUVzeyWFHz3HpxCshQmeTBIe1VHoVgjDI30LthCzmfNPdAfOZNLnhrqnRgpdVYts/jBIij6.PIyE.";

  # Reach nginx via the forwarded ports 8080 (http) and 8443 (https).
  networking.firewall.allowedTCPPorts = [
    80
    443
  ];
}
