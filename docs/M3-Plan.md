    <h2>Scope Overview</h2>
    <ul>
      <li>Sub‑3 second failover with consistent connection retention</li>
      <li>Full conntrack state synchronization and recovery</li>
      <li>Security &amp; system hardening across kernel, ARP, ACLs</li>
      <li>Observability stack: Prometheus, Grafana, Loki/Promtail, alerting</li>
    </ul>

    <h2>Phase 1 — Failover Optimization (HA Resiliency)</h2>
    <table>
      <thead>
        <tr><th>Task</th><th>Description</th><th>Deliverable</th></tr>
      </thead>
      <tbody>
        <tr>
          <td><strong>VRRP Tuning</strong></td>
          <td>Tune <code>advert_int</code>, <code>preempt_delay</code>, and health-check cadence to reach sub‑3 s failover while avoiding flaps.</td>
          <td>Tuned <code>keepalived.conf</code></td>
        </tr>
        <tr>
          <td><strong>Health Scripts</strong></td>
          <td>Extend <code>/usr/local/sbin/ha-check.sh</code> for multipath checks (default GW ping, external ICMP, HTTP 204 reachability).</td>
          <td>Updated script + syslog entries</td>
        </tr>
        <tr>
          <td><strong>GARP Broadcasts</strong></td>
          <td>Issue multiple Gratuitous ARPs on master promotion to flush neighbor caches and prevent black-holing.</td>
          <td>GARP logic in <code>notify_master</code></td>
        </tr>
        <tr>
          <td><strong>Failover Tests</strong></td>
          <td>Soft &amp; hard failover drills; capture packet-loss and session retention metrics.</td>
          <td>Test report &amp; graphs</td>
        </tr>
      </tbody>
    </table>

    <h2>Phase 2 — conntrackd Enhancements (State Synchronization)</h2>
    <table>
      <thead>
        <tr><th>Task</th><th>Description</th><th>Deliverable</th></tr>
      </thead>
      <tbody>
        <tr>
          <td><strong>FTFW Mode</strong></td>
          <td>Enable Fault‑Tolerant Firewall (FTFW) mode for live state mirroring including expectations.</td>
          <td>Updated <code>conntrackd.conf</code></td>
        </tr>
        <tr>
          <td><strong>Sync Channel Hardening</strong></td>
          <td>Isolate sync VLAN; add PSK; validate MTU; consider disabling GSO/TSO offloads if needed.</td>
          <td>Secure sync path</td>
        </tr>
        <tr>
          <td><strong>State Reconciliation</strong></td>
          <td>Periodic hash comparisons via <code>conntrackd -c stats diff</code> to validate parity and drift.</td>
          <td>Reconciliation logs</td>
        </tr>
        <tr>
          <td><strong>Stress Testing</strong></td>
          <td>Drive &gt;=10k NAT connections with <code>iperf3</code>/tcpreplay; measure sync latency &amp; loss.</td>
          <td>Benchmarks &amp; charts</td>
        </tr>
      </tbody>
    </table>

    <h2>Phase 3 — System &amp; Network Hardening</h2>
    <table>
      <thead>
        <tr><th>Category</th><th>Action</th></tr>
      </thead>
      <tbody>
        <tr>
          <td><strong>Kernel Tuning</strong></td>
          <td>Ensure <code>rp_filter=2</code>, increase <code>nf_conntrack_max</code>/<code>_buckets</code>, disable redirects; persist via <code>/etc/sysctl.d/</code>.</td>
        </tr>
        <tr>
          <td><strong>ARP Flux Mitigation</strong></td>
          <td>Apply <code>arp_ignore=1</code>, <code>arp_announce=2</code> to stabilize VIP mobility.</td>
        </tr>
        <tr>
          <td><strong>Firewall Policy</strong></td>
          <td>Default drop with rate‑limited logs; SSH/metrics allow‑lists; explicit VRRP acceptance on LAN.</td>
        </tr>
        <tr>
          <td><strong>Access Control</strong></td>
          <td>Root‑only for keepalived/conntrackd configs; tighten file permissions and service units.</td>
        </tr>
        <tr>
          <td><strong>Security Audits</strong></td>
          <td>Run <code>lynis</code> or <code>oscap</code> baselines; track findings and remediation.</td>
        </tr>
      </tbody>
    </table>

    <h2>Phase 4 — Observability Stack Integration</h2>
    <h3>1) Prometheus &amp; Node Exporters</h3>
    <ul>
      <li>Deploy <code>node_exporter</code> on each gateway.</li>
      <li>Enable textfile collector for:
        <ul>
          <li><code>/proc/sys/net/netfilter/nf_conntrack_count</code> &amp; <code>_max</code></li>
          <li>nftables counters snapshots</li>
          <li>Keepalived VRRP state (VIP presence, role)</li>
        </ul>
      </li>
    </ul>

    <h3>2) Grafana Dashboards</h3>
    <ul>
      <li>VRRP state timeline (MASTER/BACKUP)</li>
      <li>Conntrack utilization % and new flows/sec</li>
      <li>NAT throughput (WAN rx/tx bytes per second)</li>
      <li>Drop rate and nftables log counters</li>
    </ul>

    <h3>3) Alerting Rules (Alertmanager)</h3>
    <table>
      <thead><tr><th>Alert</th><th>Condition</th><th>Severity</th></tr></thead>
      <tbody>
        <tr><td>VRRP State Deviation</td><td>Preferred node not MASTER &gt; 60s</td><td>critical</td></tr>
        <tr><td>Conntrack Usage &gt; 80%</td><td><code>count/max &gt; 0.8</code> for 5m</td><td>warning</td></tr>
        <tr><td>Drop Rate High</td><td>nftables drop counters over threshold</td><td>warning</td></tr>
        <tr><td>Healthcheck Failures</td><td>&ge; 3 failures within 2m</td><td>critical</td></tr>
      </tbody>
    </table>

    <h3>4) Loki + Promtail</h3>
    <ul>
      <li>Ship <code>/var/log/syslog</code> (keepalived, conntrackd), kernel, and nftables logs with labels <code>{job="nat-ha"}</code>.</li>
      <li>Correlate VRRP events with NAT counters via Grafana Explore.</li>
    </ul>

    <h2>Phase 5 — Chaos &amp; Acceptance Testing</h2>
    <table>
      <thead><tr><th>Scenario</th><th>Success Criteria</th></tr></thead>
      <tbody>
        <tr><td>Soft failover (stop keepalived)</td><td>VIP shift &lt; 3 s; ≤ 3 ICMP drops</td></tr>
        <tr><td>Hard failover (unplug WAN)</td><td>Backup assumes VIP autonomously</td></tr>
        <tr><td>Stateful TCP flow</td><td>Ongoing SSH/iperf sessions survive</td></tr>
        <tr><td>UDP stream</td><td>Packet loss &lt; 2% during switch</td></tr>
        <tr><td>Reboot sequence</td><td>VIP + conntrack roles auto‑recover</td></tr>
      </tbody>
    </table>

    <h2>Deliverables</h2>
    <table>
      <thead><tr><th>Output</th><th>Description</th></tr></thead>
      <tbody>
        <tr><td><code>nftables.conf</code></td><td>Hardened ruleset with counters and rate‑limited logging</td></tr>
        <tr><td><code>keepalived.conf</code></td><td>Optimized timers and notify hooks (GARP + role scripts)</td></tr>
        <tr><td><code>conntrackd.conf</code></td><td>FTFW mode, PSK, sync tuning, stats hooks</td></tr>
        <tr><td><code>ha-check.sh</code></td><td>Multipath health with HTTP 204 test</td></tr>
        <tr><td><code>prometheus.yml</code></td><td>Targets, textfile collector paths, alert rules</td></tr>
        <tr><td><code>grafana-dashboard.json</code></td><td>VRRP &amp; NAT observability panels</td></tr>
        <tr><td><code>runbook-failover.md</code></td><td>Ops guide for maintenance &amp; chaos tests</td></tr>
      </tbody>
    </table>

    <h2>Expected Outcome</h2>
    <div class="card ok">
      By the end of Milestone 3, failover will be <strong>sub‑3 seconds</strong> with stateful continuity, observability will provide <strong>real‑time HA visibility</strong>, and the system will be <strong>hardened and production‑ready</strong>.
    </div>

    <div class="footer">
      Prepared by: <strong>Sandip Gangdhar</strong> — Senior Cloud Architect, Akamai Connected Cloud (Linode)
    </div>
  </div>
</body>
</html>
