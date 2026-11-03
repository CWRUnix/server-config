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

  # Baseline containers config inside every sandbox, bound read-only at
  # /etc/containers. cgroups are DISABLED: the sandbox has no cgroupfs and
  # never should (writable cgroup delegation can't be done safely without
  # host-side privileged helpers), and the user-.slice quotas below remain
  # the real enforcement either way. Rootless networking nests another
  # slirp4netns (double NAT) — pasta isn't reachable from a comma-provided
  # podman (its wrapper only hardcodes runtimes/conmon). Users can override
  # any of this via ~/.config/containers/ (home is writable, /etc isn't).
  containersConfig = pkgs.runCommand "cwrunix-containers-config" { } ''
    mkdir -p $out/etc/containers
    ln -s ${containersConf} $out/etc/containers/containers.conf
    ln -s ${policyJson} $out/etc/containers/policy.json
    ln -s ${registriesConf} $out/etc/containers/registries.conf
    ln -s ${storageConf} $out/etc/containers/storage.conf
  '';

  containersConf = pkgs.writeText "containers.conf" ''
    [containers]
    # No cgroupfs in the sandbox; resource limits come from the host's
    # user-.slice instead. --memory/--cpus on `podman run` are no-ops.
    cgroups = "disabled"

    [engine]
    cgroup_manager = "cgroupfs"
    # no journald socket in the sandbox
    events_logger = "file"
    # only crun supports running with cgroups disabled
    runtime = "crun"
    network_cmd_path = "${pkgs.slirp4netns}/bin/slirp4netns"
    # the sandbox has no /var/tmp, and "storage" races first-run storage
    # init; stage image copies on the session's tmpfs /tmp (still bounded
    # by the host's per-slice MemoryMax)
    image_copy_tmp_dir = "/tmp"
    # the stub /sys/fs/cgroup is tmpfs, so podman's probe reports "v1";
    # cgroups are intentionally disabled, and the warning is just noise
    env = [ "PODMAN_IGNORE_CGROUPSV1_WARNING=1" ]

    [network]
    default_rootless_network_cmd = "slirp4netns"
  '';

  policyJson = pkgs.writeText "policy.json" ''
    { "default": [ { "type": "insecureAcceptAnything" } ] }
  '';

  registriesConf = pkgs.writeText "registries.conf" ''
    unqualified-search-registries = ["docker.io"]
  '';

  storageConf = pkgs.writeText "storage.conf" ''
    [storage]
    driver = "overlay"

    [storage.options]
    # The sandbox maps exactly one uid/gid (no subuid delegation is possible
    # under bwrap), so layer files owned by other ids can't be chown'ed;
    # ignore it — everything lands owned by the container's root (= the
    # user's own uid outside).
    ignore_chown_errors = "true"
  '';

  netnsSetup = pkgs.replaceVars ./netns-setup.sh {
    bash = pkgs.bash;
    ip = "${pkgs.iproute2}/bin/ip";
    bindfs = pkgs.bindfs;
  };

  loginSandbox = pkgs.runCommand "cwrunix-login-sandbox" { } ''
    mkdir -p $out/bin
    substitute ${./login-sandbox.sh} $out/bin/login-sandbox \
      --replace-fail '@bash@' '${pkgs.bash}' \
      --replace-fail '@bwrap@' '${pkgs.bubblewrap}/bin/bwrap' \
      --replace-fail '@unshare@' '${pkgs.util-linux}/bin/unshare' \
      --replace-fail '@slirp4netns@' '${pkgs.slirp4netns}/bin/slirp4netns' \
      --replace-fail '@netnsSetup@' '${netnsSetup}' \
      --replace-fail '@containersConfig@' '${containersConfig}' \
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
    bindfs
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
