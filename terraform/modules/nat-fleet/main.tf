# main.tf (terraform/modules/nat-fleet)
#
# The core module of the whole solution: provisions one pool ("fleet") of
# N independently-active, three-interface NAT node instances, and renders
# every node's cloud-init user-data from the ansible/ templates so each
# node boots up fully configured (nftables NAT rules, buddy-sync/FRR IP
# failover, the Prometheus exporter) with no manual post-boot steps.
#
# -----------------------------------------------------
# What this file creates:
#
# 1) locals.node_ids/node_vpc_ips/node_vlan_ips - Deterministic node names
#    and static VPC/VLAN IPs, computed from CIDR + offset so there is no
#    Terraform dependency cycle (see the cycle note further down).
# 2) linode_instance.node       - One Linode per node_id, with three NIC
#    interfaces: eth0 (real public IP, never VPC 1:1 NAT -- required for
#    buddy IP failover), eth1 (VPC, for buddy-pair conntrackd sync), eth2
#    (VLAN, transparent NAT for the private client fleet).
# 3) linode_instance_ip.extra_egress - Additional, non-shared public IPs
#    per node when egress_ips_per_node > 1 (more ephemeral-port headroom).
# 4) locals.node_cloud_init      - Renders ansible/cloud-init/nat-node.yaml.tftpl
#    (which in turn renders nftables.conf.tftpl) once per node, with
#    that node's own static IPs and this pool's feature flags baked in.
#
# -----------------------------------------------------
# Usage:
#
# - Call this module once per pool from your environment root module (see
#   terraform/environments/example/main.tf) -- once for the default
#   "shared" pool, and again per dedicated tenant pool if you need one.
# - node_count is the Terraform-managed floor; natctl can add elastic
#   nodes above it automatically (controller/natctl/cloud_init.py mirrors
#   this same three-interface layout for those) -- see docs/ARCHITECTURE.md
#   section 4.
# - See variables.tf for every input this module accepts, and outputs.tf
#   for what it exposes back to the caller (node IPs, IDs).
#
# -----------------------------------------------------
# Best Practices:
#
# - Never reference linode_instance.node[*].ip_address from inside this
#   file's own cloud-init rendering -- see the dependency-cycle note
#   further down. That's why nftables uses `masquerade` instead of a
#   literal SNAT IP, and why the node self-detects its own public IP at
#   boot instead.
# - Keep this file's cloud-init template arguments in sync with
#   controller/natctl/cloud_init.py's elastic-node path -- see
#   docs/RUNBOOK.md "Keep the two cloud-init renderers in sync".
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
  }
}

