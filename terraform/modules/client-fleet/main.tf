# main.tf (terraform/modules/client-fleet) -- CUSTOMER-REPO BINARY VARIANT
#
# This is the customer-repo-overlay equivalent of the dev repo's
# terraform/modules/client-fleet/main.tf. Functionally identical except
# for one thing: client-agent is fetched as a pre-compiled BINARY at boot
# (over the fleet's own VLAN/VPC, via natctl's GET /agents/client-agent --
# see controller/natctl/api.py) instead of being embedded as Python
# source (gzip+base64) the way the dev repo does it. See this overlay's
# ansible/cloud-init/client-node.yaml.tftpl for the fetch mechanics and
# why python3's stdlib urllib is used instead of curl.
#
# variables.tf/outputs.tf are UNCHANGED from the dev repo -- only this
# file (main.tf) is replaced. The publish pipeline (see
# scripts/publish/assemble_customer_repo.py in the dev repo) copies
# variables.tf/outputs.tf verbatim and overlays this file on top.
#
# -----------------------------------------------------
# What changed vs. the dev repo's main.tf:
#
# - locals.combined_agent_bundle_raw/combined_agent_bundle_gz_b64 and
#   locals.agent_bundle_extractor_py are REMOVED -- nothing here reads
#   client-agent/lng_client_agent.py off disk at all (that file doesn't
#   exist in this repo -- it's compiled into a binary and uploaded to
#   Object Storage instead, see terraform/modules/artifacts).
# - The client_cloud_init templatefile() call no longer passes
#   combined_agent_bundle_gz_b64/agent_bundle_extractor_py -- the
#   overlay client-node.yaml.tftpl doesn't have those template variables
#   at all, it fetches instead.
# - Everything else (interface layouts, static VLAN addressing, the four
#   interface_mode variants) is identical to the dev repo -- this is
#   purely an agent-delivery-mechanism change, not a networking change.
#
# -----------------------------------------------------
# Author:
# - Sandip Gangdhar
# - GitHub: https://github.com/sandipgangdhar
#
# (c) Linode-NAT-Gateway (LNG) | Developed by Sandip Gangdhar | 2026
# -----------------------------------------------------

terraform {
  required_providers {
    linode = {
      source  = "linode/linode"
      version = "~> 2.9"
    }
  }
}

locals {
  label_prefix = "lng-client-${var.group_name}"
  node_ids     = [for i in range(var.client_count) : "${local.label_prefix}-${i + 1}"]

  attach_public    = var.interface_mode == "public_vlan"
  attach_vpc_plain = var.interface_mode == "vpc_vlan"
  attach_vpc_nat   = var.interface_mode == "public_vpc_vlan"

  vlan_iface = var.interface_mode == "vlan_only" ? "eth0" : "eth1"

  enable_nat_egress = contains(["vlan_only", "vpc_vlan"], var.interface_mode)

  natctl_roster_url_effective = (
    var.interface_mode == "vlan_only" && var.natctl_roster_vlan_url != ""
    ? var.natctl_roster_vlan_url
    : var.natctl_roster_base_url
  )

  vlan_prefix = try(split("/", var.vlan_cidr)[1], "")
  client_vlan_ips = {
    for i, node_id in local.node_ids :
    node_id => cidrhost(var.vlan_cidr, var.static_vlan_ip_offset + i)
  }
}

resource "linode_instance" "client" {
  for_each = toset(local.node_ids)

  label           = each.key
  region          = var.region
  type            = var.instance_type
  image           = var.image
  authorized_keys = var.authorized_keys
  root_pass       = var.root_pass
  firewall_id     = var.firewall_id
  tags            = concat(var.tags, ["lng", "lng-client", "lng-client-group-${var.group_name}"])

  dynamic "interface" {
    for_each = local.attach_public ? [1] : []
    content {
      purpose = "public"
    }
  }

  dynamic "interface" {
    for_each = local.attach_vpc_plain ? [1] : []
    content {
      purpose   = "vpc"
      subnet_id = var.public_subnet_id
    }
  }

  dynamic "interface" {
    for_each = local.attach_vpc_nat ? [1] : []
    content {
      purpose   = "vpc"
      subnet_id = var.public_subnet_id
      ipv4 {
        nat_1_1 = "any"
      }
    }
  }

  interface {
    purpose      = "vlan"
    label        = var.vlan_label
    ipam_address = "${local.client_vlan_ips[each.key]}/${local.vlan_prefix}"
  }

  metadata {
    user_data = base64gzip(local.client_cloud_init[each.key])
  }
}

locals {
  client_cloud_init = {
    for node_id in local.node_ids : node_id => templatefile("${path.module}/../../../ansible/cloud-init/client-node.yaml.tftpl", {
      node_name              = node_id
      node_id                = node_id
      pool_name              = var.pool_name
      vlan_iface             = local.vlan_iface
      static_vlan_ip         = local.client_vlan_ips[node_id]
      vlan_prefix            = local.vlan_prefix
      enable_nat_egress      = local.enable_nat_egress
      natctl_roster_base_url = local.natctl_roster_url_effective
    })
  }
}
