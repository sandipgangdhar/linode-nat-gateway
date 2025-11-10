# ⚙️ Client Configuration Guide — Dual NAT Gateway (ECMP Mode)
> Version 1.0 | Last Updated: Nov 2025 | Author: Sandip Gangdhar

<details>
<summary><b>Click to expand full client configuration (all commands + troubleshooting)</b></summary>

```bash
################################################################################
# 🧩 Step 1 — Replace Default Route (Enable ECMP)
################################################################################
# Replaces the default route with two equal-cost next hops so that outbound
# traffic is distributed between NAT1 (192.168.1.1) and NAT2 (192.168.1.10).
# Using "replace" ensures the existing SSH session stays intact.
sudo ip route replace default scope global \
  nexthop via 192.168.1.1  dev eth1 weight 1 \
  nexthop via 192.168.1.10 dev eth1 weight 1


################################################################################
# ⚙️ Step 2 — Enable ECMP Hashing and Loose Reverse Path Filter
################################################################################
# fib_multipath_hash_policy = 1 → Enables L4 hashing (per-flow load balancing)
# rp_filter = 2 → Enables loose mode for asymmetric return paths
echo 1 | sudo tee /proc/sys/net/ipv4/fib_multipath_hash_policy
sudo sysctl -w net.ipv4.conf.all.rp_filter=2
sudo sysctl -w net.ipv4.conf.eth1.rp_filter=2


################################################################################
# 🧱 Step 3 — Persist Settings Across Reboots
################################################################################
# (a) Persist sysctl parameters
sudo tee /etc/sysctl.d/99-ecmp.conf >/dev/null <<'EOF'
net.ipv4.fib_multipath_hash_policy = 1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.eth1.rp_filter = 2
EOF
sudo sysctl --system

# (b) Persist ECMP route via systemd
sudo tee /etc/systemd/system/ecmp-route.service >/dev/null <<'EOF'
[Unit]
Description=Apply ECMP default route
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/sbin/ip route replace default scope global \
  nexthop via 192.168.1.1  dev eth1 weight 1 \
  nexthop via 192.168.1.10 dev eth1 weight 1
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl enable ecmp-route.service


################################################################################
# 🔍 Step 4 — Validate Load Balancing
################################################################################
# Sends 10 requests to https://api.ipify.org to verify alternating NAT IPs.
# Expected output alternates between 172.236.95.221 and 172.236.95.99.
for i in {1..10}; do curl -s https://api.ipify.org; echo; done


################################################################################
# 🧭 Reference Summary
################################################################################
# Component     Setting               Purpose
# ------------  --------------------  ------------------------------------------
# Default route  ECMP                 Split outbound traffic across both NATs
# Hash policy   1 (L3+L4)             Per-flow balancing
# RP filter     Loose (2)             Allow asymmetric return paths
# Systemd unit  ecmp-route.service   Restore routes on boot


################################################################################
# 📘 Example Topology
################################################################################
# +-----------------------+
# | Private Host (eth1)  |
# | 192.168.1.20        |
# | Default route → ECMP |
# | via 192.168.1.1/10  |
# +-----------+-----------+
#             |
#    VLAN 192.168.1.0/24
#             |
# +-----------+-----------+
# | NAT1 → 172.236.95.221 |
# | NAT2 → 172.236.95.99  |
# +------------------------+


################################################################################
# 🧰 Step 5 — Verification & Troubleshooting
################################################################################
# 🟢 Check current routes
ip route show default
ip route show table main | grep default

# 🟢 Verify ECMP hash policy and rp_filter settings
sysctl net.ipv4.fib_multipath_hash_policy
sysctl net.ipv4.conf.all.rp_filter
sysctl net.ipv4.conf.eth1.rp_filter

# 🟢 Confirm per-flow NAT distribution
for i in {1..20}; do curl -s https://api.ipify.org; echo; done

# 🟢 Trace a specific route selection
ip route get 8.8.8.8

# 🟢 Inspect NAT connection tracking table (requires root)
sudo conntrack -L | grep -E 'dport=80|dport=443' | head

# 🟢 Restart ECMP route service if changes applied
sudo systemctl restart ecmp-route.service
sudo systemctl status ecmp-route.service

</details>
```
