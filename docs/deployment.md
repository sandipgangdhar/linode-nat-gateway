<h1>⚙️ Deployment Guide — Linode NAT Gateway (HA)</h1>
<p>This guide explains how to deploy the <strong>Linode NAT Gateway</strong> in two modes:</p>
<ul>
  <li><strong>Single Pair (1 HA pair)</strong> — one VRRP pair (<code>nat-a</code>, <code>nat-b</code>)</li>
  <li><strong>Multi Pair (N HA pairs)</strong> — multiple VRRP pairs (<code>nat1-a/b</code>, <code>nat2-a/b</code>, …)</li>
</ul>
<p class="note">✅ <strong>Terraform auto-generates</strong> the Ansible inventory and pair-specific <code>group_vars</code> files. <strong>Do not edit</strong> those by hand.</p>

<hr />

<h2>🧭 Prerequisites</h2>
<table>
  <thead><tr><th>Tool</th><th style="text-align:right">Version</th><th>Purpose</th></tr></thead>
  <tbody>
    <tr><td>Terraform</td><td style="text-align:right">≥ 1.6.x</td><td>Provision Linodes, VLANs, IP sharing, etc.</td></tr>
    <tr><td>Ansible</td><td style="text-align:right">≥ 2.15.x</td><td>Configure nftables, Keepalived, Lelastic</td></tr>
    <tr><td>linode-cli (optional)</td><td style="text-align:right">Latest</td><td>Manual checks</td></tr>
    <tr><td>SSH keypair</td><td style="text-align:right">RSA / ED25519</td><td>Node auth</td></tr>
    <tr><td>Git</td><td style="text-align:right">Latest</td><td>Source control</td></tr>
  </tbody>
</table>

<h3>Environment</h3>
<pre><code>export LINODE_TOKEN="your-linode-api-token"
git clone https://github.com/sandipgangdhar/linode-nat-gateway.git
cd linode-nat-gateway/terraform
</code></pre>

<hr />

<h2>🧱 Variables &amp; Logic Flow</h2>
<p>
The deployment is <strong>fully dynamic</strong> — Terraform automatically creates the required number of NAT Gateway HA pairs depending on how many configurations you include in <code>var.nat_pairs</code>. Each list entry represents one redundant pair ( e.g., <code>nat1-a/b</code>, <code>nat2-a/b</code> ).
</p>

<ul>
  <li>If <code>nat_pairs</code> contains <strong>one item</strong> → one NAT HA pair is created (e.g., <code>nat1-a</code>, <code>nat1-b</code>).</li>
  <li>If <code>nat_pairs</code> contains <strong>multiple items</strong> → multiple independent HA pairs are created (e.g., <code>nat1-a/b</code>, <code>nat2-a/b</code>, <code>nat3-a/b</code>, …).</li>
</ul>

<p>There is now only <strong>one variable file</strong>: <code>terraform/terraform.tfvars</code>.  
All configuration — from shared IPs and VLAN labels to VRRP IDs — is defined inside this file.</p>

<h3>Common Variables</h3>
<p>Defined in <code>terraform/variables.tf</code> (applies to all NAT pairs):</p>
<ul>
  <li><code>region</code> — Linode region (e.g. <code>"in-maa"</code>)</li>
  <li><code>image</code> — base image (default <code>"linode/ubuntu24.04"</code>)</li>
  <li><code>type</code> — Linode instance type (default <code>"g6-standard-2"</code>)</li>
  <li><code>ssh_authorized_keys</code> — public keys for cloud-init access</li>
  <li><code>use_ip_share</code> — enables Linode IP sharing (default <code>true</code>)</li>
  <li><code>dcid</code> — Linode data center ID (required when IP sharing is enabled)</li>
  <li><code>placement_group_label</code> / <code>placement_group_type</code> — optional anti-affinity grouping</li>
  <li><code>nat_pairs</code> — list of NAT Gateway pairs (each item defines its own VLAN, shared IP, VRRP config, etc.)</li>
