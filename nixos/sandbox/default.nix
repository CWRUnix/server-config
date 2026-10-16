{ pkgs, inputs, ... }:
let
  # Read-only toolset available inside every user sandbox. Users extend
  # their own environment on top of this with home-manager (the nix
  # daemon socket is bind-mounted in, so builds are untrusted and land
  # in the shared store).
  sandboxProfile = pkgs.buildEnv {
    name = "cwrunix-sandbox-profile";
    paths = with pkgs; [
      bashInteractive
      zsh # the members' login shell (login-sandbox.sh)
      coreutils
      findutils
      gnugrep
      gnused
      gawk
      less
      which
      file
      procps
      diffutils
      nettools # hostname(1)
      glibc.bin # getent(1)
      curl
      wget
      git
      jq
      cacert
      nix
      home-manager
      openssh # provides scp/sftp client + scp server mode for transfers into the sandbox
      # comma with the prebuilt nix-index database baked in (its wrapper
      # sets NIX_INDEX_DATABASE), so `, foo` works with zero setup.
      inputs.nix-index-database.packages.${pkgs.stdenv.system}.comma-with-db
    ];
    pathsToLink = [
      "/bin"
      "/etc"
      "/share"
    ];
  };

  netnsSetup = pkgs.replaceVars ./netns-setup.sh {
    bash = pkgs.bash;
    ip = "${pkgs.iproute2}/bin/ip";
  };

  loginSandbox = pkgs.runCommand "cwrunix-login-sandbox" { } ''
    mkdir -p $out/bin
    substitute ${./login-sandbox.sh} $out/bin/login-sandbox \
      --replace-fail '@bash@' '${pkgs.bash}' \
      --replace-fail '@bwrap@' '${pkgs.bubblewrap}/bin/bwrap' \
      --replace-fail '@unshare@' '${pkgs.util-linux}/bin/unshare' \
      --replace-fail '@slirp4netns@' '${pkgs.slirp4netns}/bin/slirp4netns' \
      --replace-fail '@netnsSetup@' '${netnsSetup}' \
      --replace-fail '@sandboxProfile@' '${sandboxProfile}'
    chmod +x $out/bin/login-sandbox
  '';
in
{
  # sssd forces remote users' shells to this path (see auth/sssd.nix).
  environment.etc."cwrunix/login-sandbox".source = "${loginSandbox}/bin/login-sandbox";

  # Handy for admins debugging the sandbox by hand:
  #   sudo -u someuser /etc/cwrunix/login-sandbox
  environment.systemPackages = with pkgs; [
    bubblewrap
    slirp4netns
  ];

  # Fair-share guardrails so a single sandboxed user can't eat the host.
  # (user-.slice is the template for all per-user slices; bump individual
  # users with `systemctl set-property user-<uid>.slice ...`.)
  systemd.units."user-.slice.d/50-cwrunix-limits.conf".text = ''
    [Slice]
    CPUQuota=200%
    MemoryMax=8G
    TasksMax=512
  '';
}
