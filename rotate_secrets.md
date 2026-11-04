# Rotating secrets (`secrets.yaml`)

Runbook for rotating every secret in `secrets.yaml`. Do the phases in order;
verify each before moving on. All commands run from the repo root.

## Ground rules — never view the values

- Set values by generation/paste without echoing them:

  ```bash
  # generate in place (history stores the unexpanded command line);
  # the helper refuses empty values so a missing generator (e.g. no
  # openssl in PATH) can't silently set an EMPTY secret:
  set_secret() {
    [ -n "$2" ] || { echo "refusing to set $1 to an EMPTY value" >&2; return 1; }
    sops set secrets.yaml "$1" "$(jq -Rn --arg v "$2" '$v')"
  }
  set_secret '["frp"]["token"]' "$(openssl rand -base64 32)"

  # paste in without echo/history (space prefix + read -s):
  read -rs tok && set_secret '["cloudflare"]["dns_api_token"]' "$tok" && unset tok
  ```

- If your age key isn't in the default location: prefix sops commands with
  `SOPS_AGE_KEY_FILE=./key.txt`.
- `restartUnits` in `nixos/sops.nix` bounce the right services on deploy.
  sops templates (`authentik-tofu-env`, etc.) re-render when any placeholder
  secret changes and restart their own units — secrets without explicit
  `restartUnits` still propagate.
- For provider-issued tokens: create the new one, deploy, **verify**, then
  revoke the old one. Never revoke before verify.
- Rollback for the randoms: `git revert` the secrets commit + deploy (tofu
  re-pushes the old values where it manages the remote side).

## Inventory

| Secret                                     | Kind                                                 | Rotation                                                                                                                                 | Impact window                                                           |
| ------------------------------------------ | ---------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| `github_token`                             | GitHub PAT                                           | **delete it** — nothing in the repo consumes it, and the current value is legacy-format (pure hex; real PATs are `ghp_…`/`github_pat_…`) | —                                                                       |
| `cloudflared-creds`                        | tunnel creds JSON                                    | **Phase 5** (recreate tunnel)                                                                                                            | public ingress blip ~1 min                                              |
| `authentik/secret_key`                     | random                                               | Phase 1                                                                                                                                  | all authentik sessions dropped                                          |
| `authentik/bootstrap_password`             | random                                               | Phase 1                                                                                                                                  | none (akadmin UI password — record the new one!)                        |
| `authentik/ldap_outpost_token`             | random                                               | Phase 1                                                                                                                                  | none (pushed by ensure-outpost-token on container restart)              |
| `authentik/bootstrap_token`                | random + API `set_key`                               | **Phase 2**                                                                                                                              | bot/tofu blip (minutes)                                                 |
| `ldap/bind_password`                       | random                                               | Phase 1                                                                                                                                  | sssd blip, self-heals (cached creds)                                    |
| `headscale/oidc_client_secret`             | random                                               | Phase 1                                                                                                                                  | headscale OIDC logins until tofu converges                              |
| `headscale/preauth_key`                    | —                                                    | **dead, delete it** (unused per sops.nix comment)                                                                                        | —                                                                       |
| `cloudflare/dns_api_token`                 | provider console                                     | **Phase 3**                                                                                                                              | none if verified before revoke                                          |
| `headplane/cookie_secret`                  | random, **exactly 32 chars**                         | Phase 1                                                                                                                                  | headplane sessions dropped                                              |
| `headplane/api_key`                        | headscale CLI                                        | **Phase 4**                                                                                                                              | headplane API blip                                                      |
| `discord/client_id`, `guild_id`, `role_id` | identifiers                                          | **not secrets — skip**                                                                                                                   | —                                                                       |
| `discord/client_secret`                    | provider console                                     | Phase 3                                                                                                                                  | Discord SSO broken until tofu converges                                 |
| `discord/bot_token`                        | provider console                                     | Phase 3                                                                                                                                  | bot down until deploy                                                   |
| `frp/token`                                | random                                               | Phase 1                                                                                                                                  | pushed to relay by proxy-provision (no-op until Linode exists)          |
| `linode/api_token`                         | provider console                                     | Phase 3                                                                                                                                  | none (API auth only; scopes: `images:read_write`, `linodes:read_write`) |
| `webtty/client_secret`                     | random                                               | Phase 1                                                                                                                                  | webtty SSO until tofu converges                                         |
| `webtty/cookie_secret`                     | random, **base64URL** of 32 bytes (see Phase 1 note) | Phase 1                                                                                                                                  | webtty sessions dropped                                                 |
| `sops/mac`                                 | —                                                    | auto-managed — skip                                                                                                                      | —                                                                       |

