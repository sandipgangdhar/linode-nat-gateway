<h1>⚙️ Client Configuration Guide — Dual NAT Gateway (ECMP Mode)</h1>
<blockquote>Version 1.0 | Last Updated: Nov 2025 | Author: Sandip Gangdhar</blockquote>

<hr>

<h2>🧩 Step 1 — Replace Default Route (Enable ECMP)</h2>
<p>
Replaces the default route with two equal-cost next hops so outbound traffic is distributed between <code>192.168.1.1</code> and <code>192.168.1.10</code>.  
Using <code>replace</code> ensures the current SSH session stays intact.
</p>

<pre><code>sudo ip route replace default scope global \
  nexthop via 192.168.1.1  dev eth1 weight 1 \
  nexthop via 192.168.1.10 dev eth1 weight 1
</code></pre>

<hr>

<h2>⚙️ Step 2 — Enable ECMP Hashing & Loose Reverse Path Filter</h2>
<p>
Enable kernel settings for per-flow load balancing and loose return path validation.
</p>

<ul>
<li><code>fib_multipath_hash_policy = 1</code> → Enables Layer-4 hashing</li>
<li><code>rp_filter = 2</code> → Enables loose mode for asymmetric return paths</li>
</ul>

<pre><code>echo 1 | sudo tee /proc/sys/net/ipv4/fib_multipath_hash_policy
sudo sysctl -w net.ipv4.conf.all.rp_filter=2
sudo sysctl -w net.ipv4.conf.eth1.rp_filter=2
</code></pre>

<hr>

<h2>🧱 Step 3 — Persist Settings Across Reboots</h2>

<h3>(a) Persist sysctl parameters</h3>
<pre><code>sudo tee /etc/sysctl.d/99-ecmp.conf >/dev/null <<'EOF'
net.ipv4.fib_multipath_hash_policy = 1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.eth1.rp_filter = 2
EOF
sudo sysctl --system
</code></pre>

<h3>(b) Persist ECMP route via systemd</h3>
<pre><code>sudo tee /etc/systemd/system/ecmp-route.service >/dev/null <<'EOF'
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
</code></pre>

<hr>

<h2>🔍 Step 4 — Validate Load Balancing</h2>
<p>
Send multiple external requests to confirm alternating egress through both NAT gateways.
</p>

<pre><code>for i in {1..10}; do curl -s https://api.ipify.org; echo; done
</code></pre>

<p>
Expected alternating outputs between:
<code>172.236.95.221</code> and <code>172.236.95.99</code>
</p>

<hr>

<h2>⚡ ECMP Failover Behavior & Self-Healing</h2>
<p>
When using ECMP with multiple next hops:
</p>
<ul>
<li>The Linux kernel continuously monitors reachability through the ARP table.</li>
<li>If a NAT gateway (e.g., <code>192.168.1.10</code>) stops replying, the kernel marks that route as <b>FAILED</b> and prunes it.</li>
<li>Traffic automatically flows through the remaining active NAT gateway (e.g., <code>192.168.1.1</code>).</li>
<li>When the failed gateway comes back online, it is automatically re-added.</li>
</ul>

<h3>🧠 Internal Logic</h3>
<pre><code>
1️⃣  Kernel sends packets → ARP lookup.
2️⃣  If ARP fails repeatedly → mark next-hop FAILED.
3️⃣  Remove from ECMP group until reachable again.
4️⃣  Restore route when ARP succeeds.
</code></pre>

<h3>📈 Behavior by Failure Type</h3>
<table>
<thead>
<tr><th>Failure Type</th><th>Detection</th><th>Behavior</th></tr>
</thead>
<tbody>
<tr><td>NAT process crash</td><td>ARP timeout</td><td>Route pruned; traffic shifts</td></tr>
<tr><td>Instance down</td><td>Unreachable via ARP</td><td>Auto-failover to healthy NAT</td></tr>
<tr><td>VLAN link loss</td><td>No ARP reply</td><td>Next hop marked failed</td></tr>
<tr><td>Both NATs down</td><td>No reachable next hops</td><td>Traffic halted until one returns</td></tr>
</tbody>
</table>

<h3>🔧 Optional — Faster Failure Detection (Ping Probing)</h3>
<pre><code>sudo ip route replace default \
  nexthop via 192.168.1.1 dev eth1 weight 1 \
  nexthop via 192.168.1.10 dev eth1 weight 1 \
  nexthop ping 192.168.1.1 \
  nexthop ping 192.168.1.10
</code></pre>

<p>
Using <code>nexthop ping</code> (Linux 5.14+) triggers periodic probes for each gateway to achieve sub-5-second failover.
</p>

<h3>🧾 Summary</h3>
<ul>
<li>Linux ECMP automatically removes dead next hops — no manual action required.</li>
<li><code>fib_multipath_hash_policy = 1</code> ensures per-flow hashing for better load distribution.</li>
<li><code>rp_filter = 2</code> allows asymmetric return paths without packet drops.</li>
<li>Optionally, <code>nexthop ping</code> or <code>keepalived</code> can speed detection.</li>
</ul>

<h2>🧭 Reference Summary</h2>

<table>
<thead>
<tr><th>Component</th><th>Setting</th><th>Purpose</th></tr>
</thead>
<tbody>
<tr><td>Default route</td><td>ECMP</td><td>Split outbound traffic across both NATs</td></tr>
<tr><td>Hash policy</td><td>1 (L3+L4)</td><td>Per-flow balancing</td></tr>
<tr><td>RP filter</td><td>Loose (2)</td><td>Allow asymmetric return paths</td></tr>
<tr><td>Systemd unit</td><td>ecmp-route.service</td><td>Restore routes on boot</td></tr>
</tbody>
</table>

<hr>

<h2>📘 Example Topology</h2>
<pre><code>+-----------------------+
| Private Host (eth1)  |
| 192.168.1.20        |
| Default route → ECMP |
| via 192.168.1.1/10  |
+-----------+-----------+
            |
   VLAN 192.168.1.0/24
            |
+-----------+-----------+
| NAT1 → 172.236.95.221 |
| NAT2 → 172.236.95.99  |
+------------------------+
</code></pre>

<hr>

<h2>🧰 Step 5 — Verification & Troubleshooting</h2>

<h3>🟢 Check current routes</h3>
<pre><code>ip route show default
ip route show table main | grep default
</code></pre>

<h3>🟢 Verify ECMP hash policy and rp_filter</h3>
<pre><code>sysctl net.ipv4.fib_multipath_hash_policy
sysctl net.ipv4.conf.all.rp_filter
sysctl net.ipv4.conf.eth1.rp_filter
</code></pre>

<h3>🟢 Confirm per-flow NAT distribution</h3>
<pre><code>for i in {1..20}; do curl -s https://api.ipify.org; echo; done
</code></pre>

<h3>🟢 Trace route selection</h3>
<pre><code>ip route get 8.8.8.8
</code></pre>

<h3>🟢 Inspect NAT connection tracking table</h3>
<pre><code>sudo conntrack -L | grep -E 'dport=80|dport=443' | head
</code></pre>

<h3>🟢 Restart ECMP route service if changes applied</h3>
<pre><code>sudo systemctl restart ecmp-route.service
sudo systemctl status ecmp-route.service
</code></pre>

<hr>

<p><b>✅ End State:</b> Dual-NAT ECMP routing is active, traffic evenly distributed across both NAT gateways, and configurations persist after reboot.</p>

</body>
</html>
