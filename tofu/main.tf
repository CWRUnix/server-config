# Declarative bootstrap for the authentik instance (runs automatically via
# the authentik-tofu systemd service inside the authentik container — see
# nixos/authentik-bootstrap.nix). Replaces all manual UI setup except users.
#
# Provider auth comes from the environment (AUTHENTIK_URL / AUTHENTIK_TOKEN,
# rendered by sops into /run/secrets/authentik-tofu-env).
#
# DO NOT `tofu apply` this from a laptop/admin box against the live server:
# the container-side service owns the apply and keeps its own state (in the
# container's storage, wiped and re-applied with a fresh DB). An outside
# apply with a stale local state just fights it ("already exists" 400s).
# The TF_VAR dance below is for dev/VM testing only.

terraform {
  required_providers {
    authentik = {
      source  = "goauthentik/authentik"
      version = "2026.5.2"
    }
  }
}

variable "ldap_bind_password" {
  type      = string
  sensitive = true
}

# The LDAP outpost service (authentik-ldap) starts with this token; the
# bootstrap service forces the outpost's API token to this value via the
# set_key API action (see ensure-outpost-token.py in nixos/).
variable "ldap_outpost_token" {
  type      = string
  sensitive = true
}

variable "headscale_client_secret" {
  type      = string
  sensitive = true
}

variable "webtty_client_secret" {
  type      = string
  sensitive = true
}

# Discord application credentials for the club SSO source.
variable "discord_client_id" {
  type = string
}

variable "discord_client_secret" {
  type      = string
  sensitive = true
}

# The club Discord server + the role required to enroll.
variable "discord_guild_id" {
  type = string
}

variable "discord_role_id" {
  type = string
}

provider "authentik" {}

# ---------------------------------------------------------------------------
# LDAP: bind flow (identification + password + login; no MFA — binds are
# non-interactive), provider, application, service account, outpost.
# ---------------------------------------------------------------------------

resource "authentik_stage_password" "ldap" {
  name = "ldap-authentication-password"
  backends = [
    "authentik.core.auth.InbuiltBackend",
    "authentik.core.auth.TokenBackend",
    "authentik.sources.ldap.auth.LDAPBackend",
    "authentik.sources.kerberos.auth.KerberosBackend",
  ]
}

resource "authentik_stage_identification" "ldap" {
  name           = "ldap-identification-stage"
  user_fields    = ["username", "email"]
  password_stage = authentik_stage_password.ldap.id
}

resource "authentik_stage_user_login" "ldap" {
  name = "ldap-authentication-login"
}

resource "authentik_flow" "ldap" {
  name        = "ldap-authentication-flow"
  title       = "LDAP Authentication Flow"
  slug        = "ldap-authentication-flow"
  designation = "authentication"
}

resource "authentik_flow_stage_binding" "ldap-identification" {
  target = authentik_flow.ldap.uuid
  stage  = authentik_stage_identification.ldap.id
  order  = 10
}

resource "authentik_flow_stage_binding" "ldap-login" {
  target = authentik_flow.ldap.uuid
  stage  = authentik_stage_user_login.ldap.id
  order  = 30
}

data "authentik_flow" "default-invalidation" {
  slug = "default-invalidation-flow"
}

resource "authentik_provider_ldap" "ldap" {
  name        = "ldap"
  base_dn     = "dc=ldap,dc=goauthentik,dc=io"
  bind_flow   = authentik_flow.ldap.uuid
  unbind_flow = data.authentik_flow.default-invalidation.id
  # No MFA over LDAP binds (SSH); also avoids authentik's semicolon-splitting
  # of bind passwords when MFA support is enabled.
  mfa_support = false
}

resource "authentik_application" "ldap" {
  name              = "LDAP"
  slug              = "ldap"
  protocol_provider = authentik_provider_ldap.ldap.id
}

# Service account sssd binds as (cn=ldapservice,ou=users,dc=ldap,...).
resource "authentik_rbac_role" "ldap-search" {
  name = "LDAP search"
}

resource "authentik_user" "ldapservice" {
  username = "ldapservice"
  name     = "LDAP Service Account"
  password = var.ldap_bind_password
  roles    = [authentik_rbac_role.ldap-search.id]
}

# Let the service account see all users/groups for searches (object
# permission on the LDAP provider; role-based, since authentik 2026.x
# dropped user-level object permissions).
resource "authentik_rbac_permission_role" "ldap-search" {
  role       = authentik_rbac_role.ldap-search.id
  permission = "authentik_providers_ldap.search_full_directory"
  model      = "authentik_providers_ldap.ldapprovider"
  object_id  = authentik_provider_ldap.ldap.id
}