## Phase 1 — self-generated randoms (one deploy)

```bash
set_secret '["frp"]["token"]'                       "$(openssl rand -base64 32)"
set_secret '["authentik"]["bootstrap_password"]'    "$(openssl rand -base64 24)"
set_secret '["authentik"]["secret_key"]'            "$(openssl rand -base64 48)"
set_secret '["ldap"]["bind_password"]'              "$(openssl rand -base64 32)"
set_secret '["authentik"]["ldap_outpost_token"]'    "$(openssl rand -base64 32)"
set_secret '["headscale"]["oidc_client_secret"]'    "$(openssl rand -hex 32)"
set_secret '["webtty"]["client_secret"]'            "$(openssl rand -hex 32)"
set_secret '["webtty"]["cookie_secret"]'            "$(openssl rand -base64 32 | tr '+/' '-_')"   # base64URL! see below
set_secret '["headplane"]["cookie_secret"]'         "$(openssl rand -base64 24)"   # exactly 32 chars
```

**Why `webtty/cookie_secret` must be base64URL**: oauth2-proxy (≥7.8-ish,
verified on 7.15.5) validates file-sourced cookie secrets by decoding with
`base64.RawURLEncoding` — the URL-safe alphabet. A _standard_ base64 value
that happens to contain `+` or `/` fails that decode, oauth2-proxy falls back
to the raw string, and the service dies with
`cookie_secret from file must be 16, 24, or 32 bytes ... but is 44 bytes`.
Whether plain base64 works is a coin flip per generated value — always `tr
'+/' '-_'`. (No openssl on the machine?
`python3 -c "import secrets,base64;print(base64.urlsafe_b64encode(secrets.token_bytes(32)).decode())"`.)

Commit, deploy. Then, **after the in-container tofu run converges**
(`journalctl -M authentik -u authentik-tofu` on zeus), restart the stragglers
so they pick up the tofu-pushed values:

```bash
systemctl restart container@headscale.service oauth2-proxy.service
```

Verify: SSH login still works (ldap bind), authentik UI with the **new**
akadmin password, webtty SSO, headplane login, `journalctl -u proxy-provision`
(if the relay exists: frp token pushed, `frp-relay` connected).

## Phase 2 — `authentik/bootstrap_token`

`AUTHENTIK_BOOTSTRAP_TOKEN` is only read at authentik's _first_ boot; changing
the env does nothing afterwards. Rotate by forcing the token value via the API
(same `set_key` pattern as `nixos/ensure-outpost-token.py`):

```bash
old=$(sops decrypt --extract '["authentik"]["bootstrap_token"]' secrets.yaml)
new=$(openssl rand -base64 36)
AK=https://authentik-zeus.cwrunix.com

# find akadmin's API token identifier (usually "akadmin-bootstrap"):
curl -fsS -H "Authorization: Bearer $old" \
  "$AK/api/v3/core/tokens/?user__username=akadmin" | jq -r '.results[].identifier'

# force the new value onto it (use the identifier from above):
curl -fsS -X POST -H "Authorization: Bearer $old" -H 'Content-Type: application/json' \
  -d "{\"key\": \"$new\"}" "$AK/api/v3/core/tokens/<identifier>/set_key/"

# verify the new key works BEFORE switching consumers:
curl -fsS -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $new" \
  "$AK/api/v3/core/users/?page_size=1"        # want: 200

set_secret '["authentik"]["bootstrap_token"]' "$new"
unset old new
```

Commit + deploy. The tofu bootstrap, discord-bot, and headscale-user-sync all
pick it up from their env templates. Between `set_key` and the deploy those
consumers use the old (now-invalid) token — a few minutes of bot/sync errors,
self-healing on restart.

## Phase 3 — provider-issued