locals {
  # v9: natctl-on-node's package content is no longer read/embedded here
  # at all -- terraform/modules/artifacts uploads controller/natctl/*.py
  # once per environment and var.natctl_file_urls (passed in from
  # environments/example/main.tf) carries the resulting URLs straight
  # through to nat-node.yaml.tftpl's boot-time curl fetch. See that
  # module's main.tf header comment for why (Linode's 16384-byte decoded
  # cloud-init limit).

  node_ids = [for i in range(var.node_count) : "${var.fleet_label}-${i + 1}"]

  # M16: node_id -> its 0-based creation-order index, the same index
  # node_ids[i] used to derive that id in the first place. linode_instance.node
  # below is for_each-keyed by node_id (a set of strings), not count, so
  # this is how its dynamic "placement_group" block recovers "which
  # position is this node" to compute a contiguous placement-group block
  # assignment (floor(index / 5), see linode_placement_group.nodes below).
  node_index = {
    for i, id in local.node_ids : id => i
  }

  # Deterministic static IPs for both private-side interfaces, one per
  # node. Computed directly from the caller-supplied CIDR + offset rather
  # than looked up post-creation, for the same reason described in the
  # nftables/cloud-init comments below: avoiding a Terraform dependency
  # cycle. Multiple fleets/pools sharing the same VPC subnet or VLAN must
  # be given non-overlapping offset ranges.
  node_vpc_ips = {
    for i in range(var.node_count) :
    local.node_ids[i] => cidrhost(var.public_subnet_cidr, var.private_ip_offset + i)
  }

  node_vlan_ips = {
    for i in range(var.node_count) :
    local.node_ids[i] => cidrhost(var.vlan_cidr, var.vlan_ip_offset + i)
  }

  # v7: per-node instance_type override (docs/VERTICAL-SCALING.md) -- lets
  # a floor node that's been vertically-scaled by natctl's operator-driven
  # resize tool (natctl_cli's `resize` command) keep its new size on the
  # next `terraform apply`, instead of Terraform reverting it back to
  # var.instance_type. Any node_id NOT present in
  # var.node_instance_type_overrides falls back to the pool's base
  # var.instance_type, exactly as before this variable existed.
  node_instance_types = {
    for node_id in local.node_ids :
    node_id => lookup(var.node_instance_type_overrides, node_id, var.instance_type)
  }

  # M17 (roadmap/M17-reserved-ip-pool-and-prereservation.md): the first
  # length(var.reserved_ip_pool) node_ids (by creation order) are covered
  # by operator-supplied addresses the operator already owns; every
  # node_id past that still needs a FRESH linode_networking_ip.reserved
  # resource, same as before this variable existed. An empty
  # reserved_ip_pool (the default) makes this identical to every
  # node_id needing a new reservation -- fully backward compatible.
  node_ids_needing_new_reservation = slice(
    local.node_ids,
    min(length(var.reserved_ip_pool), length(local.node_ids)),
    length(local.node_ids),
  )
}

# Reserved public IPv4s (opt-in, reserved_ip_enabled) -- allocated UP
# FRONT, independently of linode_instance.node below, and handed to each
# node's `ipv4` argument at CREATE time (not assigned after the fact via
# linode_reserved_ip_assignment) so the node never gets Linode's normal
# ephemeral default IP in the first place -- no leftover unused address,
# no ambiguity about which of two eth0 addresses NAT/BGP should use. See
# variables.tf's reserved_ip_enabled docs and docs/ARCHITECTURE.md for the
# full rationale. Referencing this from linode_instance.node below (and
# from node_cloud_init further down) is NOT the dependency cycle the
# "intentionally NOT referencing linode_instance.node[*].ip_address"
# comment further down warns about -- that cycle is specifically about a
# resource referencing ITS OWN computed attribute; this is a distinct
# resource, computed independently, that linode_instance.node merely
# depends on (a normal forward reference).
resource "linode_networking_ip" "reserved" {
  for_each = var.reserved_ip_enabled ? toset(local.node_ids_needing_new_reservation) : toset([])

  type     = "ipv4"
  public   = true
  reserved = true
  region   = var.region
}

# M17: every floor node's reserved address, regardless of whether it came
# from the operator-supplied reserved_ip_pool (by creation-order position)
# or a freshly-created linode_networking_ip.reserved resource above. This
# is what linode_instance.node's ipv4 argument below actually reads --
# neither source is referenced directly there, so a node never needs to
# know or care which one it got. Empty map when reserved_ip_enabled is
# false, matching the feature's existing all-or-nothing gating.
locals {
  node_reserved_ips = var.reserved_ip_enabled ? merge(
    {
      for i, node_id in local.node_ids : node_id => var.reserved_ip_pool[i]
      if i < length(var.reserved_ip_pool)
    },
    {
      for node_id in local.node_ids_needing_new_reservation :
      node_id => linode_networking_ip.reserved[node_id].address
    },
  ) : {}
}

