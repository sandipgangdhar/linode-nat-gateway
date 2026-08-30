# variables.tf (terraform/modules/observability)
#
# Inputs for the control-plane instance: placement, sizing, credentials,
# and the fully-rendered natctl config it should boot with.
#
# -----------------------------------------------------
# Key Parameters:
#
# 1) label/region/instance_type/image - Standard instance placement/sizing.
# 2) authorized_keys/root_pass         - SSH access.
# 3) vpc_id/subnet_id/private_ip        - VPC placement; private_ip is
#    pinned (not auto-assigned) so it's a known, stable address for every
#    NAT node and client instance to reach natctl at.
# 4) firewall_id                        - The control-plane Cloud Firewall
#    from terraform/modules/vpc.
# 5) grafana_admin_password             - Change this from the default
#    before any real deployment.
# 6) natctl_config_yaml                 - The full natctl.yaml content as a
#    string, composed at the environment level (see
#    terraform/environments/example/main.tf) so this module doesn't need
#    to know about individual pools.
# 7) linode_token                       - API token natctl uses; needs
#    linodes:read_write, vpc:read_write, networking:read_write.
#
# -----------------------------------------------------
# Author:
# - Sandip Gangdhar
# - GitHub: https://github.com/sandipgangdhar
#
# (c) Linode-NAT-Gateway (LNG) | Developed by Sandip Gangdhar | 2026
# -----------------------------------------------------

variable "label" {
  type    = string
  default = "lng-observability"
}

variable "region" {
  type = string
}

