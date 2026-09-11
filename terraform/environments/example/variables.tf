# variables.tf (terraform/environments/example)
#
# Every input this example environment accepts. Copy
# terraform.tfvars.example to terraform.tfvars and fill in at minimum
# linode_token, authorized_keys, root_pass, and pools -- everything else
# has a working default.
#
# -----------------------------------------------------
# Key Parameters:
#
# 1) linode_token/region/authorized_keys/root_pass - Required; account and
#    access basics.
# 2) pools - Every NAT-fleet pool this environment provisions, keyed by a
#    short pool identifier -- sizing, VLAN identity, and addressing per
#    pool. Add, rename, or remove a pool entirely by editing this one
#    map; main.tf never needs touching for that. See its own description
#    below for the full field-by-field breakdown and the two plan-time
#    checks (main.tf's pool_reserved_cidrs_no_overlap_same_vlan and
#    pool_vpc_offsets_no_overlap) that keep multiple pools from silently
#    colliding.
# 3) observability_vlan_pool - Which pool's VLAN (if any) the
#    observability host joins directly.
# 4) ip_failover_enabled/linode_bgp_dcid - Buddy IP failover (see
#    docs/NAT-GATEWAY-DEFINITIVE-GUIDE.html §4.4, "BGP-Based IP Failover").
#    Applies uniformly to every pool.
# 5) reserved_ip_enabled - Fixed/whitelist-safe public IPs for every node,
#    floor and elastic, in every pool (account-gated by Linode, off by
#    default).
# 6) placement_group_enabled/placement_group_policy - Spread floor nodes
#    across separate physical hosts (off by default; floor nodes only;
#    applies uniformly to every pool).
# 7) grafana_admin_password         - Change before any real deployment.
#
# -----------------------------------------------------
# Author:
# - Sandip Gangdhar
# - GitHub: https://github.com/sandipgangdhar
#
# (c) Linode-NAT-Gateway (LNG) | Developed by Sandip Gangdhar | 2026
# -----------------------------------------------------

variable "linode_token" {
  description = "Linode Personal Access Token (scopes: linodes:read_write, vpc:read_write, networking:read_write)"
  type        = string
  sensitive   = true
}

variable "region" {
  description = "Linode region/data center, e.g. us-east"
  type        = string
  default     = "us-east"
}

variable "label" {
  description = "Prefix for every resource this environment creates whose name is otherwise fixed (currently module.vpc's three Cloud Firewalls: '<label>-nat-node-fw'/'<label>-control-plane-fw'/'<label>-client-fw'). Change this to run a second, clearly-distinguishable copy of this environment in the same account/region without any naming collision with an existing 'lng-example' deployment -- e.g. a live-testing/verification environment alongside a real one."
  type        = string
  default     = "lng-example"
}

# ---------------------------------------------------------------------------
# Bring Your Own VPC. This automation does not create the Linode VPC
# or its subnet(s) -- see terraform/modules/vpc/main.tf's header comment
# for why. Create one yourself first (Cloud Manager, linode-cli, or a
# separate one-time Terraform config -- see
# docs/NAT-GATEWAY-DEFINITIVE-GUIDE.html §9.1) before running
# `terraform apply` here. vpc_id/public_subnet_id
# are required, no defaults -- there's no environment-agnostic default
# that would make sense for an id specific to your account.
# ---------------------------------------------------------------------------

variable "vpc_id" {
  description = "Numeric id of your existing Linode VPC. Create this yourself first (docs/NAT-GATEWAY-DEFINITIVE-GUIDE.html §9.1)."
  type        = number
}

variable "public_subnet_id" {
  description = "Numeric id of your existing VPC subnet that every NAT node's eth1 (VPC) interface and the observability instance attach to. Its CIDR is looked up automatically (see terraform/modules/vpc's data.linode_vpc_subnet.public) -- make sure it has enough headroom for every pool's private_ip_offset range combined (see the pools variable below) before creating it."
  type        = number
}