# A supplied reserved_ip_pool longer than node_count would leave its
# excess addresses permanently unused by this pool -- caught loudly at
# plan time with the exact counts needed to fix it, rather than the
# operator discovering the mistake by noticing an address never gets
# assigned to anything.
check "reserved_ip_pool_fits_node_count" {
  assert {
    condition     = !var.reserved_ip_enabled || length(var.reserved_ip_pool) <= var.node_count
    error_message = "reserved_ip_pool has ${length(var.reserved_ip_pool)} address(es) but node_count is only ${var.node_count} -- ${length(var.reserved_ip_pool) - var.node_count} of the supplied address(es) would never be assigned to any node in this pool. Either trim reserved_ip_pool to at most node_count entries, or raise node_count."
  }
}

# M16 (roadmap/M16-anti-affinity-placement-groups.md, opt-in
# placement_group_enabled): spreads this pool's floor nodes across
# separate physical Akamai hosts, closing the gap docs/COMPARISON.md
# documents (a correlated physical-host failure taking out both buddy
# pair members with nothing to fail over to). Akamai caps a group at 5
# Linodes, so a pool bigger than 5 nodes gets ceil(node_count / 5)
# groups instead of failing to apply -- linode_instance.node's dynamic
# "placement_group" block below assigns node index i to group
# floor(i / 5), a CONTIGUOUS block assignment (not round-robin) chosen
# because buddy.py pairs healthy nodes in roughly creation order, so
# most pairs land inside one group and stay protected -- see this
# milestone's roadmap file "Residual gap" section for what this does and
# doesn't guarantee once a pool spans more than one group.
resource "linode_placement_group" "nodes" {
  count = var.placement_group_enabled ? ceil(var.node_count / 5) : 0

  label                  = "${var.fleet_label}-pg-${count.index}"
  region                 = var.region
  placement_group_type   = "anti_affinity:local"
  placement_group_policy = var.placement_group_policy
}