resource "authentik_outpost" "ldap" {
  name               = "LDAP"
  type               = "ldap"
  protocol_providers = [authentik_provider_ldap.ldap.id]
}

# ---------------------------------------------------------------------------
# headscale: OIDC login for the tailnet.
# ---------------------------------------------------------------------------

data "authentik_flow" "default-authorization-implicit" {
  slug = "default-provider-authorization-implicit-consent"
}

data "authentik_flow" "default-provider-invalidation" {
  slug = "default-provider-invalidation-flow"
}

data "authentik_certificate_key_pair" "self-signed" {
  name              = "authentik Self-signed Certificate"
  fetch_certificate = false
  fetch_key         = false
}

data "authentik_property_mapping_provider_scope" "openid" {
  name = "authentik default OAuth Mapping: OpenID 'openid'"
}

data "authentik_property_mapping_provider_scope" "email" {
  name = "authentik default OAuth Mapping: OpenID 'email'"
}

data "authentik_property_mapping_provider_scope" "profile" {
  name = "authentik default OAuth Mapping: OpenID 'profile'"
}

resource "authentik_provider_oauth2" "headscale" {
  name               = "headscale"
  client_id          = "headscale"
  client_secret      = var.headscale_client_secret
  client_type        = "confidential"
  authorization_flow = data.authentik_flow.default-authorization-implicit.id
  invalidation_flow  = data.authentik_flow.default-provider-invalidation.id
  # The provider's computed default for grant_types comes back wrong against
  # authentik 2026.8 (authorize rejects the flow with "Invalid grant_type"),
  # so set it explicitly.
  grant_types = [
    "authorization_code",
    "refresh_token",
  ]
  allowed_redirect_uris = [
    {
      matching_mode     = "strict"
      url               = "https://headscale-zeus.cwrunix.com/oidc/callback"
      redirect_uri_type = "authorization"
    },
    # headplane shares this OIDC client (same sub claims => automatic
    # headscale<->headplane identity linking, per headplane docs).
    {
      matching_mode     = "strict"
      url               = "https://headplane-zeus.cwrunix.com/admin/oidc/callback"
      redirect_uri_type = "authorization"
    }
  ]
  property_mappings = [
    data.authentik_property_mapping_provider_scope.openid.id,
    data.authentik_property_mapping_provider_scope.email.id,
    data.authentik_property_mapping_provider_scope.profile.id,
  ]
  signing_key = data.authentik_certificate_key_pair.self-signed.id
}

resource "authentik_application" "headscale" {
  name              = "headscale"
  slug              = "headscale"
  protocol_provider = authentik_provider_oauth2.headscale.id
}

# ---------------------------------------------------------------------------
# WebTTY (browser shell without a tailscale client): oauth2-proxy guards
# ttyd-zeus.cwrunix.com with this OIDC client. After SSO the member still
# hits login(1) -> PAM -> LDAP password (the tunnel path carries no
# tailnet identity, so OS auth still applies).
# ---------------------------------------------------------------------------

resource "authentik_provider_oauth2" "webtty" {
  name               = "webtty"
  client_id          = "webtty"
  client_secret      = var.webtty_client_secret
  client_type        = "confidential"
  authorization_flow = data.authentik_flow.default-authorization-implicit.id
  invalidation_flow  = data.authentik_flow.default-provider-invalidation.id
  # Same 2026.8 workaround as the headscale provider above.
  grant_types = [
    "authorization_code",
    "refresh_token",
  ]
  allowed_redirect_uris = [
    {
      matching_mode     = "strict"
      url               = "https://ttyd-zeus.cwrunix.com/oauth2/callback"
      redirect_uri_type = "authorization"
    }
  ]
  property_mappings = [
    data.authentik_property_mapping_provider_scope.openid.id,
    data.authentik_property_mapping_provider_scope.email.id,
    data.authentik_property_mapping_provider_scope.profile.id,
  ]
  signing_key = data.authentik_certificate_key_pair.self-signed.id
}

