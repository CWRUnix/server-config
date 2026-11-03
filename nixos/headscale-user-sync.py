#!/usr/bin/env python3
"""Mirror authentik users into headscale, matched by email.

headplane links SSO logins to headscale users by subject (only present on
OIDC-created users) or by email (fallback). Pre-creating every authentik
user here with their email means headplane linking always succeeds
automatically and the (patched-out) manual claim-picker never has anything
to offer. Idempotent: skips users whose email already exists in headscale.
Never deletes.

Runs inside the headscale container (see nixos/containers/headscale.nix);
talks to the authentik container directly over the host's veth routing.
"""

import json
import subprocess
import sys
import urllib.request

AUTHENTIK_URL = "http://10.77.0.2:9000"  # authentik container
TOKEN_PATH = "/run/secrets/authentik-api-token"


def headscale_json(*args: str):
    out = subprocess.run(
        ["headscale", *args, "-o", "json"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    return json.loads(out)


def main() -> int:
    with open(TOKEN_PATH) as f:
        token = f.read().strip()

    req = urllib.request.Request(
        f"{AUTHENTIK_URL}/api/v3/core/users/?page_size=500",
        headers={"Authorization": f"Bearer {token}"},
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        ak_users = json.load(r)["results"]

    # NOTE: `headscale users list -o json` prints `null` (not []) when the
    # DB has no users yet (fresh install) — coerce to [].
    existing = headscale_json("users", "list") or []
    existing_emails = {u.get("email") for u in existing if u.get("email")}
    existing_names = {u.get("name") for u in existing if u.get("name")}

    for u in ak_users:
        # only real users; skip service accounts and anything without an email
        if u.get("type") not in ("internal", "external"):
            continue
        email = (u.get("email") or "").strip()
        if not email:
            continue
        name = u["username"]
        if email in existing_emails:
            continue
        if name in existing_names:
            print(
                f"WARN: headscale user {name!r} exists with a different email; skipping",
                file=sys.stderr,
            )
            continue
        print(f"creating headscale user {name!r} <{email}>")
        try:
            subprocess.run(
                ["headscale", "users", "create", name, "--email", email],
                check=True,
            )
        except subprocess.CalledProcessError as e:
            # e.g. Discord usernames that aren't valid headscale names
            # (".pmis") — skip the user, don't wedge the whole sync.
            print(f"WARN: failed to create headscale user {name!r}: {e}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