variable "instance_type" {
  type    = string
  default = "g6-standard-2"
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

variable "vpc_id" {
  type = number
}

variable "subnet_id" {
  type = number
}

variable "private_ip" {
  description = "Static private IP for this instance in subnet_id — pinned (rather than auto-assigned) so client-agent instances and Terraform outputs have a known-in-advance address for natctl's roster API."
  type        = string
}

variable "firewall_id" {
  type = number
}

variable "grafana_admin_password" {
  type      = string
  sensitive = true
  default   = "changeme-lng-grafana"
}

variable "natctl_config_yaml" {
  description = "Fully-rendered natctl config (natctl.example.yaml shape) as a string — compose this at the environment level with yamlencode() or a heredoc so this module stays generic. See terraform/environments/example/main.tf."
  type        = string
  sensitive   = true
}

variable "linode_token" {
  description = "Linode API token natctl uses to discover fleet nodes and drive autoscaling. Scope: linodes:read_write, vpc:read_write, networking:read_write. Still required even when run_natctl is false, since Prometheus/Grafana/Alertmanager on this host don't need it but this module doesn't currently split that variable out further."
  type        = string
  sensitive   = true
}

variable "run_natctl" {
  description = "Whether THIS instance runs natctl itself, in addition to Prometheus/Grafana/Alertmanager. Default true preserves the original single-dedicated-host layout. Set to false once natctl runs on every NAT node instead (terraform/modules/nat-fleet's natctl_on_node_enabled) -- running natctl in two places at once is redundant, and (once leader_election.enabled) this host would need its own NATCTL_SELF_NODE_ID/NATCTL_SELF_LINODE_ID identity to participate safely, which this module does not set up. See docs/RUNBOOK.md's natctl-on-node section."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# v6: monitoring-stack opt-out -- if your organization already runs
# Prometheus/Grafana (or a Prometheus-remote-write-compatible backend like
# Grafana Cloud, Mimir, Thanos Receive, VictoriaMetrics), you don't need
# this project to stand up a second one. See docs/OBSERVABILITY.md
# "Bring your own monitoring".
# ---------------------------------------------------------------------------

variable "run_monitoring_stack" {
  description = "Whether THIS instance provisions its own Prometheus/Grafana/Alertmanager (via Docker Compose) at all. Default true preserves the original behavior. Set to false to skip all three entirely -- e.g. when you already have monitoring and just want your own Prometheus (or equivalent) to scrape LNG's exporters directly (see nat_exporter's :9200/metrics and natctl's GET /file_sd for target discovery) or receive prometheus_remote_write_url pushes from elsewhere. If both run_natctl and run_monitoring_stack are false, this whole instance has nothing left to do -- omit the module call entirely instead (see terraform/environments/example/main.tf's create_observability_instance local)."
  type        = bool
  default     = true
}

variable "prometheus_remote_write_url" {
  description = "If set (and run_monitoring_stack is true), this instance's own Prometheus additionally pushes every scraped sample to this URL via remote_write -- the mechanism for the \"give us an endpoint to push our observability data to\" case: point this at your existing Grafana Cloud / Mimir / Thanos Receive / VictoriaMetrics endpoint and this Prometheus becomes a local scrape-and-forward agent instead of (or in addition to) a standalone dashboarded instance. Left empty (default), Prometheus only serves its own local :9090/Grafana, exactly as before this variable existed. Basic-auth credentials, if the receiver needs them, go in prometheus_remote_write_username/password below -- kept separate so this URL itself can stay a non-sensitive value in your tfvars."
  type        = string
  default     = ""
}

variable "prometheus_remote_write_username" {
  description = "Basic-auth username for prometheus_remote_write_url, if your receiver requires it. Empty means no auth header is sent."
  type        = string
  default     = ""
}

variable "prometheus_remote_write_password" {
  description = "Basic-auth password for prometheus_remote_write_url, if your receiver requires it."
  type        = string
  sensitive   = true
  default     = ""
}

variable "natctl_file_urls" {
  description = "Map of natctl/*.py filename -> public URL (terraform/modules/artifacts' natctl_file_urls output), fetched one curl per file at boot instead of embedded inline -- only actually consumed when run_natctl is true. See that module's main.tf header for why (Linode's 16384-byte decoded cloud-init limit -- this alone, even without exporter.py/buddy_sync.py which this instance never installs, was already enough to push this instance's cloud-init over budget once combined with the dashboards/alerts JSON this file also carries)."
  type        = map(string)
  default     = {}
}

variable "natctl_service_url" {
  description = "Public URL (terraform/modules/artifacts' natctl_service_url output) fetched at boot instead of embedded inline -- v10, kept in sync with terraform/modules/nat-fleet's equivalent variable. Only actually consumed when run_natctl is true."
  type        = string
  default     = ""
}

variable "natctl_requirements_txt_url" {
  description = "Public URL (terraform/modules/artifacts' natctl_requirements_txt_url output) fetched at boot instead of embedded inline -- v10, kept in sync with terraform/modules/nat-fleet's equivalent variable. Only actually consumed when run_natctl is true."
  type        = string
  default     = ""
}

# v21: "source" (default) or "binary" -- kept in sync with
# terraform/modules/nat-fleet's equivalent variable, see its v21 comment
# and docs/PUBLISHING.md.
variable "agent_distribution" {
  description = "\"source\" (default) or \"binary\" -- see terraform/modules/nat-fleet/variables.tf's matching v21 comment."
  type        = string
  default     = "source"
}

variable "natctl_bin_url" {
  description = "Public URL of a pre-compiled natctl binary, used instead of natctl_file_urls/natctl_requirements_txt_url when agent_distribution is \"binary\" and run_natctl. Cheap to leave empty otherwise."
  type        = string
  default     = ""
}

variable "nat_overview_json_url" {
  description = "Public URL (terraform/modules/artifacts' nat_overview_json_url output) for dashboards/nat-overview.json, fetched at boot instead of embedded inline -- v15. Only actually consumed when run_monitoring_stack is true. Fetching this instead of embedding it means editing the dashboard JSON no longer forces this instance to be replaced on the next apply (user_data changes are ForceNew; a fetched-at-boot URL reference is a few dozen stable bytes regardless of the target content)."
  type        = string
  default     = ""
}

# BUG FIX (found live, 2026-08-29, roadmap/M4-autoscaling.md): this module
# never accepted Object Storage credentials at all, so in the default
# single-dedicated-host layout (run_natctl=true, natctl_on_node_enabled=
# false) natctl's FleetController.object_storage_access_key/secret_key
# resolved to empty strings -- main.py's build_controllers() sources them
# via LeaderElectionConfig.resolved_access_key()/resolved_secret_key(),
# which falls back to NATCTL_OBJECT_STORAGE_ACCESS_KEY/SECRET_KEY in
# /etc/natctl/env, but this instance's own cloud-init (unlike
# ansible/cloud-init/nat-node.yaml.tftpl's, used only when
# natctl_on_node_enabled=true) never wrote that file. Confirmed live: every
# elastic-node provision attempt failed with a real S3 PutObject 400 (empty/
# invalid credentials) while trying to upload the new node's nftables.conf
# -- autoscaling's actual provisioning step has likely never worked via the
# default deployment mode. These credentials are ALWAYS needed here when
# run_natctl is true (every pool's elastic-node uploads use them,
# regardless of leader_election/natctl_on_node_enabled), unlike
# leader_election's own object storage fields which are genuinely optional.
variable "object_storage_access_key" {
  description = "Object Storage access key natctl uses to upload each elastic node's own rendered nftables.conf/artifacts (fleet.py's _provision() -> object_storage.py's upload_public_object()) -- required whenever run_natctl is true, independent of leader_election. Written to /etc/natctl/env (0600), never into natctl_config_yaml itself."
  type        = string
  sensitive   = true
  default     = ""
}

variable "object_storage_secret_key" {
  description = "Object Storage secret key, paired with object_storage_access_key above."
  type        = string
  sensitive   = true
  default     = ""
}
