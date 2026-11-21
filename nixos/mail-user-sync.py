#!/usr/bin/env python3
"""Mirror authentik users into Stalwart mail accounts.

Stalwart authenticates members against authentik via its OIDC directory
(see containers/mail.nix), but accounts must EXIST locally before first
login or inbound mail to them bounces. This mirrors every active authentik
user into a Stalwart User account (<username>@cwrunix.com). Idempotent,
create-only: accounts are never deleted (a deactivated authentik user
keeps their mailbox but can no longer authenticate).

Also puts akadmin into the "admins" group (postmaster@/abuse@/admin@
aliases land there) — that membership can't be statically provisioned
because the provision plan lives in the world-readable nix store and the
sync owns all runtime account state.

Also seeds akadmin as the INITIAL member of the "frep" group (the group
itself is provisioned in containers/mail.nix). Seed-only: once the group
has any member, the sync leaves it alone — akadmin manages the list
imperatively from then on (Bulwark), and neither the provision plan
(upsert-only, and groups carry no member field anyway) nor this sync
will clobber those runtime edits.

Note: accounts in an OIDC directory cannot carry local password
credentials (Stalwart refuses them), and app-password secrets are
server-generated, so no pre-seeded service-account passwords exist here
by design — members mint their own app passwords in the webmail for
thick clients.

Runs inside the mail container; talks to Stalwart's management JMAP API on
localhost and to the authentik container directly over the host's veth
routing (same pattern as headscale-user-sync.py).
"""

import base64
import json
import sys
import urllib.request

STALWART_JMAP = "http://127.0.0.1:8080/jmap"
AUTHENTIK_URL = "http://10.77.0.2:9000"  # authentik container
AK_TOKEN_PATH = "/run/secrets/authentik-api-token"
ADMIN_PW_PATH = "/run/secrets/mail-admin"

DOMAIN = "cwrunix.com"
ADMINS_GROUP = "admins"
FREP_GROUP = "frep"  # seeded with the club admin once, then imperatively managed
CLUB_ADMIN = "akadmin"  # gets postmaster@/abuse@/admin@ via the group

JMAP_USING = ["urn:ietf:params:jmap:core", "urn:stalwart:jmap"]


def read(path: str) -> str:
    with open(path) as f:
        return f.read().strip()


def jmap(auth_header: str, calls: list) -> list:
    """Run one JMAP request; return the list of per-call response payloads."""
    body = json.dumps({"using": JMAP_USING, "methodCalls": calls}).encode()
    req = urllib.request.Request(
        STALWART_JMAP,
        data=body,
        headers={
            "Authorization": auth_header,
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        resp = json.load(r)
    out = []
    for name, data, _tag in resp.get("methodResponses", []):
        if name == "error":
            raise RuntimeError(f"JMAP error: {data}")
        out.append(data)
    return out


def main() -> int:
    auth = "Basic " + base64.b64encode(
        f"admin:{read(ADMIN_PW_PATH)}".encode()
    ).decode()

    # --- resolve the cwrunix.com domain id + list existing accounts -------
    domains = jmap(
        auth,
        [
            ["x:Domain/query", {"limit": 10000}, "0"],
            [
                "x:Domain/get",
                {
                    "resultOf": "0",
                    "path": "/ids",
                    "properties": ["name"],
                },
                "1",
            ],
        ],
    )
    domain_ids = {
        d.get("id") for d in domains[1].get("list", []) if d.get("name") == DOMAIN
    }
    if not domain_ids:
        print(f"error: no Stalwart domain named {DOMAIN!r} yet", file=sys.stderr)
        return 1
    domain_id = domain_ids.pop()

    accounts = jmap(
        auth,
        [
            ["x:Account/query", {"limit": 100000}, "0"],
            [
                "x:Account/get",
                {
                    "resultOf": "0",
                    "path": "/ids",
                    "properties": ["name", "domainId", "memberGroupIds"],
                },
                "1",
            ],
        ],
    )
    by_name = {
        a.get("name"): a
        for a in accounts[1].get("list", [])
        if a.get("domainId") == domain_id and a.get("name")
    }

    # --- the club's users --------------------------------------------------
    req = urllib.request.Request(
        f"{AUTHENTIK_URL}/api/v3/core/users/?page_size=500",
        headers={"Authorization": f"Bearer {read(AK_TOKEN_PATH)}"},
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        ak_users = json.load(r)["results"]

    create = {}
    for u in ak_users:
        if u.get("type") not in ("internal", "external") or not u.get("is_active", True):
            continue
        name = u["username"]
        if name in by_name:
            continue
        create[f"u-{name}"] = {"@type": "User", "name": name, "domainId": domain_id}

    if create:
        result = jmap(auth, [["x:Account/set", {"create": create}, "0"]])[0]
        for temp_id in result.get("created", {}):
            print(f"created Stalwart account for {create[temp_id]['name']!r}")
        for temp_id, err in result.get("notCreated", {}).items():
            print(
                f"WARN: could not create {create[temp_id]['name']!r}: {err}",
                file=sys.stderr,
            )

    # --- postmaster@ plumbing: akadmin in the admins group ------------------
    # (re-list if we just created accounts, so akadmin's id is known)
    if create and CLUB_ADMIN not in by_name:
        accounts = jmap(
            auth,
            [
                ["x:Account/query", {"limit": 100000}, "0"],
                [
                    "x:Account/get",
                    {"resultOf": "0", "path": "/ids", "properties": ["name", "domainId", "memberGroupIds"]},
                    "1",
                ],
            ],
        )
        by_name = {
            a.get("name"): a
            for a in accounts[1].get("list", [])
            if a.get("domainId") == domain_id and a.get("name")
        }

    group = by_name.get(ADMINS_GROUP)
    admin = by_name.get(CLUB_ADMIN)
    if group and admin:
        # NB: set-valued fields come back from JMAP as JSON objects
        # ({id: true}), not arrays.
        groups = admin.get("memberGroupIds") or {}
        if group["id"] not in groups:
            new_groups = dict(groups)
            new_groups[group["id"]] = True
            jmap(
                auth,
                [
                    [
                        "x:Account/set",
                        {"update": {admin["id"]: {"memberGroupIds": new_groups}}},
                        "0",
                    ]
                ],
            )
            # memberGroupIds is REPLACED wholesale by Account/set — keep
            # the local copy current so the frep seeding below doesn't
            # clobber the membership just added.
            admin["memberGroupIds"] = new_groups
            print(f"added {CLUB_ADMIN!r} to group {ADMINS_GROUP!r}")
    elif not group:
        print(f"WARN: group {ADMINS_GROUP!r} missing (provision not run yet?)", file=sys.stderr)

    # --- frep@: seed akadmin as the initial member -------------------------
    # Unlike the admins group this is NOT ensured on every run: the group
    # is managed imperatively (Bulwark) once it has any member, so only a
    # completely memberless (freshly provisioned) group gets seeded.
    frep = by_name.get(FREP_GROUP)
    if frep and admin:
        members = [
            a["name"]
            for a in by_name.values()
            if frep["id"] in (a.get("memberGroupIds") or {})
        ]
        if not members:
            new_groups = dict(admin.get("memberGroupIds") or {})
            new_groups[frep["id"]] = True
            jmap(
                auth,
                [
                    [
                        "x:Account/set",
                        {"update": {admin["id"]: {"memberGroupIds": new_groups}}},
                        "0",
                    ]
                ],
            )
            print(f"seeded {CLUB_ADMIN!r} as initial member of group {FREP_GROUP!r}")
    elif not frep:
        print(f"WARN: group {FREP_GROUP!r} missing (provision not run yet?)", file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main())
