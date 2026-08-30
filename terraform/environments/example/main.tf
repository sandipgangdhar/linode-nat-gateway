# main.tf (terraform/environments/example)
#
# The wired-up, end-to-end example environment: one VPC, a shared NAT pool
# (the Terraform-managed floor), an optional dedicated pool for a
# higher-value tenant, and the single observability/control-plane instance
# that runs natctl + Prometheus + Grafana. This is the file to read to see
# how all the individual modules (vpc, nat-fleet, observability) compose
# into one working deployment -- `terraform apply` here is the fastest way
# to stand up the whole solution end-to-end.
#
# -----------------------------------------------------
# What this file wires together:
#
# 1) module.vpc                 - Creates the three Cloud Firewalls (NAT
#    node + control plane + client, v14) attached to YOUR existing
#    VPC/subnet(s) -- v11: this
#    automation no longer creates the VPC or its subnet(s) itself, see
#    that module's header comment and docs/RUNBOOK.md "Bring your own
#    VPC".
# 2) locals (natctl_private_ip / vlan_*_shared / vlan_*_dedicated_acme /
#    vlan_reserved_ceiling_*) - Deterministic addressing so every module
#    below can reference natctl's IP, each pool's VLAN, and each pool's
#    reserved static-IP ceiling without a cross-module dependency cycle.
# 3) module.nat_fleet_shared     - The default pool every tenant uses
#    unless assigned elsewhere.
# 4) module.nat_fleet_dedicated_acme - An optional second pool
#    demonstrating isolated/reserved capacity for one tenant (toggle with
#    var.enable_dedicated_pool_example).
# 5) locals.natctl_pool_shared / natctl_pool_dedicated_acme / natctl_pools /
#    natctl_config_yaml - Composes the full natctl.yaml (natctl.example.yaml
#    shape) as a Terraform value, so natctl's elastic-node provisioning
#    knows about both pools.
# 6) module.observability        - The natctl + Prometheus + Grafana
#    instance, given the composed natctl_config_yaml above.
# 7) module.client_fleet         - v14: optional client (downstream
#    application/VPN server) instances, one module call per var.client_groups
#    entry -- creates nothing when that map is left at its default ({}). See
#    terraform/modules/client-fleet's own header comment and docs/RUNBOOK.md
#    "Onboard a client instance (automated)".
#
# -----------------------------------------------------
# Usage:
#
# - Create a VPC + subnet yourself first (see docs/RUNBOOK.md "Bring your
#   own VPC") -- v11: this automation no longer creates one for you.
# - Copy terraform.tfvars.example to terraform.tfvars, fill in your Linode
#   API token/SSH key/region/vpc_id/public_subnet_id, then
#   `terraform init && terraform apply`.
# - See outputs.tf for what to do next (client-agent install URLs, Grafana
#   URL).
# - See docs/RUNBOOK.md for day-2 operations once this is live.
#
# -----------------------------------------------------
# Best Practices:
#
# - Keep every pool's private_ip_offset/vlan_ip_offset/elastic_ip_offset_start
#   ranges non-overlapping -- this file's comments show the exact ranges in
#   use so a new pool can pick a clear one.
# - Treat this environment as a template to copy, not a shared environment
#   to keep extending indefinitely -- create a new environments/<name>/
#   directory per real deployment instead.
#
# -----------------------------------------------------
# Author:
# - Sandip Gangdhar
# - GitHub: https://github.com/sandipgangdhar
#
# (c) Linode-NAT-Gateway (LNG) | Developed by Sandip Gangdhar | 2026
# -----------------------------------------------------

# v11: BYO VPC -- this module no longer creates the VPC or its subnet(s)
# itself (see terraform/modules/vpc/main.tf's header comment). vpc_id/
# public_subnet_id/private_subnet_ids come straight from variables.tf,
# which you set in your own terraform.tfvars -- see docs/RUNBOOK.md
# "Bring your own VPC" for how to create them first.
module "vpc" {
  source = "../../modules/vpc"

  label = var.label

  vpc_id             = var.vpc_id
  public_subnet_id   = var.public_subnet_id
  private_subnet_ids = var.private_subnet_ids
  admin_cidrs        = var.admin_cidrs
}

