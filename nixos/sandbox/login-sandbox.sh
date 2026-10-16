#!@bash@/bin/bash
# login-sandbox: forced shell for remote (LDAP) users.
#
# Drops the user into a per-session bubblewrap sandbox:
#   * unshared namespaces: user, mount, pid, ipc, net, uts, cgroup
#     (everything bubblewrap supports; the time namespace is the only
#     one of the 8 left shared — bwrap can't unshare it)
#   * home directory bind-mounted read-write (consistent across sessions)
#   * /nix shared read-only, nix daemon socket read-write -> untrusted
#     nix builds against the host daemon into the shared store;
#     home-manager works
#   * fresh /proc, minimal /dev, tmpfs /tmp, generated minimal /etc
#   * outbound-only internet via slirp4netns (no host/peer visibility)
#   * GPU passthrough: /dev/dri (render nodes) + the host's Mesa driver
#     dir are bound in. nixpkgs' vulkan-loader/libglvnd look in
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
# network setup shim keeps CAP_NET_ADMIN across exec; bwrap then maps
# back to the real uid/gid inside its nested user namespace.
@unshare@ --user --map-root-user --net \
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
  --dev /dev \
  --proc /proc \
  --ro-bind /nix /nix \
  --bind /nix/var/nix/daemon-socket /nix/var/nix/daemon-socket \
  --bind "$home" "$home" \
  --dev-bind-try /dev/dri /dev/dri \
  --ro-bind-try /run/opengl-driver /run/opengl-driver \
  --tmpfs "/run/user/$uid" \
  --ro-bind "$etc/passwd" /etc/passwd \
  --ro-bind "$etc/group" /etc/group \
  --ro-bind "$etc/hosts" /etc/hosts \
  --ro-bind "$etc/resolv.conf" /etc/resolv.conf \
  --ro-bind "$etc/nsswitch.conf" /etc/nsswitch.conf \
  --ro-bind @sandboxProfile@/etc/ssl /etc/ssl \
  --ro-bind-try /run/current-system/sw/share/terminfo /usr/share/terminfo \
  --ro-bind-try /run/current-system/sw/lib/locale /usr/lib/locale \
  --symlink @sandboxProfile@/bin/bash /bin/sh \
  --chdir "$home" \
  -- "$@" <&0 &
sandbox_pid=$!

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
