# Infrastructure for the raw-TCP relay that lets stock tailscaled clients
# reach headscale (Cloudflare's tunnel strips Upgrade on POST, so the
# TS2021 control handshake needs a plain TCP relay). Applied on zeus by
# proxy-provision.service (nixos/proxy-relay.nix); can also be applied by
# hand from the dev shell with the same env vars.
#
# State: /root/infra-tofu on zeus (persists via /persist).
#
# Required env (from sops template infra-tofu-env):
#   TF_VAR_linode_token          - Linode API token, scopes:
#                                  images:read_write, linodes:read_write,
#                                  events:read_only (the provider polls
#                                  /v4/account/events to await instance
#                                  create/boot/destroy — a replacement
#                                  fails with 401 without it),
#                                  ips:read_write (linode_rdns reads+sets
#                                  the PTR via /v4/networking/ips)
#   TF_VAR_cloudflare_api_token  - the existing scoped zone DNS token
#   TF_VAR_cloudflare_zone_id    - resolved by the provision script
#   TF_VAR_image_path            - path to the built proxy .img.gz
#   TF_VAR_root_pass             - throwaway (SSH-key-only box; API field)
#   TF_VAR_provision_ssh_pubkey  - zeus's dedicated provisioning key

terraform {
  # State MUST NOT live in the workdir: proxy-provision rsync --delete's
  # the workdir from the nix store on every run, which used to wipe
  # terraform.tfstate with it (every apply then tried to re-create
  # everything — hence the "identical record already exists" errors when
  # DNS records existed, and the relay instance being replaced blindly).
  # Keep it next to the workdir instead; /root is persisted.
  backend "local" {
    path = "/root/infra-tofu/terraform.tfstate"
  }

  required_providers {
    linode = {
      source  = "linode/linode"
      version = "4.7.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "5.28.0"
    }
  }
}

variable "linode_token" {
  type      = string
  sensitive = true
}
variable "cloudflare_api_token" {
  type      = string
  sensitive = true
}
variable "cloudflare_zone_id" {
  type = string
}
variable "image_path" {
  type = string
}
variable "root_pass" {
  type      = string
  sensitive = true
}
variable "provision_ssh_pubkey" {
  type = string
}

provider "linode" {
  token = var.linode_token
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

# Built by `nix build .#proxy-image` (see proxy/default.nix). file_hash
# gates re-upload: only changes to the image push a new one (which in turn
# replaces the instance — the relay is immutable infrastructure).
resource "linode_image" "relay" {
  label       = "zeus-relay"
  description = "Minimal NixOS frp relay for zeus; built from proxy/ in cwrunix-server-config"
  region      = "us-ord"
  tags        = ["zeus", "relay"]

  file_path = var.image_path
  file_hash = filemd5(var.image_path)
}

resource "linode_instance" "relay" {
  label  = "zeus-relay"
  region = linode_image.relay.region
  type   = "g6-nanode-1"
  image  = linode_image.relay.id

  # NixOS images carry no MBR bootloader (nixpkgs linode-image.nix builds
  # for Linode's GRUB 2 boot mode: Linode's GRUB reads /boot/grub/grub.cfg
  # off the disk). The API default kernel (linode/latest-*) would try to
  # boot the disk with a Linode-side kernel and fail.
  kernel = "linode/grub2"

  # Key-only SSH. root_pass is a throwaway: PasswordAuthentication is off
  # in the image; the Linode API just requires the field at creation.
  root_pass       = var.root_pass
  authorized_keys = [var.provision_ssh_pubkey]

  tags = ["zeus", "relay"]
}

# The instance's public IPv4 (linode_instance.ip_address is deprecated).
data "linode_instance_networking" "relay" {
  linode_id = linode_instance.relay.id
}

locals {
  proxy_ip = data.linode_instance_networking.relay.ipv4[0].public[0].address
}

# Grey-cloud A record: DNS only, Cloudflare's HTTP proxy is NOT in the
# path (it would strip the TS2021 Upgrade header). Replaces the legacy
# tunnel CNAME, which proxy-provision.service deletes before apply.
resource "cloudflare_dns_record" "headscale_zeus" {
  zone_id = var.cloudflare_zone_id
  name    = "headscale-zeus.cwrunix.com"
  type    = "A"
  content = local.proxy_ip
  proxied = false
  ttl     = 1 # automatic
}

# ---------------------------------------------------------------------------
# Mail (Stalwart on zeus, reached through this relay — see
# nixos/containers/mail.nix). All grey-cloud (Cloudflare can't proxy SMTP).
# DKIM records are NOT here: Stalwart publishes/rotates them itself via the
# scoped DNS token (dnsManagement in containers/mail.nix).
# ---------------------------------------------------------------------------

# The relay is the public face of the mailserver. This is the MX target,
# the TLS identity (Stalwart's ACME cert), and the rDNS/PTR name below.
resource "cloudflare_dns_record" "mail" {
  zone_id = var.cloudflare_zone_id
  name    = "mail.cwrunix.com"
  type    = "A"
  content = local.proxy_ip
  proxied = false
  ttl     = 1
}

resource "cloudflare_dns_record" "mail_mx" {
  zone_id  = var.cloudflare_zone_id
  name     = "cwrunix.com"
  type     = "MX"
  content  = "mail.cwrunix.com"
  priority = 10
  ttl      = 1
}

# Only the MX host (this relay) may send for @cwrunix.com: outbound mail
# originates here (smarthost), never from zeus's campus address.
resource "cloudflare_dns_record" "mail_spf" {
  zone_id = var.cloudflare_zone_id
  name    = "cwrunix.com"
  type    = "TXT"
  content = "v=spf1 mx -all"
  ttl     = 1
}

resource "cloudflare_dns_record" "mail_dmarc" {
  zone_id = var.cloudflare_zone_id
  name    = "_dmarc.cwrunix.com"
  type    = "TXT"
  content = "v=DMARC1; p=quarantine; rua=mailto:postmaster@cwrunix.com; fo=1"
  ttl     = 1
}

# PTR/rDNS for the relay IP -> mail.cwrunix.com. Linode requires the A
# record to resolve to the IP first.
resource "linode_rdns" "mail" {
  address = local.proxy_ip
  rdns    = cloudflare_dns_record.mail.name

  depends_on = [cloudflare_dns_record.mail]
}

output "proxy_ip" {
  value = local.proxy_ip
}