variable "admin_cidrs" {
  description = "List of CIDRs allowed to reach SSH (every node) and Grafana/Prometheus/Alertmanager (the control-plane host). No default, deliberately: previously hardcoded to 0.0.0.0/0 (open to the entire internet) with only a code comment telling an operator to fix it. Set this to your own admin/office/VPN egress CIDR(s), e.g. [\"203.0.113.4/32\"]."
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "Map of VPC private-subnet label => existing subnet id, for VPC-resident workloads that are NOT the VLAN-based NAT client fleet (e.g. an LKE Enterprise cluster sharing this VPC) -- see docs/NAT-GATEWAY-DEFINITIVE-GUIDE.html §1.2 for why the client fleet itself rides VLAN, not VPC. Leave empty ({}) if you don't have any; this is optional, unlike vpc_id/public_subnet_id."
  type        = map(number)
  default     = {}
}

# ---------------------------------------------------------------------------
# Pools -- every NAT-fleet pool this environment provisions, as a single
# map. Each key becomes: natctl's pool_name (and so the roster URL path,
# GET /fleet/<key>), part of every node's Linode label
# ("<fleet_label>-<n>"), and the key in natctl.yaml's own pools: map.
# Multiple pools are fully independent -- a pool is the unit of both
# scaling and isolation (each gets its own floor/elastic bounds, its own
# VLAN identity) -- but multiple pools MAY share one physical VLAN
# ("same-VLAN mode": some customers already run one VLAN per account for
# both NAT gateway traffic and other workloads, and standing up a second
# VLAN just for a second pool isn't practical for them). When two or more
# pools share a vlan_label, the only thing that needs coordinating is
# that their own vlan_cidr_reserved sub-blocks don't overlap each other --
# main.tf's "pool_reserved_cidrs_no_overlap_same_vlan" check enforces this
# for EVERY pair of pools on the same VLAN at plan time, not just two.
# Regardless of VLAN sharing, every pool's private_ip_offset range (VPC
# side, [private_ip_offset, private_ip_offset+floor_nodes-1]) must also
# not overlap any other pool's, since every pool shares this
# environment's one public_subnet_id -- main.tf's
# "pool_vpc_offsets_no_overlap" check covers this one too.
#
# Per-pool fields:
#   fleet_label             - Unique label prefix for this pool's Linode
#                              instances, e.g. "lng-common". See
#                              terraform/modules/nat-fleet's fleet_label.
#   floor_nodes              - Terraform-managed baseline node count.
#                              Start minimal (1) and raise it (or let
#                              natctl add elastic capacity above the
#                              floor) once real load justifies more. See
#                              docs/NAT-GATEWAY-DEFINITIVE-GUIDE.html §5.1
#                              (Two Tiers of Capacity).
#   max_nodes                - Ceiling natctl will never scale this pool
#                              past, floor + elastic combined.
#   instance_type             - Linode plan for every floor node in this
#                              pool.
#   vlan_label                - VLAN label this pool's nodes (and its
#                              private client fleet) join. See
#                              terraform/modules/nat-fleet's vlan_label.
#   vlan_cidr                  - The FULL, real VLAN address space for
#                              this pool -- e.g. a customer's whole /16.
#                              Every node (floor, elastic, and the
#                              observability host if it joins this pool's
#                              VLAN -- see observability_vlan_pool below)
#                              configures THIS CIDR's own prefix length
#                              on its interface, so routing works across
#                              the entire VLAN, not just this pool's own
#                              corner of it. Only the exact same value as
#                              another pool's vlan_cidr when that other
#                              pool also shares this pool's vlan_label --
#                              nothing enforces that, since two pools on
#                              genuinely separate VLANs are fully
#                              isolated L2 domains on Linode regardless of
#                              numeric CIDR overlap.
#   vlan_cidr_reserved          - A small sub-block nested inside
#                              vlan_cidr, wholly owned by this pool's own
#                              floor+elastic nodes (and the observability
#                              host, if it joins this pool's VLAN) --
#                              nothing else should ever be assigned an
#                              address inside it. Communicate this to the
#                              customer as a clean, round boundary
#                              ("everything from X onward is yours")
#                              rather than sizing it precisely -- generous
#                              slack here is harmless. Must be nested
#                              inside this pool's own vlan_cidr --
#                              validated at plan time
#                              (terraform/modules/nat-fleet's
#                              vlan_reserved_cidr_nested_in_vlan_cidr
#                              check).
#   private_ip_offset            - Starting host offset within
#                              public_subnet_id's CIDR for this pool's
#                              static VPC IPs. Must not overlap any other
#                              pool's [private_ip_offset,
#                              private_ip_offset+floor_nodes-1] range --
#                              see pool_vpc_offsets_no_overlap above. A
#                              GLOBALLY-scoped number (all pools share
#                              one public_subnet_id), unlike vlan_ip_offset
#                              below.
#   vlan_ip_offset               - Starting host offset within THIS
#                              pool's own vlan_cidr_reserved (not
#                              private_ip_offset's address space -- a
#                              separate, POOL-LOCAL range) for this
#                              pool's static VLAN IPs. Does not need to
#                              be globally unique across pools the way
#                              private_ip_offset does, since each pool's
#                              vlan_cidr_reserved is its own independent
#                              address space -- reusing the same small
#                              number (e.g. 20) in every pool is normal
#                              and expected.
#   elastic_ip_offset_start        - Starting VLAN host offset (within
#                              this pool's own vlan_cidr_reserved) for
#                              natctl-provisioned elastic nodes. Must
#                              leave enough room after [vlan_ip_offset,
#                              vlan_ip_offset + floor_nodes - 1] that
#                              raising floor_nodes later can never reach
#                              it -- see main.tf's
#                              "pool_floor_nodes_below_elastic_offset"
#                              check. Must also actually fit inside this
#                              pool's own (possibly small)
#                              vlan_cidr_reserved block, together with
#                              enough room for up to (max_nodes -
#                              floor_nodes) elastic nodes -- Terraform's
#                              own cidrhost() will hard-error at apply
#                              time if it doesn't (this module doesn't
#                              add a separate plan-time check for that
#                              specific case, since cidrhost()'s own
#                              error is already immediate and clear).
#   reserved_ip_pool             - Optional. Reserved IPv4 addresses you
#                              ALREADY OWN (reused from a prior
#                              deployment on this account, or reserved
#                              out-of-band ahead of time), for this
#                              pool's floor nodes to use instead of
#                              always minting a brand-new reservation.
#                              Assigned by position -- the first entry
#                              goes to this pool's first floor node by
#                              creation order, and so on; any floor node
#                              beyond the length of this list still gets
#                              a freshly-created reservation. Only
#                              meaningful when reserved_ip_enabled is
#                              true. Must not exceed this pool's
#                              floor_nodes in length -- see
#                              terraform/modules/nat-fleet's
#                              reserved_ip_pool_fits_node_count check.
#                              Defaults to [] (fully backward compatible).
# ---------------------------------------------------------------------------

