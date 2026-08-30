# variables.tf (terraform/modules/nat-fleet)
#
# Every input this module accepts, grouped conceptually below. Each
# individual variable already carries a detailed inline `description` --
# this header is the map to read them in context rather than duplicating
# each one.
#
# -----------------------------------------------------
# Groups of parameters:
#
# 1) Identity/placement  - fleet_label, pool_name, region, vpc_id,
#    public_subnet_id/cidr, vlan_label/cidr/ip_offset, private_subnet_cidrs,
#    firewall_id, tags.
# 2) Sizing              - node_count (Terraform floor), instance_type,
#    image, egress_ips_per_node, conntrack_max, private_ip_offset.
# 3) Access              - authorized_keys, root_pass.
# 4) Buddy-sync / IP failover - natctl_roster_url, ip_failover_enabled,
#    linode_bgp_dcid (see docs/ARCHITECTURE.md section 3.5/3.6).
#
# -----------------------------------------------------
# Usage:
#
# - Required (no default): fleet_label, region, vpc_id, public_subnet_id,
#   public_subnet_cidr, vlan_label, vlan_cidr, private_subnet_cidrs,
#   firewall_id, authorized_keys, root_pass.
# - Everything else has a safe default so a minimal call still boots a
#   working, feature-flagged-off fleet.
# - ip_failover_enabled requires natctl_roster_url and linode_bgp_dcid to
#   also be set.
#
# -----------------------------------------------------
# Author:
# - Sandip Gangdhar
# - GitHub: https://github.com/sandipgangdhar
#
# (c) Linode-NAT-Gateway (LNG) | Developed by Sandip Gangdhar | 2026
# -----------------------------------------------------

variable "fleet_label" {
  description = "Unique label prefix for this fleet, e.g. lng-shared or lng-dedicated-acme"
  type        = string
}

variable "pool_name" {
  description = "Pool identifier tenants are mapped to (\"shared\" or a dedicated tenant name). Tagged onto every node for natctl's fleet discovery — see docs/ARCHITECTURE.md §4."
  type        = string
  default     = "shared"
}

variable "region" {
  type = string
}

variable "vpc_id" {
  type = number
}

variable "public_subnet_id" {
  description = "The VPC subnet every node's eth1 (VPC) interface lives in. Serves buddy-pair conntrackd sync traffic — see docs/ARCHITECTURE.md §3.5. This is NOT where the private client fleet lives anymore (see vlan_label) — VPC does not support routing a client's default gateway through a peer instance to reach non-VPC destinations, which is why v4 moved that job to VLAN. See docs/ARCHITECTURE.md §3.0 for the validated finding behind this."
  type        = number
}

variable "public_subnet_cidr" {
  description = "CIDR of public_subnet_id, used to compute deterministic static VPC IPs for this fleet's nodes."
  type        = string
}

variable "vlan_label" {
  description = "Name of the VLAN every node's eth2 interface joins, and that private client instances also join, for transparent NAT egress. VLANs aren't a standalone Terraform resource on Linode — they come into existence implicitly the first time any instance attaches an interface with this label, and disappear when the last one detaches. See docs/ARCHITECTURE.md §3.0."
  type        = string
}

variable "vlan_cidr" {
  description = "CIDR used to compute this fleet's deterministic static VLAN IPs (via cidrhost + vlan_ip_offset), same pattern as public_subnet_cidr for VPC. Must not overlap with any other fleet/pool's offset range sharing the same VLAN."
  type        = string
}

variable "vlan_ip_offset" {
  description = "Starting host offset within vlan_cidr for this fleet's static VLAN IPs."
  type        = number
  default     = 20
}

variable "private_subnet_cidrs" {
  description = "CIDR(s) of the private client fleet on the VLAN that this pool is allowed to forward traffic for (the source-address allow-list in the NAT node's forward chain). Despite the name (kept for continuity with earlier versions), these are VLAN-side CIDRs in v4, not VPC subnets — see vlan_label/vlan_cidr above."
  type        = list(string)
}

variable "firewall_id" {
  type = number
}

variable "node_count" {
  description = "Floor (Terraform-managed baseline) node count for this fleet. Defaults to 1 -- start minimal and raise it (or lean on natctl's elastic autoscaling above the floor) once real load justifies more, rather than assuming multi-node capacity is needed up front. At 1 node, conntrack buddy-sync/buddy IP failover (if enabled for this pool) simply stay dormant until a second node exists -- see docs/ARCHITECTURE.md §3.5's \"Already self-adjusts to node count\" note. natctl may add more elastic nodes above this floor if autoscaling is enabled — see docs/ARCHITECTURE.md §4 and controller/natctl/fleet.py. Scaling this down is a normal `terraform apply`; natctl never removes floor nodes, only ones it provisioned itself."
  type        = number
  default     = 1
}

