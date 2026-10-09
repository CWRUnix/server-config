{ lib, modulesPath, ... }:
{
  # Throwaway QEMU test VM — `nix run .#vm` from the repo root.
  #
  # Differences from the real server:
  #   * no disko/impermanence (single throwaway ext4 disk; the real disk
  #     layout is only exercised at actual install time)
  #   * the temporary sops age key is injected via a 9p share (the flake
  #     app copies ./key.txt into place and passes the virtfs flag)
  #   * cloudflared disabled (placeholder credentials), so the tunnel
  #     ingress is not testable here — use the forwarded ports instead:
  #       - http://localhost:8080  (nginx; set a Host header of
  #         authentik.zeus.cwrunix.com / headscale.zeus.cwrunix.com)
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
  };

  # No real tunnel credentials in the test VM.
  services.cloudflared.enable = lib.mkForce false;

  # No real Cloudflare DNS API token in the test VM either — nginx serves
  # plain HTTP only.
  cwrunix.wildcardTls = false;

  # TEST ONLY: known password for the admin account inside the throwaway VM
  # ("zeus-test"), so console login and sudo work without real credentials.
  users.users.tev.hashedPassword = lib.mkForce "$6$yxN9qlVzA6vaIx1s$RdC8cIhMesUVzeyWFHz3HpxCshQmeTBIe1VHoVgjDI30LthCzmfNPdAfOZNLnhrqnRgpdVYts/jBIij6.PIyE.";

  # Reach nginx via the forwarded port 8080.
  networking.firewall.allowedTCPPorts = [ 80 ];
}