resource "linode_instance" "node" {
  for_each = toset(local.node_ids)

  label           = each.key
  region          = var.region
  type            = local.node_instance_types[each.key]
  image           = var.image
  authorized_keys = var.authorized_keys
  root_pass       = var.root_pass
  firewall_id     = var.firewall_id
  tags            = concat(var.tags, ["lng", "lng-fleet", "lng-pool-${var.pool_name}"])
  # Assigns this node's reserved address (operator-supplied via M17's
  # reserved_ip_pool, or freshly created above -- see node_reserved_ips)
  # as its public IPv4 on creation, instead of Linode's usual
  # auto-assigned ephemeral one. null (the argument's own default/unset
  # state) when reserved_ip_enabled is false, preserving the original
  # ephemeral-IP behavior exactly.
  ipv4 = var.reserved_ip_enabled ? [local.node_reserved_ips[each.key]] : null

  # M16 (opt-in placement_group_enabled): assigns this node to its
  # contiguous-block placement group -- floor(index / 5) matches
  # linode_placement_group.nodes' own count-based indexing above. A
  # dynamic block with zero-or-one iterations (rather than a plain
  # nested block) so the "off" case produces the exact same resource
  # shape as before this feature existed -- an empty for_each list
  # emits zero placement_group blocks. The provider's id argument here
  # is numeric, unlike linode_placement_group's own string .id output,
  # hence tonumber().
  dynamic "placement_group" {
    for_each = var.placement_group_enabled ? [1] : []
    content {
      id = tonumber(linode_placement_group.nodes[floor(local.node_index[each.key] / 5)].id)
    }
  }

  # eth0 — a REAL, direct public IP (NOT VPC's 1:1 NAT). This is deliberate:
  # Linode's VPC IPs cannot use the IP Sharing/failover feature at all
  # ("VPC IP addresses cannot use IP sharing or IP transfer features" —
  # Linode VPC reference docs), so buddy IP failover (ip_failover_enabled)
  # would be structurally impossible if this node's public identity came
  # from VPC instead. See docs/ARCHITECTURE.md §3.0/§3.5.
  interface {
    purpose = "public"
  }

  # eth1 — VPC. Serves buddy-pair conntrackd sync traffic. Deliberately
  # NOT used to route the
  # private client fleet's default gateway — that was the original v1-v3
  # design and it does not work: Linode's VPC fabric does not forward a
  # packet through a peer instance to a non-VPC-member destination, only
  # validated empirically (see docs/ARCHITECTURE.md §3.0's writeup of the
  # tcpdump-based test that proved this).
  interface {
    purpose   = "vpc"
    subnet_id = var.public_subnet_id
    ipv4 {
      vpc = local.node_vpc_ips[each.key]
    }
  }

  # eth2 — VLAN. The private client fleet lives here (no public IP, not in
  # VPC) and gets transparent NAT egress through this node, exactly the way
  # the original NAT gateway concept was meant to work — just on the
  # network that actually supports gateway-style routing on Linode.
  interface {
    purpose      = "vlan"
    label        = var.vlan_label
    ipam_address = "${local.node_vlan_ips[each.key]}/${split("/", var.vlan_cidr)[1]}"
  }

  metadata {
    # v9: gzip before base64 -- cloud-init auto-detects and decompresses
    # gzip'd user-data natively, and this alone (independent of the
    # artifacts-module fetch-at-boot change above) buys meaningful headroom
    # against Linode's 16384-byte DECODED limit for whatever's still
    # embedded inline (nftables.conf, systemd units, env
    # files). See terraform/modules/artifacts/main.tf's header comment for
    # why gzip alone isn't sufficient for exporter.py/buddy_sync.py/the
    # natctl package specifically.
    user_data = base64gzip(local.node_cloud_init[each.key])
  }

  # NOTE on Network Helper (found live in M28, NOT fixed here -- see
  # roadmap/M28-full-production-readiness-pass.md): Linode's Network Helper
  # regenerates /etc/systemd/network/05-eth0.network on every boot from
  # this instance's CURRENT IP-sharing state, and it renders every
  # ipv4.shared address (buddy IP failover's whole mechanism --
  # ip_failover_enabled, POST /networking/ips/share) as an extra static
  # `Address=` line on eth0 -- not something FRR/BGP announces dynamically
  # from lo the way docs/ARCHITECTURE.md §3.6 describes. Both buddies end
  # up with the SAME address bound to eth0 simultaneously (confirmed live:
  # lng-shared-1 booted with lng-shared-2's own IP statically on its eth0),
  # breaking that node's own egress outright, and it recurs on every
  # reboot. linode/linode provider ~> 2.9 (pinned in versions.tf) exposes
  # NEITHER a top-level network_helper attribute NOR a helpers block on
  # linode_instance/its config block for the implicit-config pattern used
  # here (confirmed against this version's own provider schema) -- so this
  # can't be fixed in HCL without a provider bump, which is out of scope
  # for a live-testing pass. The elastic-node path (fleet.py's
  # create_instance() payload, a raw POST /linode/instances call) CAN and
  # does set network_helper=false directly, since that API field exists at
  # instance-create time regardless of provider support.
}

# Extra egress IPs beyond each node's primary public IP. These stay on the
# SAME node permanently — there's no partner to share them with, so this is
# a plain additional-IP allocation, not the IP-sharing API (that's reserved
# for the PRIMARY eth0 address via ip_failover_enabled below).
resource "linode_instance_ip" "extra_egress" {
  for_each = {
    for pair in flatten([
      for node_id in local.node_ids : [
        for n in range(var.egress_ips_per_node - 1) : {
          key     = "${node_id}-${n}"
          node_id = node_id
        }
      ]
    ]) : pair.key => pair
  }

  linode_id = linode_instance.node[each.value.node_id].id
  public    = true
}

