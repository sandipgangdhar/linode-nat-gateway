# main.tf (terraform/environments/example)
#
# The wired-up, end-to-end example environment: one VPC, any number of NAT
# pools (each a Terraform-managed floor; natctl adds elastic capacity above
# it), and the single observability/control-plane instance that runs
# natctl + Prometheus + Grafana. This is the file to read to see how all
# the individual modules (vpc, nat-fleet, observability) compose into one
# working deployment -- `terraform apply` here is the fastest way to stand
# up the whole solution end-to-end.
#
# -----------------------------------------------------
# What this file wires together:
#
# 1) module.vpc            - Creates the three Cloud Firewalls (NAT node +
#    control plane + client) attached to YOUR existing VPC/subnet(s) --
#    this automation does not create the VPC or its subnet(s) itself, see
#    that module's header comment and docs/NAT-GATEWAY-DEFINITIVE-GUIDE.html
#    §9.1 (Prerequisites) -- create the VPC and at least one subnet
#    yourself first, this project only ever reads them back.
# 2) locals (pool_pairs_same_vlan / pool_reserved_int / observability_vlan_ip) -
#    Deterministic addressing and the cross-pool bookkeeping the two check
#    blocks below need, computed once so every module below can reference
#    it without a cross-module dependency cycle.
# 3) module.nat_fleet[each pool key] - One nat-fleet module instance per
#    entry in var.pools -- see variables.tf's pools description for the
#    full per-pool field list. Add, rename, or remove a pool entirely by
#    editing that one map; this file never needs touching for that.
# 4) locals.natctl_pools / natctl_config_yaml - Composes the full
#    natctl.yaml (natctl.example.yaml shape) as a Terraform value, so
#    natctl's elastic-node provisioning knows about every pool.
# 5) module.observability   - The natctl + Prometheus + Grafana instance,
#    given the composed natctl_config_yaml above.
#
# This environment does not create client instances at all -- a
# customer's own automation creates their client instances, and
# scripts/install-nat-client.sh configures an already-existing instance
# to become a working client. See docs/NAT-GATEWAY-DEFINITIVE-GUIDE.html
# §9.3 (Onboarding a Client Instance).
#
# This environment always runs COMPILED agent binaries, not Python source
# -- every module call below sets agent_distribution = "binary" and wires
# the matching *_bin_url values from module.artifacts (this repo's own
# standalone, binary-only copy of that module). The *_py_url values are
# still threaded through as harmless, unused placeholders, kept only
# because nat-fleet/observability's own variables.tf still declare them as
# required inputs.
#
# -----------------------------------------------------
# Usage:
#
# - Create a VPC + subnet yourself first (see
#   docs/NAT-GATEWAY-DEFINITIVE-GUIDE.html §9.1) -- this automation does
#   not create one for you.
# - Copy terraform.tfvars.example to terraform.tfvars, fill in your Linode
#   API token/SSH key/region/vpc_id/public_subnet_id/pools, then
#   `terraform init && terraform apply`.
# - See outputs.tf for what to do next (client-agent install URLs, Grafana
#   URL).
# - See docs/NAT-GATEWAY-DEFINITIVE-GUIDE.html Part X (Day-2 Operations)
#   once this is live.
#
# -----------------------------------------------------
# Best Practices:
#
# - Keep every pool's private_ip_offset (VPC-side) non-overlapping across
#   ALL pools, and every pool's vlan_cidr_reserved non-overlapping against
#   every OTHER pool sharing the same vlan_label -- both are enforced at
#   plan time (see the two check blocks below), so a mistake fails loudly
#   rather than silently colliding.
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

