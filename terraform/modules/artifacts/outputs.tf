# outputs.tf (terraform/modules/artifacts) -- CUSTOMER-REPO BINARY VARIANT
#
# See main.tf's header comment for why exporter_py_url/buddy_sync_py_url/
# natctl_file_urls/natctl_requirements_txt_url below are harmless
# placeholders (nat-fleet/observability's variables.tf still require
# them, but agent_distribution = "binary" means nothing in the rendered
# cloud-init ever actually reads their values), and why
# natctl_service_url/nat_exporter_service_url/lng_buddy_sync_service_url
# are redirected to the binary-mode unit files rather than getting new
# output names.
#
# -----------------------------------------------------
# Author:
# - Sandip Gangdhar
# - GitHub: https://github.com/sandipgangdhar
#
# (c) Linode-NAT-Gateway (LNG) | Developed by Sandip Gangdhar | 2026
# -----------------------------------------------------

# Harmless placeholders -- see this file's header comment.
output "exporter_py_url" {
  description = "Unused placeholder in this repo (agent_distribution is always \"binary\") -- see main.tf's header comment."
  value       = ""
}

output "buddy_sync_py_url" {
  description = "Unused placeholder -- see exporter_py_url above."
  value       = ""
}

output "natctl_file_urls" {
  description = "Unused placeholder -- see exporter_py_url above."
  value       = {}
}

output "natctl_requirements_txt_url" {
  description = "Unused placeholder -- see exporter_py_url above."
  value       = ""
}

# The real, actually-consumed binary artifact URLs.
output "exporter_bin_url" {
  description = "Public URL for the compiled nat-exporter binary."
  value       = "${local.base_url}/${linode_object_storage_object.nat_exporter_bin.key}"
}

output "buddy_sync_bin_url" {
  description = "Public URL for the compiled buddy-sync binary."
  value       = "${local.base_url}/${linode_object_storage_object.buddy_sync_bin.key}"
}

output "natctl_bin_url" {
  description = "Public URL for the compiled natctl binary."
  value       = "${local.base_url}/${linode_object_storage_object.natctl_bin.key}"
}

output "client_agent_bin_url" {
  description = "Public URL for the compiled client-agent binary -- fetched ONCE by natctl itself at its own startup (ApiConfig.client_agent_bin_url), then served to client instances over VLAN/VPC via GET /agents/client-agent. Not fetched directly by client instances from Object Storage."
  value       = "${local.base_url}/${linode_object_storage_object.client_agent_bin.key}"
}

# Redirected to the binary-mode unit files -- see main.tf's header
# comment for why these keep the dev repo's "source" output names.
output "natctl_service_url" {
  description = "Public URL for the binary-mode natctl systemd unit."
  value       = "${local.base_url}/${linode_object_storage_object.natctl_service.key}"
}

output "nat_exporter_service_url" {
  description = "Public URL for the binary-mode nat-exporter systemd unit."
  value       = "${local.base_url}/${linode_object_storage_object.nat_exporter_service.key}"
}

output "lng_buddy_sync_service_url" {
  description = "Public URL for the binary-mode lng-buddy-sync systemd unit."
  value       = "${local.base_url}/${linode_object_storage_object.lng_buddy_sync_service.key}"
}

output "conntrackd_peer_service_url" {
  description = "Public URL for the conntrackd@.service TEMPLATE unit -- unchanged from the dev repo, not agent_distribution-specific (conntrackd itself is an apt package, not compiled)."
  value       = "${local.base_url}/${linode_object_storage_object.conntrackd_peer_service.key}"
}

output "nat_overview_json_url" {
  description = "Public URL for dashboards/nat-overview.json -- unchanged from the dev repo."
  value       = "${local.base_url}/${linode_object_storage_object.nat_overview_json.key}"
}
