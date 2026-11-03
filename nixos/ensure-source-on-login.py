# Ensures settings on the default (authentik-managed) objects, which have
# no stable UUIDs across installs and so can't be imported by tofu
# wipe-safely — hence these idempotent API patches:
#
#   1. The "discord" source (created by tofu) is attached to the default
#      login page's identification stage, so its button shows up on
#      /if/flow/default-authentication-flow/ (an empty sources list shows
#      NO source buttons).
#   2. The default brand designates the tofu-managed "recovery" flow, so
#      API-minted recovery links work (POST /core/users/{id}/recovery/
#      400s with "No recovery flow set." otherwise). That endpoint is how
#      the cwrunix-bot Discord /reset-password command and the admin UI's
#      copy-link action mint links. Deliberately NOT setting the login
#      identification stage's recovery_flow: that button starts the flow
#      tokenless and would hit an email stage we don't run (no SMTP) —
#      Discord is the delivery path.
#   3. Branding: the default brand's logo + the default login flow's
#      background point at the club assets served by nginx under /branding/
#      (see nixos/branding.nix). The tofu-managed flows (member-enrollment,
#      recovery) set their own background directly in tofu.
#
# Env (from /run/secrets/authentik-tofu-env): AUTHENTIK_URL, AUTHENTIK_TOKEN.
import json
import os
import sys
import urllib.error
import urllib.request

BASE = os.environ["AUTHENTIK_URL"].rstrip("/")
TOKEN = os.environ["AUTHENTIK_TOKEN"]
SOURCE_SLUG = "discord"
STAGE_NAME = "default-authentication-identification"


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


sources = api(f"/api/v3/sources/oauth/?slug={SOURCE_SLUG}")["results"]
if len(sources) != 1:
    sys.exit(f"source {SOURCE_SLUG!r} not found (tofu not applied yet?)")
source_pk = sources[0]["pk"]

stages = api(f"/api/v3/stages/identification/?name={STAGE_NAME}")["results"]
if len(stages) != 1:
    sys.exit(f"identification stage {STAGE_NAME!r} not found")
stage = stages[0]

if source_pk in stage["sources"]:
    print("discord source already on the default login identification stage")
else:
    api(f"/api/v3/stages/identification/{stage['pk']}/", "PATCH", {
        "sources": stage["sources"] + [source_pk],
    })
    print("discord source added to the default login identification stage")

# --- recovery flow on the default brand ------------------------------------

RECOVERY_FLOW_SLUG = "recovery"

flows = api(f"/api/v3/flows/instances/?slug={RECOVERY_FLOW_SLUG}")["results"]
if len(flows) != 1:
    sys.exit(f"recovery flow {RECOVERY_FLOW_SLUG!r} not found (tofu not applied yet?)")
flow_pk = flows[0]["pk"]

brands = [b for b in api("/api/v3/core/brands/")["results"] if b.get("default")]
if len(brands) != 1:
    sys.exit("default brand not found")
brand = brands[0]

if brand.get("flow_recovery") == flow_pk:
    print("default brand already designates the recovery flow")
else:
    api(f"/api/v3/core/brands/{brand['brand_uuid']}/", "PATCH", {
        "flow_recovery": flow_pk,
    })
    print("default brand now designates the recovery flow")

# --- branding: logo + login background --------------------------------------
# Assets are served by nginx at /branding/ on the authentik vhost (see
# nixos/branding.nix); relative URLs resolve against the public origin.

# Both branding fields reject absolute paths ("Absolute paths are not
# allowed") — they must be full URLs, unlike the baked-in /static/ default.
BRAND_LOGO = "https://authentik-zeus.cwrunix.com/branding/logo.png"
FLOW_BACKGROUND = "https://authentik-zeus.cwrunix.com/branding/bg.webp"

# The admin top bar caps the logo via the ak-page-navbar component's own
# CSS variable (default 2.25rem ≈ 36px — unreadably small for the
# horizontal club logo). authentik has no size/margin settings on brands;
# custom CSS is the only knob. It is adopted into every component's shadow
# root, and !important is needed to beat the component's own :host default.
BRAND_CSS = """
/* CWRUnix: readable club logo in the admin top bar */
ak-page-navbar {
  --ak-c-page-navbar__brand-logo--Height: 4rem !important;
}
""".strip()

brand_patch = {}
if brand.get("branding_logo") != BRAND_LOGO:
    brand_patch["branding_logo"] = BRAND_LOGO
if brand.get("branding_custom_css") != BRAND_CSS:
    brand_patch["branding_custom_css"] = BRAND_CSS

if not brand_patch:
    print("default brand already has the club logo + css")
else:
    api(f"/api/v3/core/brands/{brand['brand_uuid']}/", "PATCH", brand_patch)
    print(f"default brand patched: {sorted(brand_patch)}")

login_flows = api("/api/v3/flows/instances/?slug=default-authentication-flow")["results"]
if len(login_flows) != 1:
    sys.exit("default-authentication-flow not found")

if login_flows[0].get("background") == FLOW_BACKGROUND:
    print("login flow already has the club background")
else:
    # note: flow detail endpoints are keyed by slug, not uuid
    api("/api/v3/flows/instances/default-authentication-flow/", "PATCH", {
        "background": FLOW_BACKGROUND,
    })
    print("login flow now has the club background")
