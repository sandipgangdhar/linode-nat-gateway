<h1>Milestone 2 — Completion Report</h1>
<h2>Project: Linode High Availability NAT Gateway</h2>
<p><strong>Date:</strong> November 2025<br>
<strong>Author:</strong> Sandip Gangdhar<br>
<strong>Version:</strong> 1.0</p>

<h2>✅ Objective</h2>
<p>To deploy and validate a <strong>redundant, stateful, and fault-tolerant NAT Gateway</strong> setup on Linode using open-source Linux components. This milestone ensures that the base HA network stack — including VRRP, nftables, and conntrack synchronization — is fully functional and reliable under real-world failover conditions.</p>

<h2>🧩 Achieved Components</h2>
<h3>1. High-Availability Gateway Pair</h3>
<ul>
<li>Two or more <strong>Linux gateway nodes</strong> deployed within the same <strong>VLAN/LAN segment</strong>.</li>
<li>Configured with <strong>Keepalived (VRRP)</strong> to provide a <strong>floating Virtual IP (VIP)</strong> for automatic failover.</li>
<li>Verified VIP mobility between nodes under failure and recovery scenarios.</li>
</ul>

<h3>2. Stateful NAT & Firewall Layer</h3>
<ul>
<li><strong>nftables</strong> implemented for NAT (SNAT/MASQUERADE) and packet filtering.</li>
<li>Rulebase persisted across reboots with consistent hook priorities.</li>
<li>Logging and rate-limiting rules configured for security and observability.</li>
</ul>

<h3>3. Stateful Connection Synchronization</h3>
<ul>
<li><strong>conntrackd</strong> configured and enabled on both gateway nodes.</li>
<li>Synchronization occurs over a <strong>dedicated sync interface (eth2)</strong>.</li>
<li>Real-time state replication for TCP and UDP flows across nodes verified.</li>
<li>Active sessions remain intact during failover.</li>
</ul>

<h3>4. Interface Role Segregation</h3>
<table>
<tr><th>Interface</th><th>Purpose</th><th>Example</th><th>Notes</th></tr>
<tr><td>wan</td><td>Public uplink</td><td>eth0</td><td>Connected to Linode public network.</td></tr>
<tr><td>lan</td><td>Internal/VLAN</td><td>eth1</td><td>Connected to the private VLAN segment.</td></tr>
<tr><td>sync</td><td>State sync interface</td><td>eth2</td><td>Dedicated to conntrackd synchronization.</td></tr>
</table>

<h2>🧪 Validation & Testing Results</h2>
<table>
<tr><th>Test Case</th><th>Description</th><th>Result</th></tr>
<tr><td>VRRP Failover (soft)</td><td>Stopped keepalived on MASTER node</td><td>✅ VIP moved to BACKUP within 3–4 seconds</td></tr>
<tr><td>VRRP Failover (hard)</td><td>Simulated WAN disconnection on MASTER</td><td>✅ BACKUP assumed MASTER role automatically</td></tr>
<tr><td>Session Continuity</td><td>Ongoing TCP and UDP flows during failover</td><td>✅ Sessions remained active and resumed seamlessly</td></tr>
<tr><td>Routing & NAT</td><td>Verified outbound SNAT translation via VIP</td><td>✅ Consistent NAT behavior</td></tr>
<tr><td>Persistence</td><td>Rebooted both nodes one-by-one</td><td>✅ VRRP, NAT, and conntrackd auto-recovered successfully</td></tr>
</table>

<h2>⚙️ Technical Summary</h2>
<table>
<tr><th>Component</th><th>Purpose</th><th>Status</th></tr>
<tr><td>Keepalived (VRRP)</td><td>VIP management and failover</td><td>✅ Configured and verified</td></tr>
<tr><td>nftables</td><td>NAT & firewall</td><td>✅ Ruleset persistent</td></tr>
<tr><td>conntrackd</td><td>Stateful sync</td><td>✅ Operational</td></tr>
<tr><td>sync VLAN</td><td>State replication</td><td>✅ Reachable and isolated</td></tr>
<tr><td>Systemd services</td><td>Startup automation</td><td>✅ Verified on boot</td></tr>
<tr><td>sysctl tuning</td><td>Forwarding & rp_filter tuning</td><td>✅ Applied</td></tr>
</table>

<h2>📊 Key Observations</h2>
<ul>
<li>Failover latency averaged <strong>~3 seconds</strong>, with minimal packet loss (&lt;3 ICMPs dropped).</li>
<li>All NAT sessions preserved during failover.</li>
<li>No asymmetric routing observed.</li>
<li>conntrackd sync achieved full state parity across both nodes.</li>
</ul>

<h2>🧱 Current Architecture Diagram</h2>
<pre>
           +----------------------+
           |    Public Network    |
           +----------+-----------+
                      |
             VRRP Floating VIP
                      |
       +--------------+--------------+
       |                             |
+--------------+             +--------------+
|  Gateway-1   |             |  Gateway-2   |
| (MASTER)     |             | (BACKUP)     |
|--------------|             |--------------|
| eth0 (WAN)   |             | eth0 (WAN)   |
| eth1 (LAN)   |             | eth1 (LAN)   |
| eth2 (SYNC)  |<--sync-->   | eth2 (SYNC)  |
| nftables + conntrackd      | nftables + conntrackd |
+--------------+             +--------------+
       |                             |
       +-------------+---------------+
                     |
                VLAN / LAN Segment
                     |
                Internal Instances
</pre>

<div class="next">
<h2>🚀 Next Steps — Milestone 3: High Availability Hardening & Observability</h2>
<table>
<tr><th>Area</th><th>Focus</th><th>Planned Enhancements</th></tr>
<tr><td>Failover Optimization</td><td>Reduce VRRP failover time below 3 seconds</td><td>Tune advert_int, preempt_delay, health scripts</td></tr>
<tr><td>State Sync Tuning</td><td>Improve conntrackd resync reliability</td><td>Enable FTFW mode and buffer tuning</td></tr>
<tr><td>System Hardening</td><td>Kernel parameters, ARP flux mitigation</td><td>Add sysctl and nftables fine-tuning</td></tr>
<tr><td>Observability Stack</td><td>Prometheus, Grafana, Loki integration</td><td>Add exporters, dashboards, and alerts</td></tr>
<tr><td>Runbooks & Chaos Testing</td><td>Operational testing and documentation</td><td>Simulate failures and validate resiliency</td></tr>
</table>
</div>

<div class="status">
<h2>🏁 Status</h2>
<p><strong>Milestone 2 successfully completed.</strong><br>
The environment is stable, stateful, and ready for the observability and tuning work planned in <strong>Milestone 3</strong>.</p>
</div>

<p><strong>Prepared by:</strong><br>
Sandip Gangdhar<br>
Senior Technical Solutions Architect — Akamai Connected Cloud (Linode)</p>

</body>