variable "pools" {
  description = "Every NAT-fleet pool this environment provisions, keyed by a short pool identifier. See this file's own header comment above for the full field-by-field breakdown."
  type = map(object({
    fleet_label             = string
    floor_nodes             = number
    max_nodes               = number
    instance_type           = string
    vlan_label              = string
    vlan_cidr               = string
    vlan_cidr_reserved      = string
    private_ip_offset       = number
    vlan_ip_offset          = number
    elastic_ip_offset_start = number
    reserved_ip_pool        = optional(list(string), [])
  }))
}

variable "observability_vlan_pool" {
  description = "Which pool's VLAN the observability host joins directly -- its own static address (at a fixed offset just below that pool's floor nodes) is drawn from that pool's own vlan_cidr_reserved. Must be a key in var.pools, or \"\" to skip joining any VLAN entirely (natctl is then only reachable via VPC in single-dedicated-host mode -- see docs/NAT-GATEWAY-DEFINITIVE-GUIDE.html §2.3). Only meaningful when natctl_on_node_enabled is false (the single-dedicated-host layout) -- in natctl-on-node mode every pool's own nodes already run natctl locally, so there's no separate control-plane VLAN question. No default, deliberately -- an explicit choice, not a guess at which pool (if any) matters most for reachability."
  type        = string
}

