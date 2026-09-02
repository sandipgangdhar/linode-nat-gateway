# main.tf (terraform/modules/vpc)
#
# v11: BYO VPC/subnets. This module used to create the Linode VPC and its
# subnets itself (linode_vpc.this, linode_vpc_subnet.public/private) --
# per an explicit decision to keep VPC (and VLAN) creation out of scope of
# this automation, it no longer does. You bring an existing VPC and its
# subnet(s) (Cloud Manager, linode-cli, or your own separate Terraform --
# see docs/RUNBOOK.md "Bring your own VPC") and this module only reads
# them back (via data sources, so it can still compute each subnet's real
# CIDR for the firewall rules below without asking you to retype it) and
# creates the three Cloud Firewalls that attach to your NAT/observability/
# client instances (v14: added the client one). VLANs never had a standalone Terraform resource to begin with
# (a VLAN is just a label -- see terraform/modules/nat-fleet's vlan_label/
# vlan_cidr and terraform/environments/example/variables.tf's vlan_*
# variables) so there was nothing to remove there beyond making those
# already-implicit values real, overridable input variables instead of
# hardcoded locals -- see environments/example/main.tf.
#
# -----------------------------------------------------
# Resources created:
#
# 1) linode_firewall.nat_node    - Default-deny Cloud Firewall attached to
#                                   every NAT node: allows the exporter
#                                   port (9200), the natctl roster API
#                                   (8099 -- BUG FIX, 2026-08-02: needed
#                                   here too for natctl_on_node_enabled,
#                                   not just on control_plane below), and
#                                   SSH. Outbound is unrestricted because
#                                   these instances exist to perform
#                                   egress NAT.
# 2) linode_firewall.control_plane - Default-deny Cloud Firewall attached to
#                                   the natctl/observability host: allows
#                                   the roster API (8099), Grafana/
#                                   Prometheus/Alertmanager UI ports
#                                   (3000/9090/9093), and SSH.
# 3) linode_firewall.client        - v14: Default-deny Cloud Firewall for
#                                   client instances. As of M20
#                                   (2026-09-02) this project no longer
#                                   creates those instances itself -- a
#                                   customer attaches this firewall (its
#                                   id is a Terraform output) to whatever
#                                   they create via their own automation.
#                                   SSH only -- client-agent needs no
#                                   inbound port at all.
#
# Data sources (not resources -- nothing here is created or destroyed by
# Terraform):
#
# 1) data.linode_vpc_subnet.public  - Looks up var.public_subnet_id's real
#                                      CIDR (ipv4), which the firewall rules
#                                      below and several downstream modules
#                                      (nat-fleet's cidrhost() math) need.
# 2) data.linode_vpc_subnet.private - Same, for each entry in
#                                      var.private_subnet_ids.
#
# -----------------------------------------------------
# Usage:
#
# - Create your VPC and its public subnet (plus any private subnets you
#   need) yourself first -- Cloud Manager, linode-cli, or a separate,
#   one-time Terraform config are all fine, this module has no opinion.
#   See docs/RUNBOOK.md "Bring your own VPC" for the exact linode-cli
#   commands and the CIDR-planning constraints nat-fleet/observability
#   already assume (their cidrhost()-based static addressing needs the
#   subnet's CIDR to have enough headroom for every pool's offset range).
# - Pass the resulting vpc_id/public_subnet_id/private_subnet_ids into this
#   module (see terraform/environments/example/main.tf).
# - Called once per environment to create the three Cloud Firewalls every
#   nat-fleet pool, the observability instance, and every client-fleet group
#   attach to.
# - Cloud Firewall only filters the public and VPC interfaces -- it does
#   NOT filter VLAN traffic at all. The node's own nftables ruleset
#   (ansible/templates/nftables.conf.tftpl) is the only access control for
#   VLAN (eth2) traffic. See docs/ARCHITECTURE.md section 3.7.
# - Tighten the SSH and Grafana/Prometheus/Alertmanager inbound rules to
#   your admin CIDR before going to production; they default to
#   0.0.0.0/0 so the example environment works out of the box.
#
# -----------------------------------------------------
# Best Practices:
#
# - Keep this firewall coarse-grained (allow the port fleet-wide) and let
#   fine-grained, per-pool/per-tenant restriction happen in nftables
#   (node-side) -- that split is deliberate throughout this project, not
#   accidental duplication.
# - Review firewall_id / control_plane_firewall_id outputs before wiring
#   new modules to this VPC so you don't accidentally bypass either
#   firewall.
#
# -----------------------------------------------------
# Author:
# - Sandip Gangdhar
# - GitHub: https://github.com/sandipgangdhar
#
# (c) Linode-NAT-Gateway (LNG) | Developed by Sandip Gangdhar | 2026
# -----------------------------------------------------

