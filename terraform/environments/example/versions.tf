# versions.tf (terraform/environments/example)
#
# Pins the Terraform CLI and Linode provider versions this example
# environment is tested against, and configures the Linode provider with
# the API token supplied via var.linode_token.
#
# -----------------------------------------------------
# Usage:
#
# - Terraform >= 1.6 required.
# - linode/linode provider ~> 2.9 -- do not jump a major version without
#   re-testing every module, since resource schemas can change.
#
# -----------------------------------------------------
# Author:
# - Sandip Gangdhar
# - GitHub: https://github.com/sandipgangdhar
#
# (c) Linode-NAT-Gateway (LNG) | Developed by Sandip Gangdhar | 2026
# -----------------------------------------------------

terraform {
  required_version = ">= 1.6"

  required_providers {
    linode = {
      source  = "linode/linode"
      version = "~> 2.9"
    }
  }
}

provider "linode" {
  token = var.linode_token
}
