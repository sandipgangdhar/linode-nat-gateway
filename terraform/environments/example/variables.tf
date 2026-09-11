# variables.tf (terraform/environments/example)
#
# Every input this example environment accepts. Copy
# terraform.tfvars.example to terraform.tfvars and fill in at minimum
# linode_token, authorized_keys, and root_pass -- everything else has a
# working default.
#
# -----------------------------------------------------
# Key Parameters:
#
# 1) linode_token/region/authorized_keys/root_pass - Required; account and
#    access basics.
# 2) shared_pool_floor_nodes/shared_pool_max_nodes/nat_instance_type -
#    Sizing for the default pool.
# 3) enable_dedicated_pool_example - Toggle the second example pool on/off.
# 4) ip_failover_enabled/linode_bgp_dcid - Buddy IP failover (see
#    docs/NAT-GATEWAY-DEFINITIVE-GUIDE.html §4.4, "BGP-Based IP Failover").
# 5) reserved_ip_enabled - Fixed/whitelist-safe public IPs for every node,
#    floor and elastic (account-gated by Linode, off by default).
# 6) shared_pool_reserved_ip_pool/dedicated_acme_pool_reserved_ip_pool -
#    Bring-your-own reserved IPs for floor nodes, by position, off
#    by default.
# 7) placement_group_enabled/placement_group_policy - Spread floor nodes
#    across separate physical hosts (off by default; floor nodes
#    only).
# 8) grafana_admin_password         - Change before any real deployment.
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
  description = "Numeric id of your existing VPC subnet that every NAT node's eth1 (VPC) interface and the observability instance attach to. Its CIDR is looked up automatically (see terraform/modules/vpc's data.linode_vpc_subnet.public) -- make sure it has enough headroom for every pool's private_ip_offset range (shared pool starts at .20, dedicated-acme at .50 in this example -- see main.tf's module.nat_fleet_* calls) before creating it."
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
# VLAN label/CIDR are real input
# variables so you can override them from terraform.tfvars without editing
# main.tf. Linode VLANs have no standalone Terraform resource (a VLAN is
# just a label -- see terraform/modules/nat-fleet's vlan_label/vlan_cidr
# variables) so, unlike the VPC above, there is nothing to "bring your
# own" here in the sense of a pre-existing object; you're simply choosing
# the label/address space instead of having it chosen for you. Defaults
# reproduce this environment's original values exactly, so leaving these
# unset changes nothing.
# ---------------------------------------------------------------------------

variable "vlan_label_shared" {
  description = "VLAN label the shared pool's nodes (and its private client fleet) join. See terraform/modules/nat-fleet's vlan_label."
  type        = string
  default     = "lng-vlan-shared"
}

variable "vlan_cidr_shared" {
  description = "The FULL, real VLAN address space for the shared pool -- e.g. a customer's whole /16. Every node (floor, elastic, and the observability host when it joins this VLAN) configures THIS CIDR's own prefix length on its interface, so routing works across the entire VLAN, not just this project's own corner of it. 2026-09-11 range-simplification refactor: this project's own floor+elastic nodes only ever draw addresses from vlan_cidr_shared_reserved below (a small, wholly-owned sub-block nested inside this CIDR) -- everything else in vlan_cidr_shared is free for a customer's own automation to assign client addresses from, with no reservation-window sizing needed on their side at all. OK to overlap or nest with vlan_cidr_dedicated_acme -- separate VLAN labels are fully isolated L2 domains on Linode regardless of numeric CIDR overlap."
  type        = string
  default     = "192.168.100.0/22" # covers private-app-1 + private-app-2 clients
}