# Every module that directly uses a provider's resources must declare its
# own required_providers block with an explicit source -- the root
# environment's own required_providers (terraform/environments/example/
# versions.tf) does NOT propagate this source address down to child
# modules automatically (see HashiCorp's Provider Requirements docs:
# "If you omit the source argument when requiring a provider, Terraform
# uses an implied source address of registry.terraform.io/hashicorp/
# <LOCAL NAME>"). Without this block, `terraform init` fails trying to
# resolve a nonexistent hashicorp/linode provider instead of the real
# linode/linode one -- this was a real, latent bug in this module until
# discovered against a live `terraform init` run. Version constraint
# mirrors the root's.
terraform {
  required_providers {
    linode = {
      source  = "linode/linode"
      version = "~> 2.9"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# roadmap/M18-firewall-label-collision.md: Akamai enforces Cloud Firewall
# labels as unique ACCOUNT-WIDE, not scoped to this Terraform state -- so
# if state is ever lost or reset while these three firewalls survive on
# the account, the next `apply` hard-fails with
# `[400] Label must be unique among your Cloud Firewalls` (live-hit,
# 2026-09-01). One random suffix, shared across all three labels below,
# fixes this by construction rather than just detecting it: losing state
# also loses THIS resource, so the next `apply` after a state loss mints
# a NEW suffix and the freshly-created firewalls can never collide with
# whatever orphaned ones the lost-state run left behind. No `keepers` --
# deliberately generated once and left stable across every normal
# `apply`, exactly like any other resource that lives in state.
#
# byte_length=1 (2 hex chars), not 2 -- Akamai's firewall label cap is 32
# characters (the same limit hit for real once before, M9), and with the
# longest fixed suffix ("-control-plane-fw", 17 chars) plus the default
# var.label ("lng-example", 11 chars) already at 28, there's only 4
# characters of budget left including the separator. byte_length=2 (4
# hex chars + separator = 5) would have exceeded 32 immediately even for
# TODAY'S live label, with no state loss needed to trigger it -- confirmed
# by hand before implementing, not discovered live. 1 byte (256 possible
# suffixes) is a much smaller space than 2 bytes (65536), but the
# property that matters is only "the NEW suffix differs from the ONE
# specific orphaned suffix a lost-state rebuild left behind" -- a 1-in-256
# accidental re-collision is a rare, retry-able edge case, not a
# systemic problem. The precondition below is the safety net for anyone
# using a longer custom var.label than fits this budget.
resource "random_id" "fw_suffix" {
  byte_length = 1
}

# Fails loudly and clearly at plan time if var.label is too long to fit
# Akamai's 32-character firewall label cap once the fixed suffix words
# and the random suffix above are accounted for -- rather than a
# cryptic raw `[400] Attribute label string length must be between 3
# and 32` from the API (the exact class of confusing failure this whole
# milestone exists to move away from). "-control-plane-fw-XX" (the
# longest of the three fixed suffixes, plus a hyphen and the 2-hex-char
# random suffix) is 20 characters, so var.label can be at most 12.
resource "terraform_data" "label_length_check" {
  lifecycle {
    precondition {
      condition     = length(var.label) <= 12
      error_message = "var.label (\"${var.label}\", ${length(var.label)} chars) is too long -- with the fixed \"-control-plane-fw-\" suffix and this module's 2-character random suffix, Akamai's 32-character Cloud Firewall label cap allows var.label up to 12 characters. Shorten var.label."
    }
  }
}

# v11: read-only lookups against your existing VPC subnet(s) -- confirmed
# against the Linode Terraform provider's own data-source docs
# (registry.terraform.io/providers/linode/linode/latest/docs/data-sources/
# vpc_subnet): vpc_id + id in, label/ipv4/ipv6/etc back out. Fetching the
# CIDR this way (rather than adding a public_subnet_cidr input variable)
# means there's exactly one place your subnet's real CIDR can come from --
# it can never drift from what you typed, because nothing here lets you
# type it.
data "linode_vpc_subnet" "public" {
  vpc_id = var.vpc_id
  id     = var.public_subnet_id
}

data "linode_vpc_subnet" "private" {
  for_each = var.private_subnet_ids

  vpc_id = var.vpc_id
  id     = each.value
}

# Default-deny Cloud Firewall applied to every NAT node. v2 (active-active
# fleet): each node is fully independent, so there's no peer/VRRP/BGP/
# conntrackd traffic to allow anymore — just the exporter/healthz port
# (scraped by natctl, client-agents, and Prometheus) and SSH. Outbound is
# unrestricted because these instances exist to perform egress NAT
# (tenant-level restriction, if needed, is enforced in nftables on the
# node, not here).
resource "linode_firewall" "nat_node" {
  label = "${var.label}-nat-node-fw-${random_id.fw_suffix.hex}"

  inbound_policy  = "DROP"
  outbound_policy = "ACCEPT"

  # nat_exporter's /metrics (Prometheus) and /healthz (natctl, scraping from
  # the observability instance in this same VPC subnet). This does NOT
  # cover the VLAN client fleet's access to 9200 (client-agent instances
  # probe /healthz directly) — Cloud Firewall does not filter VLAN traffic
  # at all (confirmed against Linode's docs, see docs/ARCHITECTURE.md
  # §3.7), so that path is gated entirely by nftables on the node itself
  # (ansible/templates/nftables.conf.tftpl), not here. var.private_subnet_ids
  # (this module's own VPC subnets) intentionally isn't included below
  # anymore — v4 moved the private client fleet off VPC and onto VLAN, see
  # docs/ARCHITECTURE.md §3.0.
  inbound {
    label    = "nat-exporter"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "9200"
    ipv4     = [data.linode_vpc_subnet.public.ipv4]
  }

  # BUG FIX (found live, 2026-08-02): natctl's roster API (8099) was only
  # ever opened on the SEPARATE control_plane firewall below -- fine when
  # natctl runs on the dedicated observability host, but when
  # natctl_on_node_enabled is true, natctl runs directly ON the NAT nodes
  # instead (this firewall, not control_plane), and nothing opened 8099
  # here. Confirmed live: a client-fleet instance's client-agent could
  # reach a NAT node's exporter (9200, already allowed above) but every
  # roster fetch against that same node's 8099 timed out -- Cloud
  # Firewall silently dropping it, not a natctl/DNS/routing problem.
  # Matches control_plane's own natctl-api rule exactly (same port, same
  # VPC-internal-only source restriction) -- harmless to always add here
  # too: when natctl_on_node_enabled is false, nothing listens on 8099 on
  # a NAT node either, so this rule simply goes unused in that case.
  inbound {
    label    = "natctl-api"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "8099"
    ipv4     = concat([data.linode_vpc_subnet.public.ipv4], [for s in data.linode_vpc_subnet.private : s.ipv4])
  }

  # BUG FIX (found live, 2026-08-29, roadmap/M3-ha-failover.md): Cloud
  # Firewall never had ANY rule for conntrackd buddy-pair sync -- its
  # inbound_policy=DROP catch-all silently blocked this UDP traffic at
  # the network level, upstream of and independent from nftables' own
  # matching rule (ansible/templates/nftables.conf.tftpl /
  # cloud_init.py's render_nftables(), both fixed in the same commit).
  # Confirmed live: raw `nc -u` between two nodes' VPC IPs, on a port
  # inside this exact range, delivered nothing until this rule was added
  # -- nftables' own rule alone was necessary but not sufficient.
  # buddy_sync.py's _conntrack_peer_port() derives each relationship's
  # actual port as CONNTRACKD_BASE_PORT (3780) + hash%CONNTRACKD_PORT_RANGE
  # (1000), i.e. 3780-4779 inclusive -- see that module for why a single
  # fixed port can't be used (two simultaneous peer relationships, e.g. a
  # triangle's hub, need independently-numbered ports to avoid colliding).
  inbound {
    label    = "conntrackd-sync"
    action   = "ACCEPT"
    protocol = "UDP"
    ports    = "3780-4779"
    ipv4     = [data.linode_vpc_subnet.public.ipv4]
  }

  # SSH for operator access — scoped to var.admin_cidrs (roadmap/M2-security.md)
  inbound {
    label    = "ssh"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "22"
    ipv4     = var.admin_cidrs
  }

  # roadmap/M2-security.md: Cloud Firewall does NOT auto-exempt ICMP from an
  # inbound_policy=DROP catch-all -- confirmed live during BGP-failover
  # verification (M3), where an admin needed to ping a node's own public IP
  # to observe a live failover and found it silently blocked. A genuine
  # operational need (diagnosing exactly this kind of failover), scoped the
  # same way as SSH -- not opened to the whole internet.
  inbound {
    label    = "icmp"
    action   = "ACCEPT"
    protocol = "ICMP"
    ipv4     = var.admin_cidrs
  }
}

# Separate firewall for the natctl/observability host: needs the exporter
# rule too (it scrapes every node) plus its own API port for client-agents
# to poll the fleet roster, and the Grafana/Prometheus UI ports.
resource "linode_firewall" "control_plane" {
  label = "${var.label}-control-plane-fw-${random_id.fw_suffix.hex}"

  inbound_policy  = "DROP"
  outbound_policy = "ACCEPT"

  inbound {
    label    = "natctl-api"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "8099"
    ipv4     = concat([data.linode_vpc_subnet.public.ipv4], [for s in data.linode_vpc_subnet.private : s.ipv4])
  }

  inbound {
    label    = "grafana-prometheus"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "3000,9090,9093"
    ipv4     = var.admin_cidrs # roadmap/M2-security.md -- was 0.0.0.0/0
  }

  # Real bug found live, 2026-09-02, verifying M24 against the live
  # customer-repo deployment: with natctl_on_node_enabled, EVERY NAT
  # node runs its own natctl instance, which queries THIS host's
  # Prometheus directly for autoscale metrics (prometheus_client.py's
  # PrometheusClient, used by fleet.py's evaluate_autoscale()) -- VPC
  # -sourced traffic, not admin-sourced. The grafana-prometheus rule
  # above only ever allowed var.admin_cidrs, so every natctl-on-node
  # instance's Prometheus query has been timing out on every single
  # reconcile pass since natctl_on_node_enabled was turned on --
  # confirmed via a real natctl journalctl log on a live node
  # (`HTTPConnectionPool(host='10.60.32.5', port=9090): ... Connection
  # ... timed out`). PrometheusClient.scalar()'s fail-soft default
  # (0.0) silently masked this: every autoscale metric has been reading
  # a stuck 0.0 the entire time, meaning a real scale-out-worthy load
  # spike would never have been detected, and a low-watermark scale-in
  # metric misreading 0.0 as "very low utilization" could trigger an
  # inappropriate scale-in. Only port 9090 (the query API) needs
  # VPC-internal access -- 3000 (Grafana UI)/9093 (Alertmanager UI) are
  # human-facing and correctly stay admin_cidrs-only.
  inbound {
    label    = "prometheus-vpc-internal"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "9090"
    ipv4     = concat([data.linode_vpc_subnet.public.ipv4], [for s in data.linode_vpc_subnet.private : s.ipv4])
  }

  inbound {
    label    = "ssh"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "22"
    ipv4     = var.admin_cidrs
  }
}

# v14: minimal firewall for client instances -- SSH only. Deliberately its
# own firewall, not a reuse of nat_node's: client instances aren't NAT
# nodes and need none of nat_node's ports (the exporter) open at all --
# client-agent is outbound-only, no inbound port needed. As of M20
# (2026-09-02) this project doesn't create client instances anymore, but
# still creates and exposes this firewall (client_firewall_id output) for
# a customer to attach to instances their own automation creates -- same
# "coarse-grained, shared" reasoning as nat_node/control_plane above;
# fine-grained restriction, if ever needed, belongs on the instance
# itself.
resource "linode_firewall" "client" {
  label = "${var.label}-client-fw-${random_id.fw_suffix.hex}"

  inbound_policy  = "DROP"
  outbound_policy = "ACCEPT"

  inbound {
    label    = "ssh"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "22"
    ipv4     = var.admin_cidrs # roadmap/M2-security.md -- was 0.0.0.0/0
  }
}
