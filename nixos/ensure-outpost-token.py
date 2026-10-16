# Ensures the LDAP outpost's API token (auto-created by authentik when the
# outpost is created) has the key our sops secret "authentik/ldap_outpost_token"
# holds, so the authentik-ldap service can authenticate. Idempotent.
#
# Env (from /run/secrets/authentik-tofu-env): AUTHENTIK_URL, AUTHENTIK_TOKEN,
# TF_VAR_ldap_outpost_token.
import json
import os
import sys
import urllib.error
import urllib.request

BASE = os.environ["AUTHENTIK_URL"].rstrip("/")
TOKEN = os.environ["AUTHENTIK_TOKEN"]
DESIRED = os.environ["TF_VAR_ldap_outpost_token"]


def api(path, method="GET", data=None):
    req = urllib.request.Request(BASE + path, method=method)
    req.add_header("Authorization", f"Bearer {TOKEN}")
    body = None
    if data is not None:
        req.add_header("Content-Type", "application/json")
        body = json.dumps(data).encode()
    try:
        with urllib.request.urlopen(req, data=body) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise


outposts = api("/api/v3/outposts/instances/")["results"]
ldap_outposts = [o for o in outposts if o["type"] == "ldap"]
if len(ldap_outposts) != 1:
    sys.exit(f"expected exactly 1 LDAP outpost, found {len(ldap_outposts)}")
identifier = f"ak-outpost-{ldap_outposts[0]['pk']}-api"

current = api(f"/api/v3/core/tokens/{identifier}/view_key/")
if current is None:
    # Token not lazily created yet (shouldn't happen — outpost creation
    # triggers it) — create it for the outpost's service user.
    username = f"ak-outpost-{ldap_outposts[0]['pk']}"
    users = api(f"/api/v3/core/users/?username={username}")["results"]
    if len(users) != 1:
        sys.exit(f"outpost user {username} not found")
    api("/api/v3/core/tokens/", "POST", {
        "identifier": identifier,
        "user": users[0]["pk"],
        "intent": "api",
        "expiring": False,
        "description": "Managed by authentik-bootstrap (nixos/authentik-bootstrap.nix)",
    })
    current = api(f"/api/v3/core/tokens/{identifier}/view_key/")
    if current is None:
        sys.exit("failed to create outpost token")

if current["key"] == DESIRED:
    print("outpost token key already matches sops value")
else:
    api(f"/api/v3/core/tokens/{identifier}/set_key/", "POST", {"key": DESIRED})
    print("outpost token key updated to sops value")