variable "observability_private_ip_offset" {
  description = "Starting host offset within public_subnet_id's CIDR for the observability host's static VPC (eth1) address -- same mechanism as each pool's own private_ip_offset (see the pools variable above), but for the one non-pool instance this environment creates. Defaults to 5, clear of every pool's own private_ip_offset range in a fresh deployment (pools default to 20+). Live-found gap (2026-09-11): this was hardcoded to 5 with no override at all until this variable existed -- harmless for a single deployment, but a real collision (Linode's [400] \"The provided IP is already in use in the subnet\" at apply time) when this environment's public_subnet_id is a VPC subnet ALSO used by a completely separate LNG deployment (different terraform.tfvars/state) that happens to use the same offset for its own observability host -- this project's own pool_vpc_offsets_no_overlap-style checks can only ever see pools/resources within THIS state, never a second deployment's. Change this if you know this subnet is shared with another deployment already using the default. Checked against every pool's own private_ip_offset range at plan time (see main.tf's observability_vpc_offset_no_overlap_pools check) -- but only within this one deployment's own pools, same limitation as every other check here."
  type        = number
  default     = 5
}

variable "authorized_keys" {
  description = "SSH public key(s) installed on every instance"
  type        = list(string)
}

variable "root_pass" {
  description = "Root password for provisioned instances (SSH key auth is still recommended as the primary access path)"
  type        = string
  sensitive   = true
}

variable "ip_failover_enabled" {
  description = "Enable BIDIRECTIONAL BGP-based IP Sharing (FRR) between buddy pairs so a dead node's public IP fails over, not just its conntrack state — each node self-announces its own IP and backs up its buddy's simultaneously. Requires linode_bgp_dcid to be set for your region. Applies uniformly to every pool. See docs/NAT-GATEWAY-DEFINITIVE-GUIDE.html §4.3/§4.4."
  type        = bool
  default     = false
}

variable "linode_bgp_dcid" {
  description = "Linode BGP data-center ID for IP Sharing's route-server neighbors. Look this up from Linode's current failover documentation (https://www.linode.com/docs/products/compute/compute-instances/guides/failover/) for your region — deliberately not hardcoded here since it's a Linode-side mapping that can change. Required if ip_failover_enabled is true."
  type        = number
  default     = null
}

variable "reserved_ip_enabled" {
  description = "Whether every NAT node's primary public IP (floor AND natctl-provisioned elastic nodes, in every pool) is a Linode Reserved IP instead of the ephemeral one Linode auto-assigns — so a node's egress IP stays the same even across an instance replacement, which matters if any downstream service IP-whitelists this fleet's addresses. Off by default: Linode's Reserved IP feature is account-gated (\"IP reservation is not currently available to all users\") — confirm it's enabled for your account (Cloud Manager, or Linode support) before turning this on. See terraform/modules/nat-fleet/variables.tf's reserved_ip_enabled and docs/NAT-GATEWAY-DEFINITIVE-GUIDE.html §4.6 for the full design, including what this does NOT cover (egress_ips_per_node's extra IPs stay ephemeral)."
  type        = bool
  default     = false
}

variable "placement_group_enabled" {
  description = "Whether every pool's floor nodes are spread across Linode Placement Groups (anti_affinity:local) so Akamai avoids co-locating them on the same physical host — closes the correlated-physical-host-failure gap that buddy conntrack sync + BGP IP failover alone don't cover (both narrow the risk of one node dying, but do nothing if both members of a buddy pair happen to sit on the same physical host and that host fails as a unit). Off by default — same opt-in pattern as reserved_ip_enabled. Floor nodes only; natctl-provisioned elastic nodes are NOT covered, deliberately out of scope. See terraform/modules/nat-fleet/variables.tf's placement_group_enabled and docs/NAT-GATEWAY-DEFINITIVE-GUIDE.html §4.5 for the full design, including the multi-group chunking behavior for pools over 5 nodes."
  type        = bool
  default     = false
}

variable "placement_group_policy" {
  description = "Linode's placement_group_policy for every placement group this environment creates when placement_group_enabled is true: \"strict\" (default — refuses to violate anti-affinity, fails the operation rather than co-locating) or \"flexible\" (best-effort). See terraform/modules/nat-fleet/variables.tf's placement_group_policy for the full trade-off."
  type        = string
  default     = "strict"
}