# BYO VPC -- this module does not create the VPC or its subnet(s)
# itself (see terraform/modules/vpc/main.tf's header comment). vpc_id/
# public_subnet_id/private_subnet_ids come straight from variables.tf,
# which you set in your own terraform.tfvars -- create the VPC and
# subnet(s) yourself first (docs/NAT-GATEWAY-DEFINITIVE-GUIDE.html §9.1),
# this project only ever reads them back.
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
  #
  # var.observability_private_ip_offset (default 5), not a bare literal --
  # live-found gap (2026-09-11): a hardcoded 5 collided with a SECOND,
  # entirely separate LNG deployment sharing this same public_subnet_id
  # (Linode returned [400] "The provided IP is already in use in the
  # subnet" at apply time), since that other deployment's own
  # observability host used the exact same hardcoded offset. See that
  # variable's own description for the full story and
  # observability_vpc_offset_no_overlap_pools below for what IS checked
  # (this deployment's own pools) vs. what can't be (a second
  # deployment's state, invisible to this one).
  natctl_private_ip = cidrhost(module.vpc.public_subnet_cidr, var.observability_private_ip_offset)

  # Once natctl runs on every NAT node instead of the dedicated
  # observability host (natctl_on_node_enabled), buddy-sync's roster poll
  # has to point somewhere that's ACTUALLY running natctl -- the
  # observability host may not even exist anymore (see
  # create_observability_instance below). This is buddy-sync-only --
  # NOT client-agent, which always gets its own roster URL via an
  # explicit --roster-url at manual client-install time (see
  # docs/NAT-GATEWAY-DEFINITIVE-GUIDE.html §9.3, "Onboarding a Client
  # Instance"), never through this local at all (config.py's
  # PoolConfig.natctl_roster_base_url docstring confirms the same
  # buddy-sync/IP-failover-only scope).
  #
  # In natctl_on_node_enabled mode, buddy-sync and its OWN pool-aware
  # natctl instance are ALWAYS co-located on the exact same node (that's
  # the definition of this mode -- natctl runs on every NAT node) -- so
  # localhost is unambiguously correct, trivially simple, and
  # structurally immune to a real failure mode a single shared remote
  # address would otherwise have: since user_data/cloud-init config is
  # baked in once at each node's own creation time and never refreshed, a
  # single hardcoded node address (e.g. one specific pool's first floor
  # node) only ever knows about its OWN pool -- pointing every pool's
  # buddy-sync at it means any OTHER pool's roster fetch 404s outright,
  # silently breaking that pool's buddy IP-failover assignment even
  # though its own leader election and autoscaling are working fine. The
  # single-dedicated-host branch (natctl_on_node_enabled = false) keeps
  # the real remote address -- there, buddy-sync (on NAT nodes) and
  # natctl (on the separate observability host) are never co-located, so
  # localhost would be wrong there specifically; that mode also only ever
  # runs a single natctl process serving every pool, so it never has this
  # problem to begin with.
  natctl_roster_base_url = (
    var.natctl_on_node_enabled
    ? "http://localhost:8099"
    : "http://${local.natctl_private_ip}:8099"
  )

  # A stable numeric rank per pool key (its position in the sorted key
  # list) -- HCL's < operator only works on numbers, not strings, so
  # comparing pool keys directly to dedupe pairs below isn't possible;
  # comparing their ranks is.
  pool_rank = { for i, k in sort(keys(var.pools)) : k => i }

  # Every pool paired with every OTHER pool that shares its vlan_label --
  # the actual set of pairs that need reserved-CIDR overlap checking
  # below. setproduct() gives every ordered pair (including self-pairs
  # and both (a,b)/(b,a) orderings); filtering by rank keeps exactly one
  # unordered pair per combination, and drops self-pairs entirely (a pool
  # never needs checking against itself).
  pool_pairs_same_vlan = [
    for pair in setproduct(keys(var.pools), keys(var.pools)) : pair
    if local.pool_rank[pair[0]] < local.pool_rank[pair[1]] && var.pools[pair[0]].vlan_label == var.pools[pair[1]].vlan_label
  ]

  # Plain-integer (base-256) encodings of each pool's own reserved
  # sub-block's network/broadcast address, for the overlap check below --
  # Terraform's built-in cidrhost() only gives you an address AS AN
  # OFFSET WITHIN one CIDR, it has no function to compare two DIFFERENT
  # CIDRs' ranges against each other. Same technique
  # terraform/modules/nat-fleet's own vlan_reserved_cidr_nested_in_vlan_cidr
  # check uses.
  pool_reserved_int = {
    for k, p in var.pools : k => [
      for h in [cidrhost(p.vlan_cidr_reserved, 0), cidrhost(p.vlan_cidr_reserved, -1)] :
      sum([for i, o in split(".", h) : tonumber(o) * pow(256, 3 - i)])
    ]
  }

  # Every pair from pool_pairs_same_vlan whose reserved sub-blocks
  # actually overlap -- empty when everything's fine. Named individually
  # (not just a boolean) so the check block below can enumerate exactly
  # which pools collided, not just that "something" did.
  overlapping_reserved_pool_pairs = [
    for pair in local.pool_pairs_same_vlan : "${pair[0]} <-> ${pair[1]}"
    if !(
      local.pool_reserved_int[pair[0]][1] < local.pool_reserved_int[pair[1]][0] ||
      local.pool_reserved_int[pair[1]][1] < local.pool_reserved_int[pair[0]][0]
    )
  ]

  # Every pair of pools (regardless of vlan_label -- they all share this
  # environment's one public_subnet_id on the VPC side) whose
  # private_ip_offset ranges [offset, offset+floor_nodes-1] actually
  # overlap. Unlike the VLAN-side reserved-CIDR check above, this one
  # applies to every pool pair unconditionally, not just same-VLAN pairs
  # -- the VPC subnet is shared no matter what each pool's own VLAN looks
  # like.
  all_pool_pairs = [
    for pair in setproduct(keys(var.pools), keys(var.pools)) : pair
    if local.pool_rank[pair[0]] < local.pool_rank[pair[1]]
  ]
  overlapping_vpc_offset_pool_pairs = [
    for pair in local.all_pool_pairs : "${pair[0]} <-> ${pair[1]}"
    if !(
      var.pools[pair[0]].private_ip_offset + var.pools[pair[0]].floor_nodes <= var.pools[pair[1]].private_ip_offset ||
      var.pools[pair[1]].private_ip_offset + var.pools[pair[1]].floor_nodes <= var.pools[pair[0]].private_ip_offset
    )
  ]

  # Every pool whose own private_ip_offset range contains
  # var.observability_private_ip_offset -- the observability host has
  # only a single fixed VPC address (not a range), so this is a simpler
  # single-point-in-range check than overlapping_vpc_offset_pool_pairs
  # above, not a second copy of the same pairwise logic. Only catches a
  # collision within THIS deployment's own pools -- see
  # observability_private_ip_offset's own description for why a second,
  # entirely separate deployment sharing the same public_subnet_id is
  # invisible to this check.
  pools_overlapping_observability_offset = [
    for k, p in var.pools : k
    if var.observability_private_ip_offset >= p.private_ip_offset && var.observability_private_ip_offset < p.private_ip_offset + p.floor_nodes
  ]

  # Every pool whose own floor range reaches its own elastic_ip_offset_start
  # -- a pool's own floor count against its own elastic start, entirely
  # self-contained, nothing to do with any OTHER pool.
  pools_with_floor_reaching_elastic_offset = [
    for k, p in var.pools : k
    if p.vlan_ip_offset + p.floor_nodes > p.elastic_ip_offset_start
  ]

  # The observability host's own VLAN address, as a full "host/prefix"
  # string ready to pass straight into module.observability -- host from
  # var.observability_vlan_pool's own vlan_cidr_reserved (that pool's own
  # sub-block), prefix from that same pool's vlan_cidr itself (the wide,
  # real VLAN CIDR every node actually configures its interface with --
  # see that variable's own comment for why the prefix must stay wide,
  # not narrowed to the reserved sub-block). Fixed offset one below where
  # that pool's own floor nodes start -- comfortably clear of both the
  # floor range and the elastic range by construction, no separate
  # collision check needed for a single fixed offset the way floor/
  # elastic's own ranges need one. Empty string when observability_vlan_pool
  # is "" (opting out of a VLAN interface entirely).
  observability_vlan_ip = (
    var.observability_vlan_pool != ""
    ? "${cidrhost(var.pools[var.observability_vlan_pool].vlan_cidr_reserved, var.pools[var.observability_vlan_pool].vlan_ip_offset - 1)}/${split("/", var.pools[var.observability_vlan_pool].vlan_cidr)[1]}"
    : ""
  )
}

