# ⚙️ Deployment Guide / Setup Instructions

This document explains the **end-to-end deployment process** for the Linode NAT Gateway (High Availability) solution — from Terraform provisioning to Ansible configuration and validation.  
It’s fully reproducible and designed to be executed in any environment where the Linode API token is available.

---

## 🧭 Prerequisites

Before deploying, ensure you have the following tools and access configured:

| Tool | Version | Purpose |
|-------|----------|----------|
| **Terraform** | ≥ 1.6.x | Infrastructure provisioning |
| **Ansible** | ≥ 2.15.x | Configuration management |
| **linode-cli** | Latest | Optional manual checks |
| **SSH keypair** | RSA / ED25519 | Used for node authentication |
| **Git** | Latest | For cloning and version control |

---

### 🔑 Environment Setup

1. Export your Linode API token:
   ```bash
   export LINODE_TOKEN="your-token-here"
   ```

2. (Optional) Verify access:
   ```bash
   linode-cli account view
   ```

3. Clone the repo and switch to the feature branch:
   ```bash
   git clone https://github.com/sandipgangdhar/linode-nat-gateway.git
   cd linode-nat-gateway
   git checkout feature/nat-gateway
   ```

---

## 🧱 Step 1: Terraform Infrastructure Deployment

Terraform provisions the base infrastructure:
- 2 × Linode VMs (`nat-a`, `nat-b`)
- Shared Public IP (FIP) for IP Sharing
- VLAN interface for private subnet
- Required security groups and SSH access

### ⚙️ Configure Variables

Edit `terraform/terraform.tfvars` and set values:
```hcl
region            = "ap-west"
root_pass         = "StrongPassword!"
ssh_authorized_keys = ["ssh-ed25519 AAAA..."]
vlan_label        = "vlan-nat"
vlan_subnet       = "192.168.1.0/24"
public_fip        = "172.236.95.221"
```

> ⚠️ Do **not** commit `terraform.tfvars` with your actual SSH keys or tokens — instead use `terraform.tfvars.example` as a template.

---

### 🚀 Deploy the Infrastructure

```bash
cd terraform
terraform init
terraform plan
terraform apply -auto-approve
```

Terraform output will provide:
- Node IPs (public and private)
- VLAN subnet
- FIP details

> Copy these IPs into the **Ansible inventory file** for the next step.

---

## 🧩 Step 2: Ansible Configuration

Once the Linodes are provisioned, configure HA NAT stack using:

```bash
cd ../ansible
ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -i inventory.ini site.yml
```

### 📋 Inventory Example (`inventory.ini`)

```ini
[nat]
nat-a ansible_host=172.235.5.178 pub_if=eth0 vlan_if=eth1 vlan_vip=192.168.1.1 fip_ip=172.236.95.221 priority=150
nat-b ansible_host=172.232.104.118 pub_if=eth0 vlan_if=eth1 vlan_vip=192.168.1.1 fip_ip=172.236.95.221 priority=100
```

### 🧰 What Ansible Does

1. Installs base packages (`nftables`, `keepalived`, `lelastic`).  
2. Configures `/etc/nftables.d/nat-natgw.nft` for SNAT.  
3. Deploys `/usr/local/sbin/keepalived-notify.sh` for IP handover.  
4. Applies `/etc/keepalived/keepalived.conf` for VRRP.  
5. Starts and enables services.  
6. Runs **validation tasks** automatically.

---

## ✅ Step 3: Validation and Health Check

After deployment, validation runs automatically and prints a summary like this:

```
Host: nat-a
Services active (nftables, keepalived, lelastic): OK
VIP on MASTER: OK
VIP absent on BACKUP: OK
SNAT rule present: OK
Egress via FIP (MASTER only): OK
BGP (lelastic) healthy: OK
✅ nat-a: NAT-HA validation PASSED
```

If any item fails, Ansible will indicate `❌ validation FAILED` for that node.

### Manual Health Verification

| Check | Command | Expected Output |
|--------|----------|----------------|
| VRRP state | `systemctl status keepalived` | MASTER on one node, BACKUP on other |
| FIP presence | `ip addr show eth0 | grep 172.` | Present only on MASTER |
| SNAT rule | `nft list chain ip nat POSTROUTING` | Rule with `snat to FIP` |
| Connectivity | `curl -4 ifconfig.me` | Returns shared FIP |
| BGP | `systemctl status lelastic` | Running, peers established |

---

## 🔁 Step 4: Failover Testing (Optional)

You can simulate failure scenarios:

| Action | Command | Expected Behavior |
|--------|----------|------------------|
| Stop Keepalived on MASTER | `systemctl stop keepalived` | BACKUP becomes MASTER |
| Bring public IF down | `ip link set eth0 down` | FIP moves to BACKUP |
| Reboot MASTER | `reboot` | BACKUP continues serving NAT |
| Resume MASTER | `systemctl start keepalived` | Returns to BACKUP |

After each test, re-run:
```bash
ansible-playbook -i inventory.ini site.yml -t validate
```

---

## 🧹 Step 5: Teardown

To remove everything cleanly:

```bash
cd terraform
terraform destroy -auto-approve
```

This will delete both Linodes, VLAN, and IP assignments.

---

## 🧠 Automation via Makefile (Optional)

You can simplify operations using a top-level `Makefile`:

```makefile
apply:
	cd terraform && terraform apply -auto-approve
	ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -i ansible/inventory.ini ansible/site.yml

validate:
	ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -i ansible/inventory.ini ansible/site.yml -t validate

destroy:
	cd terraform && terraform destroy -auto-approve

failover-test:
	ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -i ansible/inventory.ini ansible/site.yml -t failover
```

Usage:
```bash
make apply
make validate
make destroy
```

---

## 📁 Deployment Files Summary

| File | Purpose |
|------|----------|
| `terraform/main.tf` | Core infrastructure resources |
| `terraform/variables.tf` | Parameter definitions |
| `terraform/outputs.tf` | Public/private IPs and VLAN IDs |
| `ansible/site.yml` | Main automation playbook |
| `ansible/inventory.ini` | Node definitions |
| `ansible/roles/nat_ha` | Tasks, templates, handlers for NAT setup |
| `scripts/` | Utility shell scripts (optional future automation) |

---

## ✅ End State

After successful deployment:
- `nat-a` → MASTER, owns VIP `192.168.1.1` and FIP `172.236.95.221`
- `nat-b` → BACKUP, monitors VRRP
- Private instances use `192.168.1.1` as default gateway
- Internet access and failover are fully functional

---

Next doc 👉 [Performance Benchmark & Test Results](https://github.com/sandipgangdhar/linode-nat-gateway/blob/feature/nat-gateway/docs/performance.md)
