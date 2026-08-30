# outputs.tf (terraform/modules/observability)
#
# Endpoints for the control-plane instance this module creates.
#
# -----------------------------------------------------
# Outputs:
#
# 1) public_ip      - The observability instance's public IP.
# 2) private_ip      - Its pinned VPC IP -- feed into client-agent's
#                       NATCTL_ROSTER_URL and each nat-fleet pool's
#                       natctl_roster_url.
# 3) grafana_url      - http://<public_ip>:3000
# 4) prometheus_url   - http://<public_ip>:9090
#
# -----------------------------------------------------
# Author:
# - Sandip Gangdhar
# - GitHub: https://github.com/sandipgangdhar
#
# (c) Linode-NAT-Gateway (LNG) | Developed by Sandip Gangdhar | 2026
# -----------------------------------------------------

locals {
  # v9: linode_instance's own `ip_address` attribute is deprecated by the
  # Terraform Linode provider (confirmed via the provider's own deprecation
  # warning on a live `terraform apply` -- "Refer to the provider
  # documentation for details") in favor of `ipv4`, a list of this
  # instance's public IPv4 addresses. tolist()/index 0 gets the same
  # single-string value ip_address used to provide -- this instance only
  # ever has one public interface (see main.tf's linode_instance.observability),
  # so index 0 is always the right (and only) address.
  public_ip = tolist(linode_instance.observability.ipv4)[0]
}

output "public_ip" {
  value = local.public_ip
}

output "private_ip" {
  description = "Point client-agent's NATCTL_ROSTER_URL at this (see terraform/environments/example/outputs.tf)."
  value       = var.private_ip
}

output "grafana_url" {
  value = "http://${local.public_ip}:3000"
}

output "prometheus_url" {
  value = "http://${local.public_ip}:9090"
}