# v10: per-node dynamic config, uploaded to Object Storage instead of
# embedded inline in cloud-init -- see ansible/cloud-init/nat-node.yaml.tftpl's
# v10 header note and terraform/modules/artifacts/main.tf's header comment
# for the full "why" (Linode's 16384-byte decoded cloud-init limit, and why
# v9's exporter.py/buddy_sync.py/natctl-package fix alone wasn't enough
# headroom once natctl_on_node_enabled is on). Unlike
# the STATIC files terraform/modules/artifacts uploads once per
# environment, this differs per node (vpc_ip, vlan_ip, cidrs,
# reserved_public_ip), so each node gets its own object -- content =
# (not source =) the same templatefile() call previously inlined directly
# into node_cloud_init below.
locals {
  object_storage_base_url = "https://${var.object_storage_bucket}.${var.object_storage_s3_region}.linodeobjects.com"
}

resource "linode_object_storage_object" "nftables_conf" {
  for_each = toset(local.node_ids)

  bucket     = var.object_storage_bucket
  region     = var.object_storage_s3_region
  access_key = var.object_storage_access_key
  secret_key = var.object_storage_secret_key

  key = "lng-artifacts/${var.pool_name}/${each.key}/nftables.conf"
  content = templatefile("${path.module}/../../../ansible/templates/nftables.conf.tftpl", {
    public_iface         = "eth0"
    vpc_iface            = "eth1"
    vlan_iface           = "eth2"
    private_subnet_cidrs = var.private_subnet_cidrs
    reserved_public_ip   = var.reserved_ip_enabled ? local.node_reserved_ips[each.key] : ""
    pool_subnet_cidr     = var.natctl_roster_url != "" ? var.public_subnet_cidr : ""
    # BUG FIX (found live, 2026-08-02): this local nftables ruleset never
    # opened 8099 for natctl_on_node_enabled -- see that rule's own
    # comment in nftables.conf.tftpl for the full story.
    natctl_on_node_enabled = var.natctl_on_node_enabled
  })
  acl = "public-read"
  etag = md5(templatefile("${path.module}/../../../ansible/templates/nftables.conf.tftpl", {
    public_iface           = "eth0"
    vpc_iface              = "eth1"
    vlan_iface             = "eth2"
    private_subnet_cidrs   = var.private_subnet_cidrs
    reserved_public_ip     = var.reserved_ip_enabled ? local.node_reserved_ips[each.key] : ""
    pool_subnet_cidr       = var.natctl_roster_url != "" ? var.public_subnet_cidr : ""
    natctl_on_node_enabled = var.natctl_on_node_enabled
  }))
}

