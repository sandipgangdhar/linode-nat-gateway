# 🧭 Linode NAT Gateway (High Availability)

<p align="center">
  <img src="https://raw.githubusercontent.com/sandipgangdhar/linode-nat-gateway/feature/nat-gateway/docs/images/linode-nat-banner.png" alt="Linode NAT Gateway Banner" width="100%">
</p>

![Terraform](https://img.shields.io/badge/Terraform-v1.5%2B-purple?logo=terraform)
![Ansible](https://img.shields.io/badge/Ansible-2.14%2B-red?logo=ansible)
![Linux](https://img.shields.io/badge/Linux-Ubuntu%2024.04-informational?logo=linux)
![Status](https://img.shields.io/badge/Status-Active%20Development-yellow)
![License](https://img.shields.io/badge/License-MIT-blue)

A fully automated, production-grade **High-Availability NAT Gateway** for **Akamai Connected Cloud (Linode)** — built using **Terraform**, **Ansible**, **Keepalived (VRRP)**, **lelastic (BGP route propagation)**, and **nftables**.  

This setup provides **automatic failover**, **stateful NAT**, and **shared public IP resiliency** across multiple Linode instances — matching or exceeding cloud-native NAT solutions from AWS, Azure, and GCP.

---

## 🧾 Table of Contents
- [📚 Documentation Index](#-documentation-index)
- [🚀 Quick Summary](#-quick-summary)
- [🏗️ Quick Deployment](#-quick-deployment)
- [📊 Current Milestone Progress](#-current-milestone-progress)
- [🧠 Highlights](#-highlights)
- [👨‍💻 Author & Maintainer](#-author--maintainer)

---
## 📚 Documentation Index

| Section | Description |
|----------|--------------|
| [1️⃣ Introduction / Overview](https://github.com/sandipgangdhar/linode-nat-gateway/blob/feature/nat-gateway/docs/introduction.md) | What this solution does and its core design principles |
| [2️⃣ Features & Advantages](https://github.com/sandipgangdhar/linode-nat-gateway/blob/feature/nat-gateway/docs/features-and-advantages.md) | Key highlights, unique advantages, and architectural value |
| [3️⃣ Architecture Overview Diagram](https://github.com/sandipgangdhar/linode-nat-gateway/blob/feature/nat-gateway/docs/architecture.md) | Complete topology, packet flow, and logical architecture |
| [4️⃣ Detailed Component Responsibilities](https://github.com/sandipgangdhar/linode-nat-gateway/blob/feature/nat-gateway/docs/components.md) | Role of Keepalived, lelastic, nftables, and Linode IP Sharing |
| [5️⃣ Component Interactions](https://github.com/sandipgangdhar/linode-nat-gateway/blob/feature/nat-gateway/docs/interactions.md) | Flow of control and communication between components |
| [6️⃣ Failure Scenarios & Recovery Behavior](https://github.com/sandipgangdhar/linode-nat-gateway/blob/feature/nat-gateway/docs/failures.md) | Complete fault-injection and recovery matrix |
| [7️⃣ Comparison with Cloud NAT Solutions](https://github.com/sandipgangdhar/linode-nat-gateway/blob/feature/nat-gateway/docs/comparison.md) | AWS, Azure, and GCP NAT comparisons |
| [8️⃣ Deployment Guide / Setup Instructions](https://github.com/sandipgangdhar/linode-nat-gateway/blob/feature/nat-gateway/docs/deployment.md) | Terraform + Ansible step-by-step setup |
| [9️⃣ Performance Benchmark & Test Results](https://github.com/sandipgangdhar/linode-nat-gateway/blob/feature/nat-gateway/docs/performance.md) | Latency, throughput, and failover timing |
| [🔟 Repository Structure](https://github.com/sandipgangdhar/linode-nat-gateway/blob/feature/nat-gateway/docs/repository.md) | Directory layout and contents summary |
| [🏷️ License / Author / Contributions](https://github.com/sandipgangdhar/linode-nat-gateway/blob/feature/nat-gateway/docs/license.md) | Author credits and contribution info |
---

## 🚀 Quick Summary

This solution delivers **active-passive NAT High Availability** using open-source components and Linode native primitives:

| Component | Purpose |
|------------|----------|
| **Keepalived (VRRP)** | Manages floating VIPs and automatic role transition (MASTER ↔ BACKUP). |
| **nftables** | Provides NAT (SNAT) and packet-filtering logic. |
| **lelastic** | Handles dynamic BGP route advertisement for FIP continuity during failover. |
| **Linode IP Sharing** | Enables shared public IP (FIP) between nodes within the same region. |
| **Ansible + Terraform** | End-to-end infrastructure provisioning and configuration automation. |

✨ **Outcome:** Seamless failover between two NAT nodes with near-zero packet loss for long-lived TCP flows, full observability, and linear scalability (add more NAT pairs if required).

---

## 🏗️ Quick Deployment

```console
# 1️⃣ Clone and switch to the feature branch
git clone https://github.com/sandipgangdhar/linode-nat-gateway.git
cd linode-nat-gateway
git checkout feature/nat-gateway

# 2️⃣ Create and edit terraform.tfvars
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Open terraform.tfvars and set your preferred region, VLAN label, etc.

# 3️⃣ Export your Linode API token
# Terraform expects TF_VAR_ prefix to automatically populate the input variable
export TF_VAR_linode_token=<YOUR_LINODE_API_TOKEN>

# 4️⃣ Deploy the infrastructure using Terraform
cd terraform
terraform init
terraform apply -auto-approve

# 5️⃣ Configure High Availability NAT
cd ../ansible
ansible-playbook -i inventory.ini site.yml

# 6️⃣ Validate deployment and failover
ansible-playbook -i inventory.ini site.yml -t validate
```

---

## 📊 Current Milestone Progress

| Milestone | Description | Status |
|------------|--------------|--------|
| 1️⃣ **Terraform Infrastructure Provisioning** | Core Linodes, VLAN, and FIP setup | ✅ Completed |
| 2️⃣ **Ansible Configuration Automation** | Keepalived, nftables, lelastic | ✅ Completed |
| 3️⃣ **HA Hardening & Observability** | Monitoring, metrics, and alerting | 🔄 In Progress |
| 4️⃣ **Auto-Recovery & Event Hooks** | Failover detection and route healing | ⏳ Planned |
| 5️⃣ **Scenario Testing & Benchmarking** | Validation matrix and performance tests | ⏳ Upcoming |

---

## 🧠 Highlights

- 🔄 **Automatic VRRP failover** between dual NAT nodes  
- 🧱 **Stateless design**, no persistent storage dependency  
- 💡 **Terraform + Ansible unified workflow**  
- 🔍 **Built-in validation tests** (services, routes, SNAT, VIP checks)  
- 🌐 **Multi-pair scaling** via independent NAT clusters  
- 📈 **Cloud-agnostic** logic easily portable to other providers  

---

## 👨‍💻 Author & Maintainer

**Sandip Gangdhar**  
Senior Enterprise Cloud Consultant / Solution Architect  
**Akamai Connected Cloud (Linode)**  

🔗 [LinkedIn Profile](https://linkedin.com/in/ssandippggangdhar)  
📦 GitHub: [sandipgangdhar/linode-nat-gateway](https://github.com/sandipgangdhar/linode-nat-gateway)

---

> 🧡 Built for real-world enterprise workloads on **Akamai Connected Cloud**,  
> ensuring simplicity, openness, and cost-optimized resilience.