locals {
  # The observability instance's private IP is a deterministic offset
  # within the shared VPC subnet (cidrhost is a pure function, not a
  # resource attribute), so — same trick as node_private_ips in
  # terraform/modules/nat-fleet — every fleet module below can reference
  # this value with NO dependency on the observability instance actually
  # existing yet. This is what lets buddy-sync (and client-agent) point at
  # natctl's roster API without a cross-module cycle. See module
  # "observability" below, whose own private_ip variable is given this
  # exact same value.
  natctl_private_ip = cidrhost(module.vpc.public_subnet_cidr, 5)

  # v6: once natctl runs on every NAT node instead of the dedicated
  # observability host (natctl_on_node_enabled), the roster API client-agent
  # and buddy-sync poll has to point somewhere that's ACTUALLY running
  # natctl -- the observability host may not even exist anymore (see
  # create_observability_instance below). Points at the shared pool's first
  # Terraform-managed floor node (cidrhost(public_subnet_cidr, 20), the same
  # deterministic formula nat-fleet's own locals.node_vpc_ips uses for
  # offset 20 + index 0) -- known at plan time with no dependency cycle,
  # same trick natctl_private_ip already relies on above. HONEST CAVEAT:
  # this is a single node, not a highly-available endpoint -- natctl's
  # read-only roster work runs on every leader-eligible node (see
  # main.py's reconcile_once()), so any node would answer, but this
  # environment doesn't load-balance across them. See docs/RUNBOOK.md's
  # natctl-on-node section for how to put a DNS round-robin or small L4
  # balancer in front of every node's :8099 in production instead of
  # relying on one node's availability.
  natctl_roster_base_url = (
    var.natctl_on_node_enabled
    ? "http://${cidrhost(module.vpc.public_subnet_cidr, 20)}:8099"
    : "http://${local.natctl_private_ip}:8099"
  )

  # v20 (found live, 2026-08-02/03): natctl_roster_base_url above is
  # always VPC-addressed, unreachable for a true "vlan_only" client-fleet
  # group (no VPC interface at all) -- see client-fleet/variables.tf's
  # natctl_roster_vlan_url description for the full story. Unlike
  # natctl_roster_base_url (one address works for every pool, because
  # every pool's NAT nodes share this environment's one VPC subnet),
  # VLANs are pool-scoped and non-routable to each other -- a pool's
  # vlan_only clients can only ever reach a node on THEIR OWN pool's
  # VLAN. So this is a map, one entry per pool (see pool_vlan_cidrs
  # below), each pointing at that pool's own first floor node's VLAN IP
  # -- offset 20, the same vlan_ip_offset convention nat-fleet's own
  # locals.node_vlan_ips uses, so this is always that pool's
  # lng-<pool>-1 node. Empty map when natctl_on_node_enabled is false:
  # that offset-20 node isn't running natctl either way then, same
  # caveat natctl_roster_base_url above already has.
  natctl_roster_vlan_urls = var.natctl_on_node_enabled ? {
    for pool_name, cidr in local.pool_vlan_cidrs :
    pool_name => "http://${cidrhost(cidr, 20)}:8099"
  } : {}

  # VLAN CIDRs for the private client fleet — v4 moved client traffic off
  # VPC and onto VLAN (VPC can't transit-route to non-VPC destinations,
  # see docs/ARCHITECTURE.md §3.0). Linode VLANs have no standalone
  # Terraform resource/subnet object (unlike VPC subnets above) — a VLAN is
  # just a label, and its address space is whatever CIDR you choose here
  # and pass to every attached instance's ipam_address. One VLAN per pool,
  # matching nat-fleet's one-vlan_label-per-fleet granularity. These are a
  # completely separate address space from the VPC subnets above on
  # purpose — VLAN (L2) and VPC (L3) are unrelated fabrics here. v11:
  # sourced from variables.tf (overridable from terraform.tfvars) instead
  # of hardcoded here -- see that file's matching v11 comment block.
  vlan_label_shared         = var.vlan_label_shared
  vlan_cidr_shared          = var.vlan_cidr_shared
  vlan_label_dedicated_acme = var.vlan_label_dedicated_acme
  vlan_cidr_dedicated_acme  = var.vlan_cidr_dedicated_acme

  # v12: single source of truth for every pool's addressing offsets --
  # previously these were separate hardcoded literals scattered across the
  # nat_fleet_shared/nat_fleet_dedicated_acme module calls (vlan_ip_offset,
  # private_ip_offset) and the natctl_pool_shared/natctl_pool_dedicated_acme
  # locals (elastic_ip_offset_start) below. Naming them once here lets the
  # reserved-ceiling computation immediately below reference the SAME numbers those
  # blocks use, instead of a human keeping two copies in sync by hand.
  vlan_ip_offset                         = 20 # shared by both pools -- see each module call's private_ip_offset/vlan_ip_offset for why this is safe (separate address spaces)
  elastic_ip_offset_start_shared         = 100
  elastic_ip_offset_start_dedicated_acme = 150
  # v16: named here (was two separate hardcoded "2" literals -- one on
  # module.nat_fleet_dedicated_acme's node_count below, one on
  # natctl_pool_dedicated_acme's min_nodes further down) so the new
  # floor-vs-elastic-offset check block below, the module call, and
  # natctl's own min_nodes all reference the exact same number instead of
  # a human keeping three copies in sync by hand -- same "single source
  # of truth" reasoning as vlan_ip_offset/elastic_ip_offset_start_* above.
  dedicated_acme_pool_floor_nodes = 2
  dedicated_acme_pool_max_nodes   = 6 # mirrors module.nat_fleet_dedicated_acme's node_count=2 floor + natctl_pool_dedicated_acme's max_nodes=6 below (not a variable -- this example pool's ceiling is fixed, unlike the shared pool's shared_pool_max_nodes)

  # v13: same-VLAN mode -- vlan_label_shared and vlan_label_dedicated_acme
  # are now ALLOWED to be the same VLAN label. Real-world reason: some
  # customers already run one VLAN per account for BOTH NAT gateway traffic
  # and VPN traffic, and standing up a second, VPN-only VLAN just so this
  # example's two pools can each keep their own separate VLAN isn't
  # practical for them. When both pools share one VLAN, they share one real
  # L2 broadcast domain -- see vlan_cidr_shared's description in
  # variables.tf for why that's normally unsafe (no cross-pool address
  # coordination anywhere in this codebase). same_vlan_mode below is what
  # turns on the coordination needed to make it safe: vlan_cidr_dedicated_acme's
  # ENTIRE block (its own floor+elastic node IPs AND its own reserved-window ceiling) is
  # carved out of vlan_cidr_shared and excluded wholesale from the shared
  # pool's own reserved-window ceiling (see vlan_usable_ceiling_shared below) -- see
  # the "same_vlan_dedicated_acme_reservation_valid" check block further
  # down for the plan-time validation that makes this safe rather than just
  # assumed.
  same_vlan_mode = var.enable_dedicated_pool_example && var.vlan_label_shared == var.vlan_label_dedicated_acme

  # Plain-integer (base-256) encodings of each CIDR's network/broadcast
  # address. Terraform's built-in cidrhost() only gives you an address AS AN
  # OFFSET WITHIN one CIDR -- it has no function to compare two DIFFERENT
  # CIDRs' address ranges against each other, which same_vlan_mode's
  # reservation math needs (is vlan_cidr_dedicated_acme's block nested
  # inside vlan_cidr_shared's, and where exactly does it start, in terms
  # cidrhost(vlan_cidr_shared, ...) can consume?). Converting each address
  # to a plain integer via its 4 octets makes that a normal numeric
  # comparison -- no provider or external tool needed, pure Terraform.
  _ipv4_to_int = {
    for ip in toset([
      cidrhost(local.vlan_cidr_shared, 0),
      cidrhost(local.vlan_cidr_shared, -1),
      cidrhost(local.vlan_cidr_dedicated_acme, 0),
      cidrhost(local.vlan_cidr_dedicated_acme, -1),
      ]) : ip => (
      tonumber(split(".", ip)[0]) * 16777216 +
      tonumber(split(".", ip)[1]) * 65536 +
      tonumber(split(".", ip)[2]) * 256 +
      tonumber(split(".", ip)[3])
    )
  }

  vlan_shared_net_int      = local._ipv4_to_int[cidrhost(local.vlan_cidr_shared, 0)]
  vlan_shared_bcast_int    = local._ipv4_to_int[cidrhost(local.vlan_cidr_shared, -1)]
  vlan_dedicated_net_int   = local._ipv4_to_int[cidrhost(local.vlan_cidr_dedicated_acme, 0)]
  vlan_dedicated_bcast_int = local._ipv4_to_int[cidrhost(local.vlan_cidr_dedicated_acme, -1)]

  # Offset (within vlan_cidr_shared) where the shared pool's OWN floor +
  # elastic static VLAN IPs stop and its reserved windows would otherwise end --
  # named here (rather than left inline) so both vlan_reserved_ceiling_shared
  # below AND the same-VLAN check block can reference the exact same
  # expression instead of a human keeping two copies in sync.
  shared_pool_own_ceiling_offset = local.vlan_ip_offset + local.elastic_ip_offset_start_shared + var.shared_pool_max_nodes + var.vlan_elastic_headroom_margin

  # v17: the dedicated-acme pool's own equivalent of
  # shared_pool_own_ceiling_offset above, pulled out into its own named
  # local (previously computed inline, once, only inside
  # vlan_reserved_ceiling_dedicated_acme below) so it can ALSO be referenced from
  # local.pool_static_reserved_start further down, without a human having
  # to keep two copies of this formula in sync.
  dedicated_acme_pool_own_ceiling_offset = local.vlan_ip_offset + local.elastic_ip_offset_start_dedicated_acme + local.dedicated_acme_pool_max_nodes + var.vlan_elastic_headroom_margin

  # v12: Reserved static-IP ceilings
  # are now COMPUTED from each pool's VLAN CIDR + the offsets above, instead
  # of hand-typed IP literals in variables.tf. Previously an operator had to
  # pick a range that (a) falls inside the right VLAN CIDR and (b) stays
  # clear of every node's static vlan_ip, entirely by hand, with NO
  # automated check -- the shipped defaults up to v11 actually got this
  # wrong (192.168.100.100 collided with the shared pool's first elastic
  # node at 192.168.100.120). The range now starts just past every address
  # a floor or elastic node could ever hold (vlan_ip_offset +
  # elastic_ip_offset_start + max_nodes) plus a configurable safety margin
  # (var.vlan_elastic_headroom_margin). HONEST CAVEAT: natctl's elastic offset
  # counter (_next_elastic_offset in controller/natctl/fleet.py) increments
  # once per node EVER provisioned in a pool's lifetime and is never reused
  # when a node drains, so max_nodes is not a hard ceiling on that counter
  # over a long enough time horizon -- the margin is a practical buffer
  # sized for realistic autoscaling churn, not a mathematical guarantee. See
  # docs/RUNBOOK.md for the full explanation. Override var.vlan_elastic_headroom_margin
  # if you expect heavy long-running scale-out/scale-in churn.
  #
  # v17: + var.client_static_vlan_reserved shifts the reserved window's start
  # out by exactly that many addresses, opening up a window
  # [shared_pool_own_ceiling_offset, shared_pool_own_ceiling_offset +
  # client_static_vlan_reserved - 1] for client_groups' opt-in
  # static_vlan_ip_offset use (see variables.tf's client_static_vlan_reserved
  # and docs/RUNBOOK.md's "Static VLAN IPs for client groups" section).
  # var.client_static_vlan_reserved defaults to 0, so this is a no-op
  # (identical address layout to pre-v17) unless an operator deliberately
  # raises it.
  #
  vlan_reserved_ceiling_shared = cidrhost(
    local.vlan_cidr_shared,
    local.shared_pool_own_ceiling_offset + var.client_static_vlan_reserved
  )

  # v13: in same_vlan_mode, the shared pool's reserved-window ceiling must stop BEFORE
  # vlan_cidr_dedicated_acme's block begins, instead of running all the way
  # to vlan_cidr_shared's last usable host -- that whole block (dedicated
  # nodes' static IPs AND its own reserved-window ceiling, computed independently below)
  # is reserved/excluded here so the two pools' reserved windows, now on the
  # same L2 segment, can never overlap. HONEST CAVEAT:
  # this keeps the shared pool's range a single CONTIGUOUS block (matching
  # how this project's static-IP windows are modeled today --
  # one contiguous range), which means any vlan_cidr_shared address space AFTER
  # vlan_cidr_dedicated_acme's block goes entirely unused for the shared
  # pool's own reserved windows, not just the reserved block itself -- place
  # vlan_cidr_dedicated_acme as close to the END of vlan_cidr_shared as
  # your sizing allows to avoid wasting address space. Supporting a
  # reservation in the MIDDLE of the shared range (with usable space on
  # both sides) would need real multi-range support wired through this
  # environment's addressing scheme, which is a real feature, not
  # implemented here.
  vlan_usable_ceiling_shared = (
    local.same_vlan_mode
    ? cidrhost(local.vlan_cidr_shared, local.vlan_dedicated_net_int - local.vlan_shared_net_int - 1)
    : cidrhost(local.vlan_cidr_shared, -2) # last usable host (skips broadcast) -- unchanged, separate-VLAN behavior
  )

  # Unaffected by same_vlan_mode -- entirely self-contained within
  # vlan_cidr_dedicated_acme's own (now possibly-nested) block, exactly the
  # same cidrhost() math as before same-VLAN mode existed.
  # v17: same + var.client_static_vlan_reserved treatment as
  # vlan_reserved_ceiling_shared above -- now expressed via
  # dedicated_acme_pool_own_ceiling_offset instead of repeating the
  # underlying formula inline a second time.
  # BUG FIX (found live, 2026-08-02): these two used to call cidrhost()
  # UNCONDITIONALLY, even though every actual consumer of them
  # (module.nat_fleet_dedicated_acme's count, natctl_pool_dedicated_acme's
  # inclusion in local.natctl_pools, etc.) is already gated on
  # var.enable_dedicated_pool_example. That mismatch meant a real, live
  # crash: with enable_dedicated_pool_example = false (the dedicated-acme
  # example pool entirely disabled and never actually provisioned) plus
  # sizing on the SHARED pool's own variables that happens to overflow
  # vlan_cidr_dedicated_acme's default /24 once client_static_vlan_reserved/
  # vlan_elastic_headroom_margin are raised (e.g. client_static_vlan_reserved =
  # 100, vlan_elastic_headroom_margin = 100 -- both entirely reasonable choices
  # for the SHARED pool, which is a /12 with room to spare), `terraform
  # plan`/`apply` failed outright with "prefix of 24 does not accommodate a
  # host numbered 376" for a pool that was never going to be created at
  # all. The vlan_reserved_ceiling_dedicated_acme_range_valid check block below already
  # had the right guard (!var.enable_dedicated_pool_example || ...) -- but a
  # `check` block's condition can only run AFTER the locals it references
  # evaluate without erroring, and cidrhost() itself has no such
  # short-circuit; it fails as a hard function-call error regardless of
  # whether anything downstream would ever use the result. Fixed by
  # applying the exact same guard directly to the cidrhost() calls: when
  # the dedicated-acme pool is disabled, fall back to a placeholder offset
  # (0 -- the CIDR's own network address, always valid for any prefix) that
  # is never actually read by anything (every real consumer is itself
  # count/for_each-gated on this same var), instead of computing the real,
  # potentially-overflowing formula for a pool that doesn't exist this
  # apply.
  vlan_reserved_ceiling_dedicated_acme = (
    var.enable_dedicated_pool_example
    ? cidrhost(
      local.vlan_cidr_dedicated_acme,
      local.dedicated_acme_pool_own_ceiling_offset + var.client_static_vlan_reserved
    )
    : cidrhost(local.vlan_cidr_dedicated_acme, 0) # placeholder, unused -- see BUG FIX comment above
  )
  vlan_usable_ceiling_dedicated_acme = (
    var.enable_dedicated_pool_example
    ? cidrhost(local.vlan_cidr_dedicated_acme, -2)
    : cidrhost(local.vlan_cidr_dedicated_acme, 0) # placeholder, unused -- see BUG FIX comment above
  )
}