# Every pair of pools sharing one physical VLAN must keep their own
# reserved sub-blocks from overlapping -- when no two pools share a
# vlan_label, pool_pairs_same_vlan is empty and this check does nothing.
check "pool_reserved_cidrs_no_overlap_same_vlan" {
  assert {
    condition     = length(local.overlapping_reserved_pool_pairs) == 0
    error_message = "These pool pairs share a vlan_label but have overlapping vlan_cidr_reserved sub-blocks: ${join(", ", local.overlapping_reserved_pool_pairs)}. Both pools' floor+elastic nodes would draw addresses from the same space on the same physical VLAN, a real collision risk. Pick non-overlapping reserved sub-blocks for every pool on the same VLAN."
  }
}

# Every pair of pools' VPC-side private_ip_offset ranges must not overlap,
# regardless of VLAN -- all pools share this environment's one
# public_subnet_id.
check "pool_vpc_offsets_no_overlap" {
  assert {
    condition     = length(local.overlapping_vpc_offset_pool_pairs) == 0
    error_message = "These pool pairs have overlapping private_ip_offset ranges on the shared VPC subnet: ${join(", ", local.overlapping_vpc_offset_pool_pairs)}. Both pools' nodes would get the same VPC (eth1) address, a real collision. Give every pool a non-overlapping private_ip_offset range (offset..offset+floor_nodes-1)."
  }
}

# observability_private_ip_offset must not fall inside any pool's own
# private_ip_offset range, or the observability host and that pool's
# floor node would collide on the shared VPC subnet.
check "observability_vpc_offset_no_overlap_pools" {
  assert {
    condition     = length(local.pools_overlapping_observability_offset) == 0
    error_message = "observability_private_ip_offset (${var.observability_private_ip_offset}) falls inside these pools' own private_ip_offset ranges: ${join(", ", local.pools_overlapping_observability_offset)}. The observability host and one of that pool's floor nodes would get the same VPC (eth1) address. Move observability_private_ip_offset outside every pool's [private_ip_offset, private_ip_offset+floor_nodes-1] range."
  }
}

# Plan-time validation that a pool's own FLOOR node count can never grow
# large enough to collide with that same pool's elastic node range. Floor
# nodes occupy offsets [vlan_ip_offset, vlan_ip_offset+floor_nodes-1]
# within their own vlan_cidr_reserved; elastic nodes start at that pool's
# own elastic_ip_offset_start. Nothing stops an operator from setting
# floor_nodes large enough to walk into that gap -- Terraform would apply
# it silently otherwise, producing a real floor-node/elastic-node VLAN IP
# collision the first time natctl provisions an elastic node.
check "pool_floor_nodes_below_elastic_offset" {
  assert {
    condition     = length(local.pools_with_floor_reaching_elastic_offset) == 0
    error_message = "These pools have floor_nodes large enough that their floor VLAN offsets reach their own elastic_ip_offset_start: ${join(", ", local.pools_with_floor_reaching_elastic_offset)}. This would be a real IP collision the first time natctl provisions an elastic node for that pool. Lower floor_nodes, or raise elastic_ip_offset_start, for the affected pool(s)."
  }
}

