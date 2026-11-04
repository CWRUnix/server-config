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
      zsh # the members' login shell (via cwrunix-sandbox)
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
      # the job-broker client (infrastructure like the newuidmap shim, not
      # a convenience tool): `cwrunix-job submit -- cmd...`
      (pkgs.runCommand "cwrunix-job-client" { } ''
        mkdir -p $out/bin
        ln -s ${sandboxBins}/bin/cwrunix-job $out/bin/cwrunix-job
      '')
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
  # the real enforcement either way. Rootless networking is the podman
  # default (pasta; podman 6 dropped slirp4netns) — the nixpkgs build finds
  # it via its compiled-in helper dir, and it nests fine inside the
  # sandbox's own slirp4netns. Users can override any of this via
  # ~/.config/containers/ (home is writable, /etc isn't).
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
    # the sandbox has no /var/tmp, and "storage" races first-run storage
    # init; stage image copies on the session's tmpfs /tmp (still bounded
    # by the host's per-slice MemoryMax)
    image_copy_tmp_dir = "/tmp"
    # the read-only cgroup2 slice bind is absent (no logind session),
    # /sys/fs/cgroup is a tmpfs stub, which podman 5.x reports as "v1";
    # cgroups are intentionally disabled, so the warning is just noise.
    # (podman >= 6 instead refuses v1 outright — the slice bind in the
    # login sandbox exists to satisfy its startup statfs check.)
    env = [ "PODMAN_IGNORE_CGROUPSV1_WARNING=1" ]
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
    # Tolerate layer files owned by unmappable ids: in the single-uid
    # fallback sandbox they can't be chown'ed, and even in the multi-uid
    # sandbox an image may reference ids outside the member's range.
    ignore_chown_errors = "true"
  '';

  # The sandbox launcher: the cwrunix-sandbox Rust workspace (separate
  # repo). One unprivileged binary handles the login + inner-setup roles;
  # cwrunix-subid-map is the only privileged piece (setuid wrapper below).
  sandboxBins = inputs.cwrunix-sandbox.packages.${pkgs.stdenv.system}.cwrunix-sandbox;

  # /etc/cwrunix/login-sandbox is a thin wrapper pinning the tool paths
  # (sssd forces remote users' shells to it; see auth/sssd.nix).
  loginSandbox = pkgs.writeShellScriptBin "cwrunix-login-sandbox" ''
    exec ${sandboxBins}/bin/cwrunix-sandbox login \
      --bwrap ${pkgs.bubblewrap}/bin/bwrap \
      --slirp4netns ${pkgs.slirp4netns}/bin/slirp4netns \
      --ip ${pkgs.iproute2}/bin/ip \
      --bindfs ${pkgs.bindfs}/bin/bindfs \
      --sandbox-profile ${sandboxProfile} \
      --containers-config ${containersConfig} \
      --subid-map-bin ${sandboxBins}/bin/cwrunix-subid-map \
      --systemctl ${pkgs.systemd}/bin/systemctl \
      --jobs-sock "$XDG_RUNTIME_DIR/cwrunix-jobs.ctl" \
      "$@"
  '';
in
{
  # sssd forces remote users' shells to this path (see auth/sssd.nix).
  environment.etc."cwrunix/login-sandbox".source = "${loginSandbox}/bin/cwrunix-login-sandbox";

  # Setuid root; writes the outer user namespace's full id map for a
  # member's freshly-unshared session (deterministic per-uid range, target
  # must be the caller's own unmapped process — see crates/subid-map/).
  # This is what enables multi-uid rootless containers in the sandbox.
  security.wrappers.cwrunix-subid-map = {
    setuid = true;
    owner = "root";
    group = "root";
    source = "${sandboxBins}/bin/cwrunix-subid-map";
  };

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

  # Background jobs (cwrunix-job inside the sandbox): a per-user,
  # socket-activated, STATELESS broker wraps each submitted command in a
  # fresh login sandbox as a transient user unit. Jobs inherit the
  # user-.slice quotas above and outlive the session because lingering
  # keeps the user manager running (enabled at login via pam_exec below).
  # The broker only ever runs the login wrapper and only ever touches the
  # caller's own user manager.
  systemd.user.sockets.cwrunix-jobsd = {
    description = "CWRUnix job broker socket";
    socketConfig.ListenStream = "%t/cwrunix-jobs.ctl";
  };
  systemd.user.services.cwrunix-jobsd = {
    description = "CWRUnix job broker";
    serviceConfig.ExecStart = "${sandboxBins}/bin/cwrunix-jobsd";
    environment = {
      CWRUNIX_SYSTEMD_RUN = "${pkgs.systemd}/bin/systemd-run";
      CWRUNIX_SYSTEMCTL = "${pkgs.systemd}/bin/systemctl";
      CWRUNIX_LOGIN_SANDBOX = "/etc/cwrunix/login-sandbox";
    };
  };

  # Enable lingering for LDAP members at login (root context via pam_exec)
  # so their user manager — and any scheduled jobs — survives logout. Their
  # login SESSION is still torn down exactly as before; linger only pins
  # user@<uid>.service.
  security.pam.services.login.rules.session.cwrunix-linger = {
    order = 12500;
    control = "optional";
    modulePath = "pam_exec.so";
    args = [
      "${
        pkgs.writeShellApplication {
          name = "cwrunix-enable-linger";
          runtimeInputs = [
            pkgs.coreutils
            pkgs.systemd
          ];
          text = ''
            uid=$(id -u "$PAM_USER" 2>/dev/null) || exit 0
            [ "$uid" -ge 2000 ] && [ "$uid" -lt 12000 ] || exit 0
            loginctl enable-linger "$PAM_USER" >/dev/null 2>&1 || true
          '';
        }
      }/bin/cwrunix-enable-linger"
    ];
  };
}