# v18: plain-integer encodings of the four actual, final reserved-ceiling
# boundaries, for the two sanity checks just below. Kept SEPARATE from the
# _ipv4_to_int map above (rather than folded into it) because
# vlan_usable_ceiling_shared itself depends on vlan_dedicated_net_int/
# vlan_shared_net_int, which are THEMSELVES derived from _ipv4_to_int --
# adding vlan_usable_ceiling_shared to that same map's own input list would be a
# circular reference. Same "tonumber(split(".", ip)[n])" pattern as
# _ipv4_to_int, just applied directly and locally instead.
locals {
  vlan_reserved_ceiling_shared_int = (
    tonumber(split(".", local.vlan_reserved_ceiling_shared)[0]) * 16777216 +
    tonumber(split(".", local.vlan_reserved_ceiling_shared)[1]) * 65536 +
    tonumber(split(".", local.vlan_reserved_ceiling_shared)[2]) * 256 +
    tonumber(split(".", local.vlan_reserved_ceiling_shared)[3])
  )
  vlan_usable_ceiling_shared_int = (
    tonumber(split(".", local.vlan_usable_ceiling_shared)[0]) * 16777216 +
    tonumber(split(".", local.vlan_usable_ceiling_shared)[1]) * 65536 +
    tonumber(split(".", local.vlan_usable_ceiling_shared)[2]) * 256 +
    tonumber(split(".", local.vlan_usable_ceiling_shared)[3])
  )
  vlan_reserved_ceiling_dedicated_acme_int = (
    tonumber(split(".", local.vlan_reserved_ceiling_dedicated_acme)[0]) * 16777216 +
    tonumber(split(".", local.vlan_reserved_ceiling_dedicated_acme)[1]) * 65536 +
    tonumber(split(".", local.vlan_reserved_ceiling_dedicated_acme)[2]) * 256 +
    tonumber(split(".", local.vlan_reserved_ceiling_dedicated_acme)[3])
  )
  vlan_usable_ceiling_dedicated_acme_int = (
    tonumber(split(".", local.vlan_usable_ceiling_dedicated_acme)[0]) * 16777216 +
    tonumber(split(".", local.vlan_usable_ceiling_dedicated_acme)[1]) * 65536 +
    tonumber(split(".", local.vlan_usable_ceiling_dedicated_acme)[2]) * 256 +
    tonumber(split(".", local.vlan_usable_ceiling_dedicated_acme)[3])
  )
}

# v18: catches a real, previously-unvalidated gap -- cidrhost() only
# errors if vlan_reserved_ceiling_shared's offset exceeds what the CIDR can
# hold AT ALL; it has no idea vlan_usable_ceiling_shared even exists, so
# it happily computes a vlan_reserved_ceiling_shared that's numerically
# AFTER vlan_usable_ceiling_shared (an inverted, nonsensical range) as
# long as
# that start offset still fits somewhere inside the CIDR. Concretely: a
# large client_static_vlan_reserved (see variables.tf) pushes
# the reserved ceiling out; in same_vlan_mode, vlan_usable_ceiling_shared is ALSO a
# fixed, comparatively-nearby point (wherever vlan_cidr_dedicated_acme's
# nested block begins) rather than the CIDR's last usable host -- so this
# is easiest to hit with same_vlan_mode on and a smaller VLAN CIDR, but
# the check applies unconditionally either way.
check "vlan_reserved_ceiling_shared_range_valid" {
  assert {
    condition     = local.vlan_reserved_ceiling_shared_int <= local.vlan_usable_ceiling_shared_int
    error_message = "vlan_reserved_ceiling_shared (${local.vlan_reserved_ceiling_shared}) is now AFTER vlan_usable_ceiling_shared (${local.vlan_usable_ceiling_shared}) -- client_static_vlan_reserved (currently ${var.client_static_vlan_reserved}) is too large for vlan_cidr_shared's available address space (and, if same_vlan_mode is on, for the room left before vlan_cidr_dedicated_acme's nested block). Lower client_static_vlan_reserved, widen vlan_cidr_shared, or (in same_vlan_mode) move vlan_cidr_dedicated_acme's block further from vlan_cidr_shared's start."
  }
}

check "vlan_reserved_ceiling_dedicated_acme_range_valid" {
  assert {
    condition     = !var.enable_dedicated_pool_example || local.vlan_reserved_ceiling_dedicated_acme_int <= local.vlan_usable_ceiling_dedicated_acme_int
    error_message = "vlan_reserved_ceiling_dedicated_acme (${local.vlan_reserved_ceiling_dedicated_acme}) is now AFTER vlan_usable_ceiling_dedicated_acme (${local.vlan_usable_ceiling_dedicated_acme}) -- client_static_vlan_reserved (currently ${var.client_static_vlan_reserved}) is too large for vlan_cidr_dedicated_acme's available address space. Lower client_static_vlan_reserved, or widen vlan_cidr_dedicated_acme."
  }
}

# v13: plan-time validation for same_vlan_mode -- when vlan_label_shared and
# vlan_label_dedicated_acme are deliberately set to the SAME VLAN (see
# locals.same_vlan_mode above), the safety of vlan_usable_ceiling_shared's
# reservation logic depends on two things actually being true, neither of
# which Terraform enforces just by the math above running without erroring:
#
# 1) vlan_cidr_dedicated_acme's block must be fully NESTED inside
#    vlan_cidr_shared's block -- otherwise "exclude it from the shared
#    pool's range" doesn't even mean anything coherent (dedicated could be
#    a disjoint block elsewhere in address space entirely, or only
#    partially overlapping vlan_cidr_shared).
# 2) vlan_cidr_dedicated_acme's block must start AFTER
#    shared_pool_own_ceiling_offset (+ v17: client_static_vlan_reserved) --
#    otherwise it would collide with the shared pool's OWN floor/elastic
#    node static IPs, or with the shared pool's client_groups static
#    reservation window, both of which live at the LOW end of
#    vlan_cidr_shared and are never excluded by anything else (only the
#    reserved-window ceiling gets carved around the dedicated block).
#
# When same_vlan_mode is false (the default -- separate VLANs), this check
# is always true and does nothing, matching this environment's existing,
# already-safe behavior.
check "same_vlan_dedicated_acme_reservation_valid" {
  assert {
    condition = !local.same_vlan_mode || (
      local.vlan_dedicated_net_int >= local.vlan_shared_net_int &&
      local.vlan_dedicated_bcast_int <= local.vlan_shared_bcast_int &&
      local.vlan_dedicated_net_int > local.vlan_shared_net_int + local.shared_pool_own_ceiling_offset + var.client_static_vlan_reserved
    )
    error_message = "vlan_label_shared == vlan_label_dedicated_acme (same-VLAN mode), but vlan_cidr_dedicated_acme is not safely nested inside vlan_cidr_shared. It must (1) fall entirely within vlan_cidr_shared's address range, and (2) start after offset ${local.shared_pool_own_ceiling_offset + var.client_static_vlan_reserved} within vlan_cidr_shared (vlan_ip_offset + elastic_ip_offset_start_shared + shared_pool_max_nodes + vlan_elastic_headroom_margin + client_static_vlan_reserved), so it doesn't collide with the shared pool's own floor/elastic node static IPs or its client_groups static reservation window. See docs/RUNBOOK.md's \"Same-VLAN mode\" and \"Static VLAN IPs for client groups\" sections."
  }
}