locals {
  # terraform/modules/artifacts needs the Object Storage S3 region/
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

# Uploads the compiled agent binaries (natctl/nat-exporter/buddy-sync) to
# Object Storage ONCE for the whole environment, so every pool's nodes
# (floor and elastic alike) and the observability instance can fetch them
# at boot instead of embedding their content inline -- see
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
  # module.nat_fleet below AND the natctl_pools composition further down
  # (the latter feeds natctl_config_yaml, for natctl's OWN elastic-node
  # cloud-init renderer -- it renders the same three-interface + FRR
  # layout as the Terraform floor-node path by a completely different
  # mechanism (Python vs. a Terraform template), so the two must be kept
  # behaviorally in sync by hand whenever either changes).
  exporter_py_url   = module.artifacts.exporter_py_url
  buddy_sync_py_url = module.artifacts.buddy_sync_py_url
  natctl_file_urls  = module.artifacts.natctl_file_urls

  # This environment always runs compiled agents, not Python source -- see
  # terraform/modules/artifacts (this repo's standalone, binary-only
  # variant) and controller/natctl/cloud_init.py's/
  # ansible/cloud-init/*.tftpl's agent_distribution handling upstream.
  # exporter_py_url/buddy_sync_py_url/natctl_file_urls above are harmless,
  # unused placeholders in this mode -- kept only because nat-fleet/
  # observability's variables.tf still declare them as required inputs;
  # every actual fetch uses the *_bin_url values below instead.
  agent_distribution = "binary"
  exporter_bin_url   = module.artifacts.exporter_bin_url
  buddy_sync_bin_url = module.artifacts.buddy_sync_bin_url
  natctl_bin_url     = module.artifacts.natctl_bin_url
  # See natctl_config_yaml's api.client_agent_bin_url further down for
  # where this is actually consumed.
  client_agent_bin_url = module.artifacts.client_agent_bin_url
  # See natctl_config_yaml's api.install_nat_client_script_url further
  # down for where this is actually consumed.
  install_nat_client_script_url = module.artifacts.install_nat_client_script_url

  # Static, non-secret systemd unit files + requirements.txt -- see
  # terraform/modules/artifacts/main.tf's header comment for why these are
  # also fetched at boot instead of embedded per-pool.
  nat_exporter_service_url    = module.artifacts.nat_exporter_service_url
  lng_buddy_sync_service_url  = module.artifacts.lng_buddy_sync_service_url
  conntrackd_peer_service_url = module.artifacts.conntrackd_peer_service_url
  natctl_service_url          = module.artifacts.natctl_service_url
  natctl_requirements_txt_url = module.artifacts.natctl_requirements_txt_url
}

# One nat-fleet module instance per pool defined in var.pools -- see
# variables.tf's pools description for the full per-pool field list. A
# pool is the unit of both scaling and isolation: the default pool every
# tenant uses unless assigned elsewhere, or a tenant's own dedicated pool
# demonstrating isolated/reserved capacity -- same module either way, not
# separate code (see docs/NAT-GATEWAY-DEFINITIVE-GUIDE.html §5.1, "Two
# Tiers of Capacity").
module "nat_fleet" {
  source   = "../../modules/nat-fleet"
  for_each = var.pools

  fleet_label        = each.value.fleet_label
  pool_name          = each.key
  region             = var.region
  vpc_id             = module.vpc.vpc_id
  public_subnet_id   = module.vpc.public_subnet_id
  public_subnet_cidr = module.vpc.public_subnet_cidr
  # VLAN CIDR (private client fleet), not a VPC subnet CIDR.
  private_subnet_cidrs = [each.value.vlan_cidr]
  # A VPC-attached instance only ever gets a kernel route to its own
  # directly-connected subnet -- nothing routes it to any OTHER subnet in
  # the same VPC automatically, not even Linode's own Network Helper.
  # Every subnet in the environment's VPC is auto-discovered here
  # (terraform/modules/vpc's all_subnet_cidrs output) and routed into
  # this pool's nodes at boot as a routing convenience -- it does not
  # change what Cloud Firewall itself permits.
  vpc_sibling_subnet_cidrs = module.vpc.all_subnet_cidrs
  firewall_id              = module.vpc.firewall_id

  node_count        = each.value.floor_nodes
  private_ip_offset = each.value.private_ip_offset
  instance_type     = each.value.instance_type
  authorized_keys   = var.authorized_keys
  root_pass         = var.root_pass

  vlan_label         = each.value.vlan_label
  vlan_cidr          = each.value.vlan_cidr
  vlan_reserved_cidr = each.value.vlan_cidr_reserved
  vlan_ip_offset     = each.value.vlan_ip_offset # POOL-LOCAL (within vlan_cidr_reserved) -- not private_ip_offset, a different address space

  ip_failover_enabled = var.ip_failover_enabled
  linode_bgp_dcid     = var.linode_bgp_dcid

  reserved_ip_enabled = var.reserved_ip_enabled
  reserved_ip_pool    = each.value.reserved_ip_pool

  placement_group_enabled = var.placement_group_enabled
  placement_group_policy  = var.placement_group_policy

  natctl_roster_url = local.natctl_roster_base_url # buddy-sync + IP-failover opt-in — see docs/NAT-GATEWAY-DEFINITIVE-GUIDE.html Part IV (High Availability)

  # natctl-on-node (opt-in) — see variables.tf's natctl_on_node_enabled.
  # natctl_config_yaml is defined further down (locals.natctl_config_yaml)
  # but Terraform resolves locals independently of source-file order, so
  # this forward reference is fine.
  natctl_on_node_enabled    = var.natctl_on_node_enabled
  natctl_config_yaml        = var.natctl_on_node_enabled ? local.natctl_config_yaml : ""
  linode_token              = var.natctl_on_node_enabled ? var.linode_token : ""
  object_storage_access_key = var.natctl_object_storage_access_key
  object_storage_secret_key = var.natctl_object_storage_secret_key

  # Fetched-at-boot artifact URLs -- see module.artifacts above and
  # terraform/modules/artifacts/main.tf's header comment. This environment
  # always runs compiled agents -- see local.agent_distribution's own
  # comment above for why exporter_py_url/buddy_sync_py_url/
  # natctl_file_urls below are harmless, unused placeholders and the
  # actual fetch uses the *_bin_url values that follow.
  exporter_py_url   = module.artifacts.exporter_py_url
  buddy_sync_py_url = module.artifacts.buddy_sync_py_url
  natctl_file_urls  = module.artifacts.natctl_file_urls

