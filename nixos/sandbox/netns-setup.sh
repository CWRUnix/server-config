#!@bash@/bin/bash
# Runs inside the outer user+net+mount namespace created by unshare (see
# login-sandbox.sh), as root-in-that-namespace (hence CAP_NET_ADMIN and
# CAP_SYS_ADMIN). Brings up loopback, waits for slirp4netns (started from
# the outside by the parent wrapper) to create tap0, configures it, mounts
# the per-session read-only FUSE mirror of the nix store, then runs bwrap
# (as a child, NOT via exec: bindfs is in this process's mount namespace
# rather than bwrap's pid namespace, so it would survive the session — the
# EXIT trap reaps it. This PID stays alive either way, so slirp4netns
# still exits with the session).
set -euo pipefail

@ip@ link set dev lo up

for _ in $(seq 1 100); do
  @ip@ link show dev tap0 >/dev/null 2>&1 && break
  sleep 0.1
done

if ! @ip@ link show dev tap0 >/dev/null 2>&1; then
  echo "login-sandbox: warning: slirp4netns did not create tap0; continuing without network" >&2
else
  @ip@ addr add 10.0.2.100/24 dev tap0
  @ip@ link set tap0 up
  @ip@ route add default via 10.0.2.2
fi

mnt_is_up() {
  local want="$1" mnt
  while read -r _ mnt _; do
    [ "$mnt" = "$want" ] && return 0
  done < /proc/self/mounts
  return 1
}

# Read-only FUSE mirror of /nix: page-cache-isolates the store from the
# host (see login-sandbox.sh for the rationale). Runs as euid 0 in this
# user namespace, so libfuse does a direct mount(2) — no setuid fusermount
# needed. -f keeps bindfs a child of this process; when the session's
# private mount namespace dies the FUSE connection closes and bindfs exits
# on its own. `ro` is enforced at kernel level, so not even a protocol-level
# write can reach the real store. entry/attr caching is aggressive because
# store paths are immutable; negative_timeout stays short so paths freshly
# added by the host nix daemon (the user's own builds) show up immediately.
@bindfs@/bin/bindfs -f \
  -o ro,entry_timeout=300,attr_timeout=300,negative_timeout=1 \
  /nix "$CWRUNIX_NIX_FUSE_MNT" &
bindfs_pid=$!

for _ in $(seq 1 100); do
  mnt_is_up "$CWRUNIX_NIX_FUSE_MNT" && break
  kill -0 "$bindfs_pid" 2>/dev/null || break # bindfs died; don't wait
  sleep 0.05
done
if ! mnt_is_up "$CWRUNIX_NIX_FUSE_MNT"; then
  echo "login-sandbox: error: FUSE mirror of /nix failed to mount" >&2
  exit 1
fi

# bindfs predates bwrap's pid namespace, so the namespace teardown that
# kills leftover user processes on logout doesn't reach it; reap it here.
# (SIGKILL of this process would still leak it, but the parent wrapper only
# ever sends SIGTERM.)
trap 'kill "$bindfs_pid" 2>/dev/null || true' EXIT

# NB: <&0 is required — background jobs in a non-interactive shell get
# stdin forced to /dev/null, which would make an interactive inner shell
# exit on EOF immediately.
"$@" <&0 &
child_pid=$!
wait "$child_pid"