# v16: plan-time validation that a pool's own FLOOR node count can never
# grow large enough to collide with that same pool's elastic node range.
# Found live, 2026-08-02, during a design discussion: floor nodes occupy
# offsets [vlan_ip_offset, vlan_ip_offset + floor_nodes - 1] within their
# VLAN CIDR; elastic nodes start at a fixed elastic_ip_offset_start (100
# for shared, 150 for dedicated-acme). The 80-address gap between them
# (20..100) is generous headroom for realistic floor node counts, but
# nothing previously stopped an operator from setting
# shared_pool_floor_nodes to something large enough to walk into that
# gap -- Terraform would have applied it silently, producing a real
# floor-node/elastic-node VLAN IP collision the first time natctl
# provisioned an elastic node. Unlike the same-VLAN check above, this
# has nothing to do with same_vlan_mode -- it's a pool's own floor count
# against its own elastic start, always checked.
check "shared_pool_floor_nodes_below_elastic_offset" {
  assert {
    condition     = local.vlan_ip_offset + var.shared_pool_floor_nodes <= local.elastic_ip_offset_start_shared
    error_message = "shared_pool_floor_nodes (${var.shared_pool_floor_nodes}) would give the shared pool's floor nodes VLAN offsets ${local.vlan_ip_offset}..${local.vlan_ip_offset + var.shared_pool_floor_nodes - 1}, which reaches or passes elastic_ip_offset_start_shared (${local.elastic_ip_offset_start_shared}) -- elastic nodes' own static VLAN IPs start there, so this would be a real IP collision the first time natctl provisions an elastic node. Lower shared_pool_floor_nodes, or raise elastic_ip_offset_start_shared in locals (and re-check shared_pool_own_ceiling_offset/vlan_reserved_ceiling_shared, which move with it) before applying."
  }
}

check "dedicated_acme_pool_floor_nodes_below_elastic_offset" {
  assert {
    condition = !var.enable_dedicated_pool_example || (
      local.vlan_ip_offset + local.dedicated_acme_pool_floor_nodes <= local.elastic_ip_offset_start_dedicated_acme
    )
    error_message = "dedicated_acme_pool_floor_nodes (${local.dedicated_acme_pool_floor_nodes}) would give the dedicated-acme pool's floor nodes VLAN offsets ${local.vlan_ip_offset}..${local.vlan_ip_offset + local.dedicated_acme_pool_floor_nodes - 1}, which reaches or passes elastic_ip_offset_start_dedicated_acme (${local.elastic_ip_offset_start_dedicated_acme}). Raise elastic_ip_offset_start_dedicated_acme in locals before increasing dedicated_acme_pool_floor_nodes."
  }
}

# v17.2: fixed, isolated per-group STATIC VLAN SLOTS. v17.1's design fully
# automated address picking by tightly packing every static group's
# addresses back-to-back in name-sort order -- but that meant deleting or
# shrinking ONE static group could shift, and force recreation of, every
# OTHER static group that happened to sort after it on the same pool. As
# of v17.2, client_groups exposes an explicit `static_vlan_slot` integer
# (0, 1, 2, ...) per group instead -- a group's address is computed
# SOLELY from its own pool_name + static_vlan_slot + the pool-wide
# client_static_vlan_slot_size constant, never from any other group's
# client_count, existence, or slot. Nothing about group B's config or
# lifecycle can ever change group A's address, full stop -- the
# isolation is structural, not just usually-true.
locals {
  # Each pool's reserved-window START offset (within that pool's own VLAN
  # CIDR) -- the same shared_pool_own_ceiling_offset/
  # dedicated_acme_pool_own_ceiling_offset values vlan_reserved_ceiling_shared/
  # vlan_reserved_ceiling_dedicated_acme above already use to shift the reserved-window
  # pool's start out by var.client_static_vlan_reserved.
  pool_static_reserved_start = merge(
    { "shared" = local.shared_pool_own_ceiling_offset },
    var.enable_dedicated_pool_example ? { "dedicated-acme-corp" = local.dedicated_acme_pool_own_ceiling_offset } : {},
  )

  # Every client_groups entry now requires static_vlan_slot -- this local
  # exists mainly so static_client_offsets/static_client_ranges below
  # have a stable name to iterate, unchanged from the shape this had when
  # static addressing was still opt-in.
  static_client_groups = {
    for name, g in var.client_groups : name => g
  }

  # Each static group's own starting offset: its pool's reserved-window
  # start, plus (its own slot number * the pool-wide slot width). Compare
  # to v17.1's cumulative-sum-over-every-earlier-group formula -- this one
  # references ONLY local values that belong to the group itself (g.pool_name,
  # g.static_vlan_slot) plus one GLOBAL constant (var.client_static_vlan_slot_size)
  # that's the same for every group on a pool. No other group's data ever
  # enters this expression, which is exactly what makes the isolation
  # guarantee true rather than aspirational.
  static_client_offsets = {
    for name, g in local.static_client_groups : name =>
    local.pool_static_reserved_start[g.pool_name] + g.static_vlan_slot * var.client_static_vlan_slot_size
  }

  # Each static group's own [start, end] computed range (end inclusive) --
  # end uses this group's ACTUAL client_count (which may be less than the
  # full slot width; the unused remainder of the slot simply sits idle,
  # reserved but unclaimed by anyone, same trade-off as any fixed-size
  # bucket allocation). Feeds both check blocks below and
  # module.client_fleet's static_vlan_ip_offset argument further down.
  static_client_ranges = {
    for name, g in local.static_client_groups : name => {
      pool_name = g.pool_name
      slot      = g.static_vlan_slot
      start     = local.static_client_offsets[name]
      end       = local.static_client_offsets[name] + g.client_count - 1
    }
  }
}

# A static group's client_count must never exceed the fixed slot width --
# otherwise its LAST instance(s) would land past its own slot boundary and
# straight into the NEXT slot number's territory (which may well be
# claimed by a different group). This is the one thing slot-based
# isolation does NOT prevent by construction, since client_count is the
# group's own free-to-change value, not something this design fixes.
check "client_static_vlan_slot_capacity" {
  assert {
    condition = alltrue([
      for name, g in local.static_client_groups :
      g.client_count <= var.client_static_vlan_slot_size
    ])
    error_message = "One or more static_vlan_slot client_groups entries has client_count greater than var.client_static_vlan_slot_size (currently ${var.client_static_vlan_slot_size}) -- that group's last instance(s) would overflow past its own slot and into the next slot number's address range. Either lower that group's client_count, or raise client_static_vlan_slot_size (a per-pool, pool-wide change -- see that variable's own description for what else it affects)."
  }
}

# Two static groups on the SAME pool must never claim the same
# static_vlan_slot number -- a plain equality check, not a range-overlap
# one, since every slot is the same fixed width by construction (given
# the capacity check above holds, distinct slot numbers on the same pool
# can never produce overlapping address ranges).
check "client_static_vlan_slots_unique_per_pool" {
  assert {
    condition = alltrue([
      for pair in setproduct(keys(local.static_client_ranges), keys(local.static_client_ranges)) :
      pair[0] == pair[1] ||
      local.static_client_ranges[pair[0]].pool_name != local.static_client_ranges[pair[1]].pool_name ||
      local.static_client_ranges[pair[0]].slot != local.static_client_ranges[pair[1]].slot
    ])
    error_message = "Two or more client_groups entries claim the SAME static_vlan_slot number on the SAME pool -- every static group on a pool needs its own unique slot number (0, 1, 2, ...). Check each static group's static_vlan_slot against every other static group targeting the same pool_name."
  }
}

# The one thing fixed slots do NOT make impossible: running out of room in
# the reserved window itself. If a group's slot number is high enough
# that (slot + 1) * client_static_vlan_slot_size exceeds
# client_static_vlan_reserved, that group's addresses land PAST the
# reserved window -- straight into the next unreserved range. This check catches
# that at `terraform plan` time, with the exact numbers needed to fix it,
# instead of letting it apply and silently create a real address
# address collision.
check "client_static_vlan_offsets_within_pool_reservation" {
  assert {
    condition = alltrue([
      for name, r in local.static_client_ranges :
      r.end <= local.pool_static_reserved_start[r.pool_name] + var.client_static_vlan_reserved - 1
    ])
    error_message = "One or more client_groups' static_vlan_slot no longer fits inside client_static_vlan_reserved (currently ${var.client_static_vlan_reserved}) -- that group's slot would be packed past the reserved window and collide with unreserved address space. Raise var.client_static_vlan_reserved to at least (highest static_vlan_slot used on that pool + 1) * client_static_vlan_slot_size, then re-plan."
  }
}

