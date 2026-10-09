#!@bash@/bin/bash
# Runs inside the outer user+net namespace created by unshare (see
# login-sandbox.sh), as root-in-that-namespace (hence CAP_NET_ADMIN).
# Brings up loopback, waits for slirp4netns (started from the outside by
# the parent wrapper) to create tap0, configures it, then hands off to
# bwrap via exec (keeping this PID so slirp4netns exits with the session).
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

exec "$@"