resource "authentik_application" "webtty" {
  name              = "webtty"
  slug              = "webtty"
  protocol_provider = authentik_provider_oauth2.webtty.id
}
# ---------------------------------------------------------------------------
# Discord SSO: members log in with their Discord account. Two gates:
#
#   1. Role check — an expression policy calls the Discord API live to
#      verify the user has the member role on the club server. Bound to
#      BOTH enrollment and authentication (dedicated discord-authentication
#      flow, so other sources never run it), so losing the role locks the
#      account at next login. Successful checks are cached on the authentik
#      user object for 30 days so we don't inherit Discord's availability
#      on every login; a stale cache + unreachable Discord fails closed
#      with a friendly message.
#   2. Admin approval — enrollment creates the account INACTIVE (an admin
#      activates it under Directory -> Users). Inactive users are rejected
#      by the login stage, so enrollment alone grants nothing.
# ---------------------------------------------------------------------------

resource "authentik_source_oauth" "discord" {
  name              = "Discord"
  slug              = "discord"
  provider_type     = "discord"
  consumer_key      = var.discord_client_id
  consumer_secret   = var.discord_client_secret
  additional_scopes = "guilds.members.read" # lets the policy read the member object

  # Match returning users to their account by email (Discord emails are
  # verified). The default "identifier" mode relies on the stored source
  # connection — which our approval-gated enrollment never saves (the deny
  # stage aborts the flow before the link stage runs), so returning users
  # were sent through enrollment again. email_link re-links them instead.
  user_matching_mode = "email_link"

  authentication_flow = authentik_flow.discord-authentication.uuid
  enrollment_flow     = authentik_flow.member-enrollment.uuid
}

# --- role check ------------------------------------------------------------

resource "authentik_policy_expression" "discord-member-role" {
  name       = "discord-member-role"
  expression = <<-EOT
    import json
    import time
    import urllib.error
    import urllib.request

    GUILD_ID = "${var.discord_guild_id}"
    ROLE_ID = "${var.discord_role_id}"
    RECHECK_AFTER_SECONDS = 30 * 86400

    user = context.get("pending_user")
    if user is not None:
        attrs = user.attributes or {}
        last = attrs.get("discord_role_checked_at", 0)
        if time.time() - last < RECHECK_AFTER_SECONDS:
            return True

    connection = context.get("goauthentik.io/sources/connection")
    token = getattr(connection, "access_token", None)
    if not token:
        ak_logger.warning("discord role check: no access token on connection")
        ak_message("Discord link is missing an access token; please contact an admin.")
        return False

    # NB: browser UA — Discord's API sits behind Cloudflare, which blocks the
    # default Python UA with error 1010 (intermittently).
    try:
        resp = requests.get(
            f"https://discord.com/api/v10/users/@me/guilds/{GUILD_ID}/member",
            headers={
                "Authorization": f"Bearer {token}",
                "Accept": "application/json",
                "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
            },
            timeout=10,
        )
    except Exception as e:
        ak_logger.warning("discord role check failed", error=str(e))
        ak_message("Could not reach Discord to verify membership; please try again later.")
        return False

    if resp.status_code == 404:
        ak_message("You are not a member of the CWRUnix Discord server.")
        return False
    if resp.status_code != 200:
        ak_logger.warning("discord role check HTTP error", status=resp.status_code, body=resp.text[:300])
        ak_message(f"Discord membership check failed (HTTP {resp.status_code}); please try again later.")
        return False

    member = resp.json()

    if ROLE_ID not in [str(role_id) for role_id in member.get("roles", [])]:
        ak_message("You do not have the required role on the CWRUnix Discord server.")
        return False

    if user is not None:
        try:
            attrs = user.attributes or {}
            attrs["discord_role_checked_at"] = time.time()
            user.attributes = attrs
            user.save()
        except Exception:
            pass # caching is best-effort; never let it deny a valid member
    return True
  EOT
}

# --- member enrollment (prompt username -> create INACTIVE -> deny message) ---

resource "authentik_policy_expression" "member-enrollment-sso-only" {
  name       = "member-enrollment-sso-only"
  expression = "return ak_is_sso_flow"
}

resource "authentik_stage_prompt_field" "member-username" {
  name      = "member-enrollment-field-username"
  field_key = "username"
  label     = "Username"
  type      = "username"
  required  = true
  order     = 100
}

resource "authentik_stage_prompt" "member-enrollment" {
  name   = "member-enrollment-prompt"
  fields = [authentik_stage_prompt_field.member-username.id]
  # Username must be valid everywhere the account feeds: POSIX/Linux login
  # on zeus (via sssd/LDAP), headscale user names, MagicDNS labels. The
  # built-in username field already rejects duplicates; this adds format.
  validation_policies = [authentik_policy_expression.member-enrollment-username-format.id]
}