</ul>

<h3>Dynamic Behavior</h3>
<ul>
  <li>Each item in <code>nat_pairs</code> becomes a <strong>fully isolated HA pair</strong> (2 Linodes + VRRP).</li>
  <li>Terraform auto-generates:
    <ul>
      <li><code>../ansible/inventory.ini</code> — with all pairs and nodes</li>
      <li><code>../ansible/group_vars/nat.yml</code> — common vars</li>
      <li><code>../ansible/group_vars/nat_&lt;pair&gt;.yml</code> — per-pair vars</li>
    </ul>
  </li>
  <li>No conditional logic or flags — the system simply reads how many <code>nat_pairs</code> exist and builds that many HA pairs.</li>
</ul>

<h3>🧩 Example</h3>
<p>If you define:</p>
<pre><code>nat_pairs = [
  { name = "nat1", ... },
  { name = "nat2", ... },
  { name = "nat3", ... }
]
</code></pre>
<p>Terraform will automatically create three pairs: <code>nat1-a/b</code>, <code>nat2-a/b</code>, and <code>nat3-a/b</code>,  
along with matching <code>group_vars/nat_nat1.yml</code>, <code>nat_nat2.yml</code>, <code>nat_nat3.yml</code> files and inventory entries.</p>

<h2>🔧 Configure with Ansible</h2>
<p>Terraform writes files to <code>../ansible</code>:</p>
<ul>
  <li><code>inventory.ini</code> — with groups/hosts and hostvars (public IPs, priorities, etc.)</li>
  <li><code>group_vars/nat.yml</code> — common vars (e.g., <code>dcid</code>)</li>
  <li><code>group_vars/nat_&lt;pair&gt;.yml</code> — per-pair vars (<code>fip</code>, <code>vlan_vip</code>, <code>vrrp_id</code>, etc.)</li>
</ul>
<p>✅ If you set <code>vrrp_id</code> in <code>nat_pairs</code>, it’s <strong>propagated</strong> to group_vars (e.g., <code>vrrp_id: 51/52</code>).</p>

<h3>Run Ansible</h3>
<pre><code>cd ../ansible
ANSIBLE_HOST_KEY_CHECKING=false ansible-playbook -i inventory.ini site.yml
</code></pre>
<p>The playbook:</p>
<ul>
  <li>Waits for cloud-init</li>
  <li>Pauses/clears apt/dpkg locks</li>
  <li>Installs/configures <code>nftables</code>, <code>keepalived</code>, <code>lelastic</code></li>
  <li>Drops templates:
    <ul>
      <li><code>/etc/keepalived/keepalived.conf</code></li>
      <li><code>/etc/nftables.d/nat.nft</code> (SNAT → FIP)</li>
      <li><code>/usr/local/sbin/keepalived-notify.sh</code> (bind/unbind FIP, etc.)</li>
    </ul>
  </li>
  <li>Enables &amp; starts services</li>
  <li>Validates VIP/FIP &amp; SNAT</li>
</ul>
<p class="note">If you see apt lock retries, just re-run the play—our playbook already includes robust lock handling.</p>

<hr />

<h2>✅ Post-Deploy Checks</h2>
<pre><code># Keepalived status
systemctl status keepalived

# VIP present only on MASTER
ip addr show &lt;vlan_if&gt; | grep -E '192\.168\.'

# FIP (shared public IP) only on MASTER (bound/unbound via notify script)
ip addr show &lt;pub_if&gt; | grep -E '172\.'

# SNAT rule present
nft list chain ip nat POSTROUTING | grep snat

