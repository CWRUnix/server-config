#!@bash@/bin/bash
# login-sandbox: forced shell for remote (LDAP) users.
#
# Drops the user into a per-session bubblewrap sandbox:
#   * unshared namespaces: user, mount, pid, ipc, net, uts, cgroup
#     (everything bubblewrap supports; the time namespace is the only
#     one of the 8 left shared — bwrap can't unshare it)
#   * home directory bind-mounted read-write (consistent across sessions)
#   * /nix is a per-session READ-ONLY FUSE MIRROR (bindfs), not a host bind
#     mount: page-cache-corrupting kernel exploits of the Dirty Pipe family
#     (e.g. ZDI-CAN-33367) can rewrite the cached copy of any readable file,
#     and a bind mount shares the host's page cache for the store — poison
#     a store path there and the next root process to execute it on the
#     host runs attacker's code. FUSE inodes are session-private, so such
#     corruption is confined to the attacker's own view. The nix daemon
#     socket remains a direct bind, so builds are still untrusted and land
#     in the shared store as before — and since the daemon reads the store
#     host-side, builds pay no FUSE overhead; only client-side store reads
#     (exec, dynamic linking, flake eval) go through the mirror. Nix and
#     home-manager keep working.
#   * podman works out of the box (e.g. via `, podman`): /etc/containers is
#     a read-only baseline config with cgroups DISABLED — there is no
#     cgroupfs in the sandbox and there shouldn't be (writable cgroup
#     delegation can't be done safely here; the host's user-.slice quotas
#     remain the enforcement, so per-container --memory/--cpus are no-ops).
#     /dev/net/tun covers nested slirp4netns container networking and
#     /dev/fuse covers fuse-overlayfs. Note: single-uid containers only —
#     the sandbox maps exactly one uid and setuid newuidmap can't work
#     under bwrap, so root-in-container is the user's own uid outside.
#   * fresh /proc, minimal /dev, tmpfs /tmp, generated minimal /etc; /sys is
#     an EMPTY tmpfs — sysfs can't be mounted in a user namespace, and the
#     host's buys nothing here. The one exception: /sys/fs/cgroup is a
#     read-only bind of the user's OWN systemd slice
#     (user.slice/user-$uid.slice) when a logind session exists — podman >= 6
#     fatally refuses to start unless statfs() there reports cgroup2, and a
#     userns can't mount a fresh cgroup2 ("Mount too revealing"). The bind
#     exposes nothing beyond the user's own session cgroups, and ro + file
#     ownership mean no cgroup writes are possible (matching the disabled
#     cgroups policy; falls back to an empty stub dir if absent).
#   * outbound-only internet via slirp4netns (no host/peer visibility)
#   * GPU passthrough: /dev/dri (render nodes) + the host's Mesa driver
#     dir are bound in — the latter re-sourced through the FUSE mirror like
#     every other store path (a direct bind would reopen the shared
#     page-cache hole). nixpkgs' vulkan-loader/libglvnd look in
#     /run/opengl-driver by default, so any nix-built app gets hardware
#     Vulkan/GL without knowing anything about our driver setup. Absent
#     GPU (test VM) -> the -try binds skip silently.
set -euo pipefail

user="$(id -un)"
uid="$(id -u)"
gid="$(id -g)"
home="$(getent passwd "$user" | cut -d: -f6)"

if [ -z "$home" ] || [ ! -d "$home" ]; then
  echo "login-sandbox: $user has no usable home directory ($home)" >&2
  exit 1
fi

# Members' login shell is zsh (bash remains available in the profile for
# scripts and for anyone who prefers it).
inner_shell="@sandboxProfile@/bin/zsh"
sandbox_profile="@sandboxProfile@"
containers_config="@containersConfig@"

# sshd invokes the login shell either with no args (interactive login) or
# as `<shell> -c <command>` (ssh host cmd, scp, ...). Both run sandboxed.
if [ "${1:-}" = "-c" ]; then
  set -- "$inner_shell" -c "${2:-}"
else
  set -- "$inner_shell" -l
fi

# Minimal per-user /etc, generated at login. It lives in the session
# runtime dir so logind cleans it up when the last session ends.
runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$uid}"
if [ -d "$runtime_dir" ] && [ -w "$runtime_dir" ]; then
  etc="$(mktemp -d "$runtime_dir/login-sandbox.XXXXXX")"
else
  etc="$(mktemp -d /tmp/login-sandbox.XXXXXX)"
fi

# Mountpoint for the per-session FUSE mirror of the store (mounted by
# netns-setup.sh inside the outer namespace). Also referenced by the FUSE-
# sourced bwrap binds below, so all three stay in sync.
mkdir "$etc/nix"
export CWRUNIX_NIX_FUSE_MNT="$etc/nix"

group="$(getent group "$gid" | cut -d: -f1 || true)"
group="${group:-users}"

cat > "$etc/passwd" <<EOF
root:x:0:0:root:/root:/bin/bash
$user:x:$uid:$gid:$user:$home:$inner_shell
nobody:x:65534:65534:nobody:/nonexistent:/sbin/nologin
EOF

cat > "$etc/group" <<EOF
root:x:0:
$group:x:$gid:
nogroup:x:65534:
EOF

# 10.0.2.3 is slirp4netns' built-in DNS resolver.
printf 'nameserver 10.0.2.3\noptions edns0\n' > "$etc/resolv.conf"
printf '127.0.0.1 localhost\n::1 localhost\n' > "$etc/hosts"
printf 'passwd: files\ngroup: files\nshadow: files\nhosts: files dns\n' > "$etc/nsswitch.conf"