resource "authentik_policy_expression" "member-enrollment-username-format" {
  name       = "member-enrollment-username-format"
  expression = <<-EOT
    import re
    username = str(context["prompt_data"].get("username", ""))
    if not re.fullmatch(r"[a-z_][a-z0-9_-]{0,31}", username):
        ak_message("Username must start with a lowercase letter or underscore and contain only lowercase letters, numbers, '-' and '_' (max 32 characters).")
        return False
    # Names that exist as local system accounts on zeus. An authentik user
    # with such a name cannot actually log in as the local user (the
    # pam_localuser gate in nixos/auth/sssd.nix denies them) — reject here
    # so they find out with a clear message instead of a dead account.
    # Keep in sync with the host's users (admins + common service users).
    reserved = {
        "root", "daemon", "bin", "sys", "adm", "lp", "mail", "uucp",
        "operator", "nobody", "systemd-network", "systemd-resolve",
        "systemd-timesync", "systemd-coredump", "systemd-oom",
        "systemd-logind", "messagebus", "dbus", "polkituser", "nscd",
        "sshd", "sssd", "nginx", "acme", "dnsmasq", "cloudflared",
        "authentik", "headscale", "headplane", "discord-bot",
        # local admin accounts (nixos/admins/):
        "tev",
    }
    if username in reserved:
        ak_message("That username is reserved on the server. Please choose another one.")
        return False
    return True
  EOT
}

resource "authentik_stage_user_write" "member-enrollment" {
  name                     = "member-enrollment-write"
  create_users_as_inactive = true
}

resource "authentik_stage_deny" "member-enrollment" {
  name         = "member-enrollment-deny"
  deny_message = "Your account has been created and is pending approval by a CWRUnix admin. Contact an admin to activate it, then log in again."
}

resource "authentik_flow" "member-enrollment" {
  name        = "Member enrollment (admin approval)"
  title       = "Welcome to CWRUnix!"
  slug        = "member-enrollment"
  designation = "enrollment"
  # Club branding, served by nginx on the authentik vhost (nixos/branding.nix).
  background = "https://authentik-zeus.cwrunix.com/branding/bg.webp"  # flow.background rejects absolute paths; must be a full URL
}

resource "authentik_flow_stage_binding" "member-enrollment-prompt" {
  target = authentik_flow.member-enrollment.uuid
  stage  = authentik_stage_prompt.member-enrollment.id
  order  = 10
}

resource "authentik_flow_stage_binding" "member-enrollment-write" {
  target = authentik_flow.member-enrollment.uuid
  stage  = authentik_stage_user_write.member-enrollment.id
  order  = 20
}

resource "authentik_flow_stage_binding" "member-enrollment-deny" {
  target = authentik_flow.member-enrollment.uuid
  stage  = authentik_stage_deny.member-enrollment.id
  order  = 30
}

# The flow must only ever run as a source enrollment, never standalone.
resource "authentik_policy_binding" "member-enrollment-sso-only" {
  target = authentik_flow.member-enrollment.uuid
  policy = authentik_policy_expression.member-enrollment-sso-only.id
  order  = 10
}

resource "authentik_policy_binding" "discord-role-enrollment" {
  target = authentik_flow.member-enrollment.uuid
  policy = authentik_policy_expression.discord-member-role.id
  order  = 0
}

# --- dedicated Discord authentication flow (login stage + role re-check) ---

resource "authentik_stage_user_login" "discord-authentication" {
  name = "discord-authentication-login"
}

resource "authentik_flow" "discord-authentication" {
  name        = "Discord authentication"
  title       = "Discord authentication"
  slug        = "discord-authentication"
  designation = "authentication"
}

resource "authentik_flow_stage_binding" "discord-authentication-login" {
  target = authentik_flow.discord-authentication.uuid
  stage  = authentik_stage_user_login.discord-authentication.id
  order  = 10
}

resource "authentik_policy_binding" "discord-role-authentication" {
  target = authentik_flow.discord-authentication.uuid
  policy = authentik_policy_expression.discord-member-role.id
  order  = 0
}