# Outbound identity (MASTER will show its pair's FIP)
curl -s ifconfig.me
</code></pre>
<p><strong>Expected:</strong></p>
<ul>
  <li>In each pair, one node is <strong>MASTER</strong> (owns VIP+FIP), the other is <strong>BACKUP</strong>.</li>
  <li><code>curl -s ifconfig.me</code> from a <strong>private host</strong> behind the VIP will show the <strong>pair’s shared public IP</strong>.</li>
</ul>

<hr />

<h2>🧪 Failover Tests (Optional)</h2>
<pre><code># On the current MASTER:
systemctl stop keepalived
# or
ip link set &lt;pub_if&gt; down
# or
reboot

# Restore:
systemctl start keepalived
</code></pre>

<hr />

<h2>👩‍💼 Private Hosts — ECMP to Two Gateways</h2>
<p>To use <strong>both NAT pairs</strong> for outbound (ECMP), see <code>docs/client-configuration.md</code>. Quick gist (example VLAN VIPs <code>192.168.1.1</code> and <code>192.168.1.10</code> on <code>eth1</code>):</p>
<pre><code># 1) Replace default route with two equal-cost nexthops (do NOT delete default first)
sudo ip route replace default scope global \
  nexthop via 192.168.1.1  dev eth1 weight 1 \
  nexthop via 192.168.1.10 dev eth1 weight 1

# 2) Improve per-flow hashing and accept asymmetric return paths
echo 1 | sudo tee /proc/sys/net/ipv4/fib_multipath_hash_policy
sudo sysctl -w net.ipv4.conf.all.rp_filter=2
sudo sysctl -w net.ipv4.conf.eth1.rp_filter=2

# Persist via /etc/sysctl.d/nat-ecmp.conf
sudo tee /etc/sysctl.d/nat-ecmp.conf >/dev/null &lt;&lt;'CONF'
net.ipv4.fib_multipath_hash_policy=1
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.eth1.rp_filter=2
CONF
sudo sysctl --system
</code></pre>
<ul>
  <li><code>ip route replace</code> updates the default route atomically (safer over SSH).</li>
  <li><code>fib_multipath_hash_policy=1</code> hashes on src/dst IP+port (better flow spread).</li>
  <li><code>rp_filter=2</code> (loose) allows asymmetric replies typical with ECMP/NAT.</li>
</ul>

<hr />

<h2>🧯 Troubleshooting</h2>
<ul>
  <li><strong>“ip address associated with VRID … not present in MASTER advert”</strong><br>
    Ensure <code>vrrp_id</code> is <strong>unique per pair</strong> and <code>vlan_vip</code> is correct in the per-pair <code>group_vars</code> file.</li>
  <li><strong>Both pairs NAT via the same public IP</strong><br>
    Verify each pair’s <code>shared_ipv4</code> differs and appears in its <code>group_vars/nat_&lt;pair&gt;.yml</code> as <code>fip</code>.</li>
  <li><strong>Apt/dpkg lock loops</strong><br>
    Re-run the play; pre_tasks already try to kill auto updates, clear locks, and <code>dpkg --configure -a</code>.</li>
  <li><strong>Inventory looks wrong</strong><br>
    Re-run <code>terraform apply</code>; it regenerates <code>../ansible/inventory.ini</code> and <code>group_vars</code>.</li>
</ul>

<hr />

<h2>🗑️ Teardown</h2>
<pre><code>cd terraform
terraform destroy -auto-approve
</code></pre>

<hr />

<h2>📦 Files Touched by Terraform</h2>
<ul>
  <li><code>terraform/*.tf</code> — core infra + logic</li>
  <li><code>../ansible/inventory.ini</code> — generated</li>
  <li><code>../ansible/group_vars/nat.yml</code> — generated</li>
  <li><code>../ansible/group_vars/nat_&lt;pair&gt;.yml</code> — generated</li>
</ul>

<p class="ok"><strong>End state:</strong> HA NAT (single or multiple pairs) with validated VIP/FIP failover, SNAT via shared IP, and optional ECMP from private hosts.</p>

</body>
</html>