  agent_distribution = local.agent_distribution
  exporter_bin_url   = local.exporter_bin_url
  buddy_sync_bin_url = local.buddy_sync_bin_url
  natctl_bin_url     = local.natctl_bin_url

  # Static, non-secret systemd unit files + requirements.txt.
  nat_exporter_service_url    = module.artifacts.nat_exporter_service_url
  lng_buddy_sync_service_url  = module.artifacts.lng_buddy_sync_service_url
  conntrackd_peer_service_url = module.artifacts.conntrackd_peer_service_url
  natctl_service_url          = module.artifacts.natctl_service_url
  natctl_requirements_txt_url = module.artifacts.natctl_requirements_txt_url

  # Per-node dynamic conf upload (nftables.conf) -- reuses the SAME
  # Object Storage bucket module.artifacts and natctl's leader-election
  # lease already use. See terraform/modules/nat-fleet/main.tf's header
  # comment.
  object_storage_bucket    = var.natctl_object_storage_bucket
  object_storage_s3_region = local.natctl_object_storage_region
}

locals {
  # natctl's own elastic-node provisioning (fleet.py + cloud_init.py) mirrors
  # the same three-interface layout (VLAN + FRR) as the Terraform floor
  # nodes above, so elastic capacity behaves identically to floor capacity
  # from a NAT/failover standpoint. One object per pool, built the same
  # shape module.nat_fleet's own per-pool inputs use.
  natctl_pools = {
    for k, p in var.pools : k => {
      region               = var.region
      vpc_id               = module.vpc.vpc_id
      public_subnet_id     = module.vpc.public_subnet_id
      public_subnet_cidr   = module.vpc.public_subnet_cidr
      private_subnet_cidrs = [p.vlan_cidr]
      # vlan_label/vlan_cidr are required here -- config.py's PoolConfig
      # has no default for either (every node's eth2 joins this VLAN for
      # the private client fleet, regardless of ip_failover), so omitting
      # them makes Config.load() raise TypeError: PoolConfig.__init__()
      # missing 2 required positional arguments on every natctl start, for
      # any pool. Mirrors module.nat_fleet's own vlan_label/vlan_cidr
      # arguments above (same source values).
      vlan_label = p.vlan_label
      vlan_cidr  = p.vlan_cidr
      # This pool's floor+elastic nodes live inside this small, wholly-owned
      # sub-block of the VLAN -- fleet.py's _provision() uses this
      # directly both to pick an elastic node's address and as its hard
      # containment refuse-to-provision gate. See
      # PoolConfig.vlan_reserved_cidr's own comment (config.py).
      vlan_reserved_cidr = p.vlan_cidr_reserved
      # linode_firewall.id is a STRING in the Linode Terraform provider's
      # schema, even though it's a numeric ID -- yamlencode() faithfully
      # preserves that as a quoted YAML string ("99779873"), but config.py's
      # PoolConfig.firewall_id is typed int, and the Linode API's
      # POST /linode/instances rejects a string firewall_id outright ("Must
      # be of type Integer") when natctl tries to provision an elastic
      # node. tonumber() here, not a Python-side fix, since every OTHER
      # numeric field pulled from this module (vpc_id, public_subnet_id)
      # already comes through as a real number and this is the one
      # exception.
      firewall_id     = tonumber(module.vpc.firewall_id)
      authorized_keys = var.authorized_keys
      root_pass       = var.root_pass
      # min_nodes/max_nodes are DELIBERATELY NOT set here. This whole object
      # gets embedded into every floor node's Metadata Service user_data
      # (when natctl_on_node_enabled) and unconditionally into the
      # observability host's -- since user_data is read once at boot and
      # can never be updated in place, embedding a value that changes on
      # every scaling operation would force Terraform to destroy and
      # recreate every existing instance carrying it.
      # PoolConfig.min_nodes/max_nodes now default to (3, 12) in config.py
      # as a bootstrap fallback, and every natctl process refreshes the
      # real values from the linode_object_storage_object.pool_scaling
      # object below on every reconcile pass (FleetController.
      # refresh_pool_scaling(), called first thing each pass in
      # main.py's reconcile_once()) -- a plain in-place Object Storage PUT,
      # entirely decoupled from any instance's own creation payload.
      instance_type = p.instance_type
      # Both offsets are ABSOLUTE host offsets within vlan_reserved_cidr
      # above, compared directly against each other (never summed) --
      # see this file's own pool_floor_nodes_below_elastic_offset check
      # and fleet.py's _provision(). Without vlan_ip_offset explicitly
      # wired through here, PoolConfig would silently fall back to its
      # own Python-side default (20) regardless of what this pool's
      # vlan_ip_offset is actually set to in terraform.tfvars.
      vlan_ip_offset               = p.vlan_ip_offset
      elastic_ip_offset_start      = p.elastic_ip_offset_start
      conntrack_buddy_sync_enabled = true
      # var.ip_failover_enabled/var.linode_bgp_dcid must be threaded into
      # this pool's natctl config explicitly, not just into FRR's own
      # cloud-init rendering (a completely separate path) -- FRR alone gets
      # each node self-announcing its own public IP and BGP peering
      # working, but without natctl also knowing ip_failover is enabled for
      # this pool, it never computes ip_failover_self_ip/
      # ip_failover_buddy_ips, so buddy-sync never has a secondary
      # announcement to add to any node's frr.conf -- a dead node's buddy
      # is never actually configured to take over its IP, even with
      # ip-sharing manually configured via the API. A silent failure of the
      # whole HA mechanism if these two fields are left out, not just a
      # config nicety.
      ip_failover_enabled    = var.ip_failover_enabled
      linode_bgp_dcid        = var.linode_bgp_dcid
      reserved_ip_enabled    = var.reserved_ip_enabled
      natctl_roster_base_url = local.natctl_roster_base_url
      # Elastic nodes natctl provisions for this pool also get natctl
      # installed on themselves (leader-election-eligible), matching the
      # Terraform floor's natctl_on_node_enabled above — see
      # config.py's PoolConfig.natctl_on_node_enabled docstring.
      natctl_on_node_enabled = var.natctl_on_node_enabled
      # Fetched-at-boot artifact URLs, mirroring module.nat_fleet's
      # exporter_py_url/buddy_sync_py_url/natctl_file_urls above --
      # natctl's own elastic-node cloud-init renderer
      # (controller/natctl/cloud_init.py) needs the SAME URLs. This
      # environment always runs compiled agents -- see local.
      # agent_distribution's own comment above.
      exporter_py_url   = local.exporter_py_url
      buddy_sync_py_url = local.buddy_sync_py_url
      natctl_file_urls  = local.natctl_file_urls

      agent_distribution = local.agent_distribution
      exporter_bin_url   = local.exporter_bin_url
      buddy_sync_bin_url = local.buddy_sync_bin_url
      natctl_bin_url     = local.natctl_bin_url
      # Static, non-secret systemd unit files + requirements.txt --
      # natctl's own elastic-node cloud-init renderer
      # (controller/natctl/cloud_init.py) needs the SAME URLs. See
      # terraform/modules/artifacts/main.tf's header comment.
      nat_exporter_service_url    = module.artifacts.nat_exporter_service_url
      lng_buddy_sync_service_url  = module.artifacts.lng_buddy_sync_service_url
      conntrackd_peer_service_url = module.artifacts.conntrackd_peer_service_url
      natctl_service_url          = module.artifacts.natctl_service_url
      natctl_requirements_txt_url = module.artifacts.natctl_requirements_txt_url
      # Bucket/region fleet.py uploads THIS pool's elastic nodes' own
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
  }

  # file_sd_path is only meaningful when natctl and Prometheus share a
  # filesystem, i.e. the original single-dedicated-host layout
  # (natctl_on_node_enabled = false, module.observability runs natctl too).
  # Once natctl runs on every NAT node instead, Prometheus (wherever it
  # lives) should scrape natctl's GET /file_sd HTTP endpoint on any node
  # instead — see api.py's build_file_sd_groups(), which returns the same
  # target-list shape a static file_sd file would, sourced from natctl's
  # own live roster instead of a file this environment writes.
  natctl_config_yaml = yamlencode({
    reconcile_interval_seconds = 15
    api = {
      listen_host = "0.0.0.0"
      listen_port = 8099
      # Lets a vlan_only/vpc_vlan client instance fetch the compiled
      # client-agent binary over the fleet's own VLAN/VPC before it has
      # any other network path -- see controller/natctl/api.py's GET
      # /agents/client-agent (upstream) and this repo's own
      # ansible/cloud-init/client-node.yaml.tftpl.
      client_agent_bin_url = local.client_agent_bin_url
      # Same fetch-once-serve-locally mechanism for the onboarding
      # SCRIPT itself, GET /agents/install-nat-client.sh -- lets an
      # operator bootstrap a brand-new client instance with one curl
      # against this fleet's own VLAN/VPC instead of already needing a
      # copy of the script on hand.
      install_nat_client_script_url = local.install_nat_client_script_url
    }
    pools = local.natctl_pools
    # Must NOT be hardcoded to "http://localhost:9090" -- that's only
    # correct in the original single-dedicated-host layout
    # (natctl_on_node_enabled=false, where natctl and Prometheus run on
    # the SAME instance -- module.observability). Once
    # natctl_on_node_enabled is true, this same composed YAML gets
    # copied onto every NAT node, none of which run Prometheus locally --
    # Prometheus (module.observability, when create_observability_instance
    # is true) lives on a separate host at local.natctl_private_ip. Get
    # this wrong and natctl's own health-check conntrack query against
    # "localhost:9090" fails with connection refused, which can feed into
    # wrongly deciding a freshly-provisioned elastic node has "failed
    # health checks" and draining/deleting it minutes after it came up
    # healthy.
    prometheus_url = "http://${local.natctl_private_ip}:9090"
    # vpc_sibling_subnet_cidrs is DELIBERATELY NOT set here -- it used to
    # be embedded directly (a top-level field, since it's a property of
    # the VPC itself, not any one pool), which meant every subnet added
    # to the VPC later required this whole object's user_data to be
    # regenerated (observability host recreated, or every
    # natctl_on_node_enabled floor/elastic node individually restarted
    # with a hand-edited config). Config.vpc_sibling_subnet_cidrs now
    # defaults to an empty list as a bootstrap fallback, and every natctl
    # process refreshes the real value from
    # linode_object_storage_object.vpc_sibling_subnets below on every
    # reconcile pass (FleetController.refresh_vpc_sibling_subnets()) --
    # same decoupling-from-user_data pattern §4.6 already uses for
    # min_nodes/max_nodes.
    linode = {
      api_base = "https://api.linode.com/v4"
      token    = null # set via LINODE_TOKEN in /etc/natctl/env instead — see modules/observability
    }
    file_sd_path = var.natctl_on_node_enabled ? null : "/opt/lng-observability/file_sd/lng-nodes.json"
    # Leader election + STONITH fencing (see
    # controller/natctl/leader_election.py) — only meaningful once natctl
    # runs on more than one instance at a time. object_storage_access_key/
    # secret_key are deliberately left unset here (null, not the real
    # values) even though var.natctl_object_storage_access_key/secret_key
    # exist — they resolve from NATCTL_OBJECT_STORAGE_ACCESS_KEY/
    # NATCTL_OBJECT_STORAGE_SECRET_KEY in each node's own /etc/natctl/env
    # instead (wired in module.nat_fleet's object_storage_access_key/
    # secret_key arguments above), since this composed YAML gets copied
    # to every NAT node once natctl_on_node_enabled is true and shouldn't
    # carry secrets directly — see config.py's LeaderElectionConfig
    # docstring.
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

  # Whether this environment needs the observability instance AT ALL.
  # - !natctl_on_node_enabled: the original single-dedicated-host layout
  #   still needs somewhere to run natctl, full stop.
  # - run_monitoring_stack: even with natctl_on_node_enabled, this
  #   environment still provisions its own Prometheus/Grafana/Alertmanager
  #   unless you've said you already have monitoring elsewhere.
  # Only false (instance skipped entirely) when BOTH natctl runs on the NAT
  # nodes themselves AND you've opted out of this environment's own
  # monitoring stack -- meaning you're bringing your own Prometheus, which
  # should then point at natctl_roster_base_url's GET /file_sd endpoint on
  # any node instead of scraping a dedicated instance this environment
  # never creates in that case.
  create_observability_instance = !var.natctl_on_node_enabled || var.run_monitoring_stack
}

# min_nodes/max_nodes live here instead of inside natctl_config_yaml -- a plain, separate
# resource whose content changing is a harmless in-place Object Storage
# PUT, with zero relationship to any linode_instance's own user_data.
# Every natctl process (floor-node-resident or the observability host)
# reads this every reconcile pass (FleetController.refresh_pool_scaling())
# instead of relying on a boot-time-embedded value. Terraform-driven only
# by design -- terraform.tfvars stays the single source of truth for
# these two values -- no live natctl_cli override exists for this one,
# unlike other settings that support one.
# PRIVATE (no acl argument, same default-private treatment
# object_storage.py's read_json_object()/write_json_object() already use
# for the reserved-IP ownership manifest) -- read via natctl's own
# authenticated boto3 client, never curl'd at boot the way the
# public-read artifacts are. One object per pool, keyed by pool name.
resource "linode_object_storage_object" "pool_scaling" {
  for_each = var.pools

  bucket     = var.natctl_object_storage_bucket
  region     = local.natctl_object_storage_region
  access_key = var.natctl_object_storage_access_key
  secret_key = var.natctl_object_storage_secret_key

  key = "natctl/pool-scaling/${each.key}.json"
  content = jsonencode({
    min_nodes = each.value.floor_nodes
    max_nodes = each.value.max_nodes
    source    = "terraform"
  })
  etag = md5(jsonencode({
    min_nodes = each.value.floor_nodes
    max_nodes = each.value.max_nodes
    source    = "terraform"
  }))
}

# The Terraform-authoritative baseline for the whole-environment
# VPC-sibling-subnets list -- see locals.natctl_config_yaml's comment
# above for why this was pulled out of natctl.yaml's own embedded
# content. One object per environment (not per pool, unlike
# pool_scaling above) since this is a property of the whole VPC.
# natctl_cli set-vpc-sibling-subnets can also write this same object
# directly for an immediate, no-apply-needed update -- this resource
# will overwrite that back to live VPC discovery on the next apply,
# same relationship pool_scaling already has with its own live
# override.
resource "linode_object_storage_object" "vpc_sibling_subnets" {
  bucket     = var.natctl_object_storage_bucket
  region     = local.natctl_object_storage_region
  access_key = var.natctl_object_storage_access_key
  secret_key = var.natctl_object_storage_secret_key

  key = "natctl/vpc-sibling-subnets.json"
  content = jsonencode({
    cidrs  = module.vpc.all_subnet_cidrs
    source = "terraform"
  })
  etag = md5(jsonencode({
    cidrs  = module.vpc.all_subnet_cidrs
    source = "terraform"
  }))
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

  # var.observability_private_ip_offset (default 5) in the public/
  # NAT-node subnet — clear of every pool's own floor and elastic ranges
  # by default (see variables.tf's pools description), and checked
  # against them at plan time (observability_vpc_offset_no_overlap_pools
  # above). Same value as local.natctl_private_ip above, kept as one
  # local so it's impossible for this and the buddy-sync/client-agent
  # roster URL to drift apart. Only actually reachable/meaningful when
  # create_observability_instance is true, of course.
  private_ip = local.natctl_private_ip
  vpc_prefix = split("/", module.vpc.public_subnet_cidr)[1]
  # This host's VPC interface only ever gets a kernel route for its OWN
  # directly-connected subnet -- without this, a client on ANY other VPC
  # subnet couldn't reach (or get a reply from) natctl's roster API
  # (8099) here in the default single-control-plane layout, even though
  # Cloud Firewall's private_subnet_ids rule already allows it -- the
  # kernel would simply have no route to send the reply back over. See
  # terraform/modules/vpc's all_subnet_cidrs output (auto-discovered,
  # not hand-maintained).
  vpc_sibling_subnet_cidrs = module.vpc.all_subnet_cidrs

  # Observability's own genuine VLAN interface + reserved static address --
  # needed when natctl_on_node_enabled = false, since this dedicated host
  # is then the only place natctl runs at all, and natctl needs a
  # VLAN-side presence for the same reasons every NAT node does. Joins
  # var.observability_vlan_pool's own VLAN specifically (see that
  # variable's own description) -- see
  # terraform/modules/observability/main.tf's dynamic "interface" block
  # and variables.tf's vlan_label/vlan_ip. Empty strings (both variables)
  # when observability_vlan_pool is "", skipping the VLAN interface
  # entirely -- that module's own dynamic block is gated on vlan_label
  # being non-empty.
  vlan_label = var.observability_vlan_pool != "" ? var.pools[var.observability_vlan_pool].vlan_label : ""
  vlan_ip    = local.observability_vlan_ip

  grafana_admin_password = var.grafana_admin_password
  natctl_config_yaml     = local.natctl_config_yaml
  linode_token           = var.linode_token

  # natctl on this instance needs these for every pool's elastic-node
  # uploads, independent of leader_election/natctl_on_node_enabled -- see
  # terraform/modules/observability/variables.tf's own comment.
  object_storage_access_key = var.natctl_object_storage_access_key
  object_storage_secret_key = var.natctl_object_storage_secret_key

  # Fetched-at-boot artifact URLs -- see module.artifacts above and
  # terraform/modules/artifacts/main.tf's header comment. Only actually
  # consumed when run_natctl is true, but harmless to always pass. This
  # host always runs a compiled natctl -- see local.agent_distribution's
  # own comment above.
  natctl_file_urls   = local.natctl_file_urls
  agent_distribution = local.agent_distribution
  natctl_bin_url     = local.natctl_bin_url

  # Static, non-secret systemd unit file + requirements.txt -- see
  # terraform/modules/artifacts/main.tf's header comment.
  natctl_service_url          = module.artifacts.natctl_service_url
  natctl_requirements_txt_url = module.artifacts.natctl_requirements_txt_url

  # Pre-built Grafana dashboard JSON, fetched at boot instead of
  # embedded -- see terraform/modules/artifacts/main.tf's header comment.
  nat_overview_json_url = module.artifacts.nat_overview_json_url

  # Once natctl runs on every NAT node instead (natctl_on_node_enabled),
  # this host stops running natctl itself -- it wasn't given its own
  # NATCTL_SELF_NODE_ID/NATCTL_SELF_LINODE_ID identity, and running natctl
  # in two places at once (here AND on every NAT node) would be redundant.
  # See docs/NAT-GATEWAY-DEFINITIVE-GUIDE.html §2.3/§2.4 for the
  # natctl-on-node placement mode this toggle switches to.
  run_natctl = !var.natctl_on_node_enabled

  # When natctl_on_node_enabled, run_natctl above is false, so this host
  # never runs write_file_sd() -- Prometheus's file_sd_configs-based
  # nat_exporter job would then have zero targets, permanently. Point
  # Prometheus at natctl's own GET /file_sd HTTP endpoint instead in
  # that case.
  #
  # Polling a SINGLE hardcoded node does NOT answer identically for the
  # whole fleet: every instance's own `user_data`/cloud-init config is
  # baked in once at each node's own creation time and never refreshed,
  # so a node created before a second pool was ever enabled has no idea
  # that pool exists and answers /file_sd for its own pool only -- a
  # single hardcoded target only ever covers the pool(s) that existed
  # when that specific node was created. Polling ONE TARGET PER POOL
  # instead of one target for the whole fleet avoids this -- each pool's
  # own first floor node is, by construction, always aware of its own
  # pool (it was created as part of enabling it), so this guarantees
  # full coverage regardless of any other node's own config age.
  # Prometheus's http_sd_configs supports multiple entries under one job
  # (ansible/templates/prometheus.yml.tftpl loops over this list), each
  # independently polled and merged -- not a single URL with a list
  # value.
  natctl_http_sd_targets = var.natctl_on_node_enabled ? [
    for k, m in module.nat_fleet : "${values(m.node_vpc_ips)[0]}:8099"
    if length(m.node_vpc_ips) > 0
  ] : []

  # Reuse an existing Prometheus/Grafana instead of standing up a
  # second one -- see variables.tf's run_monitoring_stack. Set it false
  # and give the three prometheus_remote_write_* values below to have
  # natctl's own metrics forwarded to your existing Prometheus instead.
  run_monitoring_stack             = var.run_monitoring_stack
  prometheus_remote_write_url      = var.customer_prometheus_remote_write_url
  prometheus_remote_write_username = var.customer_prometheus_remote_write_username
  prometheus_remote_write_password = var.customer_prometheus_remote_write_password
}

# This environment does not create client instances -- see
# docs/NAT-GATEWAY-DEFINITIVE-GUIDE.html §9.3 for the actual onboarding
# flow (scripts/install-nat-client.sh, run against an instance the
# customer's own automation already created). module.vpc.client_firewall_id
# and module.artifacts.client_agent_bin_url exist independently of client
# instance creation -- see those modules' own comments for what they're
# each for.