# Host-store-sourced conveniences are resolved at login and rebound THROUGH
# THE FUSE MIRROR ("$etc/nix<store path>") — a direct bind would share the
# host's page cache for those paths, reopening the hole the mirror closes.
# -try semantics are preserved for anything absent (e.g. GPU-less test VM)
# or not a store path.
resolved_binds=()
for pair in \
  "/run/opengl-driver:/run/opengl-driver" \
  "/run/current-system/sw/share/terminfo:/usr/share/terminfo" \
  "/run/current-system/sw/lib/locale:/usr/lib/locale"; do
  src_host="${pair%%:*}"
  dest="${pair#*:}"
  resolved="$(readlink -f "$src_host" 2>/dev/null || true)"
  case "$resolved" in
    /nix/store/*) resolved_binds+=(--ro-bind "$etc/nix${resolved#/nix}" "$dest") ;;
    *) resolved_binds+=(--ro-bind-try "$src_host" "$dest") ;;
  esac
done

sandbox_pid=""
slirp_pid=""
cleanup() {
  [ -n "$slirp_pid" ] && kill "$slirp_pid" 2>/dev/null || true
  [ -n "$sandbox_pid" ] && kill "$sandbox_pid" 2>/dev/null || true
}
trap cleanup EXIT

# The sandbox runs in the background so slirp4netns can attach to its
# network namespace from the outside (it cannot be started from within;
# it enters the namespace and hands over the tap fd). unshare(1) runs
# WITHOUT --fork so the spawned pid is the process living in the new
# namespaces. The outer user namespace maps the user to root so the
# setup shim keeps CAP_NET_ADMIN + CAP_SYS_ADMIN (the latter for the FUSE
# mount) across exec; bwrap then maps back to the real uid/gid inside its
# nested user namespace. --mount --propagation private keeps the
# per-session FUSE staging mount off the host's mount table.
@unshare@ --user --map-root-user --net --mount --propagation private \
  @bash@/bin/bash @netnsSetup@ \
  @bwrap@ \
  --unshare-user-try \
  --unshare-ipc \
  --unshare-pid \
  --unshare-uts \
  --unshare-cgroup-try \
  --die-with-parent \
  --uid "$uid" \
  --gid "$gid" \
  --clearenv \
  --setenv HOME "$home" \
  --setenv USER "$user" \
  --setenv LOGNAME "$user" \
  --setenv SHELL "$inner_shell" \
  --setenv TERM "${TERM:-xterm-256color}" \
  --setenv LANG "en_US.UTF-8" \
  --setenv PATH "@sandboxProfile@/bin:$home/.nix-profile/bin:$home/.local/state/nix/profile/bin:/nix/var/nix/profiles/default/bin" \
  --setenv NIX_CONFIG "experimental-features = nix-command flakes" \
  --setenv NIX_SSL_CERT_FILE /etc/ssl/certs/ca-bundle.crt \
  --setenv SSL_CERT_FILE /etc/ssl/certs/ca-bundle.crt \
  --setenv LOCALE_ARCHIVE /usr/lib/locale/locale-archive \
  --setenv XDG_RUNTIME_DIR "/run/user/$uid" \
  --hostname zeus \
  --tmpfs /tmp \
  --tmpfs /sys \
  --dir /sys/fs/cgroup \
  --ro-bind-try "/sys/fs/cgroup/user.slice/user-$uid.slice" /sys/fs/cgroup \
  --dev /dev \
  --dev-bind-try /dev/net/tun /dev/net/tun \
  --dev-bind-try /dev/fuse /dev/fuse \
  --proc /proc \
  --ro-bind "$etc/nix" /nix \
  --bind /nix/var/nix/daemon-socket /nix/var/nix/daemon-socket \
  --bind "$home" "$home" \
  --dev-bind-try /dev/dri /dev/dri \
  --tmpfs "/run/user/$uid" \
  --ro-bind "$etc/passwd" /etc/passwd \
  --ro-bind "$etc/group" /etc/group \
  --ro-bind "$etc/hosts" /etc/hosts \
  --ro-bind "$etc/resolv.conf" /etc/resolv.conf \
  --ro-bind "$etc/nsswitch.conf" /etc/nsswitch.conf \
  --ro-bind "$etc/nix${sandbox_profile#/nix}/etc/ssl" /etc/ssl \
  --ro-bind "$etc/nix${containers_config#/nix}/etc/containers" /etc/containers \
  "${resolved_binds[@]}" \
  --symlink @sandboxProfile@/bin/bash /bin/sh \
  --chdir "$home" \
  -- "$@" <&0 &
sandbox_pid=$!

# Wait until the child has actually performed its unshare() before starting
# slirp4netns: namespace handles are compared by inode, so polling
# /proc/<pid>/ns/net until it differs from ours closes the race where
# slirp4netns grabs a handle to the HOST netns and fails setns with EPERM.
for _ in $(seq 1 200); do
  [ -d "/proc/$sandbox_pid/ns" ] || break # child died; slirp will fail loudly
  [ /proc/self/ns/net -ef "/proc/$sandbox_pid/ns/net" ] || break
  sleep 0.05
done

# Outbound-only internet for the sandbox (NAT via 10.0.2.0/24; access to
# the host's loopback — and thereby host-local and container services —
# is blocked). Stdout/stderr go to the void: its startup banner would
# otherwise pollute every login, and holding the ssh channel's stdout
# open would delay "Connection closed" when the session ends.
# NB: the sandbox above needs an explicit `<&0` — this script runs
# non-interactively under sshd, and background jobs in non-interactive
# shells get stdin redirected from /dev/null by default, which would make
# an interactive inner shell exit on EOF immediately.
@slirp4netns@ --mtu=65520 --disable-host-loopback "$sandbox_pid" tap0 >/dev/null 2>&1 &
slirp_pid=$!

wait "$sandbox_pid"