variable "private_ip_offset" {
  description = "Starting host offset (within public_subnet's CIDR) for this fleet's static VPC IPs. Give each fleet/pool sharing a subnet a non-overlapping offset+node_count range."
  type        = number
  default     = 20
}

variable "instance_type" {
  description = "Base instance type for every floor node in this pool. Overridable per node via node_instance_type_overrides below (e.g. after natctl_cli's operator-driven `resize` command vertically-scales a specific floor node) -- this remains the default for any node not explicitly overridden."
  type        = string
  default     = "g6-dedicated-4"
}

variable "node_instance_type_overrides" {
  description = "Optional per-node instance_type override, keyed by node_id (e.g. \"lng-shared-2\" => \"g6-dedicated-8\"). Any node_id not present here uses instance_type above. This is how Terraform represents a floor whose nodes have been individually vertically-scaled via natctl_cli's `resize` command without drift on the next `terraform apply` -- see docs/VERTICAL-SCALING.md. Left empty (default) for a uniform floor, the original behavior."
  type        = map(string)
  default     = {}
}

variable "image" {
  type    = string
  default = "linode/ubuntu22.04"
}

variable "authorized_keys" {
  type = list(string)
}

variable "root_pass" {
  type      = string
  sensitive = true
}

variable "egress_ips_per_node" {
  description = "Public egress IPs per node beyond the primary eth0 address. Each node owns its extra IPs permanently (no sharing/failover for these — only the PRIMARY eth0 address participates in buddy IP failover, see ip_failover_enabled) — more IPs per node means more 55K-connection buckets per node."
  type        = number
  default     = 1
}

variable "reserved_ip_enabled" {
  description = "Whether each node's primary eth0 public IP is a Linode Reserved IP (linode_networking_ip with reserved = true) instead of the ephemeral one Linode auto-assigns on instance creation. A reserved IP is allocated up front and stays the SAME address for as long as that node_id slot exists in this fleet, even across an instance replacement (e.g. a Terraform-forced recreate from changing instance_type/image) — the ephemeral default does not survive that. Solves the operational problem of downstream services that IP-whitelist this fleet's egress addresses: with this off, a node replacement silently changes the IP a whitelist entry depends on. Off by default because Linode's Reserved IP feature is account-gated (\"IP reservation is not currently available to all users\" — Linode's own provider docs) -- confirm it's enabled on your account (Cloud Manager, or ask Linode support) before turning this on; enabling it against an ineligible account fails the linode_networking_ip resource outright. Does NOT cover egress_ips_per_node's extra IPs (still ephemeral) or elastic (natctl-provisioned) nodes -- those are handled by natctl.yaml's own reserved_ip_enabled field (controller/natctl/config.py), kept as a SEPARATE toggle since elastic nodes are created by natctl's own Linode API calls, not this module. See docs/ARCHITECTURE.md and docs/RUNBOOK.md."
  type        = bool
  default     = false
}

variable "conntrack_max" {
  type    = number
  default = 1048576
}

variable "tags" {
  type    = list(string)
  default = []
}

variable "natctl_roster_url" {
  description = "Base URL of natctl's roster API reachable from this fleet's nodes, e.g. \"http://10.0.0.5:8099\" (no trailing slash, no /fleet/<pool> suffix — that's appended per-node). Wires up buddy-sync/ for conntrackd buddy-pair sync and (if ip_failover_enabled) buddy IP failover — see docs/ARCHITECTURE.md §3.5. Leave empty (the default) to disable both entirely for this fleet's Terraform-managed floor nodes. Must match the natctl_roster_base_url set for this pool in natctl.yaml so natctl-provisioned elastic nodes use the same value (see controller/natctl/cloud_init.py)."
  type        = string
  default     = ""
}

variable "ip_failover_enabled" {
  description = "Whether nodes in this fleet run FRR (v5 — replaces lelastic, which was architecturally locked to one role per node) for BIDIRECTIONAL BGP-based IP Sharing: each node self-announces its own eth0 public IP AND backs up its buddy's, so a node's buddy can take over its IP on failure, making buddy-pair conntrack sync (natctl_roster_url above) actually deliver session survival rather than just unusable mirrored state — see docs/ARCHITECTURE.md §3.5/§3.6/§3.6.1 for why both pieces are needed together and how bidirectional coverage was validated live. Requires natctl_roster_url to be set. Requires linode_bgp_dcid below. IP Sharing availability varies by Linode data center — confirm your region supports it before enabling (https://techdocs.akamai.com/cloud-computing/docs/configure-failover-on-a-compute-instance)."
  type        = bool
  default     = false
}

