# 📁 Repository Structure

This document provides a high-level overview of the directory layout and contents of the **Linode NAT Gateway (HA)** repository.  
It explains what each folder and key file does — helping contributors, reviewers, and users quickly understand how the project is organized.

---

## 🏗️ Folder Overview

```bash
linode-nat-gateway/
├── ansible/                # Automation role for configuring HA NAT stack
│   ├── roles/              # nat_ha role (tasks, templates, handlers)
│   ├── group_vars/         # Environment variables and host mappings
│   ├── site.yml            # Main playbook (validation + setup)
│   └── inventory.ini       # Host inventory (nat-a, nat-b definitions)
│
├── terraform/              # Infrastructure provisioning layer
│   ├── main.tf             # Defines Linode instances, VLAN, and FIP
│   ├── variables.tf        # Input variable definitions
│   ├── outputs.tf          # Public/Private IPs, VLAN IDs, etc.
│   ├── provider.tf         # Linode provider setup
│   ├── versions.tf         # Terraform version constraints
│   └── terraform.tfvars.example  # Example values (never commit secrets)
│
├── docs/                   # Documentation (Markdown files)
│   ├── architecture.md     # Detailed system and packet flow design
│   ├── comparison.md       # Linode vs AWS/GCP/Azure NAT comparison
│   ├── deployment.md       # Full Terraform + Ansible deployment guide
│   ├── performance.md      # Latency and failover benchmark results
│   ├── repository.md       # (this file) Repo structure documentation
│   └── license.md          # License and author info (auto-generated later)
│
├── scripts/                # Optional helper utilities and shell scripts
│
├── Makefile                # Optional helper for quick operations (apply/validate/destroy)
│
├── README.md               # Root index with navigation links
│
└── .gitignore              # Excludes sensitive or auto-generated files
```

---

## 🧩 Component Mapping

| Layer | Folder | Key Role |
|-------|---------|----------|
| **Provisioning** | `terraform/` | Creates Linodes, VLAN, shared IPs |
| **Configuration** | `ansible/` | Installs nftables, keepalived, lelastic |
| **Documentation** | `docs/` | Architecture, deployment, benchmarks |
| **Automation Helpers** | `scripts/`, `Makefile` | Optional testing and tooling |
| **Entry Point** | `README.md` | Central index linking all docs |

---

## 🧰 Key Files Explained

| File | Purpose |
|------|----------|
| **ansible/site.yml** | Orchestrates NAT-HA setup, validation, and health checks |
| **ansible/roles/nat_ha/tasks/main.yml** | Core configuration logic |
| **ansible/roles/nat_ha/templates/** | Jinja2 templates for `keepalived.conf`, `nat.nft`, and `notify.sh` |
| **terraform/main.tf** | Defines Linode VMs and networking resources |
| **terraform/variables.tf** | Lists customizable parameters (region, VLAN CIDR, etc.) |
| **terraform/outputs.tf** | Prints public/private IPs after apply |
| **terraform/terraform.tfvars.example** | Safe variable example for new deployments |
| **Makefile** | Simplifies lifecycle operations: `make apply`, `make validate`, etc. |
| **README.md** | Provides project overview and navigation |
| **docs/** | Contains modular markdown files for each documentation section |

---

## 🔐 Git Hygiene Guidelines

- ✅ **Never commit secrets** (e.g., API tokens, SSH keys, passwords).  
- 🧱 Use `.gitignore` to exclude sensitive or auto-generated files:
  ```
  terraform/.terraform/
  terraform/terraform.tfstate*
  terraform/terraform.tfvars
  ansible/*.retry
  *.log
  ```
- 🪶 Maintain all documentation updates under `docs/` rather than editing `README.md` directly.  
- 💡 Create branches per milestone or feature (`feature/nat-gateway`, `feature/monitoring`, etc.).  

---

## 🧭 How to Navigate the Project

| Purpose | Command | Where to Look |
|----------|----------|---------------|
| Deploy infrastructure | `cd terraform && terraform apply -auto-approve` | `terraform/` |
| Configure HA NAT | `ansible-playbook -i ansible/inventory.ini ansible/site.yml` | `ansible/` |
| Validate setup | `ansible-playbook -i ansible/inventory.ini ansible/site.yml -t validate` | `ansible/` |
| Review design | — | `docs/architecture.md` |
| Compare to AWS/GCP/Azure | — | `docs/comparison.md` |
| Check performance | — | `docs/performance.md` |

---

## 🧠 Recommended Branch Strategy

| Branch | Purpose |
|---------|----------|
| **main** | Stable release, production-ready code |
| **feature/nat-gateway** | Active development branch |
| **feature/monitoring** | Future metrics + Prometheus integration |
| **feature/failover-tests** | Scenario testing scripts |
| **docs/** | Optional documentation improvements |

---

## ✅ Summary

This structure ensures:
- Clean separation between **infrastructure**, **configuration**, and **documentation**.  
- Easy collaboration between **DevOps**, **Network**, and **Documentation** teams.  
- Simplified automation using Terraform + Ansible + Makefile.

---

Next doc 👉 [License / Author / Contributions](https://github.com/sandipgangdhar/linode-nat-gateway/blob/feature/nat-gateway/docs/license.md)