locals {
  # NOTE: intentionally NOT referencing linode_instance.node[*].ip_address
  # anywhere in this file — that attribute is only known after a node is
  # created, and node_cloud_init is embedded in that SAME node's own create
  # call, so referencing it here would be a Terraform dependency cycle.
  # nftables.conf.tftpl uses `masquerade` instead of a literal IP for
  # exactly this reason, and the node self-discovers its own public IP(s)
  # for the exporter (and for FRR's router-id/primary announcement, if ip_failover_enabled) via a
  # runcmd step — see the comments in both
  # ansible/templates/nftables.conf.tftpl and
  # ansible/cloud-init/nat-node.yaml.tftpl for the full explanation. Extra
  # egress IPs (egress_ips_per_node > 1) are real and get allocated above,
  # but wiring them into the live NAT rules is a documented day-2 step
  # (docs/RUNBOOK.md) for the same underlying reason.

  node_cloud_init = {
    for node_id in local.node_ids : node_id => templatefile("${path.module}/../../../ansible/cloud-init/nat-node.yaml.tftpl", {
      node_name = node_id
      node_id   = node_id
      pool_name = var.pool_name
      vpc_ip    = local.node_vpc_ips[node_id]
      vlan_ip   = local.node_vlan_ips[node_id]
      # M31 Finding 18: prefix lengths for the eth1/eth2 systemd-networkd
      # DNS-scope-removal override files (see nat-node.yaml.tftpl's own
      # runcmd comment for the full root cause) -- same source CIDRs
      # already used elsewhere in this module, just also needed here.
      vpc_prefix          = split("/", var.public_subnet_cidr)[1]
      vlan_prefix         = split("/", var.vlan_cidr)[1]
      conntrack_max       = var.conntrack_max
      natctl_roster_url   = var.natctl_roster_url
      ip_failover_enabled = var.ip_failover_enabled
      linode_bgp_dcid     = var.linode_bgp_dcid
      # Empty string (not reserved_ip_enabled) means "keep self-detecting
      # eth0's IP at boot, exactly as before this feature existed" -- see
      # nftables.conf.tftpl and nat-node.yaml.tftpl's own comments on
      # reserved_public_ip for what changes when this is non-empty.
      reserved_public_ip = var.reserved_ip_enabled ? local.node_reserved_ips[node_id] : ""
      # v10: nftables.conf is now fetched at boot from the per-node Object
      # Storage object uploaded above, not embedded as content: here --
      # see this file's top-of-file v10 comment and
      # ansible/cloud-init/nat-node.yaml.tftpl's own v10 header note for
      # why v9 alone wasn't enough headroom.
      nftables_conf_url = "${local.object_storage_base_url}/${linode_object_storage_object.nftables_conf[node_id].key}"

      # v9: exporter.py/buddy_sync.py are fetched at boot from Object
      # Storage (terraform/modules/artifacts), not embedded as content:
      # here -- see that module's main.tf header for why (Linode's
      # 16384-byte decoded cloud-init limit). v10: the systemd unit files
      # themselves (previously the only remaining inline pieces) are now
      # ALSO fetched -- see terraform/modules/artifacts' new static
      # uploads.
      exporter_py_url            = var.exporter_py_url
      nat_exporter_service_url   = var.nat_exporter_service_url
      buddy_sync_py_url          = var.buddy_sync_py_url
      lng_buddy_sync_service_url = var.lng_buddy_sync_service_url
      # v8: systemd TEMPLATE unit buddy_sync.py's apply_conntrack_peers()
      # instantiates per conntrack peer (conntrackd@<peer_node_id>.service)
      # -- see buddy.py's compute_conntrack_peers() and
      # docs/ARCHITECTURE.md §3.6 "Odd node counts".
      conntrackd_peer_service_url = var.conntrackd_peer_service_url

      # v6: natctl-on-node (opt-in) -- see variables.tf's
      # natctl_on_node_enabled and docs/RUNBOOK.md. Mirrors
      # terraform/modules/observability/main.tf's equivalent arguments
      # exactly, just fanned out per-node instead of to one dedicated
      # host. natctl_file_urls/natctl_requirements_txt_url/natctl_service_url
      # are cheap to pass even when disabled (nat-node.yaml.tftpl's own
      # %{ if natctl_on_node_enabled ~} guard is what actually matters).
      natctl_on_node_enabled      = var.natctl_on_node_enabled
      natctl_file_urls            = var.natctl_file_urls
      natctl_requirements_txt_url = var.natctl_requirements_txt_url
      natctl_service_url          = var.natctl_service_url
      # v10: natctl_config_yaml itself stays embedded (NOT fetched) --
      # every other Object Storage upload here is public-read, and this
      # document carries this pool's plaintext root_pass. See
      # nat-node.yaml.tftpl's v10 header note.
      natctl_config_yaml        = var.natctl_config_yaml
      linode_token              = var.linode_token
      object_storage_access_key = var.object_storage_access_key
      object_storage_secret_key = var.object_storage_secret_key

      # v21: "source" (default) preserves every line above exactly as it
      # behaved before this variable existed. See
      # controller/natctl/cloud_init.py's matching v21 comment and
      # docs/PUBLISHING.md. The three *_bin_url vars are cheap to pass
      # even when disabled, same reasoning as natctl_file_urls above.
      agent_distribution = var.agent_distribution
      exporter_bin_url   = var.exporter_bin_url
      buddy_sync_bin_url = var.buddy_sync_bin_url
      natctl_bin_url     = var.natctl_bin_url
    })
  }
}