variable "linode_bgp_dcid" {
  description = "Linode's numeric data-center ID for BGP-based IP Sharing's route-server neighbors (2600:3c0f:<dcid>:34::1-4), specific to the region you're deploying into. Look this up from Linode's current failover documentation for your region — deliberately not hardcoded here, since this mapping is Linode-maintained and region IDs are added over time. Required if ip_failover_enabled is true."
  type        = number
  default     = null
}

# ---------------------------------------------------------------------------
# natctl-on-node (opt-in): removes the requirement for a dedicated
# control-plane host by running natctl itself on every node in THIS fleet,
# safely, via leader election with STONITH-style fencing — see
# controller/natctl/leader_election.py and docs/ARCHITECTURE.md's
# leader-election section. Leave natctl_on_node_enabled at its default
# (false) to keep the original single-dedicated-host layout unchanged
# (terraform/modules/observability) — nothing below matters in that case.
# ---------------------------------------------------------------------------

variable "natctl_on_node_enabled" {
  description = "Whether every node in this fleet also runs natctl itself (leader-elected, with STONITH fencing — see controller/natctl/leader_election.py), instead of relying on a separate terraform/modules/observability host for it. This fleet's nodes become natctl's identity (NATCTL_SELF_NODE_ID/NATCTL_SELF_LINODE_ID) as well as its execution target. Requires natctl_config_yaml and (for the fencing lock) object_storage_* below to all be set. See docs/ARCHITECTURE.md's leader-election section for the honestly-stated trade-offs (fencing briefly interrupts a node's own NAT traffic) before enabling this in production."
  type        = bool
  default     = false
}

variable "natctl_config_yaml" {
  description = "The fully-composed natctl.yaml content for this entire environment (every pool's settings, including this one) — the SAME value terraform/modules/observability's natctl_config_yaml carries in the original layout, since every node running natctl needs to know about every pool, not just this one (see controller/natctl/fleet.py — one process manages every configured pool). Composed once at the environment level (terraform/environments/example/main.tf), not per-fleet. Required if natctl_on_node_enabled."
  type        = string
  default     = ""
  sensitive   = true
}

variable "linode_token" {
  description = "Linode API Personal Access Token (linodes/vpc/networking read_write scopes — see docs/RUNBOOK.md), written to /etc/natctl/env on every node in this fleet. Required if natctl_on_node_enabled. NOTE this is a real security-scope change from the original layout: this credential now needs to exist on every NAT node rather than one tightly-firewalled control-plane host — see docs/ARCHITECTURE.md's leader-election section for this trade-off stated plainly."
  type        = string
  default     = ""
  sensitive   = true
}

variable "object_storage_access_key" {
  description = "Object Storage access key for the leader-election lease bucket (endpoint/bucket/key themselves live in natctl_config_yaml's leader_election block, composed once at the environment level — see terraform/environments/example/main.tf), written to /etc/natctl/env (NATCTL_OBJECT_STORAGE_ACCESS_KEY) rather than baked into natctl_config_yaml — see config.py's LeaderElectionConfig.resolved_access_key() for why this stays out of the widely-distributed config file. Required if natctl_on_node_enabled and leader_election.enabled."
  type        = string
  default     = ""
  sensitive   = true
}

variable "object_storage_secret_key" {
  description = "Object Storage secret key for the leader-election lease bucket — see object_storage_access_key above for the same env-var-not-config-file reasoning. Required if natctl_on_node_enabled."
  type        = string
  default     = ""
  sensitive   = true
}

# ---------------------------------------------------------------------------
# v9: fetched-at-boot artifact URLs (terraform/modules/artifacts) -- see
# that module's main.tf header for the full "why" (Linode's 16384-byte
# decoded cloud-init limit). Required, unconditionally -- unlike
# object_storage_access_key/secret_key above, exporter_py_url/
# buddy_sync_py_url are needed on EVERY node regardless of
# natctl_on_node_enabled, since exporter.py alone already contributes to
# blowing the budget. natctl_file_urls is only actually consumed when
# natctl_on_node_enabled is true, but it's cheap to always pass through.
# ---------------------------------------------------------------------------

variable "exporter_py_url" {
  description = "Public URL (terraform/modules/artifacts' exporter_py_url output) this fleet's nodes curl exporter.py from at boot, instead of it being embedded inline in cloud-init -- see nat-node.yaml.tftpl's runcmd."
  type        = string
}