locals {
  # v9: terraform/modules/artifacts needs the Object Storage S3 region/
  # cluster id (e.g. "in-maa-1"), which is NOT necessarily var.region (this
  # environment's compute region -- they're commonly different, since
  # Object Storage buckets don't have to live in the same data center as
  # your Linodes). Derived from natctl_object_storage_endpoint
  # ("https://in-maa-1.linodeobjects.com" -> "in-maa-1") rather than adding
  # yet another variable, since the endpoint already fully encodes it --
  # see Linode's own URL-format docs
  # (https://techdocs.akamai.com/cloud-computing/docs/access-buckets-and-files-through-urls),
  # confirmed directly, not assumed.
  natctl_object_storage_region = trimsuffix(trimprefix(var.natctl_object_storage_endpoint, "https://"), ".linodeobjects.com")
}

# v9: uploads exporter.py/buddy_sync.py/the natctl package to Object
# Storage ONCE for the whole environment, so every pool's nodes (floor and
# elastic alike) and the observability instance can fetch them at boot
# instead of embedding their content inline -- see
# terraform/modules/artifacts/main.tf's header comment for why this is
# required, not optional (Linode's 16384-byte decoded cloud-init limit).
# Reuses the SAME bucket/credentials natctl_object_storage_* already
# documents for leader-election lease storage -- see that variable's
# description in variables.tf.
module "artifacts" {
  source = "../../modules/artifacts"

  bucket     = var.natctl_object_storage_bucket
  s3_region  = local.natctl_object_storage_region
  access_key = var.natctl_object_storage_access_key
  secret_key = var.natctl_object_storage_secret_key
}

locals {
  # Short aliases for module.artifacts's outputs -- referenced from BOTH
  # the nat_fleet_shared/dedicated_acme/observability module calls below
  # AND the natctl_pool_shared/dedicated_acme maps further down (the
  # latter feed natctl_config_yaml, for natctl's OWN elastic-node
  # cloud-init renderer -- see docs/RUNBOOK.md "Keep the two cloud-init
  # renderers in sync").
  exporter_py_url   = module.artifacts.exporter_py_url
  buddy_sync_py_url = module.artifacts.buddy_sync_py_url
  natctl_file_urls  = module.artifacts.natctl_file_urls
  # CUSTOMER REPO: this environment always runs compiled agents, not
  # Python source -- see terraform/modules/artifacts (customer-repo
  # variant) and controller/natctl/cloud_init.py's/
  # ansible/cloud-init/*.tftpl's agent_distribution handling (dev repo,
  # v21). exporter_py_url/buddy_sync_py_url/natctl_file_urls above are
  # harmless, unused placeholders in this mode -- kept only because
  # nat-fleet/observability's variables.tf still declare them as required
  # inputs; every actual fetch uses the *_bin_url values below instead.
  agent_distribution = "binary"
  exporter_bin_url   = module.artifacts.exporter_bin_url
  buddy_sync_bin_url = module.artifacts.buddy_sync_bin_url
  natctl_bin_url     = module.artifacts.natctl_bin_url
  # See natctl_config_yaml's api.client_agent_bin_url further down for
  # where this is actually consumed.
  client_agent_bin_url = module.artifacts.client_agent_bin_url

  # v10: static, non-secret systemd unit files + requirements.txt -- see
  # terraform/modules/artifacts/main.tf's header comment for why these are
  # now also fetched at boot instead of embedded per-pool.
  nat_exporter_service_url    = module.artifacts.nat_exporter_service_url
  lng_buddy_sync_service_url  = module.artifacts.lng_buddy_sync_service_url
  conntrackd_peer_service_url = module.artifacts.conntrackd_peer_service_url
  natctl_service_url          = module.artifacts.natctl_service_url
  natctl_requirements_txt_url = module.artifacts.natctl_requirements_txt_url
}

# --- Shared pool: the default pool every tenant's traffic uses unless ---
# --- assigned to a dedicated pool. This is the Terraform-managed FLOOR; ---
# --- natctl adds elastic capacity above it (see docs/ARCHITECTURE.md §4). ---
module "nat_fleet_shared" {
  source = "../../modules/nat-fleet"

  fleet_label        = "lng-shared"
  pool_name          = "shared"
  region             = var.region
  vpc_id             = module.vpc.vpc_id
  public_subnet_id   = module.vpc.public_subnet_id
  public_subnet_cidr = module.vpc.public_subnet_cidr
  # VLAN CIDR (private client fleet), not the VPC private_subnet_cidrs
  # this used to point at in v3 — see the vlan_cidr_shared local above.
  private_subnet_cidrs = [local.vlan_cidr_shared]
  firewall_id          = module.vpc.firewall_id

  node_count        = var.shared_pool_floor_nodes
  private_ip_offset = local.vlan_ip_offset # occupies .20-.20+floor_nodes-1; natctl's elastic nodes start at .100 (see natctl_config below)
  instance_type     = var.nat_instance_type
  authorized_keys   = var.authorized_keys
  root_pass         = var.root_pass

  vlan_label     = local.vlan_label_shared
  vlan_cidr      = local.vlan_cidr_shared
  vlan_ip_offset = local.vlan_ip_offset # mirrors private_ip_offset above; separate address space so no collision risk

  ip_failover_enabled = var.ip_failover_enabled
  linode_bgp_dcid     = var.linode_bgp_dcid

  reserved_ip_enabled = var.reserved_ip_enabled

  natctl_roster_url = local.natctl_roster_base_url # buddy-sync + IP-failover opt-in — see docs/ARCHITECTURE.md §5

  # v6: natctl-on-node (opt-in) — see variables.tf's natctl_on_node_enabled.
  # natctl_config_yaml is defined further down (locals.natctl_config_yaml)
  # but Terraform resolves locals independently of source-file order, so
  # this forward reference is fine.
  natctl_on_node_enabled    = var.natctl_on_node_enabled
  natctl_config_yaml        = var.natctl_on_node_enabled ? local.natctl_config_yaml : ""
  linode_token              = var.natctl_on_node_enabled ? var.linode_token : ""
  object_storage_access_key = var.natctl_object_storage_access_key
  object_storage_secret_key = var.natctl_object_storage_secret_key

  # v9: fetched-at-boot artifact URLs -- see module.artifacts above and
  # terraform/modules/artifacts/main.tf's header comment.
  exporter_py_url   = module.artifacts.exporter_py_url
  buddy_sync_py_url = module.artifacts.buddy_sync_py_url
  natctl_file_urls  = module.artifacts.natctl_file_urls
  # CUSTOMER REPO: this environment always runs compiled agents, not
  # Python source -- see terraform/modules/artifacts (customer-repo
  # variant) and controller/natctl/cloud_init.py's/
  # ansible/cloud-init/*.tftpl's agent_distribution handling (dev repo,
  # v21). exporter_py_url/buddy_sync_py_url/natctl_file_urls above are
  # harmless, unused placeholders in this mode -- kept only because
  # nat-fleet/observability's variables.tf still declare them as required
  # inputs; every actual fetch uses the *_bin_url values below instead.
  agent_distribution = "binary"
  exporter_bin_url   = module.artifacts.exporter_bin_url
  buddy_sync_bin_url = module.artifacts.buddy_sync_bin_url
  natctl_bin_url     = module.artifacts.natctl_bin_url

  # v10: static, non-secret systemd unit files + requirements.txt.
  nat_exporter_service_url    = module.artifacts.nat_exporter_service_url
  lng_buddy_sync_service_url  = module.artifacts.lng_buddy_sync_service_url
  conntrackd_peer_service_url = module.artifacts.conntrackd_peer_service_url
  natctl_service_url          = module.artifacts.natctl_service_url
  natctl_requirements_txt_url = module.artifacts.natctl_requirements_txt_url

  # v10: per-node dynamic conf upload (nftables.conf) -- reuses the SAME
  # Object Storage bucket module.artifacts and natctl's leader-election
  # lease already use. See terraform/modules/nat-fleet/main.tf's header
  # comment.
  object_storage_bucket    = var.natctl_object_storage_bucket
  object_storage_s3_region = local.natctl_object_storage_region
}

# --- Optional dedicated pool: isolated capacity for a specific tenant ---
# --- instead of sharing the pool above. Same module, different pool_name ---
# --- and a non-overlapping private_ip_offset in the same subnet. ---
module "nat_fleet_dedicated_acme" {
  source = "../../modules/nat-fleet"
  count  = var.enable_dedicated_pool_example ? 1 : 0