# ---------------------------------------------------------------------------
# Password recovery. This authentik version ships NO prebuilt recovery flow
# (checked: designation=recovery is empty on a fresh 2026.8 instance), and
# there is deliberately no email stage in it: delivery is not by email
# (CWRU outbound mail is ticket-gated). Links are minted via the API
# (POST /core/users/{id}/recovery/) and delivered over Discord by the
# cwrunix-bot /reset-password command (or an admin pasting the link from
# the user page). With the minted FlowToken the executor resumes directly
# onto the prompt stage; links are single-use (revoke_on_execution) and
# short-lived (default token duration).
#
# NOTE: password SETTING is a prompt stage + user_write (prompt_data's
# "password" key is hashed into the inbuilt credential — the same one LDAP
# binds check). authentik_stage_password only VERIFIES a password against
# backends; using it here made every input fail with "Invalid password".
#
# This flow is ALSO how new members set their FIRST password: enrollment
# collects only a username.
#
# The brand-side designation (flow_recovery on the default brand) is done
# by the ensure-step in nixos/ensure-source-on-login.py — the default brand
# has no stable UUID across installs, so tofu can't import it wipe-safely.
# ---------------------------------------------------------------------------

resource "authentik_stage_prompt_field" "recovery-password" {
  name      = "recovery-password"
  field_key = "password"
  type      = "password"
  label     = "New password"
  required  = true
}

resource "authentik_stage_prompt_field" "recovery-password-repeat" {
  name      = "recovery-password-repeat"
  field_key = "password_repeat"
  type      = "password"
  label     = "New password (repeat)"
  required  = true
}

resource "authentik_policy_password" "recovery" {
  name           = "recovery-password-length"
  error_message  = "Password must be at least 10 characters long."
  length_min     = 10
  password_field = "password"
}

resource "authentik_stage_prompt" "recovery" {
  name = "recovery-password-prompt"
  fields = [
    authentik_stage_prompt_field.recovery-password.id,
    authentik_stage_prompt_field.recovery-password-repeat.id,
  ]
  validation_policies = [authentik_policy_password.recovery.id]
}

# The recovery flow is ONLY usable with a minted flow token (single-use,
# short-lived — see the comment above). Without this guard, the "Forgot
# password?" link that now appears on the login page's password field
# (brand.flow_recovery is set) would start the flow tokenless and strand
# the user on a prompt with no pending user. NOTE: do not add an
# identification stage instead — with no email stage there is no
# verification factor, so tokenless identification+reset would let anyone
# reset ANYONE's password.
resource "authentik_policy_expression" "recovery-token-required" {
  name       = "recovery-token-required"
  # Minting happens via the admin API (which enforces its own permission);
  # executing happens via the flow executor with the token inside the
  # nested `query` param (the SPA calls /flows/executor/<slug>/?query=
  # flow_token%3D...). Everything else — including tokenless browsing to
  # /if/flow/recovery/ — is denied. `request` is the PolicyRequest, its
  # .http_request the Django request; `context` is its inner data dict.
  expression = <<-EOT
    req = request.http_request
    if req is None:
        return False
    if req.path.startswith("/api/v3/core/"):
        return True
    return "flow_token" in req.GET or "flow_token=" in req.GET.get("query", "")
  EOT
}

resource "authentik_policy_binding" "recovery-token-required" {
  target = authentik_flow.recovery.uuid
  policy = authentik_policy_expression.recovery-token-required.id
  order  = -10
}

resource "authentik_stage_user_write" "recovery" {
  name = "recovery-write"
}

resource "authentik_stage_user_login" "recovery" {
  name = "recovery-login"
}

resource "authentik_flow" "recovery" {
  name        = "recovery"
  title       = "Reset your CWRUnix password"
  slug        = "recovery"
  designation = "recovery"
  # Club branding, served by nginx on the authentik vhost (nixos/branding.nix).
  background = "https://authentik-zeus.cwrunix.com/branding/bg.webp"  # flow.background rejects absolute paths; must be a full URL
}

resource "authentik_flow_stage_binding" "recovery-prompt" {
  target = authentik_flow.recovery.uuid
  stage  = authentik_stage_prompt.recovery.id
  order  = 0
}

resource "authentik_flow_stage_binding" "recovery-write" {
  target = authentik_flow.recovery.uuid
  stage  = authentik_stage_user_write.recovery.id
  order  = 10
}

resource "authentik_flow_stage_binding" "recovery-login" {
  target = authentik_flow.recovery.uuid
  stage  = authentik_stage_user_login.recovery.id
  order  = 20
}

# ---------------------------------------------------------------------------
# GPU access group: members in this group get /dev/dri/renderD* on zeus
# (udev rule, nixos/hardware/gpu.nix). The gidNumber is pinned identically
# on both sides — device permission checks are numeric.
# ---------------------------------------------------------------------------

resource "authentik_group" "gpu" {
  name       = "gpu"
  attributes = jsonencode({ gidNumber = "2600" })
}