variable "buddy_sync_py_url" {
  description = "Public URL (terraform/modules/artifacts' buddy_sync_py_url output) this fleet's nodes curl buddy_sync.py from at boot, when natctl_roster_url is set -- see nat-node.yaml.tftpl's runcmd."
  type        = string
}

variable "natctl_file_urls" {
  description = "Map of natctl/*.py filename -> public URL (terraform/modules/artifacts' natctl_file_urls output), fetched one curl per file at boot when natctl_on_node_enabled -- see nat-node.yaml.tftpl's runcmd."
  type        = map(string)
  default     = {}
}

variable "nat_exporter_service_url" {
  description = "Public URL (terraform/modules/artifacts' nat_exporter_service_url output) this fleet's nodes curl nat-exporter.service from at boot, instead of it being embedded inline -- see nat-node.yaml.tftpl's runcmd. v10."
  type        = string
}

variable "lng_buddy_sync_service_url" {
  description = "Public URL (terraform/modules/artifacts' lng_buddy_sync_service_url output) this fleet's nodes curl lng-buddy-sync.service from at boot, when natctl_roster_url is set -- see nat-node.yaml.tftpl's runcmd. v10."
  type        = string
}

variable "conntrackd_peer_service_url" {
  description = "Public URL (terraform/modules/artifacts' conntrackd_peer_service_url output) this fleet's nodes curl the conntrackd@.service TEMPLATE unit from at boot, when natctl_roster_url is set -- see nat-node.yaml.tftpl's runcmd. v10."
  type        = string
}

variable "natctl_service_url" {
  description = "Public URL (terraform/modules/artifacts' natctl_service_url output) this fleet's nodes curl natctl.service from at boot, when natctl_on_node_enabled -- see nat-node.yaml.tftpl's runcmd. v10."
  type        = string
}

variable "natctl_requirements_txt_url" {
  description = "Public URL (terraform/modules/artifacts' natctl_requirements_txt_url output) this fleet's nodes curl controller/requirements.txt from at boot, when natctl_on_node_enabled -- see nat-node.yaml.tftpl's runcmd. v10."
  type        = string
}

# v21: "source" (default, every existing deployment) or "binary" -- picks
# between fetching exporter/buddy-sync/natctl as .py source run via python3
# (the exporter_py_url/buddy_sync_py_url/natctl_file_urls variables above)
# or as pre-compiled native executables (the three *_bin_url variables
# below). See controller/natctl/cloud_init.py's matching v21 comment and
# docs/PUBLISHING.md -- exists to support a customer-facing distribution of
# this project that ships without Python source. Defaulting to "source"
# means this is a no-op for every deployment that doesn't set it.
variable "agent_distribution" {
  description = "\"source\" (default) or \"binary\" -- see this file's v21 comment above nat-node.yaml.tftpl's matching agent_distribution template variable."
  type        = string
  default     = "source"
}

variable "exporter_bin_url" {
  description = "Public URL of a pre-compiled nat-exporter binary, used instead of exporter_py_url when agent_distribution is \"binary\". Cheap to leave empty otherwise."
  type        = string
  default     = ""
}

variable "buddy_sync_bin_url" {
  description = "Public URL of a pre-compiled buddy-sync binary, used instead of buddy_sync_py_url when agent_distribution is \"binary\". Cheap to leave empty otherwise."
  type        = string
  default     = ""
}

variable "natctl_bin_url" {
  description = "Public URL of a pre-compiled natctl binary, used instead of natctl_file_urls/natctl_requirements_txt_url when agent_distribution is \"binary\" and natctl_on_node_enabled. Cheap to leave empty otherwise."
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# v10: per-node dynamic config uploads. nftables.conf differs per node
# (vpc_ip, vlan_ip, cidrs, reserved_public_ip), so
# unlike the static files above they can't be uploaded once by the shared
# artifacts module -- this module uploads each node's own rendered content
# as its own Object Storage object (see main.tf) and reuses the SAME
# bucket/credentials the artifacts module and leader-election lease store
# already use, rather than provisioning a second bucket.
# ---------------------------------------------------------------------------

variable "object_storage_bucket" {
  description = "Object Storage bucket this fleet's per-node nftables.conf objects are uploaded into -- same bucket terraform/modules/artifacts and natctl_object_storage_bucket already use. Required (every node needs nftables.conf fetched at boot)."
  type        = string
}

variable "object_storage_s3_region" {
  description = "The Object Storage S3-compatible endpoint's region/cluster id (e.g. \"in-maa-1\") -- see terraform/modules/artifacts/variables.tf's s3_region for why this is NOT necessarily var.region."
  type        = string
}