variable "vlan_cidr_shared_reserved" {
  description = "A small sub-block nested inside vlan_cidr_shared, wholly owned by the shared pool's own floor+elastic nodes (and the observability host, when it joins this VLAN) -- nothing else should ever be assigned an address inside it. Communicate this to the customer as a clean, round boundary (\"everything from X onward is yours\") rather than sizing it precisely -- generous slack here is harmless. Must be nested inside vlan_cidr_shared -- validated at plan time (terraform/modules/nat-fleet's vlan_reserved_cidr_nested_in_vlan_cidr check). Replaces the old vlan_elastic_headroom_margin + client_static_vlan_reserved mechanism."
  type        = string
  default     = "192.168.100.0/24" # nested inside vlan_cidr_shared's own default /22 above
}

variable "vlan_label_dedicated_acme" {
  description = "VLAN label the dedicated-acme example pool's nodes join. Only relevant if enable_dedicated_pool_example is true. See terraform/modules/nat-fleet's vlan_label. Can be DIFFERENT from vlan_label_shared (separate VLANs, the original/simplest setup) or the SAME value (\"same-VLAN mode\": both pools share one physical VLAN, coordinating only on keeping their own small reserved sub-blocks -- see vlan_cidr_shared's description above -- from overlapping each other); if you make it the same, vlan_cidr_dedicated_acme_reserved must not overlap vlan_cidr_shared_reserved -- main.tf's \"vlan_cidr_reserved_no_overlap_same_vlan\" check block validates this at plan time rather than leaving it to chance."
  type        = string
  default     = "lng-vlan-acme"
}

variable "vlan_cidr_dedicated_acme" {
  description = "The FULL, real VLAN address space for the dedicated-acme example pool -- see vlan_cidr_shared above for the same reasoning. Overlapping/nesting inside vlan_cidr_shared's range is fine regardless of whether vlan_label_dedicated_acme matches vlan_label_shared or not. Only relevant if enable_dedicated_pool_example is true."
  type        = string
  default     = "192.168.105.0/24"
}

