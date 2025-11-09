# 🧩 Detailed Component Responsibilities

This document provides an in-depth explanation of each building block within the **Linode NAT Gateway (High Availability)** architecture — focusing on how every component contributes to **resiliency, scalability, and automation**.

---

## 🏗️ 1. Keepalived (VRRP-Based Failover)

**Purpose:**  
Keepalived is the heart of the **failover mechanism**. It uses the **Virtual Router Redundancy Protocol (VRRP)** to determine which node in the NAT pair acts as **MASTER** (active) and which acts as **BACKUP** (standby).

### 🔧 Responsibilities
- Manages the **floating VIP** that represents the shared gateway IP (192.168.1.1 or similar).
- Performs **VRRP heartbeats** over the VLAN/private network.
- Executes `/usr/local/sbin/keepalived-notify.sh` when state changes occur (MASTER → BACKUP → FAULT).
- Ensures **zero manual intervention** during a failover event.
- Logs all transitions for audit and observability.

### ⚙️ Configuration Highlights
- Configured with `vrrp_instance` blocks that define:
  - `state` (MASTER or BACKUP)
  - `priority` (higher = preferred master)
  - `virtual_router_id` (unique per cluster)
- `notify` script handles:
  - Adding/removing the floating IP.
  - Triggering route updates.
  - Restarting dependent services (like `lelastic`).

### 🧠 Key Design Point
Keepalived alone ensures **local failover**; it does **not** automatically propagate routing updates beyond the node.  
That’s where **lelastic** complements it by handling the **BGP advertisement** of the floating IP.

---

## 🌐 2. lelastic (BGP Route Propagation)

**Purpose:**  
`lelastic` (short for *Linode Elastic IP Manager*) is an open-source utility provided by Akamai/Linode to integrate **Linode IP Sharing** with **BGP route propagation** inside private setups.

### 🔧 Responsibilities
- Advertises the **Floating IP (FIP)** route via **BGP**.
- Ensures that the FIP is reachable externally **only from the active MASTER node**.
- Removes BGP advertisements when the node transitions to BACKUP or FAULT.
- Acts as the control plane between **Linode’s IP Sharing mechanism** and **local routing tables**.

### ⚙️ Configuration Highlights
- Installed as a **systemd service** (`lelastic.service`).
- Reads config from `/etc/default/lelastic` and `/etc/lelastic.conf`.
- Runs continuously and listens for **Keepalived notify triggers** to switch routes.
- Implements retry logic for BGP reconnection after failover.

### 🧠 Key Design Point
`lelastic` ensures **internet-level continuity** for outbound traffic.  
Without it, traffic would SNAT from the FIP but not be routed properly across the Linode network during failover.

---

## 🔥 3. nftables (NAT Engine)

**Purpose:**  
The **nftables** framework replaces `iptables` as the modern Linux packet filtering and NAT system.  
It handles the **source NAT (SNAT)** operation for all egress packets leaving the private subnet.

### 🔧 Responsibilities
- Translates private source addresses (`192.168.1.x`) to the **floating public IP (FIP)**.
- Defines postrouting rules to ensure egress packets use the correct interface (typically `eth0`).
- Handles **stateful connection tracking**, ensuring return packets follow the correct path.
- Supports fast failover because rules are **preloaded and identical** on both nodes.

### ⚙️ Example Rule
```bash
table ip nat {
  chain POSTROUTING {
    type nat hook postrouting priority srcnat;
    policy accept;
    ip saddr 192.168.1.0/24 oifname "eth0" snat to 172.236.X.X
  }
}
```

### 🧠 Key Design Point
Because nftables runs in kernel space, its **failover latency is near-zero**.  
As soon as the new MASTER assumes the FIP, packets begin egressing through it seamlessly.

---

## 🪄 4. Linode IP Sharing

**Purpose:**  
Linode’s native **IP Sharing** feature enables a **single public IPv4 address** (FIP) to be assigned to multiple Linode instances within the same region.

### 🔧 Responsibilities
- Provides the mechanism by which both NAT nodes share the same FIP.
- Automatically ensures that **only the active instance** routes inbound/outbound packets via that IP.
- Enables seamless **transition of public IP routing** when failover occurs.

### ⚙️ Behavior
- Configured via Linode Cloud Manager or API.
- Used in combination with `lelastic` for dynamic route updates.
- Requires that both Linodes reside in **the same region** (e.g., `ap-west`).

### 🧠 Key Design Point
This feature offloads the **public routing layer** from your infrastructure —  
allowing the HA pair to perform failover **without reconfiguring any upstream routes or DNS records**.

---

## 🤖 5. Automation Stack (Terraform + Ansible)

**Purpose:**  
The provisioning and configuration of this NAT HA solution are **fully automated** using **Terraform** (infrastructure as code) and **Ansible** (configuration management).

### 🧩 Terraform Responsibilities
- Creates both Linode instances (`nat-a` and `nat-b`).
- Attaches VLAN interfaces.
- Allocates and assigns the shared FIP (floating IP).
- Injects SSH keys and variables for Ansible.

### 🧩 Ansible Responsibilities
- Configures nftables, Keepalived, and lelastic.
- Deploys notify scripts and validation checks.
- Performs post-deployment verification:
  - Ensures VIP presence.
  - Confirms SNAT rule correctness.
  - Validates egress routing and health.

### 🧠 Key Design Point
This hybrid IaC approach ensures **repeatability**, **idempotence**, and **observability** —  
making the entire stack **self-healing** and easy to re-deploy in new regions.

---

## 🔍 6. Supporting Services and Scripts

| Component | Description |
|------------|--------------|
| `/usr/local/sbin/keepalived-notify.sh` | Executes custom logic on state changes (e.g., FIP attach/detach, route updates). |
| `/etc/nftables.d/nat.nft` | Contains NAT rules for outbound translation. |
| `/etc/systemd/system/lelastic.service` | Manages lelastic daemon lifecycle. |
| `/etc/keepalived/keepalived.conf` | Defines VRRP instance configuration and priorities. |
| `/etc/default/lelastic` | Environment file for lelastic runtime variables. |

---

## 🧠 Interdependency Summary

| Component | Depends On | Purpose |
|------------|-------------|----------|
| **Keepalived** | System network stack | Failover orchestration |
| **lelastic** | Keepalived state | BGP / FIP propagation |
| **nftables** | Network interfaces | Packet translation |
| **IP Sharing** | Linode Network | Shared routing backbone |
| **Ansible / Terraform** | Linode API + SSH | Deployment automation |

---

## 🏁 Summary

Together, these components deliver a **self-healing, high-availability NAT gateway** with:

- 💡 Automatic MASTER/BACKUP switching  
- 🔄 Instant FIP takeover without routing loss  
- 🔒 Stateful NAT persistence  
- ⚙️ Cloud-native automation and portability  

---

> **Next:** Continue to [🧩 Component Interactions](https://github.com/sandipgangdhar/linode-nat-gateway/blob/feature/nat-gateway/docs/interactions.md) to understand how all these layers interact during runtime.
