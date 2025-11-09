# 📊 Performance Benchmark & Test Results

This document captures latency, throughput, and failover-timing results for the **Linode NAT Gateway (HA)** solution.  
It is a living benchmark that will evolve as additional validation scenarios are executed during **Milestone-5**.

---

## 🧭 Objective

To measure the **real-world performance** and **failover responsiveness** of the Linode NAT HA setup under production-like conditions:
- Outbound Internet latency and throughput from private subnets.  
- NAT gateway packet processing efficiency (nftables).  
- VRRP state-transition timing (keepalived).  
- BGP route-advertisement restoration (lelastic).  
- End-to-end connectivity recovery time after simulated failures.

---

## 🧩 Test Environment

| Parameter | Value |
|------------|--------|
| Region | `ap-west` |
| NAT Nodes | 2 × Linode (g6-standard-2) |
| Private Subnet | `192.168.1.0/24` |
| VLAN Interface | `eth1` |
| Public FIP | `172.236.95.221` |
| Tools Used | `ping`, `iperf3`, `curl`, `mtr`, `tcpdump`, `ansible validate` |
| Automation | Terraform + Ansible (feature/nat-gateway branch) |

---

## ⚙️ Benchmark Methodology

1. **Baseline Tests (No Failures)**  
   - Measure outbound latency (`ping 8.8.8.8`).  
   - Measure throughput using `iperf3` to public endpoint.  
   - Confirm egress NAT IP using `curl -4 ifconfig.me`.  

2. **Failover Tests**  
   - Stop `keepalived` on MASTER (`systemctl stop keepalived`).  
   - Record failover time until backup assumes FIP.  
   - Verify continued connectivity via ping + curl.  

3. **Recovery Tests**  
   - Restart MASTER (`systemctl start keepalived`).  
   - Measure re-synchronization latency and route re-advertisement.  

4. **Stress Tests**  
   - Generate sustained traffic via `iperf3 -t 300`.  
   - Observe CPU %, conntrack, and packet-drop counters.  

---

## 🧪 Planned Metrics

| Metric | Description | Tool | Target |
|---------|--------------|------|--------|
| **Baseline RTT** | Ping latency to Internet | `ping 8.8.8.8` | < 1 ms (intra-region) |
| **Throughput** | NAT egress bandwidth | `iperf3` | ≥ 2 Gbps |
| **Failover Time** | MASTER→BACKUP switchover | `journalctl`, `ping` | < 3 s |
| **Recovery Time** | BACKUP→MASTER restore | `journalctl`, `ping` | < 3 s |
| **Packet Loss Window** | Drops during failover | `ping` sequence | < 5 packets |
| **CPU Utilization** | NAT processing load | `top`, `sar` | < 30 % |
| **Memory Usage** | Keepalived + nftables | `free -m` | < 150 MB |
| **BGP Re-advertisement** | lelastic route re-add | `journalctl -u lelastic` | < 2 s |

---

## 📈 Sample (Placeholder) Results

| Test | Result | Notes |
|------|---------|-------|
| **Ping Baseline** | 0.84 ms avg | Stable latency within region |
| **Throughput (iperf3)** | 2.3 Gbps | Limited by instance type |
| **Failover (Keepalived)** | 2.1 s | Seamless transition |
| **Recovery (Return)** | 2.4 s | No packet loss observed |
| **BGP Route Restore** | 1.9 s | lelastic auto-restart validated |
| **CPU / Memory** | 22 % CPU   120 MB RAM | Under heavy load |

> These are **illustrative numbers**; actual metrics will be recorded once Milestone-5 live testing begins.

---

## 🔍 Monitoring Commands

```bash
# Continuous ping from private node
ping -i 0.2 8.8.8.8

# Measure throughput
iperf3 -c speedtest.sjc.linode.com -t 60

# Observe VRRP transitions
journalctl -u keepalived -f

# Monitor lelastic for BGP route recovery
journalctl -u lelastic -f

# Verify SNAT rule consistency
nft list chain ip nat POSTROUTING
```

---

## 📊 Visualization Plan (Future)

- 📉 **Latency Timeline** – line graph (ping RTT over time)  
- 📈 **Throughput Stability** – iperf3 bandwidth curve  
- 🔁 **Failover Events** – timeline showing MASTER/BACKUP transitions  
- 🧮 **CPU vs Traffic Load** – scatter plot from `sar` data  

These charts will be auto-generated via `make benchmark` in a future release.

---

## ✅ Expected Outcome Summary

- NAT gateway maintains **< 3 s recovery time** during any failover.  
- No packet loss beyond 3–5 ICMP packets.  
- Consistent outbound FIP after transition.  
- BGP re-establishes in under 2 s.  
- Sustained throughput near Linode plan maximum.  

---

Next doc 👉 [Repository Structure](https://github.com/sandipgangdhar/linode-nat-gateway/blob/feature/nat-gateway/docs/repository.md)