- **`cloudflare/dns_api_token`**: Cloudflare dashboard → My Profile → API
  Tokens → create with the same scope (Zone.DNS Edit on cwrunix.com), or
  **Roll** the existing token in place. The token _value_ is an opaque string
  shown once (historically 40 chars; newer tokens differ — judge by the
  verify call below, not by length/charset). The UUID shown in the token list
  is the Token ID, NOT a credential. Verify before swapping:

  ```bash
  read -rs tok
  curl -fsS -H "Authorization: Bearer $tok" \
    https://api.cloudflare.com/client/v4/user/tokens/verify | jq .success   # true
  zone=$(curl -fsS -H "Authorization: Bearer $tok" \
    "https://api.cloudflare.com/client/v4/zones?name=cwrunix.com" | jq -r '.result[0].id')
  curl -fsS -H "Authorization: Bearer $tok" \
    "https://api.cloudflare.com/client/v4/zones/$zone/dns_records?per_page=1" | jq .success   # true
  set_secret '["cloudflare"]["dns_api_token"]' "$tok"; unset tok zone
  ```

  Deploy, confirm `cloudflared-dns-routes` re-ran clean, then delete the old
  token in the dashboard.

- **`discord/client_secret`**: Dev Portal → OAuth2 → Reset Secret → sops →
  deploy. The change re-renders `authentik-tofu-env`, restarting the authentik
  container, and tofu updates the Discord source. Discord SSO (enrollment /
  Discord login / the recovery policy's guild check) is broken in the window;
  existing sessions and password logins are unaffected.

- **`discord/bot_token`**: Dev Portal → Bot → Reset Token (invalidates the old
  one immediately) → sops → deploy; `container@discord-bot` restarts via
  `restartUnits`.

- **`github_token`**: nothing in this repo references it — delete the entry
  from `secrets.yaml` and `nixos/sops.nix` instead of rotating. (If some
  out-of-repo workflow uses it, rotate at GitHub → fine-grained PAT.)

- **`linode/api_token`**: Cloud Manager → API Tokens → scopes
  `images:read_write` + `linodes:read_write`, nothing else → sops → deploy.
  `proxy-provision.service` re-runs; tofu apply is a no-op if the relay
  already exists (the token only authenticates the API). Revoke the old token
  after.

## Phase 4 — `headplane/api_key`

Minted by headscale itself. On zeus:

```bash
sudo nixos-container run headscale -- headscale apikeys create --expiration 8760h
```

sops-set the output, deploy (headplane restarts via `restartUnits`), verify
headplane loads, then expire the old key:

```bash
sudo nixos-container run headscale -- headscale apikeys list
sudo nixos-container run headscale -- headscale apikeys expire --prefix '<old-prefix>'
```

## Phase 5 — `cloudflared-creds` (tunnel recreation)

There is no in-place rotation for tunnel credentials — rotation is a new
tunnel. Two artifacts exist in the wild: the **credentials JSON** (what this
secret must hold; locally-managed tunnels) and the **tunnel token** (base64
JSON `{"a":…,"t":…,"s":…}`, for remotely-managed/dashboard tunnels — NOT used
here; a dashboard-created tunnel's config silently overrides the nix ingress,
see `nixos/cloudflare.nix`).

```bash
# on an admin workstation:
nix shell nixpkgs#cloudflared   # if needed
cloudflared tunnel login        # browser → writes ~/.cloudflared/cert.pem
cloudflared tunnel create zeus2 # name must differ from the live tunnel;
                                # writes ~/.cloudflared/<new-id>.json

# back in the repo:
sops set secrets.yaml '["cloudflared-creds"]' "$(jq -Rs . < ~/.cloudflared/<new-id>.json)"
```

Edit `tunnelId` in `nixos/cloudflare.nix` (top of file) to the new ID.
**Commit creds + ID together** and deploy as one unit (the unit name, the ID
embedded in the creds, and the `<id>.cfargotunnel.com` DNS target must agree).

Verify:

```bash
journalctl -u cloudflared-tunnel-<new-id> -n 20   # "Registered tunnel connection"
journalctl -u cloudflared-dns-routes -n 10        # "updated DNS route" x3
curl -sI https://ttyd-zeus.cwrunix.com | head -1
curl -sI https://authentik-zeus.cwrunix.com | head -1
```

Then delete the old tunnel (safe only after the new one serves traffic;
rollback before this point is just `git revert` + deploy):

```bash
cloudflared tunnel delete -f <old-id>
```

Cleanup: don't open the new tunnel's config in the dashboard (flips it to
remotely-managed); delete `~/.cloudflared/cert.pem` when done (it can manage
tunnels account-wide; re-`login` next time); delete any dashboard-created
tunnel/token from earlier attempts.

## Rotating zeus's age key (`/persist/sops-nix/key.txt`)

The `deploy` recipient's private half is the key you pass to
`nix run .#deploy` at install time (e.g. `~/keys/zeus-deploy.key`) and it
lives on zeus at `/persist/sops-nix/key.txt`. Your laptop key stays valid
throughout, so every step is zero-lockout. (The VM is unaffected — it uses
the laptop key via the 9p share, not this one.)

```bash
# 1. laptop: new keypair — prints "Public key: age1…"
age-keygen -o ~/keys/zeus-deploy-new.key

# 2. .sops.yaml: add the new public key as an anchor (keep the old one!):
#      - &deploy-new age1…
#    and add `- *deploy-new` to the key group

# 3. re-encrypt to all three recipients, push
SOPS_AGE_KEY_FILE=./key.txt sops updatekeys -y secrets.yaml
git commit -am "sops: add rotated zeus age-key recipient" && git push

# 4. install the new key on zeus (the file is readable by old AND new keys
#    until step 6, so the order here is safe both ways)
scp ~/keys/zeus-deploy-new.key zeus:/persist/sops-nix/key.txt.new
ssh zeus 'chmod 600 /persist/sops-nix/key.txt.new &&
          mv /persist/sops-nix/key.txt{.new,}'

# 5. deploy as usual — activation decrypts with the new key

# 6. verify on zeus
ssh zeus 'age-keygen -y /persist/sops-nix/key.txt'   # prints the new age1…

# 7. drop the old recipient (remove the old &deploy anchor + its `- *deploy`
#    use in .sops.yaml), re-encrypt, deploy again
SOPS_AGE_KEY_FILE=./key.txt sops updatekeys -y secrets.yaml
git commit -am "sops: drop old zeus age-key recipient" && git push

# 8. retire the old key copies; the new file becomes your install-time key
mv ~/keys/zeus-deploy-new.key ~/keys/zeus-deploy.key
shred -u <every copy of the old key>
```

## Rotating zeus's SSH host key (e.g. after a leak)

The host key is persisted (`/persist/etc/ssh/ssh_host_ed25519_key{,.pub}`,
see `nixos/hardware/persistence.nix`) and is purely the SSH identity — it is
deliberately **not** a sops recipient (`secrets.yaml` is addressed only to the
laptop key and zeus's dedicated age key), so a leaked host key does **not**
compromise `secrets.yaml`. Rotation is therefore plain SSH hygiene:

1. On zeus, generate the new pair without touching the live one:

   ```bash
   ssh-keygen -t ed25519 -f /persist/etc/ssh/ssh_host_ed25519_key.new -N '' \
     -C "zeus host key $(date +%F)"
   ```

2. Swap it into place (keep the old as `.bak` until verified) and reboot —
   impermanence re-binds `/etc/ssh` at boot:

   ```bash
   mv /persist/etc/ssh/ssh_host_ed25519_key{,.bak}
   mv /persist/etc/ssh/ssh_host_ed25519_key.pub{,.bak}
   mv /persist/etc/ssh/ssh_host_ed25519_key.new     /persist/etc/ssh/ssh_host_ed25519_key
   mv /persist/etc/ssh/ssh_host_ed25519_key.new.pub /persist/etc/ssh/ssh_host_ed25519_key.pub
   chmod 600 /persist/etc/ssh/ssh_host_ed25519_key
   reboot
   ```

3. Expect the host-key-changed warning on next connect (that's the point).
   Admins scrub the old `known_hosts` entry; publish the new fingerprint so
   members can verify instead of blindly accepting:

   ```bash
   ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
   ```

4. Rotate the RSA host key the same way (`/persist/etc/ssh/ssh_host_rsa_key`),
   reboot, delete the `.bak` files.

Caveat: if the _disk_ was exposed rather than just the key file, then
`/persist/sops-nix/key.txt` is equally compromised — rotate that recipient
(Cleanup above) and run the full Phase 1–5 secrets rotation.

## Finish

- `git diff secrets.yaml` should show only `ENC[...]` blobs changing (plus the
  `sops/mac` and `lastmodified` metadata, which update automatically).
- Commit, deploy, spot-check: SSH (key + password), authentik UI, Discord SSO,
  webtty, ttyd tailnet, headplane, bot commands, podman login for a member.