  fleet_label        = "lng-dedicated-acme"
  pool_name          = "dedicated-acme-corp"
  region             = var.region
  vpc_id             = module.vpc.vpc_id
  public_subnet_id   = module.vpc.public_subnet_id
  public_subnet_cidr = module.vpc.public_subnet_cidr
  # VLAN CIDR (private client fleet) — see vlan_cidr_dedicated_acme local.
  private_subnet_cidrs = [local.vlan_cidr_dedicated_acme]
  firewall_id          = module.vpc.firewall_id

  node_count        = local.dedicated_acme_pool_floor_nodes
  private_ip_offset = 50 # non-overlapping with the shared pool's 20-31 and natctl's elastic ranges below
  instance_type     = "g6-dedicated-8"
  authorized_keys   = var.authorized_keys
  root_pass         = var.root_pass

  vlan_label     = local.vlan_label_dedicated_acme
  vlan_cidr      = local.vlan_cidr_dedicated_acme
  vlan_ip_offset = local.vlan_ip_offset

  ip_failover_enabled = var.ip_failover_enabled
  linode_bgp_dcid     = var.linode_bgp_dcid

  reserved_ip_enabled = var.reserved_ip_enabled

  natctl_roster_url = local.natctl_roster_base_url

  # v6: natctl-on-node (opt-in) — see the matching block on
  # module.nat_fleet_shared above for the full explanation.
  natctl_on_node_enabled    = var.natctl_on_node_enabled
  natctl_config_yaml        = var.natctl_on_node_enabled ? local.natctl_config_yaml : ""
  linode_token              = var.natctl_on_node_enabled ? var.linode_token : ""
  object_storage_access_key = var.natctl_object_storage_access_key
  object_storage_secret_key = var.natctl_object_storage_secret_key

  exporter_py_url   = module.artifacts.exporter_py_url
  buddy_sync_py_url = module.artifacts.buddy_sync_py_url
  natctl_file_urls  = module.artifacts.natctl_file_urls
  # CUSTOMER REPO: this environment always runs compiled agents, not
  # Python source -- see terraform/modules/artifacts (customer-repo
  # variant) and controller/natctl/cloud_init.py's/
  # ansible/cloud-init/*.tftpl's agent_distribution handling (dev repo,
  # v21). exporter_py_url/buddy_sync_py_url/natctl_file_urls above are
  # harmless, unused placeholders in this mode -- kept only because
  # nat-fleet/observability's variables.tf still declare them as required
  # inputs; every actual fetch uses the *_bin_url values below instead.
  agent_distribution = "binary"
  exporter_bin_url   = module.artifacts.exporter_bin_url
  buddy_sync_bin_url = module.artifacts.buddy_sync_bin_url
  natctl_bin_url     = module.artifacts.natctl_bin_url

  # v10: static, non-secret systemd unit files + requirements.txt.
  nat_exporter_service_url    = module.artifacts.nat_exporter_service_url
  lng_buddy_sync_service_url  = module.artifacts.lng_buddy_sync_service_url
  conntrackd_peer_service_url = module.artifacts.conntrackd_peer_service_url
  natctl_service_url          = module.artifacts.natctl_service_url
  natctl_requirements_txt_url = module.artifacts.natctl_requirements_txt_url

  # v10: per-node dynamic conf uploads -- see the matching block on
  # module.nat_fleet_shared above for the full explanation.
  object_storage_bucket    = var.natctl_object_storage_bucket
  object_storage_s3_region = local.natctl_object_storage_region
}

