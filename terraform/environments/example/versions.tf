# versions.tf (terraform/environments/example)
#
# Pins the Terraform CLI and Linode provider versions this example
# environment is tested against, and configures the Linode provider with
# the API token decrypted from secrets.enc.json (see local.linode_token
# in main.tf).
#
# -----------------------------------------------------
# Usage:
#
# - Terraform >= 1.6 required.
# - linode/linode provider ~> 2.9 -- do not jump a major version without
#   re-testing every module, since resource schemas can change.
# - hashicorp/random ~> 3.6 -- already a transitive dependency via
#   module.vpc's random_id.fw_suffix; declared here too because this
#   root module now generates its own random_password.
#   natctl_api_mutation_token directly -- see environments/example/
#   main.tf's matching resource comment.
# - carlpett/sops ~> 1.0 -- reads secrets.enc.json (SOPS + age
#   encrypted, safe to commit) directly into Terraform at plan/apply
#   time, decrypted in-memory only -- never written to a plaintext file
#   on disk. See locals.secrets in main.tf and
#   docs/NAT-GATEWAY-DEFINITIVE-GUIDE.html, Part VIII 8.3 for the full
#   workflow.
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
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    sops = {
      source  = "carlpett/sops"
      version = "~> 1.0"
    }
  }
}

provider "linode" {
  token = local.linode_token
}