variable "vlan_cidr_dedicated_acme_reserved" {
  description = "Same as vlan_cidr_shared_reserved above, but for the dedicated-acme pool's own floor+elastic nodes. Must be nested inside vlan_cidr_dedicated_acme. Only relevant if enable_dedicated_pool_example is true."
  type        = string
  default     = "192.168.105.0/27" # nested inside vlan_cidr_dedicated_acme's own default /24 above
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

variable "shared_pool_floor_nodes" {
  description = "Terraform-managed baseline node count for the shared pool. Defaults to 1 -- start minimal and raise it (or let natctl add elastic capacity above the floor) once real load justifies it, rather than assuming multi-node capacity is needed up front. At 1 node, conntrack buddy-sync and buddy IP failover (if enabled) simply stay dormant -- there's nothing to pair with -- and activate automatically the moment a second node joins, no reconfiguration needed. See docs/NAT-GATEWAY-DEFINITIVE-GUIDE.html §5.1 (Two Tiers of Capacity)."
  type        = number
  default     = 1
}

variable "shared_pool_max_nodes" {
  description = "Ceiling natctl will never scale the shared pool past, floor + elastic combined."
  type        = number
  default     = 12
}

variable "enable_dedicated_pool_example" {
  description = "Whether to provision the example dedicated pool (for a tenant needing isolated capacity) alongside the shared pool."
  type        = bool
  default     = true
}

variable "nat_instance_type" {
  type    = string
  default = "g6-dedicated-4"
}

variable "grafana_admin_password" {
  type      = string
  sensitive = true
  default   = "changeme-lng-grafana"
}

variable "ip_failover_enabled" {
  description = "Enable BIDIRECTIONAL BGP-based IP Sharing (FRR, v5) between buddy pairs so a dead node's public IP fails over, not just its conntrack state — each node self-announces its own IP and backs up its buddy's simultaneously. Requires linode_bgp_dcid to be set for your region. See docs/NAT-GATEWAY-DEFINITIVE-GUIDE.html §4.3/§4.4."
  type        = bool
  default     = false
}

variable "linode_bgp_dcid" {
  description = "Linode BGP data-center ID for IP Sharing's route-server neighbors. Look this up from Linode's current failover documentation (https://www.linode.com/docs/products/compute/compute-instances/guides/failover/) for your region — deliberately not hardcoded here since it's a Linode-side mapping that can change. Required if ip_failover_enabled is true."
  type        = number
  default     = null
}

variable "reserved_ip_enabled" {
  description = "Whether every NAT node's primary public IP (floor AND natctl-provisioned elastic nodes) is a Linode Reserved IP instead of the ephemeral one Linode auto-assigns — so a node's egress IP stays the same even across an instance replacement, which matters if any downstream service IP-whitelists this fleet's addresses. Off by default: Linode's Reserved IP feature is account-gated (\"IP reservation is not currently available to all users\") — confirm it's enabled for your account (Cloud Manager, or Linode support) before turning this on. See terraform/modules/nat-fleet/variables.tf's reserved_ip_enabled and docs/NAT-GATEWAY-DEFINITIVE-GUIDE.html §4.6 for the full design, including what this does NOT cover (egress_ips_per_node's extra IPs stay ephemeral)."
  type        = bool
  default     = false
}

variable "shared_pool_reserved_ip_pool" {
  description = "Reserved IPv4 addresses you ALREADY OWN (reused from a prior deployment on this account, or reserved out-of-band ahead of time), for the shared pool's floor nodes to use instead of always minting a brand-new reservation. Assigned by position -- the first entry goes to this pool's first floor node by creation order, and so on; any floor node beyond the length of this list still gets a freshly-created reservation. Only meaningful when reserved_ip_enabled is true. Must not exceed shared_pool_floor_nodes in length -- see terraform/modules/nat-fleet's reserved_ip_pool_fits_node_count check block. Default [] (fully backward compatible)."
  type        = list(string)
  default     = []
}

variable "dedicated_acme_pool_reserved_ip_pool" {
  description = "Same as shared_pool_reserved_ip_pool above, but for the dedicated-acme-corp pool's floor nodes (only meaningful when enable_dedicated_pool_example is true). Kept as a separate variable, not shared with the shared pool's list, since the two pools' floor node counts/positions are entirely independent -- see terraform/modules/nat-fleet's reserved_ip_pool for the full design."
  type        = list(string)
  default     = []
}

variable "placement_group_enabled" {
  description = "Whether floor nodes (shared and, if enabled, dedicated-acme-corp pools) are spread across Linode Placement Groups (anti_affinity:local) so Akamai avoids co-locating them on the same physical host — closes the correlated-physical-host-failure gap that buddy conntrack sync + BGP IP failover alone don't cover (both narrow the risk of one node dying, but do nothing if both members of a buddy pair happen to sit on the same physical host and that host fails as a unit). Off by default — same opt-in pattern as reserved_ip_enabled. Floor nodes only; natctl-provisioned elastic nodes are NOT covered, deliberately out of scope. See terraform/modules/nat-fleet/variables.tf's placement_group_enabled and docs/NAT-GATEWAY-DEFINITIVE-GUIDE.html §4.5 for the full design, including the multi-group chunking behavior for pools over 5 nodes."
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
# then claim leadership), on every NAT node instead. See
# controller/natctl/leader_election.py and
# docs/NAT-GATEWAY-DEFINITIVE-GUIDE.html §2.3/§2.4. This is defense-in-depth,
# not mathematically perfect mutual exclusion -- fencing briefly interrupts
# a node's own NAT traffic too. Leave natctl_on_node_enabled at its default
# (false) to keep this environment's original single-dedicated-host layout
# (module.observability runs natctl) unchanged.
# ---------------------------------------------------------------------------

variable "natctl_on_node_enabled" {
  description = "Run natctl on every NAT node (both example pools, floor AND elastic) instead of on a single dedicated module.observability host. When true, this file also flips module.observability's run_natctl off (running natctl in two places at once would be redundant and the observability host isn't given its own leader-election identity) and turns on leader_election in the composed natctl.yaml, with ANY node in the fleet eligible to hold leadership."
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