locals {
  # natctl's own elastic-node provisioning (fleet.py + cloud_init.py) mirrors
  # the same three-interface layout (VLAN + FRR) as the Terraform floor
  # nodes above, so elastic capacity behaves identically to floor capacity
  # from a NAT/failover standpoint. private_subnet_cidrs
  # below is the VLAN CIDR (not a VPC subnet) for the same reason it is on
  # the nat-fleet module calls above.
  natctl_pool_shared = {
    region               = var.region
    vpc_id               = module.vpc.vpc_id
    public_subnet_id     = module.vpc.public_subnet_id
    public_subnet_cidr   = module.vpc.public_subnet_cidr
    private_subnet_cidrs = [local.vlan_cidr_shared]
    # BUG FIX (found live, 2026-08-01): vlan_label/vlan_cidr were entirely
    # missing from this object. config.py's PoolConfig requires both (no
    # default -- "VLAN every node's eth2 joins for the private client
    # fleet ... required in v4 regardless of ip_failover"), so
    # Config.load() raised TypeError: PoolConfig.__init__() missing 2
    # required positional arguments on EVERY natctl start, for any pool,
    # confirmed live as the actual reason natctl.service was crash-looping
    # (6000+ restarts) on an already-running node. This wasn't specific to
    # that one node's stale config file -- this composition never set
    # these fields for ANY node, ever. Mirrors module.nat_fleet_shared's
    # own vlan_label/vlan_cidr arguments below (same source locals).
    vlan_label = local.vlan_label_shared
    vlan_cidr  = local.vlan_cidr_shared
    # The address marking the top of this pool's Terraform-managed
    # static VLAN reservation window -- fleet.py's _provision() refuses
    # to hand a new elastic node an address at or past this ceiling.
    vlan_static_ceiling = local.vlan_reserved_ceiling_shared
    # BUG FIX (found live, 2026-08-01): linode_firewall.id is a STRING in
    # the Linode Terraform provider's schema, even though it's a numeric
    # ID -- yamlencode() faithfully preserves that as a quoted YAML string
    # ("99779873"), but config.py's PoolConfig.firewall_id is typed int,
    # and the Linode API's POST /linode/instances rejects a string
    # firewall_id outright ("Must be of type Integer") when natctl tries
    # to provision an elastic node. tonumber() here, not a Python-side
    # fix, since every OTHER numeric field pulled from this module (vpc_id,
    # public_subnet_id) already comes through as a real number and this is
    # the one exception.
    firewall_id                  = tonumber(module.vpc.firewall_id)
    authorized_keys              = var.authorized_keys
    root_pass                    = var.root_pass
    min_nodes                    = var.shared_pool_floor_nodes
    max_nodes                    = var.shared_pool_max_nodes
    instance_type                = var.nat_instance_type
    elastic_ip_offset_start      = local.elastic_ip_offset_start_shared
    conntrack_buddy_sync_enabled = true
    # BUG FIX (found live, 2026-08-29, roadmap/M1-live-deployment.md):
    # var.ip_failover_enabled/var.linode_bgp_dcid were never threaded into
    # this pool's natctl config at all -- FRR itself still got the right
    # dcid (via nat_fleet_shared's own cloud-init rendering, a completely
    # separate path), so each node correctly self-announced its own public
    # IP as primary and BGP peering worked. But natctl never learned
    # ip_failover was enabled for this pool, so it never computed
    # ip_failover_self_ip/ip_failover_buddy_ips (confirmed empty/null in
    # the live roster for every node), so buddy-sync never had a secondary
    # announcement to add to any node's frr.conf -- meaning a dead node's
    # buddy was never actually configured to take over its IP, even with
    # ip-sharing manually configured via the API. This was a complete,
    # silent failure of the documented HA mechanism via the standard
    # deployment path, not just a config nicety.
    ip_failover_enabled    = var.ip_failover_enabled
    linode_bgp_dcid        = var.linode_bgp_dcid
    reserved_ip_enabled    = var.reserved_ip_enabled
    natctl_roster_base_url = local.natctl_roster_base_url
    # v6: elastic nodes natctl provisions for this pool also get natctl
    # installed on themselves (leader-election-eligible), matching the
    # Terraform floor's natctl_on_node_enabled above — see
    # config.py's PoolConfig.natctl_on_node_enabled docstring.
    natctl_on_node_enabled = var.natctl_on_node_enabled
    # v9: fetched-at-boot artifact URLs, mirroring
    # module.nat_fleet_shared's exporter_py_url/buddy_sync_py_url/
    # natctl_file_urls above -- natctl's own elastic-node cloud-init
    # renderer (controller/natctl/cloud_init.py) needs the SAME URLs. See
    # terraform/modules/artifacts/main.tf's header comment.
    exporter_py_url   = local.exporter_py_url
    buddy_sync_py_url = local.buddy_sync_py_url
    natctl_file_urls  = local.natctl_file_urls
    # CUSTOMER REPO: see the identical comment in module.artifacts's own
    # locals alias block above -- this pool always runs compiled agents.
    agent_distribution = "binary"
    exporter_bin_url   = local.exporter_bin_url
    buddy_sync_bin_url = local.buddy_sync_bin_url
    natctl_bin_url     = local.natctl_bin_url
    # v10: static, non-secret systemd unit files + requirements.txt --
    # natctl's own elastic-node cloud-init renderer
    # (controller/natctl/cloud_init.py) needs the SAME URLs. See
    # terraform/modules/artifacts/main.tf's header comment.
    nat_exporter_service_url    = module.artifacts.nat_exporter_service_url
    lng_buddy_sync_service_url  = module.artifacts.lng_buddy_sync_service_url
    conntrackd_peer_service_url = module.artifacts.conntrackd_peer_service_url
    natctl_service_url          = module.artifacts.natctl_service_url
    natctl_requirements_txt_url = module.artifacts.natctl_requirements_txt_url
    # v10: bucket/region fleet.py uploads THIS pool's elastic nodes' own
    # rendered nftables.conf into before fetching
    # them at boot -- see controller/natctl/config.py's matching
    # PoolConfig fields and controller/natctl/fleet.py's _provision().
    object_storage_bucket    = var.natctl_object_storage_bucket
    object_storage_s3_region = local.natctl_object_storage_region
    autoscale = {
      auto_provision_enabled = true
      cooldown_seconds       = 300
    }
  }

  natctl_pool_dedicated_acme = {
    region               = var.region
    vpc_id               = module.vpc.vpc_id
    public_subnet_id     = module.vpc.public_subnet_id
    public_subnet_cidr   = module.vpc.public_subnet_cidr
    private_subnet_cidrs = [local.vlan_cidr_dedicated_acme]
    # BUG FIX (found live, 2026-08-01): see natctl_pool_shared's identical
    # comment above -- vlan_label/vlan_cidr were missing here too.
    vlan_label = local.vlan_label_dedicated_acme
    vlan_cidr  = local.vlan_cidr_dedicated_acme
    # See natctl_pool_shared's identical comment above.
    vlan_static_ceiling = local.vlan_reserved_ceiling_dedicated_acme
    # BUG FIX (found live, 2026-08-01): linode_firewall.id is a STRING in
    # the Linode Terraform provider's schema, even though it's a numeric
    # ID -- yamlencode() faithfully preserves that as a quoted YAML string
    # ("99779873"), but config.py's PoolConfig.firewall_id is typed int,
    # and the Linode API's POST /linode/instances rejects a string
    # firewall_id outright ("Must be of type Integer") when natctl tries
    # to provision an elastic node. tonumber() here, not a Python-side
    # fix, since every OTHER numeric field pulled from this module (vpc_id,
    # public_subnet_id) already comes through as a real number and this is
    # the one exception.
    firewall_id                  = tonumber(module.vpc.firewall_id)
    authorized_keys              = var.authorized_keys
    root_pass                    = var.root_pass
    min_nodes                    = local.dedicated_acme_pool_floor_nodes
    max_nodes                    = local.dedicated_acme_pool_max_nodes
    instance_type                = "g6-dedicated-8"
    elastic_ip_offset_start      = local.elastic_ip_offset_start_dedicated_acme
    conntrack_buddy_sync_enabled = true
    # BUG FIX (found live, 2026-08-29, roadmap/M1-live-deployment.md):
    # var.ip_failover_enabled/var.linode_bgp_dcid were never threaded into
    # this pool's natctl config at all -- FRR itself still got the right
    # dcid (via nat_fleet_shared's own cloud-init rendering, a completely
    # separate path), so each node correctly self-announced its own public
    # IP as primary and BGP peering worked. But natctl never learned
    # ip_failover was enabled for this pool, so it never computed
    # ip_failover_self_ip/ip_failover_buddy_ips (confirmed empty/null in
    # the live roster for every node), so buddy-sync never had a secondary
    # announcement to add to any node's frr.conf -- meaning a dead node's
    # buddy was never actually configured to take over its IP, even with
    # ip-sharing manually configured via the API. This was a complete,
    # silent failure of the documented HA mechanism via the standard
    # deployment path, not just a config nicety.
    ip_failover_enabled    = var.ip_failover_enabled
    linode_bgp_dcid        = var.linode_bgp_dcid
    reserved_ip_enabled    = var.reserved_ip_enabled
    natctl_roster_base_url = local.natctl_roster_base_url
    natctl_on_node_enabled = var.natctl_on_node_enabled
    exporter_py_url        = local.exporter_py_url
    buddy_sync_py_url      = local.buddy_sync_py_url
    natctl_file_urls       = local.natctl_file_urls
    # CUSTOMER REPO: see the identical comment on natctl_pool_shared above.
    agent_distribution = "binary"
    exporter_bin_url   = local.exporter_bin_url
    buddy_sync_bin_url = local.buddy_sync_bin_url
    natctl_bin_url     = local.natctl_bin_url
    # v10: static, non-secret systemd unit files + requirements.txt --
    # natctl's own elastic-node cloud-init renderer
    # (controller/natctl/cloud_init.py) needs the SAME URLs. See
    # terraform/modules/artifacts/main.tf's header comment.
    nat_exporter_service_url    = module.artifacts.nat_exporter_service_url
    lng_buddy_sync_service_url  = module.artifacts.lng_buddy_sync_service_url
    conntrackd_peer_service_url = module.artifacts.conntrackd_peer_service_url
    natctl_service_url          = module.artifacts.natctl_service_url
    natctl_requirements_txt_url = module.artifacts.natctl_requirements_txt_url
    # v10: bucket/region fleet.py uploads THIS pool's elastic nodes' own
    # rendered nftables.conf into before fetching
    # them at boot -- see controller/natctl/config.py's matching
    # PoolConfig fields and controller/natctl/fleet.py's _provision().
    object_storage_bucket    = var.natctl_object_storage_bucket
    object_storage_s3_region = local.natctl_object_storage_region
    autoscale = {
      auto_provision_enabled = true
      cooldown_seconds       = 300
    }
  }

  natctl_pools = merge(
    { shared = local.natctl_pool_shared },
    var.enable_dedicated_pool_example ? { "dedicated-acme-corp" = local.natctl_pool_dedicated_acme } : {},
  )

  # file_sd_path is only meaningful when natctl and Prometheus share a
  # filesystem, i.e. the original single-dedicated-host layout
  # (natctl_on_node_enabled = false, module.observability runs natctl too).
  # Once natctl runs on every NAT node instead, Prometheus (wherever it
  # lives) should scrape natctl's GET /file_sd HTTP endpoint on any node
  # instead — see api.py's build_file_sd_groups() and docs/OBSERVABILITY.md.
  natctl_config_yaml = yamlencode({
    reconcile_interval_seconds = 15
    api = {
      listen_host = "0.0.0.0"
      listen_port = 8099
      # CUSTOMER REPO: lets a vlan_only/vpc_vlan client instance fetch
      # the compiled client-agent binary over the fleet's own VLAN/VPC
      # before it has any other network path -- see
      # controller/natctl/api.py's GET /agents/client-agent (dev repo,
      # v21) and customer-repo-overlay/ansible/cloud-init/client-node.yaml.tftpl.
      client_agent_bin_url = local.client_agent_bin_url
    }
    pools = local.natctl_pools
    # BUG FIX (found live, 2026-08-01): this was hardcoded to
    # "http://localhost:9090", which only happened to be correct in the
    # original single-dedicated-host layout (natctl_on_node_enabled=false,
    # where natctl and Prometheus run on the SAME instance --
    # module.observability). Once natctl_on_node_enabled is true, this same
    # composed YAML gets copied onto every NAT node, none of which run
    # Prometheus locally -- Prometheus (module.observability, when
    # create_observability_instance is true) lives on a separate host at
    # local.natctl_private_ip. Confirmed live: natctl's own health-check
    # conntrack query against "localhost:9090" failed with connection
    # refused, which fed into wrongly deciding a freshly-provisioned
    # elastic node had "failed health checks" and draining/deleting it
    # ~4 minutes after it came up healthy.
    prometheus_url = "http://${local.natctl_private_ip}:9090"
    linode = {
      api_base = "https://api.linode.com/v4"
      token    = null # set via LINODE_TOKEN in /etc/natctl/env instead — see modules/observability
    }
    file_sd_path = var.natctl_on_node_enabled ? null : "/opt/lng-observability/file_sd/lng-nodes.json"
    # v6: leader election + STONITH fencing (see
    # controller/natctl/leader_election.py) — only meaningful once natctl
    # runs on more than one instance at a time. object_storage_access_key/
    # secret_key are deliberately left unset here (null, not the real
    # values) even though var.natctl_object_storage_access_key/secret_key
    # exist — they resolve from NATCTL_OBJECT_STORAGE_ACCESS_KEY/
    # NATCTL_OBJECT_STORAGE_SECRET_KEY in each node's own /etc/natctl/env
    # instead (wired in module.nat_fleet_shared/dedicated_acme's
    # object_storage_access_key/secret_key arguments above), since this
    # composed YAML gets copied to every NAT node once natctl_on_node_enabled
    # is true and shouldn't carry secrets directly — see config.py's
    # LeaderElectionConfig docstring.
    # A single object literal (not a two-branch conditional returning
    # differently-shaped objects) deliberately -- Terraform's ?: requires
    # both branches to unify to one structural type, and an
    # enabled/endpoint/bucket-shaped object vs. an enabled-only object is a
    # real footgun there. Empty endpoint/bucket strings when disabled are
    # harmless (leader_election.enabled=false means natctl never
    # constructs an ObjectStorageLeaseStore at all -- see main.py's
    # build_leader_election()).
    leader_election = {
      enabled                 = var.natctl_on_node_enabled
      object_storage_endpoint = var.natctl_on_node_enabled ? var.natctl_object_storage_endpoint : ""
      object_storage_bucket   = var.natctl_on_node_enabled ? var.natctl_object_storage_bucket : ""
    }
  })

  # v6: whether this environment needs the observability instance AT ALL.
  # - !natctl_on_node_enabled: the original single-dedicated-host layout
  #   still needs somewhere to run natctl, full stop.
  # - run_monitoring_stack: even with natctl_on_node_enabled, this
  #   environment still provisions its own Prometheus/Grafana/Alertmanager
  #   unless you've said you already have monitoring elsewhere.
  # Only false (instance skipped entirely) when BOTH natctl runs on the NAT
  # nodes themselves AND you've opted out of this environment's own
  # monitoring stack -- see docs/OBSERVABILITY.md "Bring your own
  # monitoring" for what natctl_roster_base_url/GET-/file_sd-based scraping
  # looks like once this is false.
  create_observability_instance = !var.natctl_on_node_enabled || var.run_monitoring_stack
}