# ---------------------------------------------------------------------------
# natctl-on-node (opt-in) — removes the requirement for a dedicated
# control-plane host by running natctl itself, leader-elected with STONITH
# fencing (power off the previous leader, poll for confirmed offline, only
# then claim leadership), on every NAT node in every pool instead. See
# controller/natctl/leader_election.py and
# docs/NAT-GATEWAY-DEFINITIVE-GUIDE.html §2.3/§2.4. This is defense-in-depth,
# not mathematically perfect mutual exclusion -- fencing briefly interrupts
# a node's own NAT traffic too. Leave natctl_on_node_enabled at its default
# (false) to keep this environment's original single-dedicated-host layout
# (module.observability runs natctl) unchanged.
# ---------------------------------------------------------------------------

variable "natctl_on_node_enabled" {
  description = "Run natctl on every NAT node (every pool, floor AND elastic) instead of on a single dedicated module.observability host. When true, this file also flips module.observability's run_natctl off (running natctl in two places at once would be redundant and the observability host isn't given its own leader-election identity) and turns on leader_election in the composed natctl.yaml, with ANY node in the fleet eligible to hold leadership."
  type        = bool
  default     = false
}

variable "natctl_object_storage_endpoint" {
  description = "S3-compatible endpoint URL for a Linode Object Storage bucket (e.g. \"https://us-east-1.linodeobjects.com\") -- REQUIRED unconditionally, not just when natctl_on_node_enabled: terraform/modules/artifacts uploads exporter.py/buddy_sync.py/the natctl package here and every NAT node fetches them at boot, since embedding their content directly in cloud-init exceeds Linode's 16384-byte decoded user_data limit (see that module's main.tf header for the full numbers). Also still backs the leader-election lease when natctl_on_node_enabled (controller/natctl/leader_election.py's ObjectStorageLeaseStore) -- same bucket, dual purpose."
  type        = string
}

variable "natctl_object_storage_bucket" {
  description = "Object Storage bucket name -- see natctl_object_storage_endpoint above for why this is required unconditionally now (artifact hosting), not just for the leader-election lease."
  type        = string
}

variable "natctl_object_storage_access_key" {
  description = "Object Storage access key -- used both to upload artifacts at apply time (terraform/modules/artifacts) and, when natctl_on_node_enabled, written to each node's /etc/natctl/env for the leader-election lease (kept out of natctl_config_yaml itself -- see config.py's LeaderElectionConfig docstring for why). Required unconditionally now -- see natctl_object_storage_endpoint above."
  type        = string
  sensitive   = true
}

variable "natctl_object_storage_secret_key" {
  description = "Object Storage secret key -- see natctl_object_storage_access_key above. Required unconditionally now."
  type        = string
  sensitive   = true
}

variable "grafana_admin_password" {
  type      = string
  sensitive = true
  default   = "changeme-lng-grafana"
}

# ---------------------------------------------------------------------------
# Monitoring-stack opt-out — reuse an existing Prometheus/Grafana (or
# push into one via remote_write) instead of standing up a second one. Set
# run_monitoring_stack false and give the three prometheus_remote_write_*
# values to have natctl's own metrics forwarded to your existing
# Prometheus instead of this environment standing up its own. See
# terraform/modules/observability's run_monitoring_stack/
# prometheus_remote_write_url.
# ---------------------------------------------------------------------------

variable "run_monitoring_stack" {
  description = "Whether this environment provisions its own Prometheus/Grafana/Alertmanager at all. Default true (unchanged behavior). Set to false if you already have monitoring — point your own Prometheus at every NAT node's :9200/metrics (via natctl's GET /file_sd for target discovery) instead, or set customer_prometheus_remote_write_url below to have a still-provisioned local Prometheus forward samples into your existing backend."
  type        = bool
  default     = true
}

variable "customer_prometheus_remote_write_url" {
  description = "If set (and run_monitoring_stack is true), the local Prometheus this environment provisions also pushes every scraped sample here via remote_write — e.g. your Grafana Cloud / Mimir / Thanos Receive / VictoriaMetrics endpoint. Leave empty for the original local-only behavior."
  type        = string
  default     = ""
}

variable "customer_prometheus_remote_write_username" {
  description = "Basic-auth username for customer_prometheus_remote_write_url, if your receiver requires it."
  type        = string
  default     = ""
}

variable "customer_prometheus_remote_write_password" {
  description = "Basic-auth password for customer_prometheus_remote_write_url, if your receiver requires it."
  type        = string
  sensitive   = true
  default     = ""
}
