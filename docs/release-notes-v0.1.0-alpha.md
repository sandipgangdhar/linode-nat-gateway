# 🚀 Linode NAT Gateway (High Availability) — v0.1.0-alpha

The **first functional release** of the production-grade, **Terraform + Ansible–driven High Availability NAT Gateway** for **Akamai Connected Cloud (Linode)**.

This release introduces a dual-node VRRP-based NAT gateway supporting **automated failover**, **stateful SNAT**, and **dynamic route propagation** using Linode’s native BGP stack (`lelastic`).

---

### ✨ Highlights

- ⚙️ Fully automated setup — Terraform + Ansible end-to-end
- 🔄 Instant VRRP failover between active/standby nodes
- 🌐 Stateful NAT powered by nftables
- 📡 Dynamic BGP propagation via lelastic
- 🧱 Private VLAN ready — compatible with Linode VPC/VLAN networking
- 🧩 Modular design for multi-pair scaling
- ✅ Built-in Ansible validation for health and routing checks

---

### 🧪 Validation Summary

✅ Terraform infrastructure provisioning  
✅ Ansible configuration and service setup  
✅ Keepalived failover (VIP & FIP transition verified)  
✅ SNAT rule validation and internet access test  
✅ BGP advertisement check (lelastic peer up)  

---

### 📘 Documentation
📂 [Project Documentation (docs/)](https://github.com/sandipgangdhar/linode-nat-gateway/tree/main/docs)  
Includes architecture diagrams, failure scenarios, and deployment steps.

---

### 👨‍💻 Author

**Sandip Gangdhar**  
Senior Enterprise Cloud Consultant / Solution Architect  
**Akamai Connected Cloud (Linode)**  

🔗 [LinkedIn](https://linkedin.com/in/ssandippggangdhar)  
📦 [GitHub](https://github.com/sandipgangdhar)

---

### 🏷️ Release Info
- **Tag:** `v0.1.0-alpha`
- **Branch:** `main`
- **Date:** November 2025
- **Status:** Alpha (Milestones 1 & 2 Completed)