module "observability" {
  source = "../../modules/observability"
  count  = local.create_observability_instance ? 1 : 0

  region          = var.region
  vpc_id          = module.vpc.vpc_id
  subnet_id       = module.vpc.public_subnet_id
  firewall_id     = module.vpc.control_plane_firewall_id
  authorized_keys = var.authorized_keys
  root_pass       = var.root_pass

  # .5 in the public/NAT-node subnet — clear of the shared pool's floor
  # range (.20+), the dedicated pool's floor range (.50+), and both pools'
  # natctl elastic ranges (.100+, .150+) configured above. Same value as
  # local.natctl_private_ip above, kept as one local so it's impossible for
  # this and the buddy-sync/client-agent roster URL to drift apart. Only
  # actually reachable/meaningful when create_observability_instance is
  # true, of course.
  private_ip = local.natctl_private_ip

  grafana_admin_password = var.grafana_admin_password
  natctl_config_yaml     = local.natctl_config_yaml
  linode_token           = var.linode_token

  # BUG FIX (found live, 2026-08-29, roadmap/M4-autoscaling.md): natctl on
  # this instance needs these for every pool's elastic-node uploads,
  # independent of leader_election/natctl_on_node_enabled -- see
  # terraform/modules/observability/variables.tf's own comment.
  object_storage_access_key = var.natctl_object_storage_access_key
  object_storage_secret_key = var.natctl_object_storage_secret_key

  # v9: fetched-at-boot artifact URLs -- see module.artifacts above and
  # terraform/modules/artifacts/main.tf's header comment. Only actually
  # consumed when run_natctl is true, but harmless to always pass.
  natctl_file_urls = local.natctl_file_urls
  # CUSTOMER REPO: see the identical comment in module.artifacts's own
  # locals alias block above -- this host always runs a compiled natctl.
  agent_distribution = "binary"
  natctl_bin_url     = local.natctl_bin_url

  # v10: static, non-secret systemd unit file + requirements.txt -- see
  # terraform/modules/artifacts/main.tf's header comment.
  natctl_service_url          = module.artifacts.natctl_service_url
  natctl_requirements_txt_url = module.artifacts.natctl_requirements_txt_url

  # v15: pre-built Grafana dashboard JSON, fetched at boot instead of
  # embedded -- see terraform/modules/artifacts/main.tf's header comment.
  nat_overview_json_url = module.artifacts.nat_overview_json_url

  # v6: once natctl runs on every NAT node instead (natctl_on_node_enabled),
  # this host stops running natctl itself -- it wasn't given its own
  # NATCTL_SELF_NODE_ID/NATCTL_SELF_LINODE_ID identity, and running natctl
  # in two places at once (here AND on every NAT node) would be redundant.
  # See docs/RUNBOOK.md's natctl-on-node section.
  run_natctl = !var.natctl_on_node_enabled

  # v6: reuse an existing Prometheus/Grafana instead of standing up a
  # second one -- see variables.tf's run_monitoring_stack and
  # docs/OBSERVABILITY.md "Bring your own monitoring".
  run_monitoring_stack             = var.run_monitoring_stack
  prometheus_remote_write_url      = var.customer_prometheus_remote_write_url
  prometheus_remote_write_username = var.customer_prometheus_remote_write_username
  prometheus_remote_write_password = var.customer_prometheus_remote_write_password
}

# v14: client instances -- see terraform/modules/client-fleet's own main.tf
# header comment for the full design. Empty var.client_groups (the default)
# means this creates nothing at all, same SAME state/terraform.tfvars as
# the NAT fleet itself (deliberately -- see the discussion in this
# project's own history for why a separate root module/state was
# considered and rejected).
locals {
  # Resolves each group's pool_name (a plain string, e.g. "shared" or
  # "dedicated-acme-corp") to that pool's actual vlan_label. v20: no longer
  # the only per-pool value client-fleet groups need -- natctl_roster_vlan_urls
  # below is also keyed by pool_name now, for "vlan_only" groups (the VPC-
  # addressed natctl_roster_base_url IS still the same for every pool; only
  # the /fleet/<pool> path suffix differs there, appended by client-fleet's
  # own module using pool_name directly). Extend this map if you add a
  # third pool.
  pool_vlan_labels = merge(
    { "shared" = local.vlan_label_shared },
    var.enable_dedicated_pool_example ? { "dedicated-acme-corp" = local.vlan_label_dedicated_acme } : {},
  )

  # v17: same resolve-by-pool_name pattern as pool_vlan_labels above, but
  # for each pool's VLAN CIDR -- only actually read by client-fleet when a
  # group sets static_vlan_ip_offset (see that module's own vlan_cidr
  # variable description: "harmless to leave at its default otherwise").
  # Extend alongside pool_vlan_labels if you add a third pool.
  pool_vlan_cidrs = merge(
    { "shared" = local.vlan_cidr_shared },
    var.enable_dedicated_pool_example ? { "dedicated-acme-corp" = local.vlan_cidr_dedicated_acme } : {},
  )
}

module "client_fleet" {
  source   = "../../modules/client-fleet"
  for_each = var.client_groups

  group_name = each.key
  pool_name  = each.value.pool_name
  # Deliberately NOT wrapped in a lookup()/try() with a friendly fallback --
  # an unknown pool_name (a typo, or a dedicated-pool group left in
  # client_groups after setting enable_dedicated_pool_example back to
  # false) should fail terraform plan loudly with Terraform's own "Invalid
  # index" error citing the exact bad key, not silently attach to the
  # wrong VLAN.
  vlan_label = local.pool_vlan_labels[each.value.pool_name]

  # v17.2: opt-in static VLAN addressing via a fixed, isolated slot -- the
  # operator only picks a small static_vlan_slot integer on the group; the
  # actual address passed down to the module is COMPUTED from that slot
  # number + client_static_vlan_slot_size, by local.static_client_offsets
  # above, never derived from any other group's config. vlan_cidr is only
  # actually dereferenced by the module when that computed offset is
  # non-null (same "deliberately NOT wrapped in a friendly fallback"
  # reasoning as vlan_label above applies here too, via pool_vlan_cidrs).
  # Non-collision against this pool's floor/elastic ranges, reserved windows, and
  # every OTHER static group is enforced by this file's own
  # client_static_vlan_slot_capacity/client_static_vlan_slots_unique_per_pool/
  # client_static_vlan_offsets_within_pool_reservation check blocks -- see
  # that module's own static_vlan_ip_offset description for why the
  # module itself can't do this validation (no visibility beyond its own
  # group).
  vlan_cidr             = local.pool_vlan_cidrs[each.value.pool_name]
  static_vlan_ip_offset = local.static_client_offsets[each.key]

  client_count   = each.value.client_count
  interface_mode = each.value.interface_mode
  instance_type  = each.value.instance_type

  region          = var.region
  authorized_keys = var.authorized_keys
  root_pass       = var.root_pass
  firewall_id     = module.vpc.client_firewall_id

  # v15: only actually consumed by client-fleet when interface_mode is
  # "vpc_vlan"/"public_vpc_vlan" -- harmless to always pass.
  vpc_id           = module.vpc.vpc_id
  public_subnet_id = module.vpc.public_subnet_id

  natctl_roster_base_url = local.natctl_roster_base_url
  # v20: per-pool, only actually used when this group's interface_mode is
  # "vlan_only" -- see client-fleet/variables.tf's natctl_roster_vlan_url
  # and this file's natctl_roster_vlan_urls local for the full story.
  natctl_roster_vlan_url = lookup(local.natctl_roster_vlan_urls, each.value.pool_name, "")

  # BUG FIX (found live, 2026-08-02): client-fleet no longer fetches
  # client-agent from Object Storage at boot -- it embeds it directly
  # now (see that module's variables.tf/main.tf). Nothing to pass here
  # anymore. module.artifacts.client_agent_py_url etc. still exist and
  # still upload that file (harmless, just unused by this module now) --
  # a stable public URL for external automation, see that module's
  # outputs.tf.
}
